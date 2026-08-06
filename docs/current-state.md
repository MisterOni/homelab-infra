# Current state — 2026-08-05

Three-node **Proxmox VE 9** cluster (`homelab`), quorate. The K8 Plus (`family-prod`) runs
the family tier, the G11 (`core-infra`) runs DNS/proxy/logs/GitLab, and the MacBook is a
deliberately disposable lab node now running a **3-node K3s cluster with ArgoCD**. Everything is
provisioned with Terraform and configured with Ansible; Docker workloads ship through the
`compose_stack` role with secrets in Vault, and Kubernetes workloads arrive via git.

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
| VPN kill-switch | media-vm | Gluetun (Windscribe WireGuard, Netherlands) | qBittorrent has zero net if VPN down |
| **qBittorrent watchdog** | media-vm | systemd timer, 3 min — restarts gluetun+qbit on DHT collapse | n/a |
| Prometheus + Grafana | monitor-vm | Docker — fleet + ZFS/SMART dashboards, **email alerting live** | Tailscale-only |
| Loki | monitor-vm | Docker — centralized logs | Tailscale-only |
| uptime-kuma | monitor-vm | Docker — external checks | Tailscale-only |
| **AdGuard Home** | monitor-vm | Docker — LAN DNS + `*.lab` rewrites | LAN + Tailscale split-DNS |
| **Nginx Proxy Manager** | monitor-vm | Docker — internal reverse proxy for `*.lab` | LAN |
| **GitLab CE** | gitlab-vm | Docker — web :8929 → `git.lab`, git-SSH :2224 | Tailscale-only |
| **GitLab Runner** | runner-vm | Docker executor via `docker.sock` — gating CI on every push | Internal |
| Cloudflare Tunnel | k8plus | cloudflared LXC 201 | Only Jellyfin + Nextcloud public |
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

## Network
Fiber → living-room switch → TP-Link WiFi 7 router (192.168.0.1, DHCP/gateway) → 2.5G port →
**MikroTik CRS310-8G+2S+** (mgmt 192.168.0.2) → homelab nodes. Family devices hang off the
router directly, not through the CRS310. JetKVM on ether8 gives out-of-band console to k8plus.

VLAN migration (**ADR-007**, superseding ADR-005) is **incremental** — infra stays on
192.168.0.0/24, VLANs are added only for new zones. Phase 0 (flat baseline + mgmt IP) is done;
Phase 1 (VLAN 40 IoT/Guest) is next. Inter-VLAN routing runs **in the switch ASIC**
(hardware-offloaded L3), with policy as **switch ACLs** — not `/ip firewall filter`, which
would silently drop the traffic onto the CPU.

## Lab tier — K3s + GitOps (live since 2026-08-05)

3-node K3s cluster on the MacBook. Terraform builds the VMs (`k3s-lab.tf`); the `k3s_server` and
`k3s_agent` roles install K3s. The server generates a join token, `set_fact` publishes it, and the
agent play reads it via `hostvars`. No `docker` role — K3s ships its own containerd.

**ArgoCD** runs in-cluster, authenticated to `git.lab` with a read-only **deploy token**. One
`kubectl apply` of `app-of-apps.yaml` bootstraps everything; every workload after that arrives
through git. `prune` and `selfHeal` are on, so a manual `kubectl scale` gets reverted.

`demo-app` is served at **`demo.lab`** through the Traefik that K3s installs — Ingress rule, DNS
rewrite in AdGuard, same pattern as the `*.lab` names outside the cluster.

⚠️ The ArgoCD repo-credential Secret is applied **by hand and is not in git**. You can't store the
credential that lets ArgoCD read git *in* git — every GitOps setup has this bootstrap gap.

## CI (live since 2026-07-31)

`.gitlab-ci.yml` runs three **gating** jobs in parallel on the self-hosted runner, on every push:

| Job | Checks |
|---|---|
| `ansible-lint` | passes the **`production`** profile (one documented skip: `var-naming[no-role-prefix]`) |
| `terraform-validate` | `init -backend=false` + `validate` across `terraform/proxmox` and `terraform/aws-demo` |
| `tflint` | provider-aware linting of both Terraform directories |

GitHub Actions stays as the public smoke test (`terraform fmt`, yamllint, shellcheck, Ansible
syntax-check) and the green badge; GitLab does the deeper checks that benefit from running on the
LAN. Shared config in `.yamllint` / `.ansible-lint` so the two can't drift.

**Every host is monitored:** all 13 machines (3 nodes, 5 VMs, 2 LXCs, 3 K3s nodes) export to
Prometheus. The lab tier sits in its own `job_name: lab` so monthly teardown drills don't fire
node-down alerts.

## Data locations
- **k8plus NVMe** → `local-zfs`: VM disks.
- **`data` pool** (1 TB M.2 2230 KIOXIA, lz4/ashift=12, ~922 GB): `data/immich` → family-vm
  `/mnt/immich`. ⚠️ **Single disk, no redundancy** — off-site backup is the priority now that
  it holds real photos.
- **USB**: sda 2 TB exFAT = media library; sdc 1 TB = ZFS `backup` pool for PBS.
- Nextcloud: Docker volumes on family-vm.

## Not built yet
- **Trivy image scanning** in CI, and a build→push→deploy job. Today the pipeline is lint only.
- **`hostAliases` / absolute-name fix** for the `ndots:5` DNS flakiness from pods.
- **VLAN 40 / 20 / 30** — see Network above; Phase 1 is next.
- **Monthly teardown drill** — the rebuild path is written but has never been timed. An RTO that
  has never been measured is not an RTO (ADR-006).
- **Off-site backup** — *deliberately deferred.* Immich currently holds only photos that already
  live in iCloud, so there is an off-site second copy in practice. **Revisit the moment Immich
  ingests anything non-iCloud** (scans, SD-card video, a non-Apple device) — that content would
  have exactly one copy. Plan if resumed: restic → Backblaze B2, covering `/mnt/immich` *and* a
  `pg_dump` of the Immich DB (albums and named faces live only in the database).
- **Jellyfin as code** — CT 200 was built by hand. `docs/runbooks/lxc-rebuild.md` captures the
  container definition; the application itself still has no role, so PBS is its recovery plan.
