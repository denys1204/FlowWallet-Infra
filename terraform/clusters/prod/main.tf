module "cluster" {
  source = "../../modules/k3s-cluster"

  cluster      = "prod"
  pod_cidr     = "10.140.0.0/16"
  service_cidr = "10.141.0.0/16"

  nodes = {
    k3s-prod-1 = { vm_id = 241, ip = "10.2.0.41", role = "server", cores = 4, memory = 4096, disk = 40 }
  }
}
