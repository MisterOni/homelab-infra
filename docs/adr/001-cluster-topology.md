# ADR-001: Three-node Proxmox cluster, no HA

**Status:** accepted · 2026-07

## Context
Three machines: GMKtec K8 Plus (32 GB, family services + 2×1TB HDD), GMKtec G11
(16 GB, core infra), MacBook Pro 2019 (64 GB, lab; NIC unreliable after reboot).

## Decision
One Proxmox cluster for a single management plane, but **no HA groups** and no
shared storage. Every guest is pinned to its node.

## Rationale
- Quorum needs 2 of 3 votes → cluster survives the MacBook being down/rebooting.
- HA without shared storage and reliable nodes creates failure modes worse than
  the outages it prevents (fencing storms, split-brain risk).
- Family workloads need *predictability*, not automatic migration.

## Consequences
- K8 Plus is a single point of failure for family data → mitigated by nightly
  PBS backups + weekly encrypted off-site sync (3-2-1), not by clustering.
- If two nodes are ever down, management of the third needs `pvecm expected 1`.
