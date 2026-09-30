output "monitoring_release_name" {
  description = "Helm release name of the collector installed in the customer's cluster."
  value       = helm_release.k8s_monitoring.name
}

output "monitoring_namespace" {
  description = "Namespace the collector was installed into."
  value       = helm_release.k8s_monitoring.namespace
}

output "access_policy_name" {
  description = "Name of the Grafana Cloud access policy minted for this customer (find/revoke it here in the Grafana Cloud portal if you lose cluster access)."
  value       = grafana_cloud_access_policy.customer.name
}

# The minted push token is intentionally NOT output — it lives (sensitive) in
# state, consumed only by the collector's Helm values.
