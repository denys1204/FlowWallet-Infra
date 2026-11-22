# Renders the cloud-init user-data of a server and an agent with both providers
# mocked, so `tofu test` needs neither Proxmox nor credentials and runs in CI. A
# broken template, bad YAML or a missing file shows up here instead of as a node
# whose cloud-init fails. CI shellchecks the install script separately.

mock_provider "proxmox" {
  # The VM checks that user_data_file_id looks like a datastore file id.
  mock_resource "proxmox_virtual_environment_file" {
    defaults = {
      id = "local:snippets/ci-user-data.yaml"
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "ci-render-test-agent-token"
    }
  }
}

variables {
  cluster             = "ci"
  pod_cidr            = "10.250.0.0/16"
  service_cidr        = "10.251.0.0/16"
  ssh_public_key_path = "./tests/ci_key.pub"
  nodes = {
    k3s-ci-1 = { vm_id = 291, ip = "10.2.0.91", role = "server", cores = 1, memory = 1024, disk = 10 }
    k3s-ci-2 = { vm_id = 292, ip = "10.2.0.92", role = "agent", cores = 1, memory = 1024, disk = 10 }
  }
}

run "user_data" {
  command = apply

  assert {
    condition     = alltrue([for f in proxmox_virtual_environment_file.user_data : can(yamldecode(f.source_raw[0].data))])
    error_message = "A rendered user-data is not valid YAML."
  }

  assert {
    condition = toset([for f in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-1"].source_raw[0].data).write_files : f.path]) == toset([
      "/etc/rancher/k3s/config.yaml",
      "/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-px-lab.conf",
      "/etc/systemd/logind.conf.d/zz-px-lab-shutdown.conf",
      "/etc/px-lab/fw.nft",
      "/etc/systemd/system/px-lab-fw.service",
      "/var/lib/rancher/k3s/server/psa.yaml",
      "/usr/local/sbin/px-k3s-install",
    ])
    error_message = "The server user-data does not write exactly the expected files."
  }

  assert {
    condition = toset([for f in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-2"].source_raw[0].data).write_files : f.path]) == toset([
      "/etc/rancher/k3s/config.yaml",
      "/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-px-lab.conf",
      "/etc/systemd/logind.conf.d/zz-px-lab-shutdown.conf",
      "/etc/px-lab/fw.nft",
      "/etc/systemd/system/px-lab-fw.service",
      "/usr/local/sbin/px-k3s-install",
    ])
    error_message = "The agent user-data does not write exactly the expected files (no psa.yaml on an agent)."
  }

  # The files embedded in the user-data must parse too: the k3s config, the
  # kubelet drop-in and the Pod Security config.
  assert {
    condition = alltrue(flatten([
      for f in proxmox_virtual_environment_file.user_data : [
        for w in yamldecode(f.source_raw[0].data).write_files :
        can(yamldecode(w.content)) if endswith(w.path, ".yaml") || endswith(w.path, "50-px-lab.conf")
      ]
    ]))
    error_message = "A YAML file embedded in the user-data does not parse."
  }

  assert {
    condition = alltrue([
      for w in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-1"].source_raw[0].data).write_files :
      yamldecode(w.content)["agent-token"] == "ci-render-test-agent-token" if w.path == "/etc/rancher/k3s/config.yaml"
    ])
    error_message = "The server of a cluster with agents must carry the agent token."
  }

  assert {
    condition = alltrue([
      for w in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-2"].source_raw[0].data).write_files :
      yamldecode(w.content).server == "https://10.2.0.91:6443" if w.path == "/etc/rancher/k3s/config.yaml"
    ])
    error_message = "The agent must join the server's address."
  }

  assert {
    condition = alltrue([
      for w in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-1"].source_raw[0].data).write_files :
      yamldecode(w.content).shutdownGracePeriod == "60s" if w.path == "/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-px-lab.conf"
    ])
    error_message = "The kubelet drop-in must set the 60 s graceful shutdown."
  }

  # The firewall: own node, both nodes and the pod network as peers, mgmt let in
  # to the API server, and the unit enabled before k3s is installed.
  assert {
    condition = alltrue([
      for w in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-2"].source_raw[0].data).write_files :
      strcontains(w.content, "ip daddr != 10.2.0.92 accept")
      && strcontains(w.content, "elements = { 10.2.0.91, 10.2.0.92, 10.250.0.0/16 }")
      && strcontains(w.content, "ip saddr 10.2.0.11 tcp dport 6443 accept")
      && strcontains(w.content, "ip saddr 10.2.0.0/24 counter drop")
      if w.path == "/etc/px-lab/fw.nft"
    ])
    error_message = "The agent's firewall does not have the expected node, peers, mgmt rule and lab drop."
  }

  assert {
    condition = alltrue([
      for f in proxmox_virtual_environment_file.user_data : (
        contains(yamldecode(f.source_raw[0].data).packages, "nftables")
        && index(yamldecode(f.source_raw[0].data).runcmd, "systemctl enable --now px-lab-fw.service")
        < index(yamldecode(f.source_raw[0].data).runcmd, "/usr/local/sbin/px-k3s-install")
      )
    ])
    error_message = "Every node needs the nftables package and its firewall enabled before k3s is installed."
  }
}

# mgmt itself has no reason to let mgmt in: no 6443 exception there.
run "mgmt_firewall" {
  command = apply

  variables {
    cluster = "mgmt"
    nodes = {
      k3s-ci-1 = { vm_id = 211, ip = "10.2.0.11", role = "server", cores = 1, memory = 1024, disk = 10 }
    }
  }

  assert {
    condition = alltrue([
      for w in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-1"].source_raw[0].data).write_files :
      !strcontains(w.content, "dport 6443") if w.path == "/etc/px-lab/fw.nft"
    ])
    error_message = "The mgmt firewall must not open port 6443 to another lab host."
  }
}

# A cluster without agents gets no agent token at all.
run "no_agents_no_token" {
  command = apply

  variables {
    nodes = {
      k3s-ci-1 = { vm_id = 291, ip = "10.2.0.91", role = "server", cores = 1, memory = 1024, disk = 10 }
    }
  }

  assert {
    condition     = length(random_password.agent_token) == 0
    error_message = "A cluster without agents must not create an agent token."
  }

  assert {
    condition = alltrue([
      for w in yamldecode(proxmox_virtual_environment_file.user_data["k3s-ci-1"].source_raw[0].data).write_files :
      !contains(keys(yamldecode(w.content)), "agent-token") if w.path == "/etc/rancher/k3s/config.yaml"
    ])
    error_message = "The server of a cluster without agents must not carry an agent token."
  }
}
