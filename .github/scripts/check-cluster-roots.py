#!/usr/bin/env python3
"""Cross-checks the four cluster roots, which the module cannot do from inside one root.

- VM ids and node addresses are unique across all clusters.
- A VM id mirrors its address: 2xy for 10.2.0.xy.
- No pod or service network overlaps another one, the lab network, or the home networks the lab routes to.

The roots are plain, uniform HCL, so a few regular expressions read them. The script fails if a root no longer
matches that shape, so a reformatted root cannot slip past it.
"""

import ipaddress
import pathlib
import re
import sys

ROOTS = pathlib.Path(__file__).resolve().parents[2] / "terraform" / "clusters"

# Networks the cluster CIDRs must stay clear of: trusted home LAN, lab, spare zone, WireGuard clients.
RESERVED = {
    "home LAN": "10.1.0.0/24",
    "lab": "10.2.0.0/24",
    "spare zone": "10.3.0.0/24",
    "WireGuard": "10.8.0.0/24",
}

NODE = re.compile(r'^\s*([a-z0-9-]+)\s*=\s*\{\s*vm_id\s*=\s*(\d+)\s*,\s*ip\s*=\s*"([0-9.]+)"', re.MULTILINE)
CIDR = re.compile(r'^\s*(pod_cidr|service_cidr)\s*=\s*"([0-9./]+)"', re.MULTILINE)


def main() -> int:
    errors = []
    nodes = []  # (cluster, name, vm_id, ip)
    networks = [(f"{name} network", ipaddress.ip_network(cidr)) for name, cidr in RESERVED.items()]

    roots = sorted(p for p in ROOTS.iterdir() if (p / "main.tf").is_file())
    if not roots:
        print(f"no cluster roots found under {ROOTS}")
        return 1

    for root in roots:
        text = (root / "main.tf").read_text()
        found_nodes = NODE.findall(text)
        found_cidrs = dict(CIDR.findall(text))
        if not found_nodes or set(found_cidrs) != {"pod_cidr", "service_cidr"}:
            errors.append(f"{root.name}: main.tf no longer has the expected shape (nodes, pod_cidr, service_cidr)")
            continue
        for name, vm_id, ip in found_nodes:
            nodes.append((root.name, name, int(vm_id), ipaddress.ip_address(ip)))
        for key, cidr in sorted(found_cidrs.items()):
            networks.append((f"{root.name} {key.split('_')[0]} network", ipaddress.ip_network(cidr)))

    for attr, label in ((2, "vm_id"), (3, "ip")):
        seen = {}
        for node in nodes:
            value = node[attr]
            if value in seen:
                errors.append(f"{label} {value} is used by {seen[value]} and by {node[0]}/{node[1]}")
            seen[value] = f"{node[0]}/{node[1]}"

    for cluster, name, vm_id, ip in nodes:
        expected = 200 + int(str(ip).rsplit(".", 1)[1])
        if vm_id != expected:
            errors.append(f"{cluster}/{name}: vm_id {vm_id} does not mirror {ip} (expected {expected})")

    for i, (name_a, net_a) in enumerate(networks):
        for name_b, net_b in networks[i + 1:]:
            if net_a.overlaps(net_b):
                errors.append(f"{name_a} {net_a} overlaps {name_b} {net_b}")

    for error in errors:
        print(f"error: {error}")
    if not errors:
        print(f"ok: {len(roots)} roots, {len(nodes)} nodes, {len(networks) - len(RESERVED)} cluster networks")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
