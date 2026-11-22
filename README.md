# FlowWallet-Infra

Infrastructure for the FlowWallet lab, a Proxmox homelab that runs
[FlowWallet](https://github.com/denys1204/FlowWallet) with separate dev, stage and prod
environments. This repository holds the OpenTofu code for the lab's k3s clusters (the
virtual machines and the k3s install on them) and `bootstrap/lab.sh`, which brings one
cluster up and checks it. The platform add-ons join in a later step. Application
manifests will live in a separate repository, FlowWallet-Config.

## Layout

```
terraform/base/                  cloud image + VM template, run rarely
terraform/modules/k3s-cluster/   one k3s cluster: VMs, cloud-init, the pinned k3s install
terraform/clusters/<name>/       one root and one state per cluster: mgmt, dev, stage, prod
bootstrap/lab.sh                 bring up, check, tear down and rebuild one cluster
```

The split is deliberate. Rebuilding a cluster from scratch is the checkpoint that proves
the setup works. It should not re-download a 300 MB image every time, and rebuilding dev
must never touch mgmt, which will run Argo CD.

Each node installs a pinned k3s release on first boot. The cloud-init script checks the
binary and `install.sh` against sha256 values committed in the module, and it never
upgrades a node that already runs k3s. The server generates its own server token, which
stays on the node. A cluster with agents also gets an agent token, the only k3s secret
OpenTofu knows. A cluster without agents gets none, so its server accepts no joins;
adding an agent to it later means rebuilding the server.

Each node keeps part of its memory away from pods for the operating system and for k3s
itself, and starts evicting pods before memory runs out. The values are starting points
until the first clusters are measured. When the host shuts down, every node gives its
pods a minute to stop, and Proxmox stops the agents before the servers.

## Credentials

Nothing authenticating lives in this repository. The provider reads
`PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` and `PROXMOX_VE_INSECURE` from the
environment, kept in `~/.config/proxmox/tf.env` outside any checkout.

The cluster roots also upload their cloud-init snippets to the node over SSH, because
the Proxmox API cannot upload snippets. The key is passphrase-protected, so load it
into the agent before running anything:

```sh
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
source ~/.config/proxmox/tf.env
```

## State

Each root keeps its state in a local `terraform.tfstate`. The file is gitignored and
there is no remote backend yet, so these files are the only record of what exists on
Proxmox. Back them up before moving or cleaning this folder. If they are lost, the VMs
keep running but OpenTofu no longer tracks them, and `tofu import` is the way back.

The provider stores the snippet content in the state in plain text. The snippets carry
the agent token, so the state files and their backups stay out of git and off shared
storage.

## Usage

```sh
cd terraform/base && tofu init && tofu apply   # once: the VM template
bootstrap/lab.sh up dev                        # one cluster: apply, wait for k3s, kubeconfig, checks
```

## Bring-up script

`bootstrap/lab.sh <command> <cluster>` wraps OpenTofu for one cluster:

| Command      | What it does |
|--------------|--------------|
| `up`         | Backs up the state, runs `tofu apply`, waits for cloud-init and for every node to be Ready, fetches the kubeconfig and runs `verify` |
| `kubeconfig` | Writes `~/.kube/px-lab/<cluster>.yaml` with the context `px-<cluster>` |
| `verify`     | Checks the nodes, the system components, secrets encryption, Pod Security, where the tokens live, and that a node cannot reach the home network |
| `down`       | Asks for the cluster name, backs up the state and runs `tofu destroy` |
| `rebuild`    | `down`, then `up`. `time bootstrap/lab.sh rebuild dev` is the rebuild drill |
| `backup`     | Copies the state files to `~/Documents/Backups/flowwallet-infra-state/` and compares them |

OpenTofu still asks before it applies or destroys anything. A plain
`tofu -chdir=terraform/clusters/dev apply` works too; the script adds the waiting, the
kubeconfig and the checks. It reads only the outputs that every cluster root exports in
the same shape.

## Network

Nodes live on `10.2.0.0/24`, an isolated bridge that cannot open connections into
the home network. VM ids mirror the addresses: `221` is `10.2.0.21`. Each cluster has
its own pod and service ranges, so addresses never overlap between clusters. CI checks
that no VM id, address or range clashes across the four roots.

| Cluster | Host        | Address   | Role   | vCPU | RAM  | Pods          | Services      |
|---------|-------------|-----------|--------|------|------|---------------|---------------|
| mgmt    | k3s-mgmt-1  | 10.2.0.11 | server | 2    | 3 GB | 10.110.0.0/16 | 10.111.0.0/16 |
| dev     | k3s-dev-1   | 10.2.0.21 | server | 4    | 4 GB | 10.120.0.0/16 | 10.121.0.0/16 |
| dev     | k3s-dev-2   | 10.2.0.22 | agent  | 4    | 3 GB |               |               |
| stage   | k3s-stage-1 | 10.2.0.31 | server | 4    | 4 GB | 10.130.0.0/16 | 10.131.0.0/16 |
| prod    | k3s-prod-1  | 10.2.0.41 | server | 4    | 4 GB | 10.140.0.0/16 | 10.141.0.0/16 |
