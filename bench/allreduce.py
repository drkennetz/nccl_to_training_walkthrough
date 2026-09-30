"""All-reduce sweep under torchrun: one process per GPU, NNODES pods of an Indexed Job.

For every message size: warm-up, a timed loop with a CUDA event pair per iteration on EVERY
rank (so the per-rank spread is measured, not assumed), a correctness check on a fresh tensor,
and phase markers on stdout for the counter watcher. NCCL's own INIT/GRAPH report goes to a
per-rank file (NCCL_DEBUG_FILE) and is counted BEFORE the communicator is torn down, so the
result carries evidence of the path (P2P/MNNVL vs NET/IB vs NET/Socket) next to the numbers.
Rank 0 writes result.json + ranks.csv into --out/<run_id>/.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

# Must be set before the NCCL communicator exists; %p = pid.
_debug_file = os.environ.setdefault("NCCL_DEBUG_FILE", "/tmp/nccl_debug.%p.log")
_my_debug_file = _debug_file.replace("%p", str(os.getpid())).replace("%h", socket.gethostname().split(".")[0])

from bench import gid as gidmod  # noqa: E402
from bench import sysinfo  # noqa: E402
from bench.common import results as res  # noqa: E402
from bench.common.bw import algbw_gbs, busbw_gbs  # noqa: E402
from bench.common.nccl_log import classify_path, merge_counts, parse_nccl_log  # noqa: E402
from bench.common.phases import PhaseLog  # noqa: E402
from bench.common.schedule import iters_for, warmup_for  # noqa: E402
from bench.common.sizes import format_size, parse_sizes  # noqa: E402
from bench.common.timing import IterTimings, rank_stats  # noqa: E402


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="bench allreduce", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--sizes", default="1Mi:8Gi", help="'lo:hi' geometric sweep or a comma list (1Mi, 512Mi, 8Gi)"
    )
    ap.add_argument("--iters", default="auto", help="iterations per size, or 'auto' (size-scaled)")
    ap.add_argument("--warmup", default="auto")
    ap.add_argument("--collective", default="all_reduce", choices=["all_reduce"])
    ap.add_argument("--experiment", default="E1")
    ap.add_argument("--run-id", default=os.environ.get("RUN_ID", "adhoc"))
    ap.add_argument("--repeat", type=int, default=int(os.environ.get("REPEAT", "0")))
    ap.add_argument(
        "--variant-json",
        default=os.environ.get("VARIANT_JSON", "{}"),
        help="transport/rails/label recorded verbatim",
    )
    ap.add_argument("--image-ref", default=os.environ.get("IMAGE_REF", ""))
    ap.add_argument("--out", default=os.environ.get("RESULTS_DIR", "/results"))
    ap.add_argument(
        "--expect-hcas",
        type=int,
        default=int(os.environ.get("EXPECT_HCAS", "0")),
        help="fail fast unless this many rdma_vf_rail* devices are visible",
    )
    return ap.parse_args(argv)


def main(argv=None) -> int:
    a = parse_args(argv)
    import torch  # noqa: PLC0415
    import torch.distributed as dist  # noqa: PLC0415

    local = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local)
    node = os.environ.get("NODE_NAME") or socket.gethostname()

    if a.expect_hcas:
        seen = gidmod.list_hcas()
        if len(seen) != a.expect_hcas:
            print(f"PRECHECK-FAILED: expected {a.expect_hcas} rdma_vf_rail* devices, see {seen}", flush=True)
            return 3

    dist.init_process_group("nccl")
    rank, world = dist.get_rank(), dist.get_world_size()
    phases = PhaseLog(emit=(rank == 0))

    me = {"rank": rank, "local_rank": local, "host": node, "gpu": torch.cuda.get_device_name(local)}
    everyone: list = [None] * world
    dist.all_gather_object(everyone, me)

    sizes = parse_sizes(a.sizes)
    sweep_rows, rank_rows, timings_by_size = [], [], {}
    for nbytes in sizes:
        label = format_size(nbytes)
        iters = iters_for(nbytes) if a.iters == "auto" else int(a.iters)
        warm = warmup_for(nbytes) if a.warmup == "auto" else int(a.warmup)
        x = torch.ones(nbytes // 2, dtype=torch.bfloat16, device="cuda")

        phases.begin(f"warmup-{label}")
        for _ in range(warm):
            dist.all_reduce(x)
        torch.cuda.synchronize()
        dist.barrier()
        phases.end(f"warmup-{label}")

        starts = [torch.cuda.Event(enable_timing=True) for _ in range(iters)]
        ends = [torch.cuda.Event(enable_timing=True) for _ in range(iters)]
        phases.begin(f"timed-{label}")
        for i in range(iters):
            starts[i].record()
            dist.all_reduce(x)
            ends[i].record()
        torch.cuda.synchronize()
        phases.end(f"timed-{label}")
        secs = [s.elapsed_time(e) / 1000.0 for s, e in zip(starts, ends, strict=True)]
        del x

        # Correctness on a FRESH tensor (x has been summed in place many times).
        y = torch.ones(4096, dtype=torch.bfloat16, device="cuda")
        dist.all_reduce(y)
        ok = bool(torch.all(y == world).item())
        flags: list = [None] * world
        dist.all_gather_object(flags, ok)

        mine = IterTimings(rank, node, local, secs)
        gathered: list = [None] * world
        dist.all_gather_object(gathered, mine.to_dict())
        timings = [IterTimings(**g) for g in gathered]
        timings_by_size[nbytes] = timings
        if rank == 0:
            st = rank_stats(timings)
            row = {
                "bytes": nbytes,
                "iters": iters,
                "warmup": warm,
                "mean_s": st["mean_s"],
                "p50_s": st["p50_s"],
                "min_s": st["min_s"],
                "max_s": st["max_s"],
                "algbw_GBs": round(algbw_gbs(nbytes, st["mean_s"]), 3),
                "busbw_GBs": round(busbw_gbs(nbytes, st["mean_s"], world, a.collective), 3),
                "correct": all(bool(f) for f in flags),
                "rank_variance": {
                    k: st[k]
                    for k in (
                        "rank_mean_min_s",
                        "rank_mean_max_s",
                        "rank_mean_p50_s",
                        "spread_pct",
                        "slowest_rank",
                    )
                },
            }
            sweep_rows.append(row)
            print(
                "PERF "
                + json.dumps(
                    {
                        "bytes": nbytes,
                        "size": label,
                        "iters": iters,
                        "mean_s": round(st["mean_s"], 6),
                        "algbw_GBs": row["algbw_GBs"],
                        "busbw_GBs": row["busbw_GBs"],
                        "spread_pct": round(st["spread_pct"], 2),
                        "slowest_rank": st["slowest_rank"],
                        "correct": row["correct"],
                    }
                ),
                flush=True,
            )
            for t in timings:
                for i, s in enumerate(t.seconds):
                    rank_rows.append(
                        {
                            "run_id": a.run_id,
                            "phase": f"timed-{label}",
                            "bytes": nbytes,
                            "rank": t.rank,
                            "host": t.host,
                            "local_rank": t.local_rank,
                            "iter": i,
                            "seconds": f"{s:.6f}",
                        }
                    )

    # Transport evidence, gathered before teardown so it is complete and deterministic.
    counts = parse_nccl_log(_my_debug_file)
    reports: list = [None] * world
    dist.all_gather_object(reports, counts.to_dict())
    all_ok_flags: list = [None] * world
    dist.all_gather_object(all_ok_flags, all(r["correct"] for r in sweep_rows) if rank == 0 else True)
    print(f"RANK{rank} host={node} local_rank={local} done", flush=True)
    dist.barrier()
    dist.destroy_process_group()

    if rank != 0:
        return 0
    from bench.common.nccl_log import TransportCounts  # noqa: PLC0415

    merged = merge_counts([TransportCounts(**r) for r in reports])
    variant = json.loads(a.variant_json) if a.variant_json else {}
    hosts = sorted({e["host"] for e in everyone})
    variant = {
        "transport": variant.get("transport", "nvlink"),
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
    topo = sysinfo.topo()
    result["topology"] = {
        "hosts": hosts,
        "ranks_per_host": {h: sum(1 for e in everyone if e["host"] == h) for h in hosts},
        "gpu": everyone[0]["gpu"],
        **topo,
    }
    hcas = gidmod.list_hcas()
    if hcas:
        result["topology"]["gid_table"] = gidmod.discover(hcas)["tables"]
    env = os.environ
    result["nccl"] = {
        "network": merged.network,
        "path": classify_path(merged),
        "mnnvl": merged.mnnvl,
        "selected_ib_hca": env.get("NCCL_IB_HCA", ""),
        "socket_ifname": env.get("NCCL_SOCKET_IFNAME", ""),
        "gid_index": int(env["NCCL_IB_GID_INDEX"]) if env.get("NCCL_IB_GID_INDEX", "").isdigit() else None,
        "transport_counts": {
            k: v
            for k, v in merged.to_dict().items()
            if k not in ("network", "mnnvl", "nccl_version", "hcas", "sample")
        },
        "hcas": merged.hcas,
        "sample": merged.sample,
    }
    if merged.nccl_version and not result["versions"].get("nccl"):
        result["versions"]["nccl"] = merged.nccl_version
    result["sweep"] = sweep_rows
    result["phases"] = phases.to_list()
    result["validation"] = {
        "all_ok": all(r["correct"] for r in sweep_rows),
        "ranks_ok": sum(1 for f in all_ok_flags if f),
        "world_size": world,
    }
    out_dir = os.path.join(a.out, a.run_id)
    result["artifacts"] = {"ranks_csv": "ranks.csv", "nccl_debug_file_pattern": _debug_file}
    res.write_ranks_csv(rank_rows, out_dir)
    path = res.write_result(result, out_dir)
    print(
        "TRANSPORT "
        + json.dumps(
            result["nccl"]["transport_counts"]
            | {"path": result["nccl"]["path"], "network": merged.network, "mnnvl": merged.mnnvl}
        ),
        flush=True,
    )
    print(
        "TOPO "
        + json.dumps(
            {
                "world_size": world,
                "n_hosts": len(hosts),
                "hosts": hosts,
                "ranks_per_host": result["topology"]["ranks_per_host"],
                "gpu": everyone[0]["gpu"],
            }
        ),
        flush=True,
    )
    print("VALIDATION " + json.dumps(result["validation"]), flush=True)
    print(f"RESULT {path}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
