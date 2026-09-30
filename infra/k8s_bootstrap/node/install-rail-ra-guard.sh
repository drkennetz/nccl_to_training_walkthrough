#!/usr/bin/env bash
# node/install-rail-ra-guard.sh -- TRANSIENTLY drop the IPv6 default routes the rail VFs learned
# from the fabric's router advertisements, right before the DRA network driver on this tray is
# restarted. RUNS ON A LEASED NODE (sudo). Nothing persists: the routes come back with the next
# RA (minutes), which is REQUIRED -- see the incident below.
#
# WHY THIS EXISTS
# The rail switches send IPv6 RAs; the host's rdma_vf_rail<N> accept the default route they
# carry, and the DRA network driver (dranet) excludes any interface holding a default route as an
# "uplink" -- a driver that (re)starts after the first RA publishes ZERO devices for the tray and
# every rail-claiming pod sits Pending ("cannot allocate all claims"; live 2026-09-23). At
# bring-up the driver starts before the first RA, so this only matters for a driver restart.
#
# INCIDENT 2026-09-24 -- WHY IT MUST NOT PERSIST
# The first version wrote a sysctl drop-in (net.ipv6.conf.{default,all}.accept_ra_defrtr=0) so the
# routes never came back. The site's node health check REQUIRES that route ("Healthcheck:: RDMA
# Route Missing"): it drained every tray of two racks in a row and rebooted them, which ended both
# Kubernetes leases (pgmjq/ayoqa 2026-09-24 04:54, kobyq/mkd4q 2026-09-24 17:27). Never make the
# rails lose their RA default route for longer than a driver restart takes.
#
# USE: run it on ONE tray, then immediately `kubectl -n dranet delete pod <that tray's driver pod>`;
# the driver starts within seconds and publishes its devices; the RA restores the route soon after.
# Never in the bring-up path (the driver starts before the RAs there), never fleet-wide, never
# with a sysctl.

set -euo pipefail
IFACE_GLOB="${RAIL_IFACE_GLOB:-rdma_vf_}"
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
if [[ "${1:-}" == "--revert" ]]; then
  # Legacy: remove the drop-in the first version wrote and restore the kernel default.
  rm -f /etc/sysctl.d/98-k8s-bootstrap-rail-ra.conf
  sysctl -q -w net.ipv6.conf.default.accept_ra_defrtr=1 net.ipv6.conf.all.accept_ra_defrtr=1 || :
  for i in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E "^${IFACE_GLOB}" || true); do
    sysctl -q -w "net.ipv6.conf.${i}.accept_ra_defrtr=1" 2>/dev/null || :
  done
  echo "rail-ra-guard: legacy drop-in removed; RA default routes return with the next RA"
  exit 0
fi
removed=0
for i in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E "^${IFACE_GLOB}" || true); do
  while read -r gw; do
    [[ -n "$gw" ]] || continue
    ip -6 route del default via "$gw" dev "$i" 2>/dev/null && removed=$((removed+1)) || :
  done < <(ip -6 route show default dev "$i" proto ra 2>/dev/null | awk '/^default via/{print $3}')
done
echo "rail-ra-guard: transiently removed ${removed} RA default route(s); restart the tray's DRA driver pod NOW -- the routes return with the next RA"
