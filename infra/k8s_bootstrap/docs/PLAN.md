# Design: ephemeral Kubernetes on a borrowed Slurm GB300 cluster

> Status: approved 2026-09-10. This is the design of record; `CLAUDE.md` is the
> short operational rule set derived from it. All findings below were verified
> against the live `polite-possum` cluster and upstream release channels on that date.

## Context

We frequently get temporary access to Slurm-managed GPU clusters but need Kubernetes to do
our work. This repo makes it a one-command operation to carve racks out of a borrowed Slurm
cluster, stand up a real Kubernetes cluster on them (control plane + GPU data plane, GPU
Operator, CNI, monitoring, GitOps), scale it a rack at a time, and tear it down leaving the
nodes **pristine** — so the same repo is reusable on the next borrowed cluster.

**The overriding constraint is do-no-harm.** The Slurm cluster is shared with other people
and is not ours. Kubernetes must run *adjacent to* Slurm, never reconfiguring it. Co-scheduling
contention is accepted; collateral damage is not. Every design decision below that looks
conservative is downstream of that.

Confirmed decisions:
- **Distro:** k3s v1.36.4+k3s1 (default), kubeadm v1.37.0 behind a pluggable provider layer.
- **Control plane:** a dedicated borrowed tray (tray 0 of rack 1), tainted `NoSchedule`. Nothing
  installed on the shared Slurm controller except `kubectl` + a kubeconfig.
- **Scaling unit:** a rack. First bring-up = 1 CP + 3 workers → grow to full rack → add rack 2.
- **Git remote:** `https://github.com/dkennetzoracle/k8s_bootstrap.git`
- **Lifetime:** days. Scratch cluster, no HA etcd.
- **Phases:** plumbing → training → inference.

## Environment discovered (`polite-possum`)

| Fact | Value |
|---|---|
| Controller | `polite-possum-controller`, 172.16.0.182/24, Ubuntu 24.04, aarch64, kernel 6.14, 991 GB root |
| Node shape | `BM.GPU.GB300.4` — 4× GB300, 144 cores, 956 GB RAM, **root fs only 123 GB (85 GB free)** |
| Node local NVMe | `/mnt/localdisk` — 28 TB XFS RAID0 ← **all k3s/container storage goes here** |
| Rack | 18 trays = one NVL72 NVLink domain; `CliqueId` per rack (e.g. 388), fabric `State=Completed` |
| Node naming | `GPU-<localblock>-<rack>-<tray 0..17>`; DNS resolves live nodes via `polite-possum.local` |
| Usable localblocks | <7 idle racks: `233qa`, `edaya`, `a6tiq`, `gz7lq`, `tboia`, `ez4wq`, `q4mra`, `3asma` (avoid `vk73q`, `5y7uq`) |
| Access | SSH by hostname from controller, **passwordless sudo** everywhere, `clush`/`pdsh` installed |
| Shared FS | NFS `/home`, `/config`, `/fss` on every node |
| Preinstalled | driver **595.71.05** / CUDA 13.2, nvidia-container-toolkit 1.20.0, containerd, docker, enroot+pyxis |
| Provider daemons | `nvidia-imex` (active, `/dev/nvidia-caps-imex-channels/channel0`), `nvidia-dcgm` (:5555), `dcgm-exporter` **:9400**, node_exporter **:9100**, custom exporters **:9500/:9600/:9700** (rdma, nvlink, pcie -- verified via `/metrics`; **:9876** is a healthcheck file server, not an exporter), `slapd` :389, `slurmd` :6818 |
| Ports free | 6443, 10250, 10256-10259, 2379-2380, 8472, 4240-4245, 9962, 10010 |
| CIDR-safe | node net `172.16.0.0/12`-ish, `docker0` `172.17.0.0/16`, **no `10.x` routes** → `10.42.0.0/16` pod / `10.43.0.0/16` svc free |
| Node prereqs | swap off ✅, cgroup v2 ✅, `ip_forward=1` ✅, `br_netfilter` not loaded (k3s loads it), iptables policy ACCEPT, **40 host rules, zero `KUBE-`/`CNI-`/flannel** |
| CNI state | `/var/lib/cni` and `/etc/cni/net.d` **do not exist** → nothing else on the node uses CNI |
| Host CDI | `/var/run/cdi/nvidia.yaml` (31 KB, `kind: nvidia.com/gpu`, cdiVersion 0.7.0) |
| Networking | `eth0` (mgmt), 4 rails × 4 ports `rdma_pN_railM`, SR-IOV VFs `rdma_vf_railN` with IPv6 GUAs, OVS-DOCA, mlx5 |
| Slurm | 1053 nodes, `select/cons_tres`, `Prolog=healthchecks.sh`, `HealthCheckInterval=300`, `HealthCheckNodeState=IDLE,CYCLE` |
| Existing reservation | `InitialValidation`, user `ubuntu`, 364 nodes, `SPEC_NODES`, until 2027-09-07 (we will **not** use all of it) |

### Three decisive environment facts

1. **Hold nodes with a real Slurm job, never a reservation.** `HealthCheckNodeState=IDLE,CYCLE`
   means the OCI healthcheck (`check_gpu_setup.py` → `dcgmi health check`, NVLink probes) fires
   every 300 s on *idle* nodes and can `drain` them. Nodes held by a running job are `ALLOCATED`
   and skipped. A placeholder job is both the lease and the shield — and it makes our usage
   visible and legitimate to Slurm accounting, which is exactly "adjacent, not interfering".
2. **Host root fs is only 85 GB free.** NGC training images are 20+ GB. k3s must use
   `--data-dir=/mnt/localdisk/k3s`.
3. **The host already exports every metric we'd otherwise deploy.** kube-prometheus-stack's
   node-exporter (hostPort 9100) and GPU Operator's dcgm-exporter (9400) would **collide** with
   provider daemons. Scrape the host exporters instead — less footprint *and* better data
   (we get the provider's nvlink/pcie/rdma/nccl exporters for free).

## Why k3s (the "trimmed down" question, verified from source)

k3s removes exactly two things vs upstream: in-tree storage drivers (→ CSI) and the in-tree
cloud provider (→ CCM) — both things upstream is removing anyway. Control-plane components are
the same upstream code in one process. It is CNCF-conformance certified. DRA is **GA as of k8s
1.34** with `resource.k8s.io/v1` on by default, so it is present in 1.36.4.

What actually decided it is do-no-harm:

| Concern | k3s | kubeadm |
|---|---|---|
| Host containerd/docker config | **untouched** — own embedded containerd, own socket & state dir | rewrites `/etc/containerd/config.toml`, the containerd enroot/pyxis users share |
| Uninstall | one generated `k3s-agent-uninstall.sh`, upstream-maintained | `kubeadm reset` explicitly does *not* clean CNI conf, CNI links, iptables/IPVS |
| Package footprint | single binary, no apt | apt-installs kubelet/kubeadm/kubectl into a shared image |
| Kills other users' containers? | **No** — `getshims()` matches only `${K3S_DATA_DIR}/data/*/bin/containerd-shim` | n/a |

Verified `k3s-killall.sh` scoping: unmounts only `/run/k3s`, `/var/lib/kubelet/pods`,
`/var/lib/kubelet/plugins`, `/run/netns/cni-`; `iptables-save | grep -v KUBE- | grep -v CNI- |
grep -iv flannel | iptables-restore` preserves host rules.

Residual k3s risks, all mitigated: version lag (1.36 patched to 2027-06-28); opinionated defaults
(we disable them explicitly); non-standard containerd socket (irrelevant — we disable the
Operator's toolkit since the host's is preinstalled).

### Release timing (verified 2026-09-10)

| k8s minor | latest | EOL | k3s channel |
|---|---|---|---|
| 1.37 | 1.37.0 (2026-08-26) | 2027-10-28 | **none yet** |
| 1.36 | 1.36.4 | 2027-06-28 | `v1.36` → v1.36.4+k3s1 |
| 1.35 | 1.35.8 | 2027-02-28 | `v1.35` → v1.35.8+k3s1 |

## The IMEX / multi-node NVLink tension — the key design call

NVIDIA's GPU Operator v26.7.0 DRA docs (DRA driver v0.5.0, `draDriver.computeDomains.enabled`)
require, for a pre-installed driver:

```
systemctl disable --now nvidia-imex.service && systemctl mask nvidia-imex.service
```

That mutates a **provider-managed** daemon that is currently what gives Slurm users multi-node
NVLink. It directly contradicts do-no-harm. Separately, I verified the host CDI spec exposes the
IMEX *binaries* but **not** `/dev/nvidia-caps-imex-channels/channel0`, so pods do not get
multi-node NVLink for free either.

**Decision: two paths, default to the safe one.**

- **Path A — host IMEX preserved (default, phases 1–2).** Leave `nvidia-imex.service` completely
  alone. Legacy device plugin exposes `nvidia.com/gpu`; GFD still publishes
  `nvidia.com/gpu.clique`. Pods needing multi-node NVLink get `channel0` injected explicitly via
  a small additive CDI spec of our own (`kind: nvidia.com/imex-channel`, written to a separate
  file — never editing the host's `nvidia.yaml`). Zero host mutation, trivially reversible.
- **Path B — DRA ComputeDomain (opt-in, phase 2.5).** Only via an explicit, guarded script that
  snapshots IMEX unit state, masks it, and restores it (`unmask` + `enable --now` + fabric
  re-verify) on teardown. Worth it at **2+ racks**, where per-job domain scoping is the real
  payoff. Never the default.

Path A's assumption — that NCCL works inside a pod against a host-managed IMEX domain — is the
single biggest thing to validate in phase 1, and the plan below makes it an explicit gate.

## Repository layout

```
k8s_bootstrap/
├── README.md               # tools, pinned versions, upgrade guidance (item 7)
├── QUICKSTART.md           # copy-paste bring-up (item 8)
├── CLAUDE.md               # agent rules: safety invariants, never-do list
├── versions.env            # SINGLE SOURCE OF TRUTH for every version
├── clusters/
│   └── polite-possum.env   # per-cluster: localblock, rack, CIDRs, sizes, paths
├── bin/                    # operator entrypoints
│   ├── k8s-up              # lease CP + N workers, install, bootstrap platform
│   ├── k8s-add-rack        # lease a rack, join 18 agents
│   ├── k8s-remove-rack     # cordon/drain, uninstall, release lease
│   ├── k8s-down            # full teardown
│   ├── k8s-status          # k8s + Slurm lease state side by side
│   ├── k8s-verify-clean    # diff node state vs pre-install snapshot
│   └── k8s-check-upgrades  # query upstream for newer versions vs versions.env
├── lib/{common,slurm,preflight}.sh
├── providers/{k3s,kubeadm}.sh
├── node/                   # run ON nodes via ssh/clush
│   ├── snapshot.sh         # iptables, CDI, IMEX unit, systemd, mounts
│   ├── install-server.sh  install-agent.sh
│   ├── teardown.sh         # k3s uninstall + Cilium + CDI/IMEX restore
│   └── imex-{mask,restore}.sh
├── slurm/{lease-controlplane,lease-rack}.sbatch
├── platform/               # helm values (bootstrap now, GitOps-managed after)
│   ├── cilium/ gpu-operator/ kube-prometheus-stack/ storage/ argocd/
├── gitops/
│   ├── bootstrap/          # argocd install + root app-of-apps
│   ├── apps/               # child Applications
│   └── overlays/{scratch,full}/
└── workloads/{plumbing,training,inference}/
```

## Implementation steps

### Step 1 — Repo, docs, safety rails
- `git init`, remote `https://github.com/dkennetzoracle/k8s_bootstrap.git` (repo must be created
  on GitHub first; `gh` is not installed here). Branch `main`.
- `versions.env` as the machine-readable source of truth, sourced by every script and rendered
  into `README.md`. Pin: k3s `v1.36.4+k3s1`, k8s `v1.37.0` (kubeadm provider), helm `v4.3.0`,
  cilium `v1.20.1`, gpu-operator `v26.7.0` (chart `nvidia/gpu-operator`, repo
  `https://helm.ngc.nvidia.com/nvidia`), nvidia DRA driver `v0.5.0`, argo-cd `v3.5.2`,
  kueue `v0.19.4`. Chart versions for kube-prometheus-stack / local-path / csi-driver-nfs to be
  resolved and pinned during this step (`helm search repo --versions`).
- `CLAUDE.md` encoding the safety invariants as a hard never-do list: never touch `/etc/slurm`,
  never modify host containerd/docker config, never `systemctl` a provider daemon outside
  `node/imex-*.sh`, never write to the host's `/var/run/cdi/nvidia.yaml`, never install into
  `/usr/local/bin` on a node, always snapshot before install, always `k8s-verify-clean` after
  teardown, never lease from `vk73q`/`5y7uq`, never use all of `InitialValidation`.
- `.claude/settings.json` allowlisting the read-only `sinfo`/`squeue`/`scontrol show`/`kubectl get`
  calls to cut permission prompts; skills for `cluster-status`, `add-rack`, `teardown-verify`.

### Step 2 — Slurm lease layer (`lib/slurm.sh`, `slurm/*.sbatch`)
- Rack-aware node selection: parse `GPU-<lb>-<rack>-<tray>`, filter to responsive `IDLE` nodes
  (exclude `NOT_RESPONDING`/`drained`), reject `vk73q`/`5y7uq`, group by rack.
- Two lease kinds: a long-walltime **control-plane lease** (1 tray) and per-rack **worker leases**,
  so racks come and go without disturbing the API server.
- Placeholder sbatch body: `--exclusive --gres=gpu:4`, write nodelist to a shared state dir,
  `sleep infinity`, and `trap` on `EXIT`/`TERM` running the node teardown across its own nodelist
  so **walltime expiry or `scancel` auto-cleans**. This is required because k3s runs under systemd
  outside the job cgroup and would otherwise survive the lease.
- State dir `/home/ubuntu/.local/state/k8s-bootstrap/<cluster>/` holds job IDs, nodelists,
  snapshots, kubeconfig, join token (mode 0600).

### Step 3 — Node preflight + snapshot (`lib/preflight.sh`, `node/snapshot.sh`)
Refuse to install unless, per node: `/var/lib/cni` and `/etc/cni/net.d` absent; no `KUBE-`/`CNI-`
rules in `iptables-save`; `/mnt/localdisk` mounted with headroom; swap off; cgroup v2; k8s ports
free; `nvidia-imex.service` active and fabric `State=Completed`. Snapshot to the state dir:
`iptables-save`/`ip6tables-save`, `systemctl is-enabled/is-active` for the nvidia units,
sha256 of `/var/run/cdi/nvidia.yaml`, `ip -br addr`, `/proc/self/mounts`, `ls /usr/local/bin`.

### Step 4 — k3s provider (`providers/k3s.sh`, `node/install-*.sh`)
Server (control-plane tray), tainted so no GPU work lands there:
```
--data-dir=/mnt/localdisk/k3s  --node-taint node-role.kubernetes.io/control-plane=:NoSchedule
--flannel-backend=none --disable-network-policy --disable-kube-proxy
--disable=traefik,servicelb,local-storage --disable-helm-controller
--cluster-cidr=10.42.0.0/16 --service-cidr=10.43.0.0/16
--tls-san=<cp-ip> --write-kubeconfig-mode=0600
```
Install with `INSTALL_K3S_BIN_DIR=/opt/k8s-bootstrap/bin` **and `INSTALL_K3S_SYMLINK=skip`** so
no `ctr`/`crictl`/`kubectl` symlink is ever created on a worker — verified from `install.sh`, and
its generated uninstaller cleans symlinks from a custom `BIN_DIR` correctly. Also set
`INSTALL_K3S_SYSTEMD_DIR` explicitly and `K3S_DATA_DIR=/mnt/localdisk/k3s` (data dir is a
`K3S_DATA_DIR` env var, not an `INSTALL_K3S_*` one) so the uninstaller removes the right tree.
Agents join by token over
`https://<cp>:6443`, labelled `k8s-bootstrap.io/{localblock,rack,tray}` and tainted per pool.
`kubectl` + kubeconfig land on the controller only.

### Step 5 — Networking (`platform/cilium/values.yaml`)
Cilium v1.20.1, `kubeProxyReplacement=true`, `k8sServiceHost/Port` pointing at the CP,
`routingMode=tunnel` + geneve (nodes sit in **different /19 subnets** — 172.16.0.0/24 vs
172.16.32.0/19 — so native routing would need fabric changes we must not make), Hubble on,
`prometheus.enabled` on ports 9962-9965 (verified free), `operator.replicas=1`, `ipam.mode=kubernetes`.
No MetalLB, no L2 announcements, no LB-IPAM: **we must not squat on IPs in someone else's managed
subnet.** Service exposure is NodePort + `kubectl port-forward`. For ingress, **`ingress-nginx` is
ruled out** — verified archived 2026-03-24 with no further releases, bugfixes or security updates,
and upstream explicitly directs new users to a Gateway API implementation instead. We use
**Cilium's Gateway API** when ingress is needed, which adds no new component.

### Step 6 — GPU layer (`platform/gpu-operator/values.yaml`) — Path A
```
driver.enabled=false            # host driver 595.71.05
toolkit.enabled=false           # host nvidia-container-toolkit 1.20.0
dcgm.enabled=false              # host nv-hostengine :5555
dcgmExporter.enabled=false      # host dcgm-exporter :9400 — would collide
nodeStatusExporter.enabled=false
migManager.enabled=false        # not using MIG on GB300
devicePlugin.enabled=true
gfd.enabled=true                # publishes nvidia.com/gpu.clique
cdi.enabled=true                # verify it does not rewrite host nvidia.yaml
draDriver.computeDomains.enabled=false   # Path A: host IMEX stays
```
v26.7.0 uses the newer `GPUCluster` CRD (`gpuCluster.deployCR=true`, `clusterPolicy.deployCR=false`).
Back up `/var/run/cdi/nvidia.yaml` before install and assert its sha256 unchanged after.
Add our own additive CDI spec for `channel0` as a separate file for multi-node NVLink pods.

### Step 7 — Storage & monitoring
- `local-path-provisioner` rooted at `/mnt/localdisk/local-path` as the default StorageClass;
  `csi-driver-nfs` (or nfs-subdir provisioner) against `/fss` for shared RWX. Versions pinned in step 1.
- kube-prometheus-stack with `nodeExporter.enabled=false` and `prometheus-node-exporter` disabled,
  plus `additionalScrapeConfigs`/ScrapeConfig targeting host `:9100`, `:9400`, `:9500`, `:9600`,
  `:9700`. Grafana via port-forward. Headlamp or k9s optional (arm64 to confirm).

### Step 8 — GitOps (`gitops/`)
Argo CD v3.5.2, bootstrapped by script once (`platform/argocd`), then a root app-of-apps that
adopts everything from step 5-7 so subsequent changes are git-driven. `repoURL` =
`https://github.com/dkennetzoracle/k8s_bootstrap.git`; private-repo credentials come from a
gitignored file outside the repo (`~/.config/k8s-bootstrap/github-token`) turned into a Secret by
the bootstrap script — never committed. Kustomize overlays `scratch/` (1 CP + 3 workers) and
`full/` (rack-scale) so version bumps are tested by changing an overlay, not by hand. Argo CD
must be bootstrapped **after** Cilium (it needs pod networking).

### Step 9 — Workloads, phased
- **plumbing:** GPU smoke test (`nvidia-smi` pod), cross-node pod-to-pod, then **2-node
  nccl-tests** — the gate that validates Path A. `/fss/dgxc/nccl-tests-2.30.7` already exists
  locally and can seed the image.
- **training:** Kueue v0.19.4 for gang scheduling; multi-node jobs pinned to one rack via
  `nvidia.com/gpu.clique` / our rack labels; `hostNetwork: true` + `/dev/infiniband` so NCCL uses
  the rails rather than the geneve overlay (Multus/SR-IOV deferred — not needed for hostNetwork).
- **inference:** deferred; Gateway API + autoscaling once training is proven.

### Step 10 — Teardown & proof (`node/teardown.sh`, `bin/k8s-verify-clean`)
Ordered: cordon/drain → `k3s-agent-uninstall.sh` → remove Cilium leftovers k3s does not know about
(`cilium_host`, `cilium_net`, `cilium_vxlan`, `/sys/fs/bpf/tc/globals/cilium_*`) → remove
`/mnt/localdisk/k3s` and `/opt/k8s-bootstrap` → restore CDI/IMEX state → `scancel`.
`k8s-verify-clean` then diffs every snapshot from step 3 and **fails loudly** on any drift, and
checks the node did not land in `drain`. This is the acceptance test for do-no-harm.

## Verification

1. `bin/k8s-status` on an empty cluster → reports no leases, no cluster.
2. Preflight dry-run against 4 candidate trays → passes, snapshots written.
3. `bin/k8s-up --cluster polite-possum --workers 3` → `kubectl get nodes` shows 1 CP +
   3 workers `Ready`; `kubectl get nodes -o json` shows `nvidia.com/gpu: 4` each (12 total) and a
   consistent `nvidia.com/gpu.clique`.
4. GPU smoke pod runs `nvidia-smi -L` → 4 GB300s. Cross-node pod ping over Cilium.
5. **Gate:** 2-node nccl-tests `all_reduce_perf` completes and reports plausible NVLink-domain
   bandwidth. If it does not, Path A is insufficient and we evaluate Path B before proceeding.
6. Prometheus targets include host `:9100`/`:9400`/`:9500`/`:9600`/`:9700`, all UP;
   no port conflicts; host dcgm-exporter still serving.
7. Argo CD syncs the root app to `Healthy`/`Synced`; change an overlay image tag, commit, push,
   observe the rollout.
8. `bin/k8s-add-rack` grows to the full rack, then a second rack; new nodes join `Ready` with
   correct rack labels and their own `CliqueId`.
9. `bin/k8s-down` → `bin/k8s-verify-clean` reports zero drift on every node; `sinfo` shows the
   nodes back to `idle`, not `drained`; host `nvidia-imex.service` active, fabric `Completed`;
   `sha256` of `/var/run/cdi/nvidia.yaml` unchanged; `/usr/local/bin` unchanged.
10. Independently: `scancel` a lease directly and confirm the sbatch trap auto-cleans that node.

## Pinned versions (`versions.env`, verified 2026-09-10)

| Component | Version | Chart | Repo |
|---|---|---|---|
| k3s (default provider) | `v1.36.4+k3s1` | — | `https://get.k3s.io` |
| Kubernetes (kubeadm provider) | `v1.37.0` | — | upstream |
| Helm | `v4.3.0` | — | — |
| Cilium | `1.20.1` | `cilium-1.20.1` | `https://helm.cilium.io` |
| NVIDIA GPU Operator | `v26.7.0` | `nvidia/gpu-operator` | `https://helm.ngc.nvidia.com/nvidia` |
| NVIDIA DRA driver (Path B only) | `v0.5.0` | bundled w/ operator | — |
| Argo CD | `v3.5.2` | `argo-cd` **10.8.4** | `https://argoproj.github.io/argo-helm` |
| kube-prometheus-stack | operator `v0.93.1` | **90.0.0** | `https://prometheus-community.github.io/helm-charts` |
| csi-driver-nfs | `4.13.4` | **4.13.4** | `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts` |
| local-path-provisioner | `v0.0.37` | **0.0.38** | Rancher |
| Kueue | `v0.19.4` | resolve at install | `https://github.com/kubernetes-sigs/kueue` |
| Headlamp (optional UI) | `0.45.0` | **0.45.0** | `https://kubernetes-sigs.github.io/headlamp` |

**Pin stable, not what ArtifactHub surfaces.** ArtifactHub currently offers Cilium
`1.21.0-pre.2`, a pre-release; the stable chart `cilium-1.20.1.tgz` is confirmed present in the
Cilium chart index and is what we pin. `bin/k8s-check-upgrades` must therefore filter
pre-release/rc tags rather than blindly taking "latest".

## Findings from implementation (step 4)

Two things discovered by running against live nodes, both now encoded in `CLAUDE.md`,
`lib/preflight.sh` and `lib/drift.sh`.

### Slurm node identity can be stale — the serious one

`NodeAddr` and cluster DNS both go stale on dynamic/cloud nodes. Two Slurm node records
pointed at one physical machine:

```
scontrol: GPU-edaya-k2ssq-8 -> 172.16.39.176
dns:      GPU-edaya-k2ssq-8 -> 172.16.39.176
ssh:      GPU-edaya-k2ssq-8 -> hostname = GPU-ez4wq-56l4q-10
```

k3s was installed on two machines never allocated to the job (one of them in an *excluded*
localblock). Nothing else was running on them, but the same slip could tear down another
user's cluster. It is **intermittent** — a later 40-tray sample showed zero mismatches —
which makes it more dangerous, not less.

Mitigation: `slurm_pick_verified_trays()` checks every candidate's `hostname` in parallel
and skips mismatches; `assert_node_identity()` guards install and teardown; preflight has a
blocking `identity` gate; and `node_ip()` now asks the node for its own address rather than
trusting `NodeAddr`, warning on disagreement.

### Kernel-level drift is classified, not removed

Teardown restores paths, units, interfaces, eBPF maps, firewall rules and
`nf_conntrack_max`. It deliberately does **not** unload the modules k3s loads:
`modprobe -r br_netfilter` cascades to `bridge` and destroys the host's `docker0`;
`iptable_*` cascades to `ip_tables`. Tried on a live node, it broke Docker and required
`modprobe bridge ip_tables`, a docker restart, `ip link set docker0 up` and a container run
to recover the IPv6 link-local — and the bridge came back with a different MAC.

So `lib/drift.sh` classifies exactly two consequences as benign (the three networking
modules, and the empty `*mangle` table plus `net.bridge` sysctl key they pull in) and fails
on everything else. The allowlist matches exact module names and an empty table, never
"this file changed".

### Networking findings (step 5)

- **k3s leaves the CNI paths at containerd's defaults.** The generated containerd config has
  no `[cni]` section at all with `--flannel-backend=none`, so `/opt/cni/bin` and
  `/etc/cni/net.d` apply — which are also Cilium's defaults. No k3s-specific override needed,
  contrary to the usual k3s+Cilium advice.
- **The `nvidia` runtime is auto-configured by k3s.** The containerd config already contains
  a `nvidia` runtime with `BinaryName = /usr/bin/nvidia-container-runtime`, and k3s creates
  the matching RuntimeClass. A pod with `runtimeClassName: nvidia` sees all 4 GB300s with no
  GPU Operator at all; the operator is only needed for the `nvidia.com/gpu` resource and GFD
  labels (step 6).
- **Cilium's `operator.tolerations` default is load-bearing.** Narrowing it to the
  control-plane taint deadlocks bootstrap: agents wait for the operator to register CRDs,
  while every node is NotReady and thus tainted `node.kubernetes.io/not-ready`.
- **The chart enables LB-IPAM by default.** Disabled explicitly so rule 9 is enforced.
- **Cilium leaves residue k3s's uninstaller does not know about**: `CILIUM_*` iptables
  chains, a cgroup2 mount at `/run/cilium/cgroupv2` (so `/run/cilium` is not itself a
  mountpoint and survives `rm -rf`), and `/opt/cni`. All handled now.
- **`/sys/fs/bpf` is root-only**, so the snapshot's eBPF check was recording an empty file in
  both phases and doing nothing. Now uses `sudo`.

### GPU + DRA findings (step 6)

Both stacks verified on live GB300 trays.

**Device plugin (default).** `nvidia.com/gpu: 4` advertised; a pod requesting 1 sees exactly
1 (gate 1, by contrast, sees all 4 because `runtimeClassName: nvidia` bypasses the
scheduler). Requesting 99 is correctly rejected with `Insufficient nvidia.com/gpu`. GFD
publishes `nvidia.com/gpu.clique=<ClusterUUID>.<CliqueId>` — observed `...-388`, matching
the CliqueId `nvidia-smi -q` reports, so the label really does identify the rack's NVLink
domain. No driver, toolkit, DCGM or dcgm-exporter DaemonSet is created, as intended.

**DRA (opt-in).** k3s v1.36.4 serves `resource.k8s.io/v1` with `deviceclasses`,
`resourceclaims`, `resourceclaimtemplates` and `resourceslices`. The NVIDIA DRA driver
v0.5.0 publishes DeviceClasses `gpu.nvidia.com`, `mig.nvidia.com`, `vfio.gpu.nvidia.com`
and one ResourceSlice per node listing `gpu-0..gpu-3`. A Job referencing a
ResourceClaimTemplate against `gpu.nvidia.com` got exactly one GB300, with
`NVIDIA_VISIBLE_DEVICES=void` confirming CDI injection rather than the legacy env path.

Crucially, **DRA for GPU allocation does not require Path B**: with
`draDriver.computeDomains.enabled=false`, `nvidia-imex` stayed `active`+`enabled`, the IMEX
channel remained, fabric stayed `Completed`, clique stayed 388, and the host CDI hash
matched the baseline on every tray. Using DRA is therefore a separate decision from
adopting Path B, which is only needed for multi-node NVLink ComputeDomains.

Three sharp edges found:
- Under DRA, `nvidia.com/gpu` *capacity* still reads 4 while *allocatable* is 0. Check
  allocatable; capacity is misleading.
- Switching stacks in place is unreliable — a stale operator cache reported a ClusterPolicy
  that no longer existed and pinned GPUCluster at `notReady`. Now handled by restarting the
  operator on a detected mode change.
- Both stacks leave generated CDI specs behind (`k8s.device-plugin.nvidia.com-gpu.json`,
  `k8s.gpu.nvidia.com-claim_*.yaml`), and the device-plugin one survived the switch to DRA.
- `helm template` cannot render the DRA stack offline without
  `--api-versions resource.k8s.io/v1/DeviceClass`; the chart refuses rather than guessing.

### One unexplained node loss (step 6), and how it was attributed

On a step-6 teardown, tray `GPU-ez4wq-bi4ua-1` reported residue and then went unreachable,
sitting in Slurm `comp*` with its lease job stuck `COMPLETING`. `bin/k8s-verify-clean`
correctly reported it `UNVERIFIED` and exited nonzero rather than calling it clean.

Timeline, from `scontrol show node` and file mtimes:

```
17:51:31  GPU mode round trip finished (last helm operation)
17:51:53  slurmd RESTARTED on the tray          <-- ~90s BEFORE teardown began
17:52     bin/k8s-down started
17:53:27  bin/k8s-down finished
16:10:43  BootTime, unchanged: the machine never rebooted
```

The initiating event precedes our teardown, nothing in this repo restarts `slurmd`, the
other tray in the same run verified pristine, and six other trays from the session stayed
`idle` and healthy. The lease log ends at `holding trays` with no `releasing` line, so the
sbatch trap never ran — consistent with Slurm being unable to finish the epilog against an
unresponsive slurmd rather than with damage from cleanup.

Two durable improvements came out of it: per-node teardown logs in
`$STATE_DIR/teardown-logs/` (there was none for this incident, which is why the timeline had
to be reconstructed from mtimes), and `_path_is_safe()` in `node/teardown.sh` — a guard
found while auditing that code, since teardown runs as root and unmounts by prefix match, so
an empty `K3S_DATA_DIR` would have expanded to `/`.

### Correction: the "transient" preflight failures were a bug (step 7)

During steps 5-6 `bin/k8s-preflight` intermittently reported "could not select N
identity-verified idle tray(s)" while `bin/k8s-status` showed 60+ free trays, and calling
`slurm_pick_verified_trays` directly appeared to work. That was written off at the time as
transient node reachability. It was not.

`lib/common.sh` sets `-e`, and the parallel identity check had two bare assignments from
commands that can fail. When a candidate rack contained unreachable nodes, the background
subshell's `h="$(node_ssh_ro ...)"` failed, so the subshell died *before* its `printf` and
never wrote its result file; the read-back loop's `h="$(cat "$file")"` then failed and
aborted `slurm_pick_verified_trays` outright. The function returned nothing, printed none of
its own warnings, and the caller's guard reported an empty selection.

It was deterministic, not transient: it fired whenever the first-ranked rack contained dead
nodes, which tightest-fit ranking makes likely rather than rare. `node_ip()` had the same
shape, silently making its NodeAddr fallback unreachable.

Both fixed with `|| true` plus explicit emptiness checks; the pattern and its `bash -x`
signature are documented in CLAUDE.md under bash traps.

### Correction: the host exporter port mapping was wrong (step 7)

The environment survey recorded `:9500`/`:9600`/`:9700`/`:9876` as nvlink / pcie / rdma /
nccl exporters. Three of those four labels were wrong. Verified by curling `/metrics` on a
live node and reading the actual metric names:

| Port | Process | Metrics | Survey had said |
|---|---|---|---|
| `:9100` | node_exporter | — | node ✓ |
| `:9400` | dcgm-exporter | — | dcgm ✓ |
| `:9500` | `rdma_counters_exporter.py` | `rdma_packet_seq_err` | nvlink ✗ |
| `:9600` | `nvlink_counters_exporter.py` | `nvlink_data_tx_kib_total` | pcie ✗ |
| `:9700` | `pcie_faults_exporter.py` | `pcie_aer_correctable_error_count` | rdma ✗ |
| `:9876` | `http_server.py` | **none** — `/metrics` is 404, `text/html` | nccl ✗ |

The mapping had been inferred by correlating `ls /usr/local/bin` against a list of listening
ports, which produced a rotated guess; and `:9876` is a plain directory-listing file server
for the healthcheck logs, not an exporter at all. It is now excluded from
`HOST_SCRAPE_PORTS`, since scraping it only yields a permanently-down target.

The lesson, now noted at the config itself: never infer what a port serves from process
names. Curl `/metrics` and read the metric names.

### The NCCL gate: why PyTorch instead of nccl-tests

`/fss/dgxc/nccl-tests-2.30.7/build/all_reduce_perf` already exists, prebuilt for aarch64,
and reusing it was the obvious first choice. `ldd` settles it against:

```
libmpi.so.40 => /usr/mpi/gcc/openmpi-4.1.9a1/lib/libmpi.so.40
libnccl.so.2 => /lib/aarch64-linux-gnu/libnccl.so.2
libcudart.so.13 => /usr/local/cuda/targets/sbsa-linux/lib/libcudart.so.13
```

It is an MPI binary, and `mpirun` needs a launcher that can reach both ranks -- ssh between
pods, which in Kubernetes means the MPI Operator or ssh sidecars. That is a whole extra
component to introduce for a yes/no question.

`torch.distributed` drives the **same NCCL library**, bootstraps over TCP through the pod
network, and then lets NCCL choose its own transport for the data. `NCCL_DEBUG=INFO` reports
which transport it picked, which is precisely what this gate has to establish. No operator,
no ssh, and the collective being measured is identical.

The gate is `workloads/plumbing/07-nccl-2node.yaml`. Two properties make it a genuine
two-node test rather than an accidental single-node pass:

- an Indexed Job (`completions: 2`) gives each pod a distinct rank via
  `JOB_COMPLETION_INDEX`, and Kubernetes sets the hostname to `<job>-<index>` when
  `subdomain` is set, so rank 0 is addressable for the rendezvous;
- **hard** `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity on
  `kubernetes.io/hostname`, so the two ranks cannot land on the same node.

It runs `hostNetwork: true` with `/dev/infiniband` mounted so NCCL has the RDMA rails
available rather than being confined to the geneve overlay, and it mounts
`/dev/nvidia-caps-imex-channels` because the host CDI spec exposes the nvidia-imex
*binaries* but not that device node -- without it a pod cannot join the host's multi-node
NVLink domain at all.

### Gate result: Path A works, and what it took (step 9, gate only)

**Passed** on two trays of rack `bi4ua`, non-privileged: 544 GB/s bus bandwidth over
`P2P/MNNVL`, `correct=True`, against the host-managed IMEX domain with `nvidia-imex.service`
untouched. Training can be built on Path A; Path B is not needed for intra-rack work.

Getting there took four iterations, and each failure was informative:

| Attempt | Result | Lesson |
|---|---|---|
| `hostPath` mount of the channel dir | `MNNVL is available but not working` | cgroup v2 denies `open()`; a bind mount does not authorize a char device |
| `NVIDIA_IMEX_CHANNELS=0` | channel dir empty | CDI mode (`cdi.enabled=true`) bypasses the legacy env-var hook entirely |
| `privileged: true` | **worked**, 544 GB/s | proved the channel was fine and only authorization was missing |
| CDI spec + annotation allowlist | **worked, non-privileged** | the committed form |

The final mechanism needs three things, none of them default:

1. `node/install-imex-cdi.sh` writes an additive CDI spec for the channel.
2. `node/install-containerd-cdi-annotations.sh` allowlists `cdi.k8s.io/*` in **k3s's**
   containerd, because containerd does not forward annotations to the OCI runtime otherwise
   — this was the non-obvious one, and without it the annotation is silently ignored even
   though the nvidia runtime is configured to honour that prefix.
3. The pod carries `cdi.k8s.io/imex: "nvidia.com/imex-channel=all"`.

`provider_enable_imex_access()` applies 1 and 2 right after agents join.

Two of my own bugs were found on the way, both of which would have produced a wrong verdict:

- The correctness check compared `x == world_size` **after** 25 in-place summing
  all-reduces, so `x` held 2²⁵. A fully working MNNVL run at 544 GB/s reported
  `correct=False` and failed the gate. Validation now runs on a fresh tensor.
- The embedded Python relied on a `sed` to strip 14 leading spaces, but YAML block scalars
  already dedent — the body had 0/4/22-space lines. The gate now **compiles the extracted
  Python** as part of validation instead of assuming it looks right.

The gate also asserts the *transport*, not just success: it requires `via P2P/MNNVL` and
`MNNVL 1` in the NCCL log. Without that it would pass on a silent `NET/Socket` fallback,
which "works" at a small fraction of NVLink bandwidth and proves nothing.

RDMA remains unproven and is deliberately out of scope here: `/dev/infiniband` char devices
have the same cgroup problem, so `ibv_open_device` fails on all of them. Intra-rack NCCL
does not need RDMA. Cross-rack would, and needs the RDMA device plugin or NVIDIA Network
Operator.

### Full-scale NCCL (4 GPUs x 2 trays)

`workloads/plumbing/08-nccl-4x4.yaml` runs 8 ranks — `torchrun --nproc_per_node=4` on each
of two pods — so intra-node NVLink and cross-node MNNVL are exercised together in one
communicator.

| | ranks | busbw | transport |
|---|---|---|---|
| gate 07 | 2 (1 GPU/pod) | 544 GB/s | `P2P/MNNVL`, 0 socket |
| gate 08 | 8 (4 GPUs/pod) | **697 GB/s** | `P2P/MNNVL` x128 channels, 0 socket |

The structural result matters more than the number: NCCL reports `nRanks 8 nNodes 1
localRanks 8 MNNVL 1`. Two trays in one clique collapse into a **single logical node**, so
an 8-GPU collective spanning two machines is handled like an 8-GPU single-box job. This is
the concrete reason intra-rack training needs no RDMA.

Note `/dev/shm` is raised to 32Gi. The 64MiB default starves NCCL's intra-node shared-memory
transport once there are 4 local ranks.

One more test bug worth recording, because it is a trap specific to multi-process jobs: the
first run asserted `grep -c "correct=True" == 8` in node_rank 0's log. Each pod's `torchrun`
only captures the stdout of **its own** four ranks, so that count tops out at 4 and can never
pass — it failed a run where all 8 ranks were correct at 697 GB/s. Rank 0 now
`all_gather_object`s every rank's verdict and prints one authoritative `VALIDATION` line,
which is what the gate asserts on. Do not assert on per-pod stdout in a multi-pod job.

### Scope change

`node/teardown.sh` and `bin/k8s-verify-clean` were pulled forward from step 10 into step 4:
clean teardown cannot be proven without them, and install/uninstall have to be developed
together. `#SBATCH --requeue` was also removed from the lease — a requeued lease re-runs
while the cluster still believes it owns the original trays.

## Open items to resolve during implementation

- Confirm GPU Operator `cdi.enabled=true` does not rewrite the host `/var/run/cdi/nvidia.yaml`
  (assert via sha256 before/after — already built into step 6).
- Resolve exact chart versions for `nvidia/gpu-operator` and Kueue via `helm search repo
  --versions` once Helm is installed (ArtifactHub had no usable entry for either).
- Confirm linux/arm64 images for Argo CD, kube-prometheus-stack components, Kueue and Headlamp
  before first apply — everything on these nodes is aarch64, so a missing arm64 image is the most
  likely cause of a first-run `ImagePullBackOff`.
- Validate Path A's core assumption (NCCL over host-managed IMEX from inside a pod) at the
  step-9 gate before committing to it for training.
