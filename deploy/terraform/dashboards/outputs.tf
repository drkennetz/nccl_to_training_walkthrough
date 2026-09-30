output "folder_url" {
  value = "${var.grafana_url}${grafana_folder.compass.url}"
}

output "dashboard_urls" {
  value = { for k, d in grafana_dashboard.compass : k => "${var.grafana_url}${d.url}" }
}
