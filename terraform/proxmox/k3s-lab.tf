# The disposable lab — destroyed and rebuilt monthly ON PURPOSE.
#   terraform destroy -target=proxmox_virtual_environment_vm.k3s
locals {
  k3s_nodes = {
    k3s-server = { vmid = 141, ip = "192.168.0.41" }
    k3s-agent1 = { vmid = 142, ip = "192.168.0.42" }
    k3s-agent2 = { vmid = 143, ip = "192.168.0.43" }
  }
}

resource "proxmox_virtual_environment_vm" "k3s" {
  for_each  = local.k3s_nodes
  name      = each.key
  node_name = "macbook"
  vm_id     = each.value.vmid
  on_boot   = true

  clone {
    vm_id = var.template_id
    # Template 9000 lives on k8plus; these VMs land on macbook, so name the
    # SOURCE node or the clone fails. Pin `full` explicitly — changing this
    # flag later forces VM replacement (see JOURNAL, session 7).
    node_name = "k8plus"
    full      = true
  }

  cpu {
    cores = 4
    # Pass host CPU flags through. The default kvm64/qemu64 is x86-64-v1 and
    # lacks SSE4.2/POPCNT, which breaks anything built for x86-64-v2 — that's
    # what crash-looped Immich's ML container. No live migration here, so safe.
    type = "host"
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
    datastore_id = "local-zfs"
    # Static IP with NO DNS was the 2026-07-25 bug — the VM boots unable to
    # resolve anything. AdGuard first: the router does NOT resolve *.lab.
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
