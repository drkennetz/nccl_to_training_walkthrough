# CLAUDE.md — k8s_bootstrap

Bootstraps a **scratch Kubernetes cluster on top of a borrowed Slurm GPU cluster**.
Read `docs/PLAN.md` for the full design and the reasoning behind every choice below.

## The one rule that matters

**Do no harm to the Slurm cluster.** It is shared with other people and it is not ours.
Kubernetes runs *adjacent to* Slurm, never reconfiguring it. Co-scheduling contention is
accepted and expected; collateral damage is not.

When a choice trades cleanliness against capability, **pick cleanliness** and make the
capable option explicitly opt-in. Nearly every design decision in this repo is downstream
of that sentence.

## Never do these

Treat this as a hard list. If a task seems to require one of these, stop and ask.

1. **Never touch a node without confirming its identity first.** Slurm's `NodeAddr` and
   cluster DNS can both be **stale** on dynamic/cloud nodes: addresses get recycled and two
   Slurm node records can point at the same physical machine. This was observed live —
   `GPU-edaya-k2ssq-8` and `GPU-ez4wq-56l4q-10` resolved to one host, and k3s got installed
   on a machine that was never allocated to us. Always go through
   `assert_node_identity()` / `slurm_pick_verified_trays()`, which compare the machine's own
   `hostname` to the Slurm name. The mismatch is **intermittent**, which makes it more
   dangerous, not less.
2. **Never modify anything under `/etc/slurm`**, or any Slurm daemon, prolog, epilog, or
   config. Do not create Slurm reservations.
3. **Never modify the host container runtime.** Do not touch `/etc/containerd/config.toml`,
   `/etc/docker/daemon.json`, or restart `containerd`/`docker`. Slurm users share these via
   enroot/pyxis. k3s brings its own containerd; that is the entire point.
4. **Never `systemctl` a provider-managed daemon** — `nvidia-imex`, `nvidia-dcgm`,
   `dcgm-exporter`, `nvidia-persistenced`, `slurmd` — outside `node/imex-mask.sh` /
   `node/imex-restore.sh`, which exist only for the opt-in Path B and always snapshot first.
5. **Never write to the host's `/var/run/cdi/nvidia.yaml`.** It is host-generated. Add our
   own CDI specs as separate files. Its sha256 must be unchanged after teardown.
6. **Never install into `/usr/local/bin` on a node.** It precedes `/usr/bin` in PATH, so a
   k3s `ctr`/`crictl` symlink there would shadow the host's containerd tooling for every
   other user. Use `INSTALL_K3S_BIN_DIR=/opt/k8s-bootstrap/bin` and `INSTALL_K3S_SYMLINK=skip`.
7. **Never put container or cluster state on the node root filesystem.** It is ~123 GB with
   ~85 GB free and NGC images are 20+ GB each. Everything goes under `/mnt/localdisk`.
8. **Never lease nodes from localblocks with 7+ racks** (`vk73q`, `5y7uq` on `polite-possum`),
   and never lease the whole `InitialValidation` reservation. Leave big blocks for big jobs.
9. **Never assign a LoadBalancer IP or run MetalLB / L2 announcements / LB-IPAM.** Squatting
   on unassigned IPs in someone else's managed subnet is not ours to do. NodePort +
   `kubectl port-forward` only.
10. **Never install anything on the Slurm controller** except `kubectl`, `helm`, and a
   kubeconfig. No daemons, no systemd units. The control plane lives on a leased tray.
11. **Never hardcode a version.** Everything comes from `versions.env`.
12. **Never pin a pre-release.** Chart indexes surface `rc`/`pre` tags as "latest".

## Always do these

- **Snapshot before installing** on any node (`node/snapshot.sh`), and **verify after
  teardown** (`bin/k8s-verify-clean`). Zero drift is the acceptance test for do-no-harm.
- **Hold nodes with a real Slurm placeholder job**, never a reservation. Nodes held by a
  running job are `ALLOCATED`, which shields them from the OCI healthcheck that drains
  *idle* nodes every 300 s (`HealthCheckNodeState=IDLE,CYCLE`). It also makes our usage
  visible and legitimate to Slurm accounting.
- **Keep racks intact as the scaling unit.** 18 trays = one rack = one NVL72 NVLink domain =
  one `CliqueId`. Multi-node NVLink only works *within* a rack, so a multi-node job must be
  pinned to one rack.
- **Scrape the host exporters, do not deploy your own.** Hosts already serve `:9100` (node),
  `:9400` (dcgm), `:9500`/`:9600`/`:9700` (rdma, nvlink, pcie counters). Deploying
  kube-prometheus-stack's node-exporter or the GPU Operator's dcgm-exporter would collide on
  hostPorts and is strictly worse data.
- **Know the arch of the cluster you are on.** polite-possum (GB300) is aarch64 -- a missing
  `linux/arm64` image is the most likely first-run `ImagePullBackOff`; nearby-woodcock (B300)
  is x86_64. `EXPECTED_ARCH` in the cluster env says which; check images before adding a chart.

## Working method

Work in **numbered steps** from `docs/PLAN.md`. For each step:

1. **Author** the step's files.
2. **Test that it actually works** before claiming it does — see below.
3. **Commit** only after the tests pass, with a message explaining *why*, not just what.
4. **Push** the commit.
5. **Stop and report.** Summarize what changed and what the next step would do, then wait
   for review. Do not chain steps together, even when the next one looks mechanical.

Never commit or push a step whose tests fail or that you have not exercised. If something
cannot be tested yet because it depends on a later step, say so explicitly in the report
rather than implying it was verified.

### How to test each kind of thing

| Thing | Minimum bar before committing |
|---|---|
| Shell library | `bash -n`, then source it and call the real functions with real inputs |
| Node selection / Slurm queries | Run against the **live cluster** — read-only, so always safe |
| Anything that mutates state | Full `DRY_RUN=1` trace, and confirm the printed plan is right |
| `bin/` entrypoint | Run it for real if read-only; `--dry-run` if not; check `--help` works |
| Helm values | `helm template` with the pinned chart version and read the rendered output |
| Kubernetes manifests | `kubectl apply --dry-run=server` against a live cluster when one exists |
| Node-mutating scripts | Test on a **single leased tray** first, then verify with `bin/k8s-verify-clean` |

There are unit test suites under `tests/` — the drift classifier that decides whether a
torn-down node counts as clean, path safety, rack ranking, rack-lease bookkeeping, and
version pinning. Run all of them:

```bash
for t in tests/test-*.sh; do "$t" || break; done    # 124 cases, must be 0 failed
```

Run `tests/test-drift-classify.sh` after any change to `lib/drift.sh`, `node/snapshot.sh`
or `node/teardown.sh`; if you add a captured field, add a case for it. Run
`tests/test-rack-leases.sh` after any change to lease bookkeeping or tray selection.

Every suite must stay **hermetic and instant**. `tests/test-rack-leases.sh` stubs `sinfo`
and `scontrol` for a concrete reason: a single un-stubbed `sinfo` blocks for the full
MessageTimeout when slurmctld is down, and that quietly turned a 0.09s suite into a 120s
one against a dead cluster.

`shellcheck` is not installed on the controller. If you add it, run
`shellcheck -S warning` over `lib/`, `bin/`, `node/`, and `slurm/`.

### Two bash traps that have already bitten us

- **`die` inside `< <(...)` only exits the subshell.** `mapfile -t x < <(f)` where `f` calls
  `die` leaves `x` empty and the script running, then `set -u` fails somewhere confusing.
  Always check the array is non-empty right after.
- **`pgrep -f <pattern>` matches the ssh command carrying your script.** A pristine node will
  report itself dirty. Match on the binary or the systemd unit instead. The same self-match
  applies to `pkill -f` in your own shell: `pkill -f up7` will happily kill the shell whose
  command line contains `up7`.
- **`timeout` cannot run a shell function.** `timeout 90 kc drain ...` reads perfectly and
  never worked: timeout(1) execs its argument, so it exits 127 instantly. In `bin/k8s-down`
  that meant every partial teardown silently skipped draining, with stderr discarded and
  `|| warn "drain timed out"` then reporting a timeout for something that had not run. Use
  `kbin <seconds> <args...>` (providers/k3s.sh), which invokes the real kubectl binary and
  falls back to the server's bundled one over ssh. Same trap applies to wrapping any of our
  helpers — `node_ssh`, `kc`, `rkc` — in `timeout`.
- **`rkc` cannot take arguments containing shell metacharacters.** It flattens argv with
  `$*` and the remote shell re-parses the result, so `-o jsonpath='{...[?(@.type=="Ready")]...}'`
  dies with ``syntax error near unexpected token `('`` — and, far worse,
  `custom-columns=...k8s-bootstrap\.io/rack` loses its backslash and reports `<none>` for
  every node instead of failing. Both were hit while writing `k8s-add-rack`: the Ready wait
  never matched, and the summary table showed no rack labels. Use `kbin` (real local
  kubectl) for anything non-trivial; keep `rkc` for metacharacter-free commands.
- **A bare assignment from a fallible command aborts the whole function under `set -e`.**
  `lib/common.sh` sets `-e`, so `h="$(cat missing)"` or `ip="$(node_ssh_ro dead-node ...)"`
  does not merely leave the variable empty -- it kills the enclosing function mid-loop,
  silently. This cost real debugging time twice: tray selection produced nothing instead of
  skipping an unreachable rack, and `node_ip()`'s NodeAddr fallback was unreachable because
  the ssh failure aborted the function before reaching it. Append `|| true` whenever the
  command is *expected* to be able to fail and you intend to inspect the result yourself.

  It is also why a background worker must not rely on reaching a later line:

  ```bash
  # WRONG: if ssh fails, set -e kills the subshell and the file is never written,
  # so the reader's `cat` fails too and takes ITS function down with it.
  { h="$(ssh "$n" hostname)"; printf '%s' "${h:-UNREACHABLE}" > "$out"; } &
  # RIGHT
  { h="$(ssh "$n" hostname 2>/dev/null || true)"; printf '%s' "${h:-UNREACHABLE}" > "$out" || true; } &
  ```

  Symptom to recognise: a function returns no output and prints none of its own warnings,
  while calling it directly seems to work. Trace with `bash -x` and watch for the nesting
  level dropping (`++` back to `+`) mid-loop -- that is the abort.

### Reporting honestly

State plainly what you ran and what it showed. If a test surfaced something inconvenient —
capacity lower than expected, a rack too small, an assumption that did not hold — report it
rather than routing around it. A surprise found at a step boundary is cheap; the same
surprise found three steps deep, on live nodes, is not.

## HGX clusters (nearby-woodcock, BM.GPU.B300.8) -- what differs

Everything above holds; these are the per-cluster switches, all in `clusters/<name>.env`:

- **`NODE_TOPOLOGY=flat`.** Names are `GPU-<n>` and encode no rack. Every B300 host has its
  own OCI `rack_id`, and all idle ones share one rail of one network block in
  `/etc/slurm/topology.yaml`, so they form ONE pseudo-rack, `FLAT_RACKID`. Nodes not matching
  `FLAT_NODE_RE` are invisible -- that is what keeps the drained aarch64 GB200 trays in the same
  `compute` partition out of our leases, with `SLURM_CONSTRAINT=default` as a second lock.
  `tests/test-node-topology.sh` pins that isolation for both schemes.
- **`IMEX_PATH=none`.** NVLink ends at the node; there is no IMEX domain, no channel and no
  `nvidia.com/gpu.clique` label (CliqueId is 0). Preflight records IMEX as INFO and the
  provider skips IMEX CDI setup. Gates 07-09 assert MNNVL and cannot pass here; use
  **`10-nccl-rdma.yaml`** (8 GPUs x 2 nodes over RoCE).
- **Multi-node traffic is multiplanar RoCE** over `rdma_vf_rail0..7` (IMDS
  `rdmaFabricData.planes=4`). Those are the VFs the site health check guards (the 2026-09-24
  incident): pods use them via `hostNetwork` + privileged + `IPC_LOCK` + `/dev/infiniband`,
  never by moving them into a pod namespace. **As of 2026-09-26 that fabric carries no RDMA
  data node-to-node** (reproduced with host perftest and the site's own Slurm NCCL recipe, not
  just in pods), so gate 10 has never passed and multi-node B300 work is parked. The site's
  multi-node health check does not notice: its B300 multiplanar branch runs `--np 8` against
  an 8-slots-per-node rankfile, i.e. every rank on ONE node (its 810 GB/s is NVLink).
- **Slurm `job_container/tmpfs`** mounts `<BasePath>/<jobid>` for every running job
  (`SLURM_JOB_CONTAINER_BASE`); `lib/drift.sh` classifies exactly those as Slurm's.
- **Site-transient listeners** (`SITE_TRANSIENT_PORTS`): the site's multi-node health check
  opens `ib_write_bw` servers on 18001-18008 (one per rail VRF) on idle trays; `ports.txt`
  drift on exactly those is the site's. Any other port change stays REAL.
- **A dead tray must not end the lease (`--no-kill`).** 2026-09-27: three trays went dark, the
  32-tray lease ended `NODE_FAIL`, the trap got KillWait (30 s) and cleaned 4 of 32 -- 28 trays
  sat in the shared pool with `k3s-agent` running for ~19 h until `k8s-down --nodes` removed it.
  Leases now pass `--no-kill`. And **a trap log saying "clean" is not proof**: GPU-642's said so
  while its `k3s-agent` was still active. Only `bin/k8s-verify-clean` is.
- **Cluster auto-selection.** With several `clusters/*.env`, `load_cluster` picks the one
  named after `<cluster>-controller`, so commands on either controller need no `--cluster`.

## Layout

| Path | What it is |
|---|---|
| `versions.env` | Single source of truth for versions |
| `clusters/*.env` | Per-cluster settings (localblock, rack, CIDRs, paths) |
| `bin/` | Operator entrypoints — the only things a human runs directly |
| `lib/` | Shared shell: `common.sh`, `slurm.sh`, `preflight.sh` |
| `providers/` | Distro implementations: `k3s.sh` (default), `kubeadm.sh` |
| `node/` | Scripts that run **on** leased nodes via ssh/clush |
| `slurm/` | Placeholder-lease sbatch scripts |
| `platform/` | Helm values, applied at bootstrap then adopted by GitOps |
| `gitops/` | Argo CD bootstrap, app-of-apps, kustomize overlays |
| `workloads/` | Phased test workloads: plumbing → training → inference |
| `docs/PLAN.md` | Full design, environment survey, and rationale |

## Conventions

- Bash, `set -euo pipefail`, shellcheck-clean. Every script sources `lib/common.sh`.
- Scripts are idempotent and safe to re-run.
- Anything that mutates a node prints exactly what it will do and honours `--dry-run`.
- Cluster state lives in `$STATE_DIR`
  (`/home/ubuntu/.local/state/k8s-bootstrap/<cluster>/`), never in the repo. Tokens and
  kubeconfigs are mode 0600.
- Secrets never enter the repo. GitHub credentials come from
  `~/.config/k8s-bootstrap/github-token`.

## Networking (Cilium)

k3s runs with `--flannel-backend=none --disable-network-policy --disable-kube-proxy`, so
Cilium provides the CNI **and** service handling. Those flags and
`kubeProxyReplacement: true` are a matched set — change one and services break silently.

- `routingMode: tunnel` + geneve, because the control-plane tray and the workers sit in
  different `/19` subnets and native routing would need routes on a fabric we do not own.
- `k8sServiceHost`/`k8sServicePort` are passed with `--set` at install time, not stored in
  values.yaml: without kube-proxy the agents cannot reach the API through a Service IP, so
  they need the control plane's real address.
- CNI paths stay at containerd's defaults (`/opt/cni/bin`, `/etc/cni/net.d`). Verified on a
  live node: k3s writes no `[cni]` section at all when flannel is disabled, precisely so a
  third-party CNI can drop in. No k3s-specific override is needed.
- `enableLBIPAM: false` and `defaultLBServiceIPAM: none` — the chart enables LB-IPAM by
  default, and rule 9 is enforced at the datapath rather than left merely unexercised.

**`operator.tolerations` must stay `- operator: Exists`.** This is the chart default and it
is load-bearing. Agents block until the operator registers Cilium's CRDs; until the agents
are ready every node is NotReady and therefore carries kubelet's automatic
`node.kubernetes.io/not-ready:NoSchedule` taint. Narrowing the operator's tolerations to
just the control-plane taint deadlocks the entire bootstrap. Verified the hard way.

## Teardown: what can and cannot be restored

Teardown must return a node byte-identical to its baseline, with a short, *enumerated* set
of exceptions that `lib/drift.sh` classifies as benign:

- k3s loads `br_netfilter`, `iptable_filter` and `iptable_nat`, which pull in an empty
  `*mangle` table and a `net.bridge.bridge-nf-call-iptables` sysctl key.
- **Investigating a node can dirty it.** The `sock_diag` modules autoload from any
  socket-inspecting command: `ss -Hltn` (which our own preflight and snapshot both run)
  pulls `inet_diag`/`tcp_diag`, and `ss -x` pulls `unix_diag`. A purely read-only
  `ss -xlp`, run to find out which containerd owned the NRI socket, made a torn-down tray
  fail `k8s-verify-clean` as REAL drift half an hour later. The whole 14-module family is
  now classified benign. When verify-clean flags a module, check what *you* ran on that
  node before concluding teardown is at fault.
- Cilium loads its eBPF/tunnel modules (`cls_bpf`, `sch_ingress`, `geneve`,
  `nf_socket_*`, `nf_tproxy_*`, …).
- Everything else — paths, units, interfaces, eBPF pins, firewall rules, mounts, the host
  CDI hash, `nf_conntrack_max` — is actively restored and **must** match.

Three Cilium-specific leftovers that k3s's own uninstaller knows nothing about, all now
handled in `node/teardown.sh`:

- **`CILIUM_*` iptables chains.** k3s's killall strips `KUBE-`/`CNI-`/flannel only. We
  filter cilium lines and restore, the same technique, leaving host rules intact.
- **Generated CDI specs.** The device plugin writes
  `/var/run/cdi/k8s.device-plugin.nvidia.com-gpu.json` and the DRA driver writes one
  `k8s.gpu.nvidia.com-claim_<uuid>.yaml` per claim; both outlive their pods, and the
  device-plugin one even survived a switch to DRA. Teardown removes `k8s.*` specs and
  skips `$HOST_CDI_SPEC` by explicit comparison, not by pattern luck.
- **`/run/cilium/cgroupv2` is a cgroup2 mount.** `/run/cilium` itself is not a mountpoint,
  so a plain `rm -rf` leaves the directory behind. Teardown now unmounts everything
  *beneath* each target path, deepest first.
- **eBPF pins under `/sys/fs/bpf`.** Note that directory is root-only: `node/snapshot.sh`
  must use `sudo` to list it, or both phases record an empty file and the check silently
  does nothing. That bug was live for a while.

**Do not try to unload those modules.** `modprobe -r` also removes dependencies that become
unused, so unloading `br_netfilter` cascades to `bridge` and destroys the host's `docker0`
interface; unloading `iptable_*` cascades to `ip_tables`. This was tried on a live node and
it broke Docker. Modules autoload on demand and cost nothing — classify, do not remove.

If you add a new captured field to `node/snapshot.sh`, either restore it in
`node/teardown.sh` or classify it in `lib/drift.sh`. Never widen the benign allowlist to
silence a real leftover: the allowlist matches exact module names and an *empty* table, not
"this file changed".

## GPU stack: two mutually exclusive modes

The chart offers two stacks and rejects having both CRs present ("It is an invalid
configuration for both CRs to exist"):

| Mode | CR | Pods request | Status |
|---|---|---|---|
| default | `ClusterPolicy` | `resources.limits."nvidia.com/gpu"` | stable |
| `bin/k8s-gpu --dra` | `GPUCluster` | a `ResourceClaim` on `gpu.nvidia.com` | NVIDIA calls it experimental |

Switching modes is a real switch, not an addition. Under DRA the device-plugin
DaemonSet is removed and the node's `nvidia.com/gpu` **allocatable drops to 0**
(the `capacity` figure can linger, which is misleading — check allocatable), so
any manifest requesting `nvidia.com/gpu` simply never schedules.

**Switching in place is not reliable.** Observed live: helm deleted the
ClusterPolicy CR, yet the GPUCluster controller kept reporting
`PrerequisiteNotMet: A ClusterPolicy CR "cluster-policy" exists` while the
operator's own log said that CR was not found — a stale cache leaving GPUCluster
`notReady` indefinitely. `platform_install_gpu_operator()` now detects a mode
change and restarts the operator deployment afterwards to force a re-read.

**Everything the host already provides stays off**: `driver.enabled=false`
(host 595.71.05), `toolkit.enabled=false` (host toolkit 1.20.0, and k3s already
wrote the `nvidia` containerd runtime), `dcgm.enabled=false` (host nv-hostengine
on :5555), `dcgmExporter.enabled=false` (host exporter owns :9400 and the
operator's would collide on the hostPort). `migManager` is off because GB300 is
used whole here.

`cdi.enabled=true` is required for device injection, and it is the setting to
suspect first if the host CDI spec hash ever moves.
`platform_install_gpu_operator()` captures `sha256sum /var/run/cdi/nvidia.yaml`
on every tray before installing and re-checks after, failing the install if it
changed — rule 5, enforced rather than trusted.

DRA availability is a property of the cluster, not of NVIDIA: DRA went GA in
Kubernetes 1.34 (`resource.k8s.io/v1`, on by default) and k3s v1.36.4 serves
`deviceclasses`, `resourceclaims`, `resourceclaimtemplates` and `resourceslices`
— verified live. To render the DRA manifests offline, `helm template` needs
`--api-versions resource.k8s.io/v1/DeviceClass`, since the chart refuses to
render the stack it cannot see support for.

## GPU / IMEX: the one subtlety to understand

NVIDIA's blessed multi-node-NVLink path (GPU Operator DRA + `ComputeDomain`) requires
`systemctl disable --now nvidia-imex.service && systemctl mask nvidia-imex.service`. That
mutates a provider-managed daemon, so it is **not** the default.

- **Path A (default).** Host IMEX untouched. Device plugin exposes `nvidia.com/gpu`; GFD
  publishes `nvidia.com/gpu.clique`. Pods needing multi-node NVLink get
  `/dev/nvidia-caps-imex-channels/channel0` injected via our own additive CDI spec.
- **Path B (opt-in, 2+ racks).** DRA `ComputeDomain`, via guarded scripts that snapshot and
  restore IMEX state. Only worth it when per-job domain scoping matters.

### DRA + IMEX coexist, but only if `runtimeClassName: nvidia` stays (2026-09-14)

`workloads/plumbing/09-nccl-4x4-dra.yaml` is gate 08 with the GPUs coming from a
`ResourceClaim` (`count: 4`) instead of `limits: nvidia.com/gpu`. It passes:

```
GPUs visible : 4       NVIDIA_VISIBLE_DEVICES=void      IMEX channels: channel0
nRanks 8 nNodes 1 localRanks 8 MNNVL 1
P2P/MNNVL channels: 128    NET/Socket in data path: 0
PERF {"algbw_GBs": 397.85, "busbw_GBs": 696.24}    VALIDATION all_ok true, ranks_ok 8
```

696.24 GB/s against 696.93 for the device-plugin path — DRA costs nothing measurable.

**The non-obvious part: the pod keeps `runtimeClassName: nvidia` even though gate 04 (DRA,
single GPU) omits it and works.** It is there for IMEX, not for the GPUs.
`node/install-containerd-cdi-annotations.sh` allowlists `cdi.k8s.io/*` on the **`nvidia`
runtime table only**, so a DRA pod on the default runc runtime has the imex annotation
silently dropped and NCCL then reports "MNNVL is available but not working". The DRA driver
sets `NVIDIA_VISIBLE_DEVICES=void` in its own CDI spec precisely so the legacy nvidia hook
does not also inject GPUs, which is why the two mechanisms compose rather than fight.

If a DRA pod ever needs the default runtime, the allowlist has to be widened to it rather
than the annotation moved.

**`nvidia.com/gpu` does not merely drop to 0 under DRA — it ceases to exist.** Node
allocatable reads `<none>`, and the scheduler says `Insufficient nvidia.com/gpu`, which
looks like a capacity problem and is not one. Gates 07 and 08 both carry a header note
pointing at 09 for this reason. ResourceClaims are released automatically when the pods
complete; no GPUs stay pinned.

Note that these are orthogonal: `bin/k8s-gpu --dra` uses DRA for **GPU allocation** and
still leaves host IMEX alone, because `platform/gpu-operator/values-dra.yaml` sets
`draDriver.computeDomains.enabled=false`. The chart defaults that to **true**, so it must be
disabled explicitly — enabling it is what would mask `nvidia-imex.service`. Using DRA is
therefore not the same decision as adopting Path B.

GFD publishes `nvidia.com/gpu.clique` as `<ClusterUUID>.<CliqueId>` (observed:
`5cd30dc8-...-388`, where `388` is the same CliqueId `nvidia-smi -q` reports). That label is
the correct thing for a multi-node job to pin on.

### Path A is PROVEN (2026-09-10)

`workloads/plumbing/07-nccl-2node.yaml` passes on two trays of one rack, non-privileged:

```
MNNVL 1 cliqueId 184 cliqueSize 2 cliqueRank 0
Channel 00/0 : 0[0] -> 1[0] via P2P/MNNVL
PERF {"busbw_GBs": 544.49, ...}   correct=True
```

544 GB/s over `P2P/MNNVL` against the host-managed IMEX domain. `nvidia-imex.service` was
never touched. Training can be built on Path A.

`workloads/plumbing/08-nccl-4x4.yaml` scales it to every GPU on both trays — 8 ranks via
`torchrun --nproc_per_node=4`:

```
TOPO {"world_size": 8, "ranks_per_host": {"bi4ua-2": 4, "bi4ua-3": 4}}
nRanks 8 nNodes 1 localRanks 8 MNNVL 1
P2P/MNNVL channels: 128    NET/Socket in data path: 0
PERF {"algbw_GBs": 398.25, "busbw_GBs": 696.93}
```

**`nNodes 1` with `localRanks 8` is the headline.** NCCL collapses two trays in one clique
into a single logical node, so an 8-GPU collective across two machines is treated exactly
like an 8-GPU single-box job. That is why intra-rack work needs no RDMA at all.

Gate 07 (1 GPU/pod) is the fast smoke test; gate 08 is the full-scale one. Use 07 to check
plumbing, 08 before trusting performance numbers.

### How a pod gets IMEX access (three things, none of them the default)

Getting this wrong produces exactly one symptom, and it is misleading:

```
MNNVL (cliqueSize 2) is available but not working on this system.
Check the IMEX channel configuration (/dev/nvidia-caps-imex-channels).
```

NCCL *sees* the domain and refuses to use it. What is actually required:

1. **A CDI spec for the channel** — `node/install-imex-cdi.sh` writes
   `/var/run/cdi/k8s-bootstrap-imex.yaml` (additive; the host's `nvidia.yaml` is untouched,
   rule 5).
2. **containerd must forward `cdi.k8s.io/*` annotations to the runtime** —
   `node/install-containerd-cdi-annotations.sh` adds a drop-in under k3s's
   `config-v3.toml.d/`. Containerd does not pass annotations through unless they are
   allowlisted, so without this the annotation is silently ignored. This configures **k3s's**
   containerd, never the host's (rule 3 is about the host's).
3. **The pod requests it** — `annotations: {cdi.k8s.io/imex: "nvidia.com/imex-channel=all"}`.

`provider_enable_imex_access()` applies 1 and 2 automatically after agents join.

### Rail VFs, network-DRA claims and the site's node health check — READ THE INCIDENT

**Root cause of the three rack losses on 2026-09-24** (pgmjq/ayoqa 04:54, kobyq/mkd4q 17:27,
kobyq/snura 18:39 UTC, every lease NODE_FAIL): the site's node health check
(`/opt/oci-hpc/healthchecks/check_gpu_setup.py`, `check_multiplanar_rdma_vf_routes`) requires every
`rdma_vf_rail*` interface **present in the host network namespace** with one global IPv6 address and
**exactly one** IPv6 default route (the RA route). KTLO's multi-node checks with `gpu.rdma.nicCount: 4`
claimed the four rail VFs through the DRA network driver (dranet), which **moves the VF netdevs into
the pod namespace** for the run — whole-clique `nccl`/`nccl_pairwise` do that on every tray at once.
Captured live on GPU-kobyq-snura-1: 0 VFs / 0 rail routes on the host while its worker ran, all back
one minute after the Jobs were deleted. Result each time: `Healthcheck:: RDMA Route Missing`, drain,
reboot, lease gone. The persistent `accept_ra_defrtr=0` drop-in used on the first two racks was a
second, independent violation of the same check (it removes the "exactly one default route").

Rules: (1) **KTLO runs multi-node checks host-network on this site** — the skill's step-6 overlay
writes `gpu.rdma.nicCount: 0` and ktlo-tech PR #691 flips the GB300 default; never deploy with
claims enabled here. (2) **Never change what the site's health checks measure on a shared node** —
interfaces, routes, sysctls, services — beyond the seconds an action needs. (3) dranet installed and
idle is harmless; only claims move interfaces. `node/install-rail-ra-guard.sh` (transient RA-route
drop before a driver restart) is only relevant when claims are in use; `--revert` removes the legacy
drop-in if a tray still has one. Evidence: ktlo-telemetry-lake
`reports/gb300/2026-09-24-rack-snura-gate553/`.
