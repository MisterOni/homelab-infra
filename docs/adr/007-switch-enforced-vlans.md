# ADR-007: Switch-enforced VLANs with hardware-offloaded L3 on the CRS310

**Status:** accepted · 2026-07
**Supersedes the *mechanism* of [ADR-005](005-network-segmentation.md); keeps its trust
model.** ADR-005's zones (family / lab / mgmt) are unchanged — only where they are
enforced changes.

## Context

ADR-005 was written for an **unmanaged** TP-Link TL-SG108S-M2. With no VLAN support at
the switch, segmentation had to happen in software: separate subnets on the two NICs plus
Proxmox host firewall (nftables) zones. That was the right call for the hardware.

The hardware changed. The fleet now runs a **MikroTik CRS310-8G+2S+IN** (RouterOS,
`192.168.0.2`, in since Session 8): 8 × 2.5 GbE + 2 × SFP+, Marvell **98DX226S** switch
ASIC with a dual-core 800 MHz ARM CPU. Phase 0 (flat managed switch, mgmt IP, JetKVM on
ether8) is done. VLAN 40 (IoT/Guest) is next.

ADR-005's upgrade path said the swap would be followed by real VLANs with "an OPNsense VM
or the router doing inter-VLAN firewalling." That plan predates knowing what this
particular ASIC can do, and it is now the wrong plan.

**What did *not* change:** link speed. Every RJ45 port is still 2.5 Gbps. The managed
switch buys isolation and routing capability, not bandwidth.

## Decision

### 1. VLANs are enforced at the switch, incrementally

Bridge `vlan-filtering` on the CRS310, phased so a bad config cannot take the family
offline. Infra stays on `192.168.0.0/24`; VLANs are added for *new* zones only.

| VLAN | Name | Subnet | Contents | Phase |
|---|---|---|---|---|
| — | flat (legacy) | 192.168.0.0/24 | Existing infra + family services | ✅ live |
| 40 | IoT / Guest | 192.168.40.0/24 | Untrusted devices, guest wifi | ⏭️ next |
| 20 | Lab | 192.168.20.0/24 | K3s, Jenkins, experiments | planned |
| 30 | Mgmt + cluster | 192.168.30.0/24 | Proxmox, corosync, PBS (NIC2) | planned |

All three nodes already have VLAN-aware `vmbr0`, so tagging a guest is a NIC setting.

### 2. Inter-VLAN routing happens **on the switch**, in hardware — not on an OPNsense VM

The 98DX226S does **hardware-offloaded L3 routing**: it routes between VLANs in the ASIC
at wire speed, without touching the ARM CPU.

Router-on-a-stick via an OPNsense VM is rejected because:

- **Hairpin.** Traffic would go *up* the tagged trunk to the VM and *back down* the same
  2.5G cable — crossing it twice. Effective inter-VLAN throughput ≈ **1.25 Gbps**, half
  of line rate, for the sake of a hop that the switch can do for free.
- **Single point of failure.** A VM would become the thing the entire house's inter-VLAN
  traffic depends on. Per ADR-006 the recovery posture is restore-based and manual — an
  hour of "the internet is broken for the family" while a router VM is restored from PBS
  is not an acceptable failure mode for a shared home network.
- The switch is already a SPOF; adding a second one below it buys nothing.

### 3. Policy is expressed as **switch ACL rules**, not `/ip firewall filter` ⭐⭐

This is the load-bearing detail of this ADR.

On CRS3xx, bridge STP/RSTP, IGMP snooping and **`vlan-filtering` do not disable hardware
offload** (true since RouterOS v6.42). But **`/ip firewall filter` is CPU-based.** The
moment ADR-005's "deny inter-VLAN by default" is written as firewall rules, that traffic
is punted out of the ASIC and onto an 800 MHz dual-core ARM — which is nowhere near 2.5G
capable. The result is not an error; it is silent, mystifying slowness.

Switch ACLs express the same policy and stay in silicon. Our policy is simple L3/L4
allow-listing, which is exactly what ACLs are for.

### 4. The Proxmox host firewall stays

Host-enforced nftables zones from ADR-005 are **not** removed once VLANs land. Two
independent layers: a switch ACL misconfiguration does not silently open family data to
the lab tier, and vice versa. Defense in depth is the whole point of doing this.

### 5. Node ports are RSTP **edge ports**

RouterOS bridges run RSTP by default. A port state change can stall forwarding for
~30 seconds — long enough for corosync to lose its ring, a node to be declared dead, and
the cluster to react. This failure mode **did not exist** on the unmanaged TP-Link.

Given this fleet's history — the Intel i226 link-flap loop on k8plus (fixed with EEE off
in the `nic_tuning` role) and the MacBook's NIC dying on reboot (ADR-002) — link
transitions are a normal event here, not a rare one. Every port facing a node or a VM
host is configured as an edge port.

### 6. Switch config is versioned

The CRS310 is now infrastructure that the whole fleet depends on, and it is the only part
configured by clicking in Winbox. A `/export` of the running config is committed to this
repo. Per ADR-004's principle, that export lives on GitHub — recovering the switch must
not require the network the switch provides.

## Rationale

- Hardware offload turns the throughput argument on its head: the *simpler* topology
  (route on the switch) is also the *faster* one. Choosing OPNsense would mean paying
  half the bandwidth and adding a failure domain for a stateful firewall this network
  does not need internally.
- ADR-005's trust model was always the durable part; the enforcement point was always
  going to move. This ADR moves it without re-litigating the zones.

## Gotchas

- ⚠️ **Lockout.** Enabling `vlan-filtering` without the management VLAN configured first
  will cut you off from `192.168.0.2`. Lifelines in order: RouterOS **Safe Mode**
  (auto-undoes on disconnect) → **Winbox-by-MAC** (L2, works regardless of IP) → JetKVM
  (*k8plus console only — it cannot reach the switch*). Do Phase 1 with physical access
  available.
- ⚠️ **Offload is silent when it breaks.** Nothing errors; throughput just collapses.
  Verify after every change: bridge ports should show the hardware-offload (`H`) flag,
  and — the real test — **switch CPU should stay near idle while pushing inter-VLAN
  traffic**. A busy CPU during an `iperf3` run means the traffic is being routed in
  software and a rule needs rewriting as an ACL.
- ⚠️ **Do not put chatty pairs in different VLANs.** Same-VLAN traffic never leaves the
  switch fabric. Jellyfin and its media storage belong together.
- The two SFP+ ports remain unused — nothing in the fleet has a 10G interface.

## Consequences

- The CRS310 becomes **critical infrastructure**: a config error takes the homelab and
  potentially the family services offline. Mitigated by phasing, Safe Mode, and a
  committed config export — not eliminated.
- **Switch ACLs are less expressive than a stateful firewall.** No connection tracking,
  no IDS/IPS, coarser logging. Accepted for internal zone policy. If VLAN 40 later needs
  real inspection of guest/IoT traffic, an OPNsense VM can be reintroduced *for that one
  VLAN* without disturbing the rest — the hybrid stays available.
- Every future firewall change carries a new question that did not exist before: *does
  this stay in hardware?* That question belongs in the Phase 1 runbook.
- ADR-005 becomes historical. It is kept, not deleted: "we segmented in software because
  the switch couldn't, then moved enforcement down when it could" is the more useful
  story than pretending the current design was obvious.
