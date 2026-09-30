# Grafana Cloud stack. `auth` is a service-account token with dashboard-write + folder-write;
# supply it as TF_VAR_grafana_auth (scripts/creds.sh) — never commit it.
provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}
