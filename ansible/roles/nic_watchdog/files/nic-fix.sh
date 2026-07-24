#!/usr/bin/env bash
# MacBook USB Ethernet self-heal (ADR-002).
# The Realtek r8152 USB adapter enumerates LATE, so at boot Proxmox brings up
# vmbr0 without a working uplink and the node is unreachable. This script waits
# for the NIC, bounces it, and rebuilds bridge networking until vmbr0 has an IP.
# On a healthy boot it detects the IP immediately and exits without touching a
# thing — so it's a safe no-op except when actually needed.
set -u
MODULE="r8152"      # driver of the USB ethernet adapter (lsusb / ethtool -i nic0)
BRIDGE="vmbr0"

# Find the ethernet iface by driver, so a USB rename doesn't break us.
find_iface() {
  for n in /sys/class/net/*; do
    dev="$(basename "$n")"
    drv="$(readlink -f "$n/device/driver" 2>/dev/null || true)"
    [[ "$drv" == *"$MODULE"* ]] && { echo "$dev"; return 0; }
  done
  echo "nic0"       # fall back to the configured bridge-port name
}

healthy() { ip -4 addr show "$BRIDGE" 2>/dev/null | grep -q 'inet '; }

for i in {1..5}; do
  healthy && exit 0
  IFACE="$(find_iface)"
  echo "nic-watchdog attempt $i: $BRIDGE has no IP — healing via $IFACE"
  modprobe -r "$MODULE" 2>/dev/null || true
  sleep 1
  modprobe "$MODULE" 2>/dev/null || true
  ip link set "$IFACE" up 2>/dev/null || true
  sleep 3
  systemctl restart networking 2>/dev/null || true
  sleep 3
done

healthy && exit 0
echo "nic-watchdog: FAILED to bring up $BRIDGE after 5 attempts" >&2
exit 1
