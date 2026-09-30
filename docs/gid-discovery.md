# Why the RoCE GID index is 3 on the host and 7 in the pod — and how the code finds it

NCCL's InfiniBand transport sends RoCE v2 packets from the address at `NCCL_IB_GID_INDEX`. Most
recipes hard-code `3`. This repository discovers it (`python -m bench gid`), because the right index
depends on where the process runs, and a wrong one fails late and quietly (QP connect errors, or a
communicator that "connects" and moves zero bytes).

## What the GID table is

Every RDMA device exposes a GID table per port in sysfs:

| path | meaning |
|---|---|
| `/sys/class/infiniband/<hca>/ports/1/gids/<i>` | the 128-bit GID (formatted like an IPv6 address) |
| `/sys/class/infiniband/<hca>/ports/1/gid_attrs/types/<i>` | `IB/RoCE v1` or `RoCE v2` |
| `/sys/class/infiniband/<hca>/ports/1/gid_attrs/ndevs/<i>` | the netdev whose IP address this GID mirrors |

For RoCE the kernel (`roce_gid_mgmt`) derives GIDs from the IP addresses of the netdev bound to the
device and of every *upper* device on it (VLAN, macvlan, ipvlan children). mlx5 writes two entries per
address: one per RoCE version. On a rail VF with one SLAAC address the table therefore reads:

```
[0] fe80::…              IB/RoCE v1   rdma_vf_rail0   link-local
[1] fe80::…              RoCE v2      rdma_vf_rail0   link-local
[2] fdcd:8300:a1af:…     IB/RoCE v1   rdma_vf_rail0   global
[3] fdcd:8300:a1af:…     RoCE v2      rdma_vf_rail0   global      <- index 3 on the host
```

RoCE v1 is a pure L2 protocol and does not route; a link-local address does not leave the link. The
only entry that carries traffic across the fabric is **the RoCE v2 entry with the global address**,
which on a plain VF is index 3.

## What changes inside the pod

The benchmark pods do not take the VF. dranet gives each pod an **IPVLAN child** of the VF, and the
child autoconfigures its own global address from the fabric's router advertisements. The kernel adds
that address to the parent device's GID table, after the parent's own entries:

```
[4] fe80::…              IB/RoCE v1   rdma_vf_rail0   link-local  (the child's)
[5] fe80::…              RoCE v2      rdma_vf_rail0   link-local
[6] fdcd:8300:a1af:…     IB/RoCE v1   rdma_vf_rail0   global
[7] fdcd:8300:a1af:…     RoCE v2      rdma_vf_rail0   global      <- index 7 in the pod
```

Recorded on this cluster (probe pod, worker 1): the pod's sysfs shows only entries 4–7 (GID
entries are namespace-scoped), and `python -m bench gid` picks 7. A second pod on the same rail
would land on 11, a third on 15: the index is a property of *the namespace and the order addresses
appeared*, which is why it must be looked up, not assumed.

## What the code does

`bench/gid.py`:

1. lists the rail HCAs the process can actually open — in shared RDMA netns mode sysfs shows every
   host device, but only the claimed ones have their `uverbs` char device in `/dev/infiniband`;
2. reads each table with its type and netdev attributes and classifies every GID (link-local,
   IPv4-mapped, global, unused slot);
3. picks the RoCE v2 entry with a global address, preferring an exact match on the pod interface's
   address or name when given, else the newest (upper devices are appended after the parent's);
4. checks every claimed HCA agrees, because NCCL takes a single index for all of them, and exports
   `NCCL_IB_GID_INDEX`. The launcher in every RDMA cell runs this before `torchrun`; the chosen table
   is recorded in `result.json` under `topology.gid_table`.

NCCL ≥ 2.21 can also pick a GID by itself from `NCCL_IB_ADDR_FAMILY` / `NCCL_IB_ADDR_RANGE`; the explicit
lookup is kept because it produces evidence (the table) rather than a default.
