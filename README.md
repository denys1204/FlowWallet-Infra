# FlowWallet-Infra

Infrastructure for the FlowWallet lab, a Proxmox homelab that runs
[FlowWallet](https://github.com/denys1204/FlowWallet) with separate dev, stage and prod
environments. This repository holds the OpenTofu code for the lab's k3s clusters (the
virtual machines and the k3s install on them), the bring-up script `bootstrap/lab.sh`,
and `platform/` with the add-ons every cluster gets: cert-manager and Traefik.
Application manifests will live in a separate repository, FlowWallet-Config.

## Layout

```
terraform/base/                  cloud image, VM template and the Proxmox pools, run rarely
terraform/modules/k3s-cluster/   one k3s cluster: VMs, cloud-init, the pinned k3s install
terraform/clusters/<name>/       one root and one state per cluster: mgmt, dev, stage, prod
bootstrap/lab.sh                 bring up, check, tear down and rebuild one cluster
platform/namespaces/             namespaces and their Pod Security level
platform/cert-manager/           umbrella chart around cert-manager, pinned in Chart.lock
platform/traefik/                umbrella chart around Traefik, pinned in Chart.lock
platform/cluster-tls/            Let's Encrypt issuers and the cluster's wildcard certificate
platform/smoke/                  a throwaway whoami app that lab.sh verify deploys and removes
```

The split is deliberate. Rebuilding a cluster from scratch is the checkpoint that proves
the setup works. It should not re-download a 300 MB image every time, and rebuilding dev
must never touch mgmt, which will run Argo CD.

`terraform/base` also owns the Proxmox pools: Home, Lab, Devbox and Templates. The
cluster nodes join Lab and the template joins Templates through `pool_id`, so a rebuilt
node lands in its pool again. Guests that OpenTofu does not manage go into their pool by
hand. Apply `terraform/base` before the first cluster, because the cluster roots expect
the Lab pool to exist.

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

cert-manager answers Let's Encrypt DNS-01 challenges through the Cloudflare API. The two
API tokens live in `~/.config/px-lab/cloudflare/` (mode 0600): `prod.token` for prod and
`nonprod.token` for the other clusters. Both may edit DNS records in the `px-lab.org`
zone only. `lab.sh platform` copies the right one into a Secret in the cluster; it never
enters git.

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
| `platform`   | Creates the namespaces and the Cloudflare token Secret, then installs cert-manager, Traefik, the Let's Encrypt issuers and the cluster's wildcard certificate with Helm |
| `verify`     | Checks the nodes, the system components, secrets encryption, Pod Security, where the tokens live, the platform, HTTPS through Traefik, and that a node cannot reach the home network |
| `down`       | Asks for the cluster name, backs up the state and runs `tofu destroy` |
| `rebuild`    | `down`, then `up`. `time bootstrap/lab.sh rebuild dev` is the rebuild drill |
| `backup`     | Copies the state files to `~/Documents/Backups/flowwallet-infra-state/` and compares them |

OpenTofu still asks before it applies or destroys anything. A plain
`tofu -chdir=terraform/clusters/dev apply` works too; the script adds the waiting, the
kubeconfig and the checks. It reads only the outputs that every cluster root exports in
the same shape.

## Platform

`bootstrap/lab.sh platform <cluster>`, which `up` also runs, installs the add-ons in
`platform/` with Helm:

1. The namespaces from `platform/namespaces/`. cert-manager and Traefik run under the
   restricted Pod Security profile, stricter than the cluster-wide baseline.
2. The Secret `cert-manager/cloudflare-api-token`, from the cluster's Cloudflare token file.
3. cert-manager v1.21.3 through the umbrella chart in `platform/cert-manager`.
4. Traefik v3.7.17 (chart 42.3.1) through the umbrella chart in `platform/traefik`. One
   replica answers on ports 80 and 443 of every node through k3s ServiceLB. HTTP redirects
   permanently to HTTPS, the dashboard is off, and the cluster's wildcard certificate is
   the default certificate.
5. `platform/cluster-tls`: two ClusterIssuers, `letsencrypt-staging` and `letsencrypt-prod`,
   which answer DNS-01 challenges in the `px-lab.org` zone, and a wildcard Certificate for
   `*.<cluster>.lab.px-lab.org` from the issuer named in `values-<cluster>.yaml`. The
   issuers carry no ACME email, because the repository is public.

Each cluster's issuer is set in `platform/cluster-tls/values-<cluster>.yaml`, and all four
use `letsencrypt-prod`. Let's Encrypt issues at most five certificates for the same set
of names in seven days, and every rebuild of a cluster asks for a new one. Before several
rebuilds of one cluster in the same week, switch its issuer to `letsencrypt-staging`, then
back. `lab.sh verify` calls the cluster with `curl -k` only while its certificate comes
from staging.

Applications need no certificate objects of their own: an Ingress for a name under
`*.<cluster>.lab.px-lab.org` gets the wildcard certificate from Traefik. Application
manifests use the standard Ingress resource, not Traefik's own CRDs, so the ingress
controller stays replaceable.

The cluster names resolve through a local DNS rewrite to the cluster's server, so they
work on the home network and over WireGuard. No port is forwarded from the internet.
`lab.sh verify` deploys the whoami app from `platform/smoke/`, calls
`https://whoami.<cluster>.lab.px-lab.org` and removes the app again.

The script stops when Helm reports a Pod Security warning. From stage 2, Argo CD installs
the same charts from the same paths, with the same release names.

## CI

CI runs on every push to `main` and on every pull request. It never talks to Proxmox or
to a cluster:

- `fmt` and `tofu`: `tofu fmt -check` over all code, and `tofu validate` in the base root
  and each cluster root.
- `roots`: no VM id, address or network clashes across the four cluster roots.
- `cloud-init`: `tofu test` renders the user-data of a server and an agent with mocked
  providers and checks that it parses and writes the expected files. The install script
  inside it is rendered for both roles and shellchecked.
- `pins`: the k3s version and both sha256 values in the module match the release on GitHub.
- `platform`: a pinned Helm pulls the charts, checks them against `platform/charts.sha256`,
  then lints and renders them, cluster-tls once per `values-<cluster>.yaml`.
- `shellcheck` over `bootstrap/` and `.github/scripts/`, and `gitleaks` over the whole
  history.

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
