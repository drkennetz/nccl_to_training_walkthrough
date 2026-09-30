#!/usr/bin/env bash
# tests/test-version-pins.sh -- versions.env is the single source of truth.
#
# CLAUDE.md rule 11 says never hardcode a version. One place has to bend: a
# kustomization.yaml must name its remote resource literally, because Argo CD
# renders that directory directly and cannot expand a shell variable. So the
# literal is allowed there and enforced HERE instead.
#
# Rule 12 says never pin a pre-release; that is checked too, since chart indexes
# routinely present rc/pre tags as "latest".
#
# Run: tests/test-version-pins.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; . ./versions.env; set +a

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

# ---------------------------------------------------------------- kustomize pins
k="platform/storage/local-path/kustomization.yaml"
if [[ -r "$k" ]]; then
  found="$(grep -oE 'local-path-provisioner/v[0-9]+\.[0-9]+\.[0-9]+/' "$k" | head -1 | sed 's|local-path-provisioner/||; s|/$||')"
  if [[ "$found" == "$LOCAL_PATH_PROVISIONER_VERSION" ]]; then
    ok "kustomization pins local-path-provisioner ${found} == versions.env"
  else
    bad "kustomization pins '${found}' but versions.env says '${LOCAL_PATH_PROVISIONER_VERSION}'"
  fi
else
  bad "missing ${k}"
fi

# ---------------------------------------------------------------- no pre-releases
prerelease_re='(-rc|-pre|-alpha|-beta|\.rc[0-9]|-dev)'
while IFS='=' read -r name value; do
  value="${value%\"}"; value="${value#\"}"
  [[ -n "$value" ]] || continue
  if [[ "$value" =~ $prerelease_re ]]; then
    bad "${name} looks like a pre-release: ${value}  (rule 12)"
  fi
done < <(grep -E '^[A-Z_]+_(VERSION|CHART_VERSION)=' versions.env)
(( fail == 0 )) && ok "no pinned version looks like a pre-release"

# ---------------------------------------------------------------- shape sanity
for v in K3S_VERSION KUBEADM_K8S_VERSION HELM_VERSION CILIUM_VERSION \
         GPU_OPERATOR_VERSION ARGOCD_VERSION KUEUE_VERSION \
         LOCAL_PATH_PROVISIONER_VERSION CSI_DRIVER_NFS_VERSION \
         KUBE_PROMETHEUS_STACK_CHART_VERSION; do
  val="${!v:-}"
  if [[ -z "$val" ]]; then bad "${v} is unset"
  elif [[ "$val" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?(\+[A-Za-z0-9]+)?$ ]]; then :
  else bad "${v}='${val}' is not a plain version"; fi
done
ok "all required version variables are set and well-formed"

# ---------------------------------------------------------------- no stray literals
# Values files and scripts must not embed a chart version that versions.env owns.
strays=0
for f in platform/*/values*.yaml; do
  [[ -r "$f" ]] || continue
  if grep -qE '^\s*(version|chartVersion):\s*v?[0-9]+\.[0-9]+' "$f"; then
    # draDriver.version is a chart VALUE, not a chart version; allow it if it matches.
    got="$(grep -oE '^\s*version:\s*v?[0-9.]+' "$f" | head -1 | awk '{print $2}')"
    if [[ "$got" == "$NVIDIA_DRA_DRIVER_VERSION" ]]; then
      ok "$(basename "$f") pins draDriver ${got} == versions.env"
    else
      bad "${f} embeds version '${got}' not traceable to versions.env"; strays=$((strays+1))
    fi
  fi
done
(( strays == 0 )) && ok "no untraceable version literals in platform values"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
