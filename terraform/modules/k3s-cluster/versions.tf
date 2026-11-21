terraform {
  required_version = ">= 1.9"

  # Sources only. Each cluster root pins exact versions and configures the
  # Proxmox provider, so the module never decides which release runs.
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}
