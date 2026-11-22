# Proxmox pools group the guests in the web UI and are the unit that permissions
# attach to. OpenTofu owns the pools themselves. The cluster VMs and the template
# join theirs through pool_id, so a rebuilt VM lands in its pool again; guests that
# OpenTofu does not manage are put into theirs by hand.
locals {
  pools = {
    Home      = "Guests outside the lab, managed by hand"
    Lab       = "k3s nodes of the lab clusters, managed by OpenTofu"
    Devbox    = "The build container"
    Templates = "VM and container templates"
  }
}

resource "proxmox_virtual_environment_pool" "pool" {
  for_each = local.pools

  pool_id = each.key
  comment = each.value
}

# Templates existed before OpenTofu managed the pools.
import {
  to = proxmox_virtual_environment_pool.pool["Templates"]
  id = "Templates"
}
