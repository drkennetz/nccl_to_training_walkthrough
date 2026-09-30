#!/usr/bin/env bash
# run_matrix.sh — run every rendered cell whose result is missing, one at a time, foreground.
#
#   deploy/k8s/run_matrix.sh [--only <glob>] [--image <ref@digest>] [--dry-run] [--no-watchers]
#
# Per cell: start a counter watcher pod on each worker, apply the cell's manifests, wait for the
# Job, collect (collect.py), delete the cell and the watchers, append to results/run.log.
# Resumable: a cell with results/raw/<run_id>/result.json is skipped. RDMA cells (rails > 0) are
# refused unless COMPASS_ALLOW_NIC_CLAIMS=1 — a rail claim on a site whose node health check
# inventories the rails can drain the tray; this repo's claims are IPVLAN children (the VF stays),
# but the guard makes that a conscious decision. Nothing here uses hostNetwork.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
NS=${NAMESPACE:-compass}; ONLY="*"; IMAGE=""; DRY=0; WATCHERS=1; OUT="$REPO/results/raw"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift ;;
    --image) IMAGE="$2"; shift ;;
    --dry-run) DRY=1 ;;
    --no-watchers) WATCHERS=0 ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac; shift
done
PY=${PY:-$REPO/.venv/bin/python}; [[ -x "$PY" ]] || PY=python3
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$OUT/../run.log"; }
mkdir -p "$OUT"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

# Watchers: one per worker, rendered from the same defaults (image, pull secret).
watchers_up() {
  (( WATCHERS )) || return 0
  kubectl get nodes -l k8s-bootstrap.io/role=worker -o json \
   | jq -r '.items[] | "\(.metadata.name) \(.status.addresses[] | select(.type=="InternalIP") | .address)"' \
   | while read -r node ip; do
       "$PY" - "$node" "$ip" "$IMAGE" <<'PYEOF' | kubectl apply -f - >/dev/null
import sys, os
sys.path.insert(0, os.environ.get("HERE", "deploy/k8s"))
from render import load_matrix, render_watcher
m = load_matrix(); d = m["defaults"]
if sys.argv[3]: d["image"] = sys.argv[3]
print(render_watcher(d, sys.argv[1], sys.argv[2]))
PYEOF
     done
  kubectl -n "$NS" wait --for=condition=Ready pod -l app=compass-watcher --timeout=180s >/dev/null
}
watchers_down() { (( WATCHERS )) && kubectl -n "$NS" delete pod -l app=compass-watcher --wait=true --timeout=120s >/dev/null 2>&1 || true; }
export HERE

for dir in "$HERE"/rendered/*/; do
  run_id=$(basename "$dir")
  [[ "$run_id" == $ONLY ]] || continue
  if [[ -s "$OUT/$run_id/result.json" ]]; then log "skip $run_id (done)"; continue; fi
  manifest="$dir/manifests.yaml"
  rails=$(grep -c 'resourceClaimTemplateName: .*-rails' "$manifest" || true)
  if (( rails > 0 )) && [[ "${COMPASS_ALLOW_NIC_CLAIMS:-0}" != 1 ]]; then
    log "refuse $run_id: needs rail NIC claims; set COMPASS_ALLOW_NIC_CLAIMS=1 (IPVLAN children, VF stays on the host)"; continue
  fi
  if (( DRY )); then log "DRY $run_id"; continue; fi
  log "run  $run_id"
  t0=$(date +%s)
  # leftovers from an interrupted pass (a Job is immutable, so apply would fail)
  kubectl -n "$NS" delete -f "$manifest" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  watchers_up
  if [[ -n "$IMAGE" ]]; then sed "s#^\(\s*image:\s*\).*#\1$IMAGE#" "$manifest"; else cat "$manifest"; fi | kubectl apply -f - >/dev/null
  job="compass-$run_id"
  # poll for Complete OR Failed: `kubectl wait --for=condition=complete` would sit through a failure
  rc=1; deadline=$(( $(date +%s) + ${CELL_TIMEOUT:-1500} ))
  while (( $(date +%s) < deadline )); do
    st=$(kubectl -n "$NS" get job "$job" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)
    [[ "$st" == *"Complete=True"* ]] && { rc=0; break; }
    [[ "$st" == *"Failed=True"* ]] && { rc=2; break; }
    sleep 5
  done
  if (( rc != 0 )); then
    if kubectl -n "$NS" get job "$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' | grep -q True; then
      log "FAIL $run_id: job failed ($(kubectl -n "$NS" get job "$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].message}'))"
    else
      log "FAIL $run_id: timeout waiting for job"
    fi
    mkdir -p "$OUT/$run_id"
    for p in $(kubectl -n "$NS" get pods -l "app=$job" -o name); do kubectl -n "$NS" logs "$p" > "$OUT/$run_id/$(basename "$p").failed.log" 2>&1 || true; done
  else
    if "$PY" "$HERE/collect.py" "$run_id" --namespace "$NS" --out "$OUT" >/dev/null; then
      log "done $run_id in $(( $(date +%s) - t0 ))s: $(grep -h '^PERF' "$OUT/$run_id"/pod-0.log | tail -n 1 | cut -c1-160)"
    else
      log "FAIL $run_id: collect failed"
    fi
  fi
  kubectl -n "$NS" delete -f "$manifest" --wait=true --timeout=180s >/dev/null 2>&1 || true
  watchers_down
  # the kubelet holds a finished pod's devices until the pod object is gone; let the claims settle
  sleep "${SETTLE_S:-20}"
done
log "matrix pass complete: $(ls "$OUT"/*/result.json 2>/dev/null | wc -l | tr -d ' ') result(s)"
