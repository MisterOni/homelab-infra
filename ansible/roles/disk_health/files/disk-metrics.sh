#!/usr/bin/env bash
# Emit ZFS pool health + SMART overall-health as Prometheus metrics into
# node_exporter's textfile collector directory. Everything is wrapped in
# `timeout` because a SUSPENDED pool or a dropped USB disk can hang zpool/smartctl
# indefinitely — the whole reason we're building this. A hang must not wedge the box.
set -uo pipefail
DIR="/var/lib/prometheus/node-exporter"     # Debian node-exporter textfile dir
OUT="$DIR/disk_health.prom"
TMP="$(mktemp)"
mkdir -p "$DIR"

{
  echo "# HELP node_zfs_pool_online ZFS pool state is ONLINE (1) or not (0)."
  echo "# TYPE node_zfs_pool_online gauge"
  if command -v zpool >/dev/null 2>&1; then
    for p in $(timeout 10 zpool list -H -o name 2>/dev/null); do
      h="$(timeout 10 zpool list -H -o health "$p" 2>/dev/null)"
      [ "$h" = "ONLINE" ] && v=1 || v=0
      echo "node_zfs_pool_online{pool=\"$p\"} $v"
    done
  fi

  echo "# HELP node_smart_healthy Disk SMART overall-health PASSED (1) or failing/absent (0)."
  echo "# TYPE node_smart_healthy gauge"
  if command -v smartctl >/dev/null 2>&1; then
    while read -r dev; do
      o="$(timeout 15 smartctl -H "$dev" 2>/dev/null || timeout 15 smartctl -H -d sat "$dev" 2>/dev/null)"
      echo "$o" | grep -qiE 'PASSED|OK' && v=1 || v=0
      echo "node_smart_healthy{device=\"$dev\"} $v"
    done < <(lsblk -dnp -o NAME,TYPE | awk '$2=="disk"{print $1}')
  fi
} > "$TMP"

mv "$TMP" "$OUT"
chmod 0644 "$OUT"
