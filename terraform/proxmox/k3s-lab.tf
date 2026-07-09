# The disposable lab — destroyed and rebuilt monthly ON PURPOSE.
# terraform destroy -target=proxmox_virtual_environment_vm.k3s
locals {
  k3s_nodes = {
    k3s-server = { vmid = 141, ip = "192.168.1.41" }
    k3s-agent1 = { vmid = 142, ip = "192.168.1.42" }
    k3s-agent2 = { vmid = 143, ip = "192.168.1.43" }
  }
}

resource "proxmox_virtual_environment_vm" "k3s" {
  for_each  = local.k3s_nodes
  name      = each.key
  node_name = "macbook"
  vm_id     = each.value.vmid

  clone {
    vm_id = var.template_id
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "scsi0"
    size         = 60
  }

  agent {
    enabled = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "192.168.1.1"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_pubkey]
    }
  }
}
