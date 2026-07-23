# Current state — 2026-07-23

The old single-MacBook setup has been retired. The **K8 Plus (`family-prod`)** is now
the live production node; the family tier runs on it, provisioned with Terraform and
configured/deployed with Ansible. The G11 and MacBook nodes are not built yet.

Controller: ASUS Z13 (WSL Ansible control node). Web/domain: your-domain.example (Cloudflare
Tunnel). Email: Proton Mail on your-mail.example (separate domain).

## Live now (on K8 Plus)
| Service | How it runs | Exposure |
|---|---|---|
| Jellyfin | LXC 200, iGPU (Radeon 780M) VAAPI transcoding | Public — jellyfin.your-domain.example |
| Nextcloud + Postgres | Docker, **Ansible `compose_stack` + Vault** (fresh install) | Public — nextcloud.your-domain.example |
| Media automation | Docker — Jellyseerr → Radarr/Sonarr → Prowlarr → qBittorrent | Internal / Tailscale |
| VPN kill-switch | Gluetun (Windscribe WireGuard, Netherlands region) | qBittorrent has zero net if VPN down |
| Cloudflare Tunnel | cloudflared LXC 201 | Only Jellyfin + Nextcloud public |
| Tailscale | subnet router (192.168.0.0/24) | All admin planes — Proxmox, etc. |
| Proxmox Backup Server | dedicated ZFS pool on the 1TB HDD | nightly backups of all guests |

## Access model (ADR-003 — done)
- **Public surface = Jellyfin + Nextcloud only**, via Cloudflare Tunnel (no open ports).
- **All admin planes** (Proxmox UI, Grafana, Jenkins, GitLab, etc.) are **Tailscale-only** —
  removed from the public tunnel.

## Data locations
- Media: 2×1TB HDD moved from the MacBook to K8 Plus (sda = 2TB exFAT "JC-Media", ~890 GB
  of Movies/TV; sdb = 1TB ext4 → ZFS `backup` pool for PBS).
- Nextcloud: Docker volumes on family-vm (fresh — no legacy data).
- Spare 1TB M.2 2230 SSD: waiting on an adapter → will become the `data` ZFS pool for Immich.

## Not built yet
- **G11 (`core-infra`)** — proxy, DNS, GitLab, centralized monitoring.
- **MacBook (`lab`)** — clean wipe → K3s cluster + ArgoCD + Jenkins (disposable lab node).
- **Immich** — waiting on the SSD.
- **Off-site backup** (Backblaze B2 / Cloudflare R2) — deferred until Immich holds real photos.
