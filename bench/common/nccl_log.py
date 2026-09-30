"""Parse NCCL's own INIT/GRAPH report (NCCL_DEBUG=INFO written to a per-rank NCCL_DEBUG_FILE).

NCCL names the transport it chose per channel: "via P2P/MNNVL" (multi-node NVLink),
"via NET/IB/<n>(/GDRDMA)" (RDMA, optionally GPUDirect), "via NET/Socket" (TCP), "via SHM",
"via P2P/CUMEM" etc. Counting those lines is the *evidence* of which path carried the data;
the bandwidth number alone cannot tell a silent TCP fallback from a fabric run.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field

_VERSION = re.compile(r"NCCL version (\S+)")
_HCA = re.compile(r"\[(\d+)\]([A-Za-z0-9_-]+)(?::\d+)?/(?:RoCE|IB)")
_NETWORK = re.compile(r" Using network (\S+)")
_MNNVL = re.compile(r"MNNVL (\d)")


@dataclass
class TransportCounts:
    mnnvl_channels: int = 0
    net_ib_channels: int = 0
    net_ib_gdr_channels: int = 0
    net_socket_channels: int = 0
    p2p_channels: int = 0
    shm_channels: int = 0
    network: str = ""
    mnnvl: str = ""
    nccl_version: str = ""
    hcas: list[str] = field(default_factory=list)
    ranks_reporting: int = 0
    sample: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def parse_nccl_log(path: str) -> TransportCounts:
    """Count the data-path lines NCCL wrote for one rank's communicator. Missing file -> zeros."""
    c = TransportCounts()
    try:
        f = open(path, errors="replace")
    except OSError:
        return c
    with f:
        for line in f:
            if "via P2P/MNNVL" in line:
                c.mnnvl_channels += 1
            if "via NET/Socket" in line:
                c.net_socket_channels += 1
            if "via NET/IB" in line:
                c.net_ib_channels += 1
                if "GDRDMA" in line:
                    c.net_ib_gdr_channels += 1
            if "via P2P/" in line:
                c.p2p_channels += 1
            if "via SHM" in line:
                c.shm_channels += 1
            m = _NETWORK.search(line)
            if m and not c.network:
                c.network = m.group(1)
            m = _MNNVL.search(line)
            if m and "nRanks" in line and not c.mnnvl:
                c.mnnvl = m.group(1)
            m = _VERSION.search(line)
            if m and not c.nccl_version:
                c.nccl_version = m.group(1)
            if "NET/IB : Using" in line:
                for m in _HCA.finditer(line):
                    if m.group(2) not in c.hcas:
                        c.hcas.append(m.group(2))
            if len(c.sample) < 3 and ("Channel" in line or "Connected" in line or "Trees" in line):
                c.sample.append(line.strip()[-160:])
    c.ranks_reporting = 1
    return c


def merge_counts(per_rank: list[TransportCounts]) -> TransportCounts:
    out = TransportCounts()
    for r in per_rank:
        out.mnnvl_channels += r.mnnvl_channels
        out.net_ib_channels += r.net_ib_channels
        out.net_ib_gdr_channels += r.net_ib_gdr_channels
        out.net_socket_channels += r.net_socket_channels
        out.p2p_channels += r.p2p_channels
        out.shm_channels += r.shm_channels
        out.ranks_reporting += r.ranks_reporting
        out.network = out.network or r.network
        out.mnnvl = out.mnnvl or r.mnnvl
        out.nccl_version = out.nccl_version or r.nccl_version
        for h in r.hcas:
            if h not in out.hcas:
                out.hcas.append(h)
        if not out.sample and r.sample:
            out.sample = list(r.sample)
    return out


def classify_path(c: TransportCounts) -> str:
    """The inter-node data path this communicator used, from the evidence above."""
    if c.net_socket_channels > 0:
        return "tcp"
    if c.mnnvl_channels > 0 and c.net_ib_channels == 0:
        return "nvlink"
    if c.net_ib_channels > 0:
        return "rdma_gdr" if c.net_ib_gdr_channels == c.net_ib_channels else "rdma"
    return "unknown"
