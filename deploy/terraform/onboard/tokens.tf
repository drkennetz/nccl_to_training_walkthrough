# The customer's Grafana Cloud push token, minted by Terraform from the bootstrap
# token. `terraform apply` creates it (correctly scoped by construction — no
# hand-made token, no scope mistakes); `terraform destroy` revokes it. If you lose
# access to the customer's cluster, delete the access policy/token in the Grafana
# Cloud portal instead, then drop this workspace's state.

data "grafana_cloud_stack" "this" {
  provider = grafana.cloud
  slug     = var.grafana_cloud_stack_slug
}

locals {
  access_policy_name = "ktlo-${var.customer}-${var.cluster_name}"
  region             = var.grafana_cloud_region != "" ? var.grafana_cloud_region : data.grafana_cloud_stack.this.region_slug

  # Base scopes for the push pipeline; each optional extra adds exactly the scope
  # it needs, so the token is never over- or under-scoped for what's enabled.
  token_scopes = concat(
    ["metrics:write", "logs:write"],
    var.enable_opencost ? ["metrics:read"] : [],
    var.enable_fleet_management ? ["fleet-management:read", "fleet-management:write"] : [],
  )
}

resource "grafana_cloud_access_policy" "customer" {
  provider     = grafana.cloud
  region       = local.region
  name         = local.access_policy_name
  display_name = "KTLO ${var.customer} / ${var.cluster_name}"
  scopes       = local.token_scopes

  realm {
    type       = "stack"
    identifier = data.grafana_cloud_stack.this.id
  }
}

resource "grafana_cloud_access_policy_token" "customer" {
  provider         = grafana.cloud
  region           = local.region
  access_policy_id = grafana_cloud_access_policy.customer.policy_id
  name             = local.access_policy_name
  display_name     = "KTLO ${var.customer} / ${var.cluster_name}"
}
