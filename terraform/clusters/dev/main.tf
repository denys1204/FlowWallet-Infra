# The only cluster with an agent, so multi-node behaviour is tried here first.
module "cluster" {
  source = "../../modules/k3s-cluster"

  cluster      = "dev"
  pod_cidr     = "10.120.0.0/16"
  service_cidr = "10.121.0.0/16"

  nodes = {
    k3s-dev-1 = { vm_id = 221, ip = "10.2.0.21", role = "server", cores = 4, memory = 4096, disk = 40 }
    k3s-dev-2 = { vm_id = 222, ip = "10.2.0.22", role = "agent", cores = 4, memory = 3072, disk = 40 }
  }
}
