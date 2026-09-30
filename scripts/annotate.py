#!/usr/bin/env python3
"""Push a run's benchmark phases to Grafana as tagged annotations (tag `compass`, plus the run id
and the phase name), so every panel of the fabric dashboard shows when each message size ran.

    GRAFANA_URL=https://<stack>.grafana.net TF_VAR_grafana_auth=... scripts/annotate.py results/raw/e1-rdma
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request


def post(url: str, token: str, body: dict) -> int:
    req = urllib.request.Request(
        url.rstrip("/") + "/api/annotations",
        data=json.dumps(body).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310
        return resp.status


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("run_dir")
    ap.add_argument("--url", default=os.environ.get("GRAFANA_URL", ""))
    ap.add_argument("--token", default=os.environ.get("TF_VAR_grafana_auth", ""))
    ap.add_argument("--only-timed", action="store_true", default=True)
    a = ap.parse_args(argv)
    if not a.url or not a.token:
        print("need --url/GRAFANA_URL and --token/TF_VAR_grafana_auth", file=sys.stderr)
        return 2
    r = json.load(open(os.path.join(a.run_dir, "result.json")))
    n = 0
    for p in r["phases"]:
        if a.only_timed and not (p["name"].startswith("timed-") or p["name"] == "train"):
            continue
        body = {
            "time": int(p["t_start"] * 1000),
            "timeEnd": int(p["t_end"] * 1000),
            "tags": ["compass", r["run_id"], p["name"], r["variant"]["transport"]],
            "text": f"{r['run_id']} {p['name']} ({r['variant']['transport']}, rails={r['variant']['rails']})",
        }
        post(a.url, a.token, body)
        n += 1
    print(f"{n} annotation(s) posted for {r['run_id']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
