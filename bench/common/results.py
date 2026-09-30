"""The on-disk result: result.json (schema-validated) and ranks.csv. Nothing else knows the layout."""

from __future__ import annotations

import csv
import datetime as dt
import json
import os
from collections.abc import Iterable
from importlib import resources

import jsonschema

SCHEMA_VERSION = "1.0"


def load_schema() -> dict:
    with resources.files("bench").joinpath("schema/result.schema.json").open() as f:
        return json.load(f)


def now_iso() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def new_result(experiment: str, run_id: str, variant: dict, image_ref: str) -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "experiment": experiment,
        "variant": variant,
        "image": {"ref": image_ref},
        "versions": {},
        "topology": {"hosts": [], "ranks_per_host": {}, "gpu": ""},
        "nccl": {"network": "", "path": "unknown", "transport_counts": {}},
        "phases": [],
        "validation": {"all_ok": False, "ranks_ok": 0, "world_size": 0},
        "artifacts": {},
        "timestamps": {"start": now_iso(), "end": ""},
    }


def validate(result: dict) -> None:
    jsonschema.validate(result, load_schema())


def write_result(result: dict, out_dir: str) -> str:
    os.makedirs(out_dir, exist_ok=True)
    result["timestamps"]["end"] = result["timestamps"].get("end") or now_iso()
    validate(result)
    path = os.path.join(out_dir, "result.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(result, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
    return path


RANK_COLUMNS = ["run_id", "phase", "bytes", "rank", "host", "local_rank", "iter", "seconds"]
STEP_COLUMNS = ["run_id", "step", "rank", "host", "local_rank", "step_s", "nccl_kernel_s", "samples"]


def write_csv(rows: Iterable[dict], out_dir: str, name: str, columns: list[str]) -> str:
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=columns)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in columns})
    return path


def write_ranks_csv(rows: Iterable[dict], out_dir: str) -> str:
    return write_csv(rows, out_dir, "ranks.csv", RANK_COLUMNS)


def write_steps_csv(rows: Iterable[dict], out_dir: str) -> str:
    return write_csv(rows, out_dir, "ranks.csv", STEP_COLUMNS)
