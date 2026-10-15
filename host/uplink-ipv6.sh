#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOT'
Usage: uplink-ipv6.sh [--dry-run] [--remove]

Gives the OVN uplink network IPv6, for a host or cluster that was set up before
IPv6 existed (setup-incus-host.sh does the same for new hosts). It sets, from
.env:
  UPLINK_IPV6_GATEWAY      the upstream router's address on the uplink's /64,
                           with prefix length (e.g. 2001:db8:0:1::1/64)
  UPLINK_IPV6_OVN_RANGES   addresses on that /64 for the OVN routers' uplink
                           ports, one per project network (e.g.
                           2001:db8:0:1::10-2001:db8:0:1::ff)
  UPLINK_IPV6_ROUTES       optional: more prefixes for network forwards. With
                           routed IPv6 (IPV6_SUBNET_PREFIX, IPV6_NAT=false)
                           the project prefix is added to the routes
                           automatically: Incus only accepts routed networks
                           inside them.
  UPLINK_DNS_NAMESERVERS   optional: pushed to instances by DHCP and, for IPv6
                           addresses in the list, by router advertisement
                           (RDNSS); IPv4 and IPv6 resolvers can be mixed
It changes only the uplink; project networks get their /64 with
`deploy-project.sh --all-projects --enable-ipv6`. On a cluster, run it on any
one member. Existing instances and IPv4 are not touched.

Options:
  --dry-run   Show what would change.
  --remove    Take IPv6 off the uplink again (clears the three UPLINK_IPV6_*
              keys). Project networks with IPv6 must be set to none first.
  --help      Show this help message.
EOT
}

DRY_RUN=''
REMOVE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN='yes'; shift ;;
    --remove) REMOVE='yes'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

fail() { echo "Error: $*" >&2; exit 1; }

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ipv6.sh"
: "${UPLINK_NETWORK:?UPLINK_NETWORK not set in ${ENV_FILE}}"
command -v incus >/dev/null 2>&1 || fail 'incus command not found in PATH.'
incus network show "${UPLINK_NETWORK}" --project default >/dev/null 2>&1 || fail "uplink network '${UPLINK_NETWORK}' was not found."

# Sets one uplink key, skipping it when it already has the value.
set_key() {
  local key="$1" value="$2" have
  have="$(incus network get "${UPLINK_NETWORK}" "${key}" --project default 2>/dev/null || true)"
  if [[ "${have}" == "${value}" ]]; then
    echo "OK       ${key} = ${value:-<unset>}"
    return 0
  fi
  echo "Change   ${key}: ${have:-<unset>} -> ${value:-<unset>}"
  [[ -n "${DRY_RUN}" ]] && return 0
  if [[ -z "${value}" ]]; then
    incus network unset "${UPLINK_NETWORK}" "${key}" --project default
  else
    incus network set "${UPLINK_NETWORK}" "${key}=${value}" --project default
  fi
}

if [[ -n "${REMOVE}" ]]; then
  for key in ipv6.gateway ipv6.ovn.ranges ipv6.routes; do set_key "${key}" ''; done
  exit 0
fi

: "${UPLINK_IPV6_GATEWAY:?UPLINK_IPV6_GATEWAY not set in ${ENV_FILE}}"
: "${UPLINK_IPV6_OVN_RANGES:?UPLINK_IPV6_OVN_RANGES not set in ${ENV_FILE}}"

python3 -c '
import ipaddress, sys
gw = ipaddress.IPv6Interface(sys.argv[1])
if gw.network.prefixlen > 64:
    sys.exit(f"Error: UPLINK_IPV6_GATEWAY {gw} must have a prefix of /64 or shorter.")
for r in sys.argv[2].split(","):
    lo, _, hi = r.strip().partition("-")
    lo, hi = ipaddress.IPv6Address(lo), ipaddress.IPv6Address(hi or lo)
    if lo > hi or lo not in gw.network or hi not in gw.network:
        sys.exit(f"Error: UPLINK_IPV6_OVN_RANGES {r!r} is not inside the uplink network {gw.network}.")
    if lo <= gw.ip <= hi:
        sys.exit(f"Error: UPLINK_IPV6_OVN_RANGES {r!r} includes the gateway {gw.ip}.")
for r in filter(None, (x.strip() for x in sys.argv[3].split(","))):
    ipaddress.IPv6Network(r, strict=False)
' "${UPLINK_IPV6_GATEWAY}" "${UPLINK_IPV6_OVN_RANGES}" "${UPLINK_IPV6_ROUTES:-}" || exit 1

# Routed project networks must lie inside the uplink's routes, so the project
# prefix (IPV6_SUBNET_PREFIX, unless IPV6_NAT=true) is added to them below.
ipv6_validate_prefix || exit 1

set_key ipv6.gateway "${UPLINK_IPV6_GATEWAY}"
set_key ipv6.ovn.ranges "${UPLINK_IPV6_OVN_RANGES}"
set_key ipv6.routes "$(ipv6_uplink_routes)"
[[ -z "${UPLINK_DNS_NAMESERVERS:-}" ]] || set_key dns.nameservers "${UPLINK_DNS_NAMESERVERS}"

echo
[[ -n "${DRY_RUN}" ]] && echo 'Dry run: nothing was changed.' || incus network show "${UPLINK_NETWORK}" --project default | sed -n '/^config:/,/^description:/p'
