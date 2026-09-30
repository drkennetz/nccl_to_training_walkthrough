---
name: ktlo-cluster-bringup
description: Rebuild the GB300 validation Kubernetes cluster on a fresh Slurm rack (k3s via k8s_bootstrap) and reinstall the whole KTLO stack on it — GPU Operator, storage, Prometheus, Kueue, dranet, KTLO chart with the per-rack overlay, Grafana Cloud onboarding, the inference platform — then gate it. Use whenever the cluster is gone, a lease was cancelled, or a new rack is needed.
---

# GB300 cluster bring-up (k3s on leased Slurm trays + the KTLO stack)

Run from the Slurm controller as `ubuntu`. Two repos are involved:

| Repo | Path | Role |
|---|---|---|
| k8s_bootstrap | `~/dkennetz/k8s_bootstrap` | leases trays, installs k3s + Cilium, GPU Operator, storage (`bin/k8s-*`) |
| ktlo-tech | `~/dkennetz/dk_test` (`$KTLO_REPO`) | the chart, values, Prometheus/Kueue/dranet examples, the inference platform recipe, the live gates |

Everything after `k8s-up` is scripted in `install-ktlo-stack.sh` (this directory). Read the
rules first, then follow the steps in order. **A full rebuild takes ~25 min** (k8s-up 4 min,
stack 15 min, checkpoint staging 6 min).

## Rules that have bitten before

- **Foreground only.** Never `run_in_background`; the owner's terminal disconnects. Poll in
  Bash loops under 600 s (`until … || elapsed>540; do sleep 20; done`), re-issue if not done.
- **Never read secrets into context.** `~/dkennetz/.quay` (line 1 user, line 2 token),
  `~/dkennetz/.ngc` (NGC API key) and the kubeconfig are piped via `sed -n Np` / `--from-file` /
  env only. Never `cat` them, never put them on a logged command line.
- **`kubectl` needs** `export KUBECONFIG=~/.local/state/k8s-bootstrap/polite-possum/kubeconfig`
  (same path every rebuild; node names and IPs change).
- **Go is not on PATH** after a session restart: `export PATH=/usr/local/go/bin:$PATH`.
- **Install nothing while Kueue's webhook has no endpoints** (`kubectl -n kueue-system get endpoints`).
- **Restart the Prometheus pod after the KTLO chart lands**, or the agent ServiceMonitor targets stay
  missing (`kubectl -n ktlo-prometheus delete pod -l app.kubernetes.io/name=prometheus`).
- **The Kueue GPU quota must equal the GPUs the rack serves**: 68 with the control-plane tray
  tainted, 72 once it is untainted (`active.queue.nominalGpuQuota` in the overlay).
- **`helm upgrade` restores the controller's replicas.** If a gang-scheduled tenant is being placed,
  pause the sweep again: `kubectl -n ktlo scale deploy/ktlo-active --replicas=0` and delete its Jobs
  (`kubectl -n ktlo delete jobs -l ktlo-labs.ai/active-check`).
- **Do not cold-load many trays from the shared NFS (`/fss`) at once** — it is the controller's home
  file server and stalls. Tenant checkpoints go to each tray's NVMe (`run.sh stage`).
- **Rebuilding is the owner's call.** Do it when they ask (or when they have said "bring it up on
  another rack"); never lease trays unasked. Leases here get cancelled externally; the owner knows.
- **`pkill -f <pattern>`** from a tool shell kills the calling shell: use a bracket pattern (`'ru[n].sh'`).
- Record each step's time in `~/dkennetz/ktlo-reports/<epic>/timeline.txt` when an epic is in flight.

- **`bin/k8s-down` hangs at `### cordon` when the API server is dead** (a cancelled lease): move
  `~/.local/state/k8s-bootstrap/polite-possum/kubeconfig` aside first, then re-run it.

## Step 0 — confirm the old cluster is gone and the state is clean

```bash
cd ~/dkennetz/k8s_bootstrap && bin/k8s-status 2>&1 | tail -n 25
```
"API server … not responding" + no leases = gone. If a stale lease or kubeconfig lingers:
`bin/k8s-down` (move the dead kubeconfig aside first if it dies silently). `bin/k8s-verify-clean`
diffs node state against the pre-install snapshot when trays are still reachable.

## Step 1 — pick a rack and preflight it

`bin/k8s-status` lists idle racks with 18 trays. Prefer a rack with all 18 trays (an IMEX domain
with an unleased tray leaves a standing `dcgm_health` WARN). Preflight is read-only:

```bash
bin/k8s-preflight --rack <block>/<rack> --workers 17
```
If any tray fails, pick another rack — never override the gates.

## Step 2 — lease and install k3s (≈4 min)

```bash
bin/k8s-up --cluster polite-possum --rack <block>/<rack> --workers 17 --lease-time 7-00:00:00 --yes \
  > $S/k8s-up.log 2>&1   # then poll the log in the foreground until " ok up" or FAIL
export KUBECONFIG=~/.local/state/k8s-bootstrap/polite-possum/kubeconfig
kubectl get nodes --no-headers | awk '{print $2}' | sort | uniq -c    # expect 18 Ready
```
Both leases (control plane + rack) take `--lease-time`; the default rack lease is only 3 days.

## Step 3 — the stack (scripted)

```bash
KTLO_REPO=~/dkennetz/dk_test OVERLAY=<scratchpad>/live-overrides.yaml \
  ~/dkennetz/k8s_bootstrap/.claude/skills/ktlo-cluster-bringup/install-ktlo-stack.sh --untaint-control-plane --dynamo
```
The script is idempotent and numbered; `--from N` resumes, `--only N` repeats one step, `--list`
prints the steps. In order it does:

1. `bin/k8s-gpu` (device-plugin mode; the tenant requests `nvidia.com/gpu`) and `bin/k8s-platform --storage`
   (`local-path` RWO default + `nfs` RWX). Expect `nvidia.com/gpu` allocatable 4 on every worker.
2. `prometheus-community/prometheus-operator-crds` (ns `ktlo-monitor`) then the **local observability stack** in
   ns `ktlo-prometheus`: the in-cluster Prometheus release with the self-hosted example's values layered on
   (Alertmanager, Grafana with the KTLO dashboards from `render-dashboards.sh`, admin password in
   `~/dkennetz/.grafana-local`), Loki + Alloy for pod logs, `scrape-host-exporters.yaml`. Nothing leaves the
   cluster (owner 2026-09-26). Grafana: `kubectl -n ktlo-prometheus port-forward svc/ktlo-prometheus-grafana 3000:80`.
3. Kueue v0.19.4 (`kubectl apply --server-side` of the release manifests) and the GB300 manager config
   `deploy/kueue/kueue-manager-config-gb300.yaml` (device-class mappings for `gpu.nvidia.com` and `dra.net`).
4. dranet v1.4.0 (`oci://registry.k8s.io/networking/charts/dranet`, ns `dranet`, values from
   `deploy/examples/dranet/values.yaml`) + `deviceclass.yaml`. Expect 18 slices / 72 devices.
   **KTLO must not claim rail VFs on this site** (step 6 writes `gpu.rdma.nicCount: 0`): a claimed
   VF leaves the host namespace and the site's node health check — which requires every
   `rdma_vf_rail*` on the host with one address and exactly one RA default route — drained and
   rebooted three whole racks on 2026-09-24 ("RDMA Route Missing"; ktlo-tech #690). The driver
   itself stays installed and idle for sites without that coupling. Never alter the rails' RA
   default routes persistently either (same check); a driver restart after the first RA publishes
   0 devices — moot while claims are off (`node/install-rail-ra-guard.sh` is the transient remedy).

5. Namespace `ktlo` (privileged PSA) + pull secret `ktlo-quay-pull` from `~/dkennetz/.quay`.
6. **Rack facts → overlay.** Reads the clique id (`nvidia.com/gpu.clique`), the driver version and the
   rail MTU (over SSH to one tray: `GPU-<rack>-<n>` is the Slurm name of k8s node `gpu-<rack>-<n>`) and
   writes `$OVERLAY` (the kubelet device-plugin checkpoint path for the GPU→pod map, fabric_imex `expected_peers_by_domain` = tray count, `gpu_versions` driver pin,
   `rail_config.expected_mtu` pinned to whatever MTU the rack runs when it is not the 9266 standard (owner 2026-09-26; 9000 and 9050 seen), `nominalGpuQuota`, `gpu.allocation:
   device-plugin`). Racks differ: 9000 vs the fleet's 9266 MTU, 595.91.07 vs 595.71.05 driver.
7. KTLO chart from `git archive $KTLO_REF deploy/charts/ktlo` + `deploy/values-gb300.yaml` + the overlay,
   `--set release.revision=<short sha> --set agent.gpuReset.enabled=true`; then the Prometheus pod restart.
   Remediation stays `dryRun: true` (values default) — never flip it.
8. (`--grafana-cloud`, default OFF) Grafana Cloud onboarding: `deploy/terraform/onboard` → `terraform state rm helm_release.k8s_monitoring`
   (the release lived on the dead cluster) then `terraform apply` with the existing tfvars. Expect one
   Alloy pod in `ktlo-monitor`.
9. (`--dynamo`) the inference platform: `docs/examples/dynamo/platform/install.sh` with
   `DYNAMO_VERSION=1.4.1 NGC_API_KEY_FILE=~/dkennetz/.ngc PROMETHEUS_URL=<in-cluster prom> TENANT_NS=inference`.
   Creates `dynamo-system` (operator, NATS, etcd, Grove, KAI) and the `ngc-pull` secret in the tenant namespace.
10. (`--untaint-control-plane`) installs the IMEX CDI spec and containerd's `cdi.k8s.io` annotation allow-list on
    tray 0 (older bootstrap revisions did that on agents only — a multi-node rank on the server tray then fails its
    IMEX pre-check and the NVSwitch loopback check WARNs there), removes
    `node-role.kubernetes.io/control-plane:NoSchedule` so all 18 trays serve GPUs, and sets the overlay quota to 72
    (68 otherwise). Multi-node engines whose leader
    lands on that tray have segfaulted — keep the `nodeAffinity` that excludes it in the rack-scale graphs.

## Step 4 — gate before any tenant lands (the owner's rule)

```bash
cd $KTLO_REPO && scripts/live-validate.sh --report ~/dkennetz/ktlo-reports/<dir>/live-validate.json
```
Read the summary in its own step; expect 12/12 (G4/G8 may need a re-run: G8 can race the controller's own
sweep on the anchor tray). For a new rack also run the census, pausing the controller first so the sweep's
Jobs do not hold GPUs:

```bash
kubectl -n ktlo scale deploy/ktlo-active --replicas=0
scripts/active-census.sh -o ~/dkennetz/ktlo-reports/census-<rack>-<date> -P 18 --config-dir docs/active_tests/configs/GB300 \
  dcgm_diag nvbandwidth stream gemm gemm_correctness gpu_burn nccl_loopback nccl_loopback_nvswitch nccl_mesh
kubectl -n ktlo scale deploy/ktlo-active --replicas=1
```
Every tray PASS under the fleet floors in `embedded/active/GB300.json`; a tray outside them is a finding
to fix or exclude before the tenant.

## Step 5 — stage the tenant checkpoint (rack-scale inference only)

```bash
cd $KTLO_REPO/docs/examples/dynamo/rack-scale && NAMESPACE=inference ./run.sh stage   # ≈6 min for 18 trays
GPUS=72 NAMESPACE=inference ./run.sh graph                                             # pause the sweep first (gang placement)
```
Seed from Hugging Face onto one tray's NVMe, then node-to-node copies in doubling waves; `/fss` untouched.

## After it is up — record

Record the new rack, clique id, driver, MTU, lease ids and start time in the KTLO repository's
`docs/development/handoff.md` ("Current position" → Clusters) and commit it, and in the epic's `timeline.txt`.
Session memory is a convenience, not the record — the handoff page is what the next session (or another
machine) reads. Redeploys during the
epic reuse the overlay: `helm upgrade ktlo <chart> -n ktlo -f values-gb300.yaml -f $OVERLAY --set release.revision=…`.
