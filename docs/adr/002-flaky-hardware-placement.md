# ADR-002: The unreliable MacBook runs only disposable workloads

**Status:** accepted · 2026-07

## Context
The MacBook's NIC frequently stays down after reboot until manually bounced.
It also has the most RAM (64 GB) — the best Kubernetes lab hardware we own.

## Decision
The MacBook hosts ONLY the lab tier (K3s, Jenkins, experiments). Nothing
family-facing. A systemd watchdog (`ansible/roles/nic_watchdog`) bounces the
NIC automatically after boot.

## Rationale
Match workload criticality to hardware reliability. A lab that dies teaches
disaster recovery; a family movie night that dies teaches the family to use
Netflix again.

## Consequences
- Monthly teardown/rebuild drills are safe — worst case is my own time.
- The NIC quirk became an automation artifact instead of a chore.
