# Kubernetes Monitoring stack (Grafana Alloy) install for this customer's cluster.
#
# Identical collector config to the pre-split root, with one change: the push
# password is the per-customer token Terraform just minted
# (grafana_cloud_access_policy_token.customer.token), not a hand-supplied token.
#
# Two cluster adaptations are preserved:
#   1. Reuse the existing Node Exporter (host port 9100) — the bundled one is off
#      to avoid a hostPort collision.
#   2. Scrape only the GPU-relevant ServiceMonitors via prometheusOperatorObjects,
#      excluding the kube-prometheus-stack's own monitors (Alloy natively covers
#      those) to avoid doubled series.

locals {
  # Grafana Cloud's Prometheus (Mimir) remote-write endpoint ends in /api/prom/push.
  # A common mistake is to paste the Prometheus DATA SOURCE (query) URL — which ends
  # in /api/prom — into grafana_cloud_metrics_url; the collector then POSTs samples to
  # /api/prom and Grafana Cloud returns 404. Tolerate that by appending /push when it's
  # missing, so a query-URL paste still ships metrics.
  grafana_cloud_metrics_push_url = endswith(var.grafana_cloud_metrics_url, "/push") ? var.grafana_cloud_metrics_url : "${trimsuffix(var.grafana_cloud_metrics_url, "/")}/push"

  # Prometheus query base for OpenCost: the metrics push URL minus the trailing
  # /push, unless overridden.
  grafana_cloud_metrics_query_url = var.grafana_cloud_metrics_query_url != "" ? var.grafana_cloud_metrics_query_url : trimsuffix(local.grafana_cloud_metrics_push_url, "/push")

  # The per-customer token mints here; the collector uses it for every push.
  push_token = grafana_cloud_access_policy_token.customer.token

  # Host metrics: reuse the cluster's existing Node Exporter when told to (points
  # Alloy at it, and the chart's own is disabled below to avoid a 9100 collision);
  # otherwise namespace/labelMatchers are null (unset) and the chart wires host
  # metrics to the Node Exporter it deploys. null keeps both branches the same type.
  # In host-scrape mode (scrape_host_node_exporter) the feature is OFF: its render-time
  # validation requires Node Exporter *pods* to exist, and here the exporter is a host
  # process. The equivalent scrape is injected into alloy-metrics below instead.
  linux_hosts = {
    enabled       = !var.scrape_host_node_exporter
    namespace     = var.reuse_existing_node_exporter ? var.existing_node_exporter_namespace : null
    labelMatchers = var.reuse_existing_node_exporter ? var.existing_node_exporter_label_selector : null
  }

  # Which ServiceMonitors to scrape, expressed as label match-expressions that
  # EXCLUDE (NotIn) the noisy ones. Two knobs, both empty by default (scrape all):
  #   - service_monitor_part_of_excludes → NotIn on app.kubernetes.io/part-of,
  #     for a competing stack that labels its monitors (e.g. kube-prometheus-stack).
  #   - service_monitor_exclude_labels → arbitrary NotIn expressions, for noisy
  #     monitors that carry NO part-of label (e.g. a bundled Grafana or a cloud
  #     metrics exporter). NotIn keeps monitors that lack the label, so a monitor
  #     is dropped only if it actually has that label with a listed value.
  # Expressions are ANDed, so a monitor must pass every one to be scraped.
  sm_label_expressions = concat(
    length(var.service_monitor_part_of_excludes) > 0 ? [
      {
        key      = "app.kubernetes.io/part-of"
        operator = "NotIn"
        values   = var.service_monitor_part_of_excludes
      },
    ] : [],
    [
      for e in var.service_monitor_exclude_labels : {
        key      = e.key
        operator = "NotIn"
        values   = e.values
      }
    ],
  )

  # --- Metrics profile: which scraped series actually ship ------------------
  # "gpu-health" (default) ships only GPU + GPU-agnostic hardware-health series;
  # "full" ships everything the chart scrapes (its own default allow-lists).
  # KTLO's own ktlo_* and the AMD device-metrics-exporter's amd_gpu_* come via
  # prometheusOperatorObjects (ServiceMonitors); the source tuning below only trims
  # the noisy infra sources (node-exporter, kube-state-metrics, cAdvisor/kubelet),
  # and sm_exclude_metrics (below) drops a few high-cardinality amd_gpu_* families
  # KTLO's dashboards don't use. The gpu-health profile keeps a typical AMD cluster
  # under Grafana Cloud's free-tier 10k active-series cap. See README "Metrics profile".
  gpu_health_profile = var.metrics_profile == "gpu-health"

  # High-cardinality amd_gpu_* families the AMD device-metrics-exporter emits that
  # KTLO's dashboards/alerts never read — media engines (JPEG/VCN), the min/max clock
  # bounds (dashboards use amd_gpu_clock), and the ECC blocks this hardware never
  # populates. Dropped by name so amd_gpu_clock, the ECC counters, throttle "violation"
  # counters, temps/power/XGMI — everything the GPU-health view plots — are all kept.
  #
  # PER-BLOCK ECC IS NOW PARTLY KEPT (epic #440/A4). It used to be dropped wholesale in
  # favour of the _total roll-ups, which cost the platform the ability to say UMC-vs-GFX on
  # a hardware-fault report — while KTLO's own KTLO-GPU-ECCDEFER-01 guidance turns on
  # exactly that distinction ("on the non-HBM blocks this is the earliest signal a board is
  # failing"). We were grading a signal we could never evidence. UMC's correctable rate is
  # also the best HBM-failure predictor available, so all three severities are kept for the
  # blocks we keep, not only the uncorrectable ones.
  #
  # The keep-set is the blocks MI300X actually INSTRUMENTS. That is the only sound
  # criterion: "reads zero" cannot distinguish unsupported from healthy, because zero is
  # the expected healthy value of every ECC counter. Measured with `amd-smi metric
  # --ecc-block --json` on the live fleet — UMC, GFX, SDMA, MMHUB, XGMI_WAFL report real
  # counts; HDP and PCIE_BIF report "N/A" on every GPU, so they are not wired up on this
  # part. Those five are also exactly what recommendations.json and checks_gpu_mem.go
  # already name, so on-node grading and lake ingest agree rather than diverging.
  #
  # The exporter cannot arbitrate this: it emits all nineteen block names regardless
  # (3 severities x 20 incl. _total x 8 GPUs = 480 series/node) and coerces an unsupported
  # block to 0, so amd-smi is the source of truth for what is instrumented. Keeping five
  # costs 3 x 5 x 8 = 120 series/node; the fourteen dropped below include the two this
  # hardware reports as N/A.
  ecc_unsupported_blocks = "athub|bif|df|fuse|hdp|ih|jpeg|mca|mp0|mp1|mpio|sem|smn|vcn"

  amd_exporter_drop = [
    "amd_gpu_jpeg_busy_instantaneous",
    "amd_gpu_vcn_busy_instantaneous",
    "amd_gpu_min_clock",
    "amd_gpu_max_clock",
    "amd_gpu_ecc_(correct|uncorrect|deferred)_(${local.ecc_unsupported_blocks})",
  ]

  # ServiceMonitor-scraped metrics to DROP by name (regex). Under gpu-health this
  # defaults to the unused amd_gpu_* families above; operators can add more via
  # var.service_monitor_exclude_metrics. Empty under "full".
  sm_exclude_metrics = concat(
    local.gpu_health_profile ? local.amd_exporter_drop : [],
    var.service_monitor_exclude_metrics,
  )

  # node-exporter (host) hardware-health keep-list — regexes the chart OR-joins
  # into a single `keep` rule. Deliberately EXCLUDES node_cpu_seconds_total
  # (per-core × mode CPU utilisation — ~1.8k series on a many-core node, and not
  # a health signal) and kernel/softnet/cpufreq-cooling noise. Restore any of
  # these via var.extra_keep_node_metrics.
  node_exporter_keep = concat([
    "up",
    "node_uname_info",
    "node_boot_time_seconds",
    "node_load1", "node_load5", "node_load15",
    "node_memory_.*",              # capacity/available + HardwareCorrupted (ECC)
    "node_filesystem_avail_bytes", # disk-full / read-only signals
    "node_filesystem_size_bytes",
    "node_filesystem_free_bytes",
    "node_filesystem_readonly",
    "node_disk_.*",       # storage-device throughput / io-time
    "node_network_.*",    # NIC link, throughput, errors, drops
    "node_infiniband_.*", # RDMA / RoCE port data + errors (RDMA transfers)
    "node_hwmon_.*",      # board/CPU/NIC temperature, power, fans, voltage
    "node_thermal_zone_.*",
    "node_edac_.*",                  # ECC memory correctable/uncorrectable
    "node_cpu_core_throttles_total", # CPU thermal throttle (not utilisation)
    "node_cpu_package_throttles_total",
  ], var.extra_keep_node_metrics)

  # kube-state-metrics keep-list: node hardware/capacity plus the object-state
  # series KTLO's own dashboards/alerts reference. Everything else (pod
  # tolerations, labels, phase reasons, configmap/secret/endpoint state) drops.
  kube_state_keep = [
    "kube_node_.*",                             # info, status_condition, capacity (incl. amd.com/gpu)
    "kube_daemonset_status_.*",                 # KTLO agent DaemonSet health
    "kube_deployment_status_replicas.*",        # KTLO exporter/controller Deployments
    "kube_pod_container_status_restarts_total", # crash/restart signal
    "kube_pod_status_phase",
  ]

  # Under gpu-health: allow-list node-exporter to the hardware-health set above.
  # Merged onto linux_hosts so reuse/namespace still apply. Under "full",
  # useDefaultAllowList=true + empty include reproduces the chart's own default.
  host_metrics_tuning = {
    metricsTuning = {
      useDefaultAllowList = !local.gpu_health_profile
      includeMetrics      = local.gpu_health_profile ? local.node_exporter_keep : []
    }
  }

  # --- Host-process exporters (scrape_host_node_exporter) -------------------
  # Some clusters run node_exporter (and vendor GPU/fabric exporters) as host systemd
  # units on every node rather than as pods. The chart cannot discover those, and its
  # own Node Exporter DaemonSet (hostNetwork, port 9100) crash-loops on the bind
  # collision. This Alloy config, appended to alloy-metrics, discovers the cluster's
  # Nodes and scrapes InternalIP:<port> directly, forwarding to the same Grafana
  # Cloud destination with the same job/instance labels the chart's own Node
  # Exporter integration would set (job="integrations/node_exporter", instance=node),
  # and the same gpu-health keep-list. Extra host exporters ship unfiltered.
  # The chart passes extraConfig through Helm `tpl`, so no `{{ }}` may appear here.
  # The four host GPU/fabric exporters (scrape_host_gpu_exporters). Keep-lists are the
  # gpu-health hardware set recorded live on GB300 (docs/reference/gpu/GB300/telemetry.md):
  #   dcgm   — temps (incl. slowdown/shutdown/max-op limits), power/energy, clocks, utilisation,
  #            framebuffer, ECC volatile+aggregate, remapped rows (+pending/failure), PCIe replay,
  #            NVLink bandwidth, violation counters, the exporter's XID count, the PROF activity
  #            ratios the cost analyzer reads. Deliberately dropped: DCGM_FI_DEV_COUNT (one series
  #            per GPU/NVLink/CPU/CPU-core entity — ~220 series of nothing), vGPU licence, video
  #            encoder/decoder utilisation, python/process self-metrics.
  #   nvlink — per-GPU per-link data bytes (tx/rx); raw-frame counters are opt-in via extra keep.
  #   pcie   — AER correctable/non-fatal/fatal counts, link-width and inaccessible status per device.
  #   rdma   — every RoCE/IB counter it emits (link state, errors, ECN/CNP, retransmits, data).
  # The exporters' own python_*/process_* self-metrics never match a keep-list.
  host_gpu_exporters = var.scrape_host_gpu_exporters ? {
    dcgm = {
      port = var.host_gpu_exporter_ports.dcgm
      job  = "integrations/dcgm"
      keep = [
        "DCGM_FI_DEV_(GPU|MEMORY)_TEMP", "DCGM_FI_DEV_(GPU|MEM)_MAX_OP_TEMP",
        "DCGM_FI_DEV_(SLOWDOWN|SHUTDOWN)_TEMP",
        "DCGM_FI_DEV_POWER_USAGE", "DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION",
        "DCGM_FI_DEV_(SM|MEM)_CLOCK",
        "DCGM_FI_DEV_(GPU|MEM_COPY)_UTIL",
        "DCGM_FI_DEV_FB_(USED|FREE|RESERVED)",
        "DCGM_FI_DEV_ECC_(SBE|DBE)_(VOL|AGG)_TOTAL",
        "DCGM_FI_DEV_(CORRECTABLE|UNCORRECTABLE)_REMAPPED_ROWS", "DCGM_FI_DEV_ROW_REMAP_(FAILURE|PENDING)",
        "DCGM_FI_DEV_RETIRED_.*",
        "DCGM_FI_DEV_PCIE_REPLAY_COUNTER",
        "DCGM_FI_DEV_NVLINK_.*",
        "DCGM_FI_DEV_(CLOCKS_EVENT|CLOCK_THROTTLE)_REASONS",
        "DCGM_FI_DEV_(POWER|THERMAL|SYNC_BOOST|BOARD_LIMIT|LOW_UTIL|RELIABILITY)_VIOLATION",
        "DCGM_FI_DEV_XID_ERRORS", "DCGM_EXP_.*",
        "DCGM_FI_PROF_(GR_ENGINE_ACTIVE|SM_ACTIVE|SM_OCCUPANCY|PIPE_TENSOR_ACTIVE|DRAM_ACTIVE|PCIE_(TX|RX)_BYTES)",
      ]
    }
    nvlink = {
      port = var.host_gpu_exporter_ports.nvlink
      job  = "integrations/nvlink"
      keep = ["nvlink_data_(tx|rx)_kib_total"]
    }
    pcie = {
      port = var.host_gpu_exporter_ports.pcie
      job  = "integrations/pcie"
      keep = ["pcie_aer_.*", "pcie_bus_.*"]
    }
    rdma = {
      port = var.host_gpu_exporter_ports.rdma
      job  = "integrations/rdma"
      keep = ["rdma_.*", "ib_.*"]
    }
  } : {}

  host_exporter_targets = merge(
    { node_exporter = { port = var.host_node_exporter_port, job = "integrations/node_exporter", keep = local.node_exporter_keep } },
    local.host_gpu_exporters,
    var.extra_host_exporters,
  )

  # Targets that get a keep rule: only under gpu-health, and only when a keep-list is set.
  host_exporter_filtered = local.gpu_health_profile ? { for name, t in local.host_exporter_targets : name => t if length(t.keep) > 0 } : {}

  host_exporter_alloy_config = join("\n", concat(
    [<<-EOT
      // KTLO: host-process exporters scraped directly (no Node Exporter pods on this cluster).
      discovery.kubernetes "ktlo_host_nodes" {
        role = "node"
      }
    EOT
    ],
    [for name, t in local.host_exporter_targets : <<-EOT
      discovery.relabel "ktlo_host_${name}" {
        targets = discovery.kubernetes.ktlo_host_nodes.targets
        rule {
          source_labels = ["__meta_kubernetes_node_address_InternalIP"]
          regex         = "(.+)"
          target_label  = "__address__"
          replacement   = "$1:${t.port}"
        }
        rule {
          source_labels = ["__meta_kubernetes_node_name"]
          target_label  = "instance"
        }
        rule {
          target_label = "job"
          replacement  = "${t.job}"
        }
      }

      prometheus.scrape "ktlo_host_${name}" {
        targets    = discovery.relabel.ktlo_host_${name}.output
        job_name   = "${t.job}"
        forward_to = [${contains(keys(local.host_exporter_filtered), name) ? "prometheus.relabel.ktlo_host_${name}.receiver" : "prometheus.remote_write.grafana_cloud_metrics.receiver"}]
        clustering {
          enabled = true
        }
      }
    EOT
    ],
    [for name, t in local.host_exporter_filtered : <<-EOT
      prometheus.relabel "ktlo_host_${name}" {
        rule {
          source_labels = ["__name__"]
          regex         = "${join("|", t.keep)}"
          action        = "keep"
        }
        forward_to = [prometheus.remote_write.grafana_cloud_metrics.receiver]
      }
    EOT
    ],
  ))

  monitoring_values = {
    cluster = {
      name = var.cluster_name
    }
    destinations = {
      "grafana-cloud-metrics" = {
        type = "prometheus"
        url  = var.grafana_cloud_metrics_url
        auth = {
          type     = "basic"
          username = var.grafana_cloud_metrics_username
          password = local.push_token
        }
      }
      "grafana-cloud-logs" = {
        type = "loki"
        url  = var.grafana_cloud_logs_url
        auth = {
          type     = "basic"
          username = var.grafana_cloud_logs_username
          password = local.push_token
        }
      }
    }
    clusterMetrics = {
      enabled   = true
      collector = "alloy-metrics"
      # gpu-health turns off the sources that only produce non-health telemetry
      # (per-container cAdvisor + kubelet). "full" leaves them on (chart default).
      # Control-plane sources (apiServer/kube*) default off in the chart already.
      cadvisor        = { enabled = !local.gpu_health_profile }
      kubelet         = { enabled = !local.gpu_health_profile }
      kubeletResource = { enabled = !local.gpu_health_profile }
      "kube-state-metrics" = {
        metricsTuning = {
          useDefaultAllowList = !local.gpu_health_profile
          includeMetrics      = local.gpu_health_profile ? local.kube_state_keep : []
        }
      }
    }
    hostMetrics = {
      enabled    = true
      collector  = "alloy-metrics"
      linuxHosts = merge(local.linux_hosts, local.host_metrics_tuning)
      windowsHosts = {
        enabled = var.enable_windows_exporter
      }
      energyMetrics = {
        enabled = var.enable_kepler
      }
    }
    costMetrics = {
      enabled   = var.enable_opencost
      collector = "alloy-metrics"
    }
    clusterEvents = {
      enabled   = true
      collector = "alloy-singleton"
    }
    podLogsViaLoki = {
      enabled   = true
      collector = "alloy-logs"
    }
    prometheusOperatorObjects = {
      enabled   = true
      collector = "alloy-metrics"
      serviceMonitors = {
        labelExpressions = local.sm_label_expressions
        metricsTuning = {
          excludeMetrics = local.sm_exclude_metrics
        }
      }
    }
    collectors = {
      "alloy-metrics" = merge(
        { presets = ["clustered", "statefulset"] },
        var.scrape_host_node_exporter ? { extraConfig = local.host_exporter_alloy_config } : {},
      )
      "alloy-singleton" = {
        presets = ["singleton"]
      }
      "alloy-logs" = {
        presets = ["filesystem-log-reader", "daemonset"]
      }
    }
    collectorCommon = {
      alloy = {
        remoteConfig = {
          enabled = var.enable_fleet_management
          url     = var.grafana_cloud_fleet_url
          auth = {
            type     = "basic"
            username = var.grafana_cloud_fleet_username
            password = local.push_token
          }
        }
      }
    }
    telemetryServices = {
      "kube-state-metrics" = {
        deploy = true
      }
      "node-exporter" = {
        # Deploy our own only when NOT reusing an existing pod-based one and NOT
        # scraping a host-process one (either would collide on the host port).
        deploy = !(var.reuse_existing_node_exporter || var.scrape_host_node_exporter)
      }
      "windows-exporter" = {
        deploy = var.enable_windows_exporter
      }
      opencost = {
        deploy        = var.enable_opencost
        metricsSource = "grafana-cloud-metrics"
        opencost = {
          exporter = {
            defaultClusterId = var.cluster_name
          }
          prometheus = {
            existingSecretName = "grafana-cloud-metrics-${var.monitoring_release_name}"
            external = {
              url = local.grafana_cloud_metrics_query_url
            }
          }
        }
      }
      kepler = {
        deploy = var.enable_kepler
      }
    }
  }
}

resource "helm_release" "k8s_monitoring" {
  name             = var.monitoring_release_name
  namespace        = var.monitoring_namespace
  create_namespace = true

  repository = "https://grafana.github.io/helm-charts"
  chart      = "k8s-monitoring"
  version    = var.monitoring_chart_version

  atomic  = true
  timeout = 300

  values = [yamlencode(local.monitoring_values)]

  lifecycle {
    precondition {
      condition     = !var.scrape_host_gpu_exporters || var.scrape_host_node_exporter
      error_message = "scrape_host_gpu_exporters requires scrape_host_node_exporter = true (it reuses the host node-discovery scrape)."
    }
    precondition {
      condition     = !(var.reuse_existing_node_exporter && var.scrape_host_node_exporter)
      error_message = "reuse_existing_node_exporter (exporter runs as pods) and scrape_host_node_exporter (exporter runs as a host process) are mutually exclusive."
    }
  }
}
