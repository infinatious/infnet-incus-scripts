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
       deploy-project.sh --project-name NAME --add-missing-profiles

Creates a project, its OVN network and three profiles: NAME-linux, NAME-win
and NAME-docker (Linux with security.nesting on and Docker Engine plus the
Compose plugin installed by cloud-init).

Options:
  --project-name NAME     Project name to create.
  --project-id ID         Numeric project ID from 2 to 253. It sets the network
                          subnet (<IPV4_SUBNET_PREFIX>.<id>.0/24) and the router /
                          default NAT address (<PROJECT_NAT_IPV4_PREFIX>.<id>).
  --add-missing-profiles  For an existing project, create whichever of the
                          three profiles it lacks and leave the rest alone.
  --help                  Show this help message.

Examples:
  ./deploy-project.sh --project-name demo --project-id 42
  ./deploy-project.sh --project-name infra-edge --add-missing-profiles
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

# Writes a profile from its extra config lines (already indented under
# config:), cloud-init payload and root disk size.
write_profile() {
  local name="$1" config_lines="$2" user_data="$3" disk_size="$4"
  run incus profile create "${name}" --project "${PROJECT_NAME}" </dev/null
  cat <<PROFILE | incus profile edit "${name}" --project "${PROJECT_NAME}" >/dev/null || fail "unable to apply profile '${name}'."
config:
  boot.autostart: "true"
  cloud-init.user-data: |
$(printf '%s\n' "${user_data}" | sed 's/^/    /')
${config_lines}
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
    size: ${disk_size}
    type: disk
name: ${name}
PROFILE
}

# The Linux payload with Docker added, so users and keys stay defined in one
# file. Docker Engine and the Compose plugin come from Docker's own repos:
# get.docker.com sets them up on Debian, Ubuntu and Fedora but refuses
# AlmaLinux and Rocky, which get Docker's RHEL repo directly (checked first,
# since their ID_LIKE also contains "fedora").
docker_user_data() {
  python3 - "${CLOUD_INIT_FILE}" <<'PY'
import sys
import yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
users = [u["name"] for u in data.get("users", []) if isinstance(u, dict) and u.get("name")]
install = """. /etc/os-release
case " ${ID} ${ID_LIKE:-} " in
  *" rhel "*|*" centos "*)
    curl -fsSL https://download.docker.com/linux/rhel/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
  *) curl -fsSL https://get.docker.com | sh ;;
esac
"""
docker = [install, ["systemctl", "enable", "--now", "docker"]]
docker += [["usermod", "-aG", "docker", user] for user in users]
data["runcmd"] = docker + (data.get("runcmd") or [])
print("#cloud-config")
class Dumper(yaml.SafeDumper):
    pass
Dumper.add_representer(str, lambda d, v: d.represent_scalar("tag:yaml.org,2002:str", v, style="|" if "\n" in v else None))
print(yaml.dump(data, Dumper=Dumper, sort_keys=False, width=4096), end="")
PY
}

# Creates the project's standard profiles, skipping any that already exist.
create_standard_profiles() {
  local name
  name="${PROJECT_NAME}-linux"
  if incus profile show "${name}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
    echo "Linux profile '${name}' already exists, leaving it."
  else
    echo "Creating Linux profile '${name}' in project '${PROJECT_NAME}'..."
    write_profile "${name}" $'  limits.cpu: "1"\n  limits.memory: 2GiB' "$(cat "${CLOUD_INIT_FILE}")" 20GiB
  fi

  name="${PROJECT_NAME}-win"
  if incus profile show "${name}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
    echo "Windows profile '${name}' already exists, leaving it."
  else
    echo "Creating Windows profile '${name}' in project '${PROJECT_NAME}'..."
    write_profile "${name}" $'  limits.cpu: "2"\n  limits.memory: 4GiB' "$(cat "${CLOUDBASE_INIT_FILE}")" 64GiB
  fi

  # security.nesting lets dockerd create its own namespaces, cgroups and
  # overlay mounts inside the (still unprivileged) container.
  name="${PROJECT_NAME}-docker"
  if incus profile show "${name}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
    echo "Docker profile '${name}' already exists, leaving it."
  else
    echo "Creating Docker profile '${name}' in project '${PROJECT_NAME}'..."
    local user_data
    user_data="$(docker_user_data)" || fail "unable to build the Docker cloud-init payload."
    write_profile "${name}" $'  limits.cpu: "2"\n  limits.memory: 4GiB\n  security.nesting: "true"' "${user_data}" 40GiB
  fi
}

PROJECT_NAME=''
PROJECT_ID=''
ADD_MISSING_PROFILES=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --add-missing-profiles)
      ADD_MISSING_PROFILES='yes'
      shift
      ;;
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

if [[ -n "${ADD_MISSING_PROFILES}" ]]; then
  [[ -n "${PROJECT_NAME}" ]] || fail 'project name cannot be empty.'
  [[ -f "${CLOUD_INIT_FILE}" ]] || fail "cloud-init file '${CLOUD_INIT_FILE}' not found."
  [[ -f "${CLOUDBASE_INIT_FILE}" ]] || fail "cloudbase-init file '${CLOUDBASE_INIT_FILE}' not found."
  incus project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."
  NETWORK_NAME="${PROJECT_NAME}"
  incus network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 \
    || fail "project '${PROJECT_NAME}' has no network named '${NETWORK_NAME}'."
  create_standard_profiles
  exit 0
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
# incus create/launch commands read YAML from stdin when it isn't a terminal,
# so they get </dev/null to never block on (or swallow) a pipe or ssh channel.
run incus project create "${PROJECT_NAME}" </dev/null

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
  volatile.network.ipv4.address="${ROUTER_IPV4}" </dev/null

run incus project set "${PROJECT_NAME}" restricted.networks.access="${NETWORK_NAME}"
run incus project set "${PROJECT_NAME}" restricted.devices.nic=managed
run incus project set "${PROJECT_NAME}" restricted.devices.disk=managed

echo "Leaving the required default profile in place for project '${PROJECT_NAME}'..."

create_standard_profiles

trap - ERR

echo
echo 'Deployment complete.'
echo "Project : ${PROJECT_NAME}"
echo "Network : ${NETWORK_NAME} (${IPV4_ADDRESS}, NAT ${ROUTER_IPV4})"
echo "Uplink  : ${UPLINK_NETWORK}"
echo "MTU     : ${OVN_MTU}"
echo "Profiles: ${PROJECT_NAME}-linux, ${PROJECT_NAME}-win, ${PROJECT_NAME}-docker"
