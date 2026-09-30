"""python -m analysis <results/raw> [--out results] : tables, charts, SUMMARY.md, README block."""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

import pandas as pd

from analysis import charts, counters, load, summary, tables


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("raw", nargs="?", default="results/raw")
    ap.add_argument("--out", default=None, help="output root (default: parent of raw)")
    ap.add_argument("--readme", default="README.md")
    ap.add_argument("--no-strict", action="store_true", help="skip schema validation while loading")
    a = ap.parse_args(argv)
    out = a.out or os.path.dirname(os.path.abspath(a.raw.rstrip("/")))
    results = load.load_results(a.raw, strict=not a.no_strict)
    if not results:
        print(f"no results under {a.raw}", file=sys.stderr)
        return 1
    sw, tr, idx = load.to_sweep_frame(results), load.to_training_frame(results), load.index_frame(results)
    os.makedirs(out, exist_ok=True)
    idx.to_csv(os.path.join(out, "index.csv"), index=False)
    frames = {
        "e1_size_vs_transport": tables.e1_table(sw) if not sw.empty else None,
        "e1_small_latency": tables.e1_small_table(sw) if not sw.empty else None,
        "e2_rails": tables.e2_table(sw) if not sw.empty else None,
        "e3_scaling": tables.e3_scaling(tr) if not tr.empty else None,
        "e4_before_after": tables.e4_before_after(sw) if not sw.empty else None,
        "e5_sensitivity": tables.e5_table(sw) if not sw.empty else None,
        "e5_ddp_bucket": tables.e5_training_table(tr) if not tr.empty else None,
    }
    written = tables.write_tables(frames, os.path.join(out, "tables"))
    ch: dict[str, str] = {}
    cdir = os.path.join(out, "charts")
    if not sw.empty and ((sw.experiment == "E1") & (sw.label != "small")).any():
        ch["size_vs_busbw"] = charts.size_vs_busbw(sw, os.path.join(cdir, "size_vs_busbw.png"))
    if not sw.empty and (sw.label == "small").any():
        ch["small_message_latency"] = charts.small_message_latency(
            sw, os.path.join(cdir, "small_message_latency.png")
        )
    if not sw.empty and (sw.transport == "rdma").any() and sw[sw.transport == "rdma"]["rails"].nunique() > 1:
        ch["rails_vs_busbw"] = charts.rails_vs_busbw(sw, os.path.join(cdir, "rails_vs_busbw.png"))
    if not tr.empty:
        ch["scaling_efficiency"] = charts.scaling_efficiency(
            tables.e3_scaling(tr), os.path.join(cdir, "scaling_efficiency.png")
        )
    if not sw.empty and (sw.experiment == "E4").any():
        ch["before_after_box"] = charts.before_after_box(sw, os.path.join(cdir, "before_after_box.png"))
    for r in results:  # counter timelines for every run that shipped watcher CSVs
        csvs = [
            p
            for p in glob.glob(os.path.join(r["_dir"], "counters.*.csv"))
            if not p.endswith("counters.per-phase.csv")
        ]
        if not csvs or not r.get("phases"):
            continue
        try:
            df = counters.rates(pd.concat([counters.parse_counters_csv(p) for p in csvs], ignore_index=True))
            df = counters.join_phases(df, r["phases"])
            counters.per_phase_summary(df).to_csv(
                os.path.join(r["_dir"], "counters.per-phase.csv"), index=False
            )
            if (df.metric == "port_xmit_data").any():
                ch[f"counters_{r['run_id']}"] = charts.counters_timeline(
                    df,
                    r["phases"],
                    os.path.join(cdir, f"counters_{r['run_id']}.png"),
                    title=f"{r['run_id']}: rail transmit rate",
                )
        except Exception as e:  # noqa: BLE001
            print(f"warning: counters for {r['run_id']}: {e}", file=sys.stderr)
    frames["e5_counters"] = tables.counters_table(results)
    tables.write_tables({"e5_counters": frames["e5_counters"]}, os.path.join(out, "tables"))
    text = summary.build_summary(frames, ch, os.path.join(out, "SUMMARY.md"), idx)
    summary.update_readme(text, a.readme)
    with open(os.path.join(out, "charts.json"), "w") as f:
        json.dump(ch, f, indent=2)
    print(f"{len(results)} run(s): {len(written)} table(s), {len(ch)} chart(s) -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
