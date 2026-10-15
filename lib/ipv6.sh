#!/usr/bin/env bash
# Shared IPv6 helpers. Source this file after loading .env; do not execute it
# directly.
#
# IPv6 is optional and off until .env sets IPV6_SUBNET_PREFIX; without it every
# project network keeps ipv6.address=none and nothing below changes behaviour.
#
#   IPV6_SUBNET_PREFIX  The CIDR (no longer than /56) every project's /64 is
#                       carved from: the project's ID is the subnet number, so
#                       ID 24 of 2001:db8:1200::/48 is 2001:db8:1200:18::/64
#                       (the ID in hex, like the IPv4 side it follows).
#   IPV6_SUBNET_FROM_TOP  true: count the project subnets down from the top of the
#                       prefix (subnet number 255 minus the ID, so ID 24 of a /56
#                       is ...:e7::/64) instead of up from the bottom. A UniFi
#                       gateway hands its own VLANs the lowest free prefix IDs,
#                       so this keeps the two apart. Never change it once
#                       projects have IPv6; --enable-ipv6 renumbers them.
#   IPV6_NAT            false (default): routed. Instances get global addresses
#                       from the prefix, the uplink's upstream router must route
#                       each project /64 to its OVN router (the scripts print the
#                       route), and the per-instance firewall ACL is what keeps
#                       them private. true: NAT66. Use a ULA prefix (fd00::/8);
#                       instances reach the world through the router's uplink
#                       address and nothing is routed in.
#   IPV6_INTERNAL_CIDRS Source ranges allowed to reach an instance that has no
#                       public IPv4 (create-instance.sh --no-public-ip). Default:
#                       IPV6_SUBNET_PREFIX plus fe80::/10.

ipv6_enabled() { [[ -n "${IPV6_SUBNET_PREFIX:-}" ]]; }

# True when project networks are routed (global addresses, no NAT).
ipv6_routed() { ipv6_enabled && [[ "${IPV6_NAT:-false}" != 'true' ]]; }

# Fails unless IPV6_SUBNET_PREFIX is a valid prefix with room for project IDs.
ipv6_validate_prefix() {
  ipv6_enabled || return 0
  python3 -c '
import ipaddress, sys
try:
    net = ipaddress.IPv6Network(sys.argv[1], strict=True)
except ValueError as e:
    sys.exit(f"Error: IPV6_SUBNET_PREFIX {sys.argv[1]!r}: {e}")
if net.prefixlen > 56:
    sys.exit(f"Error: IPV6_SUBNET_PREFIX {net} is longer than /56; project IDs (up to 253) need 8 bits between it and the /64.")
' "${IPV6_SUBNET_PREFIX}"
}

# <project id> -> the project's subnet number inside the prefix.
ipv6_subnet_number() {
  if [[ "${IPV6_SUBNET_FROM_TOP:-false}" == 'true' ]]; then
    echo $(( 255 - $1 ))
  else
    echo "$1"
  fi
}

# <project id> -> the project's /64, e.g. 2001:db8:1200:18::/64.
ipv6_project_subnet() {
  python3 -c '
import ipaddress, sys
net = ipaddress.IPv6Network(sys.argv[1], strict=True)
print(ipaddress.IPv6Network((int(net.network_address) + (int(sys.argv[2]) << 64), 64)))
' "${IPV6_SUBNET_PREFIX}" "$(ipv6_subnet_number "$1")"
}

# <project id> -> the network's gateway address with prefix, e.g. 2001:db8:1200:18::1/64.
ipv6_project_gateway() {
  python3 -c '
import ipaddress, sys
net = ipaddress.IPv6Network(sys.argv[1], strict=True)
print(f"{ipaddress.IPv6Address(int(net.network_address) + (int(sys.argv[2]) << 64) + 1)}/64")
' "${IPV6_SUBNET_PREFIX}" "$(ipv6_subnet_number "$1")"
}

# Prints the source ranges allowed to reach an instance that is not public.
ipv6_internal_cidrs() {
  printf '%s\n' "${IPV6_INTERNAL_CIDRS:-${IPV6_SUBNET_PREFIX},fe80::/10}"
}

# Prints the network keys (one per line) for a project's IPv6 setting.
ipv6_network_keys() {
  local id="$1"
  if ipv6_enabled; then
    printf 'ipv6.address=%s\n' "$(ipv6_project_gateway "${id}")"
    printf 'ipv6.nat=%s\n' "$([[ "${IPV6_NAT:-false}" == 'true' ]] && echo true || echo false)"
  else
    printf 'ipv6.address=none\n'
  fi
}

# Prints the uplink's ipv6.routes: UPLINK_IPV6_ROUTES plus, when routed, the
# project prefix. Incus only lets a routed (ipv6.nat=false) OVN network use a
# subnet that lies inside its uplink's routes.
ipv6_uplink_routes() {
  python3 -c '
import sys
routes = [r.strip() for r in sys.argv[1].split(",") if r.strip()]
if sys.argv[2] and sys.argv[2] not in routes:
    routes.append(sys.argv[2])
print(",".join(routes))
' "${UPLINK_IPV6_ROUTES:-}" "$(ipv6_routed && printf '%s' "${IPV6_SUBNET_PREFIX}")"
}

# Warns when the uplink has no IPv6 gateway (project networks can't reach out
# without it). Returns 0 either way.
ipv6_check_uplink() {
  local uplink="$1"
  ipv6_enabled || return 0
  # A physical uplink has ipv6.gateway; a bridge uplink (labs) has ipv6.address.
  if [[ -z "$(incus network get "${uplink}" ipv6.gateway --project default 2>/dev/null)$(incus network get "${uplink}" ipv6.address --project default 2>/dev/null)" ]]; then
    echo "Warning: uplink '${uplink}' has no ipv6.gateway, so project networks get IPv6 addresses but no route out. Set it with host/uplink-ipv6.sh." >&2
  fi
  if ipv6_routed && [[ ",$(incus network get "${uplink}" ipv6.routes --project default 2>/dev/null)," != *",${IPV6_SUBNET_PREFIX},"* ]]; then
    echo "Error: uplink '${uplink}' ipv6.routes does not include ${IPV6_SUBNET_PREFIX}; Incus refuses routed project networks outside the uplink's routes. Run host/uplink-ipv6.sh." >&2
    return 1
  fi
}

# One line for the summaries: what the upstream router needs to reach a routed
# project network (nothing for NAT66 or IPv4-only). Incus 7.5 does not announce
# OVN project subnets over BGP, so the route has to exist on the router (a
# static route, or a BGP speaker of our own).
ipv6_route_note() {
  local network="$1" project="$2" route
  ipv6_routed || return 0
  route="$(ipv6_upstream_route "${network}" "${project}")"
  [[ -z "${route}" ]] || echo "the upstream router needs: ${route}"
}

# Prints what the upstream router needs for a routed project network:
# "<project /64> via <router uplink address>".
ipv6_upstream_route() {
  local network="$1" project="$2" subnet router
  ipv6_routed || return 0
  subnet="$(incus network get "${network}" ipv6.address --project "${project}" 2>/dev/null)"
  router="$(incus network get "${network}" volatile.network.ipv6.address --project "${project}" 2>/dev/null)"
  [[ -n "${subnet}" && "${subnet}" != 'none' ]] || return 0
  python3 -c '
import ipaddress, sys
print(ipaddress.IPv6Interface(sys.argv[1]).network, "via", sys.argv[2] or "(router uplink address not assigned yet)")
' "${subnet}" "${router}"
}

# An instance's IPv6 on its eth0 (the project network): the SLAAC address
# derived from its MAC when present, otherwise the first global address, so
# privacy (temporary) addresses are not picked up. Empty when it has none.
instance_internal_ipv6() {
  local instance="$1" project="$2" nic="${3:-eth0}" hwaddr
  hwaddr="$(incus config get "${instance}" "volatile.${nic}.hwaddr" --project "${project}" 2>/dev/null || true)"
  incus query "/1.0/instances/${instance}/state?project=${project}" 2>/dev/null \
    | jq -r --arg nic "${nic}" '.network[$nic].addresses[]? | select(.family == "inet6" and .scope == "global") | .address' \
    | python3 -c '
import ipaddress, sys
cands = []
for line in sys.stdin:
    line = line.strip()
    if line:
        cands.append(ipaddress.IPv6Address(line))
if not cands:
    sys.exit(0)
eui = None
mac = sys.argv[1].lower().replace("-", ":")
try:
    b = [int(x, 16) for x in mac.split(":")]
    if len(b) == 6:
        iid = bytes([b[0] ^ 2, b[1], b[2], 0xFF, 0xFE, b[3], b[4], b[5]])
        eui = int.from_bytes(iid, "big")
except ValueError:
    pass
for a in cands:
    if eui is not None and (int(a) & ((1 << 64) - 1)) == eui:
        print(a)
        sys.exit(0)
print(sorted(cands)[0])
' "${hwaddr}"
}
