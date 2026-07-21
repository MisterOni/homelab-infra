# Family tier on the K8 Plus — created once, changed rarely.
locals {
  family_vms = {
    family-vm  = { node = "k8plus", vmid = 121, ip = "192.168.0.21", cores = 4, mem = 8192, disk = 100 }
    media-vm   = { node = "k8plus", vmid = 122, ip = "192.168.0.22", cores = 4, mem = 4096, disk = 60 }
    monitor-vm = { node = "g11", vmid = 131, ip = "192.168.0.31", cores = 2, mem = 4096, disk = 40 }
  }
}

resource "proxmox_virtual_environment_vm" "family" {
  for_each  = local.family_vms
  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vmid

  clone {
    vm_id = var.template_id
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.mem
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "scsi0"
    size         = each.value.disk
  }

  agent {
    enabled = true
  }

  initialization {
    datastore_id = "local-zfs"
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
