#!/usr/bin/env bash
# Adjust IFACE + driver to your hardware (lspci -k | grep -A3 Ethernet)
IFACE="enp3s0"
for i in {1..5}; do
  ip link show "$IFACE" | grep -q "state UP" && exit 0
  echo "NIC down, attempt $i: reloading driver + bouncing link"
  modprobe -r bcm5974 2>/dev/null || true
  ip link set "$IFACE" down; sleep 2; ip link set "$IFACE" up; sleep 5
done
exit 1
