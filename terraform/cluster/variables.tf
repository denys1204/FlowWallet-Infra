variable "node_name" {
  description = "Proxmox node that hosts the lab"
  type        = string
  default     = "server"
}

variable "template_vm_id" {
  description = "Template produced by the base module"
  type        = number
  default     = 9000
}

variable "vm_datastore" {
  description = "Datastore for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "snippet_datastore" {
  description = "Datastore holding cloud-init snippets; needs the snippets content type"
  type        = string
  default     = "local"
}

variable "bridge" {
  description = "Bridge of the isolated lab network"
  type        = string
  default     = "vmbr2"
}

variable "gateway" {
  description = "Lab gateway, i.e. the Proxmox side of the lab bridge"
  type        = string
  default     = "10.2.0.1"
}

variable "dns_servers" {
  description = "Public resolvers on purpose: the lab must never reach into the trusted network"
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
}

variable "username" {
  description = "Login created by cloud-init"
  type        = string
  default     = "debian"
}

variable "ssh_public_key_path" {
  description = "Key injected into every node"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "timezone" {
  type    = string
  default = "Etc/UTC"
}

# VM id mirrors the address: 2xx where xx is the host octet in 10.2.0.0/24.
variable "nodes" {
  description = "Cluster members"
  type = map(object({
    vm_id  = number
    ip     = string
    cores  = number
    memory = number
    disk   = number
  }))
  default = {
    k3s-server-1 = { vm_id = 211, ip = "10.2.0.11", cores = 2, memory = 4096, disk = 30 }
    k3s-agent-1  = { vm_id = 212, ip = "10.2.0.12", cores = 4, memory = 6144, disk = 40 }
    k3s-agent-2  = { vm_id = 213, ip = "10.2.0.13", cores = 4, memory = 6144, disk = 40 }
  }
}
