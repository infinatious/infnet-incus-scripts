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
Usage: delete-project.sh --project-id ID [--delete-instances] [--yes]

Options:
  --project-id ID        Numeric project ID to select the project to delete.
  --delete-instances     Stop and delete every instance in the project before deleting the project.
  --yes                  Skip the confirmation prompt for the instance cleanup.
  --help                 Show this help message.

Examples:
  ./delete-project.sh --project-id 42
  ./delete-project.sh --project-id 42 --delete-instances --yes
EOF
}

run() {
  "$@" || fail "command failed: $*"
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DNS_LIB_FILE="${SCRIPT_DIR}/technitium-dns.sh"

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
[[ -f "${DNS_LIB_FILE}" ]] || fail "${DNS_LIB_FILE} not found."
# shellcheck source=/dev/null
source "${DNS_LIB_FILE}"

PROJECT_ID_ARG=''
DELETE_INSTANCES_ARG=''
CONFIRM_ARG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      [[ $# -ge 2 ]] || fail 'missing value for --project-id.'
      PROJECT_ID_ARG="$2"
      shift 2
      ;;
    --delete-instances)
      DELETE_INSTANCES_ARG='yes'
      shift
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

command -v lxc >/dev/null 2>&1 || fail 'lxc command not found in PATH.'
command -v jq >/dev/null 2>&1 || fail 'jq command not found in PATH.'
command -v curl >/dev/null 2>&1 || fail 'curl command not found in PATH.'

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

PROFILE_NAME="${PROJECT_NAME}"
NETWORK_NAME="${PROJECT_NAME}"

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

INSTANCE_LIST="$(lxc list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null || true)"
if [[ -n "${INSTANCE_LIST}" ]]; then
  if [[ "${DELETE_INSTANCES_ARG}" == 'yes' ]]; then
    if [[ "${CONFIRM_ARG}" != 'yes' ]]; then
      echo "Project '${PROJECT_NAME}' still has instances:" >&2
      printf '%s\n' "${INSTANCE_LIST}" >&2
      read -r -p 'Type yes to stop and delete all instances in this project before continuing: ' CONFIRM
      [[ "${CONFIRM}" == 'yes' ]] || fail 'project deletion cancelled.'
    fi

    while IFS= read -r INSTANCE_NAME; do
      [[ -n "${INSTANCE_NAME}" ]] || continue
      FORWARD_IP="$(lxc config get "${INSTANCE_NAME}" user.network_forward_ipv4 --project "${PROJECT_NAME}" 2>/dev/null || true)"
      echo "Stopping instance '${INSTANCE_NAME}'..."
      lxc stop "${INSTANCE_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || true
      echo "Deleting instance '${INSTANCE_NAME}'..."
      run lxc delete "${INSTANCE_NAME}" --project "${PROJECT_NAME}"
      if [[ -n "${FORWARD_IP}" ]]; then
        echo "Deleting forward '${FORWARD_IP}' on network '${NETWORK_NAME}'..."
        run lxc network forward delete "${NETWORK_NAME}" "${FORWARD_IP}" --project "${PROJECT_NAME}"
        dns_deregister_record "${INSTANCE_NAME}.${TECHNITIUM_ZONE:-infnet}" "${FORWARD_IP}" || true
      fi
    done < <(printf '%s\n' "${INSTANCE_LIST}" | sed '/^$/d')
  else
    echo "Project '${PROJECT_NAME}' still has instances:" >&2
    printf '%s\n' "${INSTANCE_LIST}" >&2
    echo 'Delete the instances first, then re-run this script.' >&2
    exit 1
  fi
fi

mapfile -t PROFILE_NAMES < <(lxc profile list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null || true)
if (( ${#PROFILE_NAMES[@]} > 0 )); then
  for PROFILE_NAME in "${PROFILE_NAMES[@]}"; do
    if [[ "${PROFILE_NAME}" == 'default' ]]; then
      echo "Skipping built-in profile '${PROFILE_NAME}'."
      continue
    fi
    echo "Deleting profile '${PROFILE_NAME}'..."
    run lxc profile delete "${PROFILE_NAME}" --project "${PROJECT_NAME}"
  done
else
  echo "No project profiles found, skipping."
fi

if lxc network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
  echo "Deleting network '${NETWORK_NAME}'..."
  run lxc network delete "${NETWORK_NAME}" --project "${PROJECT_NAME}"
else
  echo "Network '${NETWORK_NAME}' not found, skipping."
fi

echo "Deleting project '${PROJECT_NAME}'..."
run lxc project delete "${PROJECT_NAME}"

echo
echo 'Deletion complete.'
echo "Project : ${PROJECT_NAME}"
