#!/usr/bin/env bash
# Shared 1:1 NAT helpers for instances on OVN networks.
# Source this file after loading .env; do not execute it directly.
#
# Incus builds 1:1 NAT from two halves that must be configured together:
#   ingress  a network forward on the instance's OVN network whose listen
#            address is the public IP and whose target_address is the
#            instance (no port list = every port and protocol).
#   egress   ipv4.address.external on the instance NIC, which adds a per-NIC
#            SNAT rule so outbound traffic leaves from that same public IP.
#            Incus rejects this key unless the address is already a forward
#            on the NIC's network, so the forward is always created first.
# Before Incus 7.3 (upstream commit 42053c457d, "Fix NAT for network forward
# default targets") a default-target forward was a portless OVN load balancer
# that collided with the NIC's SNAT rule and dropped the SYN-ACKs of every
# connection the instance opened itself; nat_require_support refuses those
# versions.
# Forward listen addresses must fall inside the uplink network's ipv4.routes
# (ipv4.ovn.ranges is reserved for the OVN routers' own uplink addresses).

PUBLIC_IP_NIC='eth0'
PUBLIC_IP_CONFIG_KEY='user.public_ipv4'

nat_require_support() {
  local info version
  info="$(incus query /1.0 2>/dev/null)"
  jq -e '.api_extensions | index("network_ovn_external_nic_address")' >/dev/null <<< "${info}" \
    || { echo "Error: this Incus server lacks the 'network_ovn_external_nic_address' API extension required for 1:1 NAT." >&2; return 1; }
  version="$(jq -r '.environment.server_version // empty' <<< "${info}")"
  python3 -c '
import sys
v = tuple(int(x) for x in (sys.argv[1].split(".") + ["0", "0"])[:3])
sys.exit(0 if v >= (7, 3, 0) or (7, 0, 2) <= v < (7, 1, 0) else 1)
' "${version}" 2>/dev/null \
    || { echo "Error: Incus ${version:-unknown} has the forward/SNAT collision that breaks outbound TCP on 1:1 NAT instances; it is fixed in 7.3+ and the 7.0 LTS branch after 7.0.1." >&2; return 1; }
}

# Prints the uplink network backing an OVN network.
nat_network_uplink() {
  local network="$1" project="$2"
  incus network get "${network}" network --project "${project}" 2>/dev/null
}

# Prints the uplink's ipv4.routes, failing if none are defined.
nat_uplink_routes() {
  local uplink="$1" routes
  routes="$(incus network get "${uplink}" ipv4.routes --project default 2>/dev/null)"
  if [[ -z "${routes}" ]]; then
    echo "Error: uplink network '${uplink}' has no ipv4.routes. Public 1:1 NAT addresses must come from a range in ipv4.routes." >&2
    return 1
  fi
  printf '%s\n' "${routes}"
}

# Prints every IPv4 address already claimed on the uplink: forward and load
# balancer listen addresses, plus each OVN router's uplink address, across all
# projects' OVN networks that use this uplink.
nat_used_addresses() {
  local uplink="$1" project network
  while IFS= read -r project; do
    [[ -n "${project}" ]] || continue
    while IFS= read -r network; do
      [[ -n "${network}" ]] || continue
      incus network get "${network}" volatile.network.ipv4.address --project "${project}" </dev/null 2>/dev/null
      incus network forward list "${network}" --project "${project}" -f json </dev/null 2>/dev/null | jq -r '.[].listen_address'
      incus network load-balancer list "${network}" --project "${project}" -f json </dev/null 2>/dev/null | jq -r '.[].listen_address'
    done < <(incus network list --project "${project}" -f json </dev/null 2>/dev/null \
      | jq -r --arg u "${uplink}" '.[] | select(.type == "ovn" and .config.network == $u) | .name')
  done < <(incus project list -f json 2>/dev/null | jq -r '.[].name') | sed '/^$/d' | sort -u
}

# Checks that an address is a usable public IP: inside the uplink routes, not
# the uplink gateway or its subnet's network/broadcast address, and unused.
nat_validate_address() {
  local uplink="$1" address="$2" routes gateway
  routes="$(nat_uplink_routes "${uplink}")" || return 1
  gateway="$(incus network get "${uplink}" ipv4.gateway --project default 2>/dev/null)"
  nat_used_addresses "${uplink}" | python3 -c '
import ipaddress, sys
address, routes, gateway = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    ip = ipaddress.IPv4Address(address)
except ValueError:
    sys.exit(f"Error: {address!r} is not a valid IPv4 address.")
nets = [ipaddress.IPv4Network(r.strip(), strict=False) for r in routes.split(",") if r.strip()]
if not any(ip in n for n in nets):
    sys.exit(f"Error: {ip} is not inside the uplink ipv4.routes ({routes}).")
if gateway:
    gw = ipaddress.IPv4Interface(gateway)
    if ip in (gw.ip, gw.network.network_address, gw.network.broadcast_address):
        sys.exit(f"Error: {ip} is the uplink gateway or a network/broadcast address.")
used = {l.strip() for l in sys.stdin if l.strip()}
if str(ip) in used:
    sys.exit(f"Error: {ip} is already in use as a forward, load balancer or router address.")
' "${address}" "${routes}" "${gateway}"
}

# Prints the first free public IP inside the uplink routes.
nat_allocate_address() {
  local uplink="$1" routes gateway
  routes="$(nat_uplink_routes "${uplink}")" || return 1
  gateway="$(incus network get "${uplink}" ipv4.gateway --project default 2>/dev/null)"
  nat_used_addresses "${uplink}" | python3 -c '
import ipaddress, sys
routes, gateway = sys.argv[1], sys.argv[2]
used = {l.strip() for l in sys.stdin if l.strip()}
reserved = set()
if gateway:
    gw = ipaddress.IPv4Interface(gateway)
    reserved = {gw.ip, gw.network.network_address, gw.network.broadcast_address}
for route in routes.split(","):
    if not route.strip():
        continue
    for ip in ipaddress.IPv4Network(route.strip(), strict=False):
        if ip not in reserved and str(ip) not in used:
            print(ip)
            sys.exit(0)
sys.exit(f"Error: no free public IPv4 address left in uplink ipv4.routes ({routes}).")
' "${routes}" "${gateway}"
}

# Prints the instance currently using a public IP as its external address,
# or nothing if no instance in the project claims it.
nat_find_owner() {
  local project="$1" address="$2"
  incus list --project "${project}" -f json 2>/dev/null | jq -r --arg ip "${address}" --arg nic "${PUBLIC_IP_NIC}" \
    '.[] | select(.expanded_devices[$nic]["ipv4.address.external"] == $ip) | .name' | head -n1
}

# Sets keys on the instance's NIC, overriding the profile-inherited device
# when the instance doesn't have its own copy yet.
nat_set_nic() {
  local instance="$1" project="$2"
  shift 2
  if incus config device show "${instance}" --project "${project}" 2>/dev/null | grep -q "^${PUBLIC_IP_NIC}:"; then
    incus config device set "${instance}" "${PUBLIC_IP_NIC}" "$@" --project "${project}"
  else
    incus config device override "${instance}" "${PUBLIC_IP_NIC}" "$@" --project "${project}"
  fi
}

# Creates the 1:1 NAT mapping between a public IP and an instance.
# The internal address is pinned on the NIC so the forward target survives
# restarts; it is the instance's current address, so nothing is renumbered.
nat_attach() {
  local instance="$1" project="$2" network="$3" public_ip="$4" internal_ip="$5"

  incus network forward create "${network}" "${public_ip}" target_address="${internal_ip}" --project "${project}" || return 1

  if ! nat_set_nic "${instance}" "${project}" ipv4.address="${internal_ip}" ipv4.address.external="${public_ip}"; then
    echo "Error: unable to set ${PUBLIC_IP_NIC} external address on '${instance}'; removing forward ${public_ip}." >&2
    incus network forward delete "${network}" "${public_ip}" --project "${project}" >/dev/null 2>&1 || true
    return 1
  fi

  incus config set "${instance}" "${PUBLIC_IP_CONFIG_KEY}=${public_ip}" --project "${project}"
}

# Prints the instance's public IP from its config, falling back to the NIC.
nat_instance_address() {
  local instance="$1" project="$2" address
  address="$(incus config get "${instance}" "${PUBLIC_IP_CONFIG_KEY}" --project "${project}" 2>/dev/null || true)"
  if [[ -z "${address}" ]]; then
    address="$(incus query "/1.0/instances/${instance}?project=${project}" 2>/dev/null \
      | jq -r --arg nic "${PUBLIC_IP_NIC}" '.expanded_devices[$nic]["ipv4.address.external"] // empty')"
  fi
  printf '%s\n' "${address}"
}

# Removes the forward behind a public IP. Run after the instance is deleted.
nat_release() {
  local project="$1" network="$2" public_ip="$3"
  incus network forward delete "${network}" "${public_ip}" --project "${project}"
}
