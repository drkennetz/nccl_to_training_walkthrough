#!/usr/bin/env bash
# tests/test-path-safety.sh -- the teardown path guard.
#
# node/teardown.sh runs as ROOT on a borrowed node and unmounts by PREFIX MATCH.
# An empty or truncated variable (K3S_DATA_DIR="", NODE_LOCAL_DISK unset) would
# expand to "/" or "/mnt" and could unmount or delete far more than intended --
# including Slurm's own /mnt/localdisk/slurm-tmp and the shared enroot cache.
#
# Extracted from teardown.sh so the rules are testable without running teardown.
# If you change _path_is_safe() there, mirror it here and add cases.
#
# Run: tests/test-path-safety.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Pull the live function out of teardown.sh so the test cannot drift silently.
eval "$(sed -n '/^_path_is_safe() {/,/^}/p' node/teardown.sh)"
warn() { :; }   # silence the guard's own reporting

pass=0; fail=0
want() {                       # want <ALLOW|DENY> <path>
  local expect="$1" p="${2-}" got
  if _path_is_safe "$p" >/dev/null 2>&1; then got=ALLOW; else got=DENY; fi
  if [[ "$got" == "$expect" ]]; then printf '  ok    %-6s %s\n' "$got" "${p:-<empty>}"; pass=$((pass+1))
  else printf '  FAIL  wanted %-5s got %-5s for %s\n' "$expect" "$got" "${p:-<empty>}"; fail=$((fail+1)); fi
}

# Must never be touched.
want DENY ""
want DENY "/"
want DENY "relative/path"
want DENY "/mnt"
want DENY "/run"
want DENY "/var"
want DENY "/var/lib"
want DENY "/usr"
want DENY "/usr/bin"
want DENY "/etc"
want DENY "/home"
want DENY "/boot"
want DENY "/sys/fs"
want DENY "/proc"
# Host-owned state on the shared local disk.
want DENY "/mnt/localdisk"
want DENY "/mnt/localdisk/slurm-tmp"
want DENY "/mnt/localdisk/enroot"

# The paths teardown legitimately removes.
want ALLOW "/run/k3s"
want ALLOW "/run/flannel"
want ALLOW "/run/cilium"
want ALLOW "/var/lib/kubelet"
want ALLOW "/var/lib/cni"
want ALLOW "/var/lib/rancher"
want ALLOW "/etc/cni"
want ALLOW "/etc/rancher"
want ALLOW "/opt/cni"
want ALLOW "/opt/k8s-bootstrap"
want ALLOW "/mnt/localdisk/k3s"
want ALLOW "/mnt/localdisk/local-path"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
