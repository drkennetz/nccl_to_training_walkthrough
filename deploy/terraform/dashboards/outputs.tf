output "folder_url" {
  value = grafana_folder.compass.url
}

output "dashboard_urls" {
  value = { for k, d in grafana_dashboard.compass : k => d.url }
}
