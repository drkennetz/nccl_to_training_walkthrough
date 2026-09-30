#!/usr/bin/env bash
# lib/platform.sh -- install the in-cluster platform (CNI first, then the rest).
#
# Everything here is a Helm release created from a pinned chart version and a
# values file under platform/. Step 8 hands these releases to Argo CD; keeping the
# values in files rather than long --set lists is what makes that handover possible.

[[ -n "${_K8SBOOT_PLATFORM:-}" ]] && return 0
_K8SBOOT_PLATFORM=1

# shellcheck source=../providers/k3s.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../providers/k3s.sh"

# helm/kubectl against our cluster. KUBECONFIG is explicit so nothing depends on
# the caller's environment.
_h() { KUBECONFIG="$(state_path kubeconfig)" helm "$@"; }
_k() { KUBECONFIG="$(state_path kubeconfig)" kubectl "$@"; }

platform_require_tools() {
  command -v helm    >/dev/null 2>&1 || die "helm not found -- run bin/k8s-install-tools"
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found -- run bin/k8s-install-tools"
  state_has kubeconfig || die "no kubeconfig -- run bin/k8s-up first"
}

# helm_repo <name> <url> -- idempotent; refreshes if the URL changed.
helm_repo() {
  local name="$1" url="$2" cur
  cur="$(_h repo list -o json 2>/dev/null | jq -r --arg n "$name" '.[]?|select(.name==$n)|.url' 2>/dev/null || true)"
  if [[ "$cur" != "$url" ]]; then
    run env KUBECONFIG="$(state_path kubeconfig)" helm repo add "$name" "$url" --force-update >/dev/null \
      || die "helm repo add ${name} failed"
  fi
  run env KUBECONFIG="$(state_path kubeconfig)" helm repo update "$name" >/dev/null 2>&1 || :
}

# A helm install that was interrupted (killed terminal, lost session, timeout)
# leaves the release in pending-install / pending-upgrade, and every later
# `helm upgrade --install` then fails with "another operation in progress".
# Recover automatically rather than making the operator dig it out by hand.
helm_clear_pending() {                 # helm_clear_pending <release> <namespace>
  local rel="$1" ns="$2" status
  status="$(_h -n "$ns" list -a -o json 2>/dev/null \
             | jq -r --arg r "$rel" '.[]?|select(.name==$r)|.status' 2>/dev/null || true)"
  case "$status" in
    pending-install)
      warn "release ${rel} is stuck in pending-install (a previous run was interrupted); removing it"
      run env KUBECONFIG="$(state_path kubeconfig)" helm -n "$ns" uninstall "$rel" \
        --wait --timeout 5m >/dev/null 2>&1 || warn "  uninstall reported errors; continuing" ;;
    pending-upgrade|pending-rollback)
      warn "release ${rel} is stuck in ${status}; rolling back"
      run env KUBECONFIG="$(state_path kubeconfig)" helm -n "$ns" rollback "$rel" \
        --wait --timeout 5m >/dev/null 2>&1 || warn "  rollback reported errors; continuing" ;;
    *) dbg "release ${rel} status: ${status:-absent}" ;;
  esac
}

# ------------------------------------------------------------------ cilium
# Two values are runtime-only: with kube-proxy disabled the agents cannot reach
# the API via a Service IP, so they need the control plane's real address.
_cilium_args() {
  local cp ip; cp="$(state_read controlplane)"
  [[ -n "$cp" ]] || die "no control-plane node recorded"
  ip="$(node_ip "$cp")"
  printf '%s\n' \
    --namespace kube-system \
    --version "${CILIUM_CHART_VERSION}" \
    --values "${REPO_ROOT}/platform/cilium/values.yaml" \
    --set "k8sServiceHost=${ip}" \
    --set "k8sServicePort=6443"
}

platform_cilium_template() {
  platform_require_tools
  helm_repo cilium "${CILIUM_HELM_REPO}"
  local -a args=(); mapfile -t args < <(_cilium_args)
  _h template cilium cilium/cilium "${args[@]}"
}

platform_install_cilium() {
  platform_require_tools
  log "installing Cilium ${CILIUM_VERSION} (chart ${CILIUM_CHART_VERSION})"
  helm_repo cilium "${CILIUM_HELM_REPO}"
  helm_clear_pending cilium kube-system

  local -a args=(); mapfile -t args < <(_cilium_args)
  (( ${#args[@]} )) || die "could not build Cilium helm arguments"

  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "dry-run: helm upgrade --install cilium cilium/cilium ${args[*]}" >&2
    return 0
  fi

  _h upgrade --install cilium cilium/cilium "${args[@]}" --wait --timeout 10m \
    || { err "Cilium install failed"; _k -n kube-system get pods -l k8s-app=cilium; return 1; }

  log "waiting for nodes to become Ready"
  local waited=0 total ready
  total="$(_k get nodes --no-headers 2>/dev/null | grep -c . || echo 0)"
  while (( waited < 300 )); do
    ready="$(_k get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)"
    (( ready == total && total > 0 )) && { ok "all ${total} node(s) Ready after ${waited}s"; break; }
    sleep 5; waited=$((waited+5))
  done
  if (( waited >= 300 )); then
    err "nodes did not all become Ready within 300s"
    _k get nodes -o wide; return 1
  fi
  ok "Cilium up"
}

# Health check that does not need the cilium CLI installed.
platform_cilium_status() {
  platform_require_tools
  local pod
  pod="$(_k -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$pod" ]] || { err "no cilium agent pods found"; return 1; }
  _k -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --brief 2>/dev/null \
    || _k -n kube-system exec "$pod" -- cilium status --brief 2>/dev/null \
    || { err "could not query cilium status"; return 1; }
}

# ------------------------------------------------------------------ gpu operator
# Two mutually exclusive stacks; the chart rejects having both CRs present:
#   device plugin (default) -> pods request nvidia.com/gpu
#   DRA (opt-in)            -> pods reference a ResourceClaim on gpu.nvidia.com
_gpu_operator_args() {
  local mode="${1:-deviceplugin}"
  printf '%s\n' \
    --namespace gpu-operator --create-namespace \
    --version "${GPU_OPERATOR_CHART_VERSION}" \
    --values "${REPO_ROOT}/platform/gpu-operator/values.yaml"
  [[ "$mode" == dra ]] && printf '%s\n' --values "${REPO_ROOT}/platform/gpu-operator/values-dra.yaml"
}

platform_gpu_operator_template() {
  local mode="${1:-deviceplugin}"
  command -v helm >/dev/null 2>&1 || die "helm not found -- run bin/k8s-install-tools"
  helm repo add nvidia "${GPU_OPERATOR_HELM_REPO}" --force-update >/dev/null 2>&1 || :
  local -a args=(); mapfile -t args < <(_gpu_operator_args "$mode")
  # The chart refuses to render the DRA stack unless it can see the DeviceClass
  # API. Offline (`helm template` with no cluster) we assert it, which is exactly
  # what the chart's own error message suggests. Against a live cluster the real
  # discovery applies and this flag is harmless.
  [[ "$mode" == dra ]] && args+=(--api-versions resource.k8s.io/v1/DeviceClass)
  helm template gpu-operator nvidia/gpu-operator "${args[@]}"
}

# The host generates /var/run/cdi/nvidia.yaml and its hash is part of the
# do-no-harm baseline. Capture it before, compare after: if the operator's CDI
# handling ever starts rewriting the host's spec, this is what catches it.
_host_cdi_hashes() {
  local n
  for n in $(nodes_expand "$(slurm_all_leased_nodes | paste -sd,)"); do
    printf '%s %s\n' "$n" \
      "$(node_ssh_ro "$n" "sudo sha256sum ${HOST_CDI_SPEC} 2>/dev/null | cut -d' ' -f1" 2>/dev/null)"
  done
}

# platform_install_gpu_operator [deviceplugin|dra]
platform_install_gpu_operator() {
  local mode="${1:-deviceplugin}"
  platform_require_tools
  log "installing GPU Operator ${GPU_OPERATOR_CHART_VERSION} (mode: ${mode})"
  helm_repo nvidia "${GPU_OPERATOR_HELM_REPO}"
  helm_clear_pending gpu-operator gpu-operator

  # Switching between the ClusterPolicy and GPUCluster stacks needs care. The two
  # CRs are mutually exclusive -- each controller refuses to work while the other
  # CR exists -- and `helm upgrade` does NOT prune the one that left the manifest.
  # Observed on a live cluster after switching dra -> deviceplugin: BOTH
  # cluster-policy and gpu-cluster existed, each reporting notReady, and the
  # node's nvidia.com/gpu collapsed to 0. The stale GPUCluster still had its
  # finalizer and no deletionTimestamp, i.e. helm never even tried.
  #
  # So delete the outgoing CR ourselves, before the upgrade, and let the operator
  # clear its finalizer.
  local prev_mode="" restart_needed=0
  if   _k get clusterpolicy cluster-policy >/dev/null 2>&1; then prev_mode=deviceplugin
  elif _k get gpucluster    gpu-cluster    >/dev/null 2>&1; then prev_mode=dra; fi

  if [[ -n "$prev_mode" && "$prev_mode" != "$mode" ]]; then
    warn "switching GPU stack: ${prev_mode} -> ${mode}"
    restart_needed=1
    local old_kind old_name
    if [[ "$prev_mode" == deviceplugin ]]; then old_kind=clusterpolicy; old_name=cluster-policy
    else old_kind=gpucluster; old_name=gpu-cluster; fi
    log "removing the outgoing ${old_kind}/${old_name} (helm will not prune it)"
    run env KUBECONFIG="$(state_path kubeconfig)" kubectl delete "$old_kind" "$old_name" \
      --timeout=120s >/dev/null 2>&1 || warn "  delete of ${old_kind}/${old_name} reported errors"
    local gone=0 i
    for i in $(seq 1 30); do
      _k get "$old_kind" "$old_name" >/dev/null 2>&1 || { gone=1; break; }
      sleep 4
    done
    (( gone )) && ok "  ${old_kind}/${old_name} removed" \
      || warn "  ${old_kind}/${old_name} still present (stuck finalizer?); the new stack may stay notReady"
  fi

  local before after
  before="$(_host_cdi_hashes)"
  dbg "host CDI hashes before: ${before}"

  local -a args=(); mapfile -t args < <(_gpu_operator_args "$mode")
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "dry-run: helm upgrade --install gpu-operator nvidia/gpu-operator ${args[*]}" >&2
    return 0
  fi

  # No --wait: several DaemonSets only become ready after the validator has run,
  # and the operator reconciles in stages. We poll for the thing we actually
  # care about instead.
  _h upgrade --install gpu-operator nvidia/gpu-operator "${args[@]}" --timeout 15m \
    || { err "GPU Operator install failed"; _k -n gpu-operator get pods; return 1; }

  if (( restart_needed )); then
    log "restarting the operator so it re-reads which CR exists"
    run env KUBECONFIG="$(state_path kubeconfig)" kubectl -n gpu-operator \
      rollout restart deploy/gpu-operator >/dev/null 2>&1 || :
    run env KUBECONFIG="$(state_path kubeconfig)" kubectl -n gpu-operator \
      rollout status deploy/gpu-operator --timeout=180s >/dev/null 2>&1 || :
  fi

  if [[ "$mode" == dra ]]; then
    platform_wait_dra || return 1
  else
    platform_wait_gpu_resource || return 1
  fi

  after="$(_host_cdi_hashes)"
  if [[ "$before" != "$after" ]]; then
    err "host CDI spec ${HOST_CDI_SPEC} CHANGED -- this violates CLAUDE.md rule 5"
    printf 'before:\n%s\nafter:\n%s\n' "$before" "$after" >&2
    return 1
  fi
  ok "host CDI spec unchanged on every tray"
}

# Wait until every GPU worker advertises nvidia.com/gpu.
platform_wait_gpu_resource() {
  local want="${GPUS_PER_NODE:-4}" waited=0 workers ready
  workers="$(_k get nodes -l k8s-bootstrap.io/role=worker --no-headers 2>/dev/null | grep -c . || echo 0)"
  (( workers > 0 )) || { warn "no worker nodes labelled; skipping GPU resource wait"; return 0; }
  log "waiting for ${workers} worker(s) to have nvidia.com/gpu allocatable=${want}"
  while (( waited < 600 )); do
    # ALLOCATABLE, not capacity. Capacity lingers at 4 after the device plugin is
    # removed, so checking it reported success instantly on a cluster whose GPUs
    # were in fact unschedulable.
    ready="$(_k get nodes -l k8s-bootstrap.io/role=worker \
              -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
              | grep -c "^${want}$" || true)"
    (( ready == workers )) && { ok "all ${workers} worker(s) allocatable ${want} GPUs (after ${waited}s)"; return 0; }
    sleep 10; waited=$((waited+10))
  done
  err "GPUs not allocatable within 600s"
  _k get nodes -o custom-columns='NODE:.metadata.name,CAP:.status.capacity.nvidia\.com/gpu,ALLOC:.status.allocatable.nvidia\.com/gpu'
  _k -n gpu-operator get pods
  return 1
}

# Wait until the DRA driver publishes ResourceSlices for its DeviceClasses.
platform_wait_dra() {
  local waited=0 slices
  log "waiting for the NVIDIA DRA driver to publish ResourceSlices"
  while (( waited < 600 )); do
    slices="$(_k get resourceslices --no-headers 2>/dev/null | grep -c 'gpu.nvidia.com' || true)"
    (( slices > 0 )) && { ok "${slices} ResourceSlice(s) published (after ${waited}s)"; return 0; }
    sleep 10; waited=$((waited+10))
  done
  err "no ResourceSlices published within 600s"
  _k get deviceclasses 2>/dev/null || warn "no DeviceClass API -- is DRA enabled on this cluster?"
  _k -n gpu-operator get pods
  return 1
}

# Report whether this cluster can do DRA at all, independent of NVIDIA.
platform_dra_capability() {
  platform_require_tools
  printf '  resource.k8s.io served : %s\n' \
    "$(_k api-versions 2>/dev/null | grep '^resource.k8s.io/' | paste -sd, || echo NONE)"
  printf '  DRA API resources      : %s\n' \
    "$(_k api-resources --api-group=resource.k8s.io --no-headers 2>/dev/null | awk '{print $1}' | paste -sd,)"
  printf '  DeviceClasses          : %s\n' \
    "$(_k get deviceclasses --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, || echo none)"
  local slices; slices="$(_k get resourceslices --no-headers 2>/dev/null | wc -l)"
  printf '  ResourceSlices         : %s\n' "${slices:-0}"
}

# ------------------------------------------------------------------ storage
# Two StorageClasses with different jobs:
#   local-path (default)  RWO, node-local, on the 28T NVMe -- scratch, checkpoints
#   nfs                   RWX, shared     -- datasets and weights for multi-node
platform_install_storage() {
  platform_require_tools

  # ---- local-path: plain manifests via kustomize, so GitOps can own it and it
  # transfers to a kubeadm cluster. k3s's bundled local-storage is disabled.
  log "installing local-path-provisioner ${LOCAL_PATH_PROVISIONER_VERSION}"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "dry-run: kubectl apply -k ${REPO_ROOT}/platform/storage/local-path" >&2
  else
    run env KUBECONFIG="$(state_path kubeconfig)" kubectl apply -k \
      "${REPO_ROOT}/platform/storage/local-path" >/dev/null \
      || die "local-path-provisioner apply failed"
    run env KUBECONFIG="$(state_path kubeconfig)" kubectl -n local-path-storage \
      rollout status deploy/local-path-provisioner --timeout=180s >/dev/null \
      || { err "local-path-provisioner did not become ready"; _k -n local-path-storage get pods; return 1; }
    ok "local-path ready (default StorageClass, rooted at ${NODE_LOCAL_DISK}/local-path)"
  fi

  # ---- csi-driver-nfs for RWX. server/share are per-cluster facts, so they are
  # --set here rather than baked into the values file.
  [[ -n "${NFS_SERVER:-}" && -n "${NFS_SHARE:-}" ]] \
    || { warn "NFS_SERVER/NFS_SHARE not set in the cluster config; skipping RWX storage"; return 0; }

  log "installing csi-driver-nfs ${CSI_DRIVER_NFS_CHART_VERSION} (${NFS_SERVER}:${NFS_SHARE})"
  helm_repo csi-driver-nfs "${CSI_DRIVER_NFS_HELM_REPO}"
  helm_clear_pending csi-driver-nfs kube-system

  # Every volume lands under NFS_SUBDIR_PREFIX so teardown can remove exactly our
  # directories. /fss holds other people's data; never provision at the share root.
  local subdir="${NFS_SUBDIR_PREFIX:-k8s-bootstrap}/${CLUSTER_NAME}/\${pvc.metadata.namespace}-\${pvc.metadata.name}"
  local -a args=(
    --namespace kube-system
    --version "${CSI_DRIVER_NFS_CHART_VERSION}"
    --values "${REPO_ROOT}/platform/storage/csi-driver-nfs-values.yaml"
    --set "storageClass.name=nfs"
    --set "storageClass.parameters.server=${NFS_SERVER}"
    --set "storageClass.parameters.share=${NFS_SHARE}"
    --set "storageClass.parameters.subDir=${subdir}"
    --set "storageClass.reclaimPolicy=Delete"
    --set "storageClass.volumeBindingMode=Immediate"
  )
  # mountOptions is a list; index it explicitly.
  local i=0 opt
  IFS=',' read -ra _opts <<< "${NFS_MOUNT_OPTIONS:-nfsvers=3}"
  for opt in "${_opts[@]}"; do
    args+=(--set "storageClass.mountOptions[${i}]=${opt}"); i=$((i+1))
  done

  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "dry-run: helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs ${args[*]}" >&2
    return 0
  fi
  _h upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs "${args[@]}" \
      --wait --timeout 10m \
    || { err "csi-driver-nfs install failed"; _k -n kube-system get pods -l app.kubernetes.io/name=csi-driver-nfs; return 1; }
  ok "nfs StorageClass ready (RWX under ${NFS_SHARE}/${NFS_SUBDIR_PREFIX}/${CLUSTER_NAME})"
}

# Build the additionalScrapeConfigs Secret content for the host exporters.
# ------------------------------------------------------------------ monitoring
# Scrapes the HOST exporters rather than deploying its own. See CLAUDE.md: the
# chart's node-exporter would collide with the host's on hostPort 9100, and the
# host set also gives us the provider's nvlink/pcie/rdma/nccl metrics for free.
_render_host_scrape_configs() {
  # Mapping verified against /metrics output on a live node. Getting this from
  # the filenames in /usr/local/bin produced a rotated, wrong mapping once.
  #
  # Node service discovery, not static targets: `instance` must carry the KUBERNETES NODE
  # NAME, because KTLO's canonical recording rules (ktlo_gpu_temp_celsius & co.) join the
  # host exporters' series to ktlo_gpu_node on `node`, derived from `instance`. A static
  # "<ip>:9400" instance joins nothing -- seen on nearby-woodcock: 264 DCGM series scraped,
  # 0 ktlo_gpu_temp_celsius. Same bridge as KTLO's deploy/examples/in-cluster-prometheus.
  local names="9100:node-exporter 9400:dcgm-exporter 9500:rdma-counters 9600:nvlink-counters 9700:pcie-faults"
  local port job
  for port in ${HOST_SCRAPE_PORTS:-9100 9400 9500 9600 9700}; do
    job="host-$(awk -v p="$port" 'BEGIN{n=split("'"$names"'",a," "); for(i=1;i<=n;i++){split(a[i],b,":"); if(b[1]==p) print b[2]}}')"
    [[ "$job" == "host-" ]] && job="host-port-${port}"
    cat <<YAML
- job_name: ${job}
  # Host-provided exporter, NOT deployed by us. Scraped directly because the
  # in-cluster equivalent would collide on the hostPort.
  scrape_interval: 30s
  kubernetes_sd_configs:
    - role: node
  relabel_configs:
    - source_labels: [__meta_kubernetes_node_address_InternalIP]
      regex: "(.+)"
      target_label: __address__
      replacement: "\${1}:${port}"
    - source_labels: [__meta_kubernetes_node_name]
      target_label: instance
YAML
  done
}

platform_install_monitoring() {
  platform_require_tools
  log "installing kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
  helm_repo prometheus-community "${PROMETHEUS_HELM_REPO}"
  helm_clear_pending kube-prometheus-stack monitoring

  local -a args=(
    --namespace monitoring --create-namespace
    --version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
    --values "${REPO_ROOT}/platform/kube-prometheus-stack/values.yaml"
  )

  # The prometheus-operator CRDs may already belong to another Helm release -- KTLO's
  # onboarding installs the standalone prometheus-operator-crds chart on its Grafana Cloud
  # path. Helm then refuses to adopt them ("conflict occurred while applying object
  # .../alertmanagerconfigs.monitoring.coreos.com", seen on nearby-woodcock). Leave them to
  # their owner. The CRDs are additive across operator versions, so ours runs on theirs.
  local crd_owner
  crd_owner="$(_k get crd prometheuses.monitoring.coreos.com \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
  if [[ -n "$crd_owner" && "$crd_owner" != kube-prometheus-stack ]]; then
    warn "prometheus-operator CRDs are owned by Helm release '${crd_owner}'; installing with --skip-crds"
    args+=(--skip-crds)
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "dry-run: helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack ${args[*]}" >&2
    printf '%s\n' "dry-run: additional scrape configs would be:" >&2
    _render_host_scrape_configs 2>/dev/null | sed 's/^/  /' >&2
    return 0
  fi

  # The host targets are only knowable at install time, so they go in via a
  # Secret the chart references, not the values file.
  local tmp; tmp="$(mktemp)"; _render_host_scrape_configs > "$tmp"
  run env KUBECONFIG="$(state_path kubeconfig)" kubectl create namespace monitoring \
    --dry-run=client -o yaml 2>/dev/null | _k apply -f - >/dev/null 2>&1 || :
  run env KUBECONFIG="$(state_path kubeconfig)" kubectl -n monitoring \
    create secret generic host-scrape-configs \
    --from-file=host-scrape.yaml="$tmp" --dry-run=client -o yaml \
    | _k apply -f - >/dev/null || warn "could not create host-scrape-configs secret"
  dbg "host scrape config: $(wc -l < "$tmp") lines"
  rm -f "$tmp"

  # additionalScrapeConfigsSecret (NOT additionalScrapeConfigs) is the key for
  # referencing an existing Secret; the chart says the two cannot be combined.
  # Setting additionalScrapeConfigs.{name,key} instead makes the chart render its
  # own Secret containing a MAP, and the operator then refuses the whole config
  # with "cannot unmarshal !!map into []yaml.MapSlice" -- leaving no StatefulSet
  # and a Prometheus CR stuck at Reconciled=False.
  args+=(--set "prometheus.prometheusSpec.additionalScrapeConfigsSecret.enabled=true"
          --set "prometheus.prometheusSpec.additionalScrapeConfigsSecret.name=host-scrape-configs"
          --set "prometheus.prometheusSpec.additionalScrapeConfigsSecret.key=host-scrape.yaml")

  _h upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      "${args[@]}" --timeout 15m \
    || { err "kube-prometheus-stack install failed"; _k -n monitoring get pods; return 1; }

  # The operator creates the StatefulSet only after it successfully renders the
  # Prometheus config, so wait for the object to appear before asking about its
  # rollout -- and if it never does, print the CR's Reconciled condition, which
  # is the thing that actually explains why (a bad scrape config, for instance).
  log "waiting for the Prometheus StatefulSet to be created"
  local sts=prometheus-kube-prometheus-stack-prometheus waited=0
  while (( waited < 300 )); do
    _k -n monitoring get "statefulset/${sts}" >/dev/null 2>&1 && break
    sleep 10; waited=$((waited+10))
  done
  if ! _k -n monitoring get "statefulset/${sts}" >/dev/null 2>&1; then
    err "Prometheus StatefulSet was never created after ${waited}s"
    _k -n monitoring get prometheus -o json 2>/dev/null \
      | jq -r '.items[]?.status.conditions[]? | "    \(.type)=\(.status) reason=\(.reason)\n      \(.message)"' >&2 || :
    _k -n monitoring get pods >&2
    return 1
  fi
  log "waiting for Prometheus to become ready"
  run env KUBECONFIG="$(state_path kubeconfig)" kubectl -n monitoring rollout status \
    "statefulset/${sts}" --timeout=600s >/dev/null \
    || { err "Prometheus did not become ready"
         _k -n monitoring get prometheus -o json 2>/dev/null \
           | jq -r '.items[]?.status.conditions[]? | "    \(.type)=\(.status) reason=\(.reason)"' >&2 || :
         _k -n monitoring get pods >&2; return 1; }
  ok "monitoring up (Grafana + Prometheus; host exporters scraped, none deployed)"
}

# ------------------------------------------------------------------ nfs cleanup
# PVCs with reclaimPolicy=Delete have their subdirectory removed by the CSI driver
# when the PVC goes away. But a hard teardown uninstalls k3s without deleting
# PVCs first, so the directories survive -- on storage shared with other people.
# /fss holds other users' data (e.g. /fss/dgxc); leaving our tree there is exactly
# the kind of residue this repo exists to avoid.
#
# Runs from the CONTROLLER, once, not per node: it is one shared filesystem.
platform_cleanup_nfs() {
  local base="${SHARED_FS:-}" prefix="${NFS_SUBDIR_PREFIX:-}" cluster="${CLUSTER_NAME:-}"

  # Refuse unless every component is present and the result is unmistakably ours.
  # Getting this wrong deletes somebody's dataset, so the checks are explicit.
  [[ -n "$base" && -n "$prefix" && -n "$cluster" ]] || {
    dbg "NFS cleanup skipped: SHARED_FS/NFS_SUBDIR_PREFIX/CLUSTER_NAME not all set"; return 0; }
  local target="${base}/${prefix}/${cluster}"
  case "$target" in
    *..*)            err "refusing to clean a path containing '..': ${target}"; return 1 ;;
    "${base}"|"${base}/") err "refusing to clean the share root: ${target}"; return 1 ;;
  esac
  # Must be at least <base>/<prefix>/<cluster> -- three components below /.
  [[ "$target" == "${base}/"*"/"* ]] || {
    err "refusing to clean a shallow path: ${target}"; return 1; }
  mountpoint -q "$base" 2>/dev/null || { warn "${base} is not mounted; skipping NFS cleanup"; return 0; }

  [[ -e "$target" ]] || { dbg "no NFS residue at ${target}"; return 0; }

  local n; n="$(find "$target" -mindepth 1 -maxdepth 1 2>/dev/null | grep -c . || true)"
  log "removing our NFS volumes: ${target} (${n} entry/entries)"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "dry-run: sudo rm -rf ${target}" >&2
    return 0
  fi
  # The CSI driver creates these as root, so removal needs sudo even though the
  # share root is user-owned.
  run sudo rm -rf "$target" || { err "could not remove ${target}"; return 1; }
  # Tidy the prefix directory too, but ONLY if it is now empty -- another cluster
  # may still be using it.
  if [[ -d "${base}/${prefix}" ]] && \
     [[ -z "$(find "${base}/${prefix}" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]]; then
    run sudo rmdir "${base}/${prefix}" 2>/dev/null || :
  fi
  ok "shared storage cleaned"
}

# Report, without changing anything.
platform_nfs_residue() {
  local target="${SHARED_FS:-}/${NFS_SUBDIR_PREFIX:-}/${CLUSTER_NAME:-}"
  [[ -e "$target" ]] || { printf 'none\n'; return 0; }
  find "$target" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l
}
