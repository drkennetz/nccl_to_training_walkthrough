#!/usr/bin/env bash
# tests/test-rack-leases.sh -- unit tests for rack-lease bookkeeping and for the
# skip-already-leased-racks path that bin/k8s-add-rack depends on.
#
# Why this file exists: Slurm cannot add nodes to a running job, and lease names
# map 1:1 to racks (slurm_list_rack_leases parses the name back into
# localblock/rack). So a second lease for a rack we already hold would collide
# and corrupt that mapping. add-rack must therefore *never* select a rack it is
# already holding, and the property is cheap to pin here and expensive to notice
# live -- the symptom would be a half-leased rack and a confusing sbatch error.
#
# These tests run entirely offline: slurm_verify_trays() is stubbed, which is the
# reason it was extracted from slurm_pick_verified_trays() in the first place.
# sinfo is stubbed too -- the die path probes it for COMPLETING nodes, and when
# slurmctld is down that single call blocks for the full MessageTimeout. That is
# how this suite once took 120s: it was quietly talking to a dead cluster.
#
# Run: tests/test-rack-leases.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib/preflight.sh
. lib/preflight.sh
# lib/common.sh (sourced transitively) sets -e; these tests deliberately exercise
# failure paths, so turn it back off.
set +e

pass=0; fail=0
check() {                      # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then printf '  ok    %-30s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %-30s wanted [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# Keep the suite hermetic and instant. Without these, the two failure-path cases
# below each reach the real sinfo.
sinfo() { printf ''; }
scontrol() { case "${1:-}" in show) shift; case "${1:-}" in hostnames) tr ',' '\n' <<<"${2:-}" ;; hostlistsorted) printf '%s' "${2:-}" ;; esac ;; esac; }

# A throwaway state dir so lease bookkeeping is real but harmless. state_path
# only needs STATE_DIR, so this avoids depending on a cluster config.
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
mkdir -p "${STATE_DIR}/leases"

hold_rack() {                  # hold_rack <localblock/rack> <jobid>
  printf '%s\n' "$2" > "${STATE_DIR}/leases/rack-${1//\//-}.jobid"
  printf 'GPU-%s-0\n' "${1//\//-}" > "${STATE_DIR}/leases/rack-${1//\//-}.nodes"
}

# ------------------------------------------------------------------ naming
check "lease name for rack"  "rack-ez4wq-bi4ua"  "$(slurm_lease_name_for_rack ez4wq/bi4ua)"

# ------------------------------------------------------------------ is_leased
# A recorded lease counts as held only while its Slurm job is alive: stub squeue so the
# test runs off-controller. Job 67775 is RUNNING; anything else is gone.
squeue() { [[ "$*" == *67775* ]] && printf 'RUNNING\n'; :; }
check "unheld rack not leased" "1" "$(slurm_rack_is_leased ez4wq/bi4ua; echo $?)"
hold_rack ez4wq/bi4ua 67775
check "held rack is leased"    "0" "$(slurm_rack_is_leased ez4wq/bi4ua; echo $?)"
check "sibling rack unaffected" "1" "$(slurm_rack_is_leased ez4wq/56l4q; echo $?)"
# A lease whose job ENDED (scancel-ed, walltime) but whose .jobid file survived must not
# hold the rack hostage: bin/k8s-add-rack refused wa6cq/b6y2q on exactly this (2026-09-17).
hold_rack ez4wq/56l4q 11111
check "recorded but GONE lease is not held" "1" "$(slurm_rack_is_leased ez4wq/56l4q; echo $?)"
rm -f "${STATE_DIR}/leases/rack-ez4wq-56l4q.jobid" "${STATE_DIR}/leases/rack-ez4wq-56l4q.nodes"

# An empty .jobid must not count as held -- state_has tests for non-empty, and a
# truncated file would otherwise wedge add-rack out of a perfectly free rack.
: > "${STATE_DIR}/leases/rack-tboia-ssh2a.jobid"
check "empty jobid is not held" "1" "$(slurm_rack_is_leased tboia/ssh2a; echo $?)"
rm -f "${STATE_DIR}/leases/rack-tboia-ssh2a.jobid"

# ------------------------------------------------------------------ leased ids
hold_rack q4mra/5athq 67776
check "leased rackids"  "ez4wq/bi4ua q4mra/5athq "  "$(slurm_leased_rackids)"

# The controlplane lease is NOT a rack lease and must not appear: it holds a
# single tray on a long walltime and is deliberately outside rack churn.
printf '67763\n' > "${STATE_DIR}/leases/controlplane.jobid"
check "controlplane not a rack" "ez4wq/bi4ua q4mra/5athq " "$(slurm_leased_rackids)"

# ------------------------------------------------------------------ skip racks
# Stub the inventory and the identity check so selection is deterministic.
slurm_racks_by_capacity() {
  cat <<'INV'
17 ez4wq/iia5a
14 ez4wq/bi4ua
4 q4mra/5athq
3 tboia/ssh2a
INV
}
slurm_rack_idle_trays() {      # every tray in the rack is idle and verifiable
  local rack="$1" i
  for i in 0 1 2 3; do printf 'GPU-%s-%s\n' "${rack//\//-}" "$i"; done
}
slurm_verify_trays() { SLURM_VERIFY_BAD=(); printf '%s\n' "$@"; }
PREFER_LOCALBLOCKS="tboia ez4wq q4mra"

# With nothing skipped, PREFER order wins: tboia first.
check "no skip -> preferred rack" "GPU-tboia-ssh2a-0" \
  "$(slurm_pick_verified_trays 1 "" "" 2>/dev/null | head -1)"

# Skipping tboia must fall through to the next preferred localblock, NOT fail.
check "skip one -> next rack" "GPU-ez4wq-bi4ua-0" \
  "$(slurm_pick_verified_trays 1 "" "tboia/ssh2a" 2>/dev/null | head -1)"

# Skipping several still falls through rather than giving up early.
check "skip several" "GPU-q4mra-5athq-0" \
  "$(slurm_pick_verified_trays 1 "" "tboia/ssh2a ez4wq/bi4ua ez4wq/iia5a" 2>/dev/null | head -1)"

# A skip list must match whole rack ids. 'ez4wq/bi4ua' must not also knock out
# 'ez4wq/bi4ua2' by prefix, nor may a bare localblock skip every rack in it.
check "skip is not a prefix match" "GPU-ez4wq-bi4ua-0" \
  "$(slurm_pick_verified_trays 1 "" "tboia/ssh2a ez4wq" 2>/dev/null | head -1)"

# Skipping everything is a clear failure, not a silent empty result: add-rack
# checks the array length, but the exit status has to be nonzero too.
out="$(slurm_pick_verified_trays 1 "" "tboia/ssh2a ez4wq/bi4ua ez4wq/iia5a q4mra/5athq" 2>/dev/null)"
rc=$?
check "skip all -> empty"    ""  "$out"
check "skip all -> nonzero"  "1" "$rc"

# An explicit --rack bypasses ranking; the skip list must not be consulted, since
# add-rack has already refused an explicitly-named rack it holds.
check "explicit rack honoured" "GPU-q4mra-5athq-0" \
  "$(slurm_pick_verified_trays 1 q4mra/5athq "" 2>/dev/null | head -1)"

# ------------------------------------------------------------------ max sizing
# 'max' must size on what VERIFIES, not on what Slurm calls idle: a rack whose
# idle trays are unreachable would otherwise over-promise and then die mid-run.
check "verified count (all good)" "4" "$(slurm_rack_verified_count ez4wq/bi4ua)"

slurm_verify_trays() {         # only trays 0 and 2 are really reachable
  SLURM_VERIFY_BAD=()
  local t
  for t in "$@"; do
    case "$t" in *-0|*-2) printf '%s\n' "$t" ;; *) SLURM_VERIFY_BAD+=("${t}(=UNREACHABLE)") ;; esac
  done
}
check "verified count (2 bad)" "2" "$(slurm_rack_verified_count ez4wq/bi4ua)"

# And selection must return only verified trays, never pad with the bad ones.
check "picks only verified" "GPU-ez4wq-bi4ua-0 GPU-ez4wq-bi4ua-2" \
  "$(slurm_pick_verified_trays 2 ez4wq/bi4ua "" 2>/dev/null | paste -sd' ')"

# Asking for more than verify is a failure, not a short list.
out="$(slurm_pick_verified_trays 3 ez4wq/bi4ua "" 2>/dev/null)"; rc=$?
check "need > verified nonzero" "1" "$rc"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
