---
name: cluster-status
description: Inspect the state of the bootstrapped Kubernetes cluster and its Slurm leases on a borrowed GPU cluster. Use when asked what is running, which trays or racks are held, whether nodes are healthy, how much capacity is free, or to diagnose why a node is NotReady, drained, or failed to join. Read-only.
---

# Cluster status

All commands here are read-only and safe to run at any time.

## Start here

```bash
bin/k8s-status --nodes
```

That single command reports, in order: Slurm leases and their job states, every leased
tray with its Slurm state and rack, free capacity per rack, and Kubernetes node/pod
health. Read it before running anything else — most questions are answered by it.

## Interpreting what you see

**`AVAILABLE CAPACITY` is filtered, not total.** It excludes localblocks with 7+ racks
(`EXCLUDE_LOCALBLOCKS` in `clusters/*.env`), which are reserved for other people's large
jobs. Most of the cluster's idle capacity usually lives in those excluded blocks, so a
small number here is normal and is not a reason to widen the filter.

**Trays are counted per rack for a reason.** A rack is 18 trays and one NVL72 NVLink
domain with one `CliqueId`. Multi-node NVLink works only *within* a rack. If a rack shows
fewer than 18 idle trays, a full-rack cluster is not currently possible — pick a smaller
size rather than spreading a node pool across two racks.

**A lease in state `GONE`** means the Slurm job ended but state is still recorded. Nodes
may have been released without teardown. Run `bin/k8s-verify-clean` immediately.

## Diagnosing specific symptoms

| Symptom | Check | Likely cause |
|---|---|---|
| Node `NotReady`, or an agent never joined | `bin/k8s-status --nodes` | Its lease expired and the trap tore it down. Confirm with `squeue -u $USER`. |
| Node shows `drain` in Slurm | `sinfo -h -N -n <node> -o '%E'` | The OCI healthcheck ran against it. It was idle rather than leased. |
| GPUs not advertised on a node | `kubectl describe node <node>` | GPU Operator device plugin not ready, or the node lacks the `nvidia` RuntimeClass. |
| Multi-node NCCL slow or failing | `CLIQUE` column in `bin/k8s-status` | Nodes span two racks, so two NVLink domains. Pin the job to one rack. |
| `ImagePullBackOff` on something new | `kubectl describe pod` | No `linux/arm64` image. Every node here is aarch64. |

## Useful raw queries

```bash
squeue -u "$USER" -o '%.10i %.30j %.10T %.12l %.6D %R'   # our leases in Slurm's words
sinfo -h -N -n <node> -o '%N|%t|%E'                       # one node's state and drain reason
scontrol show node <node>                                 # CliqueId, Gres, topology, reason
tail -50 "$STATE_DIR/leases/<lease>.slurm.log"            # what a lease job printed
```

`STATE_DIR` is `~/.local/state/k8s-bootstrap/<cluster>/`. It holds lease job ids, node
lists, the kubeconfig, and pre-install snapshots. Nothing in it belongs in git.

## Do not

- Do not run `scontrol update` or create reservations to free up capacity.
- Do not widen `EXCLUDE_LOCALBLOCKS` to find more nodes.
- Do not `scancel` a lease directly to tear down a cluster — use `bin/k8s-down`, which
  uninstalls k3s *before* releasing the nodes. See `CLAUDE.md`.
