#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

OVN_MTU='1442'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init-user-data.yaml"
CLOUDBASE_INIT_FILE="${SCRIPT_DIR}/cloudbase-init-user-data.yaml"
ENV_FILE="${SCRIPT_DIR}/.env"

[[ -f "${ENV_FILE}" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"
[[ -f "${SCRIPT_DIR}/lib/public-ip.sh" ]] || { echo "Error: ${SCRIPT_DIR}/lib/public-ip.sh not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/public-ip.sh"

: "${UPLINK_NETWORK:?UPLINK_NETWORK not set in ${ENV_FILE}}"
: "${IPV4_SUBNET_PREFIX:?IPV4_SUBNET_PREFIX not set in ${ENV_FILE}}"
: "${STORAGE_POOL:?STORAGE_POOL not set in ${ENV_FILE}}"
: "${PROJECT_NAT_IPV4_PREFIX:?PROJECT_NAT_IPV4_PREFIX not set in ${ENV_FILE}}"

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: deploy-project.sh --project-name NAME --project-id ID

Options:
  --project-name NAME   Project name to create.
  --project-id ID       Numeric project ID from 2 to 253. It sets the network
                        subnet (<IPV4_SUBNET_PREFIX>.<id>.0/24) and the router /
                        default NAT address (<PROJECT_NAT_IPV4_PREFIX>.<id>).
  --help                Show this help message.

Examples:
  ./deploy-project.sh --project-name demo --project-id 42
EOF
}

run() {
  "$@" || fail "command failed: $*"
}

cleanup_network() {
  if incus network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
    echo "Cleaning up network '${NETWORK_NAME}' due to earlier failure..." >&2
    incus network delete "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || true
  fi
}

PROJECT_NAME=''
PROJECT_ID=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)
      [[ $# -ge 2 ]] || fail 'missing value for --project-name.'
      PROJECT_NAME="$2"
      shift 2
      ;;
    --project-id)
      [[ $# -ge 2 ]] || fail 'missing value for --project-id.'
      PROJECT_ID="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

if [[ -z "${PROJECT_NAME}" ]]; then
  read -r -p 'Project name: ' PROJECT_NAME
fi
if [[ -z "${PROJECT_ID}" ]]; then
  read -r -p 'Project ID (2-253): ' PROJECT_ID
fi

[[ -n "${PROJECT_NAME}" ]] || fail 'project name cannot be empty.'
[[ "${PROJECT_ID}" =~ ^[0-9]+$ ]] || fail 'project ID must be numeric.'
# .0, .1 (gateway) and .255 of the router /24 are unusable and .254 belongs to
# the default project's network.
(( PROJECT_ID >= 2 && PROJECT_ID <= 253 )) || fail 'project ID must be between 2 and 253.'

NETWORK_NAME="${PROJECT_NAME}"
PROFILE_LINUX_NAME="${PROJECT_NAME}-linux"
PROFILE_WIN_NAME="${PROJECT_NAME}-win"
IPV4_ADDRESS="${IPV4_SUBNET_PREFIX}.${PROJECT_ID}.1/24"
ROUTER_IPV4="${PROJECT_NAT_IPV4_PREFIX}.${PROJECT_ID}"

command -v incus >/dev/null 2>&1 || fail 'incus command not found in PATH.'
[[ -f "${CLOUD_INIT_FILE}" ]] || fail "cloud-init file '${CLOUD_INIT_FILE}' not found."
[[ -f "${CLOUDBASE_INIT_FILE}" ]] || fail "cloudbase-init file '${CLOUDBASE_INIT_FILE}' not found."
incus storage show "${STORAGE_POOL}" >/dev/null 2>&1 || fail "storage pool '${STORAGE_POOL}' was not found."
incus network show "${UPLINK_NETWORK}" --project default >/dev/null 2>&1 || fail "uplink network '${UPLINK_NETWORK}' was not found."
nat_used_addresses "${UPLINK_NETWORK}" | grep -qxF "${ROUTER_IPV4}" \
  && fail "router address ${ROUTER_IPV4} is already used on uplink '${UPLINK_NETWORK}' (is project ID ${PROJECT_ID} taken?)."
[[ -n "$(incus network get "${UPLINK_NETWORK}" ipv4.routes --project default 2>/dev/null)" ]] \
  || echo "Warning: uplink '${UPLINK_NETWORK}' has no ipv4.routes; create-instance.sh cannot assign 1:1 NAT public IPs until a range is added." >&2

incus project show "${PROJECT_NAME}" >/dev/null 2>&1 && fail "project '${PROJECT_NAME}' already exists."

echo "Creating project '${PROJECT_NAME}'..."
run incus project create "${PROJECT_NAME}"

PROJECT_SHOW_FILE="$(mktemp)"
cleanup_project_metadata() {
  rm -f "${PROJECT_SHOW_FILE}"
}
trap 'cleanup_network; cleanup_project_metadata' ERR

run incus project show "${PROJECT_NAME}" > "${PROJECT_SHOW_FILE}"
python3 - "${PROJECT_SHOW_FILE}" "${PROJECT_ID}" <<'PY'
import sys
from pathlib import Path
import yaml
path = Path(sys.argv[1])
project_id = sys.argv[2]
with path.open() as f:
    data = yaml.safe_load(f) or {}
data['description'] = f'Project ID: {project_id}'
with path.open('w') as f:
    yaml.safe_dump(data, f, sort_keys=False)
PY
incus project edit "${PROJECT_NAME}" < "${PROJECT_SHOW_FILE}" >/dev/null || fail "unable to update project description for '${PROJECT_NAME}'."
cleanup_project_metadata

run incus project set "${PROJECT_NAME}" features.images=false
run incus project set "${PROJECT_NAME}" features.networks=true
run incus project set "${PROJECT_NAME}" features.networks.zones=true
run incus project set "${PROJECT_NAME}" features.profiles=true
run incus project set "${PROJECT_NAME}" features.storage.volumes=true
run incus project set "${PROJECT_NAME}" restricted=false

trap cleanup_network ERR

# Presetting the router's uplink address makes Incus use it instead of taking
# the next free address from ipv4.ovn.ranges; it is also the network's default
# outbound NAT address.
echo "Creating OVN network '${NETWORK_NAME}' with IPv4 subnet ${IPV4_ADDRESS}, router/NAT address ${ROUTER_IPV4}, uplink ${UPLINK_NETWORK}, MTU ${OVN_MTU}, and IPv6 disabled..."
run incus network create "${NETWORK_NAME}" \
  --project "${PROJECT_NAME}" \
  --type=ovn \
  network="${UPLINK_NETWORK}" \
  bridge.mtu="${OVN_MTU}" \
  ipv4.address="${IPV4_ADDRESS}" \
  ipv4.nat=true \
  ipv6.address=none \
  volatile.network.ipv4.address="${ROUTER_IPV4}"

run incus project set "${PROJECT_NAME}" restricted.networks.access="${NETWORK_NAME}"
run incus project set "${PROJECT_NAME}" restricted.devices.nic=managed
run incus project set "${PROJECT_NAME}" restricted.devices.disk=managed

echo "Leaving the required default profile in place for project '${PROJECT_NAME}'..."

echo "Creating Linux profile '${PROFILE_LINUX_NAME}' in project '${PROJECT_NAME}'..."
run incus profile create "${PROFILE_LINUX_NAME}" --project "${PROJECT_NAME}"

CLOUD_INIT_CONTENT="$(cat "${CLOUD_INIT_FILE}")"

cat <<PROFILE | incus profile edit "${PROFILE_LINUX_NAME}" --project "${PROJECT_NAME}" >/dev/null || fail "unable to apply profile '${PROFILE_LINUX_NAME}'."
config:
  boot.autostart: "true"
  cloud-init.user-data: |
$(printf '%s\n' "${CLOUD_INIT_CONTENT}" | sed 's/^/    /')
  limits.cpu: "1"
  limits.memory: 2GiB
  snapshots.expiry: 3d
  snapshots.schedule: '@daily'
description: ""
devices:
  eth0:
    name: eth0
    network: ${NETWORK_NAME}
    type: nic
  root:
    path: /
    pool: ${STORAGE_POOL}
    size: 20GiB
    type: disk
name: ${PROFILE_LINUX_NAME}
PROFILE

echo "Creating Windows profile '${PROFILE_WIN_NAME}' in project '${PROJECT_NAME}'..."
run incus profile create "${PROFILE_WIN_NAME}" --project "${PROJECT_NAME}"

CLOUDBASE_INIT_CONTENT="$(cat "${CLOUDBASE_INIT_FILE}")"

cat <<PROFILE | incus profile edit "${PROFILE_WIN_NAME}" --project "${PROJECT_NAME}" >/dev/null || fail "unable to apply profile '${PROFILE_WIN_NAME}'."
config:
  boot.autostart: "true"
  cloud-init.user-data: |
$(printf '%s\n' "${CLOUDBASE_INIT_CONTENT}" | sed 's/^/    /')
  limits.cpu: "2"
  limits.memory: 4GiB
  snapshots.expiry: 3d
  snapshots.schedule: '@daily'
description: ""
devices:
  eth0:
    name: eth0
    network: ${NETWORK_NAME}
    type: nic
  root:
    path: /
    pool: ${STORAGE_POOL}
    size: 64GiB
    type: disk
name: ${PROFILE_WIN_NAME}
PROFILE

trap - ERR

echo
echo 'Deployment complete.'
echo "Project : ${PROJECT_NAME}"
echo "Network : ${NETWORK_NAME} (${IPV4_ADDRESS}, NAT ${ROUTER_IPV4})"
echo "Uplink  : ${UPLINK_NETWORK}"
echo "MTU     : ${OVN_MTU}"
echo "Profiles: ${PROFILE_LINUX_NAME}, ${PROFILE_WIN_NAME}"
