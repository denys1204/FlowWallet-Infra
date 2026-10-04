output "template_vm_id" {
  description = "Feed this into the cluster module"
  value       = proxmox_virtual_environment_vm.template.vm_id
}

output "image_file_id" {
  value = proxmox_download_file.debian.id
}
