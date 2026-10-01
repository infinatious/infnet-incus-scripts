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
DNS_LIB_FILE="${SCRIPT_DIR}/dns/technitium-dns.sh"

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
[[ -f "${DNS_LIB_FILE}" ]] || fail "${DNS_LIB_FILE} not found."
# shellcheck source=/dev/null
source "${DNS_LIB_FILE}"
[[ -f "${SCRIPT_DIR}/lib/public-ip.sh" ]] || fail "${SCRIPT_DIR}/lib/public-ip.sh not found."
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/public-ip.sh"
[[ -f "${SCRIPT_DIR}/lib/firewall.sh" ]] || fail "${SCRIPT_DIR}/lib/firewall.sh not found."
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/firewall.sh"

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

command -v incus >/dev/null 2>&1 || fail 'incus command not found in PATH.'
command -v jq >/dev/null 2>&1 || fail 'jq command not found in PATH.'
command -v curl >/dev/null 2>&1 || fail 'curl command not found in PATH.'

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

PROFILE_NAME="${PROJECT_NAME}"
NETWORK_NAME="${PROJECT_NAME}"

incus project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

INSTANCE_LIST="$(incus list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null || true)"
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
      PUBLIC_IP="$(nat_instance_address "${INSTANCE_NAME}" "${PROJECT_NAME}")"
      echo "Stopping instance '${INSTANCE_NAME}'..."
      # Force after a minute: a guest can ignore the shutdown request forever.
      incus stop "${INSTANCE_NAME}" --timeout 60 --project "${PROJECT_NAME}" >/dev/null 2>&1 \
        || incus stop "${INSTANCE_NAME}" --force --project "${PROJECT_NAME}" >/dev/null 2>&1 || true
      echo "Deleting instance '${INSTANCE_NAME}'..."
      run incus delete "${INSTANCE_NAME}" --project "${PROJECT_NAME}"
      if [[ -n "${PUBLIC_IP}" ]]; then
        echo "Releasing public IP '${PUBLIC_IP}' (network forward on '${NETWORK_NAME}')..."
        run nat_release "${PROJECT_NAME}" "${NETWORK_NAME}" "${PUBLIC_IP}"
      fi
      dns_deregister_instance "${INSTANCE_NAME}" "${PROJECT_NAME}" "${PUBLIC_IP}" || true
      run fw_delete_acl "${INSTANCE_NAME}" "${PROJECT_NAME}"
    done < <(printf '%s\n' "${INSTANCE_LIST}" | sed '/^$/d')
  else
    echo "Project '${PROJECT_NAME}' still has instances:" >&2
    printf '%s\n' "${INSTANCE_LIST}" >&2
    echo 'Delete the instances first, then re-run this script.' >&2
    exit 1
  fi
fi

mapfile -t PROFILE_NAMES < <(incus profile list --project "${PROJECT_NAME}" --format csv -c n 2>/dev/null || true)
if (( ${#PROFILE_NAMES[@]} > 0 )); then
  for PROFILE_NAME in "${PROFILE_NAMES[@]}"; do
    if [[ "${PROFILE_NAME}" == 'default' ]]; then
      echo "Skipping built-in profile '${PROFILE_NAME}'."
      continue
    fi
    echo "Deleting profile '${PROFILE_NAME}'..."
    run incus profile delete "${PROFILE_NAME}" --project "${PROJECT_NAME}"
  done
else
  echo "No project profiles found, skipping."
fi

# Any ACLs left over (e.g. created by hand) would block deleting the project.
mapfile -t ACL_NAMES < <(incus network acl list --project "${PROJECT_NAME}" -f json 2>/dev/null | jq -r '.[].name')
for ACL_NAME in "${ACL_NAMES[@]}"; do
  [[ -n "${ACL_NAME}" ]] || continue
  echo "Deleting network ACL '${ACL_NAME}'..."
  run incus network acl delete "${ACL_NAME}" --project "${PROJECT_NAME}"
done

if incus network show "${NETWORK_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
  GATEWAY_IPV4="$(incus network get "${NETWORK_NAME}" ipv4.address --project "${PROJECT_NAME}" 2>/dev/null)"
  if [[ -n "${GATEWAY_IPV4}" && "${GATEWAY_IPV4}" != 'none' ]]; then
    dns_deregister_project "${PROJECT_NAME}" "${GATEWAY_IPV4%/*}" || true
  fi
  echo "Deleting network '${NETWORK_NAME}'..."
  run incus network delete "${NETWORK_NAME}" --project "${PROJECT_NAME}"
else
  echo "Network '${NETWORK_NAME}' not found, skipping."
fi

echo "Deleting project '${PROJECT_NAME}'..."
run incus project delete "${PROJECT_NAME}"

echo
echo 'Deletion complete.'
echo "Project : ${PROJECT_NAME}"
