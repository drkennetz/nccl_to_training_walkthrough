# Every JSON in deploy/grafana/dashboards/ becomes a dashboard in one folder. The JSONs reference
# the data source as ${DS_PROMETHEUS}; it is replaced with the stack's data source UID here, so
# the same file works on any stack.
resource "grafana_folder" "compass" {
  title = var.dashboards_folder_title
}

resource "grafana_dashboard" "compass" {
  for_each = fileset("${path.module}/../../grafana/dashboards", "*.json")

  folder      = grafana_folder.compass.uid
  config_json = replace(file("${path.module}/../../grafana/dashboards/${each.value}"), "$${DS_PROMETHEUS}", var.prometheus_datasource_uid)
  overwrite   = true
}
