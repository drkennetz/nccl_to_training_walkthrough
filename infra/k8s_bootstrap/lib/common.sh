#!/usr/bin/env bash
# lib/common.sh -- shared helpers. Source this first from every script.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# Honours:
#   DRY_RUN=1   print mutating commands instead of running them
#   VERBOSE=1   echo every remote command
#   NO_COLOR=1  plain output

[[ -n "${_K8SBOOT_COMMON:-}" ]] && return 0
_K8SBOOT_COMMON=1

set -euo pipefail

# ---------------------------------------------------------------- paths
# Resolve the repo root from this file's location so scripts work from anywhere.
_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_common_dir}/.." && pwd)"
unset _common_dir

# kubectl/helm are installed per-user by bin/k8s-install-tools. Prepend that dir
# so our scripts work whether or not the user has edited their PATH. Deliberately
# NOT /usr/local/bin, which holds the shared Slurm client binaries.
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) : ;;
  *) [[ -d "${HOME}/.local/bin" ]] && PATH="${HOME}/.local/bin:${PATH}" ;;
esac
export PATH

DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

# ---------------------------------------------------------------- output
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'
  _c_blu=$'\033[36m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
  _c_red=; _c_yel=; _c_grn=; _c_blu=; _c_dim=; _c_off=
fi

log()  { printf '%s\n' "${_c_blu}==>${_c_off} $*" >&2; }
ok()   { printf '%s\n' "${_c_grn} ok${_c_off} $*" >&2; }
warn() { printf '%s\n' "${_c_yel}warn${_c_off} $*" >&2; }
err()  { printf '%s\n' "${_c_red}FAIL${_c_off} $*" >&2; }
dbg()  { [[ "$VERBOSE" == 1 ]] && printf '%s\n' "${_c_dim}     $*${_c_off}" >&2 || true; }
die()  { err "$*"; exit 1; }

step() { printf '\n%s\n' "${_c_blu}### $*${_c_off}" >&2; }

# ---------------------------------------------------------------- guards
require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

# Refuse to run as root. Everything here uses passwordless sudo per-command so
# that what we elevate stays visible and auditable.
require_not_root() {
  [[ "$(id -u)" != 0 ]] || die "do not run this as root; it uses sudo per-command by design"
}

confirm() {
  local prompt="${1:-Proceed?}"
  [[ "${ASSUME_YES:-0}" == 1 ]] && { dbg "auto-confirmed: $prompt"; return 0; }
  local reply
  printf '%s [y/N] ' "$prompt" >&2
  read -r reply || return 1
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# run <cmd...>  -- honours DRY_RUN. Use for anything that mutates state.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "${_c_dim}dry-run: $*${_c_off}" >&2
    return 0
  fi
  dbg "+ $*"
  "$@"
}

# ---------------------------------------------------------------- config
# load_cluster [name] -- sources versions.env then clusters/<name>.env.
# Defaults to $K8SBOOT_CLUSTER, else the only *.env present, else the config named
# after this Slurm controller (<cluster>-controller), else fails.
#
# The hostname rule exists so adding a second cluster does not break every existing
# command that relied on "the only config": on polite-possum-controller nothing
# changes, on nearby-woodcock-controller the B300 config is picked. It reads the
# hostname rather than asking slurmctld, which can block for MessageTimeout.
load_cluster() {
  local name="${1:-${K8SBOOT_CLUSTER:-}}"

  if [[ -z "$name" ]]; then
    local found=()
    while IFS= read -r f; do found+=("$(basename "$f" .env)"); done \
      < <(find "${REPO_ROOT}/clusters" -maxdepth 1 -name '*.env' | sort)
    case ${#found[@]} in
      1) name="${found[0]}" ;;
      0) die "no cluster configs in ${REPO_ROOT}/clusters" ;;
      *) local h; h="$(hostname -s 2>/dev/null || true)"
         if [[ "$h" == *-controller && -f "${REPO_ROOT}/clusters/${h%-controller}.env" ]]; then
           name="${h%-controller}"
         else
           die "multiple clusters (${found[*]}); pass --cluster or set K8SBOOT_CLUSTER"
         fi ;;
    esac
  fi

  local cfg="${REPO_ROOT}/clusters/${name}.env"
  [[ -f "$cfg" ]] || die "no such cluster config: $cfg"

  set -a
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/versions.env"
  # shellcheck source=/dev/null
  . "$cfg"
  set +a

  # Topology state that must be resolved in THIS (the main) shell, once, before any subshell asks
  # for it -- lib/slurm.sh, when sourced (every entrypoint sources its libraries first).
  if declare -F slurm_flat_resolve >/dev/null; then slurm_flat_resolve; fi

  : "${CLUSTER_NAME:?cluster config must set CLUSTER_NAME}"
  : "${STATE_DIR:?cluster config must set STATE_DIR}"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  dbg "loaded cluster ${CLUSTER_NAME} (state: ${STATE_DIR})"
}

# ---------------------------------------------------------------- state
# Cluster state lives outside the repo. Secrets are 0600.
state_path() { printf '%s/%s' "${STATE_DIR:?load_cluster first}" "$1"; }

state_write() {                      # state_write <name> <<<"content"
  local f; f="$(state_path "$1")"
  mkdir -p "$(dirname "$f")"
  cat > "$f"
  chmod "${2:-0644}" "$f"
}

state_read() {                       # state_read <name> [default]
  local f; f="$(state_path "$1")"
  if [[ -r "$f" ]]; then cat "$f"; else printf '%s' "${2:-}"; fi
}

state_has() { [[ -s "$(state_path "$1")" ]]; }
state_rm()  { rm -f "$(state_path "$1")"; }

# ---------------------------------------------------------------- ssh / fanout
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=15 -o ServerAliveInterval=15 -o LogLevel=ERROR)

# node_ssh <node> <cmd...>
node_ssh() {
  local node="$1"; shift
  dbg "ssh ${node}: $*"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "${_c_dim}dry-run: ssh ${node} -- $*${_c_off}" >&2
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "${node}" -- "$@"
}

# node_ssh_ro <node> <cmd...> -- read-only probe; runs even under DRY_RUN.
node_ssh_ro() {
  local node="$1"; shift
  ssh "${SSH_OPTS[@]}" "${node}" -- "$@"
}

# nodes_run <comma-list-or-hostlist> <shell-command-string>
# Fans out with clush when available, else a bounded parallel ssh loop.
nodes_run() {
  local nodes="$1"; shift
  local cmd="$*"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "${_c_dim}dry-run: on [${nodes}] -- ${cmd}${_c_off}" >&2
    return 0
  fi
  if command -v clush >/dev/null 2>&1; then
    dbg "clush -w ${nodes}: ${cmd}"
    clush -S -b -w "$nodes" "$cmd"
  else
    dbg "ssh fanout ${nodes}: ${cmd}"
    local rc=0 n
    for n in $(nodes_expand "$nodes"); do
      ssh "${SSH_OPTS[@]}" "$n" -- "$cmd" 2>&1 | sed "s/^/${n}: /" || rc=1
    done
    return $rc
  fi
}

# nodes_expand "GPU-a-b-[0-2]" -> one node per line
nodes_expand() {
  [[ -n "${1:-}" ]] || return 0
  if command -v scontrol >/dev/null 2>&1; then
    scontrol show hostnames "$1"
  else
    tr ',' '\n' <<<"$1"
  fi
}

# nodes_compress "a b c" (or newline list) -> "GPU-x-y-[0-2]"
nodes_compress() {
  local list; list="$(tr ' \n' ',,' <<<"$*" | sed 's/,\+/,/g; s/^,//; s/,$//')"
  [[ -n "$list" ]] || return 0
  if command -v scontrol >/dev/null 2>&1; then
    scontrol show hostlistsorted "$list"
  else
    printf '%s' "$list"
  fi
}

nodes_count() { nodes_expand "${1:-}" | grep -c . || true; }
