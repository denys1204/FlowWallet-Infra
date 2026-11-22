#!/usr/bin/env bash
# Brings up, checks, tears down and rebuilds one k3s cluster of the lab.
#
#   bootstrap/lab.sh up|down|rebuild|kubeconfig|platform|verify|backup <mgmt|dev|stage|prod>
#
#   backup      copy the cluster's state files to the backup folder and compare them
#   up          backup, tofu apply, wait for cloud-init and Ready nodes, kubeconfig, platform, verify
#   kubeconfig  fetch the cluster's kubeconfig into ~/.kube/px-lab/<cluster>.yaml (context px-<cluster>)
#   platform    install the add-ons from platform/ with helm (Argo CD takes this over in stage 2)
#   verify      check a running cluster; exits non-zero if any check fails
#   down        ask for the cluster name, backup, tofu destroy, drop the kubeconfig and host keys
#   rebuild     down, then up; `time bootstrap/lab.sh rebuild dev` is the rebuild drill
#
# OpenTofu keeps its own apply and destroy prompt. The state files are the only record of what
# exists on Proxmox, so they are copied and compared before every apply and destroy.
# Needs: tofu, kubectl, helm, jq, python3, ~/.ssh/id_ed25519 with its passphrase in the Keychain, the
# Proxmox credentials in ~/.config/proxmox/tf.env (read here when PROXMOX_VE_ENDPOINT is not set) and the
# Cloudflare tokens in ~/.config/px-lab/cloudflare/{prod,nonprod}.token (prod for prod, nonprod for the rest).

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
CF_TOKEN_DIR="$HOME/.config/px-lab/cloudflare"
LAB_DOMAIN="lab.px-lab.org"
PLATFORM_DIR="$REPO_ROOT/platform"
SSH_TIMEOUT=300     # seconds for a new VM to answer on ssh
READY_TIMEOUT=600   # seconds for every node to report Ready after cloud-init

# Addresses a lab node must not reach: Proxmox ssh and web UI, AdGuard DNS, the NPM admin UI, the devbox.
FORBIDDEN_TARGETS="10.1.0.2:22 10.1.0.2:8006 10.1.0.6:53 10.1.0.7:81 10.1.0.10:22"

CLUSTER=""
ROOT=""
FAILED=0
AGENT_STARTED=0
TOKEN_TMP=""

# Runs on every exit: stops the private ssh-agent and removes the token copy, whatever failed.
cleanup() {
    [ -z "$TOKEN_TMP" ] || rm -f "$TOKEN_TMP"
    [ "$AGENT_STARTED" -eq 0 ] || ssh-agent -k > /dev/null 2>&1 || true
}
trap cleanup EXIT

die() { printf 'lab.sh: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok    %s\n' "$*"; }
bad() { printf '    FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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
    AGENT_STARTED=1
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

    step "platform"
    got=$(kc -n cert-manager get deploy -o json 2> /dev/null | jq -r '[.items[]
        | select((.status.availableReplicas // 0) >= .spec.replicas) | .metadata.name] | sort | join(" ")' || true)
    [ "$got" = "cert-manager cert-manager-cainjector cert-manager-webhook" ] \
        && ok "cert-manager, cainjector and webhook available" || bad "available cert-manager deployments: '$got'"
    got=$(kc get ns cert-manager -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2> /dev/null || true)
    [ "$got" = "restricted" ] && ok "namespace cert-manager enforces Pod Security restricted" \
        || bad "namespace cert-manager enforces '$got', want restricted"
    got=$(kc get clusterissuer -o json 2> /dev/null | jq -r '[.items[]
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name] | sort | join(" ")' || true)
    [ "$got" = "letsencrypt-prod letsencrypt-staging" ] \
        && ok "ClusterIssuers letsencrypt-staging and letsencrypt-prod Ready" || bad "Ready ClusterIssuers: '$got'"
    # decoded only inside jq, which prints a verdict, never the token
    got=$(kc -n cert-manager get secret cloudflare-api-token -o json 2> /dev/null \
        | jq -r '.data["api-token"] // "" | @base64d | if length > 0 and (test("\\s") | not) then "ok" else "bad" end' || true)
    [ "$got" = "ok" ] && ok "Cloudflare token Secret present, no whitespace" || bad "Cloudflare token Secret missing or malformed"

    verify_ingress

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

    step "graceful shutdown"
    local delay
    while read -r name ip; do
        # single quotes on purpose: the $(...) runs on the node
        # shellcheck disable=SC2016
        got=$(node_ssh "$ip" 'systemd-inhibit --list --no-pager --no-legend; echo "max=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager InhibitDelayMaxUSec)"' || true)
        delay=${got##*max=t }
        case "$delay" in *[!0-9]* | "") delay="?" ;; *) delay="$((delay / 1000000))s" ;; esac
        case "$got" in
            *"Kubelet needs time to handle node shutdown"*) ok "$name: kubelet holds a shutdown delay (logind allows $delay)" ;;
            *) bad "$name: no kubelet shutdown delay, so a host shutdown kills its pods (logind allows $delay)" ;;
        esac
    done <<< "$NODES"

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
    verify_firewall

    echo
    if [ "$FAILED" -eq 0 ]; then
        echo "lab.sh: $CLUSTER passed every check"
    else
        die "$CLUSTER failed $FAILED check(s)"
    fi
}

# Traefik on the node IPs, the HTTP-to-HTTPS redirect, the wildcard certificate, and a request that goes
# all the way through: AdGuard name, ServiceLB, Traefik, TLS, an Ingress and a pod.
verify_ingress() {
    local host="x.$CLUSTER.$LAB_DOMAIN" want got issuer cert insecure="" smoke_host="whoami.$CLUSTER.$LAB_DOMAIN"
    step "ingress"
    got=$(kc -n traefik get deploy traefik -o jsonpath='{.status.availableReplicas}' 2> /dev/null || true)
    [ "${got:-0}" -ge 1 ] && ok "traefik available" || bad "traefik is not available"
    want=$(printf '%s\n' "$NODES" | awk '{print $2}' | sort | tr '\n' ' ')
    got=$(kc -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2> /dev/null | tr ' ' '\n' | sort | tr '\n' ' ' || true)
    [ "$got" = "$want" ] && ok "traefik answers on the node IPs: $got" || bad "traefik EXTERNAL-IP '$got', want '$want'"
    got=$(python3 -c 'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$host" 2> /dev/null || true)
    [ "$got" = "$SERVER_IP" ] && ok "$host resolves to $SERVER_IP (AdGuard rewrite)" \
        || bad "$host resolves to '$got', want $SERVER_IP: is this Mac using AdGuard (LAN or WireGuard)?"
    # A permanent redirect: Traefik answers 301 to GET and 308 to other methods, which keeps the method.
    got="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "http://$host/" 2> /dev/null || true)"
    got="$got / $(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -X POST --max-time 10 "http://$host/" 2> /dev/null || true)"
    case "$got" in
        "301 https://$host/ / 308 https://$host/") ok "http://$host redirects to https permanently (GET 301, POST 308)" ;;
        *) bad "http://$host answered '$got', want GET 301 and POST 308 to https" ;;
    esac
    got=$(kc -n traefik get certificate wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
    [ "$got" = "True" ] && ok "certificate traefik/wildcard Ready" || bad "certificate traefik/wildcard Ready='$got'"
    cert=$(openssl s_client -connect "$SERVER_IP:443" -servername "$host" < /dev/null 2> /dev/null \
        | openssl x509 -noout -issuer -text 2> /dev/null || true)
    issuer=$(printf '%s\n' "$cert" | grep -m1 -i '^issuer' || true)
    case "$cert" in
        *"DNS:*.$CLUSTER.$LAB_DOMAIN"*) ok "port 443 serves the wildcard for *.$CLUSTER.$LAB_DOMAIN ($issuer)" ;;
        *) bad "port 443 does not serve the wildcard certificate ($issuer)" ;;
    esac
    # The served certificate must come from the configured issuer. A staging certificate is not trusted by
    # design, so only then does curl get -k; a production one must pass curl's normal checks.
    want=$(wanted_issuer)
    case "$want:$issuer" in
        letsencrypt-staging:*STAGING*) insecure="-k"; ok "the certificate comes from $want, as configured" ;;
        letsencrypt-prod:*STAGING*) insecure="-k"; bad "values-$CLUSTER.yaml asks for $want, but port 443 still serves a staging certificate" ;;
        letsencrypt-prod:*"Let's Encrypt"*) ok "the certificate comes from $want, as configured" ;;
        *) bad "cannot match the served issuer ($issuer) with $want" ;;
    esac

    sed "s/CLUSTER/$CLUSTER/g" "$PLATFORM_DIR/smoke/whoami.yaml" | kc apply -f - > /dev/null
    if kc -n smoke rollout status deploy/whoami --timeout=120s > /dev/null 2>&1; then
        # Traefik answers 503 for a second or two after the pod is ready, until it sees the endpoints.
        local tries=0 code=""
        while :; do
            got=$(curl -sS $insecure --max-time 5 -w '\n%{http_code}' "https://$smoke_host/" 2> /dev/null || true)
            code=${got##*$'\n'}
            case "$got" in *"Hostname: whoami-"*) break ;; esac
            tries=$((tries + 1))
            [ "$tries" -lt 15 ] || break
            sleep 2
        done
        case "$got" in
            *"Hostname: whoami-"*) ok "https://$smoke_host answers through Traefik${insecure:+ (staging certificate, so -k)}" ;;
            *) bad "https://$smoke_host gave no whoami answer within 30 s (last HTTP status ${code:-none})" ;;
        esac
    else
        bad "the smoke app did not start"
    fi
    kc delete namespace smoke --wait=true --timeout=120s > /dev/null 2>&1 || bad "could not delete the smoke namespace"
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

# The node firewall of this cluster: loaded on every node, Debian's own nftables.service left off, the other
# clusters' nodes get no answer (mgmt only on the API server), and the home network cannot reach the kubelet.
# The probes start on the other clusters' nodes, so they test this cluster's rules whatever the others run.
verify_firewall() {
    step "cluster firewall"
    local name ip got table state other other_ip want port
    while read -r name ip; do
        got=$(node_ssh "$ip" 'sudo nft list table inet px_lab_fw > /dev/null 2>&1 && echo loaded || echo missing; systemctl is-enabled nftables 2> /dev/null || true' || true)
        table=$(printf '%s\n' "$got" | sed -n 1p)
        state=$(printf '%s\n' "$got" | sed -n 2p)
        [ "$table" = loaded ] && ok "$name: table inet px_lab_fw loaded" || bad "$name: the px_lab_fw table is missing"
        [ "$state" != enabled ] && ok "$name: nftables.service not enabled ($state)" \
            || bad "$name: nftables.service is enabled; its config flushes every rule, k3s's included"
    done <<< "$NODES"

    for other in $CLUSTERS; do
        [ "$other" = "$CLUSTER" ] && continue
        other_ip=$(tofu -chdir="$REPO_ROOT/terraform/clusters/$other" output -raw server_ip 2> /dev/null) || continue
        [ -n "$other_ip" ] || continue
        for port in 6443 443 22; do
            if [ "$other" = mgmt ] && [ "$port" = 6443 ]; then want=0; else want=124; fi
            got=$(probe_tcp "$other_ip" "$SERVER_IP" "$port")
            case "$want:$got" in
                0:0) ok "$other ($other_ip) reaches $SERVER_IP:$port, as Argo CD will" ;;
                124:124) ok "$other ($other_ip) gets no answer from $SERVER_IP:$port" ;;
                *) bad "$other ($other_ip) to $SERVER_IP:$port gave exit $got, want $want" ;;
            esac
        done
    done

    got=$(local_probe "$SERVER_IP" 6443)
    [ "$got" = 0 ] && ok "this Mac reaches $SERVER_IP:6443 (control)" || bad "this Mac cannot reach $SERVER_IP:6443 (exit $got)"
    while read -r name ip; do
        got=$(local_probe "$ip" 10250)
        [ "$got" = 124 ] && ok "this Mac gets no answer from the kubelet on $name ($ip:10250)" \
            || bad "the kubelet on $name ($ip:10250) answered this Mac (exit $got)"
    done <<< "$NODES"
}

# local_probe <host> <port>: a 3-second TCP connect from this Mac; prints 0, 124 (no answer) or 1 (refused).
local_probe() {
    python3 -c 'import socket, sys
s = socket.socket(); s.settimeout(3)
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); print(0)
except socket.timeout:
    print(124)
except OSError:
    print(1)' "$1" "$2"
}

# probe_tcp <from-node-ip> <host> <port>: prints the exit code of a 3-second TCP connect run on that node.
# 0 = connected, 124 = no answer (dropped), anything else = refused, or the probe itself failed.
probe_tcp() {
    local rc=0
    node_ssh "$1" "timeout 3 bash -c 'exec 3<>/dev/tcp/$2/$3'" 2> /dev/null || rc=$?
    echo "$rc"
}

# helm_install <release> <chart dir> <namespace> [helm args]: install or upgrade, wait until ready, and refuse the
# result if the API server warned about Pod Security (a warning means the namespace label is the only
# thing standing between the chart and a rejected pod).
helm_install() {
    local release=$1 chart=$2 namespace=$3 out
    shift 3
    if ! out=$(helm --kubeconfig "$KUBE_DIR/$CLUSTER.yaml" --kube-context "px-$CLUSTER" upgrade --install \
        "$release" "$chart" --namespace "$namespace" --wait --timeout 10m "$@" 2>&1); then
        printf '%s\n' "$out" | sed 's/^/          /' >&2
        die "helm could not install $release"
    fi
    case "$out" in
        *PodSecurity*)
            printf '%s\n' "$out" | sed 's/^/          /' >&2
            die "$release triggered Pod Security warnings" ;;
    esac
    ok "$release installed in $namespace ($(printf '%s\n' "$out" | awk '/^REVISION:/ {print "revision " $2}'))"
}

cmd_platform() {
    [ -f "$KUBE_DIR/$CLUSTER.yaml" ] || die "no kubeconfig for $CLUSTER yet (run: lab.sh kubeconfig $CLUSTER)"
    local token_name token_file
    # prod has its own Cloudflare token, so a leak from another cluster cannot stop prod's renewals
    if [ "$CLUSTER" = prod ]; then token_name=prod; else token_name=nonprod; fi
    token_file="$CF_TOKEN_DIR/$token_name.token"
    [ -r "$token_file" ] || die "missing $token_file"

    step "platform: charts"
    # The chart versions are pinned in Chart.lock; the content is pinned here, so a re-pushed tag is refused.
    helm dependency build "$PLATFORM_DIR/cert-manager" > /dev/null
    helm dependency build "$PLATFORM_DIR/traefik" > /dev/null
    (cd "$PLATFORM_DIR" && shasum -a 256 -c charts.sha256 > /dev/null) \
        || die "a pulled chart does not match platform/charts.sha256"
    ok "charts pulled and checked against platform/charts.sha256"

    step "platform: namespaces"
    kc apply -f "$PLATFORM_DIR/namespaces/" > /dev/null
    ok "namespaces from platform/namespaces applied"

    step "platform: Cloudflare token"
    # A copy without the trailing newline, which would otherwise end up inside the Authorization header.
    TOKEN_TMP=$(umask 077 && mktemp "$KUBE_DIR/.cf-token.XXXXXX")
    tr -d '\r\n' < "$token_file" > "$TOKEN_TMP"
    kc -n cert-manager create secret generic cloudflare-api-token --from-file=api-token="$TOKEN_TMP" \
        --dry-run=client -o yaml | kc apply -f - > /dev/null
    rm -f "$TOKEN_TMP"
    TOKEN_TMP=""
    ok "Secret cert-manager/cloudflare-api-token from $token_name.token"

    step "platform: cert-manager"
    helm_install cert-manager "$PLATFORM_DIR/cert-manager" cert-manager

    step "platform: traefik"
    helm_install traefik "$PLATFORM_DIR/traefik" traefik

    step "platform: cluster-tls"
    helm_install cluster-tls "$PLATFORM_DIR/cluster-tls" cert-manager -f "$PLATFORM_DIR/cluster-tls/values-$CLUSTER.yaml"
    kc wait --for=condition=Ready clusterissuer --all --timeout=180s > /dev/null \
        || die "the ClusterIssuers did not become Ready (ACME account registration with Let's Encrypt)"
    ok "ClusterIssuers Ready"
    # Wait until the Secret holds a certificate from the configured issuer. Waiting for Ready alone is not
    # enough after an issuer change: the old certificate keeps the condition True for a moment.
    # DNS-01 through Cloudflare and Let's Encrypt; an issuance takes one to two minutes.
    local issuer deadline=$((SECONDS + 300)) got ready
    issuer=$(wanted_issuer)
    while :; do
        got=$(kc -n traefik get secret wildcard-tls -o jsonpath='{.metadata.annotations.cert-manager\.io/issuer-name}' 2> /dev/null || true)
        ready=$(kc -n traefik get certificate wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
        [ "$got" = "$issuer" ] && [ "$ready" = "True" ] && break
        [ "$SECONDS" -lt "$deadline" ] \
            || die "no Ready wildcard certificate from $issuer after 300 s (kubectl -n traefik describe certificate wildcard)"
        sleep 5
    done
    ok "wildcard certificate *.$CLUSTER.$LAB_DOMAIN Ready, issued by $issuer"
}

# The issuer of the cluster's wildcard certificate, as configured in values-<cluster>.yaml.
wanted_issuer() {
    local issuer
    issuer=$(sed -n 's/^issuer: *//p' "$PLATFORM_DIR/cluster-tls/values-$CLUSTER.yaml")
    [ -n "$issuer" ] || issuer=$(sed -n 's/^issuer: *//p' "$PLATFORM_DIR/cluster-tls/values.yaml")
    printf '%s\n' "$issuer"
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
    cmd_platform
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
    for tool in tofu kubectl helm jq ssh python3; do
        command -v "$tool" > /dev/null || die "$tool is not installed"
    done
    # every command but backup talks to Proxmox or the nodes over ssh
    [ "$command" = backup ] || start_private_agent

    case "$command" in
        backup) cmd_backup ;;
        up) cmd_up ;;
        kubeconfig) cmd_kubeconfig ;;
        platform) cmd_platform ;;
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
