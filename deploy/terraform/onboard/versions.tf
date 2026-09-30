terraform {
  required_version = ">= 1.6"

  required_providers {
    # Installs the Kubernetes Monitoring stack (Grafana Alloy) into the customer's
    # cluster.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # Mints the customer's Grafana Cloud push token (cloud access policy + token)
    # and reads the stack to scope it.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.18"
    }
  }
}
