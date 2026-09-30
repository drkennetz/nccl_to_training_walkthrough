# -----------------------------------------------------------------------------
# Per-customer onboarding: mint the customer's Grafana Cloud push token and
# install the Alloy collector into their cluster. Applied ONCE PER CUSTOMER
# (ideally in its own Terraform workspace / state, so `terraform destroy` for that
# workspace revokes only that customer's token and removes only their collector).
# -----------------------------------------------------------------------------

# --- Bootstrap (operator-held, reused across all customers) -------------------

variable "grafana_cloud_bootstrap_token" {
  type        = string
  sensitive   = true
  description = "Operator-held Grafana Cloud access-policy token (glc_…) with scopes accesspolicies:read, accesspolicies:write, stacks:read. Terraform uses it to read the stack and mint each customer's push token. Supply via TF_VAR_grafana_cloud_bootstrap_token; never commit."
}

variable "grafana_cloud_stack_slug" {
  type        = string
  description = "Grafana Cloud stack slug (the <slug> in https://<slug>.grafana.net) — used to look up the stack the push token is scoped to."
}

variable "grafana_cloud_region" {
  type        = string
  default     = ""
  description = "Grafana Cloud region slug for the access policy (e.g. \"prod-us-east-0\"). Empty derives it from the stack's region."
}

# --- Per-customer identity ----------------------------------------------------

variable "customer" {
  type        = string
  description = "Customer/tenant name — used to name the access policy + collector and (via the KTLO Helm install) the ktlo-labs.ai/tenant label."
}

variable "cluster_name" {
  type        = string
  description = "The customer's cluster name — becomes the `cluster` label on all telemetry."
}

# --- Grafana Cloud push destinations (from the stack's connection details) ----

variable "grafana_cloud_metrics_url" {
  type        = string
  description = "Metrics (Prometheus remote-write) push URL, e.g. https://prometheus-prod-XX-prod-REGION.grafana.net./api/prom/push"
}

variable "grafana_cloud_metrics_username" {
  type        = string
  description = "Metrics destination instance-ID (username) for basic auth."
}

variable "grafana_cloud_metrics_query_url" {
  type        = string
  description = "Prometheus query URL for OpenCost. Empty derives it from the metrics push URL (minus the trailing /push)."
  default     = ""
}

variable "grafana_cloud_logs_url" {
  type        = string
  description = "Logs (Loki) push URL, e.g. https://logs-prod-XXX.grafana.net./loki/api/v1/push"
}

variable "grafana_cloud_logs_username" {
  type        = string
  description = "Logs destination instance-ID (username) for basic auth."
}

# --- Target cluster (Helm provider) + collector install -----------------------

variable "kube_config_path" {
  type        = string
  description = "Path to the kubeconfig for the customer's cluster. Empty uses the ambient kubeconfig."
  default     = "~/.kube/config"
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context to use for the customer's cluster (optional)."
  default     = ""
}

variable "monitoring_namespace" {
  type        = string
  description = "Namespace the Kubernetes Monitoring stack is installed into."
  default     = "ktlo-monitor"
}

variable "monitoring_release_name" {
  type        = string
  description = "Helm release name for the Kubernetes Monitoring stack."
  default     = "grafana-k8s-monitoring"
}

variable "monitoring_chart_version" {
  type        = string
  description = "Version constraint for the grafana/k8s-monitoring chart."
  default     = "^4"
}

# --- Cluster shape (nothing assumed — set to match the customer's cluster) ----

variable "reuse_existing_node_exporter" {
  type        = bool
  default     = false
  description = <<-EOT
    Whether the cluster ALREADY runs a Node Exporter (e.g. from a kube-prometheus-stack
    on host port 9100). Default false: the collector deploys its own — the safe default
    that assumes nothing about the cluster. Set true on a cluster that already has one:
    the collector will NOT deploy its own (avoiding a port-9100 collision) and instead
    scrapes host metrics from the existing DaemonSet identified by the two vars below.
  EOT
}

variable "existing_node_exporter_namespace" {
  type        = string
  default     = "monitoring"
  description = "Namespace of the existing Node Exporter to reuse (only when reuse_existing_node_exporter = true)."
}

variable "existing_node_exporter_label_selector" {
  type        = map(string)
  default     = { "app.kubernetes.io/name" = "prometheus-node-exporter" }
  description = "Label selector matching the existing Node Exporter pods to reuse (only when reuse_existing_node_exporter = true)."
}

variable "scrape_host_node_exporter" {
  type        = bool
  default     = false
  description = <<-EOT
    Set true when every node ALREADY runs a Node Exporter as a HOST process (a systemd unit
    on the node, not a Kubernetes pod) bound to host_node_exporter_port. Then the collector
    deploys no Node Exporter (the chart's DaemonSet would crash-loop on the port collision),
    disables the chart's pod-discovery host-metrics feature (its render-time validation
    requires matching pods), and instead scrapes every node's InternalIP:<port> directly from
    alloy-metrics, applying the same metrics_profile keep-list. Mutually exclusive with
    reuse_existing_node_exporter (which is for an exporter that runs as pods).
  EOT
}

variable "host_node_exporter_port" {
  type        = number
  default     = 9100
  description = "Host port the node-level Node Exporter listens on (only when scrape_host_node_exporter = true)."
}

variable "extra_host_exporters" {
  type = map(object({
    port = number
    job  = string
    keep = optional(list(string), [])
  }))
  default     = {}
  description = <<-EOT
    Additional HOST-process exporters to scrape on every node's InternalIP, keyed by a short
    name (letters, digits, underscore), e.g. { dcgm = { port = 9400, job = "integrations/dcgm" } }.
    `keep` is an optional list of metric-name regexes OR-joined into a keep rule (applied under
    metrics_profile = "gpu-health"; ignored under "full"). Without `keep` the series ship
    unfiltered, so mind the metrics budget. Only used when scrape_host_node_exporter = true.
  EOT

  validation {
    condition     = alltrue([for k, v in var.extra_host_exporters : can(regex("^[a-z][a-z0-9_]*$", k))])
    error_message = "extra_host_exporters keys must match ^[a-z][a-z0-9_]*$ (they become Alloy component labels)."
  }
}

variable "scrape_host_gpu_exporters" {
  type        = bool
  default     = false
  description = <<-EOT
    Also scrape the four HOST-process GPU/fabric exporters common on NVIDIA GPU images — the
    device exporter (DCGM, :9400), the NVLink counter exporter (:9600), the PCIe fault exporter
    (:9700) and the RDMA counter exporter (:9500) — on every node's InternalIP. Under
    metrics_profile = "gpu-health" each ships a curated hardware-health keep-list (see
    collector.tf `host_gpu_exporters`); under "full" everything the exporter emits ships.
    Jobs: integrations/dcgm, integrations/nvlink, integrations/pcie, integrations/rdma.
    Requires scrape_host_node_exporter = true (same node-discovery mechanism). Ports are
    overridable through host_gpu_exporter_ports.
  EOT
}

variable "host_gpu_exporter_ports" {
  type = object({
    dcgm   = optional(number, 9400)
    nvlink = optional(number, 9600)
    pcie   = optional(number, 9700)
    rdma   = optional(number, 9500)
  })
  default     = {}
  description = "Host ports of the four GPU/fabric exporters (only when scrape_host_gpu_exporters = true)."
}

variable "service_monitor_part_of_excludes" {
  type        = list(string)
  default     = []
  description = <<-EOT
    `app.kubernetes.io/part-of` values whose ServiceMonitors the collector should NOT
    scrape — set this to the label(s) of any OTHER monitoring stack on the cluster
    (e.g. [\"kube-prometheus-stack\", \"kube-state-metrics\", \"prometheus-node-exporter\"])
    so their series aren't double-shipped. Empty (default) scrapes every ServiceMonitor,
    including KTLO's — assumes no competing stack.
  EOT
}

variable "service_monitor_exclude_labels" {
  type = list(object({
    key    = string
    values = list(string)
  }))
  default     = []
  description = <<-EOT
    Extra ServiceMonitor label match-expressions to EXCLUDE from scraping, for noisy
    monitors that carry NO `app.kubernetes.io/part-of` label (so
    `service_monitor_part_of_excludes` can't catch them) — e.g. a bundled Grafana or a
    cloud-provider metrics exporter. Each entry is rendered as a `NotIn` on `key`, and
    all expressions are ANDed. Because `NotIn` keeps monitors that lack the label, a
    monitor is dropped only if it actually carries `key` with one of `values`. Example:
    [
      { key = "app.kubernetes.io/name", values = ["grafana", "oci-metrics-exporter"] },
      { key = "app",                    values = ["gpu-operator"] },
    ]
    Keep GPU/RDMA exporters (amd-device-metrics-exporter, etc.) — KTLO's dashboards read
    their `amd_gpu_*` series. Empty (default) excludes nothing beyond part-of.
  EOT
}

variable "service_monitor_exclude_metrics" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Metric names (regex ok) to DROP from ServiceMonitor-scraped targets, on top of
    what the metrics_profile already drops. Use to shed high-cardinality series a
    scraped exporter emits that you don't chart. Under metrics_profile = "gpu-health"
    the collector already drops the AMD exporter's unused families (JPEG/VCN media
    engines, min/max clock bounds, per-hardware-block ECC breakdown); this var adds
    to that list. Ignored (the AMD trim too) under metrics_profile = "full".
  EOT
}

variable "enable_windows_exporter" {
  type        = bool
  default     = false
  description = "Deploy the Windows Exporter (only useful if the cluster has Windows nodes). Off by default — GPU clusters are Linux."
}

variable "enable_kepler" {
  type        = bool
  default     = false
  description = "Deploy Kepler for per-node energy metrics. OFF by default — energy is not a hardware-health signal and Kepler adds ~700 series/node. Set true if you want per-node energy/power draw."
}

# --- Metrics profile (what actually ships to Grafana Cloud) -------------------

variable "metrics_profile" {
  type    = string
  default = "gpu-health"

  validation {
    condition     = contains(["gpu-health", "full"], var.metrics_profile)
    error_message = "metrics_profile must be \"gpu-health\" or \"full\"."
  }

  description = <<-EOT
    Which scraped series are shipped to Grafana Cloud.

    "gpu-health" (default): keep only GPU and GPU-agnostic HARDWARE-health series
    — node-exporter thermal/power/fan/voltage (hwmon), RDMA/RoCE (infiniband),
    NIC link+throughput+errors, disk/filesystem, ECC (edac), CPU thermal-throttle
    counters — plus KTLO's own amd_gpu_*/ktlo_* and a small node/workload-state
    set from kube-state-metrics. Drops per-container (cAdvisor), kubelet,
    control-plane, and CPU-utilisation telemetry. Keeps a typical cluster under
    Grafana Cloud's free-tier 10,000 active-series limit.

    "full": ship everything the chart scrapes (its own default allow-lists).
    Larger active-series bill; use only if you consume the broader k8s telemetry.
  EOT
}

variable "extra_keep_node_metrics" {
  type        = list(string)
  default     = []
  description = "Extra node-exporter metric names/regexes to keep on top of the gpu-health profile (e.g. [\"node_cpu_seconds_total\"] to restore host CPU-utilisation panels). Ignored when metrics_profile = \"full\"."
}

# --- Optional extras (each adds a scope to the minted token when enabled) -----

variable "enable_fleet_management" {
  type        = bool
  default     = false
  description = "Pull the Alloy config from Grafana Cloud Fleet Management (remotecfg). OFF by default; KTLO defines the collector config here. When true, the minted token gets the fleet-management scope automatically."
}

variable "enable_opencost" {
  type        = bool
  default     = false
  description = "Deploy OpenCost (Grafana's cluster cost add-on). OFF by default; KTLO has its own cost signal (ktlo_gpu_idle_ratio). When true, the minted token gets the metrics read/query scope automatically."
}

variable "grafana_cloud_fleet_url" {
  type        = string
  default     = ""
  description = "Fleet Management endpoint (only needed when enable_fleet_management = true)."
}

variable "grafana_cloud_fleet_username" {
  type        = string
  default     = ""
  description = "Fleet Management instance-ID/username (only needed when enable_fleet_management = true)."
}
