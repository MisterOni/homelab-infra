# ADR-006: Recovery is restore-based, not failover-based

**Status:** accepted · 2026-07
**Supersedes nothing. Extends ADR-001.**

## Context
ADR-001 chose a single Proxmox cluster with **no HA groups and no shared
storage**; every guest is pinned to its node. That decision is still right, but
it left an unanswered question: *what actually happens when a node dies?*

The honest current answer, per layer:

| Layer | On node failure | Mechanism |
|---|---|---|
| Proxmox guests | Stay down until a human acts | No HA group, no shared storage, guests pinned |
| Live migration | Only works while **both** nodes are up | Local-disk migration copies the disk over the cluster net (10.10.10.0/24) — a *planned maintenance* tool, not a recovery tool |
| K3s pods | Reschedule across k3s-server/agent1/agent2 | …but all three VMs are `node_name = "macbook"` (`terraform/proxmox/k3s-lab.tf`). The macbook is a single failure domain; if it dies the whole "cluster" dies with it |

So: pod-level rescheduling inside K3s is real but confined to one physical host.
There is no cross-node failover anywhere in the fleet.

## Decision
Make restore-based recovery the **stated, measured** recovery path, rather than
an unstated fallback:

1. Recovery from node loss = **restore the guest from PBS onto a surviving
   node**. This is the supported path. It is manual and it is documented in
   `docs/runbooks/node-failure.md`.
2. Every node gets a **declared restore target** and a **measured** RTO. An RTO
   that has never been timed is not an RTO.
3. Capacity for the restore target is verified *before* it is needed, not
   during an outage.
4. Automatic failover (see below) is explicitly **deferred**, not rejected.

## Known capacity risk — verify this
K8 Plus (32 GB) holds the family tier. Its only restore target is G11 (16 GB),
which already runs core infra. **Jellyfin + the photo/file service may not fit
in 16 GB alongside GitLab.** Until measured, the family-tier restore procedure
is fiction. Verification is step 0 of the node-failure runbook.

## Deferred: ZFS replication + HA group
Proxmox supports asynchronous **ZFS replication** (`pvesr`) between nodes on
local ZFS — no shared storage required. Paired with an HA group, a guest can be
restarted automatically on a surviving node, with data loss bounded by the
replication interval (5–15 min RPO).

This is the only real-HA option available on this hardware, and it teaches the
concepts worth knowing: fencing, quorum behaviour, RPO-vs-RTO tradeoffs,
split-brain.

**Deferred to a later phase, deliberately.** Reasons:

- It reintroduces exactly the failure modes ADR-001 rejected (fencing storms
  when the macbook's NIC drops after reboot).
- Family workloads want predictability more than they want automation.
- The unmeasured-restore gap above is a bigger real risk than the lack of
  failover, and costs far less to close.

**When it is picked up, scope it to the lab tier only** (G11 ↔ a disposable
guest). Learn the mechanics, be able to speak to fencing in an interview, and
keep it pointed away from family data. Promote to the family tier only after
the switch upgrade (done — CRS310, see [ADR-007](007-switch-enforced-vlans.md))
and a stable macbook NIC make the third vote trustworthy. ⚠️ Note that ADR-007
adds a new prerequisite: node ports must be RSTP **edge ports**, or STP
convergence can starve corosync and cause exactly the fencing storms this
section is worried about.

## Consequences
- Recovery is minutes-to-hours and requires a human. Accepted, and now stated
  out loud instead of implied.
- The quarterly restore drill (`docs/runbooks/restore-drill.md`) stops being
  hygiene and becomes the thing that validates this ADR. An empty drill table
  means this ADR is unproven.
- "Why no HA?" has a defensible answer with a measured number behind it, which
  is a stronger position than unmeasured HA.
