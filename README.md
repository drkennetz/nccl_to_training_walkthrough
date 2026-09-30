# compass_takehome — distributed communication on a GB300 pair: measure, diagnose, one change, prove

A reproducible NCCL / PyTorch benchmark environment on two NVIDIA GB300 trays (4 GPUs + 4 RDMA rails
each) in Kubernetes: an all-reduce sweep across three transports (multi-node NVLink, RoCE v2 RDMA,
TCP), a DDP training workload at 1 → 8 GPUs with scaling efficiency, the counters behind every number
(NVLink/PCIe bytes, per-rail RoCE bytes, congestion and reliability counters, per-rank spread), and
**one** controlled optimization — `NCCL_IB_QPS_PER_CONNECTION` on the RDMA path — reported as
Baseline → Hypothesis → Change → Measurement → Conclusion.

The 30-minute deck is `slides/compass.pptx` (built from the results, never typed); the numbers are in
[`results/SUMMARY.md`](results/SUMMARY.md) and the raw, schema-validated JSON under `results/raw/`.

## Layout

| path | what |
|---|---|
| `bench/` | the only code in the image: `allreduce` (sweep), `ddp` (workload), `watcher` (1 Hz counters), `gid` (RoCE GID discovery), `sysinfo`; pure helpers in `bench/common/`; `bench/schema/result.schema.json` |
| `deploy/k8s/` | `matrix.yaml` (every run cell, the single source of truth) → `render.py` → `rendered/<run_id>/manifests.yaml` (committed, drift-checked in CI); `run_matrix.sh` (resumable runner), `collect.py`, the dranet values/DeviceClass, the one-rail probe |
| `deploy/terraform/` | `onboard/` ships the cluster's host exporters to Grafana Cloud (Alloy, per-tenant token); `dashboards/` provisions `deploy/grafana/dashboards/compass-nccl-fabric.json` |
| `analysis/` | `results/raw` → tables (`e4_before_after.csv` carries the Welch p-values), PNG charts, `SUMMARY.md`, the README block below |
| `slides/` | `outline.yaml` (words) + `build_slides.py` (python-pptx) → `compass.pptx` |
| `infra/k8s_bootstrap/` | the cluster bring-up (git subtree) — see [docs/cluster-bootstrap.md](docs/cluster-bootstrap.md) |
| `docs/` | [cluster-bootstrap.md](docs/cluster-bootstrap.md), [gid-discovery.md](docs/gid-discovery.md) |
| `tests/` | pytest, no GPU, torch never imported: bandwidth math, size/iteration schedule, NCCL transport-log parser, GID table logic on a fake sysfs, schema, manifest renderer, watcher parsers, counter rates, analysis tables and charts, deck |
| `.github/workflows/ci.yml` | lint · test · render-check · terraform-validate · analysis-smoke · **image** (arm64) → `ghcr.io/drkennetz/compass_takehome:<tag>`, mirrored to `quay.io/drkennetz/ktlo-labs:compass-<tag>` |

## Design in one paragraph

Every run is one Indexed Job (one pod per tray, `torchrun --nnodes=2 --nproc_per_node=4`, rendezvous
through a headless Service) on the **pod network — no `hostNetwork` anywhere**. GPUs come from the
NVIDIA DRA driver (`ResourceClaim` on DeviceClass `gpu.nvidia.com`). Rails come from a dranet fork as
**IPVLAN children** of the rail VFs while the host runs the RDMA subsystem in *shared* netns mode: the
VF, its address and its RDMA device never leave the host (the site's node health check keeps seeing
them), and the pod gets a child interface with its own SLAAC address plus the device's char devices.
The transport is chosen per cell by NCCL environment only: MNNVL on through the IMEX channel for the
NVLink cells, `NCCL_MNNVL_ENABLE=0` + `NCCL_IB_HCA=<claimed rails>` for RDMA, `NCCL_IB_DISABLE=1` for
TCP (over the overlay, or over one rail's child to compare Ethernet and RoCE on the same wire). The
transport actually used is **proven** from NCCL's own channel report (`via P2P/MNNVL`, `via
NET/IB/…/GDRDMA`, `via NET/Socket`) counted per rank and recorded next to the bandwidth; a run whose
fabric cell fell back to sockets is a failure, not a slow result.

## Reproduce

```bash
make venv && make test                       # unit tests (no GPU)
make render-check                            # manifests match matrix.yaml
scripts/cluster-up.sh --rack <block>/<rack> --dranet-src <dranet checkout>   # lease, k3s, GPU DRA, dranet, probe
make image-push                              # or let CI publish; then pin the digest
COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --image <ref@sha256:…>   # every cell, resumable
make analyze && make slides                  # tables, charts, SUMMARY.md, the deck
```

`run_matrix.sh --only 'e4-*'` runs a subset; a cell whose `results/raw/<run_id>/result.json` exists is
skipped. Each cell starts a counter watcher pod per worker, applies the cell, waits, collects
(`result.json`, `ranks.csv`, every pod log, `counters.<node>.csv`), tears down, settles.

### The experiment matrix (`deploy/k8s/matrix.yaml`)

| id | what | ranks / path |
|---|---|---|
| `e1-nvlink`, `e1-rdma`, `e1-tcp`, `e1-tcprail` | all-reduce 1 MiB → 8 GiB (TCP at three sizes) | 2×4 over MNNVL · 4 rails RDMA · TCP on the overlay · TCP on one rail |
| `e1-*-small` | 4 KiB → 1 MiB, the latency floor | NVLink, RDMA |
| `e2-rails{1,2,4}` | rails claimed per tray | RDMA at 16 MiB / 512 MiB / 4 GiB |
| `e3-g{1,2,4}`, `e3-g8-{nvlink,rdma}` | DDP GPT-124M on synthetic tokens; samples/s, comm fraction from `torch.profiler` | 1 tray → 2 trays |
| `e4-qps{1,2,4}-r{0..4}` | **the optimization**, 5 repeats each | RDMA, `NCCL_IB_QPS_PER_CONNECTION` (+ `SPLIT_DATA_ON_QPS`) |
| `e5-*` | sensitivity: `NCCL_BUFFSIZE`, GPUDirect off, `NCCL_ALGO`, socket threads | appendix |

### What is measured, and from where

- **Bandwidth** — `busbw = bytes · 2(n−1)/n / t` (the collective-benchmark convention), from CUDA event pairs per iteration on *every* rank; the per-rank spread and the slowest rank are recorded, not averaged away.
- **Transport** — NCCL INIT/GRAPH channel lines per rank (`NCCL_DEBUG_FILE`), gathered before teardown.
- **Fabric counters** — `/sys/class/infiniband/<rail>/ports/1/{counters,hw_counters}` (bytes, `port_xmit_wait`, `out_of_sequence`, `packet_seq_err`, CNPs, ECN marks), `ethtool -S` pause frames and `rx_out_of_buffer`, DCGM profiling fields (NVLink TX/RX, PCIe TX/RX, SM active). Sampled at 1 Hz by the watcher, joined to the run's phase markers; shipped live to the Grafana Cloud dashboard *Compass — NCCL fabric counters*.
- **Topology / versions** — `nvidia-smi topo -m`, sysfs `ibdev2netdev`, `rdma link`, NUMA node per GPU, the GID table, torch/CUDA/NCCL/driver versions, the image digest and every `NCCL_*` variable in force — all inside `result.json`.

## Notes that changed the design

- **Never move a rail VF into a pod on this site.** A passthrough claim removes the VF from the host; the site's health check then drains and reboots the tray (three racks lost on 2026-09-24 in earlier work). IPVLAN + shared RDMA netns mode is the answer; the mode has to be set *before* k3s exists (details in [docs/cluster-bootstrap.md](docs/cluster-bootstrap.md)).
- **The RoCE GID index is discovered, not assumed** — it is 3 on the host and 7 inside the pod ([docs/gid-discovery.md](docs/gid-discovery.md)).
- **`NCCL_P2P_NET_CHUNKSIZE` stays unset on the RDMA path** (an earlier record: connected QPs, zero bytes on the wire when set).
- **`rx_queue_len` / NIC ring size is not a knob here**: RDMA bypasses the kernel receive path, so it can only move the TCP cells; the NIC's own buffers (`rx_out_of_buffer`, pause frames) are what the RDMA path shows.

<!-- results:start -->
_Results are written here by `make analyze`._
<!-- results:end -->
