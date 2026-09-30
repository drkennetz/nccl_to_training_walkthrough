#!/usr/bin/env bash
# lib/drift.sh -- classify pre/post snapshot differences.
#
# Not everything k3s changes can be safely undone. Unloading the modules it
# loads is NOT safe: `modprobe -r` also drops newly-unused dependencies, so
# removing br_netfilter cascades to `bridge` and destroys the host's docker0.
# That was tried on a live node and it broke Docker.
#
# So we classify instead of pretending. A difference is BENIGN only if it is one
# of the narrow, enumerated consequences of loading those modules. Everything
# else is REAL drift and fails the check. The allowlist is deliberately specific:
# it matches exact module names and an empty table, not "modules.txt changed".

[[ -n "${_K8SBOOT_DRIFT:-}" ]] && return 0
_K8SBOOT_DRIFT=1

# Modules k3s loads that we accept being left behind. They autoload on demand
# and cost nothing; the risk of removing them exceeds the benefit.
# Exact module names we accept being left loaded.
DRIFT_BENIGN_MODULES=(br_netfilter bridge ip_tables ip6_tables nf_nat
                      veth vxlan geneve udp_tunnel ip6_udp_tunnel
                      cls_bpf sch_ingress sch_clsact
                      nf_socket_ipv4 nf_socket_ipv6
                      nf_tproxy_ipv4 nf_tproxy_ipv6
                      nf_defrag_ipv4 nf_defrag_ipv6
                      # Socket-diagnostics (sock_diag netlink) family. Any tool that
                      # inspects sockets autoloads a member: our own port checks run
                      # `ss -Hltn` (node/nodecheck.sh, node/snapshot.sh) which pulls
                      # inet_diag/tcp_diag, and `ss -x` pulls unix_diag. Measured:
                      # udp_diag was absent on 4 of 4 untouched trays and present on
                      # both trays we used, so we do cause it -- but tcp_diag and
                      # inet_diag were already loaded on 2 of those 4, so the family
                      # autoloads routinely and is not ours to police.
                      #
                      # unix_diag was added after a *read-only* `ss -xlp`, run while
                      # investigating the NRI socket, made a torn-down tray fail
                      # verify-clean as REAL drift. Diagnosing a node can therefore
                      # dirty it, which is precisely why the whole family belongs here.
                      # It is a fixed, enumerable kernel set (14 modules), so it is
                      # listed exactly rather than waved through by prefix.
                      inet_diag tcp_diag udp_diag unix_diag netlink_diag
                      af_packet_diag raw_diag sctp_diag dccp_diag mptcp_diag
                      smc_diag tipc_diag vsock_diag xsk_diag)

# Netfilter/iptables EXTENSION module prefixes.
#
# These are matches and targets that the kernel autoloads the moment a rule
# references them, so the exact set depends on which rules k3s and Cilium happen
# to install -- there are dozens, and enumerating them turned into whack-a-mole
# (xt_CT appeared only after xt_conntrack, xt_mark and friends were listed).
#
# A prefix is justified here and nowhere else: every member is an on-demand
# netfilter extension in the same unremovable class as br_netfilter. This is
# deliberately NOT a blanket pass for modules.txt -- anything outside these
# prefixes and the exact list above is still real drift, which the tests pin.
DRIFT_BENIGN_MODULE_PREFIXES=(xt_ ipt_ ip6t_ nft_ nfnetlink iptable_ ip6table_
                              nf_nat_ nf_conntrack_ nf_reject_ nf_log_)

# _drift_site_transient_port PORT -- is PORT in SITE_TRANSIENT_PORTS ("18001-18008 9999")?
_drift_site_transient_port() {
  local p=$1 r
  for r in ${SITE_TRANSIENT_PORTS:-}; do
    if [[ "$r" == *-* ]]; then (( p >= ${r%-*} && p <= ${r#*-} )) && return 0
    else [[ "$p" == "$r" ]] && return 0; fi
  done
  return 1
}

# drift_classify <pre-dir> <post-dir> <file>
#   prints "BENIGN <reason>" or "REAL <summary>"; returns 0 for benign, 1 for real.
drift_classify() {
  local pre="$1" post="$2" f="$3"
  local d; d="$(diff "${pre}/${f}" "${post}/${f}" 2>/dev/null)" || true
  [[ -z "$d" ]] && { printf 'BENIGN identical'; return 0; }

  # Lines added in post ('>') and removed from post ('<'), payload only.
  local added removed
  added="$(grep '^> ' <<<"$d" | sed 's/^> //')"
  removed="$(grep '^< ' <<<"$d" | sed 's/^< //')"

  case "$f" in
    modules.txt)
      # Nothing may DISAPPEAR -- that would mean we unloaded a host module.
      [[ -n "$removed" ]] && { printf 'REAL modules removed: %s' "$(tr '\n' ' ' <<<"$removed")"; return 1; }
      local m
      while read -r m; do
        [[ -n "$m" ]] || continue
        local okm=1 b pfx
        for b in "${DRIFT_BENIGN_MODULES[@]}"; do [[ "$m" == "$b" ]] && { okm=0; break; }; done
        if (( okm )); then
          for pfx in "${DRIFT_BENIGN_MODULE_PREFIXES[@]}"; do
            [[ "$m" == "${pfx}"* ]] && { okm=0; break; }
          done
        fi
        (( okm )) && { printf 'REAL unexpected module loaded: %s' "$m"; return 1; }
      done <<<"$added"
      printf 'BENIGN k3s loaded networking modules: %s' "$(tr '\n' ' ' <<<"$added")"; return 0 ;;

    iptables.txt|ip6tables.txt)
      # Only an EMPTY mangle table may appear -- it comes with the modules above.
      # Any actual rule, or any KUBE-/CNI-/cilium chain, is our leftovers.
      if grep -qE 'KUBE-|CNI-|cilium|^-A ' <<<"$added"; then
        printf 'REAL kubernetes/CNI firewall rules remain'; return 1
      fi
      [[ -n "$removed" ]] && { printf 'REAL host firewall rules were lost'; return 1; }
      local stripped
      stripped="$(grep -vE '^\*(mangle|filter|nat|raw|security)$|^:[A-Z]+ (ACCEPT|DROP)|^COMMIT$|^$' <<<"$added")"
      [[ -n "$stripped" ]] && { printf 'REAL unexpected firewall content: %s' "$(head -1 <<<"$stripped")"; return 1; }
      printf 'BENIGN empty table appeared with loaded modules'; return 0 ;;

    sysctl.txt)
      # bridge-nf-call-iptables exists only while br_netfilter is loaded, so
      # unset -> 1 is expected. Everything else must have been restored.
      local line
      while read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == "net.bridge.bridge-nf-call-iptables=1" ]] && continue
        printf 'REAL sysctl not restored: %s' "$line"; return 1
      done <<<"$added"
      printf 'BENIGN net.bridge key present while br_netfilter is loaded'; return 0 ;;

    paths.txt)
      # Compare per PATH, not per line. Two reasons:
      #  - adding a newly-tracked path to node/snapshot.sh would otherwise make
      #    every pre-existing baseline look drifted;
      #  - the direction matters. A path PRESENT now that was absent before is
      #    our leftover. A path absent now that the host had before means we
      #    deleted something that was not ours -- worse, and also caught here.
      local path state prestate poststate leftovers="" deleted=""
      while read -r path state; do
        [[ -n "$path" && "$state" == present ]] || continue
        prestate="$(awk -v p="$path" '$1==p{print $2}' "${pre}/paths.txt" 2>/dev/null)"
        [[ "$prestate" == present ]] || leftovers+="${path} "
      done < "${post}/paths.txt"
      while read -r path state; do
        [[ -n "$path" && "$state" == present ]] || continue
        poststate="$(awk -v p="$path" '$1==p{print $2}' "${post}/paths.txt" 2>/dev/null)"
        [[ "$poststate" == present ]] || deleted+="${path} "
      done < "${pre}/paths.txt"
      [[ -n "$deleted"   ]] && { printf 'REAL host paths were deleted: %s' "$deleted"; return 1; }
      [[ -n "$leftovers" ]] && { printf 'REAL paths left behind: %s' "$leftovers"; return 1; }
      printf 'BENIGN no path appeared or disappeared'; return 0 ;;

    bpf.txt)
      # Empty tc dirs are created by the kernel's tc-bpf machinery and are not
      # ours. Only a pinned cilium* object is a leftover.
      grep -q 'cilium' <<<"$added" && { printf 'REAL cilium eBPF pins remain'; return 1; }
      [[ -n "$removed" ]] && { printf 'REAL bpf pins disappeared: %s' "$(tr '\n' ' ' <<<"$removed")"; return 1; }
      printf 'BENIGN only empty tc directories differ'; return 0 ;;

    ports.txt)
      # One comma-separated line of listening TCP ports. A port WE left listening is a leftover;
      # a host port that disappeared means we stopped something that was not ours -- both real.
      # The one enumerated exception: SITE_TRANSIENT_PORTS, listeners the site's own checks open
      # and close on their own schedule (nearby-woodcock: the multi-node health check's
      # ib_write_bw servers on 18001-18008, one per rail VRF, present in pre AND post snapshots
      # of trays we never touched). Exact ports or a-b ranges; nothing else is exempt.
      local pre_ports post_ports p other=""
      pre_ports=",$(cat "${pre}/ports.txt" 2>/dev/null),"; post_ports=",$(cat "${post}/ports.txt" 2>/dev/null),"
      for p in $(tr ',' ' ' <<<"${pre_ports//,/ } ${post_ports//,/ }" | tr ' ' '\n' | sort -un); do
        [[ "$pre_ports" == *",$p,"* && "$post_ports" == *",$p,"* ]] && continue
        _drift_site_transient_port "$p" && continue
        other+="$p "
      done
      [[ -n "$other" ]] && { printf 'REAL listening ports changed: %s' "$other"; return 1; }
      printf 'BENIGN only site-transient ports differ'; return 0 ;;

    mounts.txt)
      # snapd refreshes snaps on its own schedule and mounts the new revision under
      # /snap/<name>/<rev> (squashfs); a refresh between our pre and post snapshots is the
      # host's business, not our leftover. Anything else that appeared or vanished is real.
      #
      # Slurm job_container/tmpfs (job_container.conf BasePath, e.g. nearby-woodcock's
      # /mnt/localdisk/slurm-tmp) mounts <base>/<jobid> plus its <base>/<jobid>/.ns
      # namespace handle for EVERY running job -- the site's own health checks, or our
      # lease if a snapshot overlaps it. Slurm creates and removes them; they are not
      # ours. Matched exactly: numeric job id, and only the fstypes Slurm uses.
      local ml other="" base="${SLURM_JOB_CONTAINER_BASE:-}"
      while read -r ml; do
        [[ -n "$ml" ]] || continue
        [[ "$ml" =~ ^/snap/[^[:space:]]+[[:space:]]+squashfs$ ]] && continue
        if [[ -n "$base" && "$ml" =~ ^${base}/[0-9]+(/\.ns)?[[:space:]]+(xfs|nsfs|tmpfs)$ ]]; then continue; fi
        other+="${ml}; "
      done < <(printf '%s\n%s\n' "$added" "$removed")
      [[ -n "$other" ]] && { printf 'REAL mounts.txt changed: %s' "$other"; return 1; }
      printf 'BENIGN snap refresh or Slurm per-job tmpfs'; return 0 ;;

    *)
      printf 'REAL %s changed' "$f"; return 1 ;;
  esac
}
