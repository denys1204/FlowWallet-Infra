output "nodes" {
  description = "Name to address map of the cluster"
  value       = { for k, v in var.nodes : k => v.ip }
}

output "server_ip" {
  description = "Address of the k3s server; the API listens on port 6443"
  value       = local.server_ip
}

output "ssh" {
  description = "Ready to paste"
  value       = { for k, v in var.nodes : k => "ssh ${var.username}@${v.ip}" }
}
