# Demo runbook — 30 minutes, live cluster optional

Everything below was timed on 2026-09-30 on rack 3uwoq/6g3ya. Two modes: **live** (bring the
cluster up during the architecture talk, run three cells, show the dashboard) or **recorded** (the
committed `results/`, `SUMMARY.md`, the deck). Rehearse live once; keep recorded as the fallback.

## 0. Before the session (10 min, once)

```bash
cd ~/dkennetz/compass_takehome && export KUBECONFIG=~/.local/state/k8s-bootstrap/polite-possum/kubeconfig
source scripts/creds.sh                                   # Quay + Grafana tokens into env (never printed)
export DRANET_SRC=/path/to/dranet                          # git clone -b slaac-addressing https://github.com/dkennetzoracle/dranet
cat .image-digest                                          # the image the results were made with
open https://wittysquash3587.grafana.net/d/compass-nccl-fabric   # dashboard tab, time range "last 15 min", refresh 10 s
```

Checklist: `bin/k8s-status` shows an idle 18-tray rack; `gh run list --limit 1` is green; the deck opens;
`results/SUMMARY.md` renders. If the lease is already up from earlier, skip step 1 and start at step 3.

## 1. Bring the cluster up (≈ 7 min wall clock — talk over it)

| step | command | measured |
|---|---|---|
| preflight (read-only) | `(cd infra/k8s_bootstrap && bin/k8s-preflight --rack <block>/<rack> --workers 2)` | ~45 s |
| lease + k3s + Cilium | `(cd infra/k8s_bootstrap && bin/k8s-up --cluster polite-possum --rack <block>/<rack> --workers 2 --lease-time 1-00:00:00 --yes)` | ~4 min (nodes Ready ~85 s after the lease) |
| GPU stack, DRA mode | `(cd infra/k8s_bootstrap && bin/k8s-gpu --dra)` | ~1.5 min (2 ResourceSlices after ~20 s) |
| dranet fork + DeviceClass + namespace | steps 3 of `scripts/cluster-up.sh`, or the block below | ~1 min |

```bash
kubectl create ns dranet; kubectl label ns dranet pod-security.kubernetes.io/enforce=privileged
kubectl create ns compass
for ns in compass dranet; do kubectl -n $ns create secret docker-registry compass-quay-pull --docker-server=quay.io \
  --docker-username="$QUAY_USERNAME" --docker-password="$QUAY_PASSWORD"; done
helm upgrade --install dranet $DRANET_SRC/deployments/helm/dranet -n dranet -f deploy/k8s/dranet-values.yaml --wait
kubectl apply -f deploy/k8s/deviceclass-dranet.yaml
kubectl get resourceslices -o json | jq -r '[.items[]|select(.spec.driver=="dra.net")]|"slices=\(length) devices=\([.[].spec.devices[]]|length)"'   # 3 / 12
kubectl -n dranet logs ds/dranet | grep 'RDMA subsystem'          # "in mode: shared" on the workers
```

`scripts/cluster-up.sh --rack <block>/<rack> --dranet-src $DRANET_SRC` runs all of it in one go
(same order, same timings) and ends with the probe.

### Talking points while it comes up

**Why Kubernetes on borrowed Slurm trays, and why do-no-harm shapes everything.** The trays are leased
from a shared pool; the bootstrap snapshots each node before touching it and proves it identical after
teardown (`k8s-verify-clean`: "pristine" on every run today). Nothing in `/usr/local/bin`, no changes to
Slurm, containerd or the provider daemons (IMEX, DCGM), state on local disk. That constraint is why the
RDMA netns mode is set *before* k3s (the kernel refuses it once any pod namespace exists) and restored at
teardown.

**Why DRA for GPUs.** Dynamic Resource Allocation (GA in Kubernetes 1.34) replaces the opaque
`nvidia.com/gpu: 4` counter with a `ResourceClaim` against a `DeviceClass`: the scheduler sees the
devices as structured objects with attributes, the claim is per pod, and the same mechanism serves any
device kind — which is exactly what lets NICs be claimed the same way. Show:
`kubectl get resourceslices -o yaml | head -60` (GPU UUIDs, memory, the node) and a claim from
`deploy/k8s/rendered/e1-nvlink/manifests.yaml`.

**Why dranet for NICs, and why the fork.** A GB300 tray has four rail NICs, one per GPU. Upstream
network-DRA moves the NIC into the pod's namespace; on this site that removes it from the host, the site
health check reads "RDMA route missing", and the tray gets drained and rebooted (three racks lost that
way on 2026-09-24). The fork adds an **IPVLAN** interface type: the VF stays on the host with its address
and routes, the pod gets a child interface with its own SLAAC address, and — with the RDMA subsystem in
**shared** netns mode — the driver injects only the RDMA char devices. Result: pods use the rails, the
host inventory never changes, no `hostNetwork`, no privileged pods. Show `deploy/k8s/fragments/claim-nic.yaml.j2`
and, once the probe is up, the host still listing `rdma_vf_rail0` while the pod uses it.

**Why Cilium, and which knobs matter here** (`infra/k8s_bootstrap/platform/cilium/values.yaml`):
- `kubeProxyReplacement: true` — eBPF service load-balancing, no kube-proxy, no iptables churn on a host
  whose health check watches routes; k3s is installed with `--disable-kube-proxy --flannel-backend=none`.
- `routingMode: tunnel`, `tunnelProtocol: geneve`, `autoDirectNodeRoutes: false` — pod traffic is
  encapsulated on the management NIC; the site network never learns pod CIDRs, no BGP, and no route is
  added to the rails. The TCP-over-overlay cell (4 GB/s) shows what that path costs and why the data
  plane must never run on it.
- `enableLBIPAM: false`, no LoadBalancer IPs (a site rule): rendezvous is a headless Service.
- Hubble relay on: `cilium hubble port-forward` + `hubble observe --pod compass-...` shows the
  rendezvous and NCCL bootstrap over `eth0` and *nothing* on the data path — the data never touches the CNI.
- Pod network everywhere means the GID index inside a pod is not the host's (next section).

## 2. Prove the design with the probe (≈ 1 min once the image is cached; ≈ 5 min on a cold tray)

```bash
kubectl apply -f deploy/k8s/probe/probe-rails.yaml && kubectl -n compass wait --for=condition=Ready pod -l app=probe-rail --timeout=600s
scripts/demo-gid.sh                       # host table (index 3) next to pod table (index 7), and the pingpong
kubectl delete -f deploy/k8s/probe/probe-rails.yaml
```

Talking points: the GID table layout (two entries per address, one per RoCE version; link-local at
0/1, the VF's global at 2/3; the child's at 4–7 in the pod's namespace); why RoCE v2 + global is the only
routable choice; why the index is *discovered* per pod (`bench/gid.py`, run by every RDMA cell's
pre-check with a router solicitation first — a fresh pod has only link-local addresses until an RA
arrives). Pingpong at 4 KiB MTU: ~115–130 µs per 1 MiB round trip, 12–15 µs at 4 KiB.

## 3. Run three cells live (≈ 4 min)

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-counters-nvlink --image "$(cat .image-digest)"   # ~50 s
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-counters-rdma   --image "$(cat .image-digest)"   # ~55 s
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-counters-rails1 --image "$(cat .image-digest)"   # ~60 s
```

(`rm -rf results/raw/e5-counters-*` first if you want them re-run rather than skipped.) While each runs,
`kubectl -n compass logs -f job/compass-e5-counters-rdma` shows the pre-check: usable HCAs, the global
addresses appearing, the GID table with `<-- chosen`, then `PHASE`/`PERF` lines. Point at the dashboard
between cells: rails idle during the NVLink cell, ~480 Gb/s per rail during the RDMA cell, one rail at
~410 Gb/s in the rails1 cell.

### NCCL tuning talking points (recorded results, `results/SUMMARY.md`)

- **Transport is proven, not inferred**: every result carries NCCL's own channel report
  (`P2P/MNNVL` 256 channels on the NVLink cells; `NET/IB/…/GDRDMA` 640 on RDMA; `NET/Socket` on TCP).
- **`NCCL_IB_QPS_PER_CONNECTION`** (the one optimization): hypothesis, change, 5 repeats, Welch p —
  and a negative result: −8 % at 2, −29 % at 4; the counter window shows why (338 vs 482 Gb/s per rail,
  reordering/congestion counters still zero: less useful work per unit time, not the network).
- **`NCCL_NET_GDR_LEVEL=0`**: −38 %; same bytes on the wire, 1.6× the time — the host bounce over C2C is
  pure copy/latency cost. `NCCL_ALGO=NVLS` vs `Ring` on NVLink: 474 vs 388 GB/s algbw. `NCCL_BUFFSIZE`:
  noise. Socket threads: 7× on TCP, still 14× below RDMA.
- **`NCCL_P2P_NET_CHUNKSIZE`** is deliberately unset on the IB path (recorded earlier: QPs connect, zero
  bytes move when it is set). **`NCCL_IB_GID_INDEX`** is discovered. **`NCCL_IB_HCA`** is set to exactly
  the claimed rails (in shared mode sysfs lists all of them).
- The rails are **800 Gb/s** (4 planes × 200; sysfs says 200). The counters proved it: one rail carried
  411 Gb/s. So the RDMA ceiling (~55 % utilisation, flat DCQCN counters, PCIe Gen6 x16) is the per-rail
  injection path — a narrowed hypothesis with the next experiment named (channels per NIC, placement).

### Training tests (recorded; ~1 min per cell if run live)

`e3-g1 … e3-g8-rdma`: GPT-124M, bf16, 8 × 1024 tokens per GPU, DDP. 381 → 710 → 1191 samples/s on one
tray (100 / 93 / 78 %), 2804 over NVLink (92 %), 2090 over the rails (69 %, comm fraction 91 %).
`e5-ddp-bucket200`: 25 → 200 MiB buckets over the rails: 2769 samples/s (+32 %), comm 91 % → 32 %.
Talking point: on a slow transport, change *how often* you talk before *how* you talk; the comm fraction
is NCCL kernel residency from `torch.profiler` — an upper bound on exposed communication because it
overlaps backward compute.

## 4. Dashboard walkthrough (≈ 4 min) — *Compass — NCCL fabric counters*

Top to bottom, with the `node` variable on All:
1. **NVLink bytes per GPU** (host NVLink exporter :9600, summed over links): ~240 GB/s per GPU during the
   NVLink cell, flat during RDMA — the topology decides the path.
2. **PCIe bytes per GPU / SM active / power / clocks** (DCGM :9400): SM active is low during a pure
   collective; in the DDP cells the gap to 100 % is time spent waiting on communication.
3. **Rail transmit / receive rate** (RDMA exporter :9500, `ib_port_xmit_data` in bytes ×8): 4 × ~480 Gb/s
   in the RDMA cell, one rail in the rails1 cell, 0 in the NVLink cell.
4. **Congestion: CNPs, ECN marks** and **Reliability: out-of-sequence, sequence errors, ACK timeouts,
   adaptive retransmissions**: flat in every cell — the evidence that the ceiling is not the network.
5. **RoCE slow restarts / ICRC**: flat. **Port transmit wait**: credits, flat.
6. **Management NIC throughput / host CPU softirq+system**: the TCP cells and only the TCP cells show
   up here — RDMA and NVLink cost the host nothing.

Also worth two minutes: the same numbers in Prometheus terms —
`rate(ib_port_xmit_data{interface=~"rdma_vf_rail.*"}[1m])*8` in Explore, and the fact that the collector
(Grafana Alloy, Terraform-managed, per-tenant token) scrapes host-process exporters the site already
runs, deploying nothing on the trays.

## 5. Gaps this runbook fills that the deck alone does not

- **Fallback**: if the lease is gone, run the deck from `results/`; every number is machine-derived
  and the raw JSON per run is committed. `python -m analysis results/raw` regenerates tables and charts.
- **Reproducibility proof**: `make render-check` and `python deploy/k8s/render.py --list` show that the
  41 cells come from one `matrix.yaml`; `result.json` records image digest, versions, every `NCCL_*`.
- **Questions to expect**: why busbw counts intra-tray hops (convention, comparable with vendor tools);
  why per-rank spread matters (a fixed straggler vs jitter); how you would place jobs at rack scale
  (NVLink clique labels; rails between cliques; floors per width and size); what a silent socket fallback
  looks like and why it is a FAIL, not a slow run.
- **Teardown**: `(cd infra/k8s_bootstrap && bin/k8s-down --yes)` — ~3 min, verifies the trays clean.
