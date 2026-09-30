# Demo runbook — a 30-minute walkthrough that follows the brief

The brief asks for five things in the presentation: architecture and design choices; baseline and
scaling results; a bottleneck diagnosis that separates evidence from diagnosis; one optimization with
before/after evidence (Baseline → Hypothesis → Change → Measurement → Conclusion); and how the design
extends to multi-node production. This runbook is organised in that order. Every number quoted is in
`results/SUMMARY.md` and comes from a committed `result.json`.

Two ways to run it. **Live**: bring the cluster up during the architecture section, run three short
benchmark cells, and show the counters moving on the dashboard. **Recorded**: use the committed
results and the deck (`slides/compass.pptx`, which has speaker notes on every slide). Rehearse live once
and keep recorded as the fallback; nothing in the story depends on the live part succeeding.

Terms used below, once: **DRA** is Kubernetes Dynamic Resource Allocation, the mechanism a pod uses to
claim devices such as GPUs or NICs. **dranet** is the network-DRA driver that publishes NICs. A **rail**
is one of the four RDMA-capable NICs on a tray, one per GPU. **RoCE v2** is RDMA carried over routable
Ethernet/IP. A **GID** is the address an RDMA NIC uses for RoCE traffic; the **GID index** is which
entry of the NIC's address table NCCL should send from. **MNNVL** is multi-node NVLink: GPUs in
different trays talking over NVLink through the NVSwitch fabric, enabled by the host's IMEX daemon.
**Bus bandwidth** is the standard normalised speed collective benchmarks report.

## 0. Before the session (10 minutes, once)

```bash
cd ~/dkennetz/compass_takehome
export KUBECONFIG=~/.local/state/k8s-bootstrap/polite-possum/kubeconfig
source scripts/creds.sh                                   # exports the Quay and Grafana tokens; prints nothing
export DRANET_SRC=$HOME/src/dranet                        # git clone -b slaac-addressing https://github.com/dkennetzoracle/dranet $DRANET_SRC
cat .image-digest                                          # the exact image the committed results were produced with
```

Open two browser tabs: the dashboard
`https://wittysquash3587.grafana.net/d/compass-nccl-fabric` (time range "last 15 minutes", refresh
10 s, node variable "All") and the GitHub Actions page of the repo (the latest run is green: lint, tests,
manifest check, Terraform validation, analysis smoke run, image build and publish to ghcr.io).

Checklist: `(cd infra/k8s_bootstrap && bin/k8s-status)` lists an idle rack; the deck opens; you can
`less results/SUMMARY.md`. If a cluster is already up from earlier, start at section 2.

## 1. Architecture and design choices — talk while the cluster comes up (about 7 minutes)

Run these one after another; each finishes before the next starts. Times were measured on 2026-09-30.

| what | command | time | what you will see |
|---|---|---|---|
| check the trays are safe to use (read-only) | `(cd infra/k8s_bootstrap && bin/k8s-preflight --rack <block>/<rack> --workers 2)` | ~45 s | "ok preflight passed on all 3 tray(s)" |
| lease three trays, install k3s and Cilium | `(cd infra/k8s_bootstrap && bin/k8s-up --cluster polite-possum --rack <block>/<rack> --workers 2 --lease-time 1-00:00:00 --yes)` | ~4 min | a Slurm job is created; three nodes go Ready about 85 s after the lease |
| install the GPU stack in DRA mode | `(cd infra/k8s_bootstrap && bin/k8s-gpu --dra)` | ~1.5 min | "2 ResourceSlice(s) published" — the two workers advertising 4 GPUs each |
| install the NIC driver and create the namespace | `scripts/cluster-up.sh` step 3, or the block below | ~1 min | "dranet slices=3 devices=12" and "RDMA subsystem in mode: shared" in the driver log |

```bash
kubectl create ns dranet && kubectl label ns dranet pod-security.kubernetes.io/enforce=privileged
kubectl create ns compass
for ns in compass dranet; do kubectl -n $ns create secret docker-registry compass-quay-pull --docker-server=quay.io \
  --docker-username="$QUAY_USERNAME" --docker-password="$QUAY_PASSWORD"; done
helm upgrade --install dranet $DRANET_SRC/deployments/helm/dranet -n dranet -f deploy/k8s/dranet-values.yaml --wait
kubectl apply -f deploy/k8s/deviceclass-dranet.yaml
kubectl get resourceslices -o json | jq -r '[.items[]|select(.spec.driver=="dra.net")]|"slices=\(length) devices=\([.[].spec.devices[]]|length)"'
kubectl -n dranet logs ds/dranet | grep 'RDMA subsystem'
```

`scripts/cluster-up.sh --rack <block>/<rack> --dranet-src $DRANET_SRC` does all of the above in one
command with the same timings, and ends with the probe from section 2.

### What to say while it runs

**The hardware and the three networks.** Two GB300 trays; each has four GPUs joined by NVLink, four
ConnectX-8 rails (one per GPU), and two Grace CPUs. The two trays are in the same NVLink domain, so
GPUs in different trays can talk over NVLink as well as over the rails. That gives us three ways to
run the same collective: NVLink, RDMA over the rails, and TCP. The brief says not to assume the network
is the problem; measuring all three paths is how we avoid assuming.

**Why Kubernetes, and why a two-tray lease.** The brief cares about reproducibility, not the
scheduler. Kubernetes gives us declarative manifests that are committed and drift-checked in CI, a
scheduler that allocates GPUs and NICs as devices, and one container image that CI builds and
publishes to ghcr.io. Two trays are enough for every question asked (two ranks, two nodes, NVLink
versus RDMA), so we leased two workers rather than a rack. The trays are borrowed from a shared Slurm
pool, which is why the bootstrap snapshots every node before touching it and proves it identical after
teardown — nothing is installed in system paths, and no host daemon is changed.

**Why DRA rather than the device plugin.** With the device plugin a node advertises an opaque count
(`nvidia.com/gpu: 4`); a pod can ask for a number of GPUs and nothing else. With DRA the cluster
publishes every device with its attributes and a pod writes a claim against a device class. Show
`kubectl get resourceslices -o yaml | head -60`: the GPUs with UUIDs and memory, and the rails with
their interface name, RDMA flag and PCI address. The point that matters for this exercise: GPUs and
NICs are claimed the same way, in the same pod spec, so a pod can ask for "4 GPUs and 2 rails" and we
can vary the rail count per experiment without touching the host. Show the two claims in
`deploy/k8s/rendered/e2-rails2/manifests.yaml`.

**Why dranet, and why a fork of it.** dranet is the driver that publishes NICs through DRA. Upstream
gives a pod a NIC by moving it into the pod's network namespace. On this site the node health check
inventories the rails on the host; a moved rail reads as a broken node and the tray gets drained and
rebooted (that happened to three racks in earlier work). The fork adds an IPVLAN mode: the rail stays
on the host with its address and routes, and the pod gets a child interface with its own address. For
RDMA to work that way the host's RDMA subsystem must run in "shared" namespace mode, which the kernel
only lets you set when no container namespace exists — so the bootstrap sets it on the freshly
leased node before installing k3s and restores it at teardown. Decisions we made and why: no pod runs
with host networking, no pod is privileged, and the host's view of its NICs never changes.

**Why Cilium, and which settings matter here** (`infra/k8s_bootstrap/platform/cilium/values.yaml`).
Cilium is the pod network. It replaces kube-proxy with eBPF (no iptables rules churned on a host whose
health check watches routing), it tunnels pod traffic over the management NIC with geneve so the site
network never has to learn pod addresses (no BGP, no LoadBalancer IPs, both site rules), and Hubble
shows flows. The important design point: the pod network carries only the rendezvous and NCCL's
bootstrap handshake; the collective's data goes over NVLink or the rails. The "TCP over the overlay"
result (4 GB/s) is the measured reason.

## 2. Prove the design before benchmarking (1 minute warm, 5 minutes on a cold tray)

```bash
kubectl apply -f deploy/k8s/probe/probe-rails.yaml
kubectl -n compass wait --for=condition=Ready pod -l app=probe-rail --timeout=600s
scripts/demo-gid.sh
kubectl delete -f deploy/k8s/probe/probe-rails.yaml
```

`demo-gid.sh` prints three things. First, the host's view of the rail's address table: two entries
per IP address (one per RoCE version), link-local at indexes 0 and 1, the rail's global address at 2
and 3. Then the pod's view of the same NIC: the pod's own child interface has its own address, which
lands at indexes 4 to 7, and the tool picks **index 7**, the RoCE v2 entry with a routable address. It
also shows that the host still owns the rail (same address, four RDMA links) while the pod is using it.
Finally, it runs `ibv_rc_pingpong` between the two probe pods on that index: about 12 to 15
microseconds per 4 KiB round trip, about 120 microseconds per 1 MiB.

What to say: most recipes hard-code the GID index to 3. Inside our pods that would fail, because the
pod's address is a later entry. So every RDMA run discovers the index from the address table
(`python -m bench gid`), after first soliciting the router for an address — a fresh pod only has a
link-local address until a router advertisement arrives. This is a small example of the brief's
"separate evidence from diagnosis": we read the table instead of assuming.

## 3. Baseline, scaling and diagnosis — run three cells live (about 4 minutes)

```bash
rm -rf results/raw/e5-counters-nvlink results/raw/e5-counters-rdma results/raw/e5-counters-rails1   # only if you want them re-run rather than skipped
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-counters-nvlink --image "$(cat .image-digest)"   # ~50 s
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-counters-rdma   --image "$(cat .image-digest)"   # ~55 s
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-counters-rails1 --image "$(cat .image-digest)"   # ~60 s
```

Each command starts one Job (one pod per tray, four GPU ranks each), a small watcher pod on each
tray, waits for the Job, collects the result, and cleans up. While a cell runs, in a second terminal
`kubectl -n compass logs -f job/compass-e5-counters-rdma` shows the pre-check (which rails the pod
got, their addresses appearing, the address table with `<-- chosen`), then a `PHASE` line when the
timed loop starts and a `PERF` line with the bandwidth. Switch to the dashboard between cells: during
the NVLink cell the rails are idle and the NVLink panels move; during the RDMA cell each of the four
rails carries about 480 Gb/s; in the rails1 cell one rail carries about 410 Gb/s and the others nothing.

### What to say, tied to the recorded results

**Baseline (brief item 2).** Same 8-GPU all-reduce over three paths, 1 MiB to 8 GiB. NVLink reaches
835 GB/s bus bandwidth; the four rails about 425 GB/s; TCP on one rail 118 GB/s; TCP on the pod
overlay 4 GB/s. Below a few MiB every path costs about the same 20 to 80 microseconds — fixed costs,
not data. Which path was used is not inferred from the speed: every result records NCCL's own
connection log (256 NVLink channels, or 640 RDMA channels with GPUDirect, or socket channels).

**Scaling (brief item 2).** The training workload — a 124M-parameter GPT with PyTorch DDP — runs at 1,
2, 4 GPUs on one tray and 8 across two. Efficiency 93 % at 2, 78 % at 4, 92 % at 8 over NVLink, 69 % at
8 over the rails. The profiler shows communication taking most of the step at this model size.

**Diagnosis (brief item 3), evidence first.** Bandwidth on the RDMA path scales with the number of
rails: 96, 207, 364 GB/s at 1, 2, 4 rails. The bytes the NIC counted on the wire equal the theoretical
minimum for a two-node all-reduce, and a single rail carried 411 Gb/s — impossible on a 200 Gb/s link,
so a rail is really four 200 Gb/s planes, 800 Gb/s (the physical ports `rdma_p0..p3_rail0` are on the
host; sysfs reports one plane). The rails therefore ran at 51 to 60 % of capacity. Congestion and
reliability counters stayed at zero. Both NIC and GPU negotiate PCIe Gen6 x16. So: not the wire, not
congestion, not PCIe. The diagnosis, kept apart: the remaining suspect is the per-rail injection path
(one NCCL connection per GPU–NIC pair, GPUDirect across the Grace socket), stated as a hypothesis with
the next experiment named. The 1-to-4-GPU drop on one tray involves no NIC at all — that one is model
size and launch overhead, and saying so is the point.

## 4. The optimization — Baseline → Hypothesis → Change → Measurement → Conclusion (brief item 4)

Recorded in `results/tables/e4_before_after.csv`; the chart is on the slide. Baseline: one queue pair
per NCCL connection (NCCL's default) on the RDMA path, four rails, GPUDirect on. Hypothesis, written
before the run: the rails have headroom, one queue pair serialises each flow, so two or four queue pairs
with the data split across them should raise large-message bandwidth, at the cost of more
out-of-order delivery. Change: that variable only, 1 → 2 → 4, five repeats per cell at three sizes.
Measurement: 2 queue pairs −4 / −9 / −8 %; 4 queue pairs −19 / −32 / −29 %, statistically clear at every
size (Welch's t-test across repeats). The counter window at four queue pairs shows each rail at 338
instead of 482 Gb/s with reordering and congestion counters still at zero. Conclusion: the headroom is
real but this knob cannot reach it — splitting each message across queue pairs shrinks each work
request and multiplies completions; it helps on fabrics where a single flow cannot fill a link, which a
two-tray rail path is not. Keep the default. A negative result, reported as one.

Then the knob that did help the workload: DDP gradient buckets 25 → 200 MiB over the rails gave
2090 → 2769 samples/s (+32 %) and cut the communication share of a step from 91 % to 32 %. That is the
small-message finding applied: fewer, larger exchanges. Other measured knobs, for questions:
GPUDirect off −38 % (same bytes on the wire, 1.6× the time); NVLS vs Ring on NVLink 474 vs 388 GB/s;
NCCL buffer size no effect; Tree not a valid setting for this collective set; more socket threads 7×
on TCP, still far below RDMA. Two settings are deliberately fixed rather than tuned: the GID index is
discovered, and `NCCL_P2P_NET_CHUNKSIZE` is left unset on the RDMA path (an earlier record: with it set,
queue pairs connected but no bytes moved).

## 5. Dashboard walkthrough (about 4 minutes) — *Compass — NCCL fabric counters*

Panels top to bottom; the node variable on "All" shows both workers.

1. **NVLink bytes per GPU** (from the host NVLink exporter, summed over links): about 240 GB/s per GPU
   during the NVLink cell, flat during RDMA. Say: the topology decides the path — inside an NVLink domain
   the collective never touches a NIC.
2. **PCIe bytes, SM active, power, clocks** (from DCGM): SM activity is low during a pure collective;
   in the training cells the gap to 100 % is time spent waiting on communication. On GB300 the GPU
   reaches host memory over C2C, so even the GPUDirect-off run does not show up as GPU PCIe bytes.
3. **Rail transmit and receive rate** (from the host RDMA exporter, bytes on the wire × 8): four rails
   at about 480 Gb/s in the RDMA cell, one rail in the rails1 cell, zero in the NVLink cell.
4. **Congestion (CNPs, ECN marks) and reliability (out-of-sequence, sequence errors, ACK timeouts,
   adaptive retransmissions)**: flat in every cell. This is the evidence that the ceiling is not the
   network, and the panel to check first when a training job slows down.
5. **RoCE slow restarts, ICRC errors, transmit wait**: flat.
6. **Management NIC throughput and host CPU in softirq/system**: only the TCP cells appear here. RDMA
   and NVLink cost the host CPU nothing; TCP pays per byte.

How the data gets there: a Terraform-managed Grafana Alloy collector in the cluster scrapes the
exporters the site already runs on every tray (node, DCGM, RDMA, NVLink, PCIe) and ships to Grafana
Cloud with a per-tenant push token that Terraform minted. Nothing was installed on the trays for this.

## 6. Extending to production (brief item 5), and closing

The manifests scale by node count: one pod per tray, one GPU claim and one rail claim per pod. Inside
an NVLink domain use NVLink; between domains budget for the rails and size the gradient buckets
accordingly. The counters shown become alerts: a fabric run whose NCCL log shows a TCP fallback is a
failure, not a slow run; congestion or sequence errors per rail are the network's signal; a rail below
its share of line rate during a known-good collective is a rail fault. Floors must be calibrated per
rank count and message size because bus bandwidth is not constant in either.

Teardown when done: `(cd infra/k8s_bootstrap && bin/k8s-down --yes)`, about 3 minutes, which also
verifies the trays are back to their pre-lease state.

## If something goes wrong live

- **A cell fails its pre-check** (`PRECHECK-FAILED` in the pod log): the reason is on that line — how
  many GPUs or rails the pod saw, or that no address arrived on a rail. Delete the Job and re-run the
  cell; the results for the slides are already committed, so the story does not change.
- **The dashboard shows nothing**: check `kubectl -n ktlo-monitor get pods` (the collector) and that
  the time range is "last 15 minutes". The counters are also in the run's `counters.<node>.csv`, and
  `python -m analysis results/raw` draws them.
- **No cluster**: everything from section 3 onward runs from `results/`. `make analyze` regenerates
  every table and chart; `make slides` rebuilds the deck.
