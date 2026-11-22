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

  validation {
    condition     = alltrue([for name in keys(var.nodes) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name))])
    error_message = "Node names become host names: lowercase letters, digits and hyphens, at most 63 characters."
  }

  validation {
    condition     = alltrue([for n in values(var.nodes) : can(cidrhost("${n.ip}/32", 0))])
    error_message = "Every node ip must be a plain IPv4 address such as 10.2.0.21."
  }

  validation {
    condition     = length(distinct([for n in values(var.nodes) : n.ip])) == length(var.nodes)
    error_message = "Two nodes share an ip."
  }

  validation {
    condition     = length(distinct([for n in values(var.nodes) : n.vm_id])) == length(var.nodes)
    error_message = "Two nodes share a vm_id."
  }
}

variable "lab_cidr" {
  description = "The isolated lab network; every node address must lie inside it"
  type        = string
  default     = "10.2.0.0/24"

  validation {
    condition     = can(cidrhost(var.lab_cidr, 0))
    error_message = "Must be a CIDR block such as 10.2.0.0/24."
  }
}

# Starting values, to be tuned from the RAM measured after the first bring-up.
# The server reserves more for kube components because the API server, the
# datastore and the controllers run inside its k3s process.
variable "kubelet_memory" {
  description = "Memory the kubelet keeps away from pods, and the free-memory level at which it starts evicting"
  type = object({
    system_reserved      = string
    kube_reserved_server = string
    kube_reserved_agent  = string
    eviction_threshold   = string
  })
  default = {
    system_reserved      = "256Mi"
    kube_reserved_server = "512Mi"
    kube_reserved_agent  = "256Mi"
    eviction_threshold   = "200Mi"
  }

  validation {
    condition     = alltrue([for v in values(var.kubelet_memory) : can(regex("^[0-9]+(Mi|Gi)$", v))])
    error_message = "Use Kubernetes quantities in Mi or Gi, such as 256Mi."
  }
}

# The pinned release. Bump the version and both checksums together, in a
# change of their own. The trust anchor is the committed checksum, not the
# checksum file published next to the binary.
variable "k3s_version" {
  description = "k3s release installed on every node"
  type        = string
  default     = "v1.36.6+k3s1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "Use a k3s release tag such as v1.36.6+k3s1."
  }
}

variable "k3s_sha256" {
  description = "sha256 of the k3s binary (the k3s line of sha256sum-amd64.txt in the release)"
  type        = string
  default     = "66ceb8e67edfa547195135d74783bfadc2ecc04a91059e90ae5f70a3dbc98c15"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.k3s_sha256))
    error_message = "Must be a sha256 in lowercase hex (64 characters)."
  }
}

variable "k3s_install_sha256" {
  description = "sha256 of install.sh at the release tag (not the moving copy on get.k3s.io)"
  type        = string
  default     = "46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.k3s_install_sha256))
    error_message = "Must be a sha256 in lowercase hex (64 characters)."
  }
}

variable "node_name" {
  description = "Proxmox node that hosts the lab"
  type        = string
  default     = "server"
}

variable "pool" {
  description = "Proxmox pool of the nodes; terraform/base creates it, so apply base first"
  type        = string
  default     = "Lab"
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
