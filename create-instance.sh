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
Usage: create-instance.sh --project-id ID --environment ENV --service-code CODE --profile-type TYPE [--cpu N] [--ram GIB] [--disk GIB] [--image-index N] [--image-alias NAME] [--description-suffix TEXT]

Options:
  --project-id ID          Numeric project ID to select the project.
  --environment ENV        Environment code: p, t, q, or d.
  --service-code CODE      Five-character service code (alphanumeric).
  --profile-type TYPE      Profile family: linux or win.
  --cpu N                  Override CPU core count.
  --ram GIB                Override RAM size in GiB.
  --disk GIB               Override boot disk size in GiB.
  --image-index N          Pick the desired image by the displayed list index.
  --image-alias NAME       Pick an image by exact alias name.
  --description-suffix TEXT
                           Optional suffix appended to the generated description.
  --help                   Show this help message.

Examples:
  ./create-instance.sh --project-id 42 --environment p --service-code demo1 --profile-type linux --cpu 2 --ram 4 --disk 20 --image-index 3
  ./create-instance.sh --project-id 42 --environment d --service-code svc01 --profile-type win --image-alias ubuntu --description-suffix 'site-a'
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

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
[[ -f "${DNS_LIB_FILE}" ]] || fail "${DNS_LIB_FILE} not found."
# shellcheck source=/dev/null
source "${DNS_LIB_FILE}"

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
DESCRIPTION_SUFFIX_ARG=''
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
    --description-suffix)
      [[ $# -ge 2 ]] || fail 'missing value for --description-suffix.'
      DESCRIPTION_SUFFIX_ARG="$2"
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

require_cmd lxc
require_cmd jq
require_cmd python3
require_cmd curl

mapfile -t PROJECT_OPTIONS < <(
  lxc project list --format csv 2>/dev/null | while IFS=',' read -r PROJECT_NAME _ _ _ _ _ _ PROJECT_DESCRIPTION _; do
    [[ -n "${PROJECT_NAME}" ]] || continue
    if [[ "${PROJECT_DESCRIPTION}" =~ ^Project[[:space:]]ID:[[:space:]]([0-9]+)$ ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${PROJECT_NAME}"
    fi
  done
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
  read -r -p 'Profile type to use (linux or win): ' PROFILE_TYPE
fi
case "${PROFILE_TYPE}" in
  linux|Linux|l)
    PROFILE_NAME="${PROJECT_NAME}-linux"
    ;;
  win|Windows|w)
    PROFILE_NAME="${PROJECT_NAME}-win"
    ;;
  *)
    fail 'profile type must be linux or win.'
    ;;
esac

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."
lxc profile show "${PROFILE_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || fail "profile '${PROFILE_NAME}' does not exist in project '${PROJECT_NAME}'."
PROFILE_SHOW_FILE="$(mktemp)"
cleanup() {
  rm -f "${PROFILE_SHOW_FILE}" "${DESC_FILE}"
}
trap cleanup EXIT
lxc profile show "${PROFILE_NAME}" --project "${PROJECT_NAME}" > "${PROFILE_SHOW_FILE}"

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

lxc network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || fail "network '${NETWORK_NAME}' does not exist in project '${PROJECT_NAME}'."

NETWORK_IPV4_CIDR="$(lxc network get "${NETWORK_NAME}" ipv4.address --project "${PROJECT_NAME}" 2>/dev/null || true)"
[[ -n "${NETWORK_IPV4_CIDR}" ]] || fail "network '${NETWORK_NAME}' does not have an ipv4.address configured."
PROJECT_ID="$(awk -F '[./]' '{print $3}' <<< "${NETWORK_IPV4_CIDR}")"
[[ "${PROJECT_ID}" =~ ^[0-9]+$ ]] || fail "unable to determine project ID from network subnet '${NETWORK_IPV4_CIDR}'."
(( PROJECT_ID >= 1 && PROJECT_ID <= 255 )) || fail 'derived project ID must be between 1 and 255.'

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

case "${PROFILE_TYPE}" in
  linux|Linux|l)
    mapfile -t IMAGE_ROWS < <(lxc image list --project default --format json | jq -r '.[] | select(((.aliases | map(.name // "") | join(" ")) | test("win"; "i")) | not) | [(.aliases[0].name // "-"), .fingerprint[0:12], .type, .architecture, (.description // "")] | @tsv')
    ;;
  win|Windows|w)
    mapfile -t IMAGE_ROWS < <(lxc image list --project default --format json | jq -r '.[] | select((.aliases | map(.name // "") | join(" ")) | test("win"; "i")) | [(.aliases[0].name // "-"), .fingerprint[0:12], .type, .architecture, (.description // "")] | @tsv')
    ;;
  *)
    fail 'profile type must be linux or win.'
    ;;
esac
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
SELECTED_FP_FULL="$(lxc image list --project default --format json | jq -r --arg fp "${SELECTED_FP12}" '.[] | select(.fingerprint | startswith($fp)) | .fingerprint' | head -n1)"
[[ -n "${SELECTED_FP_FULL}" ]] || fail 'unable to resolve selected image fingerprint.'

case "${SELECTED_TYPE}" in
  virtual-machine) INSTANCE_TYPE='vs' ;;
  container) INSTANCE_TYPE='ct' ;;
  *) fail "unsupported selected image type '${SELECTED_TYPE}'." ;;
esac

NAME_PREFIX="${ENV_PREFIX}${PROJECT_ID_STR}-${SERVICE_CODE}-${INSTANCE_TYPE}"
mapfile -t EXISTING_MATCHES < <(lxc list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null | grep -E "^${NAME_PREFIX}[0-9]{2}$" || true)
NEXT_SEQ=1
if (( ${#EXISTING_MATCHES[@]} > 0 )); then
  LAST_SEQ="$(printf '%s\n' "${EXISTING_MATCHES[@]}" | sed -E 's/.*([0-9]{2})$/\1/' | sort -n | tail -n1)"
  NEXT_SEQ=$((10#${LAST_SEQ} + 1))
fi
(( NEXT_SEQ <= 99 )) || fail 'next sequence would exceed 99.'
INSTANCE_NAME="$(printf '%s%02d' "${NAME_PREFIX}" "${NEXT_SEQ}")"

LAUNCH_ARGS=(launch --project "${PROJECT_NAME}" --profile "${PROFILE_NAME}" "${SELECTED_FP_FULL}" "${INSTANCE_NAME}" -c limits.cpu="${CPU_CORES}" -c limits.memory="${RAM_GIB}GiB")
if [[ "${SELECTED_TYPE}" == 'virtual-machine' ]]; then
  LAUNCH_ARGS+=(--vm)
fi
LAUNCH_ARGS+=(-d root,size="${DISK_GIB}GiB")

echo "Creating instance '${INSTANCE_NAME}' from image ${SELECTED_ALIAS} (${SELECTED_FP12})..."
run lxc "${LAUNCH_ARGS[@]}"

echo 'Waiting for IPv4 address...'
INSTANCE_IPV4=''
for _ in $(seq 1 60); do
  INSTANCE_IPV4="$(lxc list "${INSTANCE_NAME}" --project "${PROJECT_NAME}" --format json | jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet" and .scope=="global") | .address' | head -n1)"
  if [[ -n "${INSTANCE_IPV4}" && "${INSTANCE_IPV4}" != 'null' ]]; then
    break
  fi
  sleep 2
done
[[ -n "${INSTANCE_IPV4}" && "${INSTANCE_IPV4}" != 'null' ]] || fail 'unable to determine instance IPv4 address after waiting.'

echo "Creating network forward on '${NETWORK_NAME}' to ${INSTANCE_IPV4}..."
run lxc network forward create "${NETWORK_NAME}" --project "${PROJECT_NAME}" --allocate=ipv4 target_address="${INSTANCE_IPV4}"
LISTEN_IPV4="$(lxc network forward list "${NETWORK_NAME}" --project "${PROJECT_NAME}" --format json | jq -r --arg target "${INSTANCE_IPV4}" '.[] | select(.config.target_address == $target) | .listen_address' | tail -n1)"
[[ -n "${LISTEN_IPV4}" && "${LISTEN_IPV4}" != 'null' ]] || fail 'unable to determine allocated forward listen IPv4 address.'

DNS_FQDN="${INSTANCE_NAME}.${TECHNITIUM_ZONE:-infnet}"
dns_register_record "${DNS_FQDN}" "${LISTEN_IPV4}" || true

if [[ -n "${DESCRIPTION_SUFFIX_ARG}" ]]; then
  DESCRIPTION_SUFFIX="${DESCRIPTION_SUFFIX_ARG}"
elif (( ARGS_PROVIDED == 0 )); then
  read -r -p 'Description suffix (optional): ' DESCRIPTION_SUFFIX
else
  DESCRIPTION_SUFFIX=''
fi
DESCRIPTION_TEXT="${LISTEN_IPV4} ${SELECTED_ALIAS}"
if [[ -n "${DESCRIPTION_SUFFIX}" ]]; then
  DESCRIPTION_TEXT="${DESCRIPTION_TEXT} ${DESCRIPTION_SUFFIX}"
fi
DESC_FILE="$(mktemp)"
lxc config show "${INSTANCE_NAME}" --project "${PROJECT_NAME}" > "${DESC_FILE}"
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
bash -c 'lxc config edit "$1" --project "$2" < "$3"' _ "${INSTANCE_NAME}" "${PROJECT_NAME}" "${DESC_FILE}" || fail "unable to update description field for '${INSTANCE_NAME}'."
run lxc config set "${INSTANCE_NAME}" user.network_forward_ipv4="${LISTEN_IPV4}" --project "${PROJECT_NAME}"

echo
echo 'Instance creation complete.'
echo "Name        : ${INSTANCE_NAME}"
echo "Project     : ${PROJECT_NAME}"
echo "Profile     : ${PROFILE_NAME}"
echo "Image       : ${SELECTED_ALIAS} (${SELECTED_FP12})"
echo "Type        : ${INSTANCE_TYPE}"
echo "Subnet      : ${NETWORK_IPV4_CIDR}"
echo "Project ID  : ${PROJECT_ID}"
echo "CPU         : ${CPU_CORES}"
echo "RAM         : ${RAM_GIB}GiB"
echo "Boot disk   : ${DISK_GIB}GiB"
echo "Instance IP : ${INSTANCE_IPV4}"
echo "Forward IP  : ${LISTEN_IPV4}"
echo "Description : ${DESCRIPTION_TEXT}"
if technitium_configured; then
  echo "DNS         : ${DNS_FQDN} -> ${LISTEN_IPV4}"
fi
