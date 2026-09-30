# Helm provider — the customer's cluster the collector installs into. Point it at
# the cluster with a kubeconfig path (+ optional context); the defaults use the
# ambient kubeconfig.
provider "helm" {
  kubernetes {
    config_path    = var.kube_config_path != "" ? var.kube_config_path : null
    config_context = var.kube_context != "" ? var.kube_context : null
  }
}

# Grafana Cloud provider (cloud-level, aliased) — authed with ONE operator-held
# bootstrap access-policy token (scopes: accesspolicies:read, accesspolicies:write,
# stacks:read) reused across every customer. Terraform uses it to read the stack
# and mint the customer's scoped push token. It never goes into the cluster.
provider "grafana" {
  alias                     = "cloud"
  cloud_access_policy_token = var.grafana_cloud_bootstrap_token
}
