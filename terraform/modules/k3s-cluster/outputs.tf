# Every cluster root re-exports exactly these outputs. bootstrap/lab.sh reads them
# and nothing else, so a module for another provider only has to produce the same set.

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

output "username" {
  description = "Login on every node"
  value       = var.username
}

output "k3s_version" {
  description = "k3s release the nodes were installed with"
  value       = var.k3s_version
}

output "pod_cidr" {
  description = "Pod network of the cluster"
  value       = var.pod_cidr
}

output "service_cidr" {
  description = "Service network of the cluster"
  value       = var.service_cidr
}
