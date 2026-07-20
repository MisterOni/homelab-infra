# ADR-005: Network segmentation on an unmanaged switch

**Status:** accepted · 2026-07

## Context
The fleet is wired through a **TP-Link TL-SG108S-M2** — an 8-port 2.5G
*unmanaged* switch. It has no VLAN support; it passes 802.1Q tags through
transparently but cannot create or enforce them. The home router owns
`192.168.0.0/24` and DHCP. Each mini PC (K8 Plus, G11) has **two 2.5G NICs**,
both patched to the switch. The MacBook lab node joins later.

Requirement: isolate three trust zones — **family services**, **DevOps lab**,
and **management/cluster** — so a compromised lab workload cannot reach family
data, and admin planes are not casually reachable.

## Decision
Segment in **software**, not at the switch, until a managed switch is added:

1. **Dual-NIC split.** NIC1 carries the LAN (`192.168.0.0/24`: management +
   services + internet). NIC2 carries an isolated **cluster/storage network**
   `10.10.10.0/24` (no gateway) for Proxmox corosync, live migration, and PBS
   backup traffic. Separation is by subnet, not by wire — both NICs share the
   unmanaged switch.
2. **Firewall zones enforced by the Proxmox host firewall (nftables).**
   - `family` zone (VMs .21–.29): reachable only via the reverse proxy; may
     reach the internet; may NOT be initiated-to by the lab zone.
   - `lab` zone (VMs .41–.49): internet + cluster net only; DROP to family zone.
   - `mgmt` (Proxmox .11–.13, monitoring .31): reachable only from the admin
     workstation / Tailscale.
3. **IPAM** (also encoded in `terraform/` and `ansible/inventory`):

   | Role | Address |
   |---|---|
   | Proxmox hosts | 192.168.0.11 / .12 / .13 |
   | Family VMs | 192.168.0.21 (family), .22 (media) |
   | Monitoring | 192.168.0.31 |
   | Lab / K3s VMs | 192.168.0.41–.43 |
   | Cluster net (NIC2) | 10.10.10.11 / .12 / .13 |

## Rationale
- An unmanaged switch cannot give true broadcast-domain isolation, but
  host-enforced zones + a dedicated cluster subnet deliver defense-in-depth and
  keep sensitive corosync/backup traffic off the family/service path.
- Enforcing at the hypervisor keeps the whole policy in git and reproducible.
- The dual NICs already exist — using NIC2 for the cluster ring is standard
  Proxmox practice and costs nothing.

## Gotcha
Never assign both NICs of a node to the **same** subnet on a flat switch — two
interfaces on one L2 subnet causes ARP flux. NIC2 lives on a *different* subnet
(`10.10.10.0/24`) with no gateway. During single-node bring-up, NIC2 stays down
until the second node exists.

## Consequences / upgrade path
- Isolation is host-enforced, not switch-enforced: a host-level firewall bug
  weakens it. Acceptable at this scale; documented honestly.
- **Future (Phase 4/5):** replace the TL-SG108S-M2 with a managed 2.5G smart
  switch, then move to real VLANs (10 Family / 20 Lab / 30 Mgmt+Cluster /
  40 IoT-Guest) with an OPNsense VM or the router doing inter-VLAN firewalling.
  Candidate hardware in `docs/network-upgrade.md`. Because the current switch
  passes tags, the VLAN config can be built and tested in software now; only
  enforcement waits on hardware.
