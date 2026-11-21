terraform {
  required_version = ">= 1.9"

  required_providers {
    # Exact pin: the provider is pre-1.0 and renames resources between minor
    # releases, so an upgrade is a change of its own, with a state backup first.
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.111.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}

# Endpoint, API token and TLS behaviour come from PROXMOX_VE_* environment
# variables, so no credential ever appears in this repository. SSH is only used
# to upload the cloud-init snippets.
provider "proxmox" {
  ssh {
    agent    = true
    username = "root"
  }
}
