# ADR-003: Public surface = user-facing apps only

**Status:** accepted · 2026-07 · **amended 2026-07-28 (Immich)** and **2026-07-31 (GitLab)**

## Context
Pre-migration, the Cloudflare tunnel published npm, jenkins, proxmox, jellyfin,
grafana and git subdomains of your-domain.example — admin planes were internet-reachable.

## Decision
| Exposure | Services |
|---|---|
| Public (tunnel) | Jellyfin, Nextcloud, Jellyseerr *(live 2026-07-31)* |
| Tailscale / LAN only | **GitLab**, **Immich**, Proxmox, Grafana, Prometheus, Loki, AdGuard, NPM admin, qBittorrent |

## Rationale
Admin planes are the highest-value targets and have no reason to be public.

**Immich amendment (2026-07-28):** originally slated for the public tunnel, but the family
photo library is more sensitive than the media catalogue and doesn't need to be internet-
reachable. Closed the Cloudflare hostname/Access and moved it to **Tailscale-only** — every
device that views or uploads must be on the tailnet. Bonus: this sidesteps Cloudflare's
100 MB request-body cap that was breaking large video uploads anyway.

**GitLab amendment (2026-07-31):** originally specified as *Tunnel + Cloudflare Access (email
OTP)*, on the reasoning that Access gives a zero-trust gate without breaking CI webhooks. That
was never built, and on review it shouldn't be:

- **GitLab is an admin plane by this ADR's own logic.** It holds CI runner tokens, vault-adjacent
  configuration, and eventually deploy credentials. "Admin planes have no reason to be public"
  applies to it as much as to Proxmox.
- **The access problem was already solved another way.** Tailscale split-DNS (nameserver
  192.168.0.31, restricted to the `lab` domain) makes `git.lab` resolve from anywhere on the
  tailnet — including a corporate laptop. There is no remaining need to reach it over the
  internet.
- **Self-hosted GitLab CE carries real patch obligations.** An internet-facing instance makes
  prompt upgrades a security requirement rather than a preference. Keeping it off the public
  internet removes that pressure.

**Jellyseerr note (live 2026-07-31):** specified as public from the start but only wired to the
tunnel now. It is a *user-facing* app by this ADR's categories — family members browse and request.
But it differs from Jellyfin in one way worth stating: **it holds API keys for Radarr, Sonarr and
Prowlarr**, so a compromise is a pivot into the automation stack rather than just content access.
Mitigations: authentication is **Jellyfin SSO** (one credential store, local sign-up disabled), and
non-admin requests **require approval** — so a stolen family password queues a request, it does not
command an unbounded download.

## Consequences
- Phone/laptop need Tailscale for admin work — and for Immich and GitLab — away from home.
  Acceptable; split-DNS makes it transparent.
- **Jellyseerr is the first public app that can cause internal work** (queue downloads) rather than
  only serve content. The approval workflow is what bounds that.
- Attack surface is now **3 public user apps and nothing else.** No gated admin surface at all,
  which is simpler to reason about than the original design.
- ⚠️ **Lost capability: inbound webhooks.** Nothing on the public internet can call GitLab. This
  does not bite today because:
  - GitHub↔GitLab sync uses **two push URLs on `origin`**, so one `git push` reaches both — no
    webhook required. (GitLab CE has push mirroring only; pull mirroring is a paid feature.)
  - CI runs on a self-hosted runner *inside* the LAN, which polls outbound.
- **Revisit this ADR if** a third-party service needs to trigger GitLab — e.g. Cloudflare Pages
  building the portfolio site on commit (see `docs/portfolio-site.md`). At that point the options
  are Tunnel + Cloudflare Access as originally written, or moving that one build to GitHub Actions.
