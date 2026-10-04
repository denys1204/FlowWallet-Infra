variable "node_name" {
  description = "Proxmox node that hosts the lab"
  type        = string
  default     = "server"
}

variable "image_url" {
  description = "Cloud image used as the base for every lab VM"
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "image_datastore" {
  description = "Datastore that keeps the downloaded image"
  type        = string
  default     = "local"
}

variable "vm_datastore" {
  description = "Datastore for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Bridge the template is attached to"
  type        = string
  default     = "vmbr2"
}

variable "template_vm_id" {
  description = "VM id reserved for the template"
  type        = number
  default     = 9000
}
