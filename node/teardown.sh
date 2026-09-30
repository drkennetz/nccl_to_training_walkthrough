#!/usr/bin/env bash
# node/teardown.sh -- remove everything we installed. RUNS ON A LEASED NODE.
#
# This is the most important script in the repo. The nodes are borrowed from a
# shared cluster; if this is incomplete, someone else inherits our mess.
#
# Called three ways:
#   - bin/k8s-down            (normal, orderly)
#   - slurm/lease.sbatch trap (scancel or walltime expiry)
#   - by hand, to clean a node left dirty by a SIGKILLed lease
#
# Idempotent and safe to re-run. Deliberately does NOT use `set -e`: one failing
# step must not abort the rest of the cleanup.
#
# usage: node/teardown.sh [--role auto|server|agent] [--baseline DIR] [--keep-data]
#
# --baseline points at this node's 'pre' snapshot. Without it, kernel modules and
# sysctls that k3s changed cannot be restored, and the node will show benign but
# real drift. bin/k8s-down always passes it.

set -uo pipefail

ROLE="auto"; KEEP_DATA=0; BASELINE_DIR=""
while (($#)); do
  case "$1" in
    --role)      ROLE="${2:?}"; shift 2 ;;
    --baseline)  BASELINE_DIR="${2:?}"; shift 2 ;;
    --keep-data) KEEP_DATA=1; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

NODE_INSTALL_DIR="${NODE_INSTALL_DIR:-/opt/k8s-bootstrap}"
K3S_DATA_DIR="${K3S_DATA_DIR:-/mnt/localdisk/k3s}"
NODE_LOCAL_DISK="${NODE_LOCAL_DISK:-/mnt/localdisk}"
HOST_CDI_SPEC="${HOST_CDI_SPEC:-/var/run/cdi/nvidia.yaml}"

log()  { printf '[teardown] %s\n' "$*"; }
warn() { printf '[teardown] WARN: %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || exec sudo -E bash "$0" "$@"

log "starting on $(hostname) (role=${ROLE})"

# ---------------------------------------------------------------- 1. detect
have_server=0; have_agent=0
[[ -x "${NODE_INSTALL_DIR}/bin/k3s-uninstall.sh"       ]] && have_server=1
[[ -x "${NODE_INSTALL_DIR}/bin/k3s-agent-uninstall.sh" ]] && have_agent=1
# Legacy/default location, in case something was installed without our overrides.
[[ -x /usr/local/bin/k3s-uninstall.sh       ]] && have_server=1
[[ -x /usr/local/bin/k3s-agent-uninstall.sh ]] && have_agent=1

if (( ! have_server && ! have_agent )); then
  k3s_units="$(systemctl list-units --all --plain --no-legend 'k3s*' 2>/dev/null || true)"
  if grep -q k3s <<<"$k3s_units"; then
    warn "k3s units present but no generated uninstaller; falling back to manual removal"
  else
    log "nothing installed by us; proceeding with residual cleanup anyway"
  fi
fi

# ---------------------------------------------------------------- 2. k3s uninstall
# The generated uninstaller is the supported path: it kills only shims under
# k3s's own data dir (so other users' containers are untouched), unmounts
# /run/k3s and the kubelet trees, and strips KUBE-/CNI-/flannel iptables rules
# while preserving the host's.
ran_uninstall=0
for u in "${NODE_INSTALL_DIR}/bin/k3s-agent-uninstall.sh" \
         /usr/local/bin/k3s-agent-uninstall.sh \
         "${NODE_INSTALL_DIR}/bin/k3s-uninstall.sh" \
         /usr/local/bin/k3s-uninstall.sh; do
  [[ -x "$u" ]] || continue
  log "running $u"
  if timeout 240 "$u" >/dev/null 2>&1; then ran_uninstall=1; log "  ok"
  else warn "  $u exited nonzero; continuing"; fi
done

# ---------------------------------------------------------------- 3. manual fallback
if (( ! ran_uninstall )); then
  for svc in k3s k3s-agent; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      log "stopping ${svc}"
      systemctl disable --now "${svc}" >/dev/null 2>&1 || :
      rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}.service.env"
    fi
  done
  # Kill only shims under OUR data dir. A broad `pkill containerd-shim` would
  # take out other users' enroot/docker containers on this shared node.
  for pid in $(ps -eo pid=,args= | grep -F "${K3S_DATA_DIR}/data/" \
                 | grep -F containerd-shim | awk '{print $1}'); do
    log "killing stray shim ${pid}"; kill -9 "$pid" 2>/dev/null || :
  done
  # Unmount in reverse depth order so children go before parents.
  awk '{print $2}' /proc/self/mounts \
    | grep -E "^(/run/k3s|${K3S_DATA_DIR}|/var/lib/kubelet)" \
    | sort -r | while read -r m; do log "unmounting $m"; umount -f "$m" 2>/dev/null || :; done
  systemctl daemon-reload 2>/dev/null || :
fi

# ---------------------------------------------------------------- 4. CNI leftovers
# k3s's killall only knows about flannel/cni0. With Cilium there is more, and
# none of it is removed by the generated uninstaller.
for i in cilium_host cilium_net cilium_vxlan cilium_geneve cni0 flannel.1 \
         flannel-v6.1 kube-ipvs0 nodelocaldns; do
  if ip link show "$i" >/dev/null 2>&1; then
    log "deleting interface $i"; ip link delete "$i" 2>/dev/null || :
  fi
done
# Any lingering veth halves whose peer was a pod netns.
ip -o link show type veth 2>/dev/null | awk -F': ' '/lxc|cilium|veth/{print $2}' \
  | sed 's/@.*//' | while read -r v; do
      [[ -n "$v" ]] && { log "deleting veth $v"; ip link delete "$v" 2>/dev/null || :; }
    done

# k3s's killall strips KUBE-, CNI- and flannel rules but knows nothing about
# Cilium's CILIUM_* chains, which survive the DaemonSet being deleted. Same
# technique k3s uses: filter them out and restore, leaving host rules intact.
#
# Capture first, then grep. `iptables-save | grep -q` under pipefail is a race: grep -q
# exits on the first match, iptables-save takes SIGPIPE, the pipeline "fails", and the
# strip is skipped. Observed live on nearby-woodcock GPU-387 (37 CILIUM_* rules left on
# the control plane while the worker happened to win the race).
ipt4="$(iptables-save 2>/dev/null || true)"
ipt6="$(ip6tables-save 2>/dev/null || true)"
if grep -qi cilium <<<"$ipt4"; then
  log "removing residual CILIUM_* iptables chains"
  iptables-save 2>/dev/null | grep -vi cilium | iptables-restore 2>/dev/null \
    || warn "could not rewrite iptables without cilium rules"
fi
if grep -qi cilium <<<"$ipt6"; then
  log "removing residual CILIUM_* ip6tables chains"
  ip6tables-save 2>/dev/null | grep -vi cilium | ip6tables-restore 2>/dev/null \
    || warn "could not rewrite ip6tables without cilium rules"
fi

# Cilium pins eBPF programs and maps here; they survive process death.
if [[ -d /sys/fs/bpf/tc/globals ]]; then
  for m in /sys/fs/bpf/tc/globals/cilium_*; do
    [[ -e "$m" ]] && { log "removing bpf map $(basename "$m")"; rm -f "$m" 2>/dev/null || :; }
  done
fi
rm -rf /sys/fs/bpf/cilium* 2>/dev/null || :

# ---------------------------------------------------------------- 5. filesystem
# /opt/cni is containerd's default CNI bin dir and did not exist before us --
# Cilium installs its plugin there. /etc/cni likewise appears only once a CNI
# (or containerd's default) creates it.
paths=(/var/lib/cni /etc/cni /opt/cni /var/lib/kubelet /var/lib/rancher /etc/rancher
       /run/k3s /run/flannel /run/cilium /var/lib/cilium /etc/cilium
       "${NODE_INSTALL_DIR}")
(( KEEP_DATA )) || paths+=("${K3S_DATA_DIR}" "${NODE_LOCAL_DISK}/local-path")
# Refuse to act on a path that is not plausibly ours. This script runs as root on
# a borrowed node and unmounts by PREFIX MATCH, so an empty or truncated variable
# (K3S_DATA_DIR="", NODE_LOCAL_DISK unset) could otherwise expand to "/" or "/mnt"
# and unmount or delete far more than intended. Cheap insurance on a shared machine.
_path_is_safe() {
  local p="$1"
  [[ -n "$p" ]] || { warn "refusing empty path"; return 1; }
  [[ "$p" == /* ]] || { warn "refusing relative path: $p"; return 1; }
  # Must be at least two levels deep, e.g. /run/k3s, never /run.
  [[ "$p" =~ ^/[^/]+/.+ ]] || { warn "refusing shallow path: $p"; return 1; }
  case "$p" in
    /|/bin*|/boot*|/dev*|/etc|/etc/|/home*|/lib*|/mnt|/mnt/|/opt|/opt/|/proc*|/root*|\
    /run|/run/|/sbin*|/srv*|/sys*|/tmp|/tmp/|/usr|/usr/*|/var|/var/|/var/lib|/var/log*)
      warn "refusing system path: $p"; return 1 ;;
  esac
  # Never touch the host's own state.
  case "$p" in
    /mnt/localdisk|/mnt/localdisk/|*/slurm-tmp*|*/enroot*)
      warn "refusing host-owned path: $p"; return 1 ;;
  esac
  return 0
}

for p in "${paths[@]}"; do
  _path_is_safe "$p" || continue
  [[ -e "$p" ]] || continue
  # Unmount the path itself AND anything mounted beneath it, deepest first.
  # Cilium mounts a cgroup2 filesystem at /run/cilium/cgroupv2, so /run/cilium
  # is not itself a mountpoint and a plain rm -rf leaves the directory behind.
  while read -r m; do
    [[ -n "$m" ]] || continue
    log "unmounting $m"
    umount -f "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || warn "could not unmount $m"
  done < <(awk '{print $2}' /proc/self/mounts | grep -E "^${p}(/|$)" | sort -r)

  log "removing $p"; rm -rf "$p" 2>/dev/null || warn "could not fully remove $p"
done

# ---------------------------------------------------------------- 6. host state
# CDI specs written by things WE installed. The GPU Operator's device plugin and
# the DRA driver each generate their own, and they outlive the pods:
#   k8s.device-plugin.nvidia.com-gpu.json      (device plugin)
#   k8s.gpu.nvidia.com-claim_<uuid>.yaml       (DRA driver, one per claim)
# Both were observed surviving on a live node. The host's own nvidia.yaml is
# never ours to touch -- its sha256 is part of the verify-clean baseline -- so it
# is skipped explicitly rather than by pattern luck.
shopt -s nullglob
for f in /var/run/cdi/k8s-bootstrap-* /etc/cdi/k8s-bootstrap-* \
         /var/run/cdi/k8s.*.nvidia.com-* /etc/cdi/k8s.*.nvidia.com-* \
         /var/run/cdi/k8s.gpu.nvidia.com-* /etc/cdi/k8s.gpu.nvidia.com-*; do
  [[ -e "$f" ]] || continue
  if [[ "$f" == "$HOST_CDI_SPEC" ]]; then
    warn "refusing to remove the host CDI spec ${f}"
    continue
  fi
  log "removing generated CDI spec $(basename "$f")"
  rm -f "$f"
done
shopt -u nullglob
[[ -e "$HOST_CDI_SPEC" ]] || warn "host CDI spec ${HOST_CDI_SPEC} is missing -- it should not be"

# The host IMEX daemon is provider-managed. Under Path A we never touch it; if
# Path B masked it, restore it here so the node goes back as it arrived.
if [[ "$(systemctl is-enabled nvidia-imex 2>/dev/null)" == masked ]]; then
  log "restoring masked nvidia-imex.service (Path B rollback)"
  systemctl unmask nvidia-imex.service 2>/dev/null || :
  systemctl enable --now nvidia-imex.service 2>/dev/null || :
fi

# ------------------------------------------------------ 6b. rail RA guard (dranet)
# node/install-rail-ra-guard.sh stops the rail VFs from learning an IPv6 default
# route from the fabric's RAs (the DRA network driver would exclude them as
# "uplinks"). Reverting restores the kernel default; the routes come back with the
# next periodic RA, so nothing else has to be replayed.
RAIL_RA_DROPIN="${RAIL_RA_DROPIN:-/etc/sysctl.d/98-k8s-bootstrap-rail-ra.conf}"
if [[ -e "$RAIL_RA_DROPIN" ]]; then
  log "removing rail RA guard $(basename "$RAIL_RA_DROPIN") (accept_ra_defrtr back to 1)"
  rm -f "$RAIL_RA_DROPIN"
  sysctl -q -w net.ipv6.conf.default.accept_ra_defrtr=1 net.ipv6.conf.all.accept_ra_defrtr=1 2>/dev/null || :
  for i in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^rdma_vf_' || true); do
    sysctl -q -w "net.ipv6.conf.${i}.accept_ra_defrtr=1" 2>/dev/null || :
  done
fi

# ------------------------------------------------------ 6c. RDMA netns mode
# install-agent.sh may have switched the RDMA subsystem's netns mode (RDMA_NETNS_MODE).
# By now every pod sandbox is gone, so the switch back is accepted; restore whatever the
# pre snapshot recorded (the image default is "exclusive").
if command -v rdma >/dev/null 2>&1; then
  want=""
  [[ -n "$BASELINE_DIR" && -r "${BASELINE_DIR}/rdma-system.txt" ]] \
    && want="$(awk '/netns/{for(i=1;i<=NF;i++) if($i=="netns") print $(i+1)}' "${BASELINE_DIR}/rdma-system.txt")"
  cur="$(rdma system 2>/dev/null | awk '/netns/{for(i=1;i<=NF;i++) if($i=="netns") print $(i+1)}')"
  if [[ -n "$want" && -n "$cur" && "$want" != "$cur" ]]; then
    log "restoring rdma netns mode ${cur} -> ${want}"
    rdma system set netns "$want" 2>/dev/null || warn "rdma system set netns ${want} failed (a netns is still alive?)"
  fi
fi

# ---------------------------------------------------------------- 7. kernel state
# k3s loads networking modules and raises sysctls, and neither is undone by the
# generated uninstaller. Restore what is safe to restore; classify the rest.
if [[ -n "$BASELINE_DIR" && -d "$BASELINE_DIR" ]]; then
  log "restoring kernel state from baseline ${BASELINE_DIR}"

  # NOTE: we deliberately do NOT unload kernel modules.
  #
  # `modprobe -r` also removes dependencies that become unused, so unloading
  # br_netfilter cascades to `bridge` -- which destroys the host's docker0
  # interface, and unloading iptable_* cascades to ip_tables. This was tried and
  # it broke Docker on a shared node.
  #
  # Loaded networking modules are harmless: they autoload on demand and cost
  # nothing. bin/k8s-verify-clean classifies the resulting difference (the three
  # modules, the empty *mangle table they pull in, and the net.bridge sysctl key
  # that only exists while br_netfilter is loaded) as benign, and still fails on
  # anything outside that narrow set.

  # Then sysctls. Restricted allowlist: these are the keys k3s actually changes,
  # and we must not start replaying arbitrary kernel tunables onto a shared node.
  if [[ -r "${BASELINE_DIR}/sysctl.txt" ]]; then
    while IFS='=' read -r k v; do
      case "$k" in
        net.netfilter.nf_conntrack_max|net.bridge.bridge-nf-call-iptables) ;;
        *) continue ;;
      esac
      [[ "$v" == unset ]] && continue     # key is gone with its module; nothing to set
      cur="$(sysctl -n "$k" 2>/dev/null || echo unset)"
      [[ "$cur" == "$v" ]] && continue
      log "  sysctl ${k}: ${cur} -> ${v}"
      sysctl -qw "${k}=${v}" 2>/dev/null || warn "  could not restore ${k}"
    done < "${BASELINE_DIR}/sysctl.txt"
  fi
else
  warn "no --baseline given; kernel modules and sysctls left as k3s set them"
fi

# ---------------------------------------------------------------- 8. verify locally
log "post-teardown self-check:"
residual=0
for p in /var/lib/cni /etc/cni /opt/cni /var/lib/kubelet /var/lib/rancher /etc/rancher \
         /run/k3s /run/cilium "${NODE_INSTALL_DIR}" "${K3S_DATA_DIR}"; do
  (( KEEP_DATA )) && [[ "$p" == "${K3S_DATA_DIR}" ]] && continue
  [[ -e "$p" ]] && { warn "  residual path: $p"; residual=1; }
done
n_rules="$(iptables-save 2>/dev/null | grep -cE 'KUBE-|CNI-|cilium' || true)"
(( ${n_rules:-0} > 0 )) && { warn "  ${n_rules} residual kubernetes/cilium iptables rules"; residual=1; }
n_mnt="$(awk '{print $2}' /proc/self/mounts | grep -cE '^/run/(k3s|cilium)|^/var/lib/kubelet' || true)"
(( ${n_mnt:-0} > 0 )) && { warn "  ${n_mnt} residual mount(s) under /run/k3s, /run/cilium or /var/lib/kubelet"; residual=1; }
n_pins="$(find /sys/fs/bpf -name 'cilium*' 2>/dev/null | grep -c . || true)"
(( ${n_pins:-0} > 0 )) && { warn "  ${n_pins} residual cilium eBPF pin(s)"; residual=1; }
n_cdi="$(find /var/run/cdi /etc/cdi -maxdepth 1 -name 'k8s*' 2>/dev/null | grep -c . || true)"
(( ${n_cdi:-0} > 0 )) && { warn "  ${n_cdi} residual generated CDI spec(s)"; residual=1; }
for i in cilium_host cilium_net cilium_vxlan cni0 flannel.1; do
  ip link show "$i" >/dev/null 2>&1 && { warn "  residual interface: $i"; residual=1; }
done
units="$(systemctl list-units --all --plain --no-legend 'k3s*' 2>/dev/null | awk '{print $1}' | paste -sd,)"
[[ -n "$units" ]] && { warn "  residual units: ${units}"; residual=1; }

if (( residual )); then
  log "FINISHED WITH RESIDUE -- run bin/k8s-verify-clean and inspect"
  exit 1
fi
log "clean"
