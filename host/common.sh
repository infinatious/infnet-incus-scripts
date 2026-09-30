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

# Installs Incus and its dependencies; pass --with-ovn-central on hosts that
# run the OVN databases.
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

# Reads OVN_CENTRAL_ADDRESSES (comma-separated management IPs of the hosts that
# run the OVN databases) into OVN_CENTRAL_IPS and sets OVN_NB_REMOTES /
# OVN_SB_REMOTES, the connection lists every client uses so it can fail over
# to any member.
host_load_ovn_central_addresses() {
  local address
  : "${OVN_CENTRAL_ADDRESSES:?OVN_CENTRAL_ADDRESSES not set in ${ENV_FILE}}"
  IFS=', ' read -r -a OVN_CENTRAL_IPS <<< "${OVN_CENTRAL_ADDRESSES}"
  (( ${#OVN_CENTRAL_IPS[@]} > 0 )) || fail 'OVN_CENTRAL_ADDRESSES is empty.'
  OVN_NB_REMOTES=''
  OVN_SB_REMOTES=''
  for address in "${OVN_CENTRAL_IPS[@]}"; do
    [[ "${address}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "OVN_CENTRAL_ADDRESSES entry '${address}' is not an IPv4 address."
    OVN_NB_REMOTES+="${OVN_NB_REMOTES:+,}tcp:${address}:6641"
    OVN_SB_REMOTES+="${OVN_SB_REMOTES:+,}tcp:${address}:6642"
  done
  (( ${#OVN_CENTRAL_IPS[@]} % 2 == 1 )) \
    || echo "Warning: ${#OVN_CENTRAL_IPS[@]} OVN database members; an even count tolerates no more failures than one fewer." >&2
}

# True if this host (OVN_ENCAP_IP) is one of the OVN database members.
host_is_ovn_central_member() {
  local address
  for address in "${OVN_CENTRAL_IPS[@]}"; do
    [[ "${address}" == "${OVN_ENCAP_IP}" ]] && return 0
  done
  return 1
}

# Runs this host's OVN databases as a member of the RAFT cluster (NB raft
# tcp/6643, SB raft tcp/6644), serving clients on its own address tcp/6641-6642.
# ovn-ctl does the conversion itself: with no remote it turns an existing
# standalone database into a new one-member cluster, keeping its contents;
# with a remote it discards the local standalone database and joins that
# member's cluster. Later starts reuse the clustered files. ovn-northd runs on
# every member but holds a lock, so only one is active at a time.
host_configure_ovn_central() {
  local local_ip="$1" remote_ip="${2:-}" opts db schema
  opts="--db-nb-cluster-local-addr=${local_ip} --db-sb-cluster-local-addr=${local_ip}"
  [[ -n "${remote_ip}" ]] && opts+=" --db-nb-cluster-remote-addr=${remote_ip} --db-sb-cluster-remote-addr=${remote_ip}"
  opts+=" --db-nb-create-insecure-remote=yes --db-nb-addr=${local_ip}"
  opts+=" --db-sb-create-insecure-remote=yes --db-sb-addr=${local_ip}"
  opts+=" --ovn-northd-nb-db=${OVN_NB_REMOTES} --ovn-northd-sb-db=${OVN_SB_REMOTES}"

  step "OVN database cluster member on ${local_ip}${remote_ip:+ (joining via ${remote_ip})}"
  for db in ovnnb_db ovnsb_db; do
    if [[ -f "/var/lib/ovn/${db}.db" ]] && ovsdb-tool db-is-standalone "/var/lib/ovn/${db}.db"; then
      mkdir -p /var/lib/ovn/standalone-backup
      cp -a "/var/lib/ovn/${db}.db" "/var/lib/ovn/standalone-backup/${db}.db.$(date +%Y%m%d%H%M%S)"
    fi
  done
  printf '%s\n' \
    '# Managed by infnet-incus-scripts (host/common.sh): this host is an OVN RAFT' \
    "# cluster member. Members: ${OVN_CENTRAL_ADDRESSES}" \
    "OVN_CTL_OPTS=\"${opts}\"" > /etc/default/ovn-central.new
  if ! cmp -s /etc/default/ovn-central.new /etc/default/ovn-central \
    || ovsdb-tool db-is-standalone /var/lib/ovn/ovnnb_db.db 2>/dev/null \
    || ovsdb-tool db-is-standalone /var/lib/ovn/ovnsb_db.db 2>/dev/null; then
    mv /etc/default/ovn-central.new /etc/default/ovn-central
    systemctl enable ovn-central >/dev/null 2>&1
    systemctl restart ovn-central
  else
    rm -f /etc/default/ovn-central.new
    systemctl enable --now ovn-central >/dev/null 2>&1
  fi

  for db in nb sb; do
    schema='OVN_Northbound'
    [[ "${db}" == 'sb' ]] && schema='OVN_Southbound'
    for _ in $(seq 1 60); do
      ovn-appctl -t "/var/run/ovn/ovn${db}_db.ctl" cluster/status "${schema}" 2>/dev/null \
        | grep -q '^Status: cluster member' && break
      sleep 2
    done
    ovn-appctl -t "/var/run/ovn/ovn${db}_db.ctl" cluster/status "${schema}" 2>/dev/null \
      | grep -q '^Status: cluster member' \
      || fail "the ${schema} database did not become a cluster member (see /var/log/ovn/ovsdb-server-${db}.log)."
  done
  ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound | grep -E '^(Role|Servers):|^    ' | sed 's/^/  /'
}

# The default project's network router address: the last address of
# UPLINK_IPV4_OVN_RANGES, so project IDs (router .<id>) count up from the
# bottom of the range without meeting it.
host_default_router_address() {
  python3 -c '
import ipaddress, sys
last = sys.argv[1].split(",")[-1].strip().split("-")[-1]
print(ipaddress.IPv4Address(last))
' "${UPLINK_IPV4_OVN_RANGES}"
}

host_add_admin_user() {
  step "Incus admin access for '${INCUS_ADMIN_USER}'"
  usermod -aG incus-admin "${INCUS_ADMIN_USER}"
}

# Checks the storage settings: either STORAGE_DEVICE (a whole disk or
# partition) or, with STORAGE_DEVICE empty, STORAGE_LOOP_SIZE for a ZFS pool in
# a loop file that Incus creates under /var/lib/incus/disks (for hosts whose
# only disk holds the OS).
host_check_storage_settings() {
  if [[ -z "${STORAGE_DEVICE:-}" ]]; then
    [[ "${STORAGE_LOOP_SIZE:-}" =~ ^[0-9]+(GiB|TiB)$ ]] \
      || fail 'set STORAGE_DEVICE, or leave it empty and set STORAGE_LOOP_SIZE (e.g. 700GiB) for a loop-file pool.'
  fi
}

# The storage pool's member-specific config key and value: the device, or the
# loop file's size.
host_storage_key() { [[ -n "${STORAGE_DEVICE:-}" ]] && echo source || echo size; }
host_storage_value() { [[ -n "${STORAGE_DEVICE:-}" ]] && echo "${STORAGE_DEVICE}" || echo "${STORAGE_LOOP_SIZE}"; }

# Checks STORAGE_DEVICE is free for the storage pool, erasing old partition
# and ZFS signatures when wipe=yes. Destroys everything on the device. For a
# loop-file pool it checks the filesystem has room instead.
host_prepare_storage_device() {
  local wipe="$1" dev signatures=() free_gib want_gib
  if [[ -z "${STORAGE_DEVICE:-}" ]]; then
    step "Storage: ${STORAGE_LOOP_SIZE} loop file under /var/lib/incus/disks"
    mkdir -p /var/lib/incus
    free_gib="$(df -BG --output=avail /var/lib/incus | tail -n1 | tr -dc '0-9')"
    want_gib="${STORAGE_LOOP_SIZE%GiB}"
    [[ "${STORAGE_LOOP_SIZE}" == *TiB ]] && want_gib=$(( ${STORAGE_LOOP_SIZE%TiB} * 1024 ))
    (( free_gib > want_gib )) \
      || fail "/var/lib/incus has ${free_gib} GiB free, not enough for a ${STORAGE_LOOP_SIZE} loop file."
    return 0
  fi
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
