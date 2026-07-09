# Runbook: VPN kill-switch verification (run BEFORE adding any torrent)

1. `docker exec qbittorrent curl -s ifconfig.me` → must print the **VPN** IP,
   not the home IP. Compare with `curl -s ifconfig.me` from the host.
2. `docker stop gluetun` → `docker exec qbittorrent curl -s --max-time 5 ifconfig.me`
   → must **time out**. No fallback to the real connection.
3. `docker start gluetun` → wait 30s → traffic resumes through VPN.
4. In qBittorrent settings, bind the network interface to `tun0` as a second layer.

Record date + result below each run.

| Date | VPN IP seen | Kill-switch blocked? | Notes |
|---|---|---|---|
