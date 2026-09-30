# The cluster underneath: `infra/k8s_bootstrap`

The benchmark ran on two NVIDIA GB300 compute trays (4 GPUs + 4 RDMA rail VFs each) plus one
control-plane tray, leased from a shared Slurm pool and turned into a k3s cluster by the scripts
vendored under `infra/k8s_bootstrap/` (a `git subtree` of `dkennetzoracle/k8s_bootstrap`, branch
`feat/rdma-netns-mode`). This page explains what those scripts do and why, so the environment is
reproducible without reading them all. `scripts/cluster-up.sh` drives the steps below in order.

## Do-no-harm first

The trays are borrowed. The bootstrap's rules (`infra/k8s_bootstrap/CLAUDE.md`, "Never do these")
shape every step: nothing under `/usr/local/bin`, no changes to Slurm, containerd or the
provider-managed daemons (IMEX, DCGM, persistenced), all state on the tray's local disk, and a
`pre` snapshot of every node so `bin/k8s-down` can prove the tray went back as it arrived
(`bin/k8s-verify-clean`: "pristine, 5 benign kernel differences" on every teardown in this work).

## Step by step

| step | command | what happens on the trays |
|---|---|---|
| lease | `bin/k8s-preflight`, `bin/k8s-up --workers 2 --rack <block>/<rack>` | a Slurm job holds the trays for the lease time; `node/install-server.sh` puts k3s on tray 0, `node/install-agent.sh` joins the workers; Cilium (geneve) is the CNI, pods get `10.42/16` |
| **RDMA netns mode** | part of `install-agent.sh` (`RDMA_NETNS_MODE=shared` in `clusters/polite-possum.env`) | see below |
| GPUs | `bin/k8s-gpu --dra` | the NVIDIA GPU Operator in **DRA mode**: no `nvidia.com/gpu` extended resource; pods reference a `ResourceClaim` against DeviceClass `gpu.nvidia.com`. IMEX (multi-node NVLink) is the host's own daemon, reached through the `cdi.k8s.io/imex` annotation on the `nvidia` runtime class — the operator's ComputeDomain feature is off because it would mask a provider-managed service |
| NICs | `helm install dranet` (fork) + `deploy/k8s/deviceclass-dranet.yaml` | the network-DRA driver publishes one device per rail VF (`rdma_vf_rail0..3`, filter in `deploy/k8s/dranet-values.yaml`) |
| namespace | `kubectl create ns compass` + pull secret | the benchmark's Jobs and the counter watchers live here |
| probe | `deploy/k8s/probe/probe-rails.yaml` | one pod per worker takes one rail; proves the design before any GPU run |

## The RDMA netns mode, and why it is set before k3s

Linux runs the RDMA subsystem in one of two network-namespace modes:

- **exclusive** (the image default): an RDMA device belongs to exactly one netns. Giving a pod a
  rail means *moving* the RDMA device (and, with a passthrough claim, the netdev) into the pod. On
  this site the node health check inventories the rails on the host, so a moved VF reads as a broken
  tray and gets it drained and rebooted — three racks were lost that way on 2026-09-24.
- **shared**: RDMA devices are visible from every netns; a pod needs only the device's char devices
  injected. Combined with dranet's **IPVLAN** interface type (a child interface in the pod, the VF
  stays on the host with its address and routes), nothing leaves the host and the site check stays
  green. This is the combination the benchmark uses.

The kernel refuses to change the mode (`EBUSY`) while *any* network namespace besides the root one
exists, and on a k3s node every pod sandbox is one. Doing it on a live node means killing every pod
first. So the bootstrap does it in `node/install-agent.sh`, on the fresh tray, **before k3s is
installed**, guarded by a namespace count (`lsns -t net`, `/run/netns`). The `pre` snapshot records
the mode found (`rdma-system.txt`) and `node/teardown.sh` restores it once the pods are gone, after
which the mode also reverts by itself on the next reboot. dranet detects the mode at start-up
(`RDMA subsystem in mode: shared` in its log), which is why it is installed after.

## What the probe showed (2026-09-30, rack 3uwoq/6g3ya)

In the pod: `rdma_vf_rail0@if28` as an IPVLAN child with a SLAAC global address and an RA default
route; `/dev/infiniband/{rdma_cm,umad0,uverbs4}`; `ibv_devinfo -l` → one HCA; GID index **7** (see
[gid-discovery.md](gid-discovery.md)); `ibv_rc_pingpong` between the two pods on that GID. On the
host at the same time: `rdma_vf_rail0` still `UP` with its own address, `rdma link` still four rails,
no IPVLAN device in the root namespace.

## Reproducing elsewhere

Any Kubernetes cluster with: DRA enabled (GA since 1.34), the NVIDIA DRA driver, RDMA-capable NICs
whose host runs `rdma system set netns shared` before the kubelet starts, and a dranet build with the
IPVLAN type. The manifests in `deploy/k8s/` do not know about Slurm or this site; only
`scripts/cluster-up.sh` and `infra/` do.
