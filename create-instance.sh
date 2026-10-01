#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: create-instance.sh --project-id ID --environment ENV --service-code CODE --profile-type TYPE [--cpu N] [--ram GIB] [--disk GIB] [--image-index N] [--image-alias NAME] [--public-ip IP|random | --no-public-ip] [--description-suffix TEXT] [--empty] [--target MEMBER]

Options:
  --project-id ID          Numeric project ID to select the project.
  --environment ENV        Environment code: p, t, q, or d.
  --service-code CODE      Five-character service code (alphanumeric).
  --profile-type TYPE      Profile family: linux, win or docker (Linux container
                           with Docker and Compose preinstalled).
  --cpu N                  Override CPU core count.
  --ram GIB                Override RAM size in GiB.
  --disk GIB               Override boot disk size in GiB.
  --image-index N          Pick the desired image by the displayed list index.
  --image-alias NAME       Pick an image by exact alias name.
  --public-ip IP|random    Give the instance a 1:1 NAT public IPv4: a specific
                           address from the uplink's ipv4.routes, or 'random'
                           for a random free one.
  --no-public-ip           No public IP; the instance only reaches out through
                           its project's shared NAT address.
                           With neither flag the script asks, or picks a random
                           public IP when not run from a terminal.
  --description-suffix TEXT
                           Optional suffix appended to the generated description.
  --empty                  Create an empty VM (no image) and leave it stopped,
                           with its NIC, firewall ACL, 1:1 NAT and DNS set up as
                           usual: the target for an imported disk (e.g. from
                           Proxmox, see README "Importing a VM disk").
  --target MEMBER          Cluster member to create the instance on (default:
                           Incus picks one).
  --help                   Show this help message.

Examples:
  ./create-instance.sh --project-id 42 --environment p --service-code demo1 --profile-type linux --cpu 2 --ram 4 --disk 20 --image-index 3
  ./create-instance.sh --project-id 42 --environment d --service-code svc01 --profile-type win --image-alias ubuntu --description-suffix 'site-a'
  ./create-instance.sh --project-id 24 --environment p --service-code rdsts --profile-type win --cpu 4 --ram 8 --disk 100 --public-ip random --empty --target us-west-b
EOF
}

run() {
  "$@" || fail "command failed: $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' not found in PATH."
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DNS_LIB_FILE="${SCRIPT_DIR}/dns/technitium-dns.sh"
NAT_LIB_FILE="${SCRIPT_DIR}/lib/public-ip.sh"

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
[[ -f "${DNS_LIB_FILE}" ]] || fail "${DNS_LIB_FILE} not found."
# shellcheck source=/dev/null
source "${DNS_LIB_FILE}"
[[ -f "${NAT_LIB_FILE}" ]] || fail "${NAT_LIB_FILE} not found."
# shellcheck source=/dev/null
source "${NAT_LIB_FILE}"
[[ -f "${SCRIPT_DIR}/lib/firewall.sh" ]] || fail "${SCRIPT_DIR}/lib/firewall.sh not found."
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/zabbix.sh"

ARGS_PROVIDED=$#

PROJECT_ID_ARG=''
ENV_CODE_ARG=''
SERVICE_CODE_ARG=''
PROFILE_TYPE_ARG=''
CPU_ARG=''
RAM_ARG=''
DISK_ARG=''
IMAGE_INDEX_ARG=''
IMAGE_ALIAS_ARG=''
PUBLIC_IP_ARG=''
NO_PUBLIC_IP_ARG=''
DESCRIPTION_SUFFIX_ARG=''
EMPTY_ARG=''
TARGET_ARG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      [[ $# -ge 2 ]] || fail 'missing value for --project-id.'
      PROJECT_ID_ARG="$2"
      shift 2
      ;;
    --environment)
      [[ $# -ge 2 ]] || fail 'missing value for --environment.'
      ENV_CODE_ARG="$2"
      shift 2
      ;;
    --service-code)
      [[ $# -ge 2 ]] || fail 'missing value for --service-code.'
      SERVICE_CODE_ARG="$2"
      shift 2
      ;;
    --profile-type)
      [[ $# -ge 2 ]] || fail 'missing value for --profile-type.'
      PROFILE_TYPE_ARG="$2"
      shift 2
      ;;
    --cpu)
      [[ $# -ge 2 ]] || fail 'missing value for --cpu.'
      CPU_ARG="$2"
      shift 2
      ;;
    --ram)
      [[ $# -ge 2 ]] || fail 'missing value for --ram.'
      RAM_ARG="$2"
      shift 2
      ;;
    --disk)
      [[ $# -ge 2 ]] || fail 'missing value for --disk.'
      DISK_ARG="$2"
      shift 2
      ;;
    --image-index)
      [[ $# -ge 2 ]] || fail 'missing value for --image-index.'
      IMAGE_INDEX_ARG="$2"
      shift 2
      ;;
    --image-alias)
      [[ $# -ge 2 ]] || fail 'missing value for --image-alias.'
      IMAGE_ALIAS_ARG="$2"
      shift 2
      ;;
    --public-ip)
      [[ $# -ge 2 ]] || fail 'missing value for --public-ip.'
      PUBLIC_IP_ARG="$2"
      shift 2
      ;;
    --no-public-ip)
      NO_PUBLIC_IP_ARG='yes'
      shift
      ;;
    --description-suffix)
      [[ $# -ge 2 ]] || fail 'missing value for --description-suffix.'
      DESCRIPTION_SUFFIX_ARG="$2"
      shift 2
      ;;
    --empty)
      EMPTY_ARG='yes'
      shift
      ;;
    --target)
      [[ $# -ge 2 ]] || fail 'missing value for --target.'
      TARGET_ARG="$2"
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

require_cmd incus
require_cmd jq
require_cmd python3
require_cmd curl

mapfile -t PROJECT_OPTIONS < <(
  incus project list -f json 2>/dev/null \
    | jq -r '.[] | select(.description | test("^Project ID: [0-9]+$")) | "\(.description | ltrimstr("Project ID: "))\t\(.name)"'
)
(( ${#PROJECT_OPTIONS[@]} > 0 )) || fail 'no projects with project ID metadata were found.'

echo 'Available projects:'
for PROJECT_ENTRY in "${PROJECT_OPTIONS[@]}"; do
  IFS=$'\t' read -r PROJECT_ID PROJECT_NAME <<< "${PROJECT_ENTRY}"
  printf '%2s) %s\n' "${PROJECT_ID}" "${PROJECT_NAME}"
done
if [[ -n "${PROJECT_ID_ARG}" ]]; then
  SELECTED_PROJECT_ID="${PROJECT_ID_ARG}"
else
  read -r -p 'Choose project ID: ' SELECTED_PROJECT_ID
fi
[[ "${SELECTED_PROJECT_ID}" =~ ^[0-9]+$ ]] || fail 'project selection must be numeric.'
PROJECT_NAME="$(awk -F '\t' -v pid="${SELECTED_PROJECT_ID}" '$1 == pid {print $2}' <<< "$(printf '%s\n' "${PROJECT_OPTIONS[@]}")")"
[[ -n "${PROJECT_NAME}" ]] || fail "project ID '${SELECTED_PROJECT_ID}' is not available."
PROJECT_ID="${SELECTED_PROJECT_ID}"

if [[ -n "${ENV_CODE_ARG}" ]]; then
  ENV_CODE="${ENV_CODE_ARG}"
else
  read -r -p 'Environment (p=production, t=test, q=qa, d=dev): ' ENV_CODE
fi
if [[ -n "${SERVICE_CODE_ARG}" ]]; then
  SERVICE_CODE="${SERVICE_CODE_ARG}"
else
  read -r -p 'Five-character service code: ' SERVICE_CODE
fi

[[ -n "${PROJECT_NAME}" ]] || fail 'project name cannot be empty.'
[[ "${SERVICE_CODE}" =~ ^[A-Za-z0-9]{5}$ ]] || fail 'service code must be exactly 5 alphanumeric characters.'

PROFILE_TYPE=''
PROFILE_NAME=''
NETWORK_NAME="${PROJECT_NAME}"

if [[ -n "${PROFILE_TYPE_ARG}" ]]; then
  PROFILE_TYPE="${PROFILE_TYPE_ARG}"
else
  read -r -p 'Profile type to use (linux, win or docker): ' PROFILE_TYPE
fi
case "${PROFILE_TYPE}" in
  linux|Linux|l)
    PROFILE_NAME="${PROJECT_NAME}-linux"
    PROFILE_FAMILY='linux'
    ;;
  win|Windows|w)
    PROFILE_NAME="${PROJECT_NAME}-win"
    PROFILE_FAMILY='win'
    ;;
  docker|Docker|d)
    PROFILE_NAME="${PROJECT_NAME}-linux-docker"
    PROFILE_FAMILY='linux'
    ;;
  *)
    fail 'profile type must be linux, win or docker.'
    ;;
esac

incus project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."
incus profile show "${PROFILE_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 \
  || fail "profile '${PROFILE_NAME}' does not exist in project '${PROJECT_NAME}' (add it with: ./deploy-project.sh --project-name ${PROJECT_NAME} --add-missing-profiles)."
PROFILE_SHOW_FILE="$(mktemp)"
DESC_FILE=''
cleanup() {
  rm -f "${PROFILE_SHOW_FILE}" "${DESC_FILE}"
}
trap cleanup EXIT
incus profile show "${PROFILE_NAME}" --project "${PROJECT_NAME}" > "${PROFILE_SHOW_FILE}"

PROFILE_CPU_CORES="$(python3 - "${PROFILE_SHOW_FILE}" <<'PY'
import sys
from pathlib import Path
import yaml
profile_path = Path(sys.argv[1])
with profile_path.open() as f:
    data = yaml.safe_load(f) or {}
config = data.get('config', {}) or {}
print(config.get('limits.cpu', '2'))
PY
)"
PROFILE_RAM_GIB="$(python3 - "${PROFILE_SHOW_FILE}" <<'PY'
import sys
from pathlib import Path
import yaml
profile_path = Path(sys.argv[1])
with profile_path.open() as f:
    data = yaml.safe_load(f) or {}
config = data.get('config', {}) or {}
mem = str(config.get('limits.memory', '4GiB'))
print(mem.replace('GiB', '').replace('G', '').replace('i', '').replace('B', '').strip() or '4')
PY
)"
PROFILE_DISK_GIB="$(python3 - "${PROFILE_SHOW_FILE}" <<'PY'
import sys
from pathlib import Path
import yaml
profile_path = Path(sys.argv[1])
with profile_path.open() as f:
    data = yaml.safe_load(f) or {}
devices = data.get('devices', {}) or {}
root = devices.get('root', {}) or {}
size = str(root.get('size', '20GiB'))
print(size.replace('GiB', '').replace('G', '').replace('i', '').replace('B', '').strip() or '20')
PY
)"

if [[ -n "${CPU_ARG}" ]]; then
  CPU_CORES="${CPU_ARG}"
else
  read -r -p "CPU cores [${PROFILE_CPU_CORES}]: " CPU_CORES
fi
CPU_CORES="${CPU_CORES:-${PROFILE_CPU_CORES}}"
if [[ -n "${RAM_ARG}" ]]; then
  RAM_GIB="${RAM_ARG}"
else
  read -r -p "RAM (GiB, number only) [${PROFILE_RAM_GIB}]: " RAM_GIB
fi
RAM_GIB="${RAM_GIB:-${PROFILE_RAM_GIB}}"
if [[ -n "${DISK_ARG}" ]]; then
  DISK_GIB="${DISK_ARG}"
else
  read -r -p "Boot disk size (GiB, number only) [${PROFILE_DISK_GIB}]: " DISK_GIB
fi
DISK_GIB="${DISK_GIB:-${PROFILE_DISK_GIB}}"

[[ "${CPU_CORES}" =~ ^[0-9]+$ ]] || fail 'CPU cores must be numeric.'
[[ "${RAM_GIB}" =~ ^[0-9]+$ ]] || fail 'RAM must be numeric GiB.'
[[ "${DISK_GIB}" =~ ^[0-9]+$ ]] || fail 'boot disk size must be numeric GiB.'

incus network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || fail "network '${NETWORK_NAME}' does not exist in project '${PROJECT_NAME}'."

NETWORK_IPV4_CIDR="$(incus network get "${NETWORK_NAME}" ipv4.address --project "${PROJECT_NAME}" 2>/dev/null || true)"
[[ -n "${NETWORK_IPV4_CIDR}" ]] || fail "network '${NETWORK_NAME}' does not have an ipv4.address configured."
PROJECT_ID="$(awk -F '[./]' '{print $3}' <<< "${NETWORK_IPV4_CIDR}")"
[[ "${PROJECT_ID}" =~ ^[0-9]+$ ]] || fail "unable to determine project ID from network subnet '${NETWORK_IPV4_CIDR}'."
(( PROJECT_ID >= 1 && PROJECT_ID <= 255 )) || fail 'derived project ID must be between 1 and 255.'

# Settle the 1:1 NAT public IP before launching so a bad address or an
# exhausted range fails here instead of leaving an instance behind.
[[ -n "${PUBLIC_IP_ARG}" && -n "${NO_PUBLIC_IP_ARG}" ]] && fail '--public-ip and --no-public-ip are mutually exclusive.'
if [[ -n "${NO_PUBLIC_IP_ARG}" ]]; then
  PUBLIC_IP_CHOICE='none'
elif [[ -n "${PUBLIC_IP_ARG}" ]]; then
  PUBLIC_IP_CHOICE="${PUBLIC_IP_ARG}"
elif [[ -t 0 ]]; then
  read -r -p 'Assign a public IP (1:1 NAT)? [Y/n]: ' WANT_PUBLIC_IP
  if [[ "${WANT_PUBLIC_IP,,}" =~ ^(n|no)$ ]]; then
    PUBLIC_IP_CHOICE='none'
  else
    UPLINK_NAME="$(nat_network_uplink "${NETWORK_NAME}" "${PROJECT_NAME}")"
    ROUTES_HINT="$(incus network get "${UPLINK_NAME}" ipv4.routes --project default 2>/dev/null || true)"
    read -r -p "Public IP from ${ROUTES_HINT:-the uplink routes} (blank for a random free address): " PUBLIC_IP_CHOICE
    PUBLIC_IP_CHOICE="${PUBLIC_IP_CHOICE:-random}"
  fi
else
  PUBLIC_IP_CHOICE='random'
fi

PUBLIC_IPV4=''
if [[ "${PUBLIC_IP_CHOICE}" != 'none' ]]; then
  nat_require_support || exit 1
  UPLINK_NAME="$(nat_network_uplink "${NETWORK_NAME}" "${PROJECT_NAME}")"
  [[ -n "${UPLINK_NAME}" && "${UPLINK_NAME}" != 'none' ]] || fail "network '${NETWORK_NAME}' has no uplink network, so it cannot use 1:1 NAT."
  if [[ "${PUBLIC_IP_CHOICE}" == 'random' ]]; then
    PUBLIC_IPV4="$(nat_allocate_address "${UPLINK_NAME}")" || exit 1
  else
    nat_validate_address "${UPLINK_NAME}" "${PUBLIC_IP_CHOICE}" || exit 1
    PUBLIC_IPV4="${PUBLIC_IP_CHOICE}"
  fi
  echo "Public IPv4 for 1:1 NAT: ${PUBLIC_IPV4} (uplink '${UPLINK_NAME}')."
else
  echo 'No public IP: the instance will only reach out through its project NAT address.'
fi

case "${ENV_CODE}" in
  p)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='prd'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='pd'; else ENV_PREFIX='p'; fi
    ;;
  t)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='tst'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='ts'; else ENV_PREFIX='t'; fi
    ;;
  q)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='qua'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='qa'; else ENV_PREFIX='q'; fi
    ;;
  d)
    if (( PROJECT_ID < 10 )); then ENV_PREFIX='dev'; elif (( PROJECT_ID < 100 )); then ENV_PREFIX='dv'; else ENV_PREFIX='d'; fi
    ;;
  *)
    fail 'environment must be p, t, q, or d.'
    ;;
esac

PROJECT_ID_STR="${PROJECT_ID}"

if [[ -n "${EMPTY_ARG}" ]]; then
  # An empty VM gets its disk written later, so there's no image to pick.
  [[ "${PROFILE_TYPE}" =~ ^(docker|Docker|d)$ ]] && fail '--empty creates a VM; use --profile-type win or linux.'
  [[ -z "${IMAGE_INDEX_ARG}${IMAGE_ALIAS_ARG}" ]] || fail '--empty takes no image.'
  SELECTED_TYPE='virtual-machine'; SELECTED_ALIAS='(empty)'; SELECTED_FP12='-'; SELECTED_FP_FULL=''
else
  # Docker relies on security.nesting, which only applies to containers.
  case "${PROFILE_TYPE}" in
    linux|Linux|l) IMAGE_FILTER='((.aliases | map(.name // "") | join(" ")) | test("win"; "i")) | not' ;;
    win|Windows|w) IMAGE_FILTER='(.aliases | map(.name // "") | join(" ")) | test("win"; "i")' ;;
    docker|Docker|d) IMAGE_FILTER='.type == "container" and (((.aliases | map(.name // "") | join(" ")) | test("win"; "i")) | not)' ;;
  esac
  mapfile -t IMAGE_ROWS < <(incus image list --project default --format json | jq -r ".[] | select(${IMAGE_FILTER}) | [(.aliases[0].name // \"-\"), .fingerprint[0:12], .type, .architecture, (.description // \"\")] | @tsv")
  (( ${#IMAGE_ROWS[@]} > 0 )) || fail "no matching images found for profile '${PROFILE_NAME}'."

  echo 'Available images:'
  for i in "${!IMAGE_ROWS[@]}"; do
    IFS=$'\t' read -r alias shortfp imgtype arch desc <<< "${IMAGE_ROWS[$i]}"
    printf '%2d) alias=%s  fp=%s  type=%s  arch=%s  desc=%s\n' "$((i + 1))" "$alias" "$shortfp" "$imgtype" "$arch" "$desc"
  done

  if [[ -n "${IMAGE_INDEX_ARG}" ]]; then
    IMAGE_INDEX="${IMAGE_INDEX_ARG}"
  elif [[ -n "${IMAGE_ALIAS_ARG}" ]]; then
    IMAGE_MATCH=''
    for i in "${!IMAGE_ROWS[@]}"; do
      IFS=$'\t' read -r alias shortfp imgtype arch desc <<< "${IMAGE_ROWS[$i]}"
      if [[ "${alias}" == "${IMAGE_ALIAS_ARG}" ]]; then
        IMAGE_MATCH="$((i + 1))"
        break
      fi
    done
    [[ -n "${IMAGE_MATCH}" ]] || fail "image alias '${IMAGE_ALIAS_ARG}' was not found in the filtered list."
    IMAGE_INDEX="${IMAGE_MATCH}"
  else
    read -r -p 'Choose image number: ' IMAGE_INDEX
  fi
  [[ "${IMAGE_INDEX}" =~ ^[0-9]+$ ]] || fail 'image selection must be numeric.'
  (( IMAGE_INDEX >= 1 && IMAGE_INDEX <= ${#IMAGE_ROWS[@]} )) || fail 'image selection is out of range.'
  SELECTED_ROW="${IMAGE_ROWS[$((IMAGE_INDEX - 1))]}"
  SELECTED_ALIAS="$(awk -F '\t' '{print $1}' <<< "${SELECTED_ROW}")"
  SELECTED_FP12="$(awk -F '\t' '{print $2}' <<< "${SELECTED_ROW}")"
  SELECTED_TYPE="$(awk -F '\t' '{print $3}' <<< "${SELECTED_ROW}")"
  SELECTED_FP_FULL="$(incus image list --project default --format json | jq -r --arg fp "${SELECTED_FP12}" '.[] | select(.fingerprint | startswith($fp)) | .fingerprint' | head -n1)"
  [[ -n "${SELECTED_FP_FULL}" ]] || fail 'unable to resolve selected image fingerprint.'
fi

case "${SELECTED_TYPE}" in
  virtual-machine) INSTANCE_TYPE='vs' ;;
  container) INSTANCE_TYPE='ct' ;;
  *) fail "unsupported selected image type '${SELECTED_TYPE}'." ;;
esac

NAME_PREFIX="${ENV_PREFIX}${PROJECT_ID_STR}-${SERVICE_CODE}-${INSTANCE_TYPE}"
mapfile -t EXISTING_MATCHES < <(incus list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null | grep -E "^${NAME_PREFIX}[0-9]{2}$" || true)
NEXT_SEQ=1
if (( ${#EXISTING_MATCHES[@]} > 0 )); then
  LAST_SEQ="$(printf '%s\n' "${EXISTING_MATCHES[@]}" | sed -E 's/.*([0-9]{2})$/\1/' | sort -n | tail -n1)"
  NEXT_SEQ=$((10#${LAST_SEQ} + 1))
fi
(( NEXT_SEQ <= 99 )) || fail 'next sequence would exceed 99.'
INSTANCE_NAME="$(printf '%s%02d' "${NAME_PREFIX}" "${NEXT_SEQ}")"

if [[ -n "${EMPTY_ARG}" ]]; then
  INIT_ARGS=(init --empty --project "${PROJECT_NAME}" --profile "${PROFILE_NAME}" "${INSTANCE_NAME}" -c limits.cpu="${CPU_CORES}" -c limits.memory="${RAM_GIB}GiB")
else
  INIT_ARGS=(init --project "${PROJECT_NAME}" --profile "${PROFILE_NAME}" "${SELECTED_FP_FULL}" "${INSTANCE_NAME}" -c limits.cpu="${CPU_CORES}" -c limits.memory="${RAM_GIB}GiB")
fi
if [[ "${SELECTED_TYPE}" == 'virtual-machine' ]]; then
  INIT_ARGS+=(--vm)
fi
INIT_ARGS+=(-d root,size="${DISK_GIB}GiB")
[[ -z "${TARGET_ARG}" ]] || INIT_ARGS+=(--target "${TARGET_ARG}")

if [[ -n "${EMPTY_ARG}" ]]; then
  echo "Creating empty VM '${INSTANCE_NAME}'${TARGET_ARG:+ on ${TARGET_ARG}}..."
else
  echo "Creating instance '${INSTANCE_NAME}' from image ${SELECTED_ALIAS} (${SELECTED_FP12})${TARGET_ARG:+ on ${TARGET_ARG}}..."
fi
# incus create/launch commands read YAML from stdin when it isn't a terminal,
# so they get </dev/null to never block on (or swallow) a pipe or ssh channel.
run incus "${INIT_ARGS[@]}" </dev/null

# Images that can't load the incus-agent over virtiofs/9p (e.g. Windows) are
# marked requirements.cdrom_agent and won't start without the agent drive.
NEEDS_AGENT_DRIVE="$([[ -n "${SELECTED_FP_FULL}" ]] && incus image show "${SELECTED_FP_FULL}" --project default 2>/dev/null \
  | python3 -c 'import sys, yaml; print((yaml.safe_load(sys.stdin) or {}).get("properties", {}).get("requirements.cdrom_agent", ""))')"
if [[ "${SELECTED_TYPE}" == 'virtual-machine' && "${NEEDS_AGENT_DRIVE}" == 'true' ]]; then
  echo 'Image requires the incus-agent drive; adding it...'
  run incus config device add "${INSTANCE_NAME}" agent disk source=agent:config --project "${PROJECT_NAME}" </dev/null
fi

# Configure the NIC completely (firewall, pinned address, 1:1 NAT) before the
# first start: changing it on a running VM re-plugs the NIC, which a booting
# guest (e.g. Windows) doesn't release in time ("Duplicate device ID").
remove_new_instance() {
  incus delete -f "${INSTANCE_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || true
  [[ -z "${PUBLIC_IPV4}" ]] || incus network forward delete "${NETWORK_NAME}" "${PUBLIC_IPV4}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || true
  fw_delete_acl "${INSTANCE_NAME}" "${PROJECT_NAME}" >/dev/null 2>&1 || true
}

read -r FW_PORT FW_SERVICE <<< "$(fw_default_rule "${PROFILE_FAMILY}")"
echo "Creating firewall ACL '${INSTANCE_NAME}': inbound ICMP and ${FW_SERVICE} (tcp/${FW_PORT}) only, outbound open..."
fw_create_acl "${INSTANCE_NAME}" "${PROJECT_NAME}" "${PROFILE_FAMILY}" \
  || { remove_new_instance; fail "unable to create firewall ACL '${INSTANCE_NAME}'; the instance was removed."; }
mapfile -t FW_NIC_KEYS < <(fw_nic_keys "${INSTANCE_NAME}")

DNS_FQDN="$(dns_public_name "${INSTANCE_NAME}")"
DNS_INTERNAL_FQDN="$(dns_internal_name "${INSTANCE_NAME}" "${PROJECT_NAME}")"
INSTANCE_IPV4=''
if [[ -n "${PUBLIC_IPV4}" ]]; then
  INSTANCE_IPV4="$(nat_allocate_internal_address "${NETWORK_NAME}" "${PROJECT_NAME}")" \
    || { remove_new_instance; fail "no internal address available on '${NETWORK_NAME}'; the instance was removed."; }
  echo "Mapping public ${PUBLIC_IPV4} 1:1 to ${INSTANCE_IPV4} on '${NETWORK_NAME}'..."
  nat_attach "${INSTANCE_NAME}" "${PROJECT_NAME}" "${NETWORK_NAME}" "${PUBLIC_IPV4}" "${INSTANCE_IPV4}" "${FW_NIC_KEYS[@]}" \
    || { remove_new_instance; fail "unable to create the 1:1 NAT for '${INSTANCE_NAME}'; the instance was removed."; }
else
  nat_set_nic "${INSTANCE_NAME}" "${PROJECT_NAME}" "${FW_NIC_KEYS[@]}" \
    || { remove_new_instance; fail "unable to attach firewall ACL '${INSTANCE_NAME}' to ${PUBLIC_IP_NIC}; the instance was removed."; }
fi

if [[ -n "${EMPTY_ARG}" ]]; then
  echo "Leaving '${INSTANCE_NAME}' stopped: write its disk, then start it."
elif ! incus start "${INSTANCE_NAME}" --project "${PROJECT_NAME}"; then
  # It never ran, so remove it (with its forward and ACL) rather than leave an
  # orphan that also bumps the next instance's sequence number.
  remove_new_instance
  fail "instance '${INSTANCE_NAME}' failed to start and was removed."
fi

if [[ -n "${PUBLIC_IPV4}" ]]; then
  dns_register_public "${INSTANCE_NAME}" "${PUBLIC_IPV4}" || true
else
  echo "No public IP, so no DNS record is registered for '${DNS_FQDN}'."
fi

# With a public IP the address was pinned above; otherwise find the one OVN
# handed out. The guest-reported address needs the incus-agent; VMs without
# it (e.g. a fresh Windows install) never report one, so fall back to the
# address OVN assigned to the NIC's port, matched by MAC.
[[ -n "${INSTANCE_IPV4}" || -n "${EMPTY_ARG}" ]] || echo 'Waiting for IPv4 address...'
INSTANCE_HWADDR="$(incus config get "${INSTANCE_NAME}" "volatile.${PUBLIC_IP_NIC}.hwaddr" --project "${PROJECT_NAME}" 2>/dev/null || true)"
for _ in $(seq 1 60); do
  [[ -n "${INSTANCE_IPV4}" || -n "${EMPTY_ARG}" ]] && break
  INSTANCE_IPV4="$(incus query "/1.0/instances/${INSTANCE_NAME}/state?project=${PROJECT_NAME}" 2>/dev/null \
    | jq -r --arg nic "${PUBLIC_IP_NIC}" '.network[$nic].addresses[]? | select(.family=="inet" and .scope=="global") | .address' | head -n1)"
  if [[ -z "${INSTANCE_IPV4}" && -n "${INSTANCE_HWADDR}" ]]; then
    INSTANCE_IPV4="$(incus network list-leases "${NETWORK_NAME}" --project "${PROJECT_NAME}" -f json 2>/dev/null \
      | jq -r --arg mac "${INSTANCE_HWADDR}" '.[] | select((.hwaddr | ascii_downcase) == ($mac | ascii_downcase)) | .address | select(test("^[0-9.]+$"))' | head -n1)"
  fi
  [[ -n "${INSTANCE_IPV4}" ]] && break
  sleep 2
done
# Internal OVN addresses aren't reachable from INFNET, so a VM without a
# public IP that never reports one is fine.
[[ -n "${INSTANCE_IPV4}" ]] || INSTANCE_IPV4='unknown'
if [[ "${INSTANCE_IPV4}" != 'unknown' ]]; then
  dns_register_internal "${INSTANCE_NAME}" "${PROJECT_NAME}" "${INSTANCE_IPV4}" || true
else
  echo "Internal address unknown, so '${DNS_INTERNAL_FQDN}' isn't registered yet; dns/sync-dns-records.sh adds it later."
fi

# Monitoring: register the host in Zabbix. Imported VMs (--empty) carry their
# own OS, so they get no agent template; link one by hand if they run an agent.
INSTANCE_FAMILY="${PROFILE_FAMILY}"
zabbix_register_instance "${INSTANCE_NAME}" "${PROJECT_NAME}" "${INSTANCE_FAMILY}" "${PUBLIC_IPV4}" \
  "$([[ "${INSTANCE_IPV4}" != 'unknown' ]] && echo "${INSTANCE_IPV4}")" "$([[ -n "${EMPTY_ARG}" ]] && echo no || echo auto)" || true

if [[ -n "${DESCRIPTION_SUFFIX_ARG}" ]]; then
  DESCRIPTION_SUFFIX="${DESCRIPTION_SUFFIX_ARG}"
elif (( ARGS_PROVIDED == 0 )); then
  read -r -p 'Description suffix (optional): ' DESCRIPTION_SUFFIX
else
  DESCRIPTION_SUFFIX=''
fi
DESCRIPTION_TEXT="${PUBLIC_IPV4}"
if [[ -n "${DESCRIPTION_SUFFIX}" ]]; then
  DESCRIPTION_TEXT="${DESCRIPTION_TEXT:+${DESCRIPTION_TEXT} }${DESCRIPTION_SUFFIX}"
fi
DESC_FILE="$(mktemp)"
incus config show "${INSTANCE_NAME}" --project "${PROJECT_NAME}" > "${DESC_FILE}"
python3 - "${DESC_FILE}" "${DESCRIPTION_TEXT}" <<'PY'
import sys
import yaml
path = sys.argv[1]
desc = sys.argv[2]
with open(path) as f:
    data = yaml.safe_load(f) or {}
data['description'] = desc
with open(path, 'w') as f:
    yaml.safe_dump(data, f, sort_keys=False)
PY
bash -c 'incus config edit "$1" --project "$2" < "$3"' _ "${INSTANCE_NAME}" "${PROJECT_NAME}" "${DESC_FILE}" || fail "unable to update description field for '${INSTANCE_NAME}'."

echo
echo 'Instance creation complete.'
echo "Name        : ${INSTANCE_NAME}"
echo "Project     : ${PROJECT_NAME}"
echo "Profile     : ${PROFILE_NAME}"
echo "Image       : ${SELECTED_ALIAS}${SELECTED_FP_FULL:+ (${SELECTED_FP12})}${EMPTY_ARG:+, not started}"
echo "Location    : $(incus list "${INSTANCE_NAME}" --project "${PROJECT_NAME}" -f csv -c L 2>/dev/null)"
echo "Type        : ${INSTANCE_TYPE}"
echo "Subnet      : ${NETWORK_IPV4_CIDR}"
echo "Project ID  : ${PROJECT_ID}"
echo "CPU         : ${CPU_CORES}"
echo "RAM         : ${RAM_GIB}GiB"
echo "Boot disk   : ${DISK_GIB}GiB"
echo "Instance IP : ${INSTANCE_IPV4}"
echo "Public IP   : ${PUBLIC_IPV4:-none}${PUBLIC_IPV4:+ (1:1 NAT)}"
echo "Firewall    : ACL '${INSTANCE_NAME}' - inbound ICMP and ${FW_SERVICE} (tcp/${FW_PORT}) only"
echo "Description : ${DESCRIPTION_TEXT}"
if technitium_configured; then
  [[ -n "${PUBLIC_IPV4}" ]] && echo "DNS         : ${DNS_FQDN} -> ${PUBLIC_IPV4}"
  [[ "${INSTANCE_IPV4}" != 'unknown' ]] && echo "DNS         : ${DNS_INTERNAL_FQDN} -> ${INSTANCE_IPV4}"
fi
