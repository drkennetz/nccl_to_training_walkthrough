#!/usr/bin/env bash
# tests/test-rack-ranking.sh -- unit tests for slurm_rank_racks().
#
# Ordering matters more than it looks. Tightest-fit ranking deliberately favours
# racks with just enough idle trays so that large contiguous blocks stay intact
# for other users' big jobs. The side effect is that the first candidate is often
# a mostly-down rack whose surviving nodes are unreachable -- observed live, where
# a rack reporting 2 idle trays had 0 reachable while five other racks had 14-17.
#
# So this file pins two properties:
#   1. preference order is PREFER_LOCALBLOCKS first, then tightest fit;
#   2. EVERY viable rack is emitted, so the caller can fall through.
#
# Run: tests/test-rack-ranking.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib/slurm.sh
. lib/slurm.sh
# lib/common.sh (sourced transitively) sets -e; these tests deliberately exercise
# failure paths, so turn it back off.
set +e

pass=0; fail=0
check() {                      # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then printf '  ok    %-26s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %-26s wanted [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# Stub the cluster inventory so the test is deterministic and offline.
slurm_racks_by_capacity() {
  cat <<'INV'
17 ez4wq/iia5a
16 ez4wq/56l4q
14 ez4wq/bi4ua
4 q4mra/5athq
2 gz7lq/f265q
2 tboia/ssh2a
1 3asma/lhxlq
INV
}
PREFER_LOCALBLOCKS="233qa edaya a6tiq gz7lq tboia ez4wq q4mra 3asma"

# gz7lq and tboia come first in PREFER order; within ez4wq, tightest fit first.
check "need=2 full order" \
  "gz7lq/f265q tboia/ssh2a ez4wq/bi4ua ez4wq/56l4q ez4wq/iia5a q4mra/5athq" \
  "$(slurm_rank_racks 2 | paste -sd' ')"

# Racks that cannot hold the request are excluded entirely.
check "need=14 excludes small" \
  "ez4wq/bi4ua ez4wq/56l4q ez4wq/iia5a" \
  "$(slurm_rank_racks 14 | paste -sd' ')"

check "need=17 only the largest" \
  "ez4wq/iia5a" \
  "$(slurm_rank_racks 17 | paste -sd' ')"

# Nothing can hold 18 -> no output, nonzero.
out="$(slurm_rank_racks 18 2>/dev/null)"; rc=$?
check "need=18 impossible"       ""    "$out"
check "need=18 returns nonzero"  "1"   "$rc"

# Localblocks absent from PREFER_LOCALBLOCKS must still be offered, after the
# preferred ones, and tightest-first among themselves.
PREFER_LOCALBLOCKS="gz7lq"
check "unlisted blocks come last" \
  "gz7lq/f265q tboia/ssh2a q4mra/5athq ez4wq/bi4ua ez4wq/56l4q ez4wq/iia5a" \
  "$(slurm_rank_racks 2 | paste -sd' ')"

# The property that actually matters: more than one candidate, so a bad first
# rack can be skipped.
PREFER_LOCALBLOCKS="233qa edaya a6tiq gz7lq tboia ez4wq q4mra 3asma"
n="$(slurm_rank_racks 2 | grep -c .)"
check "fallback possible (>1 cand)" "yes" "$([ "$n" -gt 1 ] && echo yes || echo no)"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
