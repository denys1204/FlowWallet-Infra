variable "cluster" {
  description = "Cluster name (mgmt, dev, stage, prod); used in node labels, VM tags and the API host name"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*$", var.cluster))
    error_message = "Use a short lowercase name such as dev."
  }
}

variable "lab_domain" {
  description = "Internal domain; the API answers as api.<cluster>.<lab_domain>"
  type        = string
  default     = "lab.px-lab.org"
}

variable "pod_cidr" {
  description = "Pod network of this cluster; each cluster gets its own range"
  type        = string

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "Must be a CIDR block such as 10.120.0.0/16."
  }
}

variable "service_cidr" {
  description = "Service network of this cluster; the cluster DNS takes its tenth address"
  type        = string

  validation {
    condition     = can(cidrhost(var.service_cidr, 10))
    error_message = "Must be a CIDR block with at least 11 addresses, such as 10.121.0.0/16."
  }
}

# VM id mirrors the address: 2xy for 10.2.0.xy.
variable "nodes" {
  description = "Cluster members: exactly one server, any number of agents"
  type = map(object({
    vm_id  = number
    ip     = string
    role   = string
    cores  = number
    memory = number
    disk   = number
  }))

  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(["server", "agent"], n.role)])
    error_message = "Every node needs role \"server\" or \"agent\"."
  }

  validation {
    condition     = length([for n in values(var.nodes) : n if n.role == "server"]) == 1
    error_message = "A cluster has exactly one server; there is no HA control plane in the lab."
  }
}

# The pinned release. Bump the version and both checksums together, in a
# change of their own. The trust anchor is the committed checksum, not the
# checksum file published next to the binary.
variable "k3s_version" {
  description = "k3s release installed on every node"
  type        = string
  default     = "v1.36.6+k3s1"
}

variable "k3s_sha256" {
  description = "sha256 of the k3s binary (the k3s line of sha256sum-amd64.txt in the release)"
  type        = string
  default     = "66ceb8e67edfa547195135d74783bfadc2ecc04a91059e90ae5f70a3dbc98c15"
}

variable "k3s_install_sha256" {
  description = "sha256 of install.sh at the release tag (not the moving copy on get.k3s.io)"
  type        = string
  default     = "46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"
}

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
