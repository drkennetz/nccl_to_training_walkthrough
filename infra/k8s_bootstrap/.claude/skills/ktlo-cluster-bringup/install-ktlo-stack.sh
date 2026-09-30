#!/usr/bin/env bash
# install-ktlo-stack.sh — everything after `bin/k8s-up`: GPU Operator, storage, Prometheus, Kueue,
# dranet, the KTLO chart with a per-rack overlay, the Grafana Cloud onboarding and (optionally) the
# inference platform. Idempotent; numbered steps; foreground waits only.
#
#   KTLO_REPO=~/dkennetz/dk_test OVERLAY=/path/live-overrides.yaml install-ktlo-stack.sh [--untaint-control-plane] [--dynamo] [--grafana-cloud]
#   install-ktlo-stack.sh --list | --from N | --only N
#
# Env: KTLO_REPO (ktlo-tech checkout), KTLO_REF (git ref for the chart, default origin/main), OVERLAY
# (overlay file written by step 6 and used by step 7), QUAY_FILE (~/dkennetz/.quay), NGC_FILE
# (~/dkennetz/.ngc), DYNAMO_VERSION (1.4.1), TENANT_NS (inference), LOG_DIR (defaults to $OVERLAY's dir).
# Secrets are piped from their files and never printed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT="$(cd "$HERE/../../.." && pwd)"
KTLO_REPO="${KTLO_REPO:-$HOME/dkennetz/dk_test}"
KTLO_REF="${KTLO_REF:-origin/main}"
CLUSTER="${CLUSTER:-polite-possum}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.local/state/k8s-bootstrap/$CLUSTER/kubeconfig}"
OVERLAY="${OVERLAY:-$HOME/.local/state/k8s-bootstrap/$CLUSTER/live-overrides.yaml}"
LOG_DIR="${LOG_DIR:-$(dirname "$OVERLAY")}"
QUAY_FILE="${QUAY_FILE:-$HOME/dkennetz/.quay}"
NGC_FILE="${NGC_FILE:-$HOME/dkennetz/.ngc}"
DYNAMO_VERSION="${DYNAMO_VERSION:-1.4.1}"
TENANT_NS="${TENANT_NS:-inference}"
PROM_URL="http://ktlo-prometheus-kube-prome-prometheus.ktlo-prometheus.svc:9090"
KUEUE_VERSION="${KUEUE_VERSION:-v0.19.4}"
DRANET_VERSION="${DRANET_VERSION:-v1.4.0}"
export PATH="/usr/local/go/bin:$HOME/.local/bin:$PATH"

UNTAINT=0; DYNAMO=0; GRAFANA_CLOUD=0; FROM=1; ONLY=""; LIST=0
GRAFANA_PW_FILE="${GRAFANA_PW_FILE:-$HOME/dkennetz/.grafana-local}"   # local Grafana admin password (created if absent; never printed)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --untaint-control-plane) UNTAINT=1 ;;
    --dynamo) DYNAMO=1 ;;
    --grafana-cloud) GRAFANA_CLOUD=1 ;;
    --from) FROM="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --list) LIST=1 ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac; shift
done

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
step() { # step N "title" — decides whether to run
  local n="$1" title="$2"
  if [[ $LIST == 1 ]]; then printf '%2d  %s\n' "$n" "$title"; return 1; fi
  if [[ -n "$ONLY" && "$ONLY" != "$n" ]]; then return 1; fi
  if [[ -z "$ONLY" && "$n" -lt "$FROM" ]]; then return 1; fi
  log "== step $n: $title"; return 0
}
wait_for() { # wait_for <seconds> <cmd...> — foreground poll, 20 s period
  local budget="$1"; shift; local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > budget )); then log "timeout after ${budget}s: $*"; return 1; fi
    sleep 20
  done
}
mkdir -p "$LOG_DIR"

# Workers = nodes that can serve GPUs (control-plane tray included once untainted).
gpu_nodes() { kubectl get nodes -l nvidia.com/gpu.present=true -o name | sed 's#node/##'; }
cp_node()   { kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | sed 's#node/##' | head -n1; }
rack_id()   { cp_node | sed -E 's/^gpu-([^-]+-[^-]+)-[0-9]+$/\1/'; }
slurm_name(){ printf 'GPU-%s\n' "${1#gpu-}"; }   # k8s node gpu-<rack>-<n> -> Slurm node GPU-<rack>-<n>

# ------------------------------------------------------------------ 1. GPU Operator + storage
if step 1 "GPU Operator (device plugin) + storage (local-path RWO, nfs RWX)"; then
  ( cd "$BOOT" && bin/k8s-gpu > "$LOG_DIR/k8s-gpu.log" 2>&1 ) || { tail -n 5 "$LOG_DIR/k8s-gpu.log"; exit 1; }
  ( cd "$BOOT" && bin/k8s-platform --storage > "$LOG_DIR/k8s-platform.log" 2>&1 ) || { tail -n 5 "$LOG_DIR/k8s-platform.log"; exit 1; }
  wait_for 300 bash -c '[[ $(kubectl get nodes -o custom-columns=G:.status.allocatable.nvidia\\.com/gpu --no-headers | grep -c "^4$") -ge 17 ]]'
  kubectl get nodes -o custom-columns=G:.status.allocatable.nvidia\\.com/gpu --no-headers | sort | uniq -c | sed 's/^/   gpu allocatable: /'
  kubectl get storageclass --no-headers | awk '{print "   storageclass:", $1, $2}'
fi

# ------------------------------------------------------------------ 2. Prometheus
if step 2 "prometheus-operator CRDs + LOCAL observability stack (Prometheus, Alertmanager, Grafana + KTLO dashboards, Loki, Alloy) + host exporter scrapes"; then
  # Local only (owner, 2026-09-26): nothing leaves the cluster. The self-hosted example's values are
  # layered on the in-cluster Prometheus release so its name/URL (ktlo-prometheus-kube-prome-prometheus)
  # stays what values-gb300.yaml, the connector and the power exporters expect.
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community grafana >/dev/null 2>&1 || true
  helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds -n ktlo-monitor --create-namespace --wait | tail -n 1
  if [[ ! -s "$GRAFANA_PW_FILE" ]]; then ( umask 077; head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24 > "$GRAFANA_PW_FILE" ); log "   local Grafana admin password written to $GRAFANA_PW_FILE (0600)"; fi
  SH="$KTLO_REPO/deploy/examples/self-hosted-observability"
  ( cd "$KTLO_REPO/deploy/examples/in-cluster-prometheus" && \
    helm upgrade --install ktlo-prometheus prometheus-community/kube-prometheus-stack -n ktlo-prometheus --create-namespace \
      -f kube-prometheus-stack-values.yaml -f "$SH/kube-prometheus-stack-values.yaml" \
      --set-file grafana.adminPassword="$GRAFANA_PW_FILE" --wait --timeout 8m | tail -n 1 && \
    kubectl apply -f scrape-host-exporters.yaml | sed 's/^/   /' )
  "$SH/render-dashboards.sh" | sed 's/namespace: ktlo-observability/namespace: ktlo-prometheus/' | kubectl apply -n ktlo-prometheus -f - | sed 's/^/   /' | tail -n 3
  helm upgrade --install ktlo-loki grafana/loki -n ktlo-prometheus -f "$SH/loki-values.yaml" --wait --timeout 6m | tail -n 1
  sed 's/ktlo-loki-gateway\.ktlo-observability\.svc/ktlo-loki-gateway.ktlo-prometheus.svc/' "$SH/alloy-values.yaml" > "$LOG_DIR/alloy-values.local.yaml"
  helm upgrade --install ktlo-alloy grafana/alloy -n ktlo-prometheus -f "$LOG_DIR/alloy-values.local.yaml" --wait --timeout 6m | tail -n 1
  kubectl -n ktlo-prometheus get pods --no-headers | awk '{print $3}' | sort | uniq -c | sed 's/^/   ktlo-prometheus pods: /'
  log "   Grafana: kubectl -n ktlo-prometheus port-forward svc/ktlo-prometheus-grafana 3000:80  (admin / $GRAFANA_PW_FILE)"
fi

# ------------------------------------------------------------------ 3. Kueue
if step 3 "Kueue $KUEUE_VERSION + GB300 manager config"; then
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml" | tail -n 1
  kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s | tail -n 1
  grep -v '^#' "$KTLO_REPO/deploy/kueue/kueue-manager-config-gb300.yaml" > "$LOG_DIR/kueue-cfg.yaml"
  kubectl create configmap kueue-manager-config -n kueue-system --from-file=controller_manager_config.yaml="$LOG_DIR/kueue-cfg.yaml" \
    --dry-run=client -o yaml | kubectl replace -f - >/dev/null
  kubectl rollout restart deploy/kueue-controller-manager -n kueue-system >/dev/null
  kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s | tail -n 1
  wait_for 120 bash -c '[[ -n $(kubectl -n kueue-system get endpoints kueue-webhook-service -o jsonpath="{.subsets[*].addresses[*].ip}") ]]'
  log "   kueue webhook has endpoints"
fi

# ------------------------------------------------------------------ 4. dranet
if step 4 "dranet $DRANET_VERSION + DeviceClass dra.net"; then
  # The driver is installed for sites that allow rail claims; on THIS site KTLO must not claim rails
  # (step 6 writes gpu.rdma.nicCount: 0): a claimed VF leaves the host netns and the site's node
  # health check ("RDMA Route Missing") drained + rebooted three whole racks on 2026-09-24 (#690).
  # DO NOT touch the rails' RA default routes here either (same check: exactly one default route).
  kubectl create namespace dranet --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace dranet pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
  helm upgrade --install dranet oci://registry.k8s.io/networking/charts/dranet --version "$DRANET_VERSION" -n dranet \
    -f "$KTLO_REPO/deploy/examples/dranet/values.yaml" --wait --timeout 6m | tail -n 1
  kubectl apply -f "$KTLO_REPO/deploy/examples/dranet/deviceclass.yaml" | sed 's/^/   /'
  sleep 20
  kubectl get resourceslices -o json | jq -r '[.items[] | select(.spec.driver=="dra.net")] | "   dranet slices=\(length) devices=\([.[].spec.devices[]] | length)"'
fi

# ------------------------------------------------------------------ 5. ktlo namespace + pull secret
if step 5 "namespace ktlo + pull secret ktlo-quay-pull"; then
  kubectl create namespace ktlo --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace ktlo pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
  kubectl -n ktlo create secret docker-registry ktlo-quay-pull --docker-server=quay.io \
    --docker-username="$(sed -n 1p "$QUAY_FILE" | tr -d '\r\n')" --docker-password="$(sed -n 2p "$QUAY_FILE" | tr -d '\r\n')" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "   secret ktlo-quay-pull: $(kubectl -n ktlo get secret ktlo-quay-pull -o jsonpath='{.type}')"
fi

# ------------------------------------------------------------------ 6. rack facts -> overlay
if step 6 "rack facts (clique, driver, rail MTU) -> $OVERLAY"; then
  RACK=$(rack_id); CP=$(cp_node)
  W=$(gpu_nodes | grep -v "^$CP$" | head -n1)
  CLIQUE=$(kubectl get node "$W" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.clique}')
  [[ -n "$CLIQUE" ]] || { echo "no nvidia.com/gpu.clique label on $W (GFD not up yet?)" >&2; exit 1; }
  SSH=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o LogLevel=ERROR)
  DRIVER=$(ssh "${SSH[@]}" "$(slurm_name "$W")" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d '\r ')
  MTU=$(ssh "${SSH[@]}" "$(slurm_name "$W")" -- ip -o link show rdma_p0_rail0 | grep -oE 'mtu [0-9]+' | awk '{print $2}')
  TRAYS=$(gpu_nodes | wc -l); CP_TAINTED=$(kubectl get node "$CP" -o jsonpath='{.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].effect}')
  if [[ $UNTAINT == 1 || -z "$CP_TAINTED" ]]; then QUOTA=$(( TRAYS * 4 )); else QUOTA=$(( (TRAYS - 1) * 4 )); fi
  {
    echo "# Deploy-time overlay for the validation cluster (NOT committed). Rack $RACK, $(date -u +%F): one NVLink clique of"
    echo "# $TRAYS trays, GPU Operator in device-plugin mode. Written by install-ktlo-stack.sh step 6; pins follow the rack."
    echo "gpu:"; echo "  allocation: device-plugin"
    echo "  # SITE RULE (#690, three racks lost 2026-09-24): never claim rail VFs into check pods here — the site's node"
    echo "  # health check requires every rdma_vf_rail* on the HOST; multi-node checks run host-network."
    echo "  rdma:"; echo "    nicCount: 0"
    echo "agent:"
    echo "  # k3s keeps the kubelet's device-plugin checkpoint here; the agent's GPU→pod map (ktlo-labs.ai/gpu-pods) reads it."
    echo "  hostPaths:"; echo "    kubeletDevicePlugins: /var/lib/kubelet/device-plugins"
    echo "  configOverlay:"; echo "    checks:"
    echo "      fabric_imex:"; echo "        expected_peers_by_domain:"; echo "          \"$CLIQUE\": $TRAYS"
    echo "      gpu_versions:"
    echo "        driver: {expected: \"$DRIVER\", severity: \"warn\"}"
    echo "        runtime: {expected: \"13.2\", severity: \"warn\"}"
    if [[ -n "$MTU" && "$MTU" != "9266" ]]; then
      echo "      # Site pin (owner 2026-09-26: pin whatever the rack runs — 9000 and 9050 seen — so rail_config measures"
      echo "      # drift from the rack's own value, not from the 9266 standard). Observed on tray $W at bring-up."
      echo "      rail_config:"; echo "        expected_mtu: $MTU"
    fi
    echo "active:"; echo "  queue:"
    echo "    # One rack: values-gb300.yaml carries the two-rack budget (132); Kueue must not admit more check pods than GPUs."
    echo "    nominalGpuQuota: $QUOTA"
  } > "$OVERLAY"
  log "   rack=$RACK trays=$TRAYS clique=$CLIQUE driver=$DRIVER rail_mtu=$MTU quota=$QUOTA -> $OVERLAY"
fi

# ------------------------------------------------------------------ 7. KTLO chart
if step 7 "KTLO chart ($KTLO_REF) + values-gb300 + overlay, then Prometheus pod restart"; then
  [[ -s "$OVERLAY" ]] || { echo "overlay $OVERLAY missing — run step 6" >&2; exit 1; }
  CH="$LOG_DIR/chart"; rm -rf "$CH"; mkdir -p "$CH"
  ( cd "$KTLO_REPO" && git fetch -q origin && git archive "$KTLO_REF" deploy/charts/ktlo | tar -x -C "$CH" && \
    git show "$KTLO_REF:deploy/values-gb300.yaml" > "$LOG_DIR/values-gb300.yaml" )
  REV=$(cd "$KTLO_REPO" && git rev-parse --short "$KTLO_REF")
  helm upgrade --install ktlo "$CH/deploy/charts/ktlo" -n ktlo -f "$LOG_DIR/values-gb300.yaml" -f "$KTLO_REPO/deploy/examples/self-hosted-observability/ktlo-values.yaml" -f "$OVERLAY" \
    --set release.revision="$REV" --set agent.gpuReset.enabled=true --wait --timeout 10m | tail -n 1
  kubectl -n ktlo rollout status ds/ktlo-agent --timeout=5m | tail -n 1
  log "   release $(kubectl -n ktlo get configmap ktlo-release -o jsonpath='{.data.release_revision}')"
  kubectl -n ktlo-prometheus delete pod -l app.kubernetes.io/name=prometheus --wait=false >/dev/null 2>&1 || true
  kubectl -n ktlo get pods --no-headers | awk '{print $3}' | sort | uniq -c | sed 's/^/   ktlo pods: /'
fi

# ------------------------------------------------------------------ 8. Grafana Cloud onboarding
if step 8 "Grafana Cloud onboarding (--grafana-cloud; default: skipped — local stack only, no egress)"; then
  if [[ $GRAFANA_CLOUD != 1 ]]; then log "   skipped (no --grafana-cloud): metrics and logs stay in the cluster; Terraform state still lists helm_release.k8s_monitoring from the last onboarding — state rm it before any future apply"; else
  ( cd "$KTLO_REPO/deploy/terraform/onboard" && \
    terraform state rm helm_release.k8s_monitoring 2>&1 | tail -n 1 | sed 's/^/   /' ; \
    terraform apply -auto-approve -input=false 2>&1 | grep -E '^Apply complete|Error' | head -n 3 | sed 's/^/   /' )
  wait_for 300 bash -c '[[ $(kubectl -n ktlo-monitor get pods --no-headers | grep -c "alloy.*Running") -ge 1 ]]'
  log "   alloy pods: $(kubectl -n ktlo-monitor get pods --no-headers | grep -c alloy)"
  fi
fi

# ------------------------------------------------------------------ 9. inference platform (optional)
if step 9 "inference platform $DYNAMO_VERSION (--dynamo)"; then
  if [[ $DYNAMO == 1 ]]; then
    ( cd "$KTLO_REPO/docs/examples/dynamo/platform" && \
      DYNAMO_VERSION="$DYNAMO_VERSION" NGC_API_KEY_FILE="$NGC_FILE" PROMETHEUS_URL="$PROM_URL" TENANT_NS="$TENANT_NS" \
      ./install.sh > "$LOG_DIR/dynamo-platform-install.log" 2>&1 ) || { tail -n 5 "$LOG_DIR/dynamo-platform-install.log"; exit 1; }
    kubectl -n dynamo-system get pods --no-headers | awk '{print $3}' | sort | uniq -c | sed 's/^/   dynamo-system: /'
    log "   ngc-pull in $TENANT_NS: $(kubectl -n "$TENANT_NS" get secret ngc-pull -o jsonpath='{.type}')"
  else log "   skipped (no --dynamo)"; fi
fi

# ------------------------------------------------------------------ 10. untaint the control-plane tray (optional)
if step 10 "untaint the control-plane tray so all trays serve GPUs (--untaint-control-plane)"; then
  if [[ $UNTAINT == 1 ]]; then
    CP=$(cp_node)
    # The server tray must be able to join multi-node NVLink work like any worker: the IMEX CDI
    # spec and containerd's cdi.k8s.io annotation allow-list (idempotent; the second restarts
    # the k3s server for a few seconds). Older bootstrap revisions wrote them on agents only.
    SSH=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o LogLevel=ERROR)
    ssh "${SSH[@]}" "$(slurm_name "$CP")" -- sudo bash -s < "$BOOT/node/install-imex-cdi.sh" 2>&1 | sed 's/^/   /' | tail -n 1
    ssh "${SSH[@]}" "$(slurm_name "$CP")" -- sudo K3S_DATA_DIR=/mnt/localdisk/k3s bash -s < "$BOOT/node/install-containerd-cdi-annotations.sh" 2>&1 | sed 's/^/   /' | tail -n 1
    wait_for 120 kubectl get nodes
    kubectl taint node "$CP" node-role.kubernetes.io/control-plane:NoSchedule- 2>&1 | sed 's/^/   /' || true
    wait_for 120 bash -c "[[ \$(kubectl get node $CP -o jsonpath='{.status.allocatable.nvidia\\.com/gpu}') == 4 ]]"
    log "   $CP allocatable nvidia.com/gpu=$(kubectl get node "$CP" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'); total $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END{print s}')"
  else log "   skipped (no --untaint-control-plane)"; fi
fi

[[ $LIST == 1 ]] || log "done. Next: scripts/live-validate.sh, then the census (pause the controller first)."
