# Quickstart

Bring up a Kubernetes cluster on borrowed Slurm nodes, then give them back clean.

Run everything from the Slurm controller (`polite-possum-controller`) as `ubuntu`.

> **Before you start, understand what this does.** It submits Slurm jobs that hold GPU nodes,
> and installs k3s on those nodes over SSH. The cluster is shared with other people. Read
> the "do no harm" section of [README.md](README.md) first — teardown is not optional
> housekeeping, it is the point.

---

## 0. One-time setup

```bash
cd /home/ubuntu/dkennetz/k8s_bootstrap

# Controller-side tools (kubectl + helm only; no daemons on the controller, ever)
# NOTE: arrives in step 5. Until then, use `kubectl` via the control-plane node:
#   ssh <cp-node> sudo /opt/k8s-bootstrap/bin/k3s kubectl get nodes

# GitHub credentials for Argo CD, kept OUTSIDE the repo and never committed
mkdir -p ~/.config/k8s-bootstrap
printf '%s' 'ghp_yourtokenhere' > ~/.config/k8s-bootstrap/github-token
chmod 600 ~/.config/k8s-bootstrap/github-token
```

Confirm the cluster looks the way the repo expects before touching anything:

```bash
bin/k8s-status                    # no leases, no cluster yet
bin/k8s-preflight --workers 3     # read-only: picks candidate trays and checks them
```

Preflight also verifies each candidate's **identity** — that the machine reachable at a
Slurm node name really is that node. On dynamic clusters the `NodeAddr`/DNS mapping goes
stale, and installing on the wrong machine is the worst thing this tool could do. Trays that
fail this check are skipped automatically; never work around it by using an IP directly.

`k8s-preflight` refuses to proceed unless every candidate node is genuinely safe to use —
no existing CNI state, no `KUBE-`/`CNI-` iptables rules, `/mnt/localdisk` mounted with
headroom, swap off, cgroup v2, k8s ports free, and `nvidia-imex` healthy. If it complains,
**do not override it**; pick different nodes.

---

## 1. Bring up the cluster (1 control plane + 3 workers)

```bash
bin/k8s-up --cluster polite-possum --workers 3
```

This leases 4 trays from one rack, installs the k3s server on tray 0 (tainted so no GPU work
lands there), joins 3 agents, then installs Cilium, the GPU Operator, storage, and monitoring.
Takes a few minutes, mostly image pulls.

```bash
export KUBECONFIG=~/.local/state/k8s-bootstrap/polite-possum/kubeconfig
kubectl get nodes -o wide
kubectl get nodes -L nvidia.com/gpu.clique -o custom-columns=\
'NAME:.metadata.name,GPUS:.status.capacity.nvidia\.com/gpu,CLIQUE:.metadata.labels.nvidia\.com/gpu\.clique'
```

You want 4 nodes `Ready` and a **consistent `CliqueId`** across them — that last one
confirms they share an NVLink domain.

`bin/k8s-up` installs Cilium as part of bring-up, because nodes stay `NotReady` without a
CNI. Pass `--no-cni` to stop before that. The `nvidia.com/gpu` resource does not appear
until the GPU Operator lands in step 6; until then GPUs are reached via
`runtimeClassName: nvidia`, which k3s wires up automatically.

---

## 2. Prove the plumbing

Run these in order. Each is a gate; do not skip ahead on a failure.

```bash
# Gate 1 -- a pod can see the GPUs through the `nvidia` RuntimeClass
kubectl apply -f workloads/plumbing/01-gpu-smoke.yaml
kubectl wait --for=condition=complete job/gpu-smoke --timeout=300s
kubectl logs job/gpu-smoke                       # expect 4x NVIDIA GB300, GPU-SMOKE-OK

# Gate 2 -- cross-node pod traffic over geneve, plus services without kube-proxy
kubectl apply -f workloads/plumbing/02-pod-to-pod.yaml
kubectl wait --for=condition=complete job/pod-to-pod --timeout=300s
kubectl logs job/pod-to-pod                      # expect POD-TO-POD-OK
```

Both jobs exit nonzero on failure, so `kubectl wait` timing out is itself the signal —
do not read the log and assume success from the absence of errors.

## 2b. GPUs as a scheduled resource

`bin/k8s-up` does not install the GPU Operator; GPUs are reachable via
`runtimeClassName: nvidia` without it, but the *scheduler* knows nothing about them until
the device plugin exists.

```bash
bin/k8s-gpu                                          # device plugin (default)
bin/k8s-gpu --status                                 # capacity, allocatable, clique, DRA

kubectl apply -f workloads/plumbing/03-gpu-resource.yaml
kubectl wait --for=condition=complete job/gpu-resource --timeout=300s
kubectl logs job/gpu-resource                        # expect GPU-RESOURCE-OK
```

Gate 3 asks for `nvidia.com/gpu: 1` and asserts exactly **one** GPU is visible. Gate 1 sees
all four, because `runtimeClassName` alone bypasses the scheduler — that difference is the
point of having both.

Check `nvidia.com/gpu.clique` in `--status`: it reads `<ClusterUUID>.<CliqueId>` and
identifies the rack's NVLink domain. Nodes sharing it can do multi-node NVLink.

### Optional: Dynamic Resource Allocation

```bash
bin/k8s-gpu --dra                                    # EXPERIMENTAL (NVIDIA's label)
kubectl apply -f workloads/plumbing/04-dra-gpu.yaml
kubectl wait --for=condition=complete job/dra-gpu --timeout=300s
kubectl logs job/dra-gpu                             # expect DRA-GPU-OK
```

DRA is GA in Kubernetes 1.34+ and this k3s serves it. Pods reference a `ResourceClaim`
against the `gpu.nvidia.com` DeviceClass instead of requesting `nvidia.com/gpu`.

Two things to know before using it:

- **The modes are mutually exclusive.** Under DRA the device plugin is removed and
  `nvidia.com/gpu` stops existing as a resource, so every manifest that requests it stops
  scheduling. Observed live, allocatable reads `<none>` rather than `0`, and the scheduler
  says `Insufficient nvidia.com/gpu` — which reads like a capacity problem and is not one.
  Adding nodes will not help.
- **The NCCL gates need their DRA variants.** Gates 07 and 08 request
  `limits: nvidia.com/gpu`, so on DRA use
  `workloads/plumbing/09-nccl-4x4-dra.yaml` instead of 08 — same 8-rank proof, GPUs from a
  `ResourceClaim` with `count: 4`. Verified at 696 GB/s, versus 697 for the device-plugin
  path, so DRA costs nothing measurable here.
- **It does not require Path B.** `computeDomains` stays disabled, so the host's
  `nvidia-imex` is untouched. Multi-node NVLink ComputeDomains are a separate decision.

Switch back with `bin/k8s-gpu` (no flag). The switch deletes the outgoing CR itself, because
helm does not prune it and the two controllers deadlock if both CRs exist.

### The multi-node NCCL gate

This is the one that validates the assumption the whole GPU design rests on: that NCCL
works inside a pod against the **host-managed** IMEX domain, so `nvidia-imex.service` never
has to be masked. It needs **two workers in the same rack** (`bin/k8s-up --workers 2`),
because a rack is one NVLink domain.

```bash
kubectl apply -f workloads/plumbing/07-nccl-2node.yaml
kubectl wait --for=condition=complete job/nccl-2node --timeout=900s
kubectl logs job/nccl-2node -l batch.kubernetes.io/job-completion-index=0
```

Expect `NCCL-GATE-OK`, a `PERF {...}` line with the measured bus bandwidth, and a
`transport signals:` line showing which transport NCCL chose. First run pulls a ~20 GB
PyTorch image on both nodes, so allow several minutes.

It drives NCCL through `torch.distributed` rather than the MPI-linked `nccl-tests` on
`/fss`, because `mpirun` would need ssh between pods (the MPI Operator or ssh sidecars).
Same NCCL library, same collective, no extra component — see
[docs/PLAN.md](docs/PLAN.md).

If it fails, **stop** and read the IMEX section of the plan before building training on
Path A. The fallback is Path B (DRA ComputeDomain), which masks the provider's IMEX daemon
and is a decision worth making deliberately.

### Full scale: 4 GPUs x 2 trays

Gate 07 uses one GPU per pod, which is enough to prove cross-node NVLink. Gate 08 uses
every GPU on both trays — 8 ranks via `torchrun --nproc_per_node=4` — so intra-node NVLink
and cross-node MNNVL are exercised together in one communicator:

```bash
kubectl apply -f workloads/plumbing/08-nccl-4x4.yaml
kubectl wait --for=condition=complete job/nccl-4x4 --timeout=900s
kubectl logs job/nccl-4x4 -l batch.kubernetes.io/job-completion-index=0
```

Expect `NCCL-4x4-OK`, a `TOPO` line showing 8 ranks split 4-and-4 across two hosts, and a
`PERF` line with the bus bandwidth. The gate asserts all 8 ranks validated, that they really
spanned 2 hosts, and that `P2P/MNNVL` appears in the data path — so it cannot pass on a
socket fallback. It is the one that validates the
assumption the whole GPU design rests on: that NCCL works inside a pod against the
host-managed IMEX domain. Until it passes, do not build training on Path A — see the IMEX
section of [docs/PLAN.md](docs/PLAN.md).

---

## 2c. Storage and monitoring

```bash
bin/k8s-platform --all              # or --storage / --monitoring
bin/k8s-platform --status
```

Two StorageClasses, with different jobs:

| Class | Modes | Backed by | Use for |
|---|---|---|---|
| `local-path` (default) | RWO | `/mnt/localdisk` — 28 TB NVMe | scratch, checkpoints |
| `nfs` | **RWX** | `/fss` over NFSv3 | datasets, weights, anything multi-node |

`local-path` is node-local: a pod that moves nodes loses the data. That is the right trade
for scratch on a fast local disk, but it means multi-node training data must use `nfs`.

Every NFS volume is provisioned under `/fss/k8s-bootstrap/<cluster>/`, never at the share
root — `/fss` holds other people's data.

```bash
kubectl apply -f workloads/plumbing/05-storage.yaml
kubectl wait --for=condition=complete job/storage-check --timeout=300s
kubectl logs job/storage-check       # expect STORAGE-OK
```

Gate 5 asserts the RWX volume is visible from **more than one node** — one node would be
satisfied by a plain RWO volume, so that count is the whole test.

### Monitoring

Prometheus and Grafana, with **no node-exporter or dcgm-exporter of our own**: the hosts
already run those and the chart's versions would collide on their hostPorts. We scrape the
host ones instead, which also gets the provider's rdma/nvlink/pcie counters for free.

```bash
kubectl apply -f workloads/plumbing/06-monitoring.yaml
kubectl wait --for=condition=complete job/monitoring-check --timeout=300s
kubectl logs job/monitoring-check    # expect MONITORING-OK

# Grafana (no ingress, no LoadBalancer -- rule 9)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Host exporter ports, **verified by curling `/metrics`** rather than inferred from process
names: `:9100` node, `:9400` dcgm, `:9500` rdma, `:9600` nvlink, `:9700` pcie. Note `:9876`
is a healthcheck *file server*, not an exporter — scraping it just yields a down target.

## 3. Turn on GitOps

```bash
bin/k8s-bootstrap-gitops
kubectl -n argocd get applications
kubectl -n argocd port-forward svc/argocd-server 8080:443   # then https://localhost:8080
```

From here, change a version in `versions.env` or an overlay under
`gitops/overlays/scratch/`, commit, push, and watch Argo CD roll it out. That is the
intended way to test an upgrade — not by hand on a live cluster.

---

## 4. Scale up

```bash
bin/k8s-add-rack                          # +3 trays from a new rack
bin/k8s-add-rack --trays max              # every verified idle tray that rack has
bin/k8s-add-rack --rack ez4wq/bi4ua       # pin the rack instead of auto-selecting
bin/k8s-status
```

Each rack is its own Slurm lease and its own NVLink domain. A multi-node training job must
be pinned to a single rack — see `workloads/training/` for how that is expressed.

**You cannot grow a rack you already hold.** Slurm has no way to add nodes to a running
job, and one lease maps to exactly one rack, so `k8s-add-rack` always takes a *different*
rack and auto-selection skips the ones you already have. To end up with more trays in the
same rack, remove it and re-add it larger:

```bash
bin/k8s-remove-rack --rack ez4wq/bi4ua
bin/k8s-add-rack    --rack ez4wq/bi4ua --trays max
```

After adding a rack, remember the new trays have no `nvidia.com/gpu` until the GPU Operator
is installed — the same trap as a fresh cluster (section 2b). `k8s-add-rack` warns if it is
missing. If it is already installed, its DaemonSets roll onto the new nodes on their own.

### Two racks, two NVLink domains — what changes (recorded 2026-09-17, 34 nodes)

- **Pin the NCCL gates to one rack.** Gates 08/09 spread their two pods by hostname only, so
  on a two-rack cluster the scheduler can put them in different cliques and NCCL reports
  `MNNVL is available but not working` — a false failure. Add a `nodeSelector` on
  `k8s-bootstrap.io/rack: <rack>` (see the comment in `09-nccl-4x4-dra.yaml`); pinned to
  `b6y2q` the gate measured 697.19 GB/s, identical to a single-rack cluster.
- **Check that every worker got its GPU label.** After `bin/k8s-gpu --dra` on 34 nodes, four
  trays had a complete `NodeFeature` object (18 `10de` PCI devices) but no
  `nvidia.com/gpu.present` label, so no DRA ResourceSlice:
  `kubectl -n gpu-operator rollout restart deploy/gpu-operator-node-feature-discovery-master`
  fixed it within a minute. Compare `kubectl get resourceslices | wc -l` with your worker
  count before running anything that needs GPUs.
- **If you install Kueue, install nothing else until it is Ready.** Its mutating webhook
  (`failurePolicy: Fail`) intercepts Deployments and Jobs cluster-wide; during its rollout
  every `kubectl apply` of a Job or Deployment fails with `no endpoints available for service
  "kueue-webhook-service"` — including this repo's plumbing gates.
- **Never `scancel` a rack lease.** The trap tears trays down serially and `scancel` gives it
  Slurm's `KillWait` (30 s), not the 300 s signal lead (that applies to walltime only). A
  16-tray lease cancelled that way left 13 trays running `k3s-agent` while Slurm showed them
  `idle`; `bin/k8s-down --nodes <trays>` then `bin/k8s-verify-clean` is the recovery.

---

## 5. Give the nodes back

**Do not skip this, and do not just `scancel`.** k3s runs under systemd outside the Slurm
job cgroup, so cancelling the lease alone would leave kubelet running on nodes that go back
into the shared pool.

```bash
bin/k8s-down
bin/k8s-verify-clean          # must report ZERO drift
```

`k8s-verify-clean` diffs each node against the snapshot taken before install: iptables rules,
the host CDI spec's sha256, nvidia unit states, network interfaces, mounts, and
`/usr/local/bin`. It also checks the nodes returned to `idle` rather than `drained`. If it
reports drift, fix it before walking away.

Sanity check from Slurm's side:

```bash
sinfo -N -o "%N %T" | grep -E "$(cat ~/.local/state/k8s-bootstrap/polite-possum/nodes | paste -sd'|')"
```

---

## Everyday reference

```bash
bin/k8s-status                        # k8s + Slurm lease state together
bin/k8s-check-upgrades                # what is out of date in versions.env
bin/k8s-remove-rack --rack <rack>     # drop one rack, keep the cluster
kubectl -n monitoring port-forward svc/grafana 3000:80
```

## When something is wrong

| Symptom | Likely cause |
|---|---|
| A Prometheus `host-*` target is down | Curl `/metrics` on that port from the node. Not every listening port is an exporter — `:9876` serves HTML. |
| `Prometheus did not become ready`, no StatefulSet | Check `kubectl -n monitoring get prometheus -o json \| jq .items[].status.conditions` — a bad `additionalScrapeConfigs` blocks the operator from rendering any config at all. |
| A tray is `UNVERIFIED` after teardown | It went unreachable before the 'post' snapshot. Check `$STATE_DIR/teardown-logs/<node>.log` and `scontrol show node <node>`; re-run teardown when it returns. Never assume it was clean. |
| `nvidia.com/gpu` capacity is 4 but nothing schedules | Check **allocatable**, not capacity. If it is 0, the device plugin is gone (DRA mode) or both GPU CRs exist. `kubectl get clusterpolicy gpucluster` — only one may exist. |
| `could not select N identity-verified idle tray(s)` right after a teardown | Released trays sit in Slurm `comp` (completing) for a minute or two and are not yet `idle`. Wait ~60s and retry; `bin/k8s-status` shows real capacity. |
| `ImagePullBackOff` on a new chart | No `linux/arm64` image. Everything here is aarch64. |
| Node `NotReady`, agent won't join | Lease expired and its trap tore the node down. Check `squeue`. |
| Node shows up `drained` in Slurm | Healthcheck ran against it. It was probably idle, not leased. |
| Multi-node NCCL slow or failing | Nodes span two racks, so two NVLink domains. Pin to one rack. |
| Pod can't reach another node's pod | Cilium tunnel issue — nodes are in different /19 subnets. |
| Argo CD can't pull the repo | Missing or stale `~/.config/k8s-bootstrap/github-token`. |
