variable "grafana_url" {
  type        = string
  description = "Grafana Cloud stack URL, e.g. https://myorg.grafana.net"
}

variable "grafana_auth" {
  type        = string
  sensitive   = true
  description = "Grafana service-account token (glsa_…) with dashboard-write + folder-write."
}

variable "dashboards_folder_title" {
  type        = string
  default     = "Compass — NCCL fabric"
  description = "Grafana folder the take-home dashboards are placed in."
}

variable "prometheus_datasource_uid" {
  type        = string
  default     = "grafanacloud-prom"
  description = "UID of the Prometheus data source the dashboards query (the stack's hosted Prometheus)."
}
