"""Load every results/raw/<run_id>/result.json into flat pandas frames."""

from __future__ import annotations

import glob
import json
import os

import pandas as pd

from bench.common.results import validate


def load_results(root: str, strict: bool = True) -> list[dict]:
    out = []
    for p in sorted(glob.glob(os.path.join(root, "*", "result.json"))):
        with open(p) as f:
            r = json.load(f)
        if strict:
            validate(r)
        r["_dir"] = os.path.dirname(p)
        out.append(r)
    return out


def _qps(r: dict) -> int:
    return int(r["variant"]["nccl_env"].get("NCCL_IB_QPS_PER_CONNECTION", "1"))


def to_sweep_frame(results: list[dict]) -> pd.DataFrame:
    rows = []
    for r in results:
        for s in r.get("sweep", []):
            rows.append(
                {
                    "run_id": r["run_id"],
                    "experiment": r["experiment"],
                    "transport": r["variant"]["transport"],
                    "label": r["variant"].get("label", ""),
                    "rails": r["variant"]["rails"],
                    "world_size": r["variant"]["world_size"],
                    "repeat": r["variant"]["repeat"],
                    "qps": _qps(r),
                    "path": r["nccl"]["path"],
                    "bytes": s["bytes"],
                    "iters": s["iters"],
                    "mean_s": s["mean_s"],
                    "p50_s": s["p50_s"],
                    "algbw_GBs": s["algbw_GBs"],
                    "busbw_GBs": s["busbw_GBs"],
                    "spread_pct": s["rank_variance"]["spread_pct"],
                    "slowest_rank": s["rank_variance"]["slowest_rank"],
                    "correct": s["correct"],
                    "nccl_env": json.dumps(r["variant"]["nccl_env"], sort_keys=True),
                }
            )
    return pd.DataFrame(rows)


def to_training_frame(results: list[dict]) -> pd.DataFrame:
    rows = []
    for r in results:
        t = r.get("training")
        if not t:
            continue
        rows.append(
            {
                "run_id": r["run_id"],
                "transport": r["variant"]["transport"],
                "gpus": r["variant"]["world_size"],
                "nodes": r["variant"]["nnodes"],
                "path": r["nccl"]["path"],
                "samples_per_s": t["samples_per_s"],
                "tokens_per_s": t.get("tokens_per_s", float("nan")),
                "step_s": t["step_s"]["mean"],
                "step_p90_s": t["step_s"]["p90"],
                "comm_fraction": t["comm_fraction"],
                "nccl_kernel_s_per_step": t["nccl_kernel_s_per_step"],
                "bucket_cap_mb": t["ddp_bucket_cap_mb"],
                "n_params": t["model"].get("n_params", 0),
            }
        )
    return pd.DataFrame(rows)


def index_frame(results: list[dict]) -> pd.DataFrame:
    rows = []
    for r in results:
        rows.append(
            {
                "run_id": r["run_id"],
                "experiment": r["experiment"],
                "transport": r["variant"]["transport"],
                "rails": r["variant"]["rails"],
                "world_size": r["variant"]["world_size"],
                "nnodes": r["variant"]["nnodes"],
                "path": r["nccl"]["path"],
                "net_socket_channels": r["nccl"]["transport_counts"].get("net_socket_channels", 0),
                "mnnvl_channels": r["nccl"]["transport_counts"].get("mnnvl_channels", 0),
                "net_ib_channels": r["nccl"]["transport_counts"].get("net_ib_channels", 0),
                "all_ok": r["validation"]["all_ok"],
                "start": r["timestamps"]["start"],
                "end": r["timestamps"]["end"],
                "torch": r["versions"].get("torch", ""),
                "nccl": r["versions"].get("nccl", ""),
                "image": r["image"].get("ref", ""),
            }
        )
    return pd.DataFrame(rows)
