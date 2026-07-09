# ADR-004: This repo lives on GitHub, mirrors to self-hosted GitLab

**Status:** accepted · 2026-07

## Context
GitLab is self-hosted *inside* the infrastructure this repo describes and
rebuilds. During migration (and any disaster), GitLab may not exist.

## Decision
GitHub is the bootstrap/public home. After Phase 2, GitLab becomes the daily
driver with push-mirroring back to GitHub (public portfolio mirror).

## Rationale
Never let infrastructure code depend on the infrastructure it describes.
The repo must be reachable precisely when everything else is on fire.

## Consequences
- Public mirror doubles as the portfolio artifact.
- Secrets hygiene is mandatory from commit #1 (SOPS/.env.example), since the
  repo is destined to be public.
