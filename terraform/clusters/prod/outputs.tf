# The same outputs in every cluster root; bootstrap/lab.sh relies on them.

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

output "username" {
  description = "Login on every node"
  value       = module.cluster.username
}

output "k3s_version" {
  description = "k3s release the nodes were installed with"
  value       = module.cluster.k3s_version
}

output "pod_cidr" {
  description = "Pod network of the cluster"
  value       = module.cluster.pod_cidr
}

output "service_cidr" {
  description = "Service network of the cluster"
  value       = module.cluster.service_cidr
}
