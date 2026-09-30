# Terraform: per-customer onboarding

The **per-customer** half of the KTLO Grafana Cloud setup. One `terraform apply`
per customer:
- **mints that customer's Grafana Cloud push token** (a cloud access policy +
  token, scoped `metrics:write` + `logs:write` — correct by construction, so no
  hand-made token and no scope mistakes), and
- **installs the Alloy collector** into the customer's cluster, wired to push with
  that token.

The shared dashboards + alerting are **not** here — they're applied once from
[`../backend`](../backend).

## Onboard / offboard
- **Onboard:** `terraform apply` — mints the token, installs the collector.
- **Offboard (cluster reachable):** `terraform destroy` — revokes the customer's
  token on the Grafana side and removes their collector.
- **Offboard (lost cluster access):** delete the access policy named
  `ktlo-<customer>-<cluster>` in the **Grafana Cloud portal → Access Policies**
  (instant cut-off, no cluster access needed), then drop this workspace's state
  (`terraform workspace delete <customer>` / `terraform state rm …`).

## State: one per customer
Run each customer in **its own workspace** (or its own backend key) so
`destroy`/state changes for one customer never touch another. Because the minted
token lives in state, use a **remote encrypted backend** for anything beyond a lab.

```bash
cd deploy/terraform/onboard

# bootstrap creds — same for every customer, export once:
export TF_VAR_grafana_cloud_bootstrap_token="glc_…"   # accesspolicies:read/write + stacks:read
export TF_VAR_grafana_cloud_stack_slug="myorg"

terraform init
terraform workspace new acme            # one workspace per customer
terraform apply \
  -var customer=acme -var cluster_name=acme-prod-1 \
  -var grafana_cloud_metrics_url="https://prometheus-prod-XX-prod-REGION.grafana.net./api/prom/push" \
  -var grafana_cloud_metrics_username="1234567" \
  -var grafana_cloud_logs_url="https://logs-prod-XXX.grafana.net./loki/api/v1/push" \
  -var grafana_cloud_logs_username="2345678"
```

(Or copy `terraform.tfvars.example` → `terraform.tfvars` per customer.) The KTLO
agent/exporter/controller themselves are installed separately with Helm — see
[`../../operations/quickstart.md`](../../../docs/operations/quickstart.md).

## Bootstrap token scope
The `grafana_cloud_bootstrap_token` is one operator-held Grafana Cloud
access-policy token with `accesspolicies:read`, `accesspolicies:write`, and
`stacks:read`. It is **not** put into any cluster — Terraform uses it only to read
the stack and mint each customer's scoped push token.

## Cluster shape (nothing is assumed)
Set these per cluster to match what's already there — the defaults assume a bare
cluster:
- **`reuse_existing_node_exporter`** (default `false`). A cluster that already runs a
  Node Exporter (kube-prometheus-stack, most managed stacks — on host port 9100)
  needs this `true`, plus `existing_node_exporter_namespace` /
  `existing_node_exporter_label_selector` to point at it. Otherwise the collector's
  own Node Exporter collides on 9100. Left `false`, the collector deploys its own.
- **`scrape_host_node_exporter`** (default `false`). For clusters whose nodes run Node
  Exporter as a **host process** (a systemd unit on every node, not a pod — common on
  provider-managed GPU images, alongside vendor GPU/fabric exporters). The chart cannot
  discover a host process, and its own Node Exporter DaemonSet (hostNetwork, port 9100)
  crash-loops on the bind collision, which `atomic` then rolls back. With this `true` the
  collector deploys no Node Exporter, turns the chart's pod-discovery host-metrics feature
  off (its render-time validation requires matching pods), and appends an Alloy scrape to
  `alloy-metrics` that discovers the cluster's Nodes and scrapes `InternalIP:<port>`
  (`host_node_exporter_port`, default 9100) with the same `job="integrations/node_exporter"`
  / `instance=<node>` labels and the same `metrics_profile` keep-list. `extra_host_exporters`
  adds further host exporters (e.g. `{ dcgm = { port = 9400, job = "integrations/dcgm" } }`),
  shipped unfiltered. Mutually exclusive with `reuse_existing_node_exporter`.
- **`scrape_host_gpu_exporters`** (default `false`). Also scrape the four host GPU/fabric
  exporters common on NVIDIA GPU images — DCGM (`:9400`, job `integrations/dcgm`), NVLink
  counters (`:9600`, `integrations/nvlink`), PCIe faults (`:9700`, `integrations/pcie`) and RDMA
  counters (`:9500`, `integrations/rdma`; ports via `host_gpu_exporter_ports`). Under the
  `gpu-health` profile each carries a curated keep-list (temps and their limits, power/energy,
  clocks, utilisation, framebuffer, ECC, remapped rows, PCIe replay, NVLink bandwidth, violation
  counters, the exporter's XID count, the PROF activity ratios; per-link NVLink data bytes; AER
  and link status per PCIe device; every RoCE/IB counter) — roughly 550 series per 4-GPU tray,
  and the DCGM entity-count series (`DCGM_FI_DEV_COUNT`, one per GPU/NVLink/CPU-core entity) is
  dropped. Under `full` everything the exporters emit ships. `extra_host_exporters` entries now
  accept a `keep` list too. Requires `scrape_host_node_exporter = true`. The DCGM series keep
  their native labels (`hostname`, `gpu`, `UUID`, `pci_bus_id`, `modelName`); the collector adds
  `instance` = node name and `job`. Inventory of what the GB300 hosts expose:
  [`docs/reference/gpu/GB300/telemetry.md`](../../../docs/reference/gpu/GB300/telemetry.md).
- **`service_monitor_part_of_excludes`** (default `[]` = scrape all ServiceMonitors).
  Set to another monitoring stack's `app.kubernetes.io/part-of` label(s) to avoid
  double-shipping its series.
- **`service_monitor_exclude_labels`** (default `[]`). For noisy ServiceMonitors that
  carry **no** `part-of` label (a bundled Grafana, a cloud metrics exporter), exclude
  them by another label — each entry becomes a `NotIn`. `NotIn` keeps label-less
  monitors, so GPU/RDMA exporters (which KTLO reads) are left alone; only monitors
  that actually have the named label+value drop out. Example:
  ```hcl
  service_monitor_exclude_labels = [
    { key = "app.kubernetes.io/name", values = ["grafana", "oci-metrics-exporter"] },
    { key = "app",                    values = ["gpu-operator"] },
  ]
  ```
- **`enable_windows_exporter`** (default `false`) / **`enable_kepler`** (default
  `false`) — Windows-node metrics / per-node energy metrics. Kepler adds ~700
  series/node and energy isn't a hardware-health signal, so it's off by default.

## Metrics profile (cardinality / bill)
**`metrics_profile`** controls which scraped series actually ship to Grafana
Cloud — the main lever on your active-series count (and therefore the bill /
free-tier fit).

- **`gpu-health`** (default) — keep only **GPU and GPU-agnostic hardware-health**
  series: node-exporter thermal/power/fan/voltage (`node_hwmon_*`), RDMA/RoCE
  (`node_infiniband_*`), NIC link+throughput+errors (`node_network_*`), disk/
  filesystem, ECC (`node_edac_*`), CPU thermal-throttle counters — plus KTLO's
  own `ktlo_*` and the GPU exporter's `amd_gpu_*` (both via ServiceMonitors) and a
  small node/workload-state set from kube-state-metrics. Turns **off** per-container
  (cAdvisor), kubelet, and CPU-utilisation telemetry. Keeps a typical cluster
  **under Grafana Cloud's free-tier 10,000 active-series cap** (versus ~30k+ with
  everything on).
- **`full`** — ship everything the chart scrapes (its own default allow-lists).
  Bigger active-series bill; use only if you consume the broader k8s telemetry.

The metrics KTLO reads — `ktlo_*` (its agent/exporters) and the `amd_gpu_*` series
its GPU dashboards plot (from the AMD device-metrics-exporter) — arrive via
ServiceMonitors and are kept. `metrics_profile` tunes the noisy infra sources
(node-exporter, kube-state-metrics, cAdvisor/kubelet) and, under `gpu-health`, also
drops a few **unused** high-cardinality `amd_gpu_*` families the exporter emits but
KTLO never charts — the JPEG/VCN media engines, `amd_gpu_min_clock`/`max_clock`
(the view uses `amd_gpu_clock`), and the ECC block names this hardware does not
report. On an 8-GPU node that's the trim that pulls a real MI300X node under the
free-tier cap; temps, power, XGMI, activity, VRAM, ECC totals, and throttle
`violation_*` counters are all kept.

**Per-block ECC is partly kept** (epic #440/A4). It used to be dropped wholesale in
favour of the `_total` roll-ups, which cost the platform the ability to say UMC-vs-GFX
on a hardware-fault report — while `KTLO-GPU-ECCDEFER-01`'s own guidance turns on
exactly that distinction.

The keep-set is the blocks MI300X actually **instruments**, measured with `amd-smi metric
--ecc-block --json`: UMC, GFX, SDMA, MMHUB, XGMI_WAFL report real counts, while HDP and
PCIE_BIF report `N/A` on every GPU. ("Reads zero" would be the wrong criterion — zero is
the expected healthy value of every ECC counter, so it cannot tell unsupported from
healthy.) Those five are also what `recommendations.json` and `checks_gpu_mem.go` already
name, so on-node grading and lake ingest agree.

Cost, measured: **120 series/node** kept (3 severities x 5 blocks x 8 GPUs), **928
series/node** dropped by the whole `gpu-health` trim. A GPU node forwards roughly **4,090
series** in total once node-exporter (~2,400) and kube-state are counted, so the 10,000-series
cap fits about **two GPU nodes with essentially no headroom** (2 × ~4,090 plus cluster-level
series lands at the cap) — the trim buys headroom, it does not make the cap elastic; a third
GPU node needs a paid tier. Size accordingly before adding nodes. Add
more drops with `service_monitor_exclude_metrics`, or drop *whole* ServiceMonitors
with `service_monitor_exclude_labels` above.

Need something the profile drops? Add it back without leaving `gpu-health`:
```hcl
extra_keep_node_metrics = ["node_cpu_seconds_total"]   # e.g. restore host CPU panels
```

## Optional extras
`enable_opencost` / `enable_fleet_management` are off by default (KTLO needs
neither). Turning either on automatically adds the extra scope it needs
(`metrics:read` / `fleet-management`) to the minted token, so it won't 401.
