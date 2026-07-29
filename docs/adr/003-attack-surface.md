# ADR-003: Public surface = user-facing apps only

**Status:** accepted · 2026-07

## Context
Pre-migration, the Cloudflare tunnel published npm, jenkins, proxmox, jellyfin,
grafana and git subdomains of your-domain.example — admin planes were internet-reachable.

## Decision
| Exposure | Services |
|---|---|
| Public (tunnel) | Jellyfin, Nextcloud, Jellyseerr |
| Tunnel + Cloudflare Access (email OTP) | GitLab (webhooks keep working) |
| Tailscale / LAN only | **Immich**, Proxmox, Jenkins, Grafana, Prometheus, NPM admin, qBittorrent |

## Rationale
Admin planes are the highest-value targets and have no reason to be public.
Cloudflare Access gives GitLab a zero-trust gate without breaking CI.

**Immich update (2026-07-28):** originally slated for the public tunnel, but the family
photo library is more sensitive than the media catalogue and doesn't need to be internet-
reachable. Closed the Cloudflare hostname/Access and moved it to **Tailscale-only** — every
device that views or uploads must be on the tailnet. Bonus: this sidesteps Cloudflare's
100 MB request-body cap that was breaking large video uploads anyway.

## Consequences
- Phone/laptop need Tailscale for admin work — and now for Immich — away from home. Acceptable.
- Attack surface shrinks to **3 public user apps + 1 gated (GitLab)**; everything else, photos
  included, is reachable only over the tailnet.
