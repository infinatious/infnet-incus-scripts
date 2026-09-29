#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
INSTALL_DIR='/opt/infnet-incus-scripts'
ZABBLY_KEY_FINGERPRINT='4EFC590696CB15B87C73A3AD82CC8797C838DCFD'

fail() {
  echo "Error: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

usage() {
  cat <<'EOF'
Usage: setup-incus-host.sh [--wipe-storage-device]

Turns a clean Ubuntu host into a standalone Incus server matching what the
scripts in this repository expect: Zabbly Incus packages (plus the web UI and
incus-extra), a local OVN control plane, the ZFS storage pool, the physical
uplink, a default OVN network, the NFS backup mount, the nightly backup timer,
optional Authentik OIDC, and the Infinatious UI branding.

Every step is safe to re-run. Settings come from the "Host bootstrap" and
"OIDC" sections of .env (see .env.example).

Options:
  --wipe-storage-device  Erase existing partition/ZFS signatures on
                         STORAGE_DEVICE before creating the pool. Needed when
                         the disk still carries an old (e.g. MicroCloud/LXD)
                         pool. Destroys everything on that disk.
  --help                 Show this help message.
EOF
}

WIPE_STORAGE_DEVICE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wipe-storage-device) WIPE_STORAGE_DEVICE='yes'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

(( EUID == 0 )) || fail 'run this script as root (sudo).'
[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"

: "${INCUS_CHANNEL:?INCUS_CHANNEL not set in ${ENV_FILE}}"
: "${INCUS_ADMIN_USER:?INCUS_ADMIN_USER not set in ${ENV_FILE}}"
: "${STORAGE_POOL:?STORAGE_POOL not set in ${ENV_FILE}}"
: "${STORAGE_DEVICE:?STORAGE_DEVICE not set in ${ENV_FILE}}"
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

. /etc/os-release
[[ "${ID}" == 'ubuntu' || "${ID}" == 'debian' ]] || fail "unsupported OS '${ID}'; Zabbly packages target Ubuntu and Debian."

# ---------------------------------------------------------------------------
step "Zabbly Incus repository (${INCUS_CHANNEL})"
KEY_FILE='/etc/apt/keyrings/zabbly.asc'
if [[ ! -f "${KEY_FILE}" ]]; then
  mkdir -p /etc/apt/keyrings
  TMP_KEY="$(mktemp)"
  curl -fsSL https://pkgs.zabbly.com/key.asc -o "${TMP_KEY}"
  gpg --show-keys --with-colons "${TMP_KEY}" | grep -q "^fpr:::::::::${ZABBLY_KEY_FINGERPRINT}:" \
    || { rm -f "${TMP_KEY}"; fail 'downloaded Zabbly key does not match the published fingerprint.'; }
  install -m 0644 "${TMP_KEY}" "${KEY_FILE}"
  rm -f "${TMP_KEY}"
fi
cat > /etc/apt/sources.list.d/zabbly-incus.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/${INCUS_CHANNEL}
Suites: ${VERSION_CODENAME}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: ${KEY_FILE}
EOF

# ---------------------------------------------------------------------------
step 'Packages'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq incus incus-ui-canonical incus-extra zfsutils-linux ovn-central ovn-host \
  nfs-common jq curl python3 python3-yaml

# ---------------------------------------------------------------------------
step "Local OVN control plane (encap ${OVN_ENCAP_IP})"
systemctl enable --now ovn-central ovn-host
ovs-vsctl set open_vswitch . \
  external_ids:ovn-remote=unix:/run/ovn/ovnsb_db.sock \
  external_ids:ovn-encap-type=geneve \
  external_ids:ovn-encap-ip="${OVN_ENCAP_IP}"
for _ in $(seq 1 30); do
  [[ -S /run/ovn/ovnnb_db.sock ]] && break
  sleep 1
done
[[ -S /run/ovn/ovnnb_db.sock ]] || fail 'OVN northbound socket /run/ovn/ovnnb_db.sock never appeared.'

# ---------------------------------------------------------------------------
step "Incus admin access for '${INCUS_ADMIN_USER}'"
usermod -aG incus-admin "${INCUS_ADMIN_USER}"

# ---------------------------------------------------------------------------
if [[ "$(incus storage list -f json | jq 'length')" == '0' ]]; then
  step "Storage device ${STORAGE_DEVICE}"
  [[ -b "${STORAGE_DEVICE}" ]] || fail "storage device '${STORAGE_DEVICE}' does not exist."
  # Installing zfsutils can auto-import a leftover pool from the same disk.
  if zpool list -H -o name 2>/dev/null | grep -qx "${STORAGE_POOL}"; then
    [[ "${WIPE_STORAGE_DEVICE}" == 'yes' ]] || fail "a ZFS pool named '${STORAGE_POOL}' is already imported. Re-run with --wipe-storage-device to destroy it."
    zpool destroy -f "${STORAGE_POOL}"
  fi
  mapfile -t SIGNATURES < <(for dev in "${STORAGE_DEVICE}" "${STORAGE_DEVICE}"-part*; do
    [[ -b "${dev}" ]] && wipefs -n "${dev}" 2>/dev/null | tail -n +2 | sed "s|^|${dev}: |"
  done)
  if (( ${#SIGNATURES[@]} > 0 )); then
    printf '  %s\n' "${SIGNATURES[@]}"
    [[ "${WIPE_STORAGE_DEVICE}" == 'yes' ]] || fail "${STORAGE_DEVICE} still has the signatures above. Re-run with --wipe-storage-device to erase them (destroys all data on it)."
    for dev in "${STORAGE_DEVICE}"-part* "${STORAGE_DEVICE}"; do
      [[ -b "${dev}" ]] && wipefs -a "${dev}"
    done
    partprobe "${STORAGE_DEVICE}" 2>/dev/null || true
    udevadm settle
  fi

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
    volatile.network.ipv4.address: ${PROJECT_NAT_IPV4_PREFIX}.254
storage_pools:
- name: ${STORAGE_POOL}
  driver: zfs
  config:
    source: ${STORAGE_DEVICE}
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

# ---------------------------------------------------------------------------
if [[ -n "${NFS_BACKUP_SOURCE:-}" ]]; then
  step "NFS backup mount ${NFS_BACKUP_SOURCE} -> ${NFS_BACKUP_DIR}"
  mkdir -p "${NFS_BACKUP_DIR}"
  if ! awk -v d="${NFS_BACKUP_DIR}" '$1 !~ /^#/ && $2 == d {found=1} END {exit !found}' /etc/fstab; then
    printf '%s  %s  nfs  defaults,_netdev  0  0\n' "${NFS_BACKUP_SOURCE}" "${NFS_BACKUP_DIR}" >> /etc/fstab
    systemctl daemon-reload
  fi
  awk -v s="${NFS_BACKUP_SOURCE}" -v d="${NFS_BACKUP_DIR}" '$1 !~ /^#/ && $1 == s && $2 != d {print $2}' /etc/fstab \
    | while read -r OTHER; do echo "Warning: ${NFS_BACKUP_SOURCE} is also mounted at ${OTHER} by /etc/fstab; remove that entry once nothing uses it." >&2; done
  mountpoint -q "${NFS_BACKUP_DIR}" || mount "${NFS_BACKUP_DIR}"
else
  step 'NFS_BACKUP_SOURCE not set, skipping the NFS backup mount'
fi

# ---------------------------------------------------------------------------
if [[ "${ROOT_DIR}" == "${INSTALL_DIR}" ]]; then
  step 'Nightly backup timer'
  install -m 0644 "${ROOT_DIR}/backup/systemd/infnet-incus-backup.service" "${ROOT_DIR}/backup/systemd/infnet-incus-backup.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now infnet-incus-backup.timer
else
  step "Repository is at ${ROOT_DIR}, not ${INSTALL_DIR}; skipping the backup timer (its units point at ${INSTALL_DIR})"
fi

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
step 'Web UI branding'
"${ROOT_DIR}/branding/apply-ui-branding.sh" --install-hook

# ---------------------------------------------------------------------------
step 'Done'
incus version
incus network show "${UPLINK_NETWORK}" --project default | sed -n '/^config:/,/^description:/p'
incus storage list
echo
echo "Web UI: https://$(hostname -f):8443/ui/"
echo "Log out and back in (or run 'newgrp incus-admin') for ${INCUS_ADMIN_USER} to use incus without sudo."
