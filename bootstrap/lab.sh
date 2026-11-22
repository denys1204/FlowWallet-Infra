#!/usr/bin/env bash
# Brings up, checks, tears down and rebuilds one k3s cluster of the lab.
#
#   bootstrap/lab.sh up|down|rebuild|kubeconfig|verify|backup <mgmt|dev|stage|prod>
#
#   backup      copy the cluster's state files to the backup folder and compare them
#   up          backup, tofu apply, wait for cloud-init and Ready nodes, fetch the kubeconfig, verify
#   kubeconfig  fetch the cluster's kubeconfig into ~/.kube/px-lab/<cluster>.yaml (context px-<cluster>)
#   verify      check a running cluster; exits non-zero if any check fails
#   down        ask for the cluster name, backup, tofu destroy, drop the kubeconfig and host keys
#   rebuild     down, then up; `time bootstrap/lab.sh rebuild dev` is the rebuild drill
#
# OpenTofu keeps its own apply and destroy prompt. The state files are the only record of what
# exists on Proxmox, so they are copied and compared before every apply and destroy.
# Needs: tofu, kubectl, jq, ssh with ~/.ssh/id_ed25519 loaded into the agent, and the Proxmox
# credentials in ~/.config/proxmox/tf.env (read here when PROXMOX_VE_ENDPOINT is not set).

# ok() always succeeds, so the `test && ok || bad` lines below never run both branches.
# shellcheck disable=SC2015
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLUSTERS="mgmt dev stage prod"
SSH_KEY="$HOME/.ssh/id_ed25519"
KUBE_DIR="$HOME/.kube/px-lab"
KNOWN_HOSTS="$KUBE_DIR/known_hosts"
BACKUP_ROOT="$HOME/Documents/Backups/flowwallet-infra-state"
TF_ENV="$HOME/.config/proxmox/tf.env"
SSH_TIMEOUT=300     # seconds for a new VM to answer on ssh
READY_TIMEOUT=600   # seconds for every node to report Ready after cloud-init

# Addresses a lab node must not reach: Proxmox ssh and web UI, AdGuard DNS, the NPM admin UI, the devbox.
FORBIDDEN_TARGETS="10.1.0.2:22 10.1.0.2:8006 10.1.0.6:53 10.1.0.7:81 10.1.0.10:22"

CLUSTER=""
ROOT=""
FAILED=0

die() { printf 'lab.sh: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok    %s\n' "$*"; }
bad() { printf '    FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

tf() { tofu -chdir="$ROOT" "$@"; }
kc() { kubectl --kubeconfig "$KUBE_DIR/$CLUSTER.yaml" --context "px-$CLUSTER" "$@"; }

# -n: never read stdin, which in the `while read ... <<< "$NODES"` loops holds the remaining nodes.
node_ssh() {
    local ip=$1
    shift
    ssh -n -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o StrictHostKeyChecking=accept-new "$USERNAME@$ip" "$@"
}

load_env() {
    if [ -z "${PROXMOX_VE_ENDPOINT:-}" ]; then
        [ -f "$TF_ENV" ] || die "PROXMOX_VE_* not set and $TF_ENV missing"
        set -a
        # shellcheck source=/dev/null
        . "$TF_ENV"
        set +a
    fi
}

# The Proxmox provider uploads the cloud-init snippets over ssh with every key the agent offers, and it
# cannot be told which one to use. With many keys loaded, sshd stops after MaxAuthTries (6) before it
# reaches the lab key. So lab.sh runs its own agent holding only the lab key, with the passphrase taken
# from the macOS Keychain, and stops it on exit.
start_private_agent() {
    eval "$(ssh-agent -s)" > /dev/null
    trap 'ssh-agent -k > /dev/null 2>&1' EXIT
    ssh-add --apple-use-keychain "$SSH_KEY" < /dev/null > /dev/null 2>&1 \
        || die "cannot load $SSH_KEY without a prompt; store its passphrase once: ssh-add --apple-use-keychain $SSH_KEY"
}

# Reads the root's outputs. They are the only contract between the module and this script.
read_outputs() {
    local out
    out=$(tf output -json)
    [ "$(printf '%s' "$out" | jq 'has("server_ip")')" = "true" ] \
        || die "$CLUSTER has no outputs: the cluster does not exist yet (run: lab.sh up $CLUSTER)"
    SERVER_IP=$(printf '%s' "$out" | jq -r '.server_ip.value')
    USERNAME=$(printf '%s' "$out" | jq -r '.username.value')
    K3S_VERSION=$(printf '%s' "$out" | jq -r '.k3s_version.value')
    POD_CIDR=$(printf '%s' "$out" | jq -r '.pod_cidr.value')
    # "name ip" lines, server first
    NODES=$(printf '%s' "$out" | jq -r --arg s "$SERVER_IP" \
        '.nodes.value | to_entries | sort_by(.value != $s) | .[] | "\(.key) \(.value)"')
    NODE_COUNT=$(printf '%s\n' "$NODES" | grep -c .)
}

cmd_backup() {
    local stamp dest f copied=0
    stamp=$(date +%Y-%m-%d-%H%M%S)
    dest="$BACKUP_ROOT/$stamp/$CLUSTER"
    for f in terraform.tfstate terraform.tfstate.backup; do
        [ -f "$ROOT/$f" ] || continue
        (umask 077 && mkdir -p "$dest")
        cp -p "$ROOT/$f" "$dest/$f"
        cmp -s "$ROOT/$f" "$dest/$f" || die "backup of $f differs from the original"
        copied=$((copied + 1))
    done
    if [ "$copied" -eq 0 ]; then
        echo "lab.sh: $CLUSTER has no state yet, nothing to back up"
    else
        echo "lab.sh: state of $CLUSTER copied to $dest ($copied files, compared)"
    fi
}

wait_for_ssh() {
    local name ip deadline
    while read -r name ip; do
        deadline=$((SECONDS + SSH_TIMEOUT))
        until node_ssh "$ip" true 2>/dev/null; do
            [ "$SECONDS" -lt "$deadline" ] || die "$name ($ip) does not answer on ssh after ${SSH_TIMEOUT}s"
            sleep 5
        done
        ok "$name answers on ssh"
    done <<< "$NODES"
}

wait_for_cloud_init() {
    local name ip rc
    while read -r name ip; do
        rc=0
        node_ssh "$ip" 'sudo cloud-init status --wait' > /dev/null || rc=$?
        case "$rc" in
            0) ok "$name: cloud-init done" ;;
            # 2 = finished with recoverable errors, such as deprecated keys: show them, carry on
            2) ok "$name: cloud-init done with warnings"
               node_ssh "$ip" 'sudo cloud-init status --long' | sed 's/^/          /' || true ;;
            *) node_ssh "$ip" 'sudo cloud-init status --long; sudo tail -n 30 /var/log/cloud-init-output.log' \
                   | sed 's/^/          /' || true
               die "$name: cloud-init failed (exit $rc), so k3s may not be installed" ;;
        esac
    done <<< "$NODES"
}

wait_for_ready() {
    local deadline ready name ip status
    deadline=$((SECONDS + READY_TIMEOUT))
    while :; do
        ready=$(kc get nodes --no-headers 2> /dev/null | awk '$2 == "Ready"' | grep -c . || true)
        [ "$ready" -eq "$NODE_COUNT" ] && break
        if [ "$SECONDS" -ge "$deadline" ]; then
            while read -r name ip; do
                status=$(kc get node "$name" \
                    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || echo "not registered")
                [ "$status" = "True" ] || echo "    $name ($ip): Ready=$status" >&2
            done <<< "$NODES"
            die "not every node is Ready after ${READY_TIMEOUT}s"
        fi
        sleep 5
    done
    ok "all $NODE_COUNT nodes Ready"
}

# k3s applies its packaged add-ons a little after the API answers, and their images still have to be pulled.
wait_for_system() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    until kc -n kube-system get deploy coredns local-path-provisioner metrics-server > /dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || die "the k3s add-ons were not created within ${READY_TIMEOUT}s"
        sleep 5
    done
    # rollout status, not `wait --for=condition=Available`: these deployments set maxUnavailable 1 with one
    # replica, so Available is already true while no pod is running yet.
    local d
    for d in coredns local-path-provisioner metrics-server; do
        kc -n kube-system rollout status "deploy/$d" --timeout="${READY_TIMEOUT}s" > /dev/null \
            || die "$d did not become available within ${READY_TIMEOUT}s"
    done
    ok "coredns, local-path-provisioner and metrics-server available"
}

cmd_kubeconfig() {
    read_outputs
    local tmp target="$KUBE_DIR/$CLUSTER.yaml"
    (umask 077 && mkdir -p "$KUBE_DIR")
    tmp=$(mktemp "$KUBE_DIR/.$CLUSTER.XXXXXX")
    # k3s names everything "default" and points at 127.0.0.1; rename to px-<cluster> and use the server address.
    node_ssh "$SERVER_IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed -e "s#https://127.0.0.1:6443#https://$SERVER_IP:6443#" -e "s/: default\$/: px-$CLUSTER/" > "$tmp" \
        || { rm -f "$tmp"; die "could not read the kubeconfig from $SERVER_IP"; }
    chmod 600 "$tmp"
    [ "$(kubectl --kubeconfig "$tmp" config get-contexts -o name)" = "px-$CLUSTER" ] \
        || { rm -f "$tmp"; die "the fetched kubeconfig has no single context px-$CLUSTER"; }
    mv "$tmp" "$target"
    echo "lab.sh: wrote $target (context px-$CLUSTER; new shells pick it up through KUBECONFIG)"
}

cmd_verify() {
    read_outputs
    [ -f "$KUBE_DIR/$CLUSTER.yaml" ] || die "no kubeconfig for $CLUSTER yet (run: lab.sh kubeconfig $CLUSTER)"
    FAILED=0
    local name ip got first_ip ready version address label range
    first_ip=$(printf '%s\n' "$NODES" | awk 'NR == 1 {print $2}')

    step "nodes"
    while read -r name ip; do
        # "|" keeps empty fields apart, unlike whitespace
        got=$(kc get node "$name" -o json 2> /dev/null | jq -r '[
            ([.status.conditions[]? | select(.type == "Ready") | .status][0]),
            .status.nodeInfo.kubeletVersion,
            ([.status.addresses[]? | select(.type == "InternalIP") | .address][0]),
            .metadata.labels["px-lab.org/cluster"],
            .spec.podCIDR] | map(. // "-") | join("|")') || { bad "$name is not registered"; continue; }
        IFS='|' read -r ready version address label range <<< "$got"
        [ "$ready" = "True" ] && [ "$version" = "$K3S_VERSION" ] && [ "$address" = "$ip" ] && [ "$label" = "$CLUSTER" ] \
            && ok "$name Ready, $version, $address, label $label" \
            || bad "$name: Ready=$ready version=$version (want $K3S_VERSION) ip=$address (want $ip) label=$label (want $CLUSTER)"
        if python3 -c 'import ipaddress, sys; sys.exit(not ipaddress.ip_network(sys.argv[1]).subnet_of(ipaddress.ip_network(sys.argv[2])))' \
            "$range" "$POD_CIDR" 2> /dev/null; then
            ok "$name pod range $range lies in $POD_CIDR"
        else
            bad "$name pod range $range is outside $POD_CIDR"
        fi
    done <<< "$NODES"

    step "system components"
    got=$(kc -n kube-system get deploy -o json | jq -r '[.items[]
        | select((.status.availableReplicas // 0) >= .spec.replicas) | .metadata.name] | sort | join(" ")')
    [ "$got" = "coredns local-path-provisioner metrics-server" ] \
        && ok "kube-system runs exactly coredns, local-path-provisioner, metrics-server, all available" \
        || bad "available kube-system deployments: '$got'"
    if got=$(kc get crd -o name); then
        case "$got" in
            *helm.cattle.io*) bad "helm.cattle.io CRDs present: helm-controller is running" ;;
            *) ok "no helm.cattle.io CRDs (helm-controller off)" ;;
        esac
    else
        bad "cannot list CRDs"
    fi

    step "server hardening"
    got=$(node_ssh "$SERVER_IP" 'sudo k3s secrets-encrypt status' || true)
    case "$got" in
        *"Encryption Status: Enabled"*) ok "secrets encryption enabled" ;;
        *) bad "secrets encryption is not enabled" ;;
    esac
    got=$(node_ssh "$SERVER_IP" 'sudo grep -c secretbox /var/lib/rancher/k3s/server/cred/encryption-config.json' || true)
    [ "${got:-0}" -ge 1 ] && ok "encryption provider is secretbox" || bad "secretbox missing from encryption-config.json"
    if got=$(kc -n default run "psa-probe-$$" --image=busybox --privileged --restart=Never --dry-run=server -- true 2>&1); then
        bad "a privileged pod was admitted in namespace default"
    else
        case "$got" in
            *"violates PodSecurity"*) ok "a privileged pod is rejected by Pod Security (baseline)" ;;
            *) bad "privileged pod probe failed for another reason: $got" ;;
        esac
    fi

    step "secrets outside the server"
    while read -r name ip; do
        [ "$ip" = "$SERVER_IP" ] && continue
        got=$(node_ssh "$ip" 'sudo grep -c "::server:" /etc/rancher/k3s/config.yaml' || true)
        [ "${got:-0}" -eq 0 ] && ok "$name holds no server token" || bad "$name holds the server token"
    done <<< "$NODES"
    # held in a variable only to search it; never printed
    if got=$(tf show -json); then
        case "$got" in
            *"::server:"*) bad "the OpenTofu state holds the server token" ;;
            *) ok "the OpenTofu state holds no server token" ;;
        esac
    else
        bad "cannot read the OpenTofu state"
    fi
    got=$(stat -f %Lp "$KUBE_DIR/$CLUSTER.yaml")
    [ "$got" = "600" ] && ok "kubeconfig is 0600" || bad "kubeconfig mode is $got"

    step "isolation (from $first_ip)"
    got=$(probe_tcp "$first_ip" 1.1.1.1 443)
    [ "$got" = 0 ] && ok "1.1.1.1:443 connects (control: the probe itself works)" \
        || bad "the control probe to 1.1.1.1:443 failed (exit $got), so the checks below prove nothing"
    local target
    for target in $FORBIDDEN_TARGETS; do
        got=$(probe_tcp "$first_ip" "${target%:*}" "${target#*:}")
        case "$got" in
            124) ok "$target gets no answer (dropped)" ;;
            0) bad "$target is reachable from the lab" ;;
            *) bad "$target answered or the probe failed (exit $got); the firewall should drop it silently" ;;
        esac
    done
    verify_ipv6

    echo
    if [ "$FAILED" -eq 0 ]; then
        echo "lab.sh: $CLUSTER passed every check"
    else
        die "$CLUSTER failed $FAILED check(s)"
    fi
}

# The lab bridge drops every IPv6 frame. On a cluster with two nodes, show that a TCP connection to the
# other node's link-local address fails while the same probe to the node's own address works.
verify_ipv6() {
    [ "$NODE_COUNT" -ge 2 ] || { ok "IPv6 between nodes: single-node cluster, nothing to probe"; return 0; }
    local a_ip b_name b_ip iface own other
    a_ip=$(printf '%s\n' "$NODES" | awk 'NR == 1 {print $2}')
    b_name=$(printf '%s\n' "$NODES" | awk 'NR == 2 {print $1}')
    b_ip=$(printf '%s\n' "$NODES" | awk 'NR == 2 {print $2}')
    # link-local address of the interface that carries the default route, i.e. the lab NIC
    local lab_ll="dev=\$(ip -o -4 route show default | awk '{print \$5}'); ip -6 -o addr show dev \"\$dev\" scope link | awk '{print \$4}' | cut -d/ -f1"
    iface=$(node_ssh "$a_ip" "ip -o -4 route show default | awk '{print \$5}'")
    own=$(node_ssh "$a_ip" "$lab_ll")
    other=$(node_ssh "$b_ip" "$lab_ll")
    if [ -z "$other" ]; then
        ok "IPv6: $b_name has no link-local address"
        return 0
    fi
    if [ -z "$own" ] || [ "$(probe_tcp "$a_ip" "$own%$iface" 22)" != 0 ]; then
        bad "IPv6 probe does not work even towards the node itself, so it proves nothing"
        return 0
    fi
    local rc
    rc=$(probe_tcp "$a_ip" "$other%$iface" 22)
    case "$rc" in
        124) ok "IPv6 to $b_name ($other) gets no answer (dropped by the bridge)" ;;
        0) bad "IPv6 reaches $b_name ($other) across the lab bridge" ;;
        *) bad "IPv6 probe to $b_name failed in an unexpected way (exit $rc)" ;;
    esac
}

# probe_tcp <from-node-ip> <host> <port>: prints the exit code of a 3-second TCP connect run on that node.
# 0 = connected, 124 = no answer (dropped), anything else = refused, or the probe itself failed.
probe_tcp() {
    local rc=0
    node_ssh "$1" "timeout 3 bash -c 'exec 3<>/dev/tcp/$2/$3'" 2> /dev/null || rc=$?
    echo "$rc"
}

cmd_up() {
    load_env
    step "backup"
    cmd_backup
    step "tofu apply"
    tf apply
    read_outputs
    (umask 077 && mkdir -p "$KUBE_DIR" && touch "$KNOWN_HOSTS")
    local name ip
    # New VMs come with new host keys; forget the old ones for these addresses.
    while read -r name ip; do
        ssh-keygen -R "$ip" -f "$KNOWN_HOSTS" > /dev/null 2>&1 || true
    done <<< "$NODES"
    step "ssh"
    wait_for_ssh
    step "cloud-init (installs k3s)"
    wait_for_cloud_init
    step "kubeconfig"
    cmd_kubeconfig
    step "nodes Ready"
    wait_for_ready
    wait_for_system
    cmd_verify
}

cmd_down() {
    load_env
    local answer name ip nodes=""
    if tf output -json | jq -e 'has("nodes")' > /dev/null; then
        nodes=$(tf output -json nodes | jq -r 'to_entries[] | "\(.key) \(.value)"')
    fi
    printf 'This destroys every VM of the %s cluster. Type the cluster name to go on: ' "$CLUSTER"
    read -r answer
    [ "$answer" = "$CLUSTER" ] || die "cancelled"
    step "backup"
    cmd_backup
    step "tofu destroy"
    tf destroy
    rm -f "$KUBE_DIR/$CLUSTER.yaml"
    if [ -n "$nodes" ] && [ -f "$KNOWN_HOSTS" ]; then
        while read -r name ip; do
            ssh-keygen -R "$ip" -f "$KNOWN_HOSTS" > /dev/null 2>&1 || true
        done <<< "$nodes"
    fi
    echo "lab.sh: $CLUSTER destroyed; kubeconfig and host keys removed"
}

main() {
    [ $# -eq 2 ] || usage
    local command=$1
    CLUSTER=$2
    case " $CLUSTERS " in
        *" $CLUSTER "*) ;;
        *) die "unknown cluster '$CLUSTER' (one of: $CLUSTERS)" ;;
    esac
    ROOT="$REPO_ROOT/terraform/clusters/$CLUSTER"
    local tool
    for tool in tofu kubectl jq ssh python3; do
        command -v "$tool" > /dev/null || die "$tool is not installed"
    done
    # every command but backup talks to Proxmox or the nodes over ssh
    [ "$command" = backup ] || start_private_agent

    case "$command" in
        backup) cmd_backup ;;
        up) cmd_up ;;
        kubeconfig) cmd_kubeconfig ;;
        verify) cmd_verify ;;
        down) cmd_down ;;
        # Two statements, not `cmd_down && cmd_up`: inside an && list bash ignores set -e,
        # so a failed destroy would carry on into apply.
        rebuild)
            cmd_down
            cmd_up
            ;;
        *) usage ;;
    esac
}

main "$@"
