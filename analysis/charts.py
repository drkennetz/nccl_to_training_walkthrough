"""PNG charts (matplotlib, Agg). Palette and mark rules follow the data-viz method: fixed
categorical order, thin marks, one axis per chart, selective direct labels, recessive grid."""

from __future__ import annotations

import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

from bench.common.sizes import format_size  # noqa: E402

# Validated reference palette (light surface): blue, orange, aqua, yellow, magenta, green, violet, red.
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
TRANSPORT_COLOR = {
    "nvlink": SERIES[0],
    "rdma": SERIES[1],
    "tcp": SERIES[2],
    "tcp-rail": SERIES[3],
    "local": SERIES[6],
}
TEXT, MUTED, GRID = "#0b0b0b", "#52514e", "#e6e5e1"
RAIL_GBPS = 200.0  # one rail VF's link rate (Gb/s)


def _style(ax, title: str, xlabel: str, ylabel: str):
    ax.set_title(title, loc="left", color=TEXT, fontsize=12, fontweight="600", pad=12)
    ax.set_xlabel(xlabel, color=MUTED)
    ax.set_ylabel(ylabel, color=MUTED)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)
    ax.grid(True, axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


def _save(fig, out: str) -> str:
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    fig.savefig(out, dpi=160, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out


def size_vs_busbw(
    df: pd.DataFrame, out: str, title: str = "All-reduce bus bandwidth vs message size (8 ranks, 2 trays)"
) -> str:
    d = df[(df.experiment == "E1") & (df.label != "small")]
    fig, ax = plt.subplots(figsize=(9, 5))
    for tr in ["nvlink", "rdma", "tcp-rail", "tcp"]:
        g = d[d.transport == tr].groupby("bytes")["busbw_GBs"].mean()
        if g.empty:
            continue
        ax.plot(g.index, g.values, marker="o", ms=5, lw=2, color=TRANSPORT_COLOR[tr], label=tr)
        ax.annotate(
            f"{tr}  {g.values[-1]:.0f} GB/s",
            (g.index[-1], g.values[-1]),
            xytext=(6, 0),
            textcoords="offset points",
            va="center",
            fontsize=9,
            color=TEXT,
        )
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ticks = sorted(d["bytes"].unique())
    ax.set_xticks(ticks)
    ax.set_xticklabels([format_size(int(t)) for t in ticks], rotation=45, ha="right")
    rails4 = 4 * RAIL_GBPS / 8
    ax.axhline(rails4, color=MUTED, lw=1, ls="--")
    ax.annotate(
        f"4 rails x {RAIL_GBPS:.0f} Gb/s = {rails4:.0f} GB/s line rate",
        (ticks[0], rails4),
        xytext=(4, 4),
        textcoords="offset points",
        fontsize=8,
        color=MUTED,
    )
    _style(ax, title, "bytes per rank", "bus bandwidth (GB/s, log)")
    ax.legend(frameon=False, fontsize=9)
    return _save(fig, out)


def small_message_latency(df: pd.DataFrame, out: str) -> str:
    d = df[(df.experiment == "E1") & (df.label == "small")]
    fig, ax = plt.subplots(figsize=(8, 4.5))
    for tr in ["nvlink", "rdma"]:
        g = d[d.transport == tr].groupby("bytes")["mean_s"].mean() * 1e6
        if g.empty:
            continue
        ax.plot(g.index, g.values, marker="o", ms=5, lw=2, color=TRANSPORT_COLOR[tr], label=tr)
        ax.annotate(
            f"{tr}  {g.values[0]:.0f} us floor",
            (g.index[0], g.values[0]),
            xytext=(6, -10),
            textcoords="offset points",
            fontsize=9,
            color=TEXT,
        )
    ax.set_xscale("log", base=2)
    ticks = sorted(d["bytes"].unique())
    ax.set_xticks(ticks)
    ax.set_xticklabels([format_size(int(t)) for t in ticks], rotation=45, ha="right")
    _style(ax, "Small messages: the latency-bound regime", "bytes per rank", "all-reduce time (us)")
    ax.legend(frameon=False, fontsize=9)
    return _save(fig, out)


def rails_vs_busbw(df: pd.DataFrame, out: str) -> str:
    d = df[(df.transport == "rdma") & (df.experiment.isin(["E1", "E2"])) & (df.label != "small")]
    rails = sorted(d["rails"].unique())
    # only the sizes every rail count ran, so the bars compare like with like
    sizes = sorted(set.intersection(*(set(d[d.rails == r]["bytes"]) for r in rails))) if rails else []
    fig, ax = plt.subplots(figsize=(8, 4.5))
    w = 0.8 / max(1, len(rails))
    for i, r in enumerate(rails):
        vals = [d[(d.rails == r) & (d.bytes == s)]["busbw_GBs"].mean() for s in sizes]
        xs = [j + i * w - 0.4 + w / 2 for j in range(len(sizes))]
        ax.bar(
            xs,
            vals,
            width=w * 0.92,
            color=SERIES[i],
            label=f"{int(r)} rail{'s' if r != 1 else ''}",
            linewidth=0,
        )
        for x, v in zip(xs, vals, strict=True):
            if v == v:
                ax.annotate(
                    f"{v:.0f}",
                    (x, v),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha="center",
                    fontsize=8,
                    color=TEXT,
                )
    ax.set_xticks(range(len(sizes)))
    ax.set_xticklabels([format_size(int(s)) for s in sizes])
    _style(ax, "RDMA path: bus bandwidth vs rails claimed per tray", "bytes per rank", "bus bandwidth (GB/s)")
    ax.legend(frameon=False, fontsize=9)
    return _save(fig, out)


def scaling_efficiency(tr: pd.DataFrame, out: str) -> str:
    fig, ax = plt.subplots(figsize=(8, 4.5))
    t = tr.sort_values(["gpus", "transport"]).reset_index(drop=True)
    labels = [
        f"{int(r.gpus)} GPU{'s' if r.gpus > 1 else ''}" + (f"\n{r.transport}" if r.nodes > 1 else "")
        for r in t.itertuples()
    ]
    colors = [
        TRANSPORT_COLOR.get(r.transport, SERIES[0]) if r.nodes > 1 else SERIES[6] for r in t.itertuples()
    ]
    ax.bar(range(len(t)), t["efficiency"] * 100, color=colors, width=0.6, linewidth=0)
    for i, r in enumerate(t.itertuples()):
        ax.annotate(
            f"{r.efficiency * 100:.0f}%\n{r.samples_per_s:.0f} smp/s\ncomm {r.comm_fraction * 100:.0f}%",
            (i, r.efficiency * 100),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            fontsize=8,
            color=TEXT,
        )
    ax.set_xticks(range(len(t)))
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylim(0, 125)
    ax.axhline(100, color=MUTED, lw=1, ls="--")
    _style(ax, "DDP scaling efficiency (throughput / (N x 1-GPU throughput))", "", "efficiency (%)")
    return _save(fig, out)


def before_after_box(df: pd.DataFrame, out: str) -> str:
    d = df[df.experiment == "E4"]
    sizes = sorted(d["bytes"].unique())
    qps = sorted(d["qps"].unique())
    fig, axes = plt.subplots(1, max(1, len(sizes)), figsize=(3.4 * max(1, len(sizes)), 4.5))
    axes = list(axes) if len(sizes) > 1 else [axes]
    for ax, s in zip(axes, sizes, strict=False):
        data = [d[(d.bytes == s) & (d.qps == q)]["busbw_GBs"].values for q in qps]
        bp = ax.boxplot(
            data,
            widths=0.5,
            patch_artist=True,
            medianprops={"color": TEXT, "lw": 1.5},
            whiskerprops={"color": MUTED},
            capprops={"color": MUTED},
            flierprops={"marker": "o", "ms": 4, "markerfacecolor": MUTED, "markeredgecolor": "none"},
        )
        for patch, q in zip(bp["boxes"], qps, strict=True):
            patch.set_facecolor(SERIES[0] if q == qps[0] else SERIES[1])
            patch.set_edgecolor("none")
            patch.set_alpha(0.85)
        ax.set_xticks(range(1, len(qps) + 1))
        ax.set_xticklabels([f"QPs={int(q)}" for q in qps], fontsize=9)
        _style(
            ax,
            format_size(int(s)),
            "NCCL_IB_QPS_PER_CONNECTION",
            "bus bandwidth (GB/s)" if ax is axes[0] else "",
        )
    fig.suptitle(
        "Optimization: queue pairs per connection on the RDMA path (5 repeats each)",
        x=0.01,
        ha="left",
        color=TEXT,
        fontsize=12,
        fontweight="600",
    )
    return _save(fig, out)


def counters_timeline(
    counters: pd.DataFrame,
    phases: list[dict],
    out: str,
    metric: str = "port_xmit_data",
    title: str = "Rail transmit rate during the run",
) -> str:
    """Per-device rate of one counter over time, with the benchmark's timed phases shaded."""
    fig, ax = plt.subplots(figsize=(10, 4.5))
    c = counters[counters.metric == metric]
    for i, (dev, g) in enumerate(sorted(c.groupby("device"))):
        g = g.sort_values("ts")
        ax.plot(g["ts"], g["rate_per_s"] * 8 / 1e9, lw=1.6, color=SERIES[i % len(SERIES)], label=dev)
    top = ax.get_ylim()[1]
    for p in phases:
        if p["name"].startswith("timed-"):
            t0, t1 = (
                pd.to_datetime(p["t_start"], unit="s", utc=True),
                pd.to_datetime(p["t_end"], unit="s", utc=True),
            )
            ax.axvspan(t0, t1, color=GRID, alpha=0.6, lw=0)
            ax.annotate(
                p["name"].replace("timed-", ""),
                (t0, top * 0.95),
                fontsize=7,
                color=MUTED,
                rotation=90,
                va="top",
            )
    _style(ax, title, "time (UTC)", "Gb/s per rail")
    ax.legend(frameon=False, fontsize=8, ncol=4)
    fig.autofmt_xdate()
    return _save(fig, out)
