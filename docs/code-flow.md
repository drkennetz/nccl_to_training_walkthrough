# Code flow — what each Python component does, step by step

Every path is relative to the repository root; line numbers are from the committed code and are
close, not exact, if the file changes. The training application's entrypoint is
**`bench/ddp_train.py`** (`main()` at line 73); the all-reduce benchmark's is **`bench/allreduce.py`**
(`main()` at line 63). Both are launched inside the pod by `torchrun`, one process per GPU, from the
command rendered in `deploy/k8s/fragments/job.yaml.j2`. `python -m bench <name>` dispatches to them
(`bench/__main__.py`).

## The training application — `bench/ddp_train.py`

What it is: PyTorch DistributedDataParallel (DDP) training of a small GPT (`bench/model.py`, 124M
parameters) on synthetic tokens, instrumented so a run yields throughput, scaling efficiency, the
communication share of a step, and proof of which transport carried the gradients.

| step | where | what happens |
|---|---|---|
| 0 | top of file | sets `NCCL_DEBUG_FILE` **before** importing torch, so NCCL writes its per-rank connection log to a file we can read later |
| 1 | `parse_args` (l.28) | steps, warm-up, profile window, per-GPU batch, sequence length, model size, `--bucket-cap-mb` (the DDP bucket size, default 25) |
| 2 | `main` (l.73–96) | picks the GPU from `LOCAL_RANK`; if more than one process, `init_process_group("nccl")` (l.86) joins the eight ranks through the rendezvous address torchrun was given; builds the model with a fixed seed so every rank starts identical; wraps it in `DDP(model, bucket_cap_mb=…)` (l.95) |
| 3 | `step()` (l.99) | one training step: draw a synthetic batch, forward under bf16 autocast, loss, `backward()` — during backward DDP's reducer fills gradient buckets and launches one NCCL all-reduce per full bucket, overlapping with the remaining backward compute — clip, `optimizer.step()`, zero grads. With one process there is no DDP wrapper and no communication |
| 4 | l.113 | `all_gather_object` of each rank's identity (host, GPU) so the result records who ran where |
| 5 | warm-up loop | `--warmup` steps not timed (CUDA graphs, allocator, NCCL connections settle) |
| 6 | timed loop | `--steps` steps, each bracketed by a pair of CUDA events on **every rank**; step time is GPU-measured, not wall-clock |
| 7 | l.142–147 | a short `torch.profiler` window (`--profile-steps`), then `comm_fraction_from_profile` (l.51) sums the CUDA time of kernels whose name contains "nccl" against the step time → the communication share (an upper bound: NCCL kernels overlap compute) |
| 8 | l.164–166 | every rank's per-step times and its parsed NCCL log are gathered to rank 0 **before** the process group is destroyed |
| 9 | rank 0, l.180–260 | computes samples/s, step statistics, the transport classification (`bench/common/nccl_log.py`), records versions and topology (`bench/sysinfo.py`), the GID table if rails are present (`bench/gid.py`), and writes `result.json` (schema-validated by `bench/common/results.py`) plus `ranks.csv` with one row per rank per step |

Why it uses the network: each rank trains on different data, so its gradients differ; the
optimizer on every rank must apply the *average* over all eight, otherwise the eight model copies
drift apart. That average is the all-reduce — 475 MiB of fp32 gradients per step, in about 19
buckets at the default 25 MiB. Within a tray the all-reduce rides NVLink; between the two trays it
rides whatever the cell's environment selects: multi-node NVLink, the RDMA rails, or TCP.

## The all-reduce benchmark — `bench/allreduce.py`

What it is: the raw collective the training step depends on, measured on its own across message
sizes so the training numbers can be interpreted.

| step | where | what happens |
|---|---|---|
| 0 | top of file | `NCCL_DEBUG_FILE` set before importing torch (same reason as above) |
| 1 | `parse_args` (l.34) | `--sizes 1Mi:8Gi` (geometric sweep, `bench/common/sizes.py`) or a list; iterations and warm-up per size default to a size-dependent schedule (`bench/common/schedule.py`) so each size takes about the same time |
| 2 | `main` (l.63–84) | optional pre-check that the expected number of rail NICs is visible; `init_process_group("nccl")`; identity gather |
| 3 | `for nbytes in sizes` (l.88) | allocate a bf16 tensor of that size on the GPU; warm-up all-reduces; then the timed loop with a CUDA event pair around every all-reduce on every rank (l.105); phase markers (`PHASE {…}` lines, `bench/common/phases.py`) are printed at the start and end of the timed loop so the counter watcher's samples can be joined to it |
| 4 | l.114–118 | correctness on a **fresh** tensor of ones: after an all-reduce every element must equal the world size; the flag is gathered from every rank |
| 5 | l.122 | per-rank timings gathered to rank 0; `bench/common/timing.py` computes mean, p50, min, max, the spread between the fastest and slowest rank, and names the slowest rank |
| 6 | l.183–187 | each rank parses its own NCCL log (`parse_nccl_log`) counting channel lines — `via P2P/MNNVL`, `via NET/IB/…/GDRDMA`, `via NET/Socket` — and the counts are gathered before teardown; `classify_path` turns them into `nvlink`, `rdma_gdr`, `rdma` or `tcp` |
| 7 | rank 0, l.200–249 | bandwidth per size (`bench/common/bw.py`: algbw = bytes / time, busbw = algbw × 2(n−1)/n), `result.json` + `ranks.csv`, and the four summary lines `TRANSPORT`, `TOPO`, `PERF`, `VALIDATION` as the last output |

## The GID discovery — `bench/gid.py` (see also `docs/gid-discovery.md`)

| step | where | what happens |
|---|---|---|
| 1 | `usable_hcas` (l.123) | which RDMA devices this pod can actually open: the ones whose `uverbs` char device exists in `/dev/infiniband` (in shared RDMA netns mode sysfs lists every host device, but the pod only holds the char devices of its claimed rails) |
| 2 | `read_gid_table` (l.77) | reads `gids/<i>`, `gid_attrs/types/<i>`, `gid_attrs/ndevs/<i>` for the port and classifies each address (`classify_gid`, l.52): link-local, IPv4-mapped, global, unused slot |
| 3 | `pick_index` (l.101) | the RoCE v2 entry with a global address; prefers a match on the pod interface's address or name when given, else the newest (upper devices such as the IPVLAN child are appended after the parent's entries) |
| 4 | `discover` (l.160) | runs 2–3 for every usable HCA and checks they agree, because NCCL takes one `NCCL_IB_GID_INDEX` for all of them |
| 5 | `main` (l.182) | prints the table with `<-- chosen`, or with `--export` prints `export NCCL_IB_GID_INDEX=<i>`; `--wait N` keeps polling while SLAAC finishes; `--list-hcas` prints the usable rails for `NCCL_IB_HCA` |

The pre-check in `deploy/k8s/fragments/job.yaml.j2` calls it in that order: list the usable rails, solicit
the router (`rdisc6`) and wait for a global address on each, then discover and export the index.

## The counter watcher — `bench/watcher.py`

Runs as a plain pod on each worker with the host's `/sys` mounted read-only and the results directory
mounted for collection. `sample_once` (l.242) reads, once a second: RDMA port counters and hardware
counters per rail (`ib_counters`, l.103 — bytes, transmit-wait, out-of-sequence, sequence errors, ACK
timeouts, CNPs, ECN marks), optional `ethtool -S` keys, the DCGM exporter on `:9400` (`dcgm_scrape`,
l.167 — SM active, PCIe bytes, power, clocks) and the NVLink exporter on `:9600` (`nvlink_scrape`,
l.196 — bytes per GPU summed over links). Output is one CSV row per sample to stdout, collected with
`kubectl logs`. `analysis/counters.py` turns the monotonic counters into rates and joins them to the
benchmark's phase markers.

## Around the benchmark

- `deploy/k8s/matrix.yaml` → `deploy/k8s/render.py` → `deploy/k8s/rendered/<run_id>/manifests.yaml`: one
  Indexed Job, a GPU claim template, a rail claim template when rails > 0, a headless Service; CI fails
  if the rendered files are stale.
- `deploy/k8s/run_matrix.sh` (loop at l.50): per cell, start the watchers (`watchers_up`, l.31), apply
  the manifests, poll the Job for Complete or Failed, `collect.py` (l.84), delete, settle.
- `deploy/k8s/collect.py`: pod logs, `result.json` and `ranks.csv` through the watcher's results mount,
  watcher CSVs, schema validation.
- `analysis/` (`python -m analysis results/raw`): `load.py` flattens results, `tables.py` builds the
  E1–E5 tables (Welch's t-test in `e4_before_after`), `charts.py` draws the PNGs, `counters.py` rates
  and phase-joins the watcher CSVs, `summary.py` writes `SUMMARY.md` and the README block.
- `slides/` (`python -m slides`): `outline.yaml` words + notes, `diagram.py` drawings, `build_slides.py`
  assembles the deck from the tables and charts.
