#!/usr/bin/env bash
# Shared host setup steps for setup-incus-host.sh and cluster-join.sh.
# Source this file after loading .env; do not execute it directly. Every step
# is safe to re-run.

ZABBLY_KEY_FINGERPRINT='4EFC590696CB15B87C73A3AD82CC8797C838DCFD'
HOST_INSTALL_DIR='/opt/infnet-incus-scripts'

fail() {
  echo "Error: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

host_require_root_and_os() {
  (( EUID == 0 )) || fail 'run this script as root (sudo).'
  . /etc/os-release
  [[ "${ID}" == 'ubuntu' || "${ID}" == 'debian' ]] || fail "unsupported OS '${ID}'; Zabbly packages target Ubuntu and Debian."
}

host_install_zabbly_repo() {
  local key_file='/etc/apt/keyrings/zabbly.asc' tmp_key
  step "Zabbly Incus repository (${INCUS_CHANNEL})"
  if [[ ! -f "${key_file}" ]]; then
    mkdir -p /etc/apt/keyrings
    tmp_key="$(mktemp)"
    curl -fsSL https://pkgs.zabbly.com/key.asc -o "${tmp_key}"
    gpg --show-keys --with-colons "${tmp_key}" | grep -q "^fpr:::::::::${ZABBLY_KEY_FINGERPRINT}:" \
      || { rm -f "${tmp_key}"; fail 'downloaded Zabbly key does not match the published fingerprint.'; }
    install -m 0644 "${tmp_key}" "${key_file}"
    rm -f "${tmp_key}"
  fi
  cat > /etc/apt/sources.list.d/zabbly-incus.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/${INCUS_CHANNEL}
Suites: $(. /etc/os-release && echo "${VERSION_CODENAME}")
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: ${key_file}
EOF
}

# Installs Incus and its dependencies; pass --with-ovn-central on the host
# that runs the OVN databases.
host_install_packages() {
  local packages=(incus incus-ui-canonical incus-extra zfsutils-linux ovn-host nfs-common jq curl python3 python3-yaml)
  [[ "${1:-}" == '--with-ovn-central' ]] && packages+=(ovn-central)
  step 'Packages'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${packages[@]}"
}

# Points this host's OVN chassis at the southbound database and sets its
# Geneve tunnel endpoint.
host_configure_ovn_chassis() {
  local southbound="$1" encap_ip="$2"
  step "OVN chassis (southbound ${southbound}, encap ${encap_ip})"
  systemctl enable --now ovn-host
  ovs-vsctl set open_vswitch . \
    external_ids:ovn-remote="${southbound}" \
    external_ids:ovn-encap-type=geneve \
    external_ids:ovn-encap-ip="${encap_ip}"
}

host_add_admin_user() {
  step "Incus admin access for '${INCUS_ADMIN_USER}'"
  usermod -aG incus-admin "${INCUS_ADMIN_USER}"
}

# Checks STORAGE_DEVICE is free for the storage pool, erasing old partition
# and ZFS signatures when wipe=yes. Destroys everything on the device.
host_prepare_storage_device() {
  local wipe="$1" dev signatures=()
  step "Storage device ${STORAGE_DEVICE}"
  [[ -b "${STORAGE_DEVICE}" ]] || fail "storage device '${STORAGE_DEVICE}' does not exist."
  # Installing zfsutils can auto-import a leftover pool from the same disk.
  if zpool list -H -o name 2>/dev/null | grep -qx "${STORAGE_POOL}"; then
    [[ "${wipe}" == 'yes' ]] || fail "a ZFS pool named '${STORAGE_POOL}' is already imported. Re-run with --wipe-storage-device to destroy it."
    zpool destroy -f "${STORAGE_POOL}"
  fi
  mapfile -t signatures < <(for dev in "${STORAGE_DEVICE}" "${STORAGE_DEVICE}"-part*; do
    [[ -b "${dev}" ]] && wipefs -n "${dev}" 2>/dev/null | tail -n +2 | sed "s|^|${dev}: |"
  done)
  (( ${#signatures[@]} > 0 )) || return 0
  printf '  %s\n' "${signatures[@]}"
  [[ "${wipe}" == 'yes' ]] || fail "${STORAGE_DEVICE} still has the signatures above. Re-run with --wipe-storage-device to erase them (destroys all data on it)."
  for dev in "${STORAGE_DEVICE}"-part* "${STORAGE_DEVICE}"; do
    [[ -b "${dev}" ]] && wipefs -a "${dev}"
  done
  partprobe "${STORAGE_DEVICE}" 2>/dev/null || true
  udevadm settle
}

host_setup_nfs_mount() {
  local other
  if [[ -z "${NFS_BACKUP_SOURCE:-}" ]]; then
    step 'NFS_BACKUP_SOURCE not set, skipping the NFS backup mount'
    return 0
  fi
  step "NFS backup mount ${NFS_BACKUP_SOURCE} -> ${NFS_BACKUP_DIR}"
  mkdir -p "${NFS_BACKUP_DIR}"
  if ! awk -v d="${NFS_BACKUP_DIR}" '$1 !~ /^#/ && $2 == d {found=1} END {exit !found}' /etc/fstab; then
    printf '%s  %s  nfs  defaults,_netdev  0  0\n' "${NFS_BACKUP_SOURCE}" "${NFS_BACKUP_DIR}" >> /etc/fstab
    systemctl daemon-reload
  fi
  while read -r other; do
    echo "Warning: ${NFS_BACKUP_SOURCE} is also mounted at ${other} by /etc/fstab; remove that entry once nothing uses it." >&2
  done < <(awk -v s="${NFS_BACKUP_SOURCE}" -v d="${NFS_BACKUP_DIR}" '$1 !~ /^#/ && $1 == s && $2 != d {print $2}' /etc/fstab)
  mountpoint -q "${NFS_BACKUP_DIR}" || mount "${NFS_BACKUP_DIR}"
}

# The backup units point at HOST_INSTALL_DIR, so only install them from there.
host_install_backup_timer() {
  local root_dir="$1"
  if [[ "${root_dir}" != "${HOST_INSTALL_DIR}" ]]; then
    step "Repository is at ${root_dir}, not ${HOST_INSTALL_DIR}; skipping the backup timer (its units point at ${HOST_INSTALL_DIR})"
    return 0
  fi
  step 'Nightly backup timer'
  install -m 0644 "${root_dir}/backup/systemd/infnet-incus-backup.service" "${root_dir}/backup/systemd/infnet-incus-backup.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now infnet-incus-backup.timer
}

host_apply_branding() {
  local root_dir="$1"
  step 'Web UI branding'
  "${root_dir}/branding/apply-ui-branding.sh" --install-hook
}
