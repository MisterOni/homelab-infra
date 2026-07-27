#!/usr/bin/env bash
# Disable Energy-Efficient Ethernet (EEE) on Intel igc NICs (i225/i226).
# EEE causes constant 2.5G link flapping on these controllers (igc driver) —
# "NIC Link is Up 2500 ... Link is Down" every 1-3s, which takes the node off the
# network. Detects igc NICs by driver, so it's a safe no-op on other hardware.
set -uo pipefail
for n in /sys/class/net/*; do
  dev="$(basename "$n")"
  drv="$(readlink -f "$n/device/driver" 2>/dev/null || true)"
  [[ "$drv" == *igc* ]] || continue
  /usr/sbin/ethtool --set-eee "$dev" eee off 2>/dev/null || true
  echo "nic-tuning: disabled EEE on $dev"
done
