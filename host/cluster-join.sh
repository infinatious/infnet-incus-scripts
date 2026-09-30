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
Usage: cluster-join.sh --token TOKEN [--wipe-storage-device]

Turns a clean Ubuntu host into a new member of an existing Incus cluster
(one made with cluster-enable.sh): installs the same packages as
setup-incus-host.sh, points this host's OVN chassis at the cluster's OVN
databases, and joins with this host's own storage disk and uplink NIC. It
also sets up the NFS backup mount, the backup timer and the UI branding.

Get TOKEN on an existing member with `incus cluster add <this host's short
hostname>` (or cluster-enable.sh --add-member). Everything cluster-wide
(networks, projects, profiles, OIDC) comes from the cluster.

This host's .env needs its own STORAGE_DEVICE, UPLINK_PARENT (on the same
public network as the other members) and OVN_ENCAP_IP, plus
OVN_CENTRAL_ADDRESS (the host running the OVN databases).

Options:
  --token TOKEN          Join token from `incus cluster add`.
  --wipe-storage-device  Erase existing partition/ZFS signatures on
                         STORAGE_DEVICE first. Destroys everything on it.
  --help                 Show this help message.
EOF
}

TOKEN=''
WIPE_STORAGE_DEVICE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      [[ $# -ge 2 ]] || { echo 'Error: missing value for --token.' >&2; exit 1; }
      TOKEN="$2"
      shift 2
      ;;
    --wipe-storage-device) WIPE_STORAGE_DEVICE='yes'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "${TOKEN}" ]] || { echo 'Error: --token is required (see --help).' >&2; exit 1; }

[[ -f "${ENV_FILE}" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

: "${INCUS_CHANNEL:?INCUS_CHANNEL not set in ${ENV_FILE}}"
: "${INCUS_ADMIN_USER:?INCUS_ADMIN_USER not set in ${ENV_FILE}}"
: "${STORAGE_POOL:?STORAGE_POOL not set in ${ENV_FILE}}"
: "${STORAGE_DEVICE:?STORAGE_DEVICE not set in ${ENV_FILE}}"
: "${OVN_ENCAP_IP:?OVN_ENCAP_IP not set in ${ENV_FILE}}"
: "${OVN_CENTRAL_ADDRESS:?OVN_CENTRAL_ADDRESS not set in ${ENV_FILE}}"
: "${UPLINK_NETWORK:?UPLINK_NETWORK not set in ${ENV_FILE}}"
: "${UPLINK_PARENT:?UPLINK_PARENT not set in ${ENV_FILE}}"
: "${NFS_BACKUP_DIR:?NFS_BACKUP_DIR not set in ${ENV_FILE}}"

host_require_root_and_os
# Packages first: the checks below need jq, which a fresh host doesn't have.
host_install_zabbly_repo
host_install_packages

# The token is base64 JSON carrying the member name and cluster addresses.
TOKEN_JSON="$(base64 -d <<< "${TOKEN}" 2>/dev/null)" || fail 'the join token is not valid base64.'
TOKEN_NAME="$(jq -r '.server_name // empty' <<< "${TOKEN_JSON}" 2>/dev/null)" || fail 'the join token is not valid.'
mapfile -t CLUSTER_ADDRESSES < <(jq -r '.addresses[]?' <<< "${TOKEN_JSON}")
[[ -n "${TOKEN_NAME}" && ${#CLUSTER_ADDRESSES[@]} -gt 0 ]] || fail 'the join token is missing its member name or cluster addresses.'
[[ "${TOKEN_NAME}" == "$(hostname -s)" ]] \
  || echo "Warning: the token is for member '${TOKEN_NAME}', this host is '$(hostname -s)'; it will join as '${TOKEN_NAME}'." >&2
ip -4 -o addr show | grep -qw "inet ${OVN_ENCAP_IP}" || fail "OVN_ENCAP_IP ${OVN_ENCAP_IP} is not an address of this host."
ip link show "${UPLINK_PARENT}" >/dev/null 2>&1 || fail "UPLINK_PARENT '${UPLINK_PARENT}' is not a network interface on this host."

step "Reachability of the cluster (${CLUSTER_ADDRESSES[*]}) and OVN (${OVN_CENTRAL_ADDRESS})"
REACHABLE=''
for ADDRESS in "${CLUSTER_ADDRESSES[@]}"; do
  timeout 5 bash -c "echo > /dev/tcp/${ADDRESS%:*}/${ADDRESS##*:}" 2>/dev/null && { REACHABLE="${ADDRESS}"; break; }
done
[[ -n "${REACHABLE}" ]] || fail "no cluster member is reachable at ${CLUSTER_ADDRESSES[*]} (firewall?)."
for PORT in 6641 6642; do
  timeout 5 bash -c "echo > /dev/tcp/${OVN_CENTRAL_ADDRESS}/${PORT}" 2>/dev/null \
    || fail "OVN at ${OVN_CENTRAL_ADDRESS}:${PORT} is not reachable (run cluster-enable.sh there first, or check the firewall)."
done

host_configure_ovn_chassis "tcp:${OVN_CENTRAL_ADDRESS}:6642" "${OVN_ENCAP_IP}"
host_add_admin_user

if [[ "$(incus query /1.0 | jq -r '.environment.server_clustered')" == 'true' ]]; then
  step 'Already a cluster member, skipping the join'
else
  [[ "$(incus storage list -f json | jq 'length')" == '0' ]] \
    || fail 'Incus on this host is already initialized as a standalone server; joining would erase it. Use a clean host.'
  host_prepare_storage_device "${WIPE_STORAGE_DEVICE}"

  step "Joining the cluster as '${TOKEN_NAME}' via ${REACHABLE}"
  incus admin init --preseed <<EOF
cluster:
  enabled: true
  server_address: ${OVN_ENCAP_IP}:8443
  cluster_token: ${TOKEN}
  member_config:
  - entity: storage-pool
    name: ${STORAGE_POOL}
    key: source
    value: ${STORAGE_DEVICE}
  - entity: network
    name: ${UPLINK_NETWORK}
    key: parent
    value: ${UPLINK_PARENT}
EOF
fi

host_setup_nfs_mount
host_install_backup_timer "${ROOT_DIR}"
host_apply_branding "${ROOT_DIR}"

step 'Done'
incus cluster list
echo
echo "Log out and back in (or run 'newgrp incus-admin') for ${INCUS_ADMIN_USER} to use incus without sudo."
