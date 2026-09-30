#!/usr/bin/env bash
# cluster-up.sh — the two-worker GB300 cluster this benchmark ran on, end to end, from the vendored
# bootstrap (infra/k8s_bootstrap). Foreground only; every step is idempotent.
#
#   scripts/cluster-up.sh --rack <block>/<rack> [--workers 2] [--lease-time 3-00:00:00]
#
# 1 lease + k3s (RDMA netns mode "shared" is set on each worker BEFORE k3s, see RDMA_NETNS_MODE)
# 2 GPU Operator in DRA mode (DeviceClass gpu.nvidia.com)
# 3 dranet fork chart (IPVLAN rail children) + DeviceClass dra.net
# 4 namespace compass + Quay pull secret (from ~/dkennetz/.quay: line 1 user, line 2 token)
# 5 the one-rail probe (deploy/k8s/probe) — proves the VF stays on the host and RDMA works in a pod
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd); BOOT="$REPO/infra/k8s_bootstrap"
RACK=""; WORKERS=2; LEASE="3-00:00:00"; CREDS_DIR="${CREDS_DIR:-$HOME/dkennetz}"
DRANET_SRC="${DRANET_SRC:-$HOME/dkennetz/dranet}"   # a checkout of dkennetzoracle/dranet@slaac-addressing (for the chart)
while [[ $# -gt 0 ]]; do case "$1" in
  --rack) RACK="$2"; shift ;; --workers) WORKERS="$2"; shift ;; --lease-time) LEASE="$2"; shift ;;
  --dranet-src) DRANET_SRC="$2"; shift ;; -h|--help) sed -n 2,12p "$0"; exit 0 ;; *) echo "unknown $1" >&2; exit 2 ;; esac; shift; done
[[ -n "$RACK" ]] || { echo "--rack <block>/<rack> is required (bin/k8s-status lists idle racks)" >&2; exit 2; }
[[ -d "$DRANET_SRC/deployments/helm/dranet" ]] || { echo "--dranet-src must point at a dranet checkout (branch slaac-addressing)" >&2; exit 2; }
export KUBECONFIG="${KUBECONFIG:-$HOME/.local/state/k8s-bootstrap/polite-possum/kubeconfig}"
step() { printf '\n### %s\n' "$*"; }

step "1 lease $WORKERS worker(s) on $RACK and install k3s"
( cd "$BOOT" && bin/k8s-preflight --rack "$RACK" --workers "$WORKERS" && bin/k8s-up --cluster polite-possum --rack "$RACK" --workers "$WORKERS" --lease-time "$LEASE" --yes )
for n in $(kubectl get nodes -l k8s-bootstrap.io/role=worker -o name | cut -d/ -f2); do
  printf '  %s: %s\n' "$n" "$(ssh -o BatchMode=yes -o LogLevel=ERROR "${n^^}" rdma system 2>/dev/null || echo '(ssh unavailable)')"
done

step "2 GPU stack in DRA mode"
( cd "$BOOT" && bin/k8s-gpu --dra )

step "3 dranet fork + DeviceClass"
kubectl create namespace dranet --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace dranet pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
kubectl create namespace compass --dry-run=client -o yaml | kubectl apply -f - >/dev/null
for ns in compass dranet; do
  kubectl -n "$ns" create secret docker-registry compass-quay-pull --docker-server=quay.io \
    --docker-username="$(sed -n 1p "$CREDS_DIR/.quay" | tr -d '\r\n')" --docker-password="$(sed -n 2p "$CREDS_DIR/.quay" | tr -d '\r\n')" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
helm upgrade --install dranet "$DRANET_SRC/deployments/helm/dranet" -n dranet -f "$REPO/deploy/k8s/dranet-values.yaml" --wait --timeout 4m | tail -n 1
kubectl apply -f "$REPO/deploy/k8s/deviceclass-dranet.yaml"
sleep 20
kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="dra.net")] | "  dranet slices=\(length) devices=\([.[].spec.devices[]] | length)"'

step "4 probe: one rail per worker as an IPVLAN child"
kubectl apply -f "$REPO/deploy/k8s/probe/probe-rails.yaml" >/dev/null
kubectl -n compass wait --for=condition=Ready pod -l app=probe-rail --timeout=900s
kubectl -n compass exec probe-rail-0 -- python -m bench gid
kubectl delete -f "$REPO/deploy/k8s/probe/probe-rails.yaml" --wait=true >/dev/null
echo; echo "ready: COMPASS_ALLOW_NIC_CLAIMS=1 deploy/k8s/run_matrix.sh --image <ref@digest>"
