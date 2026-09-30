#!/usr/bin/env bash
#SBATCH --no-requeue
#
# slurm/lease.sbatch -- a placeholder job that HOLDS trays for the k8s cluster.
#
# --no-requeue is deliberate: a requeued lease re-runs on possibly different
# trays while the cluster still believes it owns the originals. A dead lease must
# stay dead so teardown runs exactly once.
#
# This job deliberately does no work. It exists to:
#
#   1. Claim the trays, so Slurm will not schedule anyone else onto them and our
#      usage shows up honestly in accounting.
#   2. Shield them from the OCI healthcheck. HealthCheckNodeState=IDLE,CYCLE means
#      the healthcheck drains *idle* nodes every 300s; ALLOCATED nodes are skipped.
#   3. Guarantee cleanup. k3s runs under systemd OUTSIDE this job's cgroup, so
#      cancelling the job does not stop kubelet. The trap below is the backstop
#      that keeps a walltime expiry from returning a dirty node to the pool.
#
# Submitted by lib/slurm.sh -> slurm_submit_lease(). Do not run by hand.
#
# argv: <cluster-name> <lease-name> <repo-root>

set -uo pipefail   # NOT -e: cleanup must run even if a step fails

CLUSTER_NAME="${1:?cluster name required}"
LEASE_NAME="${2:?lease name required}"
REPO_ROOT="${3:?repo root required}"

# shellcheck source=../lib/common.sh
. "${REPO_ROOT}/lib/common.sh"
load_cluster "$CLUSTER_NAME"

LEASE_DIR="${STATE_DIR}/leases"
mkdir -p "$LEASE_DIR"

# Record what we ACTUALLY got, which may differ from what we asked for.
NODELIST="${SLURM_JOB_NODELIST:-}"
printf '%s\n' "$NODELIST" > "${LEASE_DIR}/${LEASE_NAME}.nodes"
nodes_expand "$NODELIST" > "${LEASE_DIR}/${LEASE_NAME}.nodes.expanded"

banner() { printf '\n[lease %s] %s -- %s\n' "$LEASE_NAME" "$(date -Is)" "$*"; }

banner "started"
cat <<INFO
  cluster   : ${CLUSTER_NAME}
  lease     : ${LEASE_NAME}
  job id    : ${SLURM_JOB_ID:-?}
  nodes     : ${NODELIST}  (${SLURM_JOB_NUM_NODES:-?} trays)
  walltime  : $(squeue -h -j "${SLURM_JOB_ID:-0}" -o '%l' 2>/dev/null || echo '?')
  repo      : ${REPO_ROOT}
INFO

# --------------------------------------------------------------- cleanup
# Runs on: normal exit, scancel (SIGTERM), and walltime (SIGTERM delivered
# LEASE_SIGNAL_LEAD seconds early via --signal=B:TERM@N so we finish before SIGKILL).
_cleaned=0
cleanup() {
  [[ "$_cleaned" == 1 ]] && return 0
  _cleaned=1
  banner "releasing -- tearing down k8s on ${NODELIST}"

  local teardown="${REPO_ROOT}/node/teardown.sh"
  if [[ -x "$teardown" ]]; then
    # /home is NFS-mounted on every node, so nodes run the script in place.
    # Best-effort and per-node: one wedged node must not block the others.
    local n rc=0
    for n in $(nodes_expand "$NODELIST"); do
      printf '[lease %s] teardown %s\n' "$LEASE_NAME" "$n"
      timeout 300 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 "$n" \
        "sudo REPO_ROOT='${REPO_ROOT}' K8SBOOT_CLUSTER='${CLUSTER_NAME}' \
         K3S_DATA_DIR='${K3S_DATA_DIR}' NODE_INSTALL_DIR='${NODE_INSTALL_DIR}' \
         NODE_LOCAL_DISK='${NODE_LOCAL_DISK}' HOST_CDI_SPEC='${HOST_CDI_SPEC}' \
         bash '${teardown}' --role auto --baseline '${STATE_DIR}/snapshots/pre/${n}'" \
        2>&1 | sed "s/^/[lease ${LEASE_NAME}] ${n}: /" || { rc=1; echo "[lease ${LEASE_NAME}] ${n}: teardown FAILED"; }
    done
    if (( rc == 0 )); then
      banner "teardown complete on all trays"
    else
      banner "WARNING: teardown failed on at least one tray -- run bin/k8s-verify-clean"
    fi
  else
    banner "WARNING: ${teardown} not present; nodes may retain k3s state. Run bin/k8s-verify-clean"
  fi

  printf '%s\n' "released $(date -Is)" > "${LEASE_DIR}/${LEASE_NAME}.released"
  banner "released"
}
trap cleanup EXIT
trap 'banner "got SIGTERM"; exit 143' TERM
trap 'banner "got SIGINT";  exit 130' INT

# --------------------------------------------------------------- hold
printf '%s\n' "held $(date -Is)" > "${LEASE_DIR}/${LEASE_NAME}.held"
banner "holding trays; cancel with: scancel ${SLURM_JOB_ID:-?}  (prefer bin/k8s-down)"

# `sleep & wait` rather than a bare sleep: bash only runs a trap after the
# current foreground command finishes, so a bare `sleep infinity` would delay
# cleanup until the walltime kill. Backgrounding lets the trap fire immediately.
sleep infinity &
SLEEP_PID=$!
wait "$SLEEP_PID"
