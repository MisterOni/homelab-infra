# Runbook: MacBook decommission checklist (gate for Phase 3)

Do NOT wipe until every box is ticked:

- [ ] `scripts/macbook-backup.sh` run, archives test-extracted, copied to 2 locations
- [ ] GitLab restored on G11, repos cloneable, CI runs, users can log in
- [ ] Grafana dashboards live on monitor-vm (provisioned from git)
- [ ] Jellyfin serving from K8 Plus for ≥1 week without complaints
- [ ] Cloudflare tunnel config shows ZERO ingress rules pointing at the MacBook
- [ ] DNS/AdGuard rewrites point nowhere near the MacBook
- [ ] Final `zfs snapshot` / disk image taken and stored on backup pool
