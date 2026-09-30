"""Architecture diagram for the deck: the two trays, what is inside each, how they are wired, and
where the control plane, the collector and the registries sit. Drawn with matplotlib so it lives in
the repo and rebuilds with the deck. Palette: the validated reference set."""

from __future__ import annotations

import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch  # noqa: E402

BLUE, ORANGE, AQUA, GREEN, VIOLET = "#2a78d6", "#eb6834", "#1baf7a", "#008300", "#4a3aa7"
TEXT, MUTED, GRID, SURFACE = "#0b0b0b", "#52514e", "#e6e5e1", "#fcfcfb"
FILL = {
    BLUE: "#e9f1fb",
    ORANGE: "#fdeee6",
    AQUA: "#e4f6ef",
    GREEN: "#e6f4e6",
    VIOLET: "#efedfa",
    MUTED: SURFACE,
}


def box(ax, x, y, w, h, label="", color=MUTED, fs=8.5, lw=1.2, bold=False):
    ax.add_patch(
        FancyBboxPatch(
            (x, y),
            w,
            h,
            boxstyle="round,pad=0.02,rounding_size=0.12",
            fc=FILL.get(color, "#fff"),
            ec=color,
            lw=lw,
        )
    )
    if label:
        ax.text(
            x + w / 2,
            y + h / 2,
            label,
            ha="center",
            va="center",
            fontsize=fs,
            color=TEXT,
            fontweight="bold" if bold else "normal",
            linespacing=1.35,
        )


def panel(ax, x, y, w, h, title, lines, color=MUTED, fs=8):
    box(ax, x, y, w, h, color=color, lw=1.4)
    ax.text(x + 0.25, y + h - 0.35, title, fontsize=9.5, fontweight="bold", color=TEXT, va="center")
    ax.text(x + 0.25, y + h - 0.75, "\n".join(lines), fontsize=fs, color=TEXT, va="top", linespacing=1.55)


def arrow(ax, p, q, color=MUTED, lw=1.4, style="-|>", label=None, loff=(0, 0.3), fs=8):
    ax.add_patch(
        FancyArrowPatch(p, q, arrowstyle=style, color=color, lw=lw, mutation_scale=12, shrinkA=2, shrinkB=2)
    )
    if label:
        ax.text(
            (p[0] + q[0]) / 2 + loff[0],
            (p[1] + q[1]) / 2 + loff[1],
            label,
            ha="center",
            va="center",
            fontsize=fs,
            color=color,
            linespacing=1.3,
        )


def tray(ax, x0, y0, name):
    w, h = 9.0, 6.2
    box(ax, x0, y0, w, h, color=MUTED, lw=1.6)
    ax.text(x0 + 0.25, y0 + h - 0.35, name, fontsize=10.5, fontweight="bold", color=TEXT, va="center")
    ax.text(
        x0 + w - 0.25,
        y0 + h - 0.35,
        "GB300 compute tray · Grace arm64",
        fontsize=8,
        color=MUTED,
        va="center",
        ha="right",
    )
    ax.text(
        x0 + 4.1, y0 + 5.15, "NVLink between the four GPUs (NVSwitch)", ha="center", fontsize=7.5, color=BLUE
    )
    for i in range(4):
        box(ax, x0 + 0.3 + i * 1.95, y0 + 4.05, 1.7, 0.85, f"GPU {i}", color=BLUE, fs=9)
        box(
            ax,
            x0 + 0.3 + i * 1.95,
            y0 + 2.35,
            1.7,
            0.95,
            f"rail {i}\nConnectX-8 VF\n4 × 200 Gb/s",
            color=ORANGE,
            fs=7,
        )
        arrow(
            ax,
            (x0 + 1.15 + i * 1.95, y0 + 4.05),
            (x0 + 1.15 + i * 1.95, y0 + 3.3),
            color=MUTED,
            lw=1,
            style="<|-|>",
        )
    ax.text(
        x0 + 4.1,
        y0 + 2.05,
        "GPUDirect RDMA: GPU → C2C → Grace → PCIe Gen6 x16 → NIC",
        ha="center",
        fontsize=7,
        color=MUTED,
    )
    box(
        ax,
        x0 + 0.3,
        y0 + 0.3,
        5.2,
        1.45,
        "benchmark pod (one per tray)\ntorchrun × 4 ranks\nclaims: 4 GPUs (DRA) + rails (dranet)",
        color=VIOLET,
        fs=7.2,
    )
    box(ax, x0 + 5.7, y0 + 0.3, 1.5, 1.45, "watcher\npod\n1 Hz counters", color=GREEN, fs=6.8)
    box(ax, x0 + 7.4, y0 + 0.3, 1.35, 1.45, "eth0\npod\nnetwork", color=AQUA, fs=6.8)
    return x0, y0, w, h


def build(out: str) -> str:
    fig, ax = plt.subplots(figsize=(16, 9))
    ax.set_xlim(0, 32)
    ax.set_ylim(0, 18)
    ax.axis("off")
    fig.patch.set_facecolor("white")
    ax.text(
        0.4,
        17.5,
        "Two GB300 trays in one NVLink domain, leased from a shared Slurm pool, running k3s",
        fontsize=15,
        fontweight="bold",
        color=TEXT,
        va="center",
    )

    t1 = tray(ax, 0.4, 9.8, "worker tray 1")
    t2 = tray(ax, 22.6, 9.8, "worker tray 2")
    r1, l2 = t1[0] + t1[2], t2[0]  # right edge of tray 1, left edge of tray 2
    mid = (r1 + l2) / 2

    # NVLink between trays
    arrow(ax, (r1, 14.6), (l2, 14.6), color=BLUE, lw=3.2, style="<|-|>")
    ax.text(
        mid,
        15.35,
        "multi-node NVLink (MNNVL) through the host IMEX channel\n256 P2P/MNNVL channels · 835 GB/s bus bandwidth at 8 GiB",
        ha="center",
        fontsize=8.5,
        color=BLUE,
        linespacing=1.4,
    )

    # rails via the fabric
    box(
        ax,
        mid - 3.2,
        13.0,
        6.4,
        1.15,
        "RoCE v2 rail fabric\n(rail i of tray 1 ↔ rail i of tray 2)",
        color=ORANGE,
        fs=8.5,
    )
    arrow(ax, (r1, 13.57), (mid - 3.2, 13.57), color=ORANGE, lw=2.4, style="<|-|>")
    arrow(ax, (mid + 3.2, 13.57), (l2, 13.57), color=ORANGE, lw=2.4, style="<|-|>")
    ax.text(
        mid,
        11.8,
        "640 NET/IB GPUDirect channels · 425 GB/s at 4 GiB\neach rail at ~55 % of its 800 Gb/s\nVF + RDMA device stay on the host; the pod gets an IPVLAN child",
        ha="center",
        fontsize=7.3,
        color=ORANGE,
        linespacing=1.35,
    )

    # pod network
    box(
        ax,
        mid - 3.8,
        9.85,
        7.6,
        1.3,
        "Cilium 1.20 · geneve tunnel on the management NIC\neBPF kube-proxy replacement · headless Service rendezvous\ncarries the rendezvous and NCCL bootstrap only — never the data",
        color=AQUA,
        fs=6.9,
    )
    arrow(ax, (r1, 10.5), (mid - 3.8, 10.5), color=AQUA, lw=1.5, style="<|-|>")
    arrow(ax, (mid + 3.8, 10.5), (l2, 10.5), color=AQUA, lw=1.5, style="<|-|>")

    # bottom row
    panel(
        ax,
        0.4,
        3.2,
        7.4,
        4.6,
        "control-plane tray (k3s server)",
        [
            "GPU Operator in DRA mode",
            "  → DeviceClass gpu.nvidia.com",
            "dranet fork (IPVLAN children)",
            "  → DeviceClass dra.net (rail VFs only)",
            "namespace compass: Jobs, claims,",
            "  headless Services, watcher pods",
            "no Kueue: two trays, one Job at a time",
        ],
    )
    panel(
        ax,
        8.2,
        3.2,
        7.4,
        4.6,
        "host exporters (every tray)",
        [
            ":9100  node exporter",
            ":9400  DCGM — SM active, PCIe bytes, power",
            ":9500  RDMA — rail bytes, CNP/ECN,",
            "         out-of-sequence, ACK timeouts",
            ":9600  NVLink bytes per link",
            ":9700  PCIe AER errors",
        ],
    )
    panel(
        ax,
        16.0,
        3.2,
        7.4,
        4.6,
        "observability (Terraform)",
        [
            "Grafana Alloy collector in-cluster,",
            "  scrapes the host exporters, ships to",
            "Grafana Cloud Prometheus",
            "  (per-tenant push token, minted by TF)",
            "dashboard: Compass — NCCL fabric counters",
            "  + per-run phase annotations",
        ],
        color=GREEN,
    )
    panel(
        ax,
        23.8,
        3.2,
        7.8,
        4.6,
        "build, tests, results (GitHub)",
        [
            "Actions: ruff · pytest (no GPU) · manifest",
            "  drift check · terraform validate · analysis",
            "  smoke · arm64 image build",
            "→ ghcr.io/drkennetz/compass_takehome",
            "  (mirrored to quay.io)",
            "results/raw/<run>/result.json (schema-",
            "  validated) + per-rank CSV + counters",
        ],
        color=VIOLET,
    )
    arrow(
        ax,
        (11.0, 7.8),
        (11.0, 9.8),
        color=GREEN,
        lw=1.3,
        style="<|-",
        label="scraped",
        loff=(0.85, 0),
        fs=7.5,
    )
    arrow(ax, (15.6, 5.5), (16.0, 5.5), color=GREEN, lw=1.3)
    ax.text(
        16.0,
        1.9,
        "matrix.yaml → render.py → 41 Indexed Jobs · run_matrix.sh runs each cell, collects result.json, pod logs and counter CSVs · python -m analysis → tables, charts, SUMMARY.md, the deck",
        ha="center",
        fontsize=8,
        color=MUTED,
    )

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    fig.savefig(out, dpi=170, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out


if __name__ == "__main__":
    print(build(sys.argv[1] if len(sys.argv) > 1 else "slides/architecture.png"))
