#!/usr/bin/env bash
# tests/test-node-topology.sh -- unit tests for the two NODE_TOPOLOGY schemes.
#
#   name (default) -- GB300 NVL72, GPU-<localblock>-<rack>-<tray>
#   flat           -- HGX B300, GPU-<n>, one configured pseudo-rack (FLAT_RACKID)
#
# The property that matters most is isolation: on nearby-woodcock the `compute`
# partition holds both B300 (GPU-387) and GB200 (GPU-4f035fce-0) nodes, so each
# scheme must see ONLY its own nodes. A GB200 tray leaking into a B300 lease (or
# the reverse) would put k3s on hardware the cluster env was never surveyed for.
#
# sinfo is stubbed: hermetic and instant (see CLAUDE.md on un-stubbed sinfo).
#
# Run: tests/test-node-topology.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib/slurm.sh
. lib/slurm.sh
set +e

pass=0; fail=0
check() {                      # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then printf '  ok    %-34s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %-34s wanted [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# Mixed partition: B300 idle/alloc/down; polite-possum-style GB300 trays; and a
# nearby-woodcock GB200 tray (GPU-<rack>-<tray>, three fields) that NEITHER scheme
# may pick up; a duplicate row as sinfo prints one per partition.
sinfo() {
  cat <<'INV'
GPU-872|idle
GPU-387|idle
GPU-1258|idle
GPU-673|alloc
GPU-86|idle*
GPU-387|idle
GPU-4f035fce-3|idle
GPU-ez4wq-bi4ua-12|idle
GPU-ez4wq-bi4ua-3|idle
GPU-ez4wq-bi4ua-0|idle
GPU-ez4wq-56l4q-1|drain
INV
}

# ------------------------------------------------------------ name (GB300, default)
unset NODE_TOPOLOGY FLAT_RACKID FLAT_NODE_RE
EXCLUDE_LOCALBLOCKS=""

check "name: 3-field GB200 invalid" "1"         "$(slurm_node_valid GPU-4f035fce-3; echo $?)"
check "name: parses GB300 name"  "ez4wq/2nyvq"  "$(slurm_node_rackid GPU-ez4wq-2nyvq-7)"
check "name: tray"               "7"            "$(slurm_node_tray GPU-ez4wq-2nyvq-7)"
check "name: B300 name invalid"  "1"            "$(slurm_node_valid GPU-387; echo $?)"
check "name: idle sees only GB300" \
  "GPU-ez4wq-bi4ua-0 GPU-ez4wq-bi4ua-12 GPU-ez4wq-bi4ua-3" \
  "$(slurm_idle_nodes | sort | paste -sd' ')"
check "name: rack trays tray-sorted" \
  "GPU-ez4wq-bi4ua-0 GPU-ez4wq-bi4ua-3 GPU-ez4wq-bi4ua-12" \
  "$(slurm_rack_idle_trays ez4wq/bi4ua | paste -sd' ')"
check "name: rackid_valid"       "0"            "$(slurm_rackid_valid ez4wq/bi4ua; echo $?)"
check "name: label env"          "NODE_LOCALBLOCK='ez4wq' NODE_RACK='bi4ua' NODE_TRAY='2' " \
                                 "$(slurm_node_label_env GPU-ez4wq-bi4ua-2)"

# ------------------------------------------------------------ flat (HGX B300)
NODE_TOPOLOGY=flat
FLAT_NODE_RE='^GPU-([0-9]+)$'
FLAT_RACKID="w4gj2e2a/wrdz7b4q"

check "flat: B300 name valid"    "0"            "$(slurm_node_valid GPU-387; echo $?)"
check "flat: GB200 name invalid" "1"            "$(slurm_node_valid GPU-4f035fce-3; echo $?)"
check "flat: GB300 name invalid" "1"            "$(slurm_node_valid GPU-ez4wq-bi4ua-3; echo $?)"
check "flat: rackid"             "w4gj2e2a/wrdz7b4q" "$(slurm_node_rackid GPU-387)"
check "flat: tray"               "1258"         "$(slurm_node_tray GPU-1258)"
check "flat: GB200 has no rackid" "1"           "$(slurm_node_rackid GPU-4f035fce-3 >/dev/null; echo $?)"
# idle only: alloc and idle* (not responding) excluded; duplicate rows collapsed.
check "flat: idle sees only B300" \
  "GPU-1258 GPU-387 GPU-872" \
  "$(slurm_idle_nodes | sort | paste -sd' ')"
# Numeric, not lexical: 387 < 872 < 1258.
check "flat: trays sorted numerically" \
  "GPU-387 GPU-872 GPU-1258" \
  "$(slurm_rack_idle_trays w4gj2e2a/wrdz7b4q | paste -sd' ')"
check "flat: one pseudo-rack"    "3 w4gj2e2a/wrdz7b4q" "$(slurm_racks_by_capacity)"
check "flat: rank needs fit"     "w4gj2e2a/wrdz7b4q"   "$(slurm_rank_racks 3)"
check "flat: rank too big fails" "1"            "$(slurm_rank_racks 4 >/dev/null; echo $?)"
check "flat: pick_trays"         "GPU-387 GPU-872"     "$(slurm_pick_trays 2 | paste -sd' ')"
check "flat: rackid_valid ok"    "0"            "$(slurm_rackid_valid w4gj2e2a/wrdz7b4q; echo $?)"
check "flat: rackid_valid other" "1"            "$(slurm_rackid_valid ez4wq/bi4ua; echo $?)"
check "flat: label env"          "NODE_LOCALBLOCK='w4gj2e2a' NODE_RACK='wrdz7b4q' NODE_TRAY='387' " \
                                 "$(slurm_node_label_env GPU-387)"
# Lease name must round-trip through slurm_list_rack_leases' first-dash split.
check "flat: lease name"         "rack-w4gj2e2a-wrdz7b4q" "$(slurm_lease_name_for_rack w4gj2e2a/wrdz7b4q)"

# Misconfigured flat mode refuses rather than guessing a rack.
check "flat: no FLAT_RACKID dies" "1" \
  "$( (FLAT_RACKID=""; slurm_node_valid GPU-387) >/dev/null 2>&1; echo $?)"

# ------------------------------------------------------------ flat + topology membership
# A node can match the name, answer ssh, pass preflight -- and be absent from Slurm's topology,
# which makes a multi-node lease that includes it fail (GPU-2571 on nearby-woodcock).
TOPO="$(mktemp)"; trap 'rm -f "$TOPO"' EXIT
cat > "$TOPO" <<'YAML'
- topology: tree
  tree:
    switches:
      - switch: 'rail::c:blk:good'
        nodes: 'GPU-387,GPU-1258'
      - switch: 'rail::c:blk:other'
        nodes: 'GPU-872'
YAML
FLAT_TOPOLOGY_FILE="$TOPO"; FLAT_TOPOLOGY_SWITCH='rail::c:blk:good'; _K8SBOOT_FLAT_MEMBERS=""
check "topo: member valid"        "0" "$(slurm_node_valid GPU-387; echo $?)"
check "topo: other switch invalid" "1" "$(slurm_node_valid GPU-872; echo $?)"
check "topo: absent node invalid" "1" "$(slurm_node_valid GPU-2571; echo $?)"
check "topo: idle filtered"       "GPU-1258 GPU-387" "$(slurm_idle_nodes | sort | paste -sd' ')"
_K8SBOOT_FLAT_MEMBERS=""; FLAT_TOPOLOGY_SWITCH='rail::c:blk:nope'
check "topo: unknown switch dies" "1" "$( (slurm_idle_nodes) >/dev/null 2>&1; echo $?)"
_K8SBOOT_FLAT_MEMBERS=""; FLAT_TOPOLOGY_SWITCH='rail::c:blk:good'; FLAT_TOPOLOGY_FILE=/nonexistent
check "topo: missing file dies"   "1" "$( (slurm_idle_nodes) >/dev/null 2>&1; echo $?)"
unset FLAT_TOPOLOGY_SWITCH FLAT_TOPOLOGY_FILE; _K8SBOOT_FLAT_MEMBERS=""
check "topo: unset = no filter"   "0" "$(slurm_node_valid GPU-2571; echo $?)"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
