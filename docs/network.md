# Network design

Physical: home router → **TP-Link TL-SG108S-M2** (8-port 2.5G, *unmanaged*).
Each mini PC has 2× 2.5G NICs, both to the switch. See ADR-005 for the reasoning.

```mermaid
flowchart TB
    ISP[🌐 Home router<br/>192.168.0.1 · DHCP+gateway]
    SW[TP-Link TL-SG108S-M2<br/>8-port 2.5G · UNMANAGED]

    ISP -- black uplink --> SW

    subgraph K8["K8 Plus · family-prod"]
      K8n1[NIC1 · 192.168.0.11]
      K8n2[NIC2 · 10.10.10.11]
    end
    subgraph G11["G11 · core-infra"]
      G1n1[NIC1 · 192.168.0.12]
      G1n2[NIC2 · 10.10.10.12]
    end
    subgraph MBP["MacBook · lab (later)"]
      Mn1[NIC1 · 192.168.0.13]
    end

    SW --- K8n1
    SW --- K8n2
    SW --- G1n1
    SW --- G1n2
    SW --- Mn1

    subgraph ZONES["Software zones — Proxmox firewall (nftables)"]
      FAM[👨‍👩‍👧 family<br/>.21 .22 · via proxy only]
      LAB[🧪 lab<br/>.41-.43 · DROP → family]
      MGMT[🔒 mgmt<br/>hosts + .31 · Tailscale only]
    end

    K8n1 -.serves.-> FAM
    MBP -.hosts.-> LAB
    K8n2 === G1n2
    classDef cluster fill:#eef,stroke:#88a;
    class K8n2,G1n2 cluster;
```

**Two planes:**
- **192.168.0.0/24 (NIC1):** management, services, internet. The only plane the
  router and family devices see.
- **10.10.10.0/24 (NIC2, no gateway):** Proxmox cluster (corosync ring 0),
  live migration, and PBS backup traffic — kept off the service path.

Config lives in `ansible/roles/proxmox_network/` and is applied by `site.yml`.
