"""What ran where: versions, GPU/NIC topology, NUMA, the NCCL knobs in force. Tolerant of
missing binaries (returns empty strings) so a partial capture never fails a run."""

from __future__ import annotations

import glob
import json
import os
import platform
import shutil
import subprocess
import sys


def _run(cmd: list[str], timeout: int = 30) -> str:
    if not shutil.which(cmd[0]):
        return ""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def versions() -> dict:
    out = {"python": platform.python_version(), "torch": "", "cuda": "", "nccl": "", "driver": ""}
    try:
        import torch  # noqa: PLC0415

        out["torch"] = torch.__version__
        out["cuda"] = torch.version.cuda or ""
        out["nccl"] = ".".join(str(x) for x in torch.cuda.nccl.version())
    except Exception:  # noqa: BLE001 - torch absent or no GPU
        pass
    out["driver"] = _run(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"]).splitlines()[
        0:1
    ] or [""]
    out["driver"] = out["driver"][0] if isinstance(out["driver"], list) else out["driver"]
    return out


def ibdev2netdev(root: str = "/sys/class/infiniband") -> str:
    """'<hca> port 1 ==> <netdev> (Up)' per device, from sysfs (the tool itself is often absent)."""
    lines = []
    for dev in sorted(glob.glob(os.path.join(root, "*"))):
        name = os.path.basename(dev)
        nets = (
            sorted(os.listdir(os.path.join(dev, "device", "net")))
            if os.path.isdir(os.path.join(dev, "device", "net"))
            else []
        )
        state = ""
        try:
            with open(os.path.join(dev, "ports", "1", "state")) as f:
                state = f.read().strip()
        except OSError:
            pass
        lines.append(f"{name} port 1 ==> {','.join(nets) or '-'} ({state or 'unknown'})")
    return "\n".join(lines)


def numa_per_gpu() -> dict:
    """local_rank-ordered PCI bus id -> numa node, from nvidia-smi and sysfs."""
    out = {}
    ids = _run(["nvidia-smi", "--query-gpu=index,pci.bus_id", "--format=csv,noheader"])
    for line in ids.splitlines():
        try:
            idx, bdf = (p.strip() for p in line.split(","))
        except ValueError:
            continue
        bdf = bdf.lower().replace("00000000:", "0000:")
        try:
            with open(f"/sys/bus/pci/devices/{bdf}/numa_node") as f:
                out[idx] = {"bdf": bdf, "numa_node": int(f.read().strip())}
        except OSError:
            out[idx] = {"bdf": bdf, "numa_node": None}
    return out


def topo() -> dict:
    return {
        "nvidia_smi_topo": _run(["nvidia-smi", "topo", "-m"]),
        "ibdev2netdev": ibdev2netdev(),
        "rdma_link": _run(["rdma", "link", "show"]),
        "pod_interfaces": _run(["ip", "-br", "addr"]),
        "numa": numa_per_gpu(),
        "cpu_affinity": str(sorted(os.sched_getaffinity(0))) if hasattr(os, "sched_getaffinity") else "",
    }


def nccl_env_selected() -> dict:
    return {k: v for k, v in sorted(os.environ.items()) if k.startswith("NCCL_")}


def main(argv: list[str] | None = None) -> int:
    print(json.dumps({"versions": versions(), "topology": topo(), "nccl_env": nccl_env_selected()}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
