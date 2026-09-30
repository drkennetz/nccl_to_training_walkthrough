"""1 Hz counter sampler: the *underlying* counters behind every bandwidth number.

Runs on each worker as a plain pod on the pod network with /sys mounted read-only; the RDMA
counters live in sysfs (visible in shared RDMA netns mode), the NIC ring/pause counters come
from `ethtool -S` when the pod holds the netdev, and the GPU-side NVLink / PCIe / SM counters
come from the host DCGM exporter (:9400) when reachable, else `dcgmi dmon`.

Output is a long-format CSV on stdout (collected with `kubectl logs`):
    ts_iso,node,source,device,metric,value
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass

IB_PORT_COUNTERS = (
    "port_xmit_data",
    "port_rcv_data",
    "port_xmit_packets",
    "port_rcv_packets",
    "port_xmit_wait",
    "port_rcv_errors",
    "port_xmit_discards",
    "link_downed",
)
IB_HW_COUNTERS = (
    "out_of_sequence",
    "packet_seq_err",
    "local_ack_timeout_err",
    "rx_icrc_encapsulated",
    "np_cnp_sent",
    "rp_cnp_handled",
    "np_ecn_marked_roce_packets",
    "rx_write_requests",
    "rx_read_requests",
    "req_cqe_error",
    "resp_cqe_error",
    "implied_nak_seq_err",
    "duplicate_request",
)
ETHTOOL_KEYS = re.compile(
    r"^(rx_out_of_buffer|rx_discards_phy|tx_discards_phy|rx_prio[0-9]_pause|tx_prio[0-9]_pause|"
    r"rx_pause_ctrl_phy|tx_pause_ctrl_phy|rx_prio[0-9]_buf_discard|rx_bytes_phy|tx_bytes_phy|"
    r"rx_vport_rdma_unicast_bytes|tx_vport_rdma_unicast_bytes)$"
)
DCGM_FIELDS = {
    "DCGM_FI_PROF_SM_ACTIVE": "sm_active",
    "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE": "tensor_active",
    "DCGM_FI_PROF_DRAM_ACTIVE": "dram_active",
    "DCGM_FI_PROF_PCIE_TX_BYTES": "pcie_tx_bytes",
    "DCGM_FI_PROF_PCIE_RX_BYTES": "pcie_rx_bytes",
    "DCGM_FI_PROF_NVLINK_TX_BYTES": "nvlink_tx_bytes",
    "DCGM_FI_PROF_NVLINK_RX_BYTES": "nvlink_rx_bytes",
    "DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL": "nvlink_bandwidth_total",
    "DCGM_FI_DEV_POWER_USAGE": "power_w",
    "DCGM_FI_DEV_SM_CLOCK": "sm_clock_mhz",
    "DCGM_FI_DEV_GPU_UTIL": "gpu_util",
}
# dcgmi field ids for the fallback (dcgmi dmon -e ...)
DCGMI_IDS = {
    "1002": "sm_active",
    "1004": "tensor_active",
    "1005": "dram_active",
    "1009": "pcie_tx_bytes",
    "1010": "pcie_rx_bytes",
    "1011": "nvlink_tx_bytes",
    "1012": "nvlink_rx_bytes",
    "155": "power_w",
    "100": "sm_clock_mhz",
}


@dataclass
class CounterRow:
    ts_iso: str
    node: str
    source: str
    device: str
    metric: str
    value: float

    def csv(self) -> str:
        return f"{self.ts_iso},{self.node},{self.source},{self.device},{self.metric},{self.value:g}"


def _read_int(path: str) -> int | None:
    try:
        with open(path) as f:
            return int(f.read().strip().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def ib_counters(dev: str, root: str = "/sys/class/infiniband", port: int = 1) -> dict[str, int]:
    base = os.path.join(root, dev, "ports", str(port))
    out: dict[str, int] = {}
    for name in IB_PORT_COUNTERS:
        v = _read_int(os.path.join(base, "counters", name))
        if v is not None:
            # port_xmit_data / port_rcv_data are in 4-byte lanes (octets/4) per the IB spec.
            out[name] = v * 4 if name in ("port_xmit_data", "port_rcv_data") else v
    for name in IB_HW_COUNTERS:
        v = _read_int(os.path.join(base, "hw_counters", name))
        if v is not None:
            out[name] = v
    return out


def parse_ethtool_stats(text: str, keys: re.Pattern = ETHTOOL_KEYS) -> dict[str, int]:
    out = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        k, _, v = line.strip().partition(":")
        k = k.strip()
        if keys.match(k):
            try:
                out[k] = int(v.strip())
            except ValueError:
                pass
    return out


def ethtool_stats(netdev: str) -> dict[str, int]:
    if not shutil.which("ethtool"):
        return {}
    try:
        r = subprocess.run(["ethtool", "-S", netdev], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return {}
    return parse_ethtool_stats(r.stdout)


_PROM_LINE = re.compile(
    r"^(?P<name>[A-Za-z_:][A-Za-z0-9_:]*)\{(?P<labels>[^}]*)\}\s+(?P<value>[-+0-9.eE]+|NaN)"
)
_LABEL = re.compile(r'(\w+)="([^"]*)"')


def parse_dcgm_exposition(text: str, fields: dict[str, str] = DCGM_FIELDS) -> list[tuple[str, str, float]]:
    """Prometheus exposition from the DCGM exporter -> (gpu, metric, value)."""
    out = []
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        m = _PROM_LINE.match(line)
        if not m or m.group("name") not in fields:
            continue
        labels = dict(_LABEL.findall(m.group("labels")))
        gpu = labels.get("gpu") or labels.get("GPU") or labels.get("device", "?")
        try:
            out.append((f"gpu{gpu}", fields[m.group("name")], float(m.group("value"))))
        except ValueError:
            continue
    return out


def dcgm_scrape(url: str, timeout: float = 2.0) -> list[tuple[str, str, float]]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - local exporter
            return parse_dcgm_exposition(resp.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return []


NVLINK_FIELDS = {"nvlink_data_tx_kib_total": "nvlink_tx_bytes", "nvlink_data_rx_kib_total": "nvlink_rx_bytes"}


def parse_nvlink_exposition(text: str) -> list[tuple[str, str, float]]:
    """The host NVLink exporter (:9600): per-GPU, per-link KiB counters -> (gpuN, metric, bytes) summed over links."""
    acc: dict[tuple[str, str], float] = {}
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        m = _PROM_LINE.match(line)
        if not m or m.group("name") not in NVLINK_FIELDS:
            continue
        labels = dict(_LABEL.findall(m.group("labels")))
        try:
            key = (f"gpu{labels.get('gpu', '?')}", NVLINK_FIELDS[m.group("name")])
            acc[key] = acc.get(key, 0.0) + float(m.group("value")) * 1024.0
        except ValueError:
            continue
    return [(g, met, v) for (g, met), v in sorted(acc.items())]


def nvlink_scrape(url: str, timeout: float = 2.0) -> list[tuple[str, str, float]]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - local exporter
            return parse_nvlink_exposition(resp.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return []


def dcgmi_sample() -> list[tuple[str, str, float]]:
    if not shutil.which("dcgmi"):
        return []
    try:
        r = subprocess.run(
            ["dcgmi", "dmon", "-e", ",".join(DCGMI_IDS), "-c", "1"], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.SubprocessError):
        return []
    out, header = [], None
    for line in r.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "#Entity":
            header = parts[1:]
            continue
        if parts[0] == "GPU" and header and len(parts) >= 2 + len(header):
            gpu = parts[1]
            for name, val in zip(header, parts[2:], strict=False):
                fid = {v: k for k, v in DCGMI_IDS.items()}  # noqa: F841 - header uses field names
                try:
                    out.append((f"gpu{gpu}", name.lower(), float(val)))
                except ValueError:
                    pass
    return out


@dataclass
class WatcherConfig:
    node: str
    devs: list[str]
    netdevs: list[str]
    dcgm_url: str
    ib_root: str = "/sys/class/infiniband"
    nvlink_url: str = ""


def sample_once(cfg: WatcherConfig, ts: str | None = None) -> list[CounterRow]:
    ts = ts or dt.datetime.now(dt.UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    rows: list[CounterRow] = []
    for d in cfg.devs:
        for k, v in ib_counters(d, cfg.ib_root).items():
            rows.append(
                CounterRow(ts, cfg.node, "ib_hw_counter" if k in IB_HW_COUNTERS else "ib_counter", d, k, v)
            )
    for n in cfg.netdevs:
        for k, v in ethtool_stats(n).items():
            rows.append(CounterRow(ts, cfg.node, "ethtool", n, k, v))
    dcgm = dcgm_scrape(cfg.dcgm_url) if cfg.dcgm_url else []
    if not dcgm:
        dcgm = dcgmi_sample()
    for gpu, metric, val in dcgm:
        rows.append(CounterRow(ts, cfg.node, "dcgm", gpu, metric, val))
    for gpu, metric, val in nvlink_scrape(cfg.nvlink_url) if cfg.nvlink_url else []:
        rows.append(CounterRow(ts, cfg.node, "nvlink", gpu, metric, val))  # monotonic byte counters
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="bench watcher", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--duration", type=float, default=0, help="seconds; 0 = until killed")
    ap.add_argument("--node", default=os.environ.get("NODE_NAME") or os.uname().nodename)
    ap.add_argument("--devs", default="", help="comma list of RDMA devices; default: every rdma_vf_rail*")
    ap.add_argument("--netdevs", default="", help="comma list of netdevs for ethtool -S (default: none)")
    ap.add_argument("--dcgm-url", default=os.environ.get("DCGM_URL", ""))
    ap.add_argument("--ib-root", default="/sys/class/infiniband")
    ap.add_argument(
        "--nvlink-url",
        default=os.environ.get("NVLINK_URL", ""),
        help="host NVLink exporter, e.g. http://<node>:9600/metrics",
    )
    a = ap.parse_args(argv)
    devs = [d for d in a.devs.split(",") if d] or sorted(
        d for d in (os.listdir(a.ib_root) if os.path.isdir(a.ib_root) else []) if d.startswith("rdma_vf_rail")
    )
    cfg = WatcherConfig(
        a.node, devs, [n for n in a.netdevs.split(",") if n], a.dcgm_url, a.ib_root, a.nvlink_url
    )
    print("ts_iso,node,source,device,metric,value", flush=True)
    t_end = time.time() + a.duration if a.duration else float("inf")
    while time.time() < t_end:
        t0 = time.time()
        for row in sample_once(cfg):
            print(row.csv())
        sys.stdout.flush()
        time.sleep(max(0.0, a.interval - (time.time() - t0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
