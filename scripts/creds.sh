#!/usr/bin/env bash
# creds.sh — export the operator's credentials from local dot files into the environment.
#   source scripts/creds.sh
# Reads (by NAME only; never printed, never on a logged command line):
#   ~/dkennetz/.glc   Grafana Cloud bootstrap token (glc_…)     -> TF_VAR_grafana_cloud_bootstrap_token
#   ~/dkennetz/.glsa  Grafana service-account token (glsa_…)     -> TF_VAR_grafana_auth
#   ~/dkennetz/.quay  line 1 user, line 2 token                  -> QUAY_USERNAME / QUAY_PASSWORD
# Seed the GitHub Actions secrets once with:
#   gh secret set QUAY_USERNAME --body "$QUAY_USERNAME" && gh secret set QUAY_PASSWORD --body "$QUAY_PASSWORD"
CREDS_DIR="${CREDS_DIR:-$HOME/dkennetz}"
_r() { [[ -r "$1" ]] && tr -d '\r\n' < "$1"; }
export TF_VAR_grafana_cloud_bootstrap_token="$(_r "$CREDS_DIR/.glc")"
export TF_VAR_grafana_auth="$(_r "$CREDS_DIR/.glsa")"
export QUAY_USERNAME="$(sed -n 1p "$CREDS_DIR/.quay" 2>/dev/null | tr -d '\r\n')"
export QUAY_PASSWORD="$(sed -n 2p "$CREDS_DIR/.quay" 2>/dev/null | tr -d '\r\n')"
for f in .glc .glsa .quay; do
  [[ -r "$CREDS_DIR/$f" ]] || echo "creds.sh: warning: $CREDS_DIR/$f missing" >&2
  [[ "$(stat -c %a "$CREDS_DIR/$f" 2>/dev/null)" =~ ^0?600$ ]] || echo "creds.sh: warning: $CREDS_DIR/$f is not mode 0600" >&2
done
unset -f _r
