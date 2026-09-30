#!/usr/bin/env bash
# providers/k3s.sh -- the k3s provider (default). Controller-side orchestration.
#
# Provider contract, so kubeadm.sh can be swapped in:
#   provider_install_server <node>
#   provider_install_agents <nodelist>
#   provider_teardown_nodes <nodelist> [--keep-data]
#   provider_fetch_kubeconfig <node>
#   provider_server_url

[[ -n "${_K8SBOOT_PROVIDER:-}" ]] && return 0
_K8SBOOT_PROVIDER=1
K8SBOOT_PROVIDER_NAME="k3s"

# shellcheck source=../lib/preflight.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/preflight.sh"

# Ask the machine for its own address rather than trusting Slurm's NodeAddr.
# NodeAddr can be stale on dynamic nodes, and two node records can share one
# address -- so it is used only as a cross-check, never as the source of truth.
node_ip() {
  local node="$1" ip slurm_ip
  # `|| true` matters: lib/common.sh sets -e, so without it a failing ssh aborts
  # this function outright and the NodeAddr fallback below never runs -- which is
  # the entire point of having it.
  ip="$(node_ssh_ro "$node" "ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p'" 2>/dev/null | tr -d '\r' || true)"
  slurm_ip="$(scontrol show node "$node" 2>/dev/null | sed -n 's/.*NodeAddr=\([^ ]*\).*/\1/p' | head -1)"
  if [[ -z "$ip" ]]; then
    [[ -n "$slurm_ip" ]] || die "cannot determine an address for ${node}"
    warn "${node}: could not ask the node for its IP; falling back to Slurm NodeAddr ${slurm_ip}"
    ip="$slurm_ip"
  elif [[ -n "$slurm_ip" && "$ip" != "$slurm_ip" ]]; then
    warn "${node}: node reports ${ip} but Slurm says ${slurm_ip} (stale mapping); using ${ip}"
  fi
  printf '%s' "$ip"
}

_node_install_env() {
  printf '%s' \
    "NODE_INSTALL_DIR='${NODE_INSTALL_DIR}' " \
    "K3S_DATA_DIR='${K3S_DATA_DIR}' " \
    "NODE_LOCAL_DISK='${NODE_LOCAL_DISK}' " \
    "K3S_VERSION='${K3S_VERSION}' " \
    "K3S_INSTALL_URL='${K3S_INSTALL_URL}' " \
    "HOST_CDI_SPEC='${HOST_CDI_SPEC}' " \
    "RDMA_NETNS_MODE='${RDMA_NETNS_MODE:-}' "
}

provider_server_url() {
  local cp; cp="$(state_read controlplane)"
  [[ -n "$cp" ]] || die "no control-plane node recorded"
  printf 'https://%s:6443' "$(node_ip "$cp")"
}

provider_install_server() {
  local node="$1"
  assert_node_identity "$node" || die "refusing to install on ${node}"
  local ip; ip="$(node_ip "$node")"
  log "installing k3s ${K3S_VERSION} server on ${node} (${ip})"

  node_ssh "$node" "$(_node_install_env) \
      POD_CIDR='${POD_CIDR}' SERVICE_CIDR='${SERVICE_CIDR}' CLUSTER_DNS='${CLUSTER_DNS}' \
      NODE_IP='${ip}' CLUSTER_NAME='${CLUSTER_NAME}' $(slurm_node_label_env "$node") \
      bash ${REPO_ROOT}/node/install-server.sh" \
    || die "server install failed on ${node}"

  [[ "$DRY_RUN" == 1 ]] && return 0
  state_write controlplane <<<"$node"

  # Join token and kubeconfig, pulled over ssh rather than written to shared NFS
  # by root, so they land here owned by us and mode 0600.
  node_ssh_ro "$node" "sudo cat ${K3S_DATA_DIR}/server/node-token" \
    | state_write node-token 0600
  state_has node-token || die "could not read join token from ${node}"

  node_ssh_ro "$node" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s|https://127.0.0.1:6443|https://${ip}:6443|" \
    | state_write kubeconfig 0600

  # The server tray carries GPUs too: give its pods the same IMEX channel access the agents
  # get (CDI spec + containerd annotation allow-list), so an operator who untaints it later
  # gets a tray that can join multi-node NVLink work. Found live 2026-09-23: a training rank on
  # the untainted server tray failed its IMEX pre-check and took the whole Job down.
  provider_enable_imex_access "$node"
  state_has kubeconfig || die "could not read kubeconfig from ${node}"

  ok "server up; kubeconfig at $(state_path kubeconfig)"
}

provider_install_agents() {
  local nodelist="$1"
  local -a nodes=(); mapfile -t nodes < <(nodes_expand "$nodelist")
  ((${#nodes[@]})) || { warn "no agents to install"; return 0; }

  assert_nodes_identity "$nodelist" || die "refusing to install on mismatched host(s)"

  local url token
  if [[ "$DRY_RUN" == 1 ]]; then
    url="https://<control-plane>:6443"; token="<token>"
  else
    url="$(provider_server_url)"; token="$(state_read node-token)"
    [[ -n "$token" ]] || die "no join token; install the server first"
  fi

  log "joining ${#nodes[@]} agent(s) to ${url}"
  local n rc=0
  for n in "${nodes[@]}"; do
    { node_ssh "$n" "$(_node_install_env) \
          K3S_URL='${url}' K3S_TOKEN='${token}' NODE_IP='$(node_ip "$n")' $(slurm_node_label_env "$n") \
          bash ${REPO_ROOT}/node/install-agent.sh" \
        >/dev/null 2>&1 && printf 'ok' > "${STATE_DIR}/.join.${n}" \
        || printf 'fail' > "${STATE_DIR}/.join.${n}"; } &
  done
  wait
  [[ "$DRY_RUN" == 1 ]] && return 0
  for n in "${nodes[@]}"; do
    if [[ "$(cat "${STATE_DIR}/.join.${n}" 2>/dev/null)" == ok ]]; then ok "  ${n} joined"
    else err "  ${n} FAILED to join"; rc=1; fi
    rm -f "${STATE_DIR}/.join.${n}"
  done
  (( rc == 0 )) && provider_enable_imex_access "$nodelist"
  return $rc
}

provider_teardown_nodes() {
  local nodelist="$1"; shift || true
  local -a extra=("$@")
  local -a nodes=(); mapfile -t nodes < <(nodes_expand "$nodelist")
  ((${#nodes[@]})) || return 0

  # Identity matters even more here: tearing down the wrong machine would
  # uninstall someone else's cluster. But one unreachable node must not block
  # cleaning the others -- filter, do not fail closed.
  local -a targets=() skipped=()
  local n
  for n in "${nodes[@]}"; do
    if assert_node_identity "$n" >/dev/null 2>&1; then targets+=("$n"); else skipped+=("$n"); fi
  done
  if (( ${#skipped[@]} )); then
    warn "skipping ${#skipped[@]} tray(s) that are unreachable or identity-mismatched: ${skipped[*]}"
    warn "  if a tray is merely down, re-run teardown when it returns; if the identity is"
    warn "  wrong, that machine is not ours and must be left alone"
  fi
  if (( ${#targets[@]} == 0 )); then
    err "no tray could be verified; nothing torn down"
    return 1
  fi
  nodes=("${targets[@]}")

  log "tearing down k3s on ${#nodes[@]} tray(s): $(nodes_compress "${nodes[@]}")"
  # Keep each node's teardown output. Without it, a node that reports residue and
  # then goes unreachable leaves nothing to post-mortem -- which happened once and
  # made it impossible to tell provider flakiness from our own damage.
  local logdir="${STATE_DIR}/teardown-logs"
  mkdir -p "$logdir"

  local n rc=0
  for n in "${nodes[@]}"; do
    { if node_ssh "$n" "sudo $(_node_install_env) \
            bash ${REPO_ROOT}/node/teardown.sh --role auto \
              --baseline '${STATE_DIR}/snapshots/pre/${n}' ${extra[*]:-}" \
            >"${logdir}/${n}.log" 2>&1
      then printf 'ok' > "${STATE_DIR}/.td.${n}"
      else printf 'fail' > "${STATE_DIR}/.td.${n}"; fi; } &
  done
  wait
  [[ "$DRY_RUN" == 1 ]] && return 0
  for n in "${nodes[@]}"; do
    if [[ "$(cat "${STATE_DIR}/.td.${n}" 2>/dev/null)" == ok ]]; then ok "  ${n} clean"
    else
      err "  ${n} teardown reported residue -- see ${logdir}/${n}.log"
      grep -E "WARN|residual|FINISHED" "${logdir}/${n}.log" 2>/dev/null \
        | tail -6 | sed 's/^/        /' >&2
      rc=1
    fi
    rm -f "${STATE_DIR}/.td.${n}"
  done
  return $rc
}

provider_fetch_kubeconfig() {
  local node="${1:-$(state_read controlplane)}"
  local ip; ip="$(node_ip "$node")"
  node_ssh_ro "$node" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s|https://127.0.0.1:6443|https://${ip}:6443|" | state_write kubeconfig 0600
}

# kubectl against our cluster, wherever it is run from.
kc() { KUBECONFIG="$(state_path kubeconfig)" kubectl "$@"; }

# Remote kubectl via the server's bundled binary -- works before kubectl is
# installed on the controller.
#
# LIMITATION, verified live: arguments are flattened with $* and re-parsed by the
# remote shell, so anything containing shell metacharacters is destroyed.
#   -o jsonpath='{...[?(@.type=="Ready")]...}'  -> remote bash: "syntax error
#                                                  near unexpected token `('"
#   custom-columns=...k8s-bootstrap\.io/rack    -> the \. is eaten, so the column
#                                                  silently reads <none> for EVERY
#                                                  node rather than failing loudly
# Use rkc only for simple, metacharacter-free arguments. For anything else use
# kbin, which runs the real local kubectl.
rkc() {
  local cp; cp="$(state_read controlplane)"
  node_ssh_ro "$cp" "sudo ${NODE_INSTALL_DIR}/bin/k3s kubectl $*"
}

# kbin <timeout-seconds> <kubectl args...> -- kubectl as a real BINARY, so it can
# be bounded by timeout(1).
#
# `timeout 90 kc drain ...` reads correctly and never worked: timeout(1) execs
# its argument, so it cannot run a shell function and exits 127 immediately.
# bin/k8s-down did exactly that, with stderr discarded and `|| warn "drain timed
# out"` -- so every partial teardown silently skipped draining and then reported
# a timeout for something that had not run. Verified: `timeout 5 kc x` gives
# "timeout: failed to run command 'kc': No such file or directory".
#
# Falls back to the server's bundled binary over ssh when the controller has no
# kubectl, bounded the same way.
kbin() {
  local t="$1"; shift
  if state_has kubeconfig && command -v kubectl >/dev/null 2>&1; then
    KUBECONFIG="$(state_path kubeconfig)" timeout "$t" kubectl "$@"
  else
    local cp; cp="$(state_read controlplane)"
    [[ -n "$cp" ]] || return 1
    timeout "$t" ssh "${SSH_OPTS[@]}" "$cp" --       "sudo ${NODE_INSTALL_DIR}/bin/k3s kubectl $*"
  fi
}

# ------------------------------------------------------------------ imex access
# Multi-node NVLink needs pods to be able to OPEN
# /dev/nvidia-caps-imex-channels/channelN. Two things are required and neither is
# the default:
#
#  1. a CDI spec describing the channel, so the nvidia runtime can inject it
#     together with the cgroup permission -- a hostPath mount makes the node
#     visible but cgroup v2 still denies open(), and NCCL then reports
#     "MNNVL (cliqueSize N) is available but not working on this system";
#  2. containerd forwarding cdi.k8s.io/* annotations to the runtime, which it
#     does not do unless they are allowlisted.
#
# Both are per-node and applied right after the agents join. This configures
# K3S's containerd only -- never the host's, which Slurm users share (rule 3).
provider_enable_imex_access() {
  local nodelist="$1"
  local -a nodes=(); mapfile -t nodes < <(nodes_expand "$nodelist")
  ((${#nodes[@]})) || return 0

  # HGX shapes (IMEX_PATH=none) have no IMEX domain: there is no channel to expose, and
  # the annotation drop-in would restart every k3s-agent serially for nothing.
  if [[ "${IMEX_PATH:-A}" == none ]]; then
    log "IMEX_PATH=none: skipping IMEX channel access (NVLink ends at the node on this shape)"
    return 0
  fi

  log "enabling IMEX channel access for pods on ${#nodes[@]} tray(s)"
  local n rc=0
  for n in "${nodes[@]}"; do
    if node_ssh "$n" "sudo K3S_DATA_DIR='${K3S_DATA_DIR}' \
          bash ${REPO_ROOT}/node/install-imex-cdi.sh" >/dev/null 2>&1; then
      dbg "  ${n}: CDI spec written"
    else
      warn "  ${n}: could not write the IMEX CDI spec; multi-node NVLink will not work"
      rc=1; continue
    fi
    # This restarts k3s-agent, so it is done serially and waited on.
    if node_ssh "$n" "sudo K3S_DATA_DIR='${K3S_DATA_DIR}' \
          bash ${REPO_ROOT}/node/install-containerd-cdi-annotations.sh" >/dev/null 2>&1; then
      dbg "  ${n}: containerd forwards cdi.k8s.io/* annotations"
    else
      warn "  ${n}: could not allowlist CDI annotations; the imex annotation will be ignored"
      rc=1
    fi
  done
  (( rc == 0 )) && ok "IMEX channel access enabled (pods may request cdi.k8s.io/imex)" \
                || warn "IMEX access incomplete -- workloads/plumbing/07-nccl-2node.yaml will fail"
  return 0    # never fail the whole bring-up over this
}
