# FlowWallet-Infra

OpenTofu for the FlowWallet Proxmox lab. `terraform/base` downloads the Debian 13 cloud image and builds VM
template 9000; it runs rarely. `terraform/modules/k3s-cluster` describes one k3s cluster, and
`terraform/clusters/{mgmt,dev,stage,prod}` are its four roots, one state each; each root is a destroy/rebuild
target on its own. `bootstrap/lab.sh` brings one cluster up, checks it and rebuilds it; `platform/` holds the
cluster add-ons it installs with Helm. `terraform/base` also owns the Proxmox pools; the cluster roots expect the
Lab pool to exist.
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
- `lab.sh platform` installs the charts in `platform/` now, and Argo CD will install them from stage 2, so keep their
  paths, release names and namespaces stable. Chart versions are pinned in `Chart.yaml` and `Chart.lock`; the
  downloaded `platform/*/charts/` stay out of git.
- A chart version bump in `Chart.yaml` needs `helm dependency update` and the new `.tgz` sha256 in
  `platform/charts.sha256`, in the same change; `lab.sh platform` and CI refuse a chart whose content differs.
- `tofu test` for the module runs from `terraform/modules/k3s-cluster` with a copy of the dev root's lock file
  (`cp ../../clusters/dev/.terraform.lock.hcl .`); that copy is gitignored.
- The Cloudflare tokens live only in `~/.config/px-lab/cloudflare/`. `lab.sh` copies them into the cluster as a
  Secret; never print them or write them into a file in the repository.
