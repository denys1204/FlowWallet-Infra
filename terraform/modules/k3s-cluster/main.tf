locals {
  ssh_key    = trimspace(file(pathexpand(var.ssh_public_key_path)))
  server_ip  = one([for n in values(var.nodes) : n.ip if n.role == "server"])
  node_label = ["px-lab.org/cluster=${var.cluster}"]

  # Pod Security admission defaults for the whole cluster: baseline is
  # enforced, restricted is audited and warned about. A namespace that needs a
  # different level says so with its own labels, kept in git.
  psa_config = yamlencode({
    apiVersion = "apiserver.config.k8s.io/v1"
    kind       = "AdmissionConfiguration"
    plugins = [{
      name = "PodSecurity"
      configuration = {
        apiVersion = "pod-security.admission.config.k8s.io/v1"
        kind       = "PodSecurityConfiguration"
        defaults = {
          enforce           = "baseline"
          "enforce-version" = "latest"
          audit             = "restricted"
          "audit-version"   = "latest"
          warn              = "restricted"
          "warn-version"    = "latest"
        }
        exemptions = {
          # The ServiceLB and local-path helper pods run privileged here.
          namespaces = ["kube-system"]
        }
      }
    }]
  })

  # k3s reads /etc/rancher/k3s/config.yaml on every start. Rendered with
  # yamlencode, so no hand-indented YAML ends up inside the cloud-init file.
  k3s_config = {
    for name, n in var.nodes : name => n.role == "server" ? yamlencode({
      "node-ip"      = n.ip
      "node-label"   = local.node_label
      "cluster-cidr" = var.pod_cidr
      "service-cidr" = var.service_cidr
      "cluster-dns"  = cidrhost(var.service_cidr, 10)
      "tls-san"      = ["api.${var.cluster}.${var.lab_domain}"]
      "agent-token"  = random_password.agent_token.result
      "disable"      = ["traefik"]
      # One install path for add-ons (helm now, Argo CD later): no HelmChart
      # custom resources, and no cluster-admin install jobs created through one.
      "disable-helm-controller"     = true
      "secrets-encryption"          = true
      "secrets-encryption-provider" = "secretbox"
      "write-kubeconfig-mode"       = "0600"
      "kube-apiserver-arg"          = ["admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml"]
      }) : yamlencode({
      "server"     = "https://${local.server_ip}:6443"
      "token"      = random_password.agent_token.result
      "node-ip"    = n.ip
      "node-label" = local.node_label
    })
  }
}

# The only k3s secret OpenTofu knows, so the only one in the snippets, the
# state and its backups. Agents join with it, but it cannot fetch the server's
# bootstrap data. The server generates its own server token, which never leaves
# the node. A rebuild draws a new one.
resource "random_password" "agent_token" {
  length  = 48
  special = false
}

# One snippet per node, because the hostname and the k3s config differ.
# Proxmox serves these as cloud-init user-data, which is why the local
# datastore needs the snippets content type. The provider keeps the content in
# the state in plain text, which is why nothing but the agent token goes in.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = var.nodes

  content_type = "snippets"
  datastore_id = var.snippet_datastore
  node_name    = var.node_name

  source_raw {
    file_name = "${each.key}-user-data.yaml"
    data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
      hostname   = each.key
      username   = var.username
      ssh_key    = local.ssh_key
      timezone   = var.timezone
      role       = each.value.role
      k3s_config = trimspace(local.k3s_config[each.key])
      psa_config = trimspace(local.psa_config)
      install_script = templatefile("${path.module}/cloud-init/px-k3s-install.sh.tftpl", {
        role               = each.value.role
        k3s_version        = var.k3s_version
        k3s_sha256         = var.k3s_sha256
        k3s_install_sha256 = var.k3s_install_sha256
      })
    })
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name        = each.key
  description = "k3s ${each.value.role} of the ${var.cluster} cluster. Managed by OpenTofu - do not edit by hand."
  node_name   = var.node_name
  vm_id       = each.value.vm_id
  tags        = ["lab", "k3s", var.cluster]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    # No ballooning: the kubelet schedules against the memory it sees at boot,
    # and a balloon reclaiming it later would starve running pods.
    dedicated = each.value.memory
    floating  = 0
  }

  # No ssd flag: Proxmox has no such option for virtio disks and drops it, so
  # setting it only produces a permanent diff.
  disk {
    datastore_id = var.vm_datastore
    interface    = "virtio0"
    size         = each.value.disk
    discard      = "on"
  }

  initialization {
    datastore_id = var.vm_datastore

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
  }

  network_device {
    bridge = var.bridge
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    ignore_changes = [
      # The clone source only matters at creation; a later template rebuild
      # must not trigger a rebuild of every running node.
      clone,
    ]
  }
}
