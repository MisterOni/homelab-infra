# Network upgrade path — ✅ COMPLETE (2026-07)

> **This document is closed.** It existed to choose a managed 2.5G switch. That choice was
> made and executed: the fleet runs a **MikroTik CRS310-8G+2S+IN** as of Session 8.
>
> - Current design → [`network.md`](network.md)
> - VLAN + routing decisions → [`adr/007-switch-enforced-vlans.md`](adr/007-switch-enforced-vlans.md)
> - Why software zones came first → [`adr/005-network-segmentation.md`](adr/005-network-segmentation.md)
>
> Kept for the decision trail, not as guidance.

## What was chosen, and why it wasn't on the shortlist

The 2026 shortlist below was all 8×2.5G web-smart switches. The CRS310-8G+2S+IN won on a
capability none of them were evaluated for: **hardware-offloaded Layer 3 routing** in the
Marvell 98DX226S ASIC. That single feature removed the need for an OPNsense router VM and
the ~50% inter-VLAN throughput penalty that came with it — see ADR-007.

**Lesson worth keeping:** the shortlist was built around "does it do VLANs?" when the
question that actually mattered was "*where does inter-VLAN traffic get routed, and at
what speed?*" Every candidate below does VLANs. Not all of them route in hardware.

## Original shortlist (2026 snapshot — historical)

| Model | Ports | Uplink | Managed | ~Price | Note |
|---|---|---|---|---|---|
| SODOLA 8×2.5G | 8×2.5G | 1×10G SFP+ | Web smart (VLAN/QoS) | ~US$80 | Best budget; fanless |
| TRENDnet TEG-3102WS | 8×2.5G | 2×10G SFP+ | Web, VLAN | ~US$180 | Solid homelab pick |
| TP-Link Omada SG3210X-M2 | 8×2.5G | 2×10G SFP+ | L2+, Omada SDN | ~US$200 | Non-PoE, SDN dashboard |
| TP-Link Omada SG2210XMP-M2 | 8×2.5G PoE+ | 2×10G SFP+ | Full, Omada SDN | ~US$250 | PoE for future APs/cameras |
| **MikroTik CRS310-8G+2S+IN** | **8×2.5G** | **2×10G SFP+** | **RouterOS v7, L3 HW offload** | — | ✅ **chosen** |

## Original VLAN plan

Superseded by the phased table in ADR-007 — notably VLAN 10 was dropped, since existing
infra stays on the flat `192.168.0.0/24` rather than being re-IP'd.

| VLAN | Name | Subnet | Contents |
|---|---|---|---|
| ~~10~~ | ~~Family~~ | ~~192.168.10.0/24~~ | dropped — infra stays flat |
| 20 | Lab | 192.168.20.0/24 | K3s, Jenkins, experiments |
| 30 | Mgmt+Cluster | 192.168.30.0/24 | Proxmox, corosync, PBS |
| 40 | IoT/Guest | 192.168.40.0/24 | Untrusted devices, guest wifi |
