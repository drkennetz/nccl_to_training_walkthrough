"""The representative workload: DDP training of a small GPT on synthetic tokens, at 1..N GPUs.

Per step: CUDA-event timing on every rank; one torch.profiler window sums the time of NCCL
kernels (the all-reduce of the gradient buckets) against the step, giving the communication
fraction the scaling-efficiency argument needs. Works at world size 1 (no DDP wrapper), so the
single-GPU baseline runs the same code path. Rank 0 writes result.json + ranks.csv.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import statistics
import sys

_debug_file = os.environ.setdefault("NCCL_DEBUG_FILE", "/tmp/nccl_debug.%p.log")
_my_debug_file = _debug_file.replace("%p", str(os.getpid())).replace("%h", socket.gethostname().split(".")[0])

from bench import gid as gidmod  # noqa: E402
from bench import sysinfo  # noqa: E402
from bench.common import results as res  # noqa: E402
from bench.common.nccl_log import TransportCounts, classify_path, merge_counts, parse_nccl_log  # noqa: E402
from bench.common.phases import PhaseLog  # noqa: E402


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="bench ddp", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--steps", type=int, default=50)
    ap.add_argument("--warmup", type=int, default=10)
    ap.add_argument("--profile-steps", type=int, default=5)
    ap.add_argument("--batch", type=int, default=8, help="per-GPU batch")
    ap.add_argument("--block", type=int, default=1024)
    ap.add_argument("--n-layer", type=int, default=12)
    ap.add_argument("--n-head", type=int, default=12)
    ap.add_argument("--n-embd", type=int, default=768)
    ap.add_argument("--bucket-cap-mb", type=int, default=25)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--experiment", default="E3")
    ap.add_argument("--run-id", default=os.environ.get("RUN_ID", "adhoc"))
    ap.add_argument("--repeat", type=int, default=int(os.environ.get("REPEAT", "0")))
    ap.add_argument("--variant-json", default=os.environ.get("VARIANT_JSON", "{}"))
    ap.add_argument("--image-ref", default=os.environ.get("IMAGE_REF", ""))
    ap.add_argument("--out", default=os.environ.get("RESULTS_DIR", "/results"))
    return ap.parse_args(argv)


def comm_fraction_from_profile(prof) -> dict:
    """Sum CUDA time of NCCL kernels vs everything, from a torch.profiler key_averages()."""
    nccl_us = total_us = 0.0
    top = []
    for ev in prof.key_averages():
        cuda_us = getattr(ev, "device_time_total", None)
        if cuda_us is None:
            cuda_us = getattr(ev, "cuda_time_total", 0.0)
        if not cuda_us:
            continue
        total_us += cuda_us
        if "nccl" in ev.key.lower():
            nccl_us += cuda_us
        top.append((ev.key[:80], cuda_us))
    top.sort(key=lambda kv: -kv[1])
    return {
        "nccl_kernel_s": nccl_us / 1e6,
        "cuda_kernel_s": total_us / 1e6,
        "top_kernels": [{"name": k, "cuda_s": v / 1e6} for k, v in top[:8]],
    }


def main(argv=None) -> int:
    a = parse_args(argv)
    import torch  # noqa: PLC0415
    import torch.distributed as dist  # noqa: PLC0415
    from torch.nn.parallel import DistributedDataParallel as DDP  # noqa: PLC0415

    from bench.model import GPT, GPTConfig, synthetic_batch  # noqa: PLC0415

    local = int(os.environ.get("LOCAL_RANK", "0"))
    world = int(os.environ.get("WORLD_SIZE", "1"))
    torch.cuda.set_device(local)
    node = os.environ.get("NODE_NAME") or socket.gethostname()
    if world > 1:
        dist.init_process_group("nccl")
    rank = dist.get_rank() if world > 1 else 0
    phases = PhaseLog(emit=(rank == 0))

    cfg = GPTConfig(n_layer=a.n_layer, n_head=a.n_head, n_embd=a.n_embd, block_size=a.block)
    torch.manual_seed(1234)
    model = GPT(cfg).cuda()
    n_params = model.n_params()
    if world > 1:
        model = DDP(model, device_ids=[local], bucket_cap_mb=a.bucket_cap_mb)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, betas=(0.9, 0.95), weight_decay=0.1, fused=True)
    gen = torch.Generator(device="cuda").manual_seed(1000 + rank)

    def step() -> float:
        x, y = synthetic_batch(a.batch, a.block, cfg.vocab, "cuda", gen)
        with torch.autocast("cuda", dtype=torch.bfloat16):
            _, loss = model(x, y)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        opt.zero_grad(set_to_none=True)
        return loss

    me = {"rank": rank, "local_rank": local, "host": node, "gpu": torch.cuda.get_device_name(local)}
    everyone: list = [me]
    if world > 1:
        everyone = [None] * world
        dist.all_gather_object(everyone, me)

    phases.begin("warmup")
    loss_first = None
    for _ in range(a.warmup):
        loss = step()
        loss_first = loss_first if loss_first is not None else float(loss.item())
    torch.cuda.synchronize()
    if world > 1:
        dist.barrier()
    phases.end("warmup")

    starts = [torch.cuda.Event(enable_timing=True) for _ in range(a.steps)]
    ends = [torch.cuda.Event(enable_timing=True) for _ in range(a.steps)]
    phases.begin("train")
    loss = None
    for i in range(a.steps):
        starts[i].record()
        loss = step()
        ends[i].record()
    torch.cuda.synchronize()
    phases.end("train")
    loss_last = float(loss.item())
    step_s = [s.elapsed_time(e) / 1000.0 for s, e in zip(starts, ends, strict=True)]

    # Profile a short window for the communication fraction.
    from torch.profiler import ProfilerActivity, profile  # noqa: PLC0415

    phases.begin("profile")
    with profile(activities=[ProfilerActivity.CUDA]) as prof:
        for _ in range(a.profile_steps):
            step()
        torch.cuda.synchronize()
    phases.end("profile")
    pf = comm_fraction_from_profile(prof)
    prof_step_s = statistics.fmean(step_s)
    nccl_per_step = pf["nccl_kernel_s"] / a.profile_steps
    comm_fraction = min(1.0, nccl_per_step / prof_step_s) if prof_step_s > 0 else 0.0

    mine = {
        "rank": rank,
        "host": node,
        "local_rank": local,
        "step_s": step_s,
        "nccl_kernel_s_per_step": nccl_per_step,
    }
    gathered: list = [mine]
    counts = parse_nccl_log(_my_debug_file)
    reports: list = [counts.to_dict()]
    if world > 1:
        gathered = [None] * world
        dist.all_gather_object(gathered, mine)
        reports = [None] * world
        dist.all_gather_object(reports, counts.to_dict())
        dist.barrier()
        dist.destroy_process_group()
    print(f"RANK{rank} host={node} local_rank={local} mean_step_s={statistics.fmean(step_s):.4f}", flush=True)
    if rank != 0:
        return 0

    all_steps = [s for g in gathered for s in g["step_s"]]
    mean_step = statistics.fmean(all_steps)
    quant = statistics.quantiles(all_steps, n=10) if len(all_steps) >= 10 else [max(all_steps)] * 9
    samples_per_s = world * a.batch / mean_step
    hosts = sorted({e["host"] for e in everyone})
    variant = json.loads(a.variant_json) if a.variant_json else {}
    variant = {
        "transport": variant.get("transport", "local" if len(hosts) == 1 else "nvlink"),
        "rails": int(variant.get("rails", 0)),
        "world_size": world,
        "nnodes": len(hosts),
        "nproc_per_node": max(sum(1 for e in everyone if e["host"] == h) for h in hosts),
        "repeat": a.repeat,
        "nccl_env": sysinfo.nccl_env_selected(),
        "label": variant.get("label", ""),
    }
    result = res.new_result(a.experiment, a.run_id, variant, a.image_ref)
    result["versions"] = sysinfo.versions()
    result["topology"] = {
        "hosts": hosts,
        "ranks_per_host": {h: sum(1 for e in everyone if e["host"] == h) for h in hosts},
        "gpu": everyone[0]["gpu"],
        **sysinfo.topo(),
    }
    merged = merge_counts([TransportCounts(**r) for r in reports])
    result["nccl"] = {
        "network": merged.network,
        "path": "local" if world == 1 else classify_path(merged),
        "mnnvl": merged.mnnvl,
        "selected_ib_hca": os.environ.get("NCCL_IB_HCA", ""),
        "socket_ifname": os.environ.get("NCCL_SOCKET_IFNAME", ""),
        "gid_index": int(os.environ["NCCL_IB_GID_INDEX"])
        if os.environ.get("NCCL_IB_GID_INDEX", "").isdigit()
        else None,
        "transport_counts": {
            k: v
            for k, v in merged.to_dict().items()
            if k not in ("network", "mnnvl", "nccl_version", "hcas", "sample")
        },
        "hcas": merged.hcas,
    }
    hcas = gidmod.list_hcas()
    if hcas:
        result["topology"]["gid_table"] = gidmod.discover(hcas)["tables"]
    result["training"] = {
        "model": cfg.to_dict() | {"n_params": n_params},
        "batch_per_gpu": a.batch,
        "block_size": a.block,
        "steps": a.steps,
        "samples_per_s": samples_per_s,
        "tokens_per_s": samples_per_s * a.block,
        "step_s": {
            "mean": mean_step,
            "p50": statistics.median(all_steps),
            "p90": quant[8],
            "min": min(all_steps),
            "max": max(all_steps),
        },
        "comm_fraction": comm_fraction,
        "nccl_kernel_s_per_step": nccl_per_step,
        "ddp_bucket_cap_mb": a.bucket_cap_mb,
        "top_kernels": pf["top_kernels"],
        "loss_first": loss_first,
        "loss_last": loss_last,
    }
    result["phases"] = phases.to_list()
    result["validation"] = {
        "all_ok": all(map(lambda v: v == v, [loss_last])) and loss_last < 1e4,
        "ranks_ok": world,
        "world_size": world,
    }
    out_dir = os.path.join(a.out, a.run_id)
    rows = [
        {
            "run_id": a.run_id,
            "step": i,
            "rank": g["rank"],
            "host": g["host"],
            "local_rank": g["local_rank"],
            "step_s": f"{s:.6f}",
            "nccl_kernel_s": f"{g['nccl_kernel_s_per_step']:.6f}",
            "samples": a.batch,
        }
        for g in gathered
        for i, s in enumerate(g["step_s"])
    ]
    res.write_steps_csv(rows, out_dir)
    path = res.write_result(result, out_dir)
    print(
        "PERF "
        + json.dumps(
            {
                "world": world,
                "samples_per_s": round(samples_per_s, 2),
                "step_s": round(mean_step, 4),
                "comm_fraction": round(comm_fraction, 3),
                "loss_first": loss_first,
                "loss_last": loss_last,
            }
        ),
        flush=True,
    )
    print(
        "TRANSPORT " + json.dumps(result["nccl"]["transport_counts"] | {"path": result["nccl"]["path"]}),
        flush=True,
    )
    print("VALIDATION " + json.dumps(result["validation"]), flush=True)
    print(f"RESULT {path}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
