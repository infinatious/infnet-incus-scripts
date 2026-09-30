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

  1. The OVN databases on this host become a one-member OVN RAFT cluster
     (contents kept, standalone copies saved under
     /var/lib/ovn/standalone-backup) serving clients on OVN_ENCAP_IP
     (northbound tcp/6641, southbound tcp/6642). The other hosts listed in
     OVN_CENTRAL_ADDRESSES grow it to full size as they join with
     cluster-join.sh.
  2. This host's OVN chassis, its ovn-northd and Incus
     (network.ovn.northbound_connection) are pointed at every address in
     OVN_CENTRAL_ADDRESSES, so they fail over to whichever members are up.
  3. cluster.https_address is set to OVN_ENCAP_IP:8443 (clustering can't use
     the wildcard address) and `incus cluster enable` is run.
  4. For each --add-member, a join token is printed for cluster-join.sh.

OVN_CENTRAL_ADDRESSES must list this host's OVN_ENCAP_IP and be identical in
every member's .env. With three members the OVN databases and the Incus
database each keep working when any one host is down.

Safe to re-run, e.g. after changing OVN_CENTRAL_ADDRESSES: it only rewrites
the OVN settings and skips the steps already done.

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
host_load_ovn_central_addresses
host_is_ovn_central_member \
  || fail "OVN_CENTRAL_ADDRESSES (${OVN_CENTRAL_ADDRESSES}) must include this host's OVN_ENCAP_IP ${OVN_ENCAP_IP}."

SERVER_INFO="$(incus query /1.0)" || fail 'unable to reach the local Incus server.'
CLUSTERED="$(jq -r '.environment.server_clustered // false' <<< "${SERVER_INFO}")"
[[ "$(incus storage list -f json | jq 'length')" != '0' ]] || fail 'Incus is not initialized here; run setup-incus-host.sh first.'
[[ -S /run/ovn/ovnnb_db.sock ]] || fail 'the OVN databases (ovn-central) do not run on this host; run this on the host setup-incus-host.sh built.'
ip -4 -o addr show | grep -qw "inet ${OVN_ENCAP_IP}" || fail "OVN_ENCAP_IP ${OVN_ENCAP_IP} is not an address of this host."

# Client listeners now come from ovn-ctl (per host, on its own address). A
# listener stored in the database would be replicated to every member, where
# its address doesn't exist, so drop any left from older versions of this
# script while the database is still standalone.
if ovsdb-tool db-is-standalone /var/lib/ovn/ovnnb_db.db 2>/dev/null; then
  ovn-nbctl del-connection
  ovn-sbctl del-connection
fi

host_configure_ovn_central "${OVN_ENCAP_IP}"
host_configure_ovn_chassis "${OVN_SB_REMOTES}" "${OVN_ENCAP_IP}"

step "Incus OVN connection -> ${OVN_NB_REMOTES}"
incus config set network.ovn.northbound_connection="${OVN_NB_REMOTES}"

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
echo "Every member's .env needs OVN_CENTRAL_ADDRESSES='${OVN_CENTRAL_ADDRESSES}'."
echo "Join a host: on it, run: sudo host/cluster-join.sh --token <token from 'incus cluster add <name>'>"
echo "Join the other OVN members promptly: with two of three joined, OVN needs both up."
