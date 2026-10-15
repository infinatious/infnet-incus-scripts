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
Usage: bgp.sh [--dry-run] [--remove]

Makes Incus advertise the routed project networks (the IPv6 /64s of
deploy-project.sh) to the upstream router over BGP, so the router needs no
static route per project. Settings come from .env:
  BGP_LOCAL_ASN     Incus's private AS number (e.g. 65100), the same on every member
  BGP_PEER_ASN      the router's AS number (e.g. 65000)
  BGP_PEER_ADDRESS  the router's address that the hosts reach over their
                    management network (e.g. the UDM's 10.100.29.1)
  BGP_PEER_NAME     name of the peer on the uplink (default: udm)
  BGP_PASSWORD      optional TCP-MD5 password, the same on the router
  UPLINK_NETWORK    the uplink the peer is attached to

What it sets:
  every member   core.bgp_address=<its cluster address>:179 and
                 core.bgp_routerid=<its cluster address> (per member), plus
                 core.bgp_asn once for the cluster
  the uplink     bgp.peers.<name>.address / .asn (/ .password)
Project networks are then advertised by Incus itself while they are routed
(ipv6.nat=false); nothing is configured per project. The router's side is
printed by host/bgp-udm-config.sh. On a cluster, run this on any one member.

Options:
  --dry-run   Show what would change.
  --remove    Take BGP off again (peer, per-member addresses, ASN).
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
: "${UPLINK_NETWORK:?UPLINK_NETWORK not set in ${ENV_FILE}}"
command -v incus >/dev/null 2>&1 || fail 'incus command not found in PATH.'
command -v jq >/dev/null 2>&1 || fail 'jq not found.'
PEER_NAME="${BGP_PEER_NAME:-udm}"

# Cluster members as "<name> <address>" lines; a standalone host is one line.
members() {
  if [[ "$(incus query /1.0 | jq -r '.environment.server_clustered')" == 'true' ]]; then
    incus query /1.0/cluster/members?recursion=1 | jq -r '.[] | "\(.server_name) \(.url | sub("^https?://"; "") | sub(":[0-9]+$"; ""))"'
  else
    echo "- $(incus query /1.0 | jq -r '.environment.addresses[0]' | sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/')"
  fi
}

# set_config <key> <value> [member]: server config, skipped when already set.
set_config() {
  local key="$1" value="$2" member="${3:-}" have target=()
  [[ -z "${member}" || "${member}" == '-' ]] || target=(--target "${member}")
  have="$(incus config get "${key}" "${target[@]}" 2>/dev/null || true)"
  if [[ "${have}" == "${value}" ]]; then
    echo "OK       ${key}${member:+ (${member})} = ${value:-<unset>}"
    return 0
  fi
  echo "Change   ${key}${member:+ (${member})}: ${have:-<unset>} -> ${value:-<unset>}"
  [[ -n "${DRY_RUN}" ]] && return 0
  if [[ -z "${value}" ]]; then
    incus config unset "${key}" "${target[@]}" </dev/null
  else
    incus config set "${key}=${value}" "${target[@]}" </dev/null
  fi
}

set_uplink() {
  local key="$1" value="$2" have
  have="$(incus network get "${UPLINK_NETWORK}" "${key}" --project default 2>/dev/null || true)"
  if [[ "${have}" == "${value}" ]]; then
    echo "OK       ${UPLINK_NETWORK} ${key} = ${value:-<unset>}"
    return 0
  fi
  echo "Change   ${UPLINK_NETWORK} ${key}: ${have:+<set>}${have:-<unset>} -> ${value:+<set>}${value:-<unset>}"
  [[ -n "${DRY_RUN}" ]] && return 0
  if [[ -z "${value}" ]]; then
    incus network unset "${UPLINK_NETWORK}" "${key}" --project default </dev/null
  else
    incus network set "${UPLINK_NETWORK}" "${key}=${value}" --project default </dev/null
  fi
}

if [[ -n "${REMOVE}" ]]; then
  for key in address asn password; do set_uplink "bgp.peers.${PEER_NAME}.${key}" ''; done
  while read -r name address; do
    set_config core.bgp_address '' "${name}"
    set_config core.bgp_routerid '' "${name}"
  done < <(members)
  set_config core.bgp_asn ''
  exit 0
fi

: "${BGP_LOCAL_ASN:?BGP_LOCAL_ASN not set in ${ENV_FILE}}"
: "${BGP_PEER_ASN:?BGP_PEER_ASN not set in ${ENV_FILE}}"
: "${BGP_PEER_ADDRESS:?BGP_PEER_ADDRESS not set in ${ENV_FILE}}"
[[ "${BGP_LOCAL_ASN}" =~ ^[0-9]+$ && "${BGP_PEER_ASN}" =~ ^[0-9]+$ ]] || fail 'BGP_LOCAL_ASN and BGP_PEER_ASN must be numbers.'
[[ "${BGP_LOCAL_ASN}" != "${BGP_PEER_ASN}" ]] || fail 'BGP_LOCAL_ASN and BGP_PEER_ASN are equal; the sessions are meant to be eBGP (different AS numbers).'
incus network show "${UPLINK_NETWORK}" --project default >/dev/null 2>&1 || fail "uplink network '${UPLINK_NETWORK}' was not found."

set_config core.bgp_asn "${BGP_LOCAL_ASN}"
while read -r name address; do
  [[ -n "${address}" ]] || continue
  set_config core.bgp_address "${address}:179" "${name}"
  set_config core.bgp_routerid "${address}" "${name}"
done < <(members)
set_uplink "bgp.peers.${PEER_NAME}.address" "${BGP_PEER_ADDRESS}"
set_uplink "bgp.peers.${PEER_NAME}.asn" "${BGP_PEER_ASN}"
[[ -z "${BGP_PASSWORD:-}" ]] || set_uplink "bgp.peers.${PEER_NAME}.password" "${BGP_PASSWORD}"

echo
if [[ -n "${DRY_RUN}" ]]; then
  echo 'Dry run: nothing was changed.'
else
  echo "Next: load the router's side (host/bgp-udm-config.sh prints it), then check the sessions: ss -tn state established '( sport = :179 or dport = :179 )' on each member."
fi
