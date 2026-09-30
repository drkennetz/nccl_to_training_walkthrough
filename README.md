# k8s_bootstrap

Stand up a **scratch Kubernetes cluster on top of a borrowed Slurm GPU cluster**, scale it a
rack at a time, and tear it down leaving the nodes pristine.

We often get access to Slurm clusters and not Kubernetes clusters, but still need Kubernetes
to do our work. This repo makes that a scripted, repeatable, reversible operation rather than
a pile of one-off commands — and it is designed to be reused on the next borrowed cluster.

**New here? Start with [QUICKSTART.md](QUICKSTART.md).**
For the design and the reasoning behind every choice, read [docs/PLAN.md](docs/PLAN.md).

## The one rule

**Do no harm to the Slurm cluster.** It is shared with other people and it is not ours.
Kubernetes runs *adjacent to* Slurm, never reconfiguring it. Co-scheduling contention is
accepted; collateral damage is not. Where a choice trades cleanliness against capability,
this repo picks cleanliness and makes the capable option opt-in. That single constraint
explains most of what follows.

## How it works

```
Slurm controller                 leased trays (one Slurm placeholder job per rack)
  kubectl, helm, kubeconfig       ┌─────────────────────────────────────────────┐
  (no daemons, ever)              │ tray 0   k3s server  (tainted NoSchedule)   │
         │                        │ tray 1   k3s agent   4x GB300               │
         └── https://<cp>:6443 ───│ tray 2   k3s agent   4x GB300               │
                                  │ tray 3   k3s agent   4x GB300               │
                                  └─────────────────────────────────────────────┘
                                    one rack = 18 trays = one NVL72 NVLink domain
```

Nodes are held by a **real Slurm placeholder job**, not a reservation. That is deliberate:
the OCI healthcheck drains *idle* nodes every 300 s (`HealthCheckNodeState=IDLE,CYCLE`), and
nodes held by a running job are `ALLOCATED` and therefore skipped. It also keeps our usage
visible and legitimate to Slurm accounting. Because k3s runs under systemd outside the job
cgroup, each lease traps its own exit and cleans up, so walltime expiry or `scancel` never
leaves a node dirty.

## Commands

| Command | What it does |
|---|---|
| `bin/k8s-up` | Lease a control-plane tray + N workers, install, bootstrap the platform |
| `bin/k8s-add-rack` | Lease another rack and join its trays as workers |
| `bin/k8s-remove-rack` | Cordon, drain, uninstall, release that rack's lease |
| `bin/k8s-down` | Full teardown |
| `bin/k8s-status` | Kubernetes and Slurm lease state, side by side |
| `bin/k8s-verify-clean` | Diff node state against the pre-install snapshot — the do-no-harm test |
| `bin/k8s-check-upgrades` | Compare `versions.env` against upstream stable releases |
| `bin/k8s-gpu` | GPU Operator: device plugin (default) or `--dra` |
| `bin/k8s-platform` | Storage (`local-path` + `nfs`) and monitoring |
| `bin/k8s-install-tools` | Install `kubectl` + `helm` into `~/.local/bin` (controller only) |
| `bin/k8s-preflight` | Check trays are safe to use; `--snapshot` captures the baseline |

## Pinned software

`versions.env` is the **single source of truth**; every script sources it and this table is
rendered from it. Never hardcode a version elsewhere. All values verified **2026-09-10**.

| Component | Version | Chart | Notes |
|---|---|---|---|
| k3s | `v1.36.4+k3s1` | — | Default provider |
| Kubernetes (kubeadm) | `v1.37.0` | — | Alternate provider, upstream latest stable |
| Helm | `v4.3.0` | — | Controller only |
| Cilium | `1.20.1` | `1.20.1` | CNI + kube-proxy replacement; geneve tunnel; LB-IPAM disabled |
| NVIDIA GPU Operator | `v26.7.0` | `v26.7.0` | Device plugin + GFD only; driver/toolkit/DCGM are host-provided |
| NVIDIA DRA driver | `v0.5.0` | bundled | **Path B only** — see [IMEX](#gpu-and-imex) |
| Argo CD | `v3.5.2` | `10.8.4` | GitOps |
| kube-prometheus-stack | operator `v0.93.1` | `90.0.0` | Bundled node-exporter **disabled** |
| csi-driver-nfs | `4.13.4` | `4.13.4` | `nfs` StorageClass (RWX) against `/fss`, NFSv3 |
| local-path-provisioner | `v0.0.37` | kustomize | Default StorageClass (RWO) on `/mnt/localdisk` |
| Kueue | `v0.19.4` | — | Gang scheduling for multi-node jobs |
| Headlamp | `0.45.0` | `0.45.0` | Optional cluster UI |

### Host-provided, never managed by us

These ship on the nodes. We assert their presence and depend on them, but never install,
upgrade, or restart them.

| Component | Version on `polite-possum` |
|---|---|
| NVIDIA driver | `595.71.05` (CUDA 13.2) |
| nvidia-container-toolkit | `1.20.0` |
| `nvidia-imex` | active; per-rack domain, fabric `State=Completed` |
| `nvidia-dcgm` / nv-hostengine | active on `127.0.0.1:5555` |
| Exporters | `:9100` node, `:9400` dcgm, `:9500` rdma, `:9600` nvlink, `:9700` pcie (verified via `/metrics`; `:9876` is a file server, not an exporter) |
| containerd / docker / enroot+pyxis | host-managed — **k3s brings its own containerd** |

### Deliberately not used

- **ingress-nginx** — archived 2026-03-24; no releases, bugfixes, or security updates.
  Upstream directs new users to a Gateway API implementation. We use Cilium's Gateway API,
  which adds no new component.
- **MetalLB / Cilium LB-IPAM / L2 announcements** — would squat on IPs in a managed subnet
  that is not ours. Use NodePort + `kubectl port-forward`.

## Considering an upgrade?

1. Run `bin/k8s-check-upgrades`. It compares `versions.env` to upstream stable and **filters
   pre-releases** — chart indexes routinely surface `rc`/`pre` tags as "latest" (ArtifactHub
   was offering Cilium `1.21.0-pre.2` while stable was `1.20.1`).
2. Bump the value in `versions.env` only.
3. Test it through a GitOps overlay (`gitops/overlays/scratch/`) before `full/`. That is the
   whole reason the overlays exist.
4. Constraints to respect:
   - Everything is **aarch64**. Confirm a `linux/arm64` image exists — a missing one is the
     likeliest cause of a first-run `ImagePullBackOff`.
   - Keep `kubectl` within one minor of the server.
   - k3s tracks one minor behind upstream. Kubernetes minor EOLs: 1.37 → 2027-10-28,
     1.36 → 2027-06-28, 1.35 → 2027-02-28, 1.34 → 2026-10-27.
   - NVIDIA DRA driver requires driver ≥ 580 and CDI in the runtime.

## Storage

| Class | Modes | Backed by | Use for |
|---|---|---|---|
| `local-path` (default) | RWO | `/mnt/localdisk` — 28 TB NVMe | scratch, checkpoints, Prometheus data |
| `nfs` | **RWX** | `/fss` over NFSv3 | datasets, weights, anything multi-node |

`local-path` is deployed from the pinned upstream manifest via kustomize rather than k3s's
bundled `local-storage` addon, so GitOps can own it and it transfers to a kubeadm cluster
unchanged. Upstream defaults to `/opt/local-path-provisioner` on the node root filesystem
(~85 GB free); the overlay repoints it at the NVMe.

It is node-local: a pod that moves nodes loses the data. Multi-node work must use `nfs`.

Every NFS volume is provisioned under `/fss/<prefix>/<cluster>/`, never at the share root —
`/fss` holds other people's data. `bin/k8s-down` removes that subtree, since a hard teardown
skips the PVC deletion that would normally clean it.

## Monitoring

kube-prometheus-stack with **no node-exporter and no dcgm-exporter of our own** — the hosts
run those already and the chart's versions collide on their hostPorts. Prometheus scrapes
the host endpoints instead, which also picks up the provider's rdma/nvlink/pcie counters.

Port assignments were **verified by curling `/metrics`**, not inferred from process names:

| Port | Exporter |
|---|---|
| `:9100` | node_exporter |
| `:9400` | dcgm-exporter |
| `:9500` | `rdma_counters_exporter.py` |
| `:9600` | `nvlink_counters_exporter.py` |
| `:9700` | `pcie_faults_exporter.py` |
| `:9876` | **not an exporter** — healthcheck file server, `/metrics` returns 404 |

Also disabled: `kubeControllerManager`, `kubeScheduler`, `kubeEtcd` (k3s runs them in one
process with no separate Services) and `kubeProxy` (Cilium replaces it). Left on, they only
produce permanently-down targets and false alerts.

Grafana and Prometheus are reached with `kubectl port-forward` — no ingress, no LoadBalancer.

## GPU and IMEX

A rack is 18 trays and **one NVL72 NVLink domain with one `CliqueId`**. Multi-node NVLink
works only *within* a rack, so multi-node jobs must be pinned to one rack.

NVIDIA's blessed multi-node-NVLink path (GPU Operator DRA + `ComputeDomain`) requires masking
the host's provider-managed `nvidia-imex.service`. That conflicts with do-no-harm, so:

- **Path A (default)** — host IMEX untouched. The device plugin exposes `nvidia.com/gpu` and
  GFD publishes `nvidia.com/gpu.clique`. Pods needing multi-node NVLink get
  `/dev/nvidia-caps-imex-channels/channel0` injected via our own additive CDI spec.
- **Path B (opt-in, worth it at 2+ racks)** — DRA `ComputeDomain`, via guarded scripts that
  snapshot and restore IMEX state, giving per-job domain scoping.

Path A rests on one assumption — that NCCL works inside a pod against a host-managed IMEX
domain. `workloads/plumbing/` contains a 2-node nccl-tests gate that validates it. **Do not
build training on Path A until that gate passes.**

## Repository layout

| Path | What it is |
|---|---|
| `versions.env` | Single source of truth for versions |
| `clusters/*.env` | Per-cluster settings; copy one to onboard a new cluster |
| `bin/` | Operator entrypoints — the only things you run directly |
| `lib/` | Shared shell: `common.sh`, `slurm.sh`, `preflight.sh` |
| `providers/` | `k3s.sh` (default), `kubeadm.sh` |
| `node/` | Scripts that run *on* leased nodes via ssh/clush |
| `slurm/` | Placeholder-lease sbatch scripts |
| `platform/` | Helm values, applied at bootstrap then adopted by GitOps |
| `gitops/` | Argo CD bootstrap, app-of-apps, kustomize overlays |
| `workloads/` | Phased tests: plumbing → training → inference |
| `tests/` | Unit tests (`tests/test-drift-classify.sh`) |
| `docs/PLAN.md` | Design of record |
| `CLAUDE.md` | Operational rules for agents working in this repo |
