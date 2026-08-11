# Current state — 2026-08-11

Three-node **Proxmox VE 9** cluster (`homelab`), quorate. The K8 Plus (`family-prod`) runs
the family tier, the G11 (`core-infra`) runs DNS/proxy/logs/GitLab, and the MacBook is a
deliberately disposable lab node running a **3-node K3s cluster with ArgoCD** — workloads are
my own Helm charts, served through Traefik Ingress. Everything is provisioned with Terraform
and configured with Ansible; Docker workloads ship through the `compose_stack` role with
secrets in Vault, and Kubernetes workloads arrive via git.

Controller: ASUS Z13 (WSL Ansible control node). Web/domain: your-domain.example (Cloudflare
Tunnel). Email: Proton Mail on your-mail.example (separate domain).

## Fleet
| Node | IP | Hardware | Role |
|---|---|---|---|
| k8plus | 192.168.0.11 | GMKtec K8 Plus, Ryzen 8845HS, 32 GB, 512 GB NVMe | family-prod |
| g11 | 192.168.0.12 | GMKtec G11, 16 GB, 256 GB SSD | core-infra |
| macbook | 192.168.0.13 | MacBook Pro 2019 i9, 64 GB (T2) | disposable lab — K3s |

**Lab tier VMs** (on macbook, Terraform-provisioned): `k3s-server` .41 · `k3s-agent1` .42 ·
`k3s-agent2` .43 — 4 vCPU / 8 GB / 60 GB each.

## Live now
| Service | Where | How it runs | Exposure |
|---|---|---|---|
| Jellyfin | k8plus | LXC 200, iGPU (Radeon 780M) VAAPI transcoding | Public — Cloudflare Tunnel |
| Nextcloud + Postgres | family-vm | Docker, `compose_stack` + Vault | Public — Cloudflare Tunnel |
| **Immich** | family-vm | Docker (server/db/redis/ML), 800 GB disk from the `data` pool | **Tailscale-only** |
| CouchDB | family-vm | Docker — Obsidian LiveSync backend | Tailscale-only |
| **Jellyseerr** | media-vm | Docker — request portal, **Jellyfin SSO**, requests need approval | Public — Cloudflare Tunnel |
| Media automation | media-vm | Radarr/Sonarr/Prowlarr → qBittorrent | Internal / Tailscale |
| **Bazarr** | media-vm | Docker — subtitles for Radarr/Sonarr, not behind gluetun (needs LAN) | Internal / Tailscale |
| VPN kill-switch | media-vm | Gluetun (Windscribe WireGuard, Netherlands) | qBittorrent has zero net if VPN down |
| **qBittorrent watchdog** | media-vm | systemd timer, 3 min — restarts gluetun+qbit on DHT collapse | n/a |
| Prometheus + Grafana | monitor-vm | Docker — fleet + ZFS/SMART dashboards, **email alerting live** | Tailscale-only |
| Loki | monitor-vm | Docker — centralized logs | Tailscale-only |
| uptime-kuma | monitor-vm | Docker — external checks | Tailscale-only |
| **AdGuard Home** | monitor-vm | Docker — LAN DNS + `*.lab` rewrites | LAN + Tailscale split-DNS |
| **Nginx Proxy Manager** | monitor-vm | Docker — internal reverse proxy for `*.lab` | LAN |
| **GitLab CE** | gitlab-vm | Docker — web :8929 → `git.lab`, git-SSH :2224 | Tailscale-only |
| **GitLab Runner** | runner-vm | Docker executor via `docker.sock` — gating CI on every push | Internal |
| **K3s + ArgoCD** | macbook (.41-.43) | 3-node K3s, ArgoCD app-of-apps, workloads as Helm charts | `demo.lab` via Traefik Ingress |
| Cloudflare Tunnel | k8plus | cloudflared LXC 201 | Only Jellyfin, Nextcloud, Jellyseerr public |
| Tailscale | all nodes/VMs | **Identity-only on servers** (`--accept-routes=false --accept-dns=false`) | All admin planes |
| Proxmox Backup Server | k8plus | ZFS `backup` pool on the 1 TB USB disk | nightly backups of all guests |

## Access model (ADR-003)
- **Public surface = Jellyfin + Nextcloud + Jellyseerr**, via Cloudflare Tunnel (no open ports).
  All three are user-facing apps; no admin plane is public.
- **All admin planes** (Proxmox UI, Grafana, GitLab, Immich) are **Tailscale-only**.
- Immich is deliberately *not* public: family photos, and Cloudflare Tunnel caps request
  bodies at 100 MB on Free/Pro, which breaks large uploads anyway.
- Internal name resolution: `*.lab` → AdGuard rewrite → NPM (192.168.0.31) → service.
  Remote clients get this via **Tailscale split-DNS** (nameserver .31 restricted to `lab`).
  Inside Kubernetes, Traefik does the same job for `demo.lab`.

## Network
Fiber → living-room switch → TP-Link WiFi 7 router (192.168.0.1, DHCP/gateway) → 2.5G port →
**MikroTik CRS310-8G+2S+** (mgmt 192.168.0.2) → homelab nodes. Family devices hang off the
router directly, not through the CRS310. JetKVM on ether8 gives out-of-band console to k8plus.

VLAN migration (**ADR-007**, superseding ADR-005) is **incremental** — infra stays on
192.168.0.0/24, VLANs are added only for new zones. Phase 0 (flat baseline + mgmt IP) is done;
Phase 1 (VLAN 40 IoT/Guest) is next. Inter-VLAN routing runs **in the switch ASIC**
(hardware-offloaded L3), with policy as **switch ACLs** — not `/ip firewall filter`, which
would silently drop the traffic onto the CPU.

## Lab tier — K3s + GitOps + Helm + Ingress (live since 2026-08-05, Helm/Ingress since 2026-08-06/07)

3-node K3s cluster on the MacBook. Terraform builds the VMs (`k3s-lab.tf`); the `k3s_server` and
`k3s_agent` roles install K3s. The server generates a join token, `set_fact` publishes it, and the
agent play reads it via `hostvars`. No `docker` role — K3s ships its own containerd.

**ArgoCD** runs in-cluster, authenticated to `git.lab` with a read-only **deploy token**. One
`kubectl apply` of `kubernetes/argocd/app-of-apps.yaml` bootstraps a `root` Application, which
watches `kubernetes/argocd/apps/` — every workload after that arrives through git. `prune` and
`selfHeal` are on, so a manual `kubectl scale` gets reverted.

Workloads are **my own Helm charts** under `kubernetes/charts/` (e.g. `charts/demo-app/`). ArgoCD
detects `Chart.yaml` and renders it with `helm template` — it does not run `helm install`, so
there's no Helm release object in the cluster and no separate state to reconcile. Raw manifests
have been deleted; the chart is the only source.

`demo-app` is served at **`demo.lab`** through the Traefik that K3s installs by default — an
Ingress resource routes by Host header, with an AdGuard rewrite pointing `demo.lab` at
192.168.0.41, the same pattern as every other `*.lab` name outside the cluster. (The earlier
LoadBalancer approach never got past `<pending>`: klipper-lb binds a hostPort per node, and
Traefik already owns `:80`. Ingress is the fix, not a bigger hammer.)

⚠️ Two things are **not in git**, both bootstrap-only and both recorded in runbooks:
- The ArgoCD repo-credential Secret is applied **by hand** — you can't store the credential that
  lets ArgoCD read git *in* git.
- A `dnsConfig: options: ndots: "1"` patch on `argocd-repo-server`, fixing DNS flakiness. ArgoCD
  is installed imperatively, so a reinstall loses this until it's folded into the install step.

## CI (live since 2026-07-31)

`.gitlab-ci.yml` runs three **gating** jobs in parallel on the self-hosted runner, on every push:

| Job | Checks |
|---|---|
| `ansible-lint` | passes the **`production`** profile (one documented skip: `var-naming[no-role-prefix]`) |
| `terraform-validate` | `init -backend=false` + `validate` across `terraform/proxmox` and `terraform/aws-demo` |
| `tflint` | provider-aware linting of both Terraform directories |

GitHub Actions stays as the public smoke test (`terraform fmt`, yamllint, shellcheck, Ansible
syntax-check) and the green badge; GitLab does the deeper checks that benefit from running on the
LAN. Shared config in `.yamllint` / `.ansible-lint` so the two can't drift. Jenkins was evaluated
and dropped — GitLab CI already covers the lint/validate gating this repo needs; Jenkins is being
learned separately, via a bootcamp course, not bolted onto the lab.

**Every host is monitored:** all 13 machines (3 nodes, 5 VMs, 2 LXCs, 3 K3s nodes) export to
Prometheus. Three provisioned Grafana alert rules, delivered by email via Proton SMTP:

| Rule | Fires when |
|---|---|
| ZFS pool not ONLINE | any pool degraded, suspended, faulted, or the disk is gone |
| Disk SMART health failing | a disk's overall-health isn't `PASSED` |
| Host stopped reporting | `up{job="nodes"} == 0` for 5 minutes |

The last is **scoped to `job="nodes"`** — the lab tier scrapes under `job_name: lab`, so destroying
it during a monthly teardown drill can't page me. The two disk rules are scoped implicitly: their
metrics come from the `disk_health` role, which only runs on the Proxmox nodes.

## Restore drills (ADR-006) — first drill run 2026-08-11

Recovery here is **restore-based, not failover-based** — a claim that only means something once
it's timed. Full procedure in `docs/runbooks/restore-drill.md`.

| Date | Restored | Restore | Total | Result |
|---|---|---|---|---|
| 2026-08-11 | media-vm, 60 GB | **12m 11s** | **25m 07s** | ✅ Pass |

Restored to a temporary VMID with the NIC disconnected, verified by mounting the disk read-only
from the host: all six `*arr`-family config directories intact, `.env` preserved with correct
permissions (`0600`), `qbit-watchdog` systemd units restored, file mtimes matched the expected
snapshot. Faster than expected — PBS only pulls the chunks it needs, so the USB 2.0 backup pool
wasn't the bottleneck assumed going in.

**It also found a real gap:** cloud-init sets no console password and SSH is key-only, so a
restored guest with broken networking can't be logged into at all. Nothing failed, but it's the
kind of finding you only get from actually running the drill — a documented `init=/bin/bash`
recovery procedure now covers it until a proper fix (console password or rescue ISO) lands.

**Still untested:**
- **family-vm** — backups are ~900 GB because they include the 800 GB Immich disk. The one that
  matters most, and the one least likely to behave like media-vm did. Test separately, next.
- Cross-node restore (a k8plus guest restored onto g11)
- Off-site restore — there is no off-site copy yet; see the deferral below
- That a restored service actually **starts** — the drill verifies data, not boot, by design (NIC
  stays disconnected)

This is a different drill from the **K3s lab teardown drill** below — restore-based recovery for
the family tier vs. rebuild-from-code for the disposable lab tier. Only the first has been timed.

## Data locations
- **k8plus NVMe** → `local-zfs`: VM disks.
- **`data` pool** (1 TB M.2 2230 KIOXIA, lz4/ashift=12, ~922 GB): `data/immich` → family-vm
  `/mnt/immich`. ⚠️ **Single disk, no redundancy** — off-site backup is deliberately deferred
  (see below), not skipped.
- **USB**: sda 2 TB exFAT = media library; sdc 1 TB = ZFS `backup` pool for PBS. ⚠️ Still on a
  **bus-powered USB 2.0 hub** — physical move to a direct port on k8plus is still pending
  (recovered from a `SUSPENDED` state 2026-07-30 with `zpool clear`; that was a software fix only).
- Nextcloud: Docker volumes on family-vm.

## Not built yet
- **Trivy image scanning** in CI, and a build→push→deploy job. Today the pipeline is lint/validate
  only.
- **`hostAliases` / absolute-name fix** for the `ndots:5` DNS flakiness from pods (the `ndots:1`
  patch above is a workaround, not the permanent fix, and isn't in git).
- **VLAN 40 / 20 / 30** — see Network above; Phase 1 is next.
- **Monthly K3s teardown drill** — the rebuild-from-code path is written but has never been timed.
  Distinct from the restore drill above, which *has* been timed. An RTO that has never been
  measured is not an RTO (ADR-006).
- **family-vm restore drill** — the restore-drill table above covers media-vm only; family-vm (the
  ~900 GB one, including Immich) hasn't been tested.
- **Off-site backup** — *deliberately deferred.* Immich currently holds only photos that already
  live in iCloud, so there is an off-site second copy in practice. **Revisit the moment Immich
  ingests anything non-iCloud** (scans, SD-card video, a non-Apple device) — that content would
  have exactly one copy. iCloud is sync, not backup: a deletion propagates (30-day recovery, then
  gone). Plan if resumed: restic → Backblaze B2, covering `/mnt/immich` *and* a `pg_dump` of the
  Immich DB (albums and named faces live only in the database).
- **Jellyfin as code** — CT 200 was built by hand. `docs/runbooks/lxc-rebuild.md` captures the
  container definition; the application itself still has no role, so PBS is its recovery plan.
- **ArgoCD is installed imperatively** — it should manage its own installation declaratively, and
  fold in the `ndots` patch so a reinstall doesn't lose it.
- **No console password on restored guests** — found by the restore drill; see above.
- **`cloudflared` ships no logs** — the one component that sees every public request has no
  visibility. CT 201 is now in `lxc_hosts`, so Promtail can reach it; wiring it up is next.
- **monitor-vm is a single point of failure** — AdGuard, NPM, Prometheus, Grafana, Loki and
  uptime-kuma all live on one VM. Restarting Docker there drops LAN DNS *and* all monitoring at
  once, including the tools that would report it. Documented as a known risk; not yet mitigated.
- **Media images are pinned to `:latest`** — `compose_stack` runs `pull: always`, so any upstream
  release can hand the family a broken service (this is how a Bazarr update briefly broke). Known
  and accepted for now; pinning is next.
