#!/usr/bin/env bash
# lib/slurm.sh -- rack-aware node selection and placeholder-lease management.
#
# Two ideas drive this file:
#
# 1. Nodes are held by a REAL placeholder job, never a reservation. The OCI
#    healthcheck drains *idle* nodes every 300s (HealthCheckNodeState=IDLE,CYCLE);
#    nodes held by a running job are ALLOCATED and skipped. The lease is both our
#    claim and our shield, and it keeps our usage legible to Slurm accounting.
#
# 2. A rack is the unit of scaling. On GB300 node names encode topology as
#    GPU-<localblock>-<rack>-<tray>, and 18 trays = one rack = one NVL72 NVLink
#    domain = one CliqueId. Multi-node NVLink only works *within* a rack, so we
#    never spread one k8s node pool across racks by accident.

[[ -n "${_K8SBOOT_SLURM:-}" ]] && return 0
_K8SBOOT_SLURM=1

# shellcheck source=./common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ------------------------------------------------------------------ parsing
# Two topology modes, chosen per cluster by NODE_TOPOLOGY:
#
#   name (default) -- GB300 NVL72: the name encodes topology.
#                     GPU-ez4wq-2nyvq-7 -> localblock=ez4wq rack=2nyvq tray=7
#   flat           -- HGX (e.g. BM.GPU.B300.8): names are GPU-<n> and carry no
#                     topology, and every host is its own NVLink domain. Nodes
#                     matching FLAT_NODE_RE form ONE pseudo-rack, FLAT_RACKID
#                     ("<block>/<rail>", from /etc/slurm/topology.yaml); tray=<n>.
#                     Anything not matching (e.g. a GB200 partition sharing the
#                     same Slurm partition) is invisible, exactly as an
#                     unparseable name is invisible in `name` mode.
readonly SLURM_NODE_RE='^([A-Za-z]+)-([a-z0-9]+)-([a-z0-9]+)-([0-9]+)$'

_slurm_flat() { [[ "${NODE_TOPOLOGY:-name}" == flat ]]; }
_flat_re()    { printf '%s' "${FLAT_NODE_RE:-^GPU-([0-9]+)$}"; }

# Optional membership filter: FLAT_TOPOLOGY_SWITCH names a switch in Slurm's topology file
# (FLAT_TOPOLOGY_FILE, default /etc/slurm/topology.yaml); only its nodes belong to the
# pseudo-rack. Needed because a Slurm node record can match the name pattern, answer ssh with
# the right hostname, pass preflight -- and still be absent from the topology, which makes any
# multi-node lease that includes it fail with "Requested topology configuration is not
# available" (GPU-2571 on nearby-woodcock, 2026-09-26). Parsed once per process; an unreadable
# file or unknown switch is fatal rather than silently admitting every node.
#
# Resolved ONCE, in the main shell, by load_cluster (slurm_flat_resolve) and EXPORTED: nearly every
# caller runs inside $(...) or a pipeline, where a cache written by the lookup itself is thrown away
# with the subshell (each node lookup then paid a fresh python3 parse, ~100 ms), and a die there
# only ended the subshell -- a bad switch surfaced as "no rack with N idle trays" (PR #1 review).
: "${_K8SBOOT_FLAT_MEMBERS:=}"
slurm_flat_resolve() {
  _slurm_flat && [[ -n "${FLAT_TOPOLOGY_SWITCH:-}" ]] || return 0
  _K8SBOOT_FLAT_MEMBERS=""
  _K8SBOOT_FLAT_MEMBERS="$(_flat_members)" || die "FLAT_TOPOLOGY_SWITCH: could not resolve ${FLAT_TOPOLOGY_SWITCH}"
  export _K8SBOOT_FLAT_MEMBERS
}
_flat_members() {
  [[ -n "$_K8SBOOT_FLAT_MEMBERS" ]] && { printf '%s' "$_K8SBOOT_FLAT_MEMBERS"; return 0; }
  local out
  out="$(python3 - "${FLAT_TOPOLOGY_FILE:-/etc/slurm/topology.yaml}" "$FLAT_TOPOLOGY_SWITCH" <<'PY' 2>&1
import sys, yaml
path, want = sys.argv[1], sys.argv[2]
docs = yaml.safe_load(open(path))
for topo in docs if isinstance(docs, list) else [docs]:
    for sw in (topo.get("tree") or {}).get("switches", []):
        if sw.get("switch") == want:
            nodes = [n for n in (sw.get("nodes") or "").split(",") if n]
            if not nodes:
                sys.exit(f"switch {want} has no direct nodes")
            print(" " + " ".join(nodes) + " "); sys.exit(0)
sys.exit(f"switch {want} not found in {path}")
PY
)" || die "FLAT_TOPOLOGY_SWITCH: ${out}"
  _K8SBOOT_FLAT_MEMBERS="$out"
  printf '%s' "$out"
}

slurm_node_valid() {
  if _slurm_flat; then
    [[ -n "${FLAT_RACKID:-}" && "${FLAT_RACKID}" == */* ]] \
      || die "NODE_TOPOLOGY=flat needs FLAT_RACKID='<block>/<rail>' in the cluster env"
    local re; re="$(_flat_re)"; [[ $1 =~ $re ]] || return 1
    [[ -z "${FLAT_TOPOLOGY_SWITCH:-}" ]] && return 0
    [[ "$(_flat_members)" == *" $1 "* ]]
  else
    [[ $1 =~ $SLURM_NODE_RE ]]
  fi
}
slurm_node_localblock() {
  if _slurm_flat; then slurm_node_valid "$1" && printf '%s' "${FLAT_RACKID%%/*}"
  else [[ $1 =~ $SLURM_NODE_RE ]] && printf '%s' "${BASH_REMATCH[2]}"; fi
}
slurm_node_rack() {
  if _slurm_flat; then slurm_node_valid "$1" && printf '%s' "${FLAT_RACKID#*/}"
  else [[ $1 =~ $SLURM_NODE_RE ]] && printf '%s' "${BASH_REMATCH[3]}"; fi
}
slurm_node_tray() {
  if _slurm_flat; then
    local re; re="$(_flat_re)"; [[ $1 =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
  else [[ $1 =~ $SLURM_NODE_RE ]] && printf '%s' "${BASH_REMATCH[4]}"; fi
}
# Fully-qualified rack id, unique across localblocks.
slurm_node_rackid() {
  slurm_node_valid "$1" || return 1
  printf '%s/%s' "$(slurm_node_localblock "$1")" "$(slurm_node_rack "$1")"
}

# Is <localblock/rack> a well-formed rack id for this cluster's topology scheme?
slurm_rackid_valid() {
  if _slurm_flat; then [[ "$1" == "${FLAT_RACKID:-}" ]]
  else slurm_node_valid "GPU-${1//\//-}-0"; fi
}

# Topology labels for the on-node installers, as an env prefix. The installers
# used to cut(1) their own hostname, which only works for the `name` scheme.
slurm_node_label_env() {
  printf "NODE_LOCALBLOCK='%s' NODE_RACK='%s' NODE_TRAY='%s' " \
    "$(slurm_node_localblock "$1" || true)" "$(slurm_node_rack "$1" || true)" \
    "$(slurm_node_tray "$1" || true)"
}

# Sort node names by tray number (works for both schemes: tray is always the last field).
_slurm_sort_by_tray() { awk -F- '{print $NF"\t"$0}' | sort -k1,1n | cut -f2; }

# ------------------------------------------------------------------ inventory
# Responsive, genuinely-idle nodes, one per line, excluding localblocks we must
# leave alone. `sinfo %t` suffixes state with '*' when the node is NOT_RESPONDING,
# so we match "idle" exactly -- "idle*" is a powered-down/unreachable node that
# would silently fail to join.
slurm_idle_nodes() {
  local excluded=" ${EXCLUDE_LOCALBLOCKS:-} "
  # Resolve the topology membership HERE, in the calling shell: inside the pipeline below a
  # die would only end the subshell and the caller would see "no idle nodes" instead of why.
  if _slurm_flat && [[ -n "${FLAT_TOPOLOGY_SWITCH:-}" ]]; then _flat_members >/dev/null; fi
  sinfo -h -N -p "${SLURM_PARTITION:-compute}" -o '%N|%t' 2>/dev/null \
    | sort -u \
    | awk -F'|' '$2 == "idle" { print $1 }' \
    | while read -r n; do
        slurm_node_valid "$n" || continue
        [[ "$excluded" == *" $(slurm_node_localblock "$n") "* ]] && continue
        printf '%s\n' "$n"
      done
}

# "<idle-tray-count> <localblock/rack>" per line, most-idle rack first.
slurm_racks_by_capacity() {
  slurm_idle_nodes \
    | while read -r n; do printf '%s\n' "$(slurm_node_rackid "$n")"; done \
    | sort | uniq -c | sort -k1,1nr -k2,2 | awk '{print $1" "$2}'
}

slurm_rack_idle_trays() {            # slurm_rack_idle_trays <localblock/rack>
  local want="$1"
  slurm_idle_nodes | while read -r n; do
    [[ "$(slurm_node_rackid "$n")" == "$want" ]] && printf '%s\n' "$n"
  done | _slurm_sort_by_tray
}

# Pick the rack to use for <n> trays.
#
# Deliberately picks the *tightest* rack that fits, walking PREFER_LOCALBLOCKS in
# order first. Taking the emptiest rack would fragment the big contiguous blocks
# other people need for large jobs; taking the tightest leaves those intact.
slurm_pick_rack() {
  local need="${1:-1}" rack count lb
  local -a candidates=()

  while read -r count rack; do
    (( count >= need )) && candidates+=("${count} ${rack}")
  done < <(slurm_racks_by_capacity)

  ((${#candidates[@]})) || return 1

  # First pass: honour PREFER_LOCALBLOCKS order, tightest fit within each.
  for lb in ${PREFER_LOCALBLOCKS:-}; do
    local best_rack="" best_count=99999
    for c in "${candidates[@]}"; do
      count="${c%% *}"; rack="${c#* }"
      [[ "${rack%%/*}" == "$lb" ]] || continue
      (( count < best_count )) && { best_count=$count; best_rack=$rack; }
    done
    [[ -n "$best_rack" ]] && { printf '%s' "$best_rack"; return 0; }
  done

  # Fallback: tightest fit anywhere not excluded.
  local best_rack="" best_count=99999
  for c in "${candidates[@]}"; do
    count="${c%% *}"; rack="${c#* }"
    (( count < best_count )) && { best_count=$count; best_rack=$rack; }
  done
  [[ -n "$best_rack" ]] || return 1
  printf '%s' "$best_rack"
}

# slurm_rank_racks <n> -> candidate racks that could hold n trays, best first.
#
# Ordering: PREFER_LOCALBLOCKS order first, then tightest fit within each, then
# anything else tightest-first. Callers should walk this list rather than trusting
# the first entry: a rack with exactly n idle trays is often a mostly-down rack
# whose remaining nodes are unreachable, so selection has to be able to fall
# through to the next candidate.
slurm_rank_racks() {
  local need="${1:-1}" rack count lb
  local -a cands=()
  while read -r count rack; do
    (( count >= need )) && cands+=("${count} ${rack}")
  done < <(slurm_racks_by_capacity)
  ((${#cands[@]})) || return 1

  local -a emitted=()
  _emit_sorted() {                     # print given entries tightest-fit first
    local -a subset=("$@")
    ((${#subset[@]})) || return 0
    printf '%s\n' "${subset[@]}" | sort -k1,1n | awk '{print $2}'
  }

  for lb in ${PREFER_LOCALBLOCKS:-}; do
    local -a group=()
    for c in "${cands[@]}"; do
      rack="${c#* }"
      [[ "${rack%%/*}" == "$lb" ]] && { group+=("$c"); emitted+=("$rack"); }
    done
    _emit_sorted "${group[@]}"
  done

  # Anything in a localblock not named in PREFER_LOCALBLOCKS.
  local -a rest=()
  for c in "${cands[@]}"; do
    rack="${c#* }"
    local seen=0
    for e in "${emitted[@]:-}"; do [[ "$e" == "$rack" ]] && { seen=1; break; }; done
    (( seen )) || rest+=("$c")
  done
  _emit_sorted "${rest[@]}"
}

# slurm_pick_trays <n> [localblock/rack] -> n node names from ONE rack
slurm_pick_trays() {
  local need="${1:-1}" rack="${2:-}"
  [[ -n "$rack" ]] || rack="$(slurm_pick_rack "$need")" \
    || die "no single rack has ${need} responsive idle trays (excluding: ${EXCLUDE_LOCALBLOCKS:-none})"

  local -a trays=()
  mapfile -t trays < <(slurm_rack_idle_trays "$rack")
  (( ${#trays[@]} >= need )) \
    || die "rack ${rack} has only ${#trays[@]} responsive idle trays, need ${need}"
  printf '%s\n' "${trays[@]:0:need}"
}

# ------------------------------------------------------------------ leases
# A lease is one Slurm job holding a set of trays. Two kinds:
#   controlplane -- 1 tray, long walltime, outlives rack churn
#   rack:<id>    -- worker trays from a single rack
slurm_lease_key()  { printf 'leases/%s.jobid' "$1"; }
slurm_lease_nodes_key() { printf 'leases/%s.nodes' "$1"; }

slurm_lease_jobid() { state_read "$(slurm_lease_key "$1")"; }
slurm_lease_nodes() { state_read "$(slurm_lease_nodes_key "$1")"; }

# Is the lease job actually alive right now?
slurm_lease_alive() {
  local jobid; jobid="$(slurm_lease_jobid "$1")"
  [[ -n "$jobid" ]] || return 1
  local st
  st="$(squeue -h -j "$jobid" -o '%T' 2>/dev/null | head -1)"
  [[ "$st" == RUNNING || "$st" == PENDING || "$st" == CONFIGURING ]]
}

slurm_lease_state() {
  local jobid; jobid="$(slurm_lease_jobid "$1")"
  if [[ -z "$jobid" ]]; then printf 'NONE'; return; fi
  local st; st="$(squeue -h -j "$jobid" -o '%T' 2>/dev/null | head -1)"
  printf '%s' "${st:-GONE}"
}

# slurm_submit_lease <name> <sbatch-script> <nodelist> [extra sbatch args...]
slurm_submit_lease() {
  local name="$1" script="$2" nodelist="$3"; shift 3
  local ntrays; ntrays="$(nodes_count "$nodelist")"

  if slurm_lease_alive "$name"; then
    die "lease '${name}' already active (job $(slurm_lease_jobid "$name")); release it first"
  fi

  local -a args=(
    --job-name "${LEASE_JOB_PREFIX:-k8sboot}-${CLUSTER_NAME}-${name}"
    --partition "${SLURM_PARTITION:-compute}"
    --nodelist "$nodelist"
    --nodes "$ntrays"
    --exclusive
    # --no-kill: one tray failing must not end the lease. Without it Slurm ends the whole job
    # NODE_FAIL, the trap gets KillWait (30 s) instead of the signal lead, and its serial
    # teardown dies after a few trays: on nearby-woodcock (2026-09-27) three trays went dark,
    # the 32-tray lease ended NODE_FAIL, the trap cleaned 4 of 32, and 28 trays sat in the
    # shared pool with k3s-agent still running for ~19 h. With --no-kill the lease keeps the
    # live trays held; k8s-down (or walltime, with the full signal lead) tears them down, and
    # the dead ones report UNVERIFIED as designed.
    --no-kill
    --gres "gpu:${GPUS_PER_NODE:-4}"
    # Advance SIGTERM so the trap has time to uninstall k3s before SIGKILL.
    # Slurm's KillWait is only 30s, which is not enough to drain and uninstall.
    --signal "B:TERM@${LEASE_SIGNAL_LEAD:-300}"
    --output "${STATE_DIR}/leases/${name}.slurm.log"
    --open-mode append
  )
  [[ -n "${LEASE_RESERVATION:-}" ]] && args+=(--reservation "${LEASE_RESERVATION}")
  # Belt and braces for partitions shared by several node types (nearby-woodcock's
  # `compute` holds both B300 and GB200): the feature must match too.
  [[ -n "${SLURM_CONSTRAINT:-}" ]] && args+=(--constraint "${SLURM_CONSTRAINT}")
  args+=("$@")

  mkdir -p "${STATE_DIR}/leases"

  log "submitting lease '${name}': ${ntrays} tray(s) on ${nodelist}"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "dry-run: sbatch ${args[*]} ${script}" >&2
    return 0
  fi

  local jobid
  jobid="$(sbatch --parsable "${args[@]}" "$script" \
            "$CLUSTER_NAME" "$name" "$REPO_ROOT")" \
    || die "sbatch failed for lease '${name}'"
  jobid="${jobid%%;*}"   # strip ";cluster" if sbatch appends it

  state_write "$(slurm_lease_key "$name")" <<<"$jobid"
  state_write "$(slurm_lease_nodes_key "$name")" <<<"$nodelist"
  ok "lease '${name}' submitted as job ${jobid}"
  printf '%s' "$jobid"
}

# Block until the lease is RUNNING and its nodes are reachable.
slurm_wait_lease() {
  local name="$1" timeout="${2:-600}"
  [[ "$DRY_RUN" == 1 ]] && { dbg "dry-run: not waiting for lease '${name}'"; return 0; }
  local jobid; jobid="$(slurm_lease_jobid "$name")"
  [[ -n "$jobid" ]] || die "no recorded job for lease '${name}'"

  log "waiting for lease '${name}' (job ${jobid}) to start..."
  local waited=0 st
  while (( waited < timeout )); do
    st="$(squeue -h -j "$jobid" -o '%T' 2>/dev/null | head -1)"
    case "$st" in
      RUNNING) ok "lease '${name}' running"; return 0 ;;
      ""|COMPLETED|CANCELLED|FAILED|TIMEOUT|NODE_FAIL)
        die "lease '${name}' (job ${jobid}) ended before starting: ${st:-GONE}; see ${STATE_DIR}/leases/${name}.slurm.log" ;;
    esac
    sleep 5; waited=$((waited + 5))
  done
  die "lease '${name}' did not start within ${timeout}s (state: ${st:-unknown})"
}

# Release a lease. Node teardown is the CALLER's job and must happen FIRST --
# k3s runs under systemd outside the job cgroup, so scancel alone leaves kubelet
# running on a node that returns to the shared pool. The sbatch trap is a
# backstop for walltime expiry, not the primary path.
slurm_cancel_lease() {
  local name="$1"
  local jobid; jobid="$(slurm_lease_jobid "$name")"
  if [[ -z "$jobid" ]]; then warn "no recorded lease '${name}'"; return 0; fi

  if slurm_lease_alive "$name"; then
    log "cancelling lease '${name}' (job ${jobid})"
    run scancel "$jobid"
  else
    dbg "lease '${name}' (job ${jobid}) already inactive"
  fi
  [[ "$DRY_RUN" == 1 ]] || { state_rm "$(slurm_lease_key "$name")"
                             state_rm "$(slurm_lease_nodes_key "$name")"; }
}

slurm_list_leases() {
  local d="${STATE_DIR}/leases"
  [[ -d "$d" ]] || return 0
  find "$d" -maxdepth 1 -name '*.jobid' -printf '%f\n' 2>/dev/null \
    | sed 's/\.jobid$//' | sort
}

# Are these nodes still ours and healthy? Catches a node drained mid-flight.
slurm_assert_nodes_allocated() {
  local nodelist="$1" bad=0 n st
  for n in $(nodes_expand "$nodelist"); do
    st="$(sinfo -h -N -n "$n" -o '%t' 2>/dev/null | sort -u | head -1)"
    case "$st" in
      alloc|mix|comp) : ;;
      *) err "node ${n} is '${st}', expected allocated"; bad=1 ;;
    esac
  done
  return $bad
}

# ------------------------------------------------------------------ lease roles
# One sbatch script (slurm/lease.sbatch) serves both roles; the only real
# difference is walltime, which is already a per-cluster config value. Two
# near-identical sbatch files would just drift apart.
SLURM_LEASE_SCRIPT_REL="slurm/lease.sbatch"

_slurm_lease_script() {
  local s="${REPO_ROOT}/${SLURM_LEASE_SCRIPT_REL}"
  [[ -f "$s" ]] || die "lease script missing: $s"
  printf '%s' "$s"
}

# The control-plane lease: one tray, long walltime, so the API server survives
# racks coming and going.
slurm_lease_controlplane() {          # slurm_lease_controlplane [node]
  local node="${1:-}"
  [[ -n "$node" ]] || node="$(slurm_pick_trays 1)"
  slurm_submit_lease controlplane "$(_slurm_lease_script)" "$node" \
    --time "${LEASE_CONTROLPLANE_TIME:-7-00:00:00}"
}

# A worker lease, named after the rack it holds so leases map 1:1 to NVLink domains.
slurm_lease_rack() {                  # slurm_lease_rack <localblock/rack> <nodelist>
  local rackid="$1" nodelist="$2"
  slurm_submit_lease "rack-${rackid//\//-}" "$(_slurm_lease_script)" "$nodelist" \
    --time "${LEASE_RACK_TIME:-3-00:00:00}"
}

slurm_lease_name_for_rack() { printf 'rack-%s' "${1//\//-}"; }

# Every rack lease currently recorded, as "<lease-name> <localblock/rack>".
slurm_list_rack_leases() {
  local l
  while read -r l; do
    [[ "$l" == rack-* ]] || continue
    local id="${l#rack-}"
    printf '%s %s/%s\n' "$l" "${id%%-*}" "${id#*-}"
  done < <(slurm_list_leases)
}

# Is slurmctld answering?
#
# Worth a dedicated probe because sinfo/squeue do NOT fail fast when it is not:
# they block for the full MessageTimeout. Measured on this cluster with slurmctld
# down, `sinfo -h -N -p compute` took exactly 120.024s, and a command that makes
# several such calls just appears to hang. `scontrol ping` answers immediately
# either way, so it is the right gate.
slurm_ctld_up() {
  local out
  out="$(timeout 10 scontrol ping 2>/dev/null || true)"
  [[ "$out" == *"is UP"* ]]
}

# Refuse to continue when Slurm is unavailable, with an explanation rather than a
# two-minute stall. Only for commands that genuinely cannot work without it --
# anything whose job is to CLEAN a node should proceed regardless, because
# teardown runs over ssh and handing a node back matters more than the lease
# bookkeeping.
slurm_require_ctld() {
  slurm_ctld_up && return 0
  err "slurmctld is not responding: $(timeout 10 scontrol ping 2>&1 | head -1)"
  err "  sinfo/squeue will each block for MessageTimeout (measured: 120s), so stopping now."
  err "  This is cluster-wide and not something this repo can fix -- check"
  err "  'systemctl status slurmctld' and escalate to the cluster admins."
  die "Slurm control daemon unavailable"
}

# Is a rack already held by one of our leases?
#
# Matters because Slurm cannot add nodes to a running job: growing a rack we
# already hold would need a second lease, and lease names map 1:1 to racks
# (slurm_list_rack_leases parses the name back into localblock/rack), so the
# second one would collide. bin/k8s-add-rack refuses instead.
slurm_rack_is_leased() {              # slurm_rack_is_leased <localblock/rack>
  local name; name="$(slurm_lease_name_for_rack "$1")"
  state_has "$(slurm_lease_key "$name")" || return 1
  # Recorded but GONE (the job ended without bin/k8s-down clearing the state — a scancel-ed
  # lease): the rack is not held, and refusing to re-add it would strand it until someone
  # notices the stale file. bin/k8s-down / k8s-verify-clean still report the stale record.
  slurm_lease_alive "$name"
}

# Rack ids we already hold a rack lease for, space-separated on one line, for
# feeding to slurm_pick_verified_trays' skip list.
slurm_leased_rackids() {
  local l id
  while read -r l id; do printf '%s ' "$id"; done < <(slurm_list_rack_leases)
}

# All nodes we currently hold, across every lease.
slurm_all_leased_nodes() {
  local l
  while read -r l; do
    nodes_expand "$(slurm_lease_nodes "$l")"
  done < <(slurm_list_leases) | sort -u | grep . || true
}
