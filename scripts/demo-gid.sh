#!/usr/bin/env bash
# demo-gid.sh — show, side by side, the RoCE GID table on the HOST rail VF (index 3) and inside a pod
# holding an IPVLAN child of the same VF (index 7), then a pingpong between the two probe pods on that GID.
# Needs the probe pods from deploy/k8s/probe/probe-rails.yaml Running, KUBECONFIG set, and ssh to the tray.
set -euo pipefail
NS=${NAMESPACE:-compass}; DEV=${DEV:-rdma_vf_rail0}
node=$(kubectl -n "$NS" get pod probe-rail-0 -o jsonpath='{.spec.nodeName}')
host=${HOST_OVERRIDE:-${node^^}}
echo "### HOST $host — $DEV GID table (sysfs)"
ssh -o BatchMode=yes -o LogLevel=ERROR "$host" "for i in 0 1 2 3 4 5 6 7; do g=\$(cat /sys/class/infiniband/$DEV/ports/1/gids/\$i); [ \"\$g\" = 0000:0000:0000:0000:0000:0000:0000:0000 ] && continue; printf '  [%s] %-40s %-12s %s\n' \$i \"\$g\" \"\$(cat /sys/class/infiniband/$DEV/ports/1/gid_attrs/types/\$i)\" \"\$(cat /sys/class/infiniband/$DEV/ports/1/gid_attrs/ndevs/\$i)\"; done; echo; echo '  host still owns the VF:'; ip -br addr show dev $DEV | sed 's/^/    /'; rdma link show | grep -c rdma_vf | sed 's/^/    rdma links: /'"
echo
echo "### POD probe-rail-0 on $node — same device, the pod's namespace"
kubectl -n "$NS" exec probe-rail-0 -- bash -lc "ip -br addr show dev $DEV | sed 's/^/  child: /'; ls /dev/infiniband | tr '\n' ' ' | sed 's/^/  char devices: /'; echo; python -m bench gid --hca $DEV"
echo
echo "### pingpong probe-rail-1 -> probe-rail-0 over $DEV on the discovered GID (1 MiB x 200, 4 KiB path MTU)"
gid=$(kubectl -n "$NS" exec probe-rail-0 -- python -m bench gid --hca "$DEV" --export | sed 's/.*=//')
ip0=$(kubectl -n "$NS" get pod probe-rail-0 -o jsonpath='{.status.podIP}')
kubectl -n "$NS" exec probe-rail-0 -- bash -lc "timeout 60 ibv_rc_pingpong -d $DEV -g $gid -m 4096 -s 1048576 -n 200 | tail -n 2" &
sleep 3
kubectl -n "$NS" exec probe-rail-1 -- bash -lc "timeout 60 ibv_rc_pingpong -d $DEV -g $gid -m 4096 -s 1048576 -n 200 $ip0 | tail -n 2"
wait
