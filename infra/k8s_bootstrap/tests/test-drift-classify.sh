#!/usr/bin/env bash
# tests/test-drift-classify.sh -- unit tests for lib/drift.sh.
#
# The classifier decides whether a torn-down node counts as clean, so a mistake
# here either hides real leftovers or blocks every teardown. Case F exists
# because unloading kernel modules once destroyed a host's docker0 bridge: a
# module DISAPPEARING must always be real drift.
#
# Run: tests/test-drift-classify.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib/drift.sh
. lib/drift.sh

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pre" "$T/post"
pass=0; fail=0

check() {                       # check <name> <file> <want BENIGN|REAL>
  local name="$1" file="$2" want="$3" got
  got="$(drift_classify "$T/pre" "$T/post" "$file")"
  if [[ "$got" == "$want"* ]]; then
    printf '  ok    %-22s %s\n' "$name" "$got"; pass=$((pass+1))
  else
    printf '  FAIL  %-22s wanted %s, got: %s\n' "$name" "$want" "$got"; fail=$((fail+1))
  fi
}

# ---------------------------------------------------------------- iptables
printf '*filter\n:INPUT ACCEPT \n:FORWARD ACCEPT \nCOMMIT\n' > "$T/pre/iptables.txt"

printf '*filter\n:INPUT ACCEPT \n:FORWARD ACCEPT \nCOMMIT\n*mangle\n:PREROUTING ACCEPT \nCOMMIT\n' > "$T/post/iptables.txt"
check "empty mangle table" iptables.txt BENIGN

printf '*filter\n:INPUT ACCEPT \n:FORWARD ACCEPT \n:KUBE-FIREWALL - \n-A INPUT -j KUBE-FIREWALL\nCOMMIT\n' > "$T/post/iptables.txt"
check "kube chain remains" iptables.txt REAL

printf '*filter\n:INPUT ACCEPT \nCOMMIT\n' > "$T/post/iptables.txt"
check "host rule lost" iptables.txt REAL

printf '*filter\n:INPUT ACCEPT \n:FORWARD ACCEPT \n-A FORWARD -i cilium_host -j ACCEPT\nCOMMIT\n' > "$T/post/iptables.txt"
check "cilium rule remains" iptables.txt REAL

# ---------------------------------------------------------------- modules
printf 'bridge\noverlay\n' > "$T/pre/modules.txt"

printf 'br_netfilter\nbridge\niptable_nat\noverlay\n' > "$T/post/modules.txt"
check "k3s modules added" modules.txt BENIGN

printf 'bridge\noverlay\nsome_random_mod\n' > "$T/post/modules.txt"
check "unexpected module" modules.txt REAL

# The regression that matters: we must never unload a host module.
printf 'overlay\n' > "$T/post/modules.txt"
check "host module removed" modules.txt REAL

# ---------------------------------------------------------------- sysctl
printf 'net.bridge.bridge-nf-call-iptables=unset\nnet.netfilter.nf_conntrack_max=262144\n' > "$T/pre/sysctl.txt"

printf 'net.bridge.bridge-nf-call-iptables=1\nnet.netfilter.nf_conntrack_max=262144\n' > "$T/post/sysctl.txt"
check "bridge key appeared" sysctl.txt BENIGN

printf 'net.bridge.bridge-nf-call-iptables=1\nnet.netfilter.nf_conntrack_max=4718592\n' > "$T/post/sysctl.txt"
check "conntrack unrestored" sysctl.txt REAL

# ---------------------------------------------------------------- cilium modules
printf 'bridge\noverlay\n' > "$T/pre/modules.txt"
printf 'bridge\ncls_bpf\ngeneve\nnf_tproxy_ipv4\noverlay\nsch_ingress\n' > "$T/post/modules.txt"
check "cilium modules added" modules.txt BENIGN

# Socket-diagnostics modules: caused by socket-level load balancing, autoload on
# demand, and in the same unremovable class as br_netfilter.
printf 'bridge\noverlay\n' > "$T/pre/modules.txt"
printf 'bridge\ninet_diag\noverlay\ntcp_diag\nudp_diag\n' > "$T/post/modules.txt"
check "socket-diag modules" modules.txt BENIGN

# unix_diag specifically: loaded by a read-only `ss -x`, which is how a diagnostic
# session dirtied a torn-down tray and failed verify-clean. Regression-pinned.
printf 'bridge\ninet_diag\noverlay\ntcp_diag\nudp_diag\nunix_diag\n' > "$T/post/modules.txt"
check "unix_diag from ss -x" modules.txt BENIGN

# The whole sock_diag family at once.
printf 'af_packet_diag\nbridge\ndccp_diag\ninet_diag\nmptcp_diag\nnetlink_diag\noverlay\nraw_diag\nsctp_diag\nsmc_diag\ntcp_diag\ntipc_diag\nudp_diag\nunix_diag\nvsock_diag\nxsk_diag\n' > "$T/post/modules.txt"
check "full sock_diag family" modules.txt BENIGN

# A lookalike that is NOT a real sock_diag module must still be real drift.
printf 'bridge\noverlay\nunix_diagnostics\n' > "$T/post/modules.txt"
check "diag lookalike name" modules.txt REAL

# But an unrelated module is still real drift -- the allowlist is a list, not a
# blanket pass for modules.txt.
printf 'bridge\noverlay\nudp_diag\nxfs\n' > "$T/post/modules.txt"
check "diag + unrelated module" modules.txt REAL

# Netfilter extension modules are accepted by PREFIX, since which ones load
# depends on which rules got installed.
printf 'bridge\noverlay\n' > "$T/pre/modules.txt"
printf 'bridge\nip6t_REJECT\niptable_raw\nnft_chain_nat\noverlay\nxt_CT\nxt_conntrack\n' > "$T/post/modules.txt"
check "netfilter ext by prefix" modules.txt BENIGN

# The prefix list must NOT become a blanket pass. These are all real drift.
for mod in xfs zfs nvidia_uvm some_random_mod dm_crypt overlay2; do
  printf 'bridge\noverlay\n' > "$T/pre/modules.txt"
  printf "bridge\noverlay\n${mod}\n" > "$T/post/modules.txt"
  check "unrelated: ${mod}" modules.txt REAL
done

# A name that merely CONTAINS a benign prefix later in the string is not a match.
printf 'bridge\noverlay\n' > "$T/pre/modules.txt"
printf 'bridge\nmy_xt_thing\noverlay\n' > "$T/post/modules.txt"
check "prefix must anchor" modules.txt REAL

# ---------------------------------------------------------------- paths (key-wise)
printf '/etc/cni absent\n/opt/k8s-bootstrap absent\n' > "$T/pre/paths.txt"
printf '/etc/cni absent\n/opt/k8s-bootstrap absent\n' > "$T/post/paths.txt"
check "paths unchanged" paths.txt BENIGN

# A path we left behind is real drift.
printf '/etc/cni present\n/opt/k8s-bootstrap absent\n' > "$T/post/paths.txt"
check "path left behind" paths.txt REAL

# Adding a newly-tracked path to snapshot.sh must NOT invalidate old baselines.
printf '/etc/cni absent\n/opt/k8s-bootstrap absent\n/opt/cni absent\n/run/cilium absent\n' > "$T/post/paths.txt"
check "new tracked path" paths.txt BENIGN

# Deleting something the host had is the worst case -- must be caught.
printf '/etc/cni absent\n/opt/k8s-bootstrap absent\n/mnt/localdisk present\n' > "$T/pre/paths.txt"
printf '/etc/cni absent\n/opt/k8s-bootstrap absent\n/mnt/localdisk absent\n' > "$T/post/paths.txt"
check "host path deleted" paths.txt REAL

# ---------------------------------------------------------------- bpf pins
printf '/sys/fs/bpf\n/sys/fs/bpf/tc\n' > "$T/pre/bpf.txt"
printf '/sys/fs/bpf\n/sys/fs/bpf/tc\n/sys/fs/bpf/tc/globals\n' > "$T/post/bpf.txt"
check "empty tc dirs" bpf.txt BENIGN
printf '/sys/fs/bpf\n/sys/fs/bpf/tc\n/sys/fs/bpf/tc/globals/cilium_lb4_services\n' > "$T/post/bpf.txt"
check "cilium pins remain" bpf.txt REAL

# ---------------------------------------------------------------- anything else
printf 'a\n' > "$T/pre/mounts.txt"; printf 'b\n' > "$T/post/mounts.txt"
check "mount changed" mounts.txt REAL
printf 'a\n' > "$T/post/mounts.txt"
check "mounts same" mounts.txt BENIGN
# snapd refreshed a snap between the snapshots: a new squashfs revision under /snap is the host's
printf '/ ext4\n/snap/core18/2999 squashfs\n' > "$T/pre/mounts.txt"
printf '/ ext4\n/snap/core18/2999 squashfs\n/snap/core18/3002 squashfs\n' > "$T/post/mounts.txt"
check "snap refresh mount" mounts.txt BENIGN
printf '/ ext4\n/snap/core18/3002 squashfs\n' > "$T/post/mounts.txt"
check "snap old revision gone" mounts.txt BENIGN
printf '/ ext4\n/snap/core18/2999 squashfs\n/mnt/localdisk/k3s/x overlay\n' > "$T/post/mounts.txt"
check "k3s overlay mount remains" mounts.txt REAL

# Slurm job_container/tmpfs: another job's per-job mount (seen live on nearby-woodcock
# while the site's multi-node health check ran) is Slurm's, not ours -- but only under
# the configured BasePath, only with a numeric job id, and only Slurm's fstypes.
printf '/ ext4\n' > "$T/pre/mounts.txt"
printf '/ ext4\n/mnt/localdisk/slurm-tmp/54224 xfs\n/mnt/localdisk/slurm-tmp/54224/.ns nsfs\n' > "$T/post/mounts.txt"
check "slurm job tmpfs, base unset" mounts.txt REAL
SLURM_JOB_CONTAINER_BASE=/mnt/localdisk/slurm-tmp
check "slurm job tmpfs" mounts.txt BENIGN
printf '/ ext4\n/mnt/localdisk/slurm-tmp/k3s xfs\n' > "$T/post/mounts.txt"
check "non-numeric under base" mounts.txt REAL
printf '/ ext4\n/mnt/localdisk/slurm-tmp/54224 overlay\n' > "$T/post/mounts.txt"
check "wrong fstype under base" mounts.txt REAL
printf '/ ext4\n/mnt/localdisk/slurm-tmp/54224/x/y xfs\n' > "$T/post/mounts.txt"
check "nested path under base" mounts.txt REAL
unset SLURM_JOB_CONTAINER_BASE

# Listening ports: ours left behind, or a host port gone, are REAL; only SITE_TRANSIENT_PORTS
# (the site health check's per-rail ib_write_bw servers on nearby-woodcock) may come and go.
printf '22,5555,9100,18004\n' > "$T/pre/ports.txt"; printf '22,5555,9100\n' > "$T/post/ports.txt"
check "site port gone, unset" ports.txt REAL
SITE_TRANSIENT_PORTS="18001-18008"
check "site port gone" ports.txt BENIGN
printf '22,5555,9100,18005\n' > "$T/post/ports.txt"
check "site port swapped" ports.txt BENIGN
printf '22,5555,9100,6443\n' > "$T/post/ports.txt"
check "k3s port left behind" ports.txt REAL
printf '22,9100\n' > "$T/post/ports.txt"
check "host port disappeared" ports.txt REAL
printf '22,5555,9100,18009\n' > "$T/post/ports.txt"
check "just outside the range" ports.txt REAL
unset SITE_TRANSIENT_PORTS

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
