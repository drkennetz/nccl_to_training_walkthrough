#!/usr/bin/env bash
# node/install-server.sh -- install the k3s server. RUNS ON A LEASED NODE.
#
# Deliberately conservative about the host:
#   - binaries go to $NODE_INSTALL_DIR/bin, never /usr/local/bin, because that
#     directory precedes /usr/bin on PATH and a k3s ctr/crictl symlink there
#     would shadow the host containerd tooling for every other user of the node
#   - INSTALL_K3S_SYMLINK=skip, so no symlinks are created at all
#   - k3s runs its own embedded containerd; the host's is never reconfigured
#   - all state lives on the big local NVMe, not the ~123G root filesystem

set -euo pipefail

NODE_INSTALL_DIR="${NODE_INSTALL_DIR:-/opt/k8s-bootstrap}"
K3S_DATA_DIR="${K3S_DATA_DIR:-/mnt/localdisk/k3s}"
K3S_VERSION="${K3S_VERSION:?K3S_VERSION required}"
K3S_INSTALL_URL="${K3S_INSTALL_URL:-https://get.k3s.io}"
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
CLUSTER_DNS="${CLUSTER_DNS:-10.43.0.10}"
NODE_IP="${NODE_IP:?NODE_IP required}"
CLUSTER_NAME="${CLUSTER_NAME:-k8sboot}"

log() { printf '[install-server] %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || exec sudo -E bash "$0" "$@"

log "k3s ${K3S_VERSION} on $(hostname) (${NODE_IP})"
mkdir -p "${NODE_INSTALL_DIR}/bin" "${K3S_DATA_DIR}"

# Labels record the physical topology so the scheduler can respect NVLink domains.
# A rack is one NVL72 domain, so a multi-node NVLink job must stay inside one.
host="$(hostname)"
# Labels come from the controller (slurm_node_label_env), which knows the cluster's
# topology scheme; cutting our own hostname is the GB300-only fallback.
lb="${NODE_LOCALBLOCK:-$(cut -d- -f2 <<<"$host")}"
rack="${NODE_RACK:-$(cut -d- -f3 <<<"$host")}"
tray="${NODE_TRAY:-$(cut -d- -f4 <<<"$host")}"

# --disable-kube-proxy / --flannel-backend=none: Cilium provides both. Until it
# is installed (step 5) nodes stay NotReady, which is expected, not a failure.
exec_args=(
  server
  --data-dir="${K3S_DATA_DIR}"
  --node-ip="${NODE_IP}"
  --advertise-address="${NODE_IP}"
  --tls-san="${NODE_IP}"
  --tls-san="${host}"
  --cluster-cidr="${POD_CIDR}"
  --service-cidr="${SERVICE_CIDR}"
  --cluster-dns="${CLUSTER_DNS}"
  --flannel-backend=none
  --disable-network-policy
  --disable-kube-proxy
  --disable=traefik,servicelb,local-storage,metrics-server
  --disable-helm-controller
  --disable-cloud-controller
  --write-kubeconfig-mode=0600
  --node-taint=node-role.kubernetes.io/control-plane=:NoSchedule
  --node-label="k8s-bootstrap.io/localblock=${lb}"
  --node-label="k8s-bootstrap.io/rack=${rack}"
  --node-label="k8s-bootstrap.io/tray=${tray}"
  --node-label="k8s-bootstrap.io/role=control-plane"
)

curl -sfL "${K3S_INSTALL_URL}" \
  | INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_BIN_DIR="${NODE_INSTALL_DIR}/bin" \
    INSTALL_K3S_SYMLINK=skip \
    INSTALL_K3S_SYSTEMD_DIR=/etc/systemd/system \
    K3S_DATA_DIR="${K3S_DATA_DIR}" \
    INSTALL_K3S_EXEC="${exec_args[*]}" \
    sh -

log "waiting for the API server to answer"
for i in $(seq 1 120); do
  if "${NODE_INSTALL_DIR}/bin/k3s" kubectl get --raw='/readyz' >/dev/null 2>&1; then
    log "API server ready after ${i}s"; break
  fi
  (( i == 120 )) && { log "ERROR: API server did not become ready"; \
                      systemctl status k3s --no-pager -l | tail -30; exit 1; }
  sleep 1
done

# The uninstaller k3s generates is the primary teardown path; make sure it exists
# and knows about our relocated bin dir before we depend on it later.
[[ -x "${NODE_INSTALL_DIR}/bin/k3s-uninstall.sh" ]] \
  || { log "ERROR: generated uninstaller missing -- refusing to leave an unremovable install"; exit 1; }

log "installed. token and kubeconfig are readable via sudo:"
log "  token      ${K3S_DATA_DIR}/server/node-token"
log "  kubeconfig /etc/rancher/k3s/k3s.yaml"
