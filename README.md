<div align="center">

# 🏠 homelab-infra

**A 3-node Proxmox homelab, rebuilt from git in under 30 minutes.**

*Family media platform + Kubernetes DevOps playground — everything as code.*

[![Proxmox](https://img.shields.io/badge/Proxmox-VE_8-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/)
[![Kubernetes](https://img.shields.io/badge/K3s-Kubernetes-326CE5?logo=kubernetes&logoColor=white)](https://k3s.io/)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-844FBA?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Ansible](https://img.shields.io/badge/Config-Ansible-EE0000?logo=ansible&logoColor=white)](https://www.ansible.com/)
[![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo&logoColor=white)](https://argoproj.github.io/cd/)
[![Uptime](https://img.shields.io/badge/family_uptime-99.9%25-brightgreen)](#-observability)

[Architecture](#%EF%B8%8F-architecture) · [Hardware](#-hardware) · [Stack](#-stack) · [Rebuild from zero](#-rebuild-from-zero) · [Design decisions](#-design-decisions) · [Roadmap](#-roadmap)

</div>

---

## Why this exists

Two problems, one cluster:

1. **My family needed a private cloud** — movies and shows on demand, phone photo backup, and file storage, without handing everything to Big Tech.
2. **I needed a production-grade DevOps lab** — a place to practise Kubernetes, GitOps, CI/CD, and infrastructure-as-code the way real teams run them, not in throwaway tutorials.

The twist that makes this interesting: **the two tiers have opposite reliability requirements.** The family tier must never go down; the lab tier is *designed* to be destroyed. So the lab node gets torn down and rebuilt from this repo — on purpose, monthly, timed. If it isn't in git, it doesn't exist.

> 🎥 **[5-minute demo video](#)** — one `git push` travels through CI, security scanning, and ArgoCD to a live Kubernetes rollout. *(link coming soon)*

## 🏗️ Architecture

```mermaid
flowchart TB
    subgraph Internet
        U[👨‍👩‍👧 Family & friends]
        CF[Cloudflare Tunnel + Access<br/>zero open router ports]
    end

    subgraph LAN["🏠 LAN — 2.5GbE switch"]
        subgraph G11["⚙️ G11 · core-infra (16 GB) — always on"]
            NPM[Nginx Proxy Manager]
            DNS[AdGuard Home DNS]
            GL[GitLab CE + Registry]
            MON[Prometheus · Grafana · Loki]
        end

        subgraph K8["🎬 K8 Plus · family-prod (32 GB) — always on"]
            JF[Jellyfin<br/>iGPU transcoding]
            IM[Immich · Nextcloud]
            ARR[Jellyseerr → Radarr/Sonarr<br/>qBittorrent ⛔ VPN kill-switch]
            PBS[(Proxmox Backup Server<br/>2×1TB HDD)]
        end

        subgraph MBP["🧪 MacBook Pro · lab (64 GB) — disposable"]
            K3S[K3s cluster · 3 VMs]
            CD[ArgoCD · GitOps]
            JK[Jenkins · JCasC]
        end
    end

    B2[(☁️ Backblaze B2<br/>encrypted off-site)]

    U --> CF --> NPM
    NPM --> JF & IM
    GL -- webhooks --> JK
    CD -- syncs from --> GL
    CD --> K3S
    MON -. scrapes all nodes .-> G11
    PBS --> B2
```

**Traffic flow:** everything public enters through a Cloudflare Tunnel (no open ports), hits one reverse proxy, and only user-facing apps are exposed. Admin planes (Proxmox, Jenkins, Grafana) are reachable via Tailscale only. GitLab sits behind Cloudflare Access.

## 🖥️ Hardware

| Node | Machine | Specs | Role | Uptime promise |
|---|---|---|---|---|
| `family-prod` | GMKtec K8 Plus | Ryzen 8845HS · 32 GB · 512 GB NVMe + 2×1 TB HDD | Media, photos, files, backups | 🟢 Always on |
| `core-infra` | GMKtec G11 | 16 GB · 256 GB SSD | Proxy, DNS, GitLab, monitoring | 🟢 Always on |
| `lab` | MacBook Pro 2019 | i9 · 64 GB · 1 TB SSD | K3s, CI/CD, experiments | 🔴 Deliberately disposable |

## 🧰 Stack

| Layer | Tools |
|---|---|
| Virtualisation | Proxmox VE 3-node cluster (quorum survives lab-node loss) |
| Provisioning | Terraform (`bpg/proxmox`) + cloud-init templates |
| Configuration | Ansible — one post-install playbook, three identical nodes |
| Containers | Docker Compose (family tier) · K3s + Helm (lab tier) |
| GitOps | ArgoCD app-of-apps — `kubectl apply` is for debugging only |
| CI/CD | GitLab CI + Jenkins (Configuration-as-Code) · Trivy image scanning |
| Observability | Prometheus · Grafana (provisioned as code) · Loki · Uptime Kuma |
| Edge & access | Cloudflare Tunnel + Access · Nginx Proxy Manager · Tailscale · AdGuard |
| Secrets | SOPS + age — nothing sensitive in git, `.env.example` everywhere |
| Backups | Proxmox Backup Server → nightly · rclone → encrypted off-site (3-2-1) |

## 📁 Repository layout

```
.
├── ansible/          # Post-install playbook + roles (network, firewall, docker, exporters, tailscale…)
├── terraform/        # VMs, LXCs, K3s cluster — the whole lab as code
├── compose/          # Family-tier stacks (media, photos, files) — one dir per stack
├── kubernetes/       # Helm values + ArgoCD Applications (app-of-apps)
├── pipelines/        # Jenkinsfiles, JCasC yaml, GitLab CI templates
├── scripts/          # Runnable documentation (storage setup, NIC fix…)
└── docs/
    ├── adr/          # Architecture Decision Records — the "why" behind everything
    └── runbooks/     # Install logs, restore drills, decommission checklists
```

## 🔄 Rebuild from zero

The lab node is rebuilt from scratch every month as a disaster-recovery drill:

```bash
terraform destroy && terraform apply   # VMs return
ansible-playbook site.yml              # nodes configured
# ArgoCD reinstalls itself, then pulls every app back from git
```

| Drill | Time | What broke |
|---|---|---|
| #1 | *(pending)* | — |

*(This table fills in as drills happen — the times should trend down and the breakage column toward "nothing".)*

## 🧠 Design decisions

The interesting choices live in [`docs/adr/`](docs/adr/). Highlights:

- **[ADR-001](docs/adr/001-cluster-topology.md)** — Why 3 nodes, why no HA/auto-failover, and how quorum survives losing the lab node
- **[ADR-002](docs/adr/002-flaky-hardware-placement.md)** — The lab runs on a MacBook whose NIC dies on reboot. That's a feature: only disposable workloads live there, and a systemd unit self-heals the NIC
- **[ADR-003](docs/adr/003-attack-surface.md)** — Public surface reduced to user-facing apps only; every admin plane moved behind zero-trust access
- **[ADR-004](docs/adr/004-git-bootstrap.md)** — Why this repo lives on GitHub even though GitLab is self-hosted: never let infrastructure code depend on the infrastructure it describes

## 📈 Observability

Every node exports metrics; every container ships logs. One Grafana instance sees everything.

<!-- Screenshots: Grafana cluster dashboard · ArgoCD app tree · Jellyfin library -->
*(screenshots coming after Phase 2)*

## 🗺️ Roadmap

- [ ] **Phase 0** — Backups verified, this repo bootstrapped
- [ ] **Phase 1** — Family tier live on K8 Plus (Jellyfin, Immich, Nextcloud, media automation) — zero-downtime cutover
- [ ] **Phase 2** — Core infra on G11 (proxy, DNS, GitLab restore, monitoring, 3-2-1 backups, edge lockdown)
- [ ] **Phase 3** — Lab rebuilt from code (K3s via Terraform/Ansible, ArgoCD, JCasC Jenkins, first commit-to-deploy pipeline)
- [ ] **Phase 4** — Monthly teardown drills · CKA
- [ ] **Phase 5** — Ephemeral cloud twin: `terraform apply` the lab onto AWS for live demos, `destroy` when done (see [terraform/aws-demo](terraform/aws-demo/))
- [ ] **Phase 6** — Portfolio showcase on [jocelynchoo.com](https://jocelynchoo.com) — demo video, live dashboards, this repo

## ✍️ Write-ups

- *Migrating my family's media platform to a 3-node Proxmox cluster — with zero downtime* (coming soon)
- *GitOps-ing my homelab with ArgoCD* (coming soon)
- *What rebuilding my lab from scratch taught me about IaC* (coming soon)

## 👋 About

I'm **Jocelyn** — building this in public while transitioning into DevOps engineering (Hong Kong).
Everything here is reproducible: clone it, read the ADRs, steal the playbooks.

[![LinkedIn](https://img.shields.io/badge/LinkedIn-connect-0A66C2?logo=linkedin)](https://www.linkedin.com/in/YOUR-PROFILE)
[![Email](https://img.shields.io/badge/email-jocelyn.choo%40gmail.com-EA4335?logo=gmail&logoColor=white)](mailto:jocelyn.choo@gmail.com)

---

<div align="center">
<sub>⚡ Powered by three small computers and an unreasonable love of automation.</sub>
</div>
