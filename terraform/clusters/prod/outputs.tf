output "nodes" {
  description = "Name to address map of the cluster"
  value       = module.cluster.nodes
}

output "server_ip" {
  description = "Address of the k3s server; the API listens on port 6443"
  value       = module.cluster.server_ip
}

output "ssh" {
  description = "Ready to paste"
  value       = module.cluster.ssh
}
