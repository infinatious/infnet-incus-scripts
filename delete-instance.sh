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
Usage: delete-instance.sh --project-id ID [--instance-index N | --instance-name NAME] [--yes]

Options:
  --project-id ID       Numeric project ID to select the project.
  --instance-index N    Numeric instance list index (1-based) to delete.
  --instance-name NAME  Exact instance name to delete.
  --yes                 Skip the confirmation prompt.
  --help                Show this help message.

Examples:
  ./delete-instance.sh --project-id 42 --instance-index 2 --yes
  ./delete-instance.sh --project-id 42 --instance-name p24-tstng-ct01 --yes
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

PROJECT_ID_ARG=''
INSTANCE_INDEX_ARG=''
INSTANCE_NAME_ARG=''
CONFIRM_ARG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      [[ $# -ge 2 ]] || fail 'missing value for --project-id.'
      PROJECT_ID_ARG="$2"
      shift 2
      ;;
    --instance-index)
      [[ $# -ge 2 ]] || fail 'missing value for --instance-index.'
      INSTANCE_INDEX_ARG="$2"
      shift 2
      ;;
    --instance-name)
      [[ $# -ge 2 ]] || fail 'missing value for --instance-name.'
      INSTANCE_NAME_ARG="$2"
      shift 2
      ;;
    --yes)
      CONFIRM_ARG='yes'
      shift
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
NETWORK_NAME="${PROJECT_NAME}"

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

mapfile -t INSTANCE_ROWS < <(lxc list --project "${PROJECT_NAME}" -c nds4 -f csv 2>/dev/null || true)
(( ${#INSTANCE_ROWS[@]} > 0 )) || fail "no instances found in project '${PROJECT_NAME}'."

echo 'Instances:'
for i in "${!INSTANCE_ROWS[@]}"; do
  IFS=',' read -r NAME DESCRIPTION STATE IPV4 <<< "${INSTANCE_ROWS[$i]}"
  printf '%2d) %-32s state=%-10s ipv4=%-15s desc=%s
' "$((i + 1))" "$NAME" "${STATE:-unknown}" "${IPV4:--}" "${DESCRIPTION:--}"
done

if [[ -n "${INSTANCE_NAME_ARG}" ]]; then
  SELECTED_ROW=''
  for INSTANCE_ROW in "${INSTANCE_ROWS[@]}"; do
    IFS=',' read -r NAME DESCRIPTION STATE IPV4 <<< "${INSTANCE_ROW}"
    if [[ "${NAME}" == "${INSTANCE_NAME_ARG}" ]]; then
      SELECTED_ROW="${INSTANCE_ROW}"
      break
    fi
  done
  [[ -n "${SELECTED_ROW}" ]] || fail "instance '${INSTANCE_NAME_ARG}' was not found in project '${PROJECT_NAME}'."
elif [[ -n "${INSTANCE_INDEX_ARG}" ]]; then
  INSTANCE_INDEX="${INSTANCE_INDEX_ARG}"
  [[ "${INSTANCE_INDEX}" =~ ^[0-9]+$ ]] || fail 'instance selection must be numeric.'
  (( INSTANCE_INDEX >= 1 && INSTANCE_INDEX <= ${#INSTANCE_ROWS[@]} )) || fail 'instance selection is out of range.'
  SELECTED_ROW="${INSTANCE_ROWS[$((INSTANCE_INDEX - 1))]}"
else
  read -r -p 'Enter instance number to delete: ' INSTANCE_INDEX
  [[ "${INSTANCE_INDEX}" =~ ^[0-9]+$ ]] || fail 'instance selection must be numeric.'
  (( INSTANCE_INDEX >= 1 && INSTANCE_INDEX <= ${#INSTANCE_ROWS[@]} )) || fail 'instance selection is out of range.'
  SELECTED_ROW="${INSTANCE_ROWS[$((INSTANCE_INDEX - 1))]}"
fi

IFS=',' read -r INSTANCE_NAME INSTANCE_DESCRIPTION INSTANCE_STATE INSTANCE_IPV4 <<< "${SELECTED_ROW}"
FORWARD_IP="$(lxc config get "${INSTANCE_NAME}" user.network_forward_ipv4 --project "${PROJECT_NAME}" 2>/dev/null || true)"

echo
echo 'Selected instance:'
echo "Name        : ${INSTANCE_NAME}"
echo "State       : ${INSTANCE_STATE:--}"
echo "IPv4        : ${INSTANCE_IPV4:--}"
echo "Description : ${INSTANCE_DESCRIPTION:--}"
if [[ -n "${FORWARD_IP}" ]]; then
  echo "Forward IP  : ${FORWARD_IP}"
fi

if [[ -n "${CONFIRM_ARG}" ]]; then
  CONFIRM='yes'
else
  read -r -p 'Are you sure you want to stop and delete this instance? Type yes to continue: ' CONFIRM
fi
[[ "${CONFIRM}" == 'yes' ]] || fail 'deletion cancelled.'

echo "Stopping instance '${INSTANCE_NAME}'..."
lxc stop "${INSTANCE_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || true

echo "Deleting instance '${INSTANCE_NAME}'..."
run lxc delete "${INSTANCE_NAME}" --project "${PROJECT_NAME}"

if [[ -n "${FORWARD_IP}" ]]; then
  echo "Deleting forward '${FORWARD_IP}' on network '${NETWORK_NAME}'..."
  run lxc network forward delete "${NETWORK_NAME}" "${FORWARD_IP}" --project "${PROJECT_NAME}"
  dns_deregister_record "${INSTANCE_NAME}.${TECHNITIUM_ZONE:-infnet}" "${FORWARD_IP}" || true
else
  echo "No stored forward IP found on instance '${INSTANCE_NAME}', skipping forward deletion."
fi

echo
echo 'Deletion complete.'
echo "Project    : ${PROJECT_NAME}"
echo "Instance   : ${INSTANCE_NAME}"
if [[ -n "${FORWARD_IP}" ]]; then
  echo "Forward IP : ${FORWARD_IP}"
fi
