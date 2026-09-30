"""Watcher CSVs -> per-second rates joined to benchmark phases."""

from __future__ import annotations

import pandas as pd

MONOTONIC_SOURCES = {"ib_counter", "ib_hw_counter", "ethtool", "nvlink"}


def parse_counters_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df["ts"] = pd.to_datetime(df["ts_iso"], utc=True)
    # resolution-agnostic epoch seconds (pandas may parse these stamps at ms resolution)
    df["t"] = (df["ts"] - pd.Timestamp(0, tz="UTC")) / pd.Timedelta(seconds=1)
    return df


def rates(df: pd.DataFrame) -> pd.DataFrame:
    """Delta/second for monotonic counters; gauges (dcgm) pass through as their value.
    Negative deltas (a counter wrap or a device re-appearing) are dropped."""
    out = []
    for (_node, source, _device, _metric), g in df.groupby(
        ["node", "source", "device", "metric"], sort=False
    ):
        g = g.sort_values("t").copy()
        if source in MONOTONIC_SOURCES:
            dv = g["value"].diff()
            dt = g["t"].diff()
            g["rate_per_s"] = dv / dt
            g = g[(g["rate_per_s"] >= 0) & (dt > 0)]
        else:
            g["rate_per_s"] = g["value"]
        out.append(g)
    return pd.concat(out, ignore_index=True) if out else df.assign(rate_per_s=pd.Series(dtype=float))


def join_phases(df: pd.DataFrame, phases: list[dict]) -> pd.DataFrame:
    df = df.copy()
    df["phase"] = "idle"
    for p in phases:
        m = (df["t"] >= p["t_start"]) & (df["t"] < p["t_end"])
        df.loc[m, "phase"] = p["name"]
    return df


def per_phase_summary(df: pd.DataFrame) -> pd.DataFrame:
    """Mean rate per phase/device/metric; for byte counters also Gb/s."""
    s = df.groupby(["phase", "source", "device", "metric"], as_index=False)["rate_per_s"].mean()
    s["gbps"] = [
        r * 8 / 1e9 if str(m).endswith(("_data", "_bytes")) else float("nan")
        for r, m in zip(s["rate_per_s"], s["metric"], strict=True)
    ]
    return s
