locals {
  ssh_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# One snippet per node, because the hostname differs. Proxmox serves these as
# cloud-init user-data, which is why the local datastore needs the snippets
# content type enabled.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = var.nodes

  content_type = "snippets"
  datastore_id = var.snippet_datastore
  node_name    = var.node_name

  source_raw {
    file_name = "${each.key}-user-data.yaml"
    data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
      hostname = each.key
      username = var.username
      ssh_key  = local.ssh_key
      timezone = var.timezone
    })
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name        = each.key
  description = "Lab node. Managed by OpenTofu - do not edit by hand."
  node_name   = var.node_name
  vm_id       = each.value.vm_id
  tags        = ["lab", "k3s"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    # No ballooning: the kubelet schedules against the memory it sees at boot,
    # and a balloon reclaiming it later would starve running pods.
    dedicated = each.value.memory
    floating  = 0
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "virtio0"
    size         = each.value.disk
    discard      = "on"
    ssd          = true
  }

  initialization {
    datastore_id = var.vm_datastore

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
  }

  network_device {
    bridge = var.bridge
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    ignore_changes = [
      # The clone source only matters at creation; a later template rebuild
      # must not trigger a rebuild of every running node.
      clone,
    ]
  }
}
