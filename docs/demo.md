# Demo runbook — a 30-minute walkthrough that follows the brief

The brief asks for five things in the presentation: architecture and design choices; baseline and
scaling results; a bottleneck diagnosis that separates evidence from diagnosis; one optimization with
before/after evidence (Baseline → Hypothesis → Change → Measurement → Conclusion); and how the design
extends to multi-node production. This runbook is organised in that order. Every number quoted is in
`results/SUMMARY.md` and comes from a committed `result.json`.

## Overview — what I am going to run, and why

Two groups of experiments, all launched the same way (one Kubernetes Job per experiment from
`deploy/k8s/matrix.yaml`, run by `deploy/k8s/run_matrix.sh`, results collected into `results/raw/<id>/`):

**To prove out the network and the tuning** (slides 4, 5, 8, 9, 10):
- `e1-nvlink`, `e1-rdma`, `e1-tcp`, `e1-tcprail` — the same 8-GPU all-reduce over the three transports, 1 MiB → 8 GiB (slide 4)
- `e1-nvlink-small`, `e1-rdma-small` — the same collective from 4 KiB to 1 MiB, to show the fixed cost per operation (slide 5)
- `e2-rails1`, `e2-rails2`, `e2-rails4` and the `e5-counters-*` windows — the RDMA path with 1, 2 and 4 rails, plus sustained runs whose only purpose is to read the NIC, NVLink and PCIe counters (slide 8)
- `e4-qps1-r*`, `e4-qps2-r*`, `e4-qps4-r*` — the one controlled optimization, `NCCL_IB_QPS_PER_CONNECTION`, five repeats per setting (slide 9)
- `e5-buffsize*`, `e5-gdr-off`, `e5-algo-*`, `e5-sock-nthreads4` — the other knobs (slide 10)

**To prove out performance and scaling of a real workload** (slides 6, 7, 10):
- `e3-g1`, `e3-g2`, `e3-g4` — DDP training of a 124M-parameter GPT on 1, 2 and 4 GPUs of one tray
- `e3-g8-nvlink`, `e3-g8-rdma` — the same training on 8 GPUs across both trays, over NVLink and over the rails (slide 7)
- `e5-ddp-bucket200` — the same 8-GPU RDMA run with 200 MiB gradient buckets instead of 25 (slide 10)

Every cell takes about one minute (the training cells slightly more; the 15 optimization repeats about
25 minutes together). All 41 are committed under `results/raw/`; in the live session I re-run a few and
show the rest from the recorded results, which the commands below regenerate identically.

The generic form for any cell, and what it does:

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only <id-or-glob> --image "$(cat .image-digest)"
#   starts a watcher pod on each worker, applies deploy/k8s/rendered/<id>/manifests.yaml (one Indexed Job,
#   one pod per tray, torchrun x 4 ranks), waits, collects result.json + ranks.csv + pod logs + counters into
#   results/raw/<id>/, deletes the Job, settles 20 s. A cell whose result.json exists is skipped —
#   `rm -rf results/raw/<id>` to force a re-run. `--only 'e4-qps1-*'` runs a group.
kubectl -n compass logs -f job/compass-<id>        # in a second terminal: pre-check, PHASE and PERF lines as they happen
python -m analysis results/raw && python -m slides   # tables, charts, SUMMARY.md and the deck from whatever has run
```

### How the runbook maps onto the deck (`slides/compass.pptx`, 11 slides, speaker notes on each)

| minutes | runbook section | slide(s) | what is on screen |
|---|---|---|---|
| 0–2 | opening | 1 (title) | the deck |
| 2–9 | §1 architecture, while the cluster comes up | 2 (architecture diagram), 3 (DRA, dranet, Cilium) | deck + a terminal running the bring-up |
| 9–11 | §2 the probe and the GID index | 3 (its last bullet) | terminal only: `scripts/demo-gid.sh` |
| 11–18 | §3 baseline, small messages, the training workload, scaling | 4, 5, 6 (pause: how DDP works), 7 | deck; a terminal running the three live cells in the background |
| 18–22 | §3 diagnosis | 8 | deck + the dashboard |
| 22–25 | §4 the optimization and the other knobs | 9, 10 | deck |
| 25–28 | §5 dashboard walkthrough | 8 again | the dashboard |
| 28–30 | §6 production and close | 11 | deck |

Code pointers used below: the training application is **`bench/ddp_train.py`** (its `main()` is the whole
flow); the all-reduce benchmark is **`bench/allreduce.py`**; the GID discovery is **`bench/gid.py`**; the
counter watcher is **`bench/watcher.py`**. Each is walked step by step in
[`docs/code-flow.md`](code-flow.md).

Each slide's notes open with a "Bridge from …" paragraph that says how the previous experiment led to
this one; read those bridges aloud when moving between slides, they are the narrative.

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
export DRANET_SRC=$HOME/dkennetz/dranet                    # a clone of dkennetzoracle/dranet, branch slaac-addressing (commit c70a33c is what the image was built from)
cat .image-digest                                          # the exact image the committed results were produced with
```

Open two browser tabs: the dashboard
`https://wittysquash3587.grafana.net/d/compass-nccl-fabric` (time range "last 15 minutes", refresh
10 s, node variable "All") and the GitHub Actions page of the repo (the latest run is green: lint, tests,
manifest check, Terraform validation, analysis smoke run, image build and publish to ghcr.io).

Checklist: `(cd infra/k8s_bootstrap && bin/k8s-status)` lists an idle rack; the deck opens; you can
`less results/SUMMARY.md`. If a cluster is already up from earlier, start at section 2.

## 1. Architecture and design choices — talk while the cluster comes up (about 7 minutes) — slides 2 and 3

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

Slide 2 is the architecture diagram; its notes carry the four sentences to say about it. Slide 3 is
DRA, dranet and Cilium. The paragraphs below expand both for questions.

**The hardware and the three networks** (slide 2). Two GB300 trays; each has four GPUs joined by NVLink, four
ConnectX-8 rails (one per GPU), and two Grace CPUs. The two trays are in the same NVLink domain, so
GPUs in different trays can talk over NVLink as well as over the rails. That gives us three ways to
run the same collective: NVLink, RDMA over the rails, and TCP. The brief says not to assume the network
is the problem; measuring all three paths is how we avoid assuming.

**Why Kubernetes, and why a two-tray lease** (slide 2 notes). The brief cares about reproducibility, not the
scheduler. Kubernetes gives us declarative manifests that are committed and drift-checked in CI, a
scheduler that allocates GPUs and NICs as devices, and one container image that CI builds and
publishes to ghcr.io. Two trays are enough for every question asked (two ranks, two nodes, NVLink
versus RDMA), so we leased two workers rather than a rack. The trays are borrowed from a shared Slurm
pool, which is why the bootstrap snapshots every node before touching it and proves it identical after
teardown — nothing is installed in system paths, and no host daemon is changed.

**Why DRA rather than the device plugin** (slide 3, first three bullets). With the device plugin a node advertises an opaque count
(`nvidia.com/gpu: 4`); a pod can ask for a number of GPUs and nothing else. With DRA the cluster
publishes every device with its attributes and a pod writes a claim against a device class. Show
`kubectl get resourceslices -o yaml | head -60`: the GPUs with UUIDs and memory, and the rails with
their interface name, RDMA flag and PCI address. The point that matters for this exercise: GPUs and
NICs are claimed the same way, in the same pod spec, so a pod can ask for "4 GPUs and 2 rails" and we
can vary the rail count per experiment without touching the host. Show the two claims in
`deploy/k8s/rendered/e2-rails2/manifests.yaml`.

**Why dranet, and why a fork of it** (slide 3, last bullet). dranet is the driver that publishes NICs through DRA. Upstream
gives a pod a NIC by moving it into the pod's network namespace. On this site the node health check
inventories the rails on the host; a moved rail reads as a broken node and the tray gets drained and
rebooted (that happened to three racks in earlier work). The fork adds an IPVLAN mode: the rail stays
on the host with its address and routes, and the pod gets a child interface with its own address. For
RDMA to work that way the host's RDMA subsystem must run in "shared" namespace mode, which the kernel
only lets you set when no container namespace exists — so the bootstrap sets it on the freshly
leased node before installing k3s and restores it at teardown. Decisions we made and why: no pod runs
with host networking, no pod is privileged, and the host's view of its NICs never changes.

**Why Cilium, and which settings matter here** (slide 2, the middle band of the diagram) (`infra/k8s_bootstrap/platform/cilium/values.yaml`).
Cilium is the pod network. It replaces kube-proxy with eBPF (no iptables rules churned on a host whose
health check watches routing), it tunnels pod traffic over the management NIC with geneve so the site
network never has to learn pod addresses (no BGP, no LoadBalancer IPs, both site rules), and Hubble
shows flows. The important design point: the pod network carries only the rendezvous and NCCL's
bootstrap handshake; the collective's data goes over NVLink or the rails. The "TCP over the overlay"
result (4 GB/s) is the measured reason.

## 2. Prove the design before benchmarking (1 minute warm, 5 minutes on a cold tray) — terminal, no slide

```bash
kubectl apply -f deploy/k8s/probe/probe-rails.yaml
kubectl -n compass wait --for=condition=Ready pod -l app=probe-rail --timeout=600s
scripts/demo-gid.sh
kubectl delete -f deploy/k8s/probe/probe-rails.yaml
```

`demo-gid.sh` (which calls `bench/gid.py`; flow in
[`docs/code-flow.md`](code-flow.md#the-gid-discovery--benchgidpy-see-also-docsgid-discoverymd)) prints three
things. First, the host's view of the rail's address table: two entries
per IP address (one per RoCE version), link-local at indexes 0 and 1, the rail's global address at 2
and 3. Then the pod's view of the same NIC: the pod's own child interface has its own address, which
lands at indexes 4 to 7, and the tool picks **index 7**, the RoCE v2 entry with a routable address. It
also shows that the host still owns the rail (same address, four RDMA links) while the pod is using it.
Finally, it runs `ibv_rc_pingpong` between the two probe pods on that index: about 12 to 15
microseconds per 4 KiB round trip, about 120 microseconds per 1 MiB.

What to say (this ties back to slide 3's last bullet, the shared RDMA namespace mode): most recipes
hard-code the GID index to 3. Inside our pods that would fail, because the
pod's address is a later entry. So every RDMA run discovers the index from the address table
(`python -m bench gid`), after first soliciting the router for an address — a fresh pod only has a
link-local address until a router advertisement arrives. This is a small example of the brief's
"separate evidence from diagnosis": we read the table instead of assuming.

## 3. Baseline, scaling and diagnosis — the experiments behind slides 4 to 8

Each block below is the exact command that produced the slide's numbers, with the measured wall
time per cell. In the live session run the three counter windows (they are the ones the dashboard
shows best); everything else is already in `results/raw/` and the slides are built from it.

**Slide 4 — baseline, the size sweep over three transports** (about 1 min per cell)

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e1-nvlink  --image "$(cat .image-digest)"   # MNNVL on, no rails
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e1-rdma    --image "$(cat .image-digest)"   # MNNVL off, 4 rails, GPUDirect
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e1-tcp     --image "$(cat .image-digest)"   # NCCL_IB_DISABLE=1 over the pod overlay
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e1-tcprail --image "$(cat .image-digest)"   # NCCL_IB_DISABLE=1 over one rail's child
grep -h '^PERF' results/raw/e1-rdma/pod-0.log | head -3                                                   # one line per size: busbw, spread, slowest rank
grep -h '^TRANSPORT' results/raw/e1-rdma/pod-0.log                                                        # the proof: 640 NET/IB GDRDMA channels, 0 NET/Socket
```

**Slide 5 — the latency floor** (about 45 s per cell; 4 KiB → 1 MiB, 200 iterations per size)

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e1-nvlink-small --image "$(cat .image-digest)"
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e1-rdma-small   --image "$(cat .image-digest)"
```

**Slide 6 — the training workload** is a diagram, nothing to run; the application is `bench/ddp_train.py`.

**Slide 7 — scaling the training workload** (about 1 min per cell; 10 warm-up + 50 timed steps + a profiler window)

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e3-g[124]'  --image "$(cat .image-digest)"   # 1, 2, 4 GPUs on one tray
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e3-g8-*'    --image "$(cat .image-digest)"   # 8 GPUs over NVLink, then over the rails
grep -h '^PERF' results/raw/e3-g8-*/pod-0.log                                                            # samples/s, step time, comm fraction
```

**Slide 8 — diagnosis: rails and counters** (about 1 min per cell)

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e2-*'          --image "$(cat .image-digest)"   # 1, 2, 4 rails at 16 MiB / 512 MiB / 4 GiB
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e5-counters-*' --image "$(cat .image-digest)"   # ~10 s sustained 4 GiB all-reduce per cell, for the counters
cat results/raw/e5-counters-rails1/counters.per-phase.csv | grep timed | grep port_xmit_data                  # bytes per second on each rail during the window
```

The host-side facts on slide 8 come from these read-only commands on a worker (they are quoted in the
notes; run them once so you have seen them):

```bash
ssh GPU-3UWOQ-6G3YA-1 'cat /sys/class/infiniband/rdma_vf_rail0/ports/1/rate'                     # "200 Gb/sec (2X NDR)" — one plane
ssh GPU-3UWOQ-6G3YA-1 'ls /sys/class/net | grep -E "^rdma_p[0-3]_rail0$"'                         # the four physical planes behind rail 0
ssh GPU-3UWOQ-6G3YA-1 'x=$(cat /sys/class/infiniband/rdma_vf_rail0/ports/1/counters/port_xmit_data); echo $((x*4)); ethtool -S rdma_vf_rail0 | grep tx_vport_rdma_unicast_bytes'   # sysfs x4 == ethtool bytes
ssh GPU-3UWOQ-6G3YA-1 'sudo lspci -vv -s 0000:03:00.0 | grep LnkSta; nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv,noheader'   # Gen6 x16 on NIC and GPU
ssh GPU-3UWOQ-6G3YA-1 'nvidia-smi topo -m | head -6'                                              # GPU–NIC relation: NODE (through the Grace socket)
```

If you run only three cells live, make them `e5-counters-nvlink`, `e5-counters-rdma` and
`e5-counters-rails1` (`rm -rf results/raw/e5-counters-*` first if they should really re-run): while each
runs, `kubectl -n compass logs -f job/compass-<id>` shows the pre-check (which rails the pod got, their
addresses appearing, the address table with `<-- chosen`), then a `PHASE` line when the timed loop starts
and a `PERF` line with the bandwidth. Switch to the dashboard between cells: rails idle during the NVLink
cell, about 480 Gb/s on each of the four rails during the RDMA cell, one rail at about 410 Gb/s in the
rails1 cell.

### What to say, tied to the recorded results

**Baseline (brief item 2) — slide 4, then slide 5 for the small-message floor.** The code that produced
these numbers is `bench/allreduce.py`; its flow (sizes → warm-up → CUDA-event-timed loop → correctness
on a fresh tensor → per-rank gather → NCCL log parse → `result.json`) is in
[`docs/code-flow.md`](code-flow.md#the-all-reduce-benchmark--benchallreducepy). If someone asks "how do
you know it used NVLink", the answer is step 6 of that flow. Same 8-GPU all-reduce over three paths, 1 MiB to 8 GiB. NVLink reaches
835 GB/s bus bandwidth; the four rails about 425 GB/s; TCP on one rail 118 GB/s; TCP on the pod
overlay 4 GB/s. Below a few MiB every path costs about the same 20 to 80 microseconds — fixed costs,
not data. Which path was used is not inferred from the speed: every result records NCCL's own
connection log (256 NVLink channels, or 640 RDMA channels with GPUDirect, or socket channels).

**The training workload — slide 6, a deliberate pause.** Before the scaling numbers, the diagram of one
DDP step: eight processes each hold the whole 124M-parameter model, compute gradients on their own
batch, average them with an all-reduce (in about 19 buckets of 25 MiB), and apply the same optimizer
step. Inside a tray the averaging travels over NVLink; between trays over whichever transport the
experiment selects. The application is `bench/ddp_train.py` — `main()` there is the entire flow, about
260 lines — and [`docs/code-flow.md`](code-flow.md#the-training-application--benchddp_trainpy) walks it
step by step (where DDP is wrapped, where the step is timed, where the profiler measures the
communication share, where the transport is proven).

**Scaling (brief item 2) — slide 7.** Its notes lead with the DDP bucket size (25 MiB default, about 19
all-reduces per step) and why that size lets the two comparisons separate wire speed from per-collective
fixed cost. The training workload — a 124M-parameter GPT with PyTorch DDP — runs at 1,
2, 4 GPUs on one tray and 8 across two. Efficiency 93 % at 2, 78 % at 4, 92 % at 8 over NVLink, 69 % at
8 over the rails. The profiler shows communication taking most of the step at this model size.

**Diagnosis (brief item 3), evidence first — slide 8.** The counters behind this slide come from
`bench/watcher.py` (one sample per second per tray; flow in
[`docs/code-flow.md`](code-flow.md#the-counter-watcher--benchwatcherpy)) joined to the benchmark's
phase markers by `analysis/counters.py`. Bandwidth on the RDMA path scales with the number of
rails: 96, 207, 364 GB/s at 1, 2, 4 rails. The bytes the NIC counted on the wire equal the theoretical
minimum for a two-node all-reduce, and a single rail carried 411 Gb/s — impossible on a 200 Gb/s link,
so a rail is really four 200 Gb/s planes, 800 Gb/s (the physical ports `rdma_p0..p3_rail0` are on the
host; sysfs reports one plane). The rails therefore ran at 51 to 60 % of capacity. Congestion and
reliability counters stayed at zero. Both NIC and GPU negotiate PCIe Gen6 x16. So: not the wire, not
congestion, not PCIe. The diagnosis, kept apart: the remaining suspect is the per-rail injection path
(one NCCL connection per GPU–NIC pair, GPUDirect across the Grace socket), stated as a hypothesis with
the next experiment named. The 1-to-4-GPU drop on one tray involves no NIC at all — that one is model
size and launch overhead, and saying so is the point.

## 4. The optimization — Baseline → Hypothesis → Change → Measurement → Conclusion (brief item 4) — slide 9

**Commands (slide 9)** — 15 cells, about 1 min each; the three settings are three matrix entries that
differ only in `NCCL_IB_QPS_PER_CONNECTION` (and `NCCL_IB_SPLIT_DATA_ON_QPS=1` for 2 and 4), each with
`repeats: 5`, which the renderer expands to `-r0 … -r4`:

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e4-qps1-*' --image "$(cat .image-digest)"   # baseline, 5 repeats
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e4-qps2-*' --image "$(cat .image-digest)"
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e4-qps4-*' --image "$(cat .image-digest)"
python -m analysis results/raw && cat results/tables/e4_before_after.csv                                  # mean, std, delta %, Welch p per size and setting
grep -A2 'e4-qps' deploy/k8s/matrix.yaml | head -12                                                        # show that only the one variable changes
```

Live, run one repeat of the baseline and one of QPs=4 (`--only e4-qps1-r0`, `--only e4-qps4-r0`, about
2 minutes) and compare their `PERF` lines at 4 GiB; the five-repeat statistics come from the recorded
runs.

**Commands (slide 10)** — the other knobs, about 1 min each:

```bash
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e5-buffsize*'    --image "$(cat .image-digest)"   # NCCL_BUFFSIZE 4 / 16 MiB
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-gdr-off        --image "$(cat .image-digest)"   # NCCL_NET_GDR_LEVEL=0
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only 'e5-algo-*'       --image "$(cat .image-digest)"   # Ring / Tree / NVLS on NVLink (Tree fails: invalid for the all-gather)
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-sock-nthreads4 --image "$(cat .image-digest)"   # TCP with more socket threads
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --only e5-ddp-bucket200  --image "$(cat .image-digest)"   # the DDP bucket change, twin of e3-g8-rdma
cat results/tables/e5_sensitivity.csv results/tables/e5_ddp_bucket.csv
```

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

Then slide 10, the knob that did help the workload: DDP gradient buckets 25 → 200 MiB over the rails gave
2090 → 2769 samples/s (+32 %) and cut the communication share of a step from 91 % to 32 %. That is the
small-message finding applied: fewer, larger exchanges. Other measured knobs, for questions:
GPUDirect off −38 % (same bytes on the wire, 1.6× the time); NVLS vs Ring on NVLink 474 vs 388 GB/s;
NCCL buffer size no effect; Tree not a valid setting for this collective set; more socket threads 7×
on TCP, still far below RDMA. Two settings are deliberately fixed rather than tuned: the GID index is
discovered, and `NCCL_P2P_NET_CHUNKSIZE` is left unset on the RDMA path (an earlier record: with it set,
queue pairs connected but no bytes moved).

## 5. Dashboard walkthrough (about 4 minutes) — *Compass — NCCL fabric counters* — return to slide 8

The dashboard is the live version of slide 8's evidence table: the same counters, on the same trays,
while the three cells from section 3 run.

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

## 6. Extending to production (brief item 5), and closing — slide 11

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
