# Network upgrade path — from software zones to real VLANs

Current switch (TL-SG108S-M2) is unmanaged. To get switch-enforced VLAN
isolation, swap it for a managed 2.5G smart switch. Candidates (verify current
price/stock before buying — 2026 snapshot):

| Model | Ports | Uplink | Managed | ~Price | Note |
|---|---|---|---|---|---|
| SODOLA 8×2.5G | 8×2.5G | 1×10G SFP+ | Web smart (VLAN/QoS) | ~US$80 | Best budget; fanless |
| TRENDnet TEG-3102WS | 8×2.5G | 2×10G SFP+ | Web, VLAN | ~US$180 | Solid homelab pick |
| TP-Link Omada SG3210X-M2 | 8×2.5G | 2×10G SFP+ | L2+, Omada SDN | ~US$200 | Non-PoE, SDN dashboard |
| TP-Link Omada SG2210XMP-M2 | 8×2.5G PoE+ | 2×10G SFP+ | Full, Omada SDN | ~US$250 | PoE for future APs/cameras |

## Target VLAN plan (build in software now, enforce after swap)
| VLAN | Name | Subnet | Contents |
|---|---|---|---|
| 10 | Family | 192.168.10.0/24 | Jellyfin, Immich, Nextcloud, family devices |
| 20 | Lab | 192.168.20.0/24 | K3s, Jenkins, experiments |
| 30 | Mgmt+Cluster | 192.168.30.0/24 | Proxmox, IPMI, corosync, PBS |
| 40 | IoT/Guest | 192.168.40.0/24 | Untrusted devices, guest wifi |

Inter-VLAN routing + firewall via an **OPNsense VM** on Proxmox (router-on-a-
stick over a tagged trunk port), or the home router if it supports VLANs.
Default policy: deny inter-VLAN, allow only explicit flows (e.g. Family→internet,
admin→all). This becomes ADR-006 when executed.
