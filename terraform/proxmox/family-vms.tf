# Family tier on the K8 Plus — created once, changed rarely.
locals {
  family_vms = {
    # data_disk = extra SSD-backed disk (GB) from the `data` ZFS pool → Immich photo library.
    family-vm  = { node = "k8plus", vmid = 121, ip = "192.168.0.21", cores = 4, mem = 12288, disk = 100, data_disk = 800 }
    media-vm   = { node = "k8plus", vmid = 122, ip = "192.168.0.22", cores = 4, mem = 4096, disk = 60 }
    runner-vm  = { node = "k8plus", vmid = 123, ip = "192.168.0.25", cores = 2, mem = 4096, disk = 40 } // 23=jellyfin 24=cloudflare
    monitor-vm = { node = "g11", vmid = 131, ip = "192.168.0.31", cores = 2, mem = 4096, disk = 40 }
    gitlab-vm  = { node = "g11", vmid = 132, ip = "192.168.0.32", cores = 4, mem = 8192, disk = 80 }
  }
}

resource "proxmox_virtual_environment_vm" "family" {
  for_each  = local.family_vms
  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vmid

  clone {
    vm_id = var.template_id
    # Template 9000 lives on k8plus. For VMs on other nodes (monitor-vm on g11)
    # set the source node so Proxmox does a cross-node clone. full stays true
    # (the provider default the existing VMs were built with) so k8plus VMs show
    # NO change — only node_name varies.
    node_name = each.value.node == "k8plus" ? null : "k8plus"
    full      = true
  }

  cpu {
    cores = each.value.cores
    # Pass host CPU flags into the guest. Proxmox's default kvm64 model lacks
    # x86-64-v2 (SSE4.2, POPCNT…), which makes Immich's ML container crash-loop:
    # "NumPy was built with baseline optimizations (X86_V2) but your machine
    # doesn't support (X86_V2)". No live migration here, so `host` is safe.
    type = "host"
  }

  memory {
    dedicated = each.value.mem
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "scsi0"
    size         = each.value.disk
  }

  # Second disk on the SSD-backed `data` pool — only VMs with data_disk set (family-vm).
  # Immich's photo library lives here; the OS disk stays on local-zfs.
  dynamic "disk" {
    for_each = try(each.value.data_disk, 0) > 0 ? [each.value.data_disk] : []
    content {
      datastore_id = "data"
      interface    = "scsi1"
      size         = disk.value
    }
  }

  agent {
    enabled = true
  }

  initialization {
    datastore_id = "local-zfs"
    # Static IP but NO DNS was the July 25 bug — a reboot left VMs unable to resolve.
    # cloud-init DNS is first-boot only, so this fixes FUTURE VMs; existing ones are
    # fixed live via netplan/resolvectl.
    #
    # AdGuard (monitor-vm, .31) MUST come first: it holds the *.lab rewrites that
    # point at NPM. Pointing at the router (.1) instead means internal names never
    # resolve — e.g. the GitLab runner can't reach git.lab to register.
    # 1.1.1.1 stays as fallback so a monitor-vm outage doesn't blind every guest.
    dns {
      servers = ["192.168.0.31", "1.1.1.1"]
    }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "192.168.0.1"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_pubkey]
    }
  }
}
