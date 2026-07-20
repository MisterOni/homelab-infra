# Current state (pre-migration) — 2026-07

Single MacBook Pro running Proxmox; all services below behind one Cloudflare
tunnel. Controller: ASUS Z13. Domain: your-domain.example (web + Cloudflare Tunnel). Proton Mail is on a separate domain, your-mail.example.

## Published tunnel routes (to be reduced — see ADR-003)
| Hostname | Service | Target exposure after migration |
|---|---|---|
| npm.your-domain.example | Nginx Proxy Manager admin | Tailscale only |
| jenkins.your-domain.example | Jenkins | Tailscale only |
| proxmox.your-domain.example | Proxmox UI | Tailscale only |
| jellyfin.your-domain.example | Jellyfin | Public (stays) |
| grafana.your-domain.example | Grafana | Tailscale only |
| git.your-domain.example | GitLab | Cloudflare Access |

## Data locations
- Media: 2×1TB HDD (USB) — moving to K8 Plus
- GitLab/Jenkins/Grafana state: MacBook docker volumes — backup via scripts/macbook-backup.sh
