#!/usr/bin/env bash
# lib/preflight.sh -- controller-side orchestration of node checks and snapshots.
#
# Fans out node/nodecheck.sh and node/snapshot.sh across candidate trays, then
# aggregates. The node scripts live on NFS and run in place; nothing is copied.

[[ -n "${_K8SBOOT_PREFLIGHT:-}" ]] && return 0
_K8SBOOT_PREFLIGHT=1

# shellcheck source=./slurm.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/slurm.sh"

# Snapshot fields that legitimately change between two reads of an idle node.
# Everything else must match exactly or we treat it as drift.
PREFLIGHT_DIFF_EXCLUDES=(--exclude=meta --exclude='*.raw' --exclude=nvidia-smi.txt
                         --exclude=phase --exclude=disk.txt --exclude=host-cdi.yaml)

# Environment handed to the on-node scripts, derived from the cluster config.
_node_env() {
  printf '%s' \
    "GPUS_PER_NODE='${GPUS_PER_NODE:-4}' " \
    "EXPECTED_ARCH='${EXPECTED_ARCH:-aarch64}' " \
    "IMEX_PATH='${IMEX_PATH:-A}' " \
    "EXPECTED_NVIDIA_DRIVER_MIN='${EXPECTED_NVIDIA_DRIVER_MIN:-580}' " \
    "NODE_LOCAL_DISK='${NODE_LOCAL_DISK:-/mnt/localdisk}' " \
    "MIN_LOCALDISK_GB='${MIN_LOCALDISK_GB:-200}' " \
    "NODE_INSTALL_DIR='${NODE_INSTALL_DIR:-/opt/k8s-bootstrap}' " \
    "SHARED_FS='${SHARED_FS:-/fss}' " \
    "IMEX_CHANNEL_DEV='${IMEX_CHANNEL_DEV:-/dev/nvidia-caps-imex-channels/channel0}' " \
    "HOST_CDI_SPEC='${HOST_CDI_SPEC:-/var/run/cdi/nvidia.yaml}' "
}

# preflight_node <node> -> raw "STATUS|check|detail" lines; exit 1 if any FAIL
preflight_node() {
  local node="$1"
  node_ssh_ro "$node" "$(_node_env) EXPECTED_NODE_NAME='${node}' bash ${REPO_ROOT}/node/nodecheck.sh"
}

# assert_node_identity <node> -- confirm the machine reachable at this name really
# is this node. Cheap, and the last line of defence for code paths that run
# without a full preflight (teardown, add-rack). See the identity check in
# node/nodecheck.sh for why this is not paranoia.
assert_node_identity() {
  local node="$1" actual
  actual="$(node_ssh_ro "$node" hostname 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$actual" ]] || { err "${node}: unreachable; cannot confirm identity"; return 1; }
  if [[ "${actual,,}" != "${node,,}" ]]; then
    err "${node}: IDENTITY MISMATCH -- that address is actually '${actual}'"
    err "  Slurm/DNS mapping is stale. Refusing to touch a host that is not ours."
    return 1
  fi
  dbg "${node}: identity confirmed"
  return 0
}

# assert_nodes_identity <nodelist> -- all or nothing.
assert_nodes_identity() {
  local bad=0 n
  for n in $(nodes_expand "$1"); do assert_node_identity "$n" || bad=1; done
  (( bad == 0 )) || { err "identity check failed -- aborting"; return 1; }
  return 0
}

# preflight_nodes <nodelist> -- check every tray, print a table, fail if any node fails.
preflight_nodes() {
  local nodelist="$1"
  local -a nodes=(); mapfile -t nodes < <(nodes_expand "$nodelist")
  ((${#nodes[@]})) || die "preflight: no nodes given"

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  log "preflight on ${#nodes[@]} tray(s): $(nodes_compress "${nodes[@]}")"

  # Run in parallel; each node's output and exit code land in the temp dir.
  local n
  for n in "${nodes[@]}"; do
    { preflight_node "$n" >"${tmp}/${n}.out" 2>"${tmp}/${n}.err"; \
      printf '%s' "$?" >"${tmp}/${n}.rc"; } &
  done
  wait

  local failed=0 warned=0
  for n in "${nodes[@]}"; do
    local rc; rc="$(cat "${tmp}/${n}.rc" 2>/dev/null || echo 99)"
    if [[ ! -s "${tmp}/${n}.out" ]]; then
      err "${n}: preflight produced no output (unreachable?)"
      sed 's/^/      /' "${tmp}/${n}.err" >&2 2>/dev/null | head -3
      failed=$((failed+1)); continue
    fi

    local nfail nwarn
    nfail="$(grep -c '^FAIL|' "${tmp}/${n}.out" || true)"
    nwarn="$(grep -c '^WARN|' "${tmp}/${n}.out" || true)"

    if (( nfail > 0 )); then
      err "${n}: ${nfail} blocking problem(s)"
      grep '^FAIL|' "${tmp}/${n}.out" | awk -F'|' '{printf "      %-18s %s\n", $2, $3}' >&2
      failed=$((failed+1))
    elif (( nwarn > 0 )); then
      warn "${n}: ok with ${nwarn} warning(s)"
      grep '^WARN|' "${tmp}/${n}.out" | awk -F'|' '{printf "      %-18s %s\n", $2, $3}' >&2
      warned=$((warned+1))
    else
      ok "${n}: all checks passed"
    fi

    [[ "$VERBOSE" == 1 ]] && grep -E '^(PASS|INFO)\|' "${tmp}/${n}.out" \
      | awk -F'|' '{printf "      %-18s %s\n", $2, $3}' >&2

    # Keep the raw report alongside the snapshots for later reference.
    mkdir -p "${STATE_DIR}/snapshots/preflight"
    cp "${tmp}/${n}.out" "${STATE_DIR}/snapshots/preflight/${n}.txt" 2>/dev/null || :
    [[ "$rc" == 0 || "$rc" == 1 ]] || warn "${n}: nodecheck exited ${rc}"
  done

  if (( failed > 0 )); then
    err "preflight FAILED on ${failed}/${#nodes[@]} tray(s) -- refusing to install"
    printf '%s\n' "  These gates protect the node, not us. Do not override them; pick other trays." >&2
    return 1
  fi
  ok "preflight passed on all ${#nodes[@]} tray(s)$( ((warned)) && printf ' (%s with warnings)' "$warned")"
  return 0
}

# snapshot_nodes <nodelist> <phase>  (phase: pre|post)
# Snapshots land on NFS at $STATE_DIR/snapshots/<phase>/<node>/.
snapshot_nodes() {
  local nodelist="$1" phase="${2:-pre}"
  local -a nodes=(); mapfile -t nodes < <(nodes_expand "$nodelist")
  ((${#nodes[@]})) || die "snapshot: no nodes given"

  # A 'pre' baseline is what k8s-verify-clean later treats as "a node we touched".
  # Writing one from a dry run made verify-clean audit 31 trays that were never leased
  # (and flag other people's jobs on them as drift). Dry runs describe; they do not record.
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    printf '%s\n' "dry-run: would capture '${phase}' snapshot of ${#nodes[@]} tray(s) under ${STATE_DIR}/snapshots/${phase}/" >&2
    return 0
  fi

  log "capturing '${phase}' snapshot of ${#nodes[@]} tray(s)"
  local n outdir
  for n in "${nodes[@]}"; do
    outdir="${STATE_DIR}/snapshots/${phase}/${n}"
    # Create it HERE, not on the node. /home is NFS and the controller caches
    # negative lookups: if we stat this path before the node creates it, the
    # controller keeps reporting ENOENT long after the files exist.
    mkdir -p "$outdir"
    {
      if node_ssh_ro "$n" \
           "$(_node_env) bash ${REPO_ROOT}/node/snapshot.sh --outdir '${outdir}' --phase '${phase}'" \
           >/dev/null 2>&1; then
        printf 'ok\n' > "${outdir}/.captured"
      else
        printf 'failed\n' > "${outdir}/.captured"
      fi
    } &
  done
  wait

  local bad=0
  for n in "${nodes[@]}"; do
    if [[ "$(cat "${STATE_DIR}/snapshots/${phase}/${n}/.captured" 2>/dev/null)" == ok ]]; then
      dbg "  ${n}: snapshot ok"
    else
      err "  ${n}: snapshot FAILED"; bad=$((bad+1))
    fi
  done
  (( bad == 0 )) || { err "snapshot failed on ${bad} tray(s)"; return 1; }
  ok "'${phase}' snapshot captured for all ${#nodes[@]} tray(s)"
}

# snapshot_diff_node <node> -- compare pre vs post. 0 = pristine, 1 = drift.
snapshot_diff_node() {
  local node="$1"
  local pre="${STATE_DIR}/snapshots/pre/${node}"
  local post="${STATE_DIR}/snapshots/post/${node}"
  [[ -d "$pre"  ]] || { err "${node}: no 'pre' snapshot -- cannot prove cleanliness"; return 1; }
  [[ -d "$post" ]] || { err "${node}: no 'post' snapshot"; return 1; }
  diff -r "${PREFLIGHT_DIFF_EXCLUDES[@]}" "$pre" "$post"
}

# ------------------------------------------------------------------ verified selection
# Node identity is checked in PARALLEL across a rack's idle trays, and trays whose
# hostname does not match their Slurm name are skipped rather than failing the run.
# On dynamic/cloud clusters a meaningful fraction of node records can be stale.
#
# slurm_pick_verified_trays <n> [localblock/rack] -> n identity-verified node names
#
# Walks candidate racks in preference order and returns the first rack that can
# supply `n` trays whose hostname matches their Slurm name. Falling through to the
# next rack is essential, not a nicety: tightest-fit ranking deliberately favours
# racks with just enough idle trays, and such a rack is frequently one where most
# nodes are down and the survivors are unreachable. Observed live -- gz7lq/f265q
# reported 2 idle trays and both were UNREACHABLE, while five other racks had
# 14-17 healthy trays each.
# slurm_verify_trays <tray>... -> the subset whose hostname matches its Slurm name.
#
# Extracted so that selection and "how many trays can this rack actually give me"
# share ONE implementation of the identity check. Rule 1 exists because a Slurm
# name can reach the wrong machine, and two copies of this logic would be two
# chances to get it wrong.
#
# `|| true` on both the ssh and the read-back is load-bearing, not defensive
# noise. lib/common.sh sets -e, so a bare assignment from a failing command
# aborts the enclosing function. Without it, an unreachable node made the ssh
# fail, the background subshell died BEFORE its printf, the file was never
# written, and the later `cat` then killed the caller outright -- so selection
# silently produced nothing instead of skipping that rack. That looked exactly
# like "transient node trouble" for a while.
#
# Sets SLURM_VERIFY_BAD to the rejected trays, annotated with what they really
# are, for callers that want to report them.
SLURM_VERIFY_BAD=()
slurm_verify_trays() {
  local -a pool=("$@")
  SLURM_VERIFY_BAD=()
  ((${#pool[@]})) || return 0

  local tmp; tmp="$(mktemp -d)"
  local t
  for t in "${pool[@]}"; do
    { local h; h="$(node_ssh_ro "$t" hostname 2>/dev/null | tr -d '\r' || true)"
      printf '%s' "${h:-UNREACHABLE}" > "${tmp}/${t}" || true; } &
  done
  wait

  local -a good=()
  for t in "${pool[@]}"; do
    local h; h="$(cat "${tmp}/${t}" 2>/dev/null || true)"
    if [[ "${h,,}" == "${t,,}" ]]; then good+=("$t"); else SLURM_VERIFY_BAD+=("${t}(=${h:-?})"); fi
  done
  rm -rf "$tmp"
  ((${#good[@]})) && printf '%s\n' "${good[@]}"
  return 0
}

# slurm_rack_verified_count <localblock/rack> -> how many trays it could really give.
# Used by `--trays max`, which must not over-promise on a rack whose idle trays
# are mostly unreachable.
slurm_rack_verified_count() {
  local -a pool=(); mapfile -t pool < <(slurm_rack_idle_trays "$1")
  ((${#pool[@]})) || { printf '0'; return 0; }
  local -a good=(); mapfile -t good < <(slurm_verify_trays "${pool[@]}")
  printf '%s' "${#good[@]}"
}

slurm_pick_verified_trays() {
  local need="${1:-1}" want_rack="${2:-}" skip_racks="${3:-}"
  local -a candidates=()
  if [[ -n "$want_rack" ]]; then
    candidates=("$want_rack")
  else
    mapfile -t candidates < <(slurm_rank_racks "$need")
    ((${#candidates[@]})) \
      || die "no rack has ${need} responsive idle trays (excluding: ${EXCLUDE_LOCALBLOCKS:-none})"
  fi

  # Racks we already hold a lease for. Slurm cannot add nodes to a running job,
  # and lease names map 1:1 to racks, so a second lease for the same rack would
  # collide -- bin/k8s-add-rack passes those racks here to skip them.
  if [[ -n "$skip_racks" ]]; then
    local -a keep=(); local c
    for c in "${candidates[@]}"; do
      [[ " ${skip_racks} " == *" ${c} "* ]] && { dbg "skipping already-leased rack ${c}"; continue; }
      keep+=("$c")
    done
    candidates=(${keep[@]+"${keep[@]}"})
    ((${#candidates[@]})) \
      || die "every rack that could supply ${need} tray(s) is already leased by us (${skip_racks}); free one with bin/k8s-remove-rack"
  fi

  local rack tried=0 summary=""
  for rack in "${candidates[@]}"; do
    [[ -n "$rack" ]] || continue
    local -a pool=(); mapfile -t pool < <(slurm_rack_idle_trays "$rack")
    (( ${#pool[@]} >= need )) || continue
    tried=$((tried+1))

    local -a good=(); mapfile -t good < <(slurm_verify_trays "${pool[@]}")
    local -a bad=(${SLURM_VERIFY_BAD[@]+"${SLURM_VERIFY_BAD[@]}"})

    if (( ${#good[@]} >= need )); then
      (( ${#bad[@]} )) && warn "rack ${rack}: skipped ${#bad[@]} unusable tray(s): ${bad[*]}"
      dbg "rack ${rack}: ${#good[@]}/${#pool[@]} trays verified"
      printf '%s\n' "${good[@]:0:need}"
      return 0
    fi

    warn "rack ${rack}: only ${#good[@]}/${#pool[@]} tray(s) verifiable; trying the next rack"
    summary+="${rack}(${#good[@]}/${#pool[@]}) "
  done

  # Nothing worked. Released trays linger in Slurm 'comp' before returning to
  # 'idle', which is the usual cause right after a teardown.
  local completing
  completing="$(sinfo -h -N -p "${SLURM_PARTITION:-compute}" -o '%N|%t' 2>/dev/null \
                 | sort -u | awk -F'|' '$2 ~ /^comp/ {c++} END{print c+0}')"
  (( completing > 0 )) && warn "${completing} tray(s) cluster-wide are still COMPLETING; wait ~60s and retry"
  (( tried > 0 )) && err "tried ${tried} rack(s): ${summary}"
  die "no rack could supply ${need} identity-verified idle tray(s)"
}
