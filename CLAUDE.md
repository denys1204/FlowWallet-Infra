# FlowWallet-Infra

OpenTofu for the FlowWallet Proxmox lab. `terraform/base` downloads the Debian 13 cloud image and builds VM
template 9000; it runs rarely. `terraform/modules/k3s-cluster` describes one k3s cluster, and
`terraform/clusters/{mgmt,dev,stage,prod}` are its four roots, one state each; each root is a destroy/rebuild
target on its own. `bootstrap/lab.sh` brings one cluster up, checks it and rebuilds it; a later step adds
`platform/` (cluster add-ons).
Application manifests belong in FlowWallet-Config, not here.

## The state files have no second copy

`terraform.tfstate` and `terraform.tfstate.backup` in `terraform/base` and in each `terraform/clusters/<name>`
root are the only record of what exists on Proxmox.
They are gitignored and there is no remote backend.

- Never delete, move or hand-edit them.
- Copy both files somewhere safe before anything that touches a module folder: a move, a cleanup, a provider
  upgrade.
- Run `tofu apply` or `tofu destroy` only when asked. `fmt`, `validate` and `plan` are safe.

## Running OpenTofu

- Credentials come from `~/.config/proxmox/tf.env` (`PROXMOX_VE_*`), outside any checkout. Never copy their values
  into this repository.
- The cluster roots upload their cloud-init snippets over SSH, since the Proxmox API cannot upload snippets, and
  the key has a passphrase. Run `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` first, or the SSH step hangs.
- `bpg/proxmox` is pinned to an exact version in `versions.tf` and the lock files. Upgrade it in a change of its
  own, after a state backup.
- `bootstrap/lab.sh up`, `down` and `rebuild` run `tofu apply` or `tofu destroy`, so run them only when asked.
  `verify`, `kubeconfig` and `backup` change nothing on Proxmox.

## Conventions

- Conventional commits (`feat:`, `fix:`, `chore:`, `ci:`, `docs:`), as in FlowWallet.
- Nothing authenticating goes into git: no tokens, keys, real `terraform.tfvars` or state. CI runs gitleaks over
  the whole history.
- The k3s install is pinned in the module: `k3s_version` plus the sha256 of the binary and of `install.sh` at that
  tag. Bump all three together, in a change of their own.
- The provider stores snippet content in the state in plain text. The agent token is the only secret allowed in
  cloud-init; anything else secret reaches the cluster another way.
- Every cluster root re-exports the same outputs, and `lab.sh` reads only those. Change them in the module and in
  all four roots together; `.github/scripts/check-cluster-roots.py` checks ids, addresses and networks across the
  roots.
