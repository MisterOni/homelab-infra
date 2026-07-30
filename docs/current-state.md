# Current state — 2026-07-30

Three-node **Proxmox VE 9** cluster (`homelab`), quorate. The K8 Plus (`family-prod`) runs
the family tier, the G11 (`core-infra`) runs DNS/proxy/logs/GitLab, and the MacBook is a
deliberately disposable lab node. Everything is provisioned with Terraform and configured
with Ansible; Docker workloads ship through the `compose_stack` role with secrets in Vault.

Controller: ASUS Z13 (WSL Ansible control node). Web/domain: your-domain.example (Cloudflare
Tunnel). Email: Proton Mail on your-mail.example (separate domain).

## Fleet
| Node | IP | Hardware | Role |
|---|---|---|---|
| k8plus | 192.168.0.11 | GMKtec K8 Plus, Ryzen 8845HS, 32 GB, 512 GB NVMe | family-prod |
| g11 | 192.168.0.12 | GMKtec G11, 16 GB, 256 GB SSD | core-infra |
| macbook | 192.168.0.13 | MacBook Pro 2019 i9, 64 GB (T2) | disposable lab |

## Live now
| Service | Where | How it runs | Exposure |
|---|---|---|---|
| Jellyfin | k8plus | LXC 200, iGPU (Radeon 780M) VAAPI transcoding | Public — Cloudflare Tunnel |
| Nextcloud + Postgres | family-vm | Docker, `compose_stack` + Vault | Public — Cloudflare Tunnel |
| **Immich** | family-vm | Docker (server/db/redis/ML), 800 GB disk from the `data` pool | **Tailscale-only** |
| CouchDB | family-vm | Docker — Obsidian LiveSync backend | Tailscale-only |
| Media automation | media-vm | Jellyseerr → Radarr/Sonarr/Prowlarr → qBittorrent | Internal / Tailscale |
| VPN kill-switch | media-vm | Gluetun (Windscribe WireGuard, Netherlands) | qBittorrent has zero net if VPN down |
| **qBittorrent watchdog** | media-vm | systemd timer, 3 min — restarts gluetun+qbit on DHT collapse | n/a |
| Prometheus + Grafana | monitor-vm | Docker — fleet + ZFS/SMART dashboards, **email alerting live** | Tailscale-only |
| Loki | monitor-vm | Docker — centralized logs | Tailscale-only |
| uptime-kuma | monitor-vm | Docker — external checks | Tailscale-only |
| **AdGuard Home** | monitor-vm | Docker — LAN DNS + `*.lab` rewrites | LAN + Tailscale split-DNS |
| **Nginx Proxy Manager** | monitor-vm | Docker — internal reverse proxy for `*.lab` | LAN |
| **GitLab CE** | gitlab-vm | Docker — web :8929 → `git.lab`, git-SSH :2224 | Tailscale-only |
| Cloudflare Tunnel | k8plus | cloudflared LXC 201 | Only Jellyfin + Nextcloud public |
| Tailscale | all nodes/VMs | **Identity-only on servers** (`--accept-routes=false --accept-dns=false`) | All admin planes |
| Proxmox Backup Server | k8plus | ZFS `backup` pool on the 1 TB USB disk | nightly backups of all guests |

## Access model (ADR-003)
- **Public surface = Jellyfin + Nextcloud only**, via Cloudflare Tunnel (no open ports).
- **All admin planes** (Proxmox UI, Grafana, GitLab, Immich) are **Tailscale-only**.
- Immich is deliberately *not* public: family photos, and Cloudflare Tunnel caps request
  bodies at 100 MB on Free/Pro, which breaks large uploads anyway.
- Internal name resolution: `*.lab` → AdGuard rewrite → NPM (192.168.0.31) → service.
  Remote clients get this via **Tailscale split-DNS** (nameserver .31 restricted to `lab`).

## Network
Fiber → living-room switch → TP-Link WiFi 7 router (192.168.0.1, DHCP/gateway) → 2.5G port →
**MikroTik CRS310-8G+2S+** (mgmt 192.168.0.2) → homelab nodes. Family devices hang off the
router directly, not through the CRS310. JetKVM on ether8 gives out-of-band console to k8plus.

VLAN migration (ADR-005) is **incremental** — infra stays on 192.168.0.0/24, VLANs are added
only for new zones. Phase 0 (flat baseline + mgmt IP) is done; Phase 1 (VLAN 40 IoT/Guest) is next.

## Data locations
- **k8plus NVMe** → `local-zfs`: VM disks.
- **`data` pool** (1 TB M.2 2230 KIOXIA, lz4/ashift=12, ~922 GB): `data/immich` → family-vm
  `/mnt/immich`. ⚠️ **Single disk, no redundancy** — off-site backup is the priority now that
  it holds real photos.
- **USB**: sda 2 TB exFAT = media library; sdc 1 TB = ZFS `backup` pool for PBS.
- Nextcloud: Docker volumes on family-vm.

## Not built yet
- **CI** — GitLab Runner + first pipeline (runner-vm reserved at 192.168.0.25). **Next up.**
- **MacBook lab tier** — K3s + ArgoCD, first commit-to-deploy pipeline.
- **Off-site backup** (Backblaze B2 / Cloudflare R2) — now blocking, see `data` pool above.
- **VLAN 40 / 20 / 30** — see Network above.
