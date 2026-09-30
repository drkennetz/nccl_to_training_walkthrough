#!/usr/bin/env python3
"""Collect one finished run into results/raw/<run_id>/: result.json + ranks.csv (written by the
index-0 pod into the node's results hostPath), every pod's log, each watcher pod's CSV, and the
sysinfo captures. Validates result.json against the schema before returning 0."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from bench.common.results import validate  # noqa: E402


def kubectl(*args: str, check: bool = True) -> str:
    r = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def pods_of_job(job: str, ns: str) -> list[dict]:
    out = kubectl("-n", ns, "get", "pods", "-l", f"app={job}", "-o", "json")
    return sorted(
        json.loads(out)["items"],
        key=lambda p: int(p["metadata"]["annotations"].get("batch.kubernetes.io/job-completion-index", "0")),
    )


def collect_run(run_id: str, ns: str, out_root: str, results_host_path: str) -> str:
    job = f"compass-{run_id}"
    out_dir = os.path.join(out_root, run_id)
    os.makedirs(out_dir, exist_ok=True)
    pods = pods_of_job(job, ns)
    if not pods:
        raise RuntimeError(f"no pods for job {job}")
    for p in pods:
        idx = p["metadata"]["annotations"].get("batch.kubernetes.io/job-completion-index", "0")
        log = kubectl("-n", ns, "logs", p["metadata"]["name"], check=False)
        with open(os.path.join(out_dir, f"pod-{idx}.log"), "w") as f:
            f.write(log)
    # result.json + ranks.csv live on the index-0 pod's node under the results hostPath.
    node0 = pods[0]["spec"]["nodeName"]
    fetch = kubectl("-n", ns, "get", "pod", "-l", "app=compass-watcher", "-o", "json", check=False)
    watcher_on_node0 = next(
        (
            w["metadata"]["name"]
            for w in json.loads(fetch or '{"items":[]}')["items"]
            if w["spec"].get("nodeName") == node0
        ),
        "",
    )
    for fname in ("result.json", "ranks.csv"):
        src = f"{results_host_path}/{run_id}/{fname}"
        if watcher_on_node0:
            data = kubectl(
                "-n",
                ns,
                "exec",
                watcher_on_node0,
                "--",
                "cat",
                f"/host-results/{run_id}/{fname}",
                check=False,
            )
        else:
            data = ""
        if not data:
            # fall back to the finished pod itself (restartPolicy Never keeps it around)
            data = kubectl(
                "-n",
                ns,
                "exec",
                pods[0]["metadata"]["name"],
                "--",
                "cat",
                f"/results/{run_id}/{fname}",
                check=False,
            )
        if data:
            with open(os.path.join(out_dir, fname), "w") as f:
                f.write(data)
        else:
            print(f"warning: could not fetch {src}", file=sys.stderr)
    for w in json.loads(fetch or '{"items":[]}')["items"]:
        node = w["spec"].get("nodeName", "node")
        csv = kubectl("-n", ns, "logs", w["metadata"]["name"], check=False)
        with open(os.path.join(out_dir, f"counters.{node}.csv"), "w") as f:
            f.write(csv)
    rp = os.path.join(out_dir, "result.json")
    if not os.path.exists(rp):
        raise RuntimeError(f"{run_id}: result.json missing (see pod-0.log)")
    with open(rp) as f:
        result = json.load(f)
    result.setdefault("artifacts", {})["pod_logs"] = sorted(
        n for n in os.listdir(out_dir) if n.startswith("pod-")
    )
    result["artifacts"]["counters_csv"] = sorted(n for n in os.listdir(out_dir) if n.startswith("counters."))
    validate(result)
    with open(rp, "w") as f:
        json.dump(result, f, indent=2, sort_keys=True)
        f.write("\n")
    return out_dir


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("run_id")
    ap.add_argument("--namespace", default="compass")
    ap.add_argument("--out", default="results/raw")
    ap.add_argument("--results-host-path", default="/mnt/localdisk/compass-results")
    a = ap.parse_args(argv)
    print(collect_run(a.run_id, a.namespace, a.out, a.results_host_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
