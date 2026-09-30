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
       cluster-join.sh   (re-run on an existing member)

Turns a clean Ubuntu host into a new member of an existing Incus cluster
(one made with cluster-enable.sh): installs the same packages as
setup-incus-host.sh, joins the OVN database cluster if this host is listed in
OVN_CENTRAL_ADDRESSES, points this host's OVN chassis at every OVN database
member, and joins Incus with this host's own storage disk and uplink NIC. It
also sets up the NFS backup mount, the backup timer and the UI branding.

Get TOKEN on an existing member with `incus cluster add <this host's short
hostname>` (or cluster-enable.sh --add-member). Everything cluster-wide
(networks, projects, profiles, OIDC) comes from the cluster.

This host's .env needs its own STORAGE_DEVICE (or STORAGE_LOOP_SIZE), UPLINK_PARENT (on the same
public network as the other members) and OVN_ENCAP_IP, plus the same
OVN_CENTRAL_ADDRESSES as every other member. Hosts listed there run a copy of
the OVN databases (use three); any others only run the OVN chassis.

Safe to re-run on a member, e.g. after changing OVN_CENTRAL_ADDRESSES: it
re-applies the OVN settings and skips the join (no --token needed).

Options:
  --token TOKEN          Join token from `incus cluster add` (first join only).
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

[[ -f "${ENV_FILE}" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

: "${INCUS_CHANNEL:?INCUS_CHANNEL not set in ${ENV_FILE}}"
: "${INCUS_ADMIN_USER:?INCUS_ADMIN_USER not set in ${ENV_FILE}}"
: "${STORAGE_POOL:?STORAGE_POOL not set in ${ENV_FILE}}"
: "${OVN_ENCAP_IP:?OVN_ENCAP_IP not set in ${ENV_FILE}}"
: "${UPLINK_NETWORK:?UPLINK_NETWORK not set in ${ENV_FILE}}"
: "${UPLINK_PARENT:?UPLINK_PARENT not set in ${ENV_FILE}}"
: "${NFS_BACKUP_DIR:?NFS_BACKUP_DIR not set in ${ENV_FILE}}"

host_require_root_and_os
host_check_storage_settings
host_load_ovn_central_addresses
OVN_MEMBER=''
host_is_ovn_central_member && OVN_MEMBER='yes'
# Packages first: the checks below need jq, which a fresh host doesn't have.
host_install_zabbly_repo
if [[ -n "${OVN_MEMBER}" ]]; then
  host_install_packages --with-ovn-central
else
  host_install_packages
fi

ALREADY_MEMBER=''
[[ "$(incus query /1.0 | jq -r '.environment.server_clustered')" == 'true' ]] && ALREADY_MEMBER='yes'
if [[ -n "${ALREADY_MEMBER}" ]]; then
  # Re-run on a member: its own cluster address stands in for the token's.
  CLUSTER_ADDRESSES=("$(incus config get cluster.https_address)")
else
  [[ -n "${TOKEN}" ]] || fail '--token is required to join (see --help).'
  # The token is base64 JSON carrying the member name and cluster addresses.
  TOKEN_JSON="$(base64 -d <<< "${TOKEN}" 2>/dev/null)" || fail 'the join token is not valid base64.'
  TOKEN_NAME="$(jq -r '.server_name // empty' <<< "${TOKEN_JSON}" 2>/dev/null)" || fail 'the join token is not valid.'
  mapfile -t CLUSTER_ADDRESSES < <(jq -r '.addresses[]?' <<< "${TOKEN_JSON}")
  [[ -n "${TOKEN_NAME}" && ${#CLUSTER_ADDRESSES[@]} -gt 0 ]] || fail 'the join token is missing its member name or cluster addresses.'
  [[ "${TOKEN_NAME}" == "$(hostname -s)" ]] \
    || echo "Warning: the token is for member '${TOKEN_NAME}', this host is '$(hostname -s)'; it will join as '${TOKEN_NAME}'." >&2
fi
ip -4 -o addr show | grep -qw "inet ${OVN_ENCAP_IP}" || fail "OVN_ENCAP_IP ${OVN_ENCAP_IP} is not an address of this host."
ip link show "${UPLINK_PARENT}" >/dev/null 2>&1 || fail "UPLINK_PARENT '${UPLINK_PARENT}' is not a network interface on this host."

step "Reachability of the cluster (${CLUSTER_ADDRESSES[*]}) and the OVN databases (${OVN_CENTRAL_ADDRESSES})"
REACHABLE=''
for ADDRESS in "${CLUSTER_ADDRESSES[@]}"; do
  timeout 5 bash -c "echo > /dev/tcp/${ADDRESS%:*}/${ADDRESS##*:}" 2>/dev/null && { REACHABLE="${ADDRESS}"; break; }
done
[[ -n "${REACHABLE}" ]] || fail "no cluster member is reachable at ${CLUSTER_ADDRESSES[*]} (firewall?)."
# An existing OVN database member to join through: clients use tcp/6641-6642,
# and a joining database member also needs its RAFT ports tcp/6643-6644.
OVN_PORTS=(6641 6642)
[[ -n "${OVN_MEMBER}" ]] && OVN_PORTS+=(6643 6644)
OVN_REMOTE=''
for ADDRESS in "${OVN_CENTRAL_IPS[@]}"; do
  [[ "${ADDRESS}" == "${OVN_ENCAP_IP}" ]] && continue
  UNREACHABLE=''
  for PORT in "${OVN_PORTS[@]}"; do
    timeout 5 bash -c "echo > /dev/tcp/${ADDRESS}/${PORT}" 2>/dev/null || UNREACHABLE+=" ${PORT}"
  done
  if [[ -z "${UNREACHABLE}" ]]; then
    OVN_REMOTE="${ADDRESS}"
    break
  fi
  echo "Note: OVN member ${ADDRESS} is not reachable on tcp${UNREACHABLE} (not built yet, or firewalled)." >&2
done
[[ -n "${OVN_REMOTE}" ]] \
  || fail "no other OVN database member in OVN_CENTRAL_ADDRESSES is reachable on tcp/${OVN_PORTS[*]} (run cluster-enable.sh on the first host, or check the firewall)."

if [[ -n "${OVN_MEMBER}" ]]; then
  host_configure_ovn_central "${OVN_ENCAP_IP}" "${OVN_REMOTE}"
else
  # Package installs start ovn-central with its own empty databases; a host
  # outside OVN_CENTRAL_ADDRESSES mustn't run them.
  systemctl disable --now ovn-central >/dev/null 2>&1 || true
fi
host_configure_ovn_chassis "${OVN_SB_REMOTES}" "${OVN_ENCAP_IP}"
host_add_admin_user

if [[ -n "${ALREADY_MEMBER}" ]]; then
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
    key: $(host_storage_key)
    value: $(host_storage_value)
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
