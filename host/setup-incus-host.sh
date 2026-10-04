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
Usage: setup-incus-host.sh [--wipe-storage-device]

Turns a clean Ubuntu host into a standalone Incus server matching what the
scripts in this repository expect: Zabbly Incus packages (plus the web UI and
incus-extra), a local OVN control plane, the ZFS storage pool, the physical
uplink, a default OVN network, the NFS backup mount, the nightly backup timer,
optional Authentik OIDC, and the Infinatious UI branding.

To grow it into a cluster later, run cluster-enable.sh on it, then
cluster-join.sh on each new host.

Every step is safe to re-run. Settings come from the "Host bootstrap" and
"OIDC" sections of .env (see .env.example).

Options:
  --wipe-storage-device  Erase existing partition/ZFS signatures on
                         STORAGE_DEVICE before creating the pool. Needed when
                         the disk still carries an old (e.g. MicroCloud/LXD)
                         pool. Destroys everything on that disk. Not used for
                         a loop-file pool (STORAGE_LOOP_SIZE).
  --help                 Show this help message.
EOF
}

WIPE_STORAGE_DEVICE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
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
: "${UPLINK_IPV4_GATEWAY:?UPLINK_IPV4_GATEWAY not set in ${ENV_FILE}}"
: "${UPLINK_IPV4_OVN_RANGES:?UPLINK_IPV4_OVN_RANGES not set in ${ENV_FILE}}"
: "${UPLINK_IPV4_ROUTES:?UPLINK_IPV4_ROUTES not set in ${ENV_FILE}}"
: "${UPLINK_DNS_NAMESERVERS:?UPLINK_DNS_NAMESERVERS not set in ${ENV_FILE}}"
: "${IPV4_SUBNET_PREFIX:?IPV4_SUBNET_PREFIX not set in ${ENV_FILE}}"
: "${PROJECT_NAT_IPV4_PREFIX:?PROJECT_NAT_IPV4_PREFIX not set in ${ENV_FILE}}"
: "${NFS_BACKUP_DIR:?NFS_BACKUP_DIR not set in ${ENV_FILE}}"

host_require_root_and_os
host_check_storage_settings
DEFAULT_ROUTER_IPV4="$(host_default_router_address)" || fail "UPLINK_IPV4_OVN_RANGES '${UPLINK_IPV4_OVN_RANGES}' is not a valid range."
host_install_zabbly_repo
host_install_packages --with-ovn-central

step 'Local OVN databases'
systemctl enable --now ovn-central
for _ in $(seq 1 30); do
  [[ -S /run/ovn/ovnnb_db.sock ]] && break
  sleep 1
done
[[ -S /run/ovn/ovnnb_db.sock ]] || fail 'OVN northbound socket /run/ovn/ovnnb_db.sock never appeared.'
# Once clustered (cluster-enable.sh) the chassis talks to the databases over
# TCP; keep that setting when this script is re-run.
SOUTHBOUND="$(ovs-vsctl --if-exists get open_vswitch . external_ids:ovn-remote 2>/dev/null | tr -d '"' || true)"
[[ "${SOUTHBOUND}" == tcp:* ]] || SOUTHBOUND='unix:/run/ovn/ovnsb_db.sock'
host_configure_ovn_chassis "${SOUTHBOUND}" "${OVN_ENCAP_IP}"
host_add_admin_user

if [[ "$(incus storage list -f json | jq 'length')" == '0' ]]; then
  host_prepare_storage_device "${WIPE_STORAGE_DEVICE}"

  step 'Initializing Incus (storage pool, uplink, default OVN network, default profile)'
  incus admin init --preseed <<EOF
config:
  core.https_address: '[::]:8443'
networks:
- name: ${UPLINK_NETWORK}
  type: physical
  description: Uplink for OVN networks
  config:
    parent: ${UPLINK_PARENT}
    ipv4.gateway: ${UPLINK_IPV4_GATEWAY}
    ipv4.ovn.ranges: ${UPLINK_IPV4_OVN_RANGES}
    ipv4.routes: ${UPLINK_IPV4_ROUTES}
    dns.nameservers: ${UPLINK_DNS_NAMESERVERS}
- name: default
  type: ovn
  description: Default OVN network
  config:
    network: ${UPLINK_NETWORK}
    ipv4.address: ${IPV4_SUBNET_PREFIX}.0.1/24
    ipv4.nat: 'true'
    ipv6.address: none
    volatile.network.ipv4.address: ${DEFAULT_ROUTER_IPV4}
storage_pools:
- name: ${STORAGE_POOL}
  driver: zfs
  config:
    $(host_storage_key): $(host_storage_value)
profiles:
- name: default
  devices:
    root:
      path: /
      pool: ${STORAGE_POOL}
      type: disk
    eth0:
      name: eth0
      network: default
      type: nic
EOF
else
  step 'Incus already initialized, skipping preseed'
fi

host_setup_nfs_mount
host_install_backup_timer "${ROOT_DIR}"

if [[ -n "${OIDC_ISSUER:-}" && -n "${OIDC_CLIENT_ID:-}" ]]; then
  step "Authentik OIDC (${OIDC_ISSUER})"
  curl -fsS -o /dev/null "${OIDC_ISSUER%/}/.well-known/openid-configuration" \
    || fail "cannot reach ${OIDC_ISSUER%/}/.well-known/openid-configuration from this host (firewall?)."
  incus config set oidc.issuer="${OIDC_ISSUER}" oidc.client.id="${OIDC_CLIENT_ID}" \
    oidc.scopes="${OIDC_SCOPES:-openid,offline_access,email,profile}"
  if [[ -n "${OIDC_AUDIENCE:-}" ]]; then
    incus config set oidc.audience="${OIDC_AUDIENCE}"
  fi
else
  step 'OIDC_ISSUER/OIDC_CLIENT_ID not set, skipping OIDC'
fi

host_apply_branding "${ROOT_DIR}"

step 'Done'
incus version
incus network show "${UPLINK_NETWORK}" --project default | sed -n '/^config:/,/^description:/p'
incus storage list
echo
echo "Web UI: https://$(hostname -f):8443/ui/"
echo "Log out and back in (or run 'newgrp incus-admin') for ${INCUS_ADMIN_USER} to use incus without sudo."
