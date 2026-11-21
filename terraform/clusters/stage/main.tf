module "cluster" {
  source = "../../modules/k3s-cluster"

  cluster      = "stage"
  pod_cidr     = "10.130.0.0/16"
  service_cidr = "10.131.0.0/16"

  nodes = {
    k3s-stage-1 = { vm_id = 231, ip = "10.2.0.31", role = "server", cores = 4, memory = 4096, disk = 40 }
  }
}
