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
  cat <<'EOF'
Usage: cluster-enable.sh [--member-name NAME] [--add-member NAME]...

Converts this standalone Incus server (built by setup-incus-host.sh) into the
first member of a cluster, without touching its instances:

  1. The OVN databases on this host start listening on OVN_ENCAP_IP
     (northbound tcp/6641, southbound tcp/6642) so other members' chassis can
     reach them, and this host's chassis and Incus are pointed at that
     address instead of the local sockets.
  2. cluster.https_address is set to OVN_ENCAP_IP:8443 (clustering can't use
     the wildcard address) and `incus cluster enable` is run.
  3. For each --add-member, a join token is printed for cluster-join.sh.

This host keeps running the only copy of the OVN databases, so it is a
single point of failure for OVN networking. Members must reach it on
tcp/6641-6642, and each other on tcp/8443 and udp/6081 (Geneve).

Options:
  --member-name NAME  Cluster name for this host (default: short hostname).
  --add-member NAME   Also create a join token for a new member NAME (its
                      short hostname). Repeat for several. More tokens can be
                      made later with `incus cluster add NAME`.
  --help              Show this help message.
EOF
}

MEMBER_NAME="$(hostname -s)"
ADD_MEMBERS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --member-name)
      [[ $# -ge 2 ]] || { echo 'Error: missing value for --member-name.' >&2; exit 1; }
      MEMBER_NAME="$2"
      shift 2
      ;;
    --add-member)
      [[ $# -ge 2 ]] || { echo 'Error: missing value for --add-member.' >&2; exit 1; }
      ADD_MEMBERS+=("$2")
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -f "${ENV_FILE}" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

: "${OVN_ENCAP_IP:?OVN_ENCAP_IP not set in ${ENV_FILE}}"
host_require_root_and_os

SERVER_INFO="$(incus query /1.0)" || fail 'unable to reach the local Incus server.'
CLUSTERED="$(jq -r '.environment.server_clustered // false' <<< "${SERVER_INFO}")"
[[ "$(incus storage list -f json | jq 'length')" != '0' ]] || fail 'Incus is not initialized here; run setup-incus-host.sh first.'
[[ -S /run/ovn/ovnnb_db.sock ]] || fail 'the OVN databases (ovn-central) do not run on this host; run this on the host setup-incus-host.sh built.'
ip -4 -o addr show | grep -qw "inet ${OVN_ENCAP_IP}" || fail "OVN_ENCAP_IP ${OVN_ENCAP_IP} is not an address of this host."

NORTHBOUND="tcp:${OVN_ENCAP_IP}:6641"
SOUTHBOUND="tcp:${OVN_ENCAP_IP}:6642"

step "OVN databases on ${OVN_ENCAP_IP} (northbound 6641, southbound 6642)"
# Listening addresses are ptcp:PORT:IP (port first), unlike the tcp:IP:PORT
# form clients use to connect.
ovn-nbctl set-connection "ptcp:6641:${OVN_ENCAP_IP}"
ovn-sbctl set-connection "ptcp:6642:${OVN_ENCAP_IP}"
for _ in $(seq 1 20); do
  ss -ltn | grep -q "${OVN_ENCAP_IP}:6641 " && ss -ltn | grep -q "${OVN_ENCAP_IP}:6642 " && break
  sleep 1
done
ss -ltn | grep -q "${OVN_ENCAP_IP}:6642 " || fail "OVN southbound is not listening on ${OVN_ENCAP_IP}:6642."

host_configure_ovn_chassis "${SOUTHBOUND}" "${OVN_ENCAP_IP}"

step "Incus OVN connection -> ${NORTHBOUND}"
incus config set network.ovn.northbound_connection="${NORTHBOUND}"

if [[ "${CLUSTERED}" == 'true' ]]; then
  step 'Already clustered, skipping cluster enable'
else
  step "Enabling clustering as member '${MEMBER_NAME}' on ${OVN_ENCAP_IP}:8443"
  incus config set cluster.https_address="${OVN_ENCAP_IP}:8443"
  incus cluster enable "${MEMBER_NAME}"
fi

for NEW_MEMBER in "${ADD_MEMBERS[@]}"; do
  step "Join token for '${NEW_MEMBER}' (single use; pass it to cluster-join.sh --token)"
  incus cluster add "${NEW_MEMBER}" </dev/null
done

step 'Done'
incus cluster list
echo
echo "OVN_CENTRAL_ADDRESS for joining hosts' .env: ${OVN_ENCAP_IP}"
echo "Join a host: on it, run: sudo host/cluster-join.sh --token <token from 'incus cluster add <name>'>"
