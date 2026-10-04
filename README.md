# FlowWallet-Infra

Infrastructure for the FlowWallet lab, a Proxmox homelab that runs
[FlowWallet](https://github.com/denys1204/FlowWallet) with separate dev, stage and prod
environments. This repository holds the OpenTofu code for the lab's virtual machines.
The cluster bootstrap and the platform add-ons join it in later stages. Application
manifests will live in a separate repository, FlowWallet-Config.

## Layout

```
terraform/base/      cloud image + VM template, run rarely
terraform/cluster/   k3s nodes, the destroy/rebuild target
```

The split is deliberate. Rebuilding the cluster from scratch is the checkpoint that
proves the setup works, and it should not re-download a 300 MB image every time.

The cluster module describes the first design: one k3s cluster with a server and two
agents. k3s itself is not installed on them yet. The next stage replaces this layout
with four clusters: mgmt, dev, stage and prod.

## Credentials

Nothing authenticating lives in this repository. The provider reads
`PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` and `PROXMOX_VE_INSECURE` from the
environment, kept in `~/.config/proxmox/tf.env` outside any checkout.

The cluster module also uploads its cloud-init snippets to the node over SSH, because
the Proxmox API cannot upload snippets. The key is passphrase-protected, so load it
into the agent before running anything:

```sh
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
source ~/.config/proxmox/tf.env
```

## State

Each module keeps its state in a local `terraform.tfstate`. The file is gitignored and
there is no remote backend yet, so these files are the only record of what exists on
Proxmox. Back them up before moving or cleaning this folder. If they are lost, the VMs
keep running but OpenTofu no longer tracks them, and `tofu import` is the way back.

## Usage

```sh
cd terraform/base    && tofu init && tofu apply    # once
cd terraform/cluster && tofu init && tofu apply    # as often as needed
```

## Network

Nodes live on `10.2.0.0/24`, an isolated bridge that cannot open connections into
the home network. VM ids mirror the addresses: `211` is `10.2.0.11`.

| Host           | Address     | vCPU | RAM  |
|----------------|-------------|------|------|
| k3s-server-1   | 10.2.0.11   | 2    | 4 GB |
| k3s-agent-1    | 10.2.0.12   | 4    | 6 GB |
| k3s-agent-2    | 10.2.0.13   | 4    | 6 GB |
