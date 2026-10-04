# FlowWallet-Infra

OpenTofu for the FlowWallet Proxmox lab. `terraform/base` downloads the Debian 13 cloud image and builds VM
template 9000; it runs rarely. `terraform/cluster` clones the k3s nodes from that template and is the
destroy/rebuild target. Later stages add `bootstrap/` (k3s, Argo CD) and `platform/` (the app-of-apps for cluster
add-ons). Application manifests belong in FlowWallet-Config, not here.

## The state files have no second copy

`terraform.tfstate` and `terraform.tfstate.backup` in both modules are the only record of what exists on Proxmox.
They are gitignored and there is no remote backend.

- Never delete, move or hand-edit them.
- Copy both files somewhere safe before anything that touches a module folder: a move, a cleanup, a provider
  upgrade.
- Run `tofu apply` or `tofu destroy` only when asked. `fmt`, `validate` and `plan` are safe.

## Running OpenTofu

- Credentials come from `~/.config/proxmox/tf.env` (`PROXMOX_VE_*`), outside any checkout. Never copy their values
  into this repository.
- The cluster module uploads its cloud-init snippets over SSH, since the Proxmox API cannot upload snippets, and
  the key has a passphrase. Run `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` first, or the SSH step hangs.
- `bpg/proxmox` is pinned to an exact version in `versions.tf` and the lock files. Upgrade it in a change of its
  own, after a state backup.

## Conventions

- Conventional commits (`feat:`, `fix:`, `chore:`, `ci:`, `docs:`), as in FlowWallet.
- Nothing authenticating goes into git: no tokens, keys, real `terraform.tfvars` or state. CI runs gitleaks over
  the whole history.
- The cluster module holds the first single-cluster design (one server, two agents), which is what runs on
  Proxmox. The next stage reshapes the `nodes` map in `terraform/cluster/variables.tf` into four clusters: mgmt,
  dev, stage and prod.
