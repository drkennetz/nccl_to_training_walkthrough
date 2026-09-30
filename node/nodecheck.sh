#!/usr/bin/env bash
# node/nodecheck.sh -- read-only preflight probe. RUNS ON A LEASED NODE.
#
# Answers one question: is it safe to install Kubernetes here, and will it work?
# Purely read-only. Uses sudo only for privileged reads (iptables, ss).
#
# Invoked over ssh by lib/preflight.sh. The repo is on NFS and mounted on every
# node, so it runs in place rather than being copied around.
#
# Output: one "STATUS|check|detail" line per check.
#   PASS  fine
#   FAIL  blocks installation
#   WARN  worth knowing, does not block
#   INFO  recorded for context
# Exit 1 if any FAIL, else 0.

set -uo pipefail   # not -e: every check must run so the report is complete

# Expectations, overridable by the caller.
GPUS_PER_NODE="${GPUS_PER_NODE:-4}"
EXPECTED_NVIDIA_DRIVER_MIN="${EXPECTED_NVIDIA_DRIVER_MIN:-580}"
NODE_LOCAL_DISK="${NODE_LOCAL_DISK:-/mnt/localdisk}"
MIN_LOCALDISK_GB="${MIN_LOCALDISK_GB:-200}"
NODE_INSTALL_DIR="${NODE_INSTALL_DIR:-/opt/k8s-bootstrap}"
SHARED_FS="${SHARED_FS:-/fss}"
IMEX_CHANNEL_DEV="${IMEX_CHANNEL_DEV:-/dev/nvidia-caps-imex-channels/channel0}"
HOST_CDI_SPEC="${HOST_CDI_SPEC:-/var/run/cdi/nvidia.yaml}"
# Ports k3s + Cilium need. 9100/9400/9500-9700 are the host's exporters and 9876
# is its healthcheck file server; all are expected to be busy, and we scrape the
# exporters rather than binding those ports ourselves.
K8S_PORTS="${K8S_PORTS:-6443 10250 10256 10257 10259 2379 2380 8472 4240 4244 4245 9962 9963 9964 9965 10010}"

fails=0
say()  { printf '%s|%s|%s\n' "$1" "$2" "${3:-}"; }
pass() { say PASS "$1" "${2:-}"; }
fail() { say FAIL "$1" "${2:-}"; fails=$((fails+1)); }
warn() { say WARN "$1" "${2:-}"; }
info() { say INFO "$1" "${2:-}"; }

say INFO hostname "$(hostname)"

# ---------------------------------------------------------------- identity
# THE most important check here. Slurm's NodeAddr and cluster DNS can both be
# STALE on dynamic/cloud nodes: addresses get recycled, and more than one Slurm
# node record can end up pointing at the same physical machine. Observed live --
# `GPU-edaya-k2ssq-8` and `GPU-ez4wq-56l4q-10` resolved to one host.
#
# Without this gate we would install on, and later tear down, a machine that was
# never allocated to us and may belong to someone else's job.
if [[ -n "${EXPECTED_NODE_NAME:-}" ]]; then
  actual="$(hostname)"
  if [[ "${actual,,}" == "${EXPECTED_NODE_NAME,,}" ]]; then
    pass identity "$actual"
  else
    fail identity "expected '${EXPECTED_NODE_NAME}' but this machine is '${actual}' -- Slurm/DNS mapping is stale; DO NOT touch this host"
  fi
else
  warn identity "EXPECTED_NODE_NAME not supplied; cannot confirm this is the right machine"
fi

# ---------------------------------------------------------------- platform
arch="$(uname -m)"
[[ "$arch" == "${EXPECTED_ARCH:-aarch64}" ]] && pass arch "$arch" \
  || warn arch "$arch (cluster env expects ${EXPECTED_ARCH:-aarch64}; check image availability)"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${VERSION_ID:-}" == "24.04" ]] && pass os "${PRETTY_NAME:-?}" \
    || warn os "${PRETTY_NAME:-?} (validated on Ubuntu 24.04)"
fi
info kernel "$(uname -r)"
info cpus "$(nproc)"
info memory_gb "$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)"

# ---------------------------------------------------------------- kubelet prereqs
if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  pass swap "off"
else
  fail swap "swap is enabled; kubelet refuses to start. $(swapon --show --noheadings | tr '\n' ' ')"
fi

cg="$(stat -fc %T /sys/fs/cgroup 2>/dev/null)"
[[ "$cg" == cgroup2fs ]] && pass cgroup "v2 (cgroup2fs)" \
  || fail cgroup "expected cgroup2fs, got '${cg:-none}'"

ipf="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
[[ "$ipf" == 1 ]] && pass ip_forward "1" || warn ip_forward "${ipf:-?} (k3s will enable it)"

# Clock skew breaks TLS handshakes and etcd. Cheap to check, miserable to debug.
ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
[[ "$ntp" == yes ]] && pass clock "NTP synchronized" \
  || warn clock "NTP not synchronized (${ntp:-unknown}); TLS and etcd are sensitive to skew"

# ---------------------------------------------------------------- do-no-harm gates
# These exist to protect the node, not us. A node that already has CNI state or
# k8s firewall rules is either in use or was left dirty; either way, not ours.
cni_dirty=""
for d in /var/lib/cni /etc/cni/net.d; do
  [[ -e "$d" ]] && cni_dirty+="$d "
done
if [[ -z "$cni_dirty" ]]; then
  pass cni_state "no pre-existing CNI state"
else
  fail cni_state "pre-existing CNI state: ${cni_dirty}-- node may be in use, or was left dirty"
fi

k8s_rules="$(sudo -n iptables-save 2>/dev/null | grep -cE 'KUBE-|CNI-|cali-|cilium' || true)"
if [[ "${k8s_rules:-0}" == 0 ]]; then
  pass iptables "clean ($(sudo -n iptables-save 2>/dev/null | grep -c . || echo '?') host rules, 0 kubernetes)"
else
  fail iptables "${k8s_rules} pre-existing kubernetes/CNI rules -- node was left dirty"
fi

# Detect an existing install by binary and unit, NOT by `pgrep -f k3s`: an -f
# pattern also matches the ssh command carrying this script, so a pristine node
# would report itself dirty.
existing=""
for b in /usr/local/bin/k3s "${NODE_INSTALL_DIR}/bin/k3s" /usr/bin/kubelet /usr/bin/kubeadm; do
  [[ -e "$b" ]] && existing+="$b "
done
while read -r u; do [[ -n "$u" ]] && existing+="unit:${u} "; done < <(
  systemctl list-units --all --no-legend --plain 'k3s*' 'kubelet*' 2>/dev/null | awk '{print $1}'
)
if [[ -z "$existing" ]]; then
  pass no_existing_k8s "no k3s/kubelet present"
else
  fail no_existing_k8s "already present: ${existing}-- tear down first (node/teardown.sh)"
fi

if [[ -e "$NODE_INSTALL_DIR" ]]; then
  warn install_dir "${NODE_INSTALL_DIR} exists; will be reused/overwritten"
else
  pass install_dir "${NODE_INSTALL_DIR} absent"
fi

# k3s symlinks ctr/crictl into its bin dir. If we ever pointed that at
# /usr/local/bin it would shadow the host's containerd tooling on PATH.
if [[ -L /usr/local/bin/ctr || -L /usr/local/bin/crictl ]]; then
  fail usr_local_bin "/usr/local/bin has ctr/crictl symlinks -- host tooling is shadowed"
else
  pass usr_local_bin "no shadowing symlinks"
fi

# ---------------------------------------------------------------- ports
busy=""
for p in $K8S_PORTS; do
  if sudo -n ss -Hltn "sport = :${p}" 2>/dev/null | grep -q LISTEN; then
    busy+="${p} "
  fi
done
[[ -z "$busy" ]] && pass ports "all required ports free" \
  || fail ports "already listening: ${busy}"

# ---------------------------------------------------------------- storage
# The node root fs is small (~123G). Container images are 20+G each, so cluster
# state must live on the big local NVMe.
if mountpoint -q "$NODE_LOCAL_DISK" 2>/dev/null; then
  avail_gb="$(df -BG --output=avail "$NODE_LOCAL_DISK" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if (( ${avail_gb:-0} >= MIN_LOCALDISK_GB )); then
    pass localdisk "${NODE_LOCAL_DISK} ${avail_gb}G free ($(findmnt -no FSTYPE "$NODE_LOCAL_DISK" 2>/dev/null))"
  else
    fail localdisk "${NODE_LOCAL_DISK} only ${avail_gb:-0}G free, need ${MIN_LOCALDISK_GB}G"
  fi
else
  fail localdisk "${NODE_LOCAL_DISK} is not a mountpoint -- cluster state has nowhere to go"
fi

root_gb="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
info root_free_gb "${root_gb:-?}"

for m in "$SHARED_FS" /home; do
  mountpoint -q "$m" 2>/dev/null && pass "shared_fs_${m//\//_}" "$m mounted" \
    || warn "shared_fs_${m//\//_}" "$m not mounted"
done

# ---------------------------------------------------------------- gpu stack
if command -v nvidia-smi >/dev/null 2>&1; then
  drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  drv_major="${drv%%.*}"
  if (( ${drv_major:-0} >= EXPECTED_NVIDIA_DRIVER_MIN )); then
    pass nvidia_driver "$drv"
  else
    fail nvidia_driver "$drv (need >= ${EXPECTED_NVIDIA_DRIVER_MIN} for DRA/CDI)"
  fi

  ngpu="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
  [[ "${ngpu:-0}" == "$GPUS_PER_NODE" ]] && pass gpu_count "$ngpu" \
    || fail gpu_count "found ${ngpu:-0}, expected ${GPUS_PER_NODE}"
  info gpu_model "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
else
  fail nvidia_driver "nvidia-smi not found"
fi

# k3s auto-detects this binary and generates the `nvidia` RuntimeClass. Without
# it, GPUs are invisible to pods no matter what the operator does.
if command -v nvidia-container-runtime >/dev/null 2>&1; then
  pass nvidia_runtime "$(command -v nvidia-container-runtime)"
else
  fail nvidia_runtime "nvidia-container-runtime not on PATH; k3s cannot wire up GPUs"
fi
command -v nvidia-ctk >/dev/null 2>&1 \
  && info nvidia_ctk "$(nvidia-ctk --version 2>/dev/null | awk '/version/{print $NF; exit}')"

# ---------------------------------------------------------------- imex / nvlink
# Path A depends on the host IMEX daemon staying healthy and untouched.
# IMEX_PATH=none (HGX, e.g. B300.8): NVLink ends at the node edge and there is no IMEX
# domain to depend on, so its absence is recorded, not warned about.
imex_active="$(systemctl is-active nvidia-imex 2>/dev/null || true)"
if [[ "${IMEX_PATH:-A}" == none ]]; then
  info imex_service "${imex_active:-absent} (IMEX_PATH=none: no multi-node NVLink on this shape)"
  [[ -e "$IMEX_CHANNEL_DEV" ]] && info imex_channel "$IMEX_CHANNEL_DEV present" \
    || info imex_channel "absent (IMEX_PATH=none)"
else
  [[ "$imex_active" == active ]] && pass imex_service "active (host-managed, Path A)" \
    || warn imex_service "${imex_active:-absent}; multi-node NVLink unavailable"

  [[ -e "$IMEX_CHANNEL_DEV" ]] && pass imex_channel "$IMEX_CHANNEL_DEV present" \
    || warn imex_channel "$IMEX_CHANNEL_DEV missing; pods cannot get multi-node NVLink"
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  # Anchor on the exact "Fabric" section header: a loose /Fabric/ match also hits
  # "GPU Fabric GUID", after which the next /State/ line is "Performance State : P0".
  fab_states="$(nvidia-smi -q 2>/dev/null \
    | awk '/^[[:space:]]+Fabric$/{f=1;next} f&&/^[[:space:]]+State[[:space:]]*:/{print $NF; f=0}' \
    | sort -u | paste -sd,)"
  [[ "$fab_states" == Completed ]] && pass fabric_state "Completed on all GPUs" \
    || warn fabric_state "${fab_states:-unknown} (want Completed on every GPU)"

  cliques="$(nvidia-smi -q 2>/dev/null | awk '/CliqueId/{print $NF}' | sort -u | paste -sd,)"
  case "$(tr -cd ',' <<<"$cliques" | wc -c)" in
    0) pass clique_id "${cliques:-none}" ;;
    *) warn clique_id "inconsistent across GPUs: ${cliques}" ;;
  esac
fi

# The host generates this CDI spec. We must never rewrite it; verify-clean
# compares this hash after teardown.
if [[ -r "$HOST_CDI_SPEC" ]]; then
  pass host_cdi "$(sudo -n sha256sum "$HOST_CDI_SPEC" 2>/dev/null | cut -c1-16)... ($(stat -c%s "$HOST_CDI_SPEC")B)"
else
  warn host_cdi "$HOST_CDI_SPEC not readable"
fi

# ---------------------------------------------------------------- host services
for u in nvidia-dcgm dcgm-exporter nvidia-persistenced containerd docker slurmd; do
  info "svc_${u}" "$(systemctl is-active "$u" 2>/dev/null || echo absent)"
done

exit $(( fails > 0 ))
