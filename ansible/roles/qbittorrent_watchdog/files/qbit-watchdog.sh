#!/usr/bin/env bash
# qBittorrent-behind-gluetun self-heal. If qbit is stuck (DHT collapsed or
# disconnected) for 2 checks running, restart gluetun + qbittorrent.
set -u

API="http://localhost:8080/api/v2/transfer/info"
STACK_DIR="/home/ubuntu/stacks/media"
STATE="/run/qbit-watchdog.fails"   # streak counter (tmpfs → clears on reboot)
NEEDED=2                            # consecutive bad checks before we act

# 1. Ask qbit how it's doing (-f = fail to empty output on HTTP errors).
JSON=$(curl -sf --max-time 10 "$API" || true)

# 2. Pull the fields — echo the VARIABLE into jq; fields start with a dot;
#    "// x" is the fallback if the field (or the whole JSON) is missing.
STATUS=$(echo "$JSON" | jq -r '.connection_status // "unknown"' 2>/dev/null)
DHT=$(echo "$JSON"    | jq -r '.dht_nodes // 0'                2>/dev/null)

# 3. Is it unhealthy?
BAD=false
if [ -z "$JSON" ]; then
  BAD=true                                   # curl failed → qbit/API unreachable
elif [ "$STATUS" = "disconnected" ] || [ "$DHT" -lt 1 ]; then
  BAD=true
fi

# 4. Debounce, then act.
if [ "$BAD" = true ]; then
  COUNT=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$COUNT" > "$STATE"
  echo "qbit-watchdog: UNHEALTHY (status=$STATUS dht=$DHT) — strike $COUNT/$NEEDED"
  if [ "$COUNT" -ge "$NEEDED" ]; then
    echo "qbit-watchdog: restarting gluetun + qbittorrent"
    cd "$STACK_DIR" && docker compose restart gluetun qbittorrent
    rm -f "$STATE"
  fi
else
  echo "qbit-watchdog: healthy (status=$STATUS dht=$DHT)"
  rm -f "$STATE"                              # good check → reset the streak
fi