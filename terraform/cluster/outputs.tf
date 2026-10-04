output "nodes" {
  description = "Name to address map of the cluster"
  value       = { for k, v in var.nodes : k => v.ip }
}

output "ssh" {
  description = "Ready to paste"
  value       = { for k, v in var.nodes : k => "ssh ${var.username}@${v.ip}" }
}
