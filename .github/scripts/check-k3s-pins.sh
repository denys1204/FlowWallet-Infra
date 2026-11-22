#!/usr/bin/env bash
# Checks the k3s pin in the module against the release on GitHub: the sha256 of the k3s binary from the
# release's sha256sum-amd64.txt, and the sha256 of install.sh at the release tag. A wrong value in the
# module would otherwise show up only as a node whose cloud-init fails.
set -euo pipefail

vars="$(cd "$(dirname "$0")/../.." && pwd)/terraform/modules/k3s-cluster/variables.tf"
default() { sed -n "/^variable \"$1\"/,/^}/s/^ *default *= *\"\(.*\)\"/\1/p" "$vars"; }
sha256() { if command -v sha256sum > /dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

version=$(default k3s_version)
want_binary=$(default k3s_sha256)
want_install=$(default k3s_install_sha256)
[ -n "$version" ] && [ -n "$want_binary" ] && [ -n "$want_install" ] || { echo "cannot read the k3s pin from $vars"; exit 1; }
tag=${version/+/%2B}

got_binary=$(curl -fsSL --retry 3 "https://github.com/k3s-io/k3s/releases/download/$tag/sha256sum-amd64.txt" \
    | awk '$2 == "k3s" { print $1 }')
got_install=$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/k3s-io/k3s/$tag/install.sh" | sha256)

failed=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok: $1 matches the release ($2)"
    else
        echo "error: $1 is pinned as $2, but the $version release has ${3:-nothing}"
        failed=1
    fi
}
check "k3s binary sha256" "$want_binary" "$got_binary"
check "install.sh sha256" "$want_install" "$got_install"
exit "$failed"
