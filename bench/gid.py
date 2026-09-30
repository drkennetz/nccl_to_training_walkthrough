"""Discover the RoCE v2 GID index for NCCL instead of asserting "we know it is 3".

Every RDMA device exposes its GID table under sysfs:

    /sys/class/infiniband/<hca>/ports/1/gids/<i>            the 128-bit GID (an IPv6-shaped address)
    /sys/class/infiniband/<hca>/ports/1/gid_attrs/types/<i> "IB/RoCE v1" or "RoCE v2"
    /sys/class/infiniband/<hca>/ports/1/gid_attrs/ndevs/<i> the netdev whose address this GID mirrors

For a RoCE device the kernel derives GIDs from the IP addresses of the netdev (and of any upper
device on top of it: VLAN, macvlan, ipvlan children). mlx5 writes TWO entries per address, one
per RoCE version, so the table reads:

    0/1  fe80::...   link-local          v1 / v2
    2/3  <global>    first global IPv6   v1 / v2     <- index 3 on a plain rail VF
    4/5  fe80::...   an ipvlan child's link-local
    6/7  <global>    the child's global (SLAAC)     <- index 7 when a pod's child holds the address

NCCL sends RoCE v2 (UDP-encapsulated) packets sourced from the GID at NCCL_IB_GID_INDEX; a
link-local or a v1 entry does not route across the fabric, and a wrong index shows up as
"QP connect failed" or zero bytes on the wire. So: pick the RoCE v2 entry whose address is global
and (when we know it) belongs to the interface the pod actually holds, then check every claimed
HCA agrees, because NCCL takes one index for all of them.

    python -m bench gid                     # table + chosen index for every HCA
    eval "$(python -m bench gid --export)"  # export NCCL_IB_GID_INDEX=<i>
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import sys
from dataclasses import asdict, dataclass

SYSFS_IB = "/sys/class/infiniband"


@dataclass
class GidEntry:
    index: int
    gid: str
    type: str  # "RoCE v2" | "IB/RoCE v1" | ""
    ndev: str
    scope: str  # "global" | "link-local" | "ipv4-mapped" | "zero" | "other"

    def to_dict(self) -> dict:
        return asdict(self)


def classify_gid(gid: str) -> str:
    """'fe80::…' -> link-local, '::ffff:a.b.c.d' -> ipv4-mapped, all-zero -> zero, else global."""
    try:
        addr = ipaddress.IPv6Address(gid)
    except ValueError:
        return "other"
    if int(addr) == 0:
        return "zero"
    if addr.is_link_local:
        return "link-local"
    if addr.ipv4_mapped is not None:
        return "ipv4-mapped"
    if addr.is_global or addr.is_private:
        return "global"
    return "other"


def _read(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def read_gid_table(hca: str, port: int = 1, root: str = SYSFS_IB) -> list[GidEntry]:
    base = os.path.join(root, hca, "ports", str(port))
    gdir = os.path.join(base, "gids")
    try:
        idx = sorted(int(n) for n in os.listdir(gdir) if n.isdigit())
    except OSError:
        return []
    out = []
    for i in idx:
        gid = _read(os.path.join(gdir, str(i)))
        if not gid or classify_gid(gid) == "zero":
            continue  # an unused slot
        out.append(
            GidEntry(
                index=i,
                gid=gid,
                type=_read(os.path.join(base, "gid_attrs", "types", str(i))),
                ndev=_read(os.path.join(base, "gid_attrs", "ndevs", str(i))),
                scope=classify_gid(gid),
            )
        )
    return out


def pick_index(table: list[GidEntry], want_ndev: str | None = None, want_addr: str | None = None) -> GidEntry:
    """The RoCE v2 entry with a global address, preferring a match on the pod's interface or
    address when given. Raises LookupError with the table when nothing qualifies."""
    cands = [e for e in table if e.type.lower().startswith("roce v2") and e.scope == "global"]
    if want_addr:
        exact = [e for e in cands if ipaddress.IPv6Address(e.gid) == ipaddress.IPv6Address(want_addr)]
        if exact:
            return exact[0]
    if want_ndev:
        by_dev = [e for e in cands if e.ndev == want_ndev]
        if by_dev:
            return by_dev[0]
    if cands:
        # No hint: take the LAST global v2 entry. Upper devices (an ipvlan child in the pod)
        # are added after the parent's own address, so the newest address is the pod's.
        return cands[-1]
    raise LookupError("no global RoCE v2 GID; table=" + json.dumps([e.to_dict() for e in table]))


SYSFS_VERBS = "/sys/class/infiniband_verbs"


def usable_hcas(verbs_root: str = SYSFS_VERBS, dev_root: str = "/dev/infiniband") -> set[str] | None:
    """HCAs this process can open: the uverbs char device exists in /dev. In shared RDMA netns
    mode sysfs lists EVERY host device, but a pod only gets the char devices of the ones it
    claimed; NCCL can only use those. None when the verbs tree is absent (no filtering)."""
    try:
        entries = os.listdir(verbs_root)
    except OSError:
        return None
    out = set()
    for u in entries:
        if not u.startswith("uverbs"):
            continue
        if not os.path.exists(os.path.join(dev_root, u)):
            continue
        try:
            with open(os.path.join(verbs_root, u, "ibdev")) as f:
                out.add(f.read().strip())
        except OSError:
            pass
    return out


def list_hcas(
    prefix: str = "rdma_vf_rail", root: str = SYSFS_IB, usable: set[str] | None = None
) -> list[str]:
    """Rail HCAs visible in sysfs, restricted to the ones this pod can open (see usable_hcas)."""
    try:
        names = sorted(h for h in os.listdir(root) if h.startswith(prefix))
    except OSError:
        return []
    if usable is None:
        usable = usable_hcas()
    if usable is not None:
        names = [n for n in names if n in usable]
    return names


def discover(
    hcas: list[str], root: str = SYSFS_IB, want_ndev: str | None = None, want_addr: str | None = None
) -> dict:
    """Per-HCA tables and choices, plus the single index NCCL can use (or an error)."""
    per = {}
    chosen = {}
    for h in hcas:
        table = read_gid_table(h, root=root)
        per[h] = [e.to_dict() for e in table]
        try:
            chosen[h] = pick_index(table, want_ndev, want_addr).index
        except LookupError as e:
            chosen[h] = None
            per[h + ":error"] = str(e)
    ok_idx = {i for i in chosen.values() if i is not None}
    result = {"hcas": hcas, "tables": per, "chosen": chosen, "index": None, "consistent": False}
    if ok_idx and len(ok_idx) == 1 and all(i is not None for i in chosen.values()):
        result["index"] = ok_idx.pop()
        result["consistent"] = True
    return result


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="bench gid", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--hca", action="append", help="HCA name (repeatable); default: every rdma_vf_rail*")
    ap.add_argument("--ndev", help="prefer the GID mirrored from this netdev (e.g. the pod's ipvlan child)")
    ap.add_argument("--addr", help="prefer the GID equal to this IPv6 address")
    ap.add_argument("--root", default=SYSFS_IB)
    ap.add_argument("--export", action="store_true", help="print 'export NCCL_IB_GID_INDEX=<i>' only")
    ap.add_argument(
        "--list-hcas", action="store_true", help="print the usable rail HCAs, comma-separated, and exit"
    )
    ap.add_argument(
        "--wait",
        type=float,
        default=0,
        help="seconds to keep polling until every HCA has a global RoCE v2 GID (SLAAC takes a moment)",
    )
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    hcas = a.hca or list_hcas(root=a.root)
    if a.list_hcas:
        print(",".join(hcas))
        return 0 if hcas else 2
    if not hcas:
        print("no RDMA devices under " + a.root, file=sys.stderr)
        return 2
    import time  # noqa: PLC0415

    deadline = time.monotonic() + a.wait
    while True:
        r = discover(hcas, root=a.root, want_ndev=a.ndev, want_addr=a.addr)
        if r["consistent"] or time.monotonic() >= deadline:
            break
        time.sleep(1.0)
    if a.export:
        if not r["consistent"]:
            print("# GID discovery failed: " + json.dumps(r["chosen"]), file=sys.stderr)
            return 1
        print(f"export NCCL_IB_GID_INDEX={r['index']}")
        return 0
    if a.json:
        print(json.dumps(r, indent=2))
    else:
        for h in hcas:
            print(f"{h}:")
            for e in r["tables"][h]:
                mark = " <-- chosen" if r["chosen"].get(h) == e["index"] else ""
                print(f"  [{e['index']}] {e['gid']:<40} {e['type']:<12} {e['ndev']:<20} {e['scope']}{mark}")
        print(f"NCCL_IB_GID_INDEX={r['index']}  consistent={r['consistent']}")
    return 0 if r["consistent"] else 1


if __name__ == "__main__":
    sys.exit(main())
