import json

import jsonschema
import pytest

from bench.common import results as res


def _sweep_result():
    r = res.new_result(
        "E1",
        "e1-nvlink",
        {
            "transport": "nvlink",
            "rails": 0,
            "world_size": 8,
            "nnodes": 2,
            "nproc_per_node": 4,
            "repeat": 0,
            "nccl_env": {"NCCL_MNNVL_ENABLE": "1"},
        },
        "img@sha256:abc",
    )
    r["versions"] = {"torch": "2.8", "cuda": "13.0", "nccl": "2.27.7", "driver": "580", "python": "3.12"}
    r["topology"] = {"hosts": ["a", "b"], "ranks_per_host": {"a": 4, "b": 4}, "gpu": "GB300"}
    r["nccl"] = {
        "network": "Socket",
        "path": "nvlink",
        "transport_counts": {
            "mnnvl_channels": 256,
            "net_ib_channels": 0,
            "net_ib_gdr_channels": 0,
            "net_socket_channels": 0,
            "p2p_channels": 512,
            "shm_channels": 0,
            "ranks_reporting": 8,
        },
    }
    r["sweep"] = [
        {
            "bytes": 1 << 29,
            "iters": 20,
            "warmup": 10,
            "mean_s": 0.0013,
            "p50_s": 0.0013,
            "min_s": 0.0012,
            "max_s": 0.0015,
            "algbw_GBs": 400.0,
            "busbw_GBs": 700.0,
            "correct": True,
            "rank_variance": {
                "rank_mean_min_s": 0.0012,
                "rank_mean_max_s": 0.0014,
                "rank_mean_p50_s": 0.0013,
                "spread_pct": 3.0,
                "slowest_rank": 5,
            },
        }
    ]
    r["phases"] = [{"name": "timed-512MiB", "t_start": 1.0, "t_end": 2.0}]
    r["validation"] = {"all_ok": True, "ranks_ok": 8, "world_size": 8}
    return r


def test_sweep_result_validates_and_writes(tmp_path):
    r = _sweep_result()
    p = res.write_result(r, str(tmp_path / "e1-nvlink"))
    back = json.load(open(p))
    assert back["timestamps"]["end"].endswith("Z") and back["run_id"] == "e1-nvlink"


def test_training_result_validates():
    r = _sweep_result()
    del r["sweep"]
    r["variant"]["transport"] = "local"
    r["nccl"]["path"] = "local"
    r["training"] = {
        "model": {"n_layer": 12},
        "batch_per_gpu": 8,
        "block_size": 1024,
        "steps": 50,
        "samples_per_s": 120.0,
        "step_s": {"mean": 0.5, "p50": 0.5, "p90": 0.55, "min": 0.4, "max": 0.6},
        "comm_fraction": 0.2,
        "nccl_kernel_s_per_step": 0.1,
        "ddp_bucket_cap_mb": 25,
    }
    res.validate(r)


def test_both_or_neither_is_rejected():
    r = _sweep_result()
    with pytest.raises(jsonschema.ValidationError):
        res.validate({k: v for k, v in r.items() if k != "sweep"})
    r["training"] = {
        "model": {},
        "batch_per_gpu": 1,
        "block_size": 1,
        "steps": 1,
        "samples_per_s": 1.0,
        "step_s": {"mean": 1, "p50": 1, "p90": 1, "min": 1, "max": 1},
        "comm_fraction": 0.0,
        "nccl_kernel_s_per_step": 0.0,
        "ddp_bucket_cap_mb": 25,
    }
    with pytest.raises(jsonschema.ValidationError):
        res.validate(r)


def test_missing_path_is_rejected():
    r = _sweep_result()
    del r["nccl"]["path"]
    with pytest.raises(jsonschema.ValidationError):
        res.validate(r)


def test_bad_transport_enum_is_rejected():
    r = _sweep_result()
    r["variant"]["transport"] = "carrier-pigeon"
    with pytest.raises(jsonschema.ValidationError):
        res.validate(r)


def test_ranks_csv_columns(tmp_path):
    p = res.write_ranks_csv(
        [
            {
                "run_id": "x",
                "phase": "timed-1MiB",
                "bytes": 1,
                "rank": 0,
                "host": "a",
                "local_rank": 0,
                "iter": 0,
                "seconds": "0.1",
            }
        ],
        str(tmp_path),
    )
    lines = open(p).read().splitlines()
    assert lines[0] == ",".join(res.RANK_COLUMNS) and lines[1].startswith("x,timed-1MiB,1,0,a,0,0,0.1")
