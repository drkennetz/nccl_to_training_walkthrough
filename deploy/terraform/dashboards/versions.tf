terraform {
  required_version = ">= 1.6"

  required_providers {
    # Dashboards only: this root touches Grafana Cloud, never a cluster.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.18"
    }
  }
}
