# Argo CD lives here from stage 2, which is why this root has a state of its own:
# rebuilding dev never touches it.
module "cluster" {
  source = "../../modules/k3s-cluster"

  cluster      = "mgmt"
  pod_cidr     = "10.110.0.0/16"
  service_cidr = "10.111.0.0/16"

  nodes = {
    k3s-mgmt-1 = { vm_id = 211, ip = "10.2.0.11", role = "server", cores = 2, memory = 3072, disk = 30 }
  }
}
