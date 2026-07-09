# ADR-003: Public surface = user-facing apps only

**Status:** accepted · 2026-07

## Context
Pre-migration, the Cloudflare tunnel published npm, jenkins, proxmox, jellyfin,
grafana and git subdomains of your-domain.example — admin planes were internet-reachable.

## Decision
| Exposure | Services |
|---|---|
| Public (tunnel) | Jellyfin, Immich, Nextcloud, Jellyseerr |
| Tunnel + Cloudflare Access (email OTP) | GitLab (webhooks keep working) |
| Tailscale / LAN only | Proxmox, Jenkins, Grafana, Prometheus, NPM admin, qBittorrent |

## Rationale
Admin planes are the highest-value targets and have no reason to be public.
Cloudflare Access gives GitLab a zero-trust gate without breaking CI.

## Consequences
- Phone/laptop need Tailscale for admin work away from home. Acceptable.
- Attack surface shrinks from 6 published admin/user apps to 1 gated + 4 user apps.
