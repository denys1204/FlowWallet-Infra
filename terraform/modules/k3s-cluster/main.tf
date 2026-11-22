locals {
  ssh_key    = trimspace(file(pathexpand(var.ssh_public_key_path)))
  server_ip  = one([for n in values(var.nodes) : n.ip if n.role == "server"])
  node_label = ["px-lab.org/cluster=${var.cluster}"]
  lab_prefix = split("/", var.lab_cidr)[1]

  # Only a cluster with agents gets an agent token. Without one the server accepts
  # no joins at all, so mgmt, stage and prod carry no join secret. Adding an agent
  # to such a cluster later changes the server's config, which means a rebuild.
  has_agents = anytrue([for n in values(var.nodes) : n.role == "agent"])

  # Two CIDR blocks overlap exactly when one contains the other.
  cidr_overlaps = {
    "pod and service" = cidrcontains(var.pod_cidr, var.service_cidr) || cidrcontains(var.service_cidr, var.pod_cidr)
    "pod and lab"     = cidrcontains(var.pod_cidr, var.lab_cidr) || cidrcontains(var.lab_cidr, var.pod_cidr)
    "service and lab" = cidrcontains(var.service_cidr, var.lab_cidr) || cidrcontains(var.lab_cidr, var.service_cidr)
  }

  # Memory the kubelet keeps away from pods, plus graceful shutdown: on a host
  # shutdown the kubelet gets a minute to stop pods before the VM powers off.
  # A KubeletConfiguration drop-in, not kubelet-arg: the shutdown settings have
  # no command-line flag, and an unknown flag stops k3s from starting at all.
  # evictionHard lists every signal, because setting it replaces the kubelet
  # defaults instead of merging with them.
  kubelet_config = {
    for role in ["server", "agent"] : role => yamlencode({
      apiVersion     = "kubelet.config.k8s.io/v1beta1"
      kind           = "KubeletConfiguration"
      systemReserved = { memory = var.kubelet_memory.system_reserved }
      kubeReserved = {
        memory = role == "server" ? var.kubelet_memory.kube_reserved_server : var.kubelet_memory.kube_reserved_agent
      }
      evictionHard = {
        "memory.available"   = var.kubelet_memory.eviction_threshold
        "nodefs.available"   = "10%"
        "nodefs.inodesFree"  = "5%"
        "imagefs.available"  = "15%"
        "imagefs.inodesFree" = "5%"
      }
      shutdownGracePeriod             = "60s"
      shutdownGracePeriodCriticalPods = "15s"
    })
  }

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
    for name, n in var.nodes : name => n.role == "server" ? yamlencode(merge({
      "node-ip"      = n.ip
      "node-label"   = local.node_label
      "cluster-cidr" = var.pod_cidr
      "service-cidr" = var.service_cidr
      "cluster-dns"  = cidrhost(var.service_cidr, 10)
      "tls-san"      = ["api.${var.cluster}.${var.lab_domain}"]
      "disable"      = ["traefik"]
      # One install path for add-ons (helm now, Argo CD later): no HelmChart
      # custom resources, and no cluster-admin install jobs created through one.
      "disable-helm-controller"     = true
      "secrets-encryption"          = true
      "secrets-encryption-provider" = "secretbox"
      "write-kubeconfig-mode"       = "0600"
      "kube-apiserver-arg"          = ["admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml"]
      }, local.has_agents ? { "agent-token" = random_password.agent_token[0].result } : {})) : yamlencode({
      "server"     = "https://${local.server_ip}:6443"
      "token"      = random_password.agent_token[0].result
      "node-ip"    = n.ip
      "node-label" = local.node_label
    })
  }
}

# The only k3s secret OpenTofu knows, so the only one in the snippets, the
# state and its backups. Agents join with it, but it cannot fetch the server's
# bootstrap data. The server generates its own server token, which never leaves
# the node. A rebuild draws a new one. Clusters without agents get none.
resource "random_password" "agent_token" {
  count = local.has_agents ? 1 : 0

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
      hostname       = each.key
      username       = var.username
      ssh_key        = local.ssh_key
      timezone       = var.timezone
      role           = each.value.role
      k3s_config     = trimspace(local.k3s_config[each.key])
      kubelet_config = trimspace(local.kubelet_config[each.value.role])
      psa_config     = trimspace(local.psa_config)
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
  # Membership lives here, not in the web UI, so a rebuilt node joins its pool again.
  pool_id = var.pool

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

  # Host boot starts the house services first (order 1-3, set by hand on their
  # guests), then the k3s servers, then the agents. Shutdown runs in reverse and
  # waits up to 90 s per node, enough for the kubelet's 60 s graceful shutdown.
  startup {
    order      = each.value.role == "server" ? 5 : 6
    up_delay   = each.value.role == "server" ? 15 : 0
    down_delay = 90
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
        address = "${each.value.ip}/${local.lab_prefix}"
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

    # Checks that span several variables, so they cannot live in a validation block.
    precondition {
      condition = (
        cidrcontains(var.lab_cidr, each.value.ip)
        && each.value.ip != var.gateway
        && each.value.ip != cidrhost(var.lab_cidr, 0)
        && each.value.ip != cidrhost(var.lab_cidr, -1)
      )
      error_message = "Node ${each.key} needs a host address inside ${var.lab_cidr} other than the gateway ${var.gateway}."
    }

    precondition {
      condition     = !anytrue(values(local.cidr_overlaps))
      error_message = "These networks overlap: ${join(", ", [for k, v in local.cidr_overlaps : k if v])}."
    }
  }
}
