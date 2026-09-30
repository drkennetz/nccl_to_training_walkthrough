#!/usr/bin/env bash
# node/install-agent.sh -- join a leased tray to the cluster as a worker.
# RUNS ON A LEASED NODE. Same host-safety constraints as install-server.sh.

set -euo pipefail

NODE_INSTALL_DIR="${NODE_INSTALL_DIR:-/opt/k8s-bootstrap}"
K3S_DATA_DIR="${K3S_DATA_DIR:-/mnt/localdisk/k3s}"
K3S_VERSION="${K3S_VERSION:?K3S_VERSION required}"
K3S_INSTALL_URL="${K3S_INSTALL_URL:-https://get.k3s.io}"
K3S_URL="${K3S_URL:?K3S_URL required (https://<server-ip>:6443)}"
K3S_TOKEN="${K3S_TOKEN:?K3S_TOKEN required}"
NODE_IP="${NODE_IP:?NODE_IP required}"

log() { printf '[install-agent] %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || exec sudo -E bash "$0" "$@"

log "joining ${K3S_URL} as $(hostname) (${NODE_IP})"
mkdir -p "${NODE_INSTALL_DIR}/bin" "${K3S_DATA_DIR}"

# ---------------------------------------------------------------- RDMA netns mode
# Must happen BEFORE k3s: the kernel refuses the switch (EBUSY) once any network namespace
# other than the root one exists, and every pod sandbox is one. See RDMA_NETNS_MODE in the
# cluster env for what the modes mean. Not persistent across a reboot; teardown restores
# the mode the pre snapshot recorded.
RDMA_NETNS_MODE="${RDMA_NETNS_MODE:-}"
if [[ -n "$RDMA_NETNS_MODE" ]] && command -v rdma >/dev/null 2>&1; then
  cur="$(rdma system 2>/dev/null | awk '/netns/{for(i=1;i<=NF;i++) if($i=="netns") print $(i+1)}')"
  if [[ "$cur" == "$RDMA_NETNS_MODE" ]]; then
    log "rdma netns mode already ${cur}"
  else
    others="$(lsns -t net -n -o NS 2>/dev/null | sort -u | wc -l)"
    mounted="$(ls -1 /run/netns 2>/dev/null | wc -l)"
    if (( others > 1 || mounted > 0 )); then
      log "ERROR: cannot set rdma netns mode ${RDMA_NETNS_MODE}: ${others} netns in use, ${mounted} mounted under /run/netns"
      lsns -t net -o NS,PID,COMMAND 2>/dev/null | head -20
      exit 1
    fi
    rdma system set netns "$RDMA_NETNS_MODE" || { log "ERROR: rdma system set netns ${RDMA_NETNS_MODE} failed"; exit 1; }
    log "rdma netns mode ${cur:-unknown} -> $(rdma system | awk '/netns/{for(i=1;i<=NF;i++) if($i=="netns") print $(i+1)}')"
  fi
fi

host="$(hostname)"
# Labels come from the controller (slurm_node_label_env), which knows the cluster's
# topology scheme; cutting our own hostname is the GB300-only fallback.
lb="${NODE_LOCALBLOCK:-$(cut -d- -f2 <<<"$host")}"
rack="${NODE_RACK:-$(cut -d- -f3 <<<"$host")}"
tray="${NODE_TRAY:-$(cut -d- -f4 <<<"$host")}"

exec_args=(
  agent
  --data-dir="${K3S_DATA_DIR}"
  --node-ip="${NODE_IP}"
  --node-label="k8s-bootstrap.io/localblock=${lb}"
  --node-label="k8s-bootstrap.io/rack=${rack}"
  --node-label="k8s-bootstrap.io/tray=${tray}"
  --node-label="k8s-bootstrap.io/role=worker"
)

curl -sfL "${K3S_INSTALL_URL}" \
  | INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_BIN_DIR="${NODE_INSTALL_DIR}/bin" \
    INSTALL_K3S_SYMLINK=skip \
    INSTALL_K3S_SYSTEMD_DIR=/etc/systemd/system \
    K3S_DATA_DIR="${K3S_DATA_DIR}" \
    K3S_URL="${K3S_URL}" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="${exec_args[*]}" \
    sh -

log "waiting for the agent to come up"
for i in $(seq 1 90); do
  systemctl is-active --quiet k3s-agent && { log "k3s-agent active after ${i}s"; break; }
  (( i == 90 )) && { log "ERROR: k3s-agent did not start"; \
                     systemctl status k3s-agent --no-pager -l | tail -30; exit 1; }
  sleep 1
done

[[ -x "${NODE_INSTALL_DIR}/bin/k3s-agent-uninstall.sh" ]] \
  || { log "ERROR: generated uninstaller missing"; exit 1; }
log "joined"
