# Runbook: node failure recovery

Per ADR-006, recovery is **restore-based**. Nothing fails over on its own.
This runbook is the supported path when a node is dead or unreachable.

## Step 0 — do this BEFORE you need it (once, then re-check after big changes)

The family-tier restore is unproven until these are ticked:

- [ ] Measure actual RAM in use by the family tier on K8 Plus (`free -h`, per-guest)
- [ ] Confirm that footprint fits on G11 (16 GB) **alongside GitLab**, or decide
      what gets shut down during a K8 Plus outage (likely: stop GitLab, it is lab-tier)
- [ ] Confirm the 2×1TB HDD data path — the disks are physically attached to
      K8 Plus. A K8 Plus hardware death means the media library is not restorable
      to G11 at all, only re-attachable. Write down which failure you are covering.
- [ ] Confirm PBS backups exist and are recent for every guest listed below
- [ ] Run one restore end-to-end and log the time in `restore-drill.md`

An untimed RTO is not an RTO.

## Node map and restore targets

| Node | LAN | Tier | Guests | Restore target | Target RTO |
|---|---|---|---|---|---|
| K8 Plus | 192.168.0.11 | Family | family-vm (.21), media-vm (.22) | G11 — *degraded*, see Step 0 | TBD — measure |
| G11 | 192.168.0.12 | Core infra | GitLab, monitor-vm (.31) | K8 Plus | TBD — measure |
| MacBook | 192.168.0.13 | Lab (disposable) | k3s-server/agent1/agent2 (.41–.43), Jenkins | **None — rebuild, do not restore** | N/A |

The MacBook is disposable by ADR-002. On its failure, do not restore: run
`terraform apply` and let it rebuild. That is the whole point of that tier.

---

## 1. Triage (5 min)

1. Is it the node or the NIC? The MacBook NIC is a known offender (ADR-002).
   Check `ping 10.10.10.13` on the cluster net as well as the LAN — a node
   reachable on one and not the other is a network fault, not a dead node.
2. From a surviving node: `pvecm status`. Confirm quorum. With 2 of 3 up you
   still have quorum and a working management plane.
3. If **two** nodes are down, the survivor needs `pvecm expected 1` before you
   can start anything. Set it back afterwards.
4. Decide: recoverable (reboot, NIC bounce, PSU) vs dead (restore).

Do not skip to restore. A restore you did not need costs more than a reboot.

## 2. If the MacBook (lab tier) is down

No user-facing impact. Nothing to restore.

1. Confirm no Cloudflare tunnel ingress points at it (should already be true —
   `macbook-decommission.md`).
2. When hardware is back: boot, let the NIC watchdog do its job, verify with
   `ip -br link`.
3. Rebuild the lab: `terraform apply` in `terraform/proxmox/`, then ArgoCD
   reconciles the workloads from git.
4. If it is dead for good, the lab moves to G11 at reduced size. Note the RAM
   drop (64 GB → 16 GB) — the 3-node K3s lab will not fit; run single-node.

## 3. If G11 (core infra) is down

Impact: GitLab, monitoring. No family impact. Not an emergency — you lose
observability, so work carefully without it.

1. Restore monitor-vm from PBS onto K8 Plus. Grafana dashboards are provisioned
   from git, so a fresh VM is acceptable; only Prometheus history is lost.
2. Restore GitLab onto the MacBook if the lab node is healthy (more RAM there),
   otherwise K8 Plus.
3. Re-point DNS/AdGuard rewrites and any Cloudflare tunnel ingress at the new
   addresses. **This step is the one people forget.**
4. Verify: repo clone works, a CI job runs, Grafana is scraping.

## 4. If K8 Plus (family tier) is down — the real emergency

Impact: Jellyfin, family photos/files. Tell the family before they discover it.

1. Check Step 0 capacity notes. If GitLab is running on G11, stop it first to
   free RAM — lab tier yields to family tier, always.
2. Restore family-vm (.21) from PBS onto G11. Restore media-vm (.22) only if
   there is room; Jellyfin without its library is not much use, so confirm the
   storage story first.
3. **Storage:** the 2×1TB HDDs are attached to K8 Plus.
   - Node alive, disks fine (e.g. boot SSD failure) → move the disks to G11 and
     re-attach.
   - Disks themselves failed → this is a data-loss event, not a node-failure
     event. Go to `restore-drill.md` and the off-site B2 copy instead.
4. Re-point the reverse proxy and Cloudflare tunnel ingress at the new addresses.
5. Verify family zone firewall rules still apply on the new host — the guest
   moved nodes, and zone membership is by IP (ADR-005). Keep the same IPs.
6. Play one video end-to-end before telling the family it is fixed.

## 5. After any restore

- [ ] Log what happened, what you did, and **how long it took** in the table below
- [ ] Update the RTO column in the node map above with the real number
- [ ] Update `restore-drill.md` if the drill procedure was wrong in practice
- [ ] Fix whatever made it slower than expected — that is the week's top task
- [ ] Restore the original node when hardware is back; migrate guests home
      during a planned window (live migration works fine when both nodes are up)

## Incident log

| Date | Node | Cause | Action taken | Time to service restored | What to fix |
|---|---|---|---|---|---|
