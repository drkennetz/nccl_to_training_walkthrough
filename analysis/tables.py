"""Tables: size x transport, rails, scaling efficiency, the before/after with a Welch t-test."""

from __future__ import annotations

import os

import pandas as pd

from bench.common.sizes import format_size


def e1_table(df: pd.DataFrame) -> pd.DataFrame:
    d = df[(df.experiment == "E1") & (df.label != "small")]
    if d.empty:
        return pd.DataFrame()
    t = d.pivot_table(index="bytes", columns="transport", values="busbw_GBs", aggfunc="mean").reset_index()
    t.insert(1, "size", t["bytes"].map(format_size))
    return t


def e1_small_table(df: pd.DataFrame) -> pd.DataFrame:
    d = df[(df.experiment == "E1") & (df.label == "small")]
    if d.empty:
        return pd.DataFrame()
    t = d.pivot_table(index="bytes", columns="transport", values="mean_s", aggfunc="mean").reset_index()
    t.insert(1, "size", t["bytes"].map(format_size))
    for c in list(t.columns[2:]):
        t[c] = t[c] * 1e6  # microseconds: the latency floor
    return t.rename(columns={c: f"{c}_us" for c in t.columns[2:]})


def e2_table(df: pd.DataFrame) -> pd.DataFrame:
    d = df[(df.transport == "rdma") & (df.label != "small") & (df.experiment.isin(["E1", "E2"]))]
    if d.empty:
        return pd.DataFrame()
    t = d.pivot_table(index="bytes", columns="rails", values="busbw_GBs", aggfunc="mean").reset_index()
    t.columns = ["bytes"] + [f"rails{int(c)}" for c in t.columns[1:]]
    t.insert(1, "size", t["bytes"].map(format_size))
    return t


def e3_scaling(tr: pd.DataFrame) -> pd.DataFrame:
    if tr.empty:
        return tr
    t = (
        tr[tr.experiment == "E3"].sort_values(["gpus", "transport"]).copy()
        if "experiment" in tr.columns
        else tr.sort_values(["gpus", "transport"]).copy()
    )
    base = t[t.gpus == 1]["samples_per_s"]
    b = float(base.iloc[0]) if len(base) else float("nan")
    t["speedup"] = t["samples_per_s"] / b
    t["efficiency"] = t["speedup"] / t["gpus"]
    return t[
        [
            "run_id",
            "gpus",
            "nodes",
            "transport",
            "path",
            "samples_per_s",
            "step_s",
            "step_p90_s",
            "comm_fraction",
            "speedup",
            "efficiency",
            "bucket_cap_mb",
        ]
    ]


def welch_p(a, b) -> float:
    try:
        from scipy import stats  # noqa: PLC0415

        if len(a) < 2 or len(b) < 2:
            return float("nan")
        return float(stats.ttest_ind(a, b, equal_var=False).pvalue)
    except Exception:  # noqa: BLE001
        return float("nan")


def e4_before_after(df: pd.DataFrame) -> pd.DataFrame:
    d = df[df.experiment == "E4"]
    if d.empty:
        return pd.DataFrame()
    rows = []
    for nbytes, g in d.groupby("bytes"):
        base = g[g.qps == g.qps.min()]["busbw_GBs"]
        for qps, gg in g.groupby("qps"):
            rows.append(
                {
                    "size": format_size(int(nbytes)),
                    "bytes": int(nbytes),
                    "qps": int(qps),
                    "n": len(gg),
                    "busbw_mean": gg["busbw_GBs"].mean(),
                    "busbw_std": gg["busbw_GBs"].std(ddof=1) if len(gg) > 1 else 0.0,
                    "busbw_min": gg["busbw_GBs"].min(),
                    "busbw_max": gg["busbw_GBs"].max(),
                    "spread_pct_mean": gg["spread_pct"].mean(),
                    "delta_pct": 100.0 * (gg["busbw_GBs"].mean() / base.mean() - 1.0)
                    if base.mean()
                    else float("nan"),
                    "p_value": welch_p(base.values, gg["busbw_GBs"].values)
                    if qps != g.qps.min()
                    else float("nan"),
                }
            )
    return pd.DataFrame(rows).sort_values(["bytes", "qps"]).reset_index(drop=True)


def e5_table(df: pd.DataFrame) -> pd.DataFrame:
    d = df[df.experiment == "E5"]
    if d.empty:
        return pd.DataFrame()
    t = d.pivot_table(index="run_id", columns="bytes", values="busbw_GBs", aggfunc="mean").reset_index()
    t.columns = [c if c == "run_id" else format_size(int(c)) for c in t.columns]
    return t


def e5_training_table(tr: pd.DataFrame) -> pd.DataFrame:
    """E5 DDP variants (e.g. a larger DDP bucket) next to their E3 twin (same gpus + transport)."""
    if tr.empty or "experiment" not in tr.columns or not (tr.experiment == "E5").any():
        return pd.DataFrame()
    rows = []
    for r in tr[tr.experiment == "E5"].itertuples():
        twin = tr[(tr.experiment == "E3") & (tr.gpus == r.gpus) & (tr.transport == r.transport)]
        base = float(twin.samples_per_s.iloc[0]) if len(twin) else float("nan")
        rows.append(
            {
                "run_id": r.run_id,
                "gpus": r.gpus,
                "transport": r.transport,
                "bucket_cap_mb": r.bucket_cap_mb,
                "samples_per_s": r.samples_per_s,
                "comm_fraction": r.comm_fraction,
                "baseline_samples_per_s": base,
                "delta_pct": 100.0 * (r.samples_per_s / base - 1.0) if base == base else float("nan"),
            }
        )
    return pd.DataFrame(rows)


def write_tables(frames: dict[str, pd.DataFrame], out_dir: str) -> list[str]:
    os.makedirs(out_dir, exist_ok=True)
    paths = []
    for name, f in frames.items():
        if f is None or f.empty:
            continue
        p = os.path.join(out_dir, f"{name}.csv")
        f.to_csv(p, index=False, float_format="%.4f")
        paths.append(p)
    return paths
