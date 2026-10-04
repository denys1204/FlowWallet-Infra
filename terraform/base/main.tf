# Resource naming is deliberately mixed. The provider is renaming everything
# ahead of v1.0, but the new-generation proxmox_vm / proxmox_cloned_vm cannot do
# cloud-init yet, so virtual machines stay on the proxmox_virtual_environment_*
# names until that gap closes. Only download_file has a finished replacement.

# Downloads the upstream cloud image once. The content type must be "import":
# Proxmox 9 refuses to build a disk out of a file stored as "iso", even when the
# extension is renamed. That renaming trick belongs to the Proxmox 8 era.
resource "proxmox_download_file" "debian" {
  content_type = "import"
  datastore_id = var.image_datastore
  node_name    = var.node_name
  url          = var.image_url
  file_name    = "debian-13-genericcloud-amd64.qcow2"
  overwrite    = false
}

# A stopped VM marked as a template. Every lab node is a full clone of it,
# which is why the template itself stays deliberately minimal.
resource "proxmox_virtual_environment_vm" "template" {
  name        = "debian-13-cloud"
  description = "Base template for the lab. Managed by OpenTofu - do not edit by hand."
  node_name   = var.node_name
  vm_id       = var.template_vm_id
  template    = true
  started     = false

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.vm_datastore
    import_from  = proxmox_download_file.debian.id
    interface    = "virtio0"
    size         = 20
    discard      = "on"
    ssd          = true
  }

  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_device {
    bridge = var.bridge
  }

  operating_system {
    type = "l26"
  }

  # Cloud images log to the serial console; without this the boot output is invisible.
  serial_device {}
}
