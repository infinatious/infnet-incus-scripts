#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: restore-instance.sh --project-id ID --instance-name NAME [--backup-index N | --backup-file PATH] [--new-name NAME] [--yes]

Restores an instance from a backup written by backup-instances.sh. The
restored instance is created in the same project it was backed up from,
under its original name unless --new-name is given.

If the backed-up instance had a 1:1 NAT public IP, its network forward is
recreated before the import (Incus refuses the import otherwise). The restore
is refused while another instance still owns that public IP, since a second
copy would share the original's NAT identity - delete the original first.

Options:
  --project-id ID       Numeric project ID that owns the backup.
  --instance-name NAME  Original instance name; used to locate its backups.
  --backup-index N      Numeric backup list index (1-based, newest first) to restore.
  --backup-file PATH    Exact backup tarball to restore, instead of browsing.
  --new-name NAME        Name for the restored instance (default: original name).
  --yes                  Skip the confirmation prompt.
  --help                 Show this help message.

Examples:
  ./restore-instance.sh --project-id 42 --instance-name p42-tstng-ct01
  ./restore-instance.sh --project-id 42 --instance-name p42-tstng-ct01 --backup-index 1 --new-name p42-tstng-ct02 --yes
EOF
}

run() {
  "$@" || fail "command failed: $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' not found in PATH."
}

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
: "${NFS_BACKUP_DIR:?NFS_BACKUP_DIR not set in ${ENV_FILE}}"
[[ -f "${ROOT_DIR}/lib/public-ip.sh" ]] || fail "${ROOT_DIR}/lib/public-ip.sh not found."
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/public-ip.sh"

PROJECT_ID_ARG=''
INSTANCE_NAME_ARG=''
BACKUP_INDEX_ARG=''
BACKUP_FILE_ARG=''
NEW_NAME_ARG=''
CONFIRM_ARG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      [[ $# -ge 2 ]] || fail 'missing value for --project-id.'
      PROJECT_ID_ARG="$2"
      shift 2
      ;;
    --instance-name)
      [[ $# -ge 2 ]] || fail 'missing value for --instance-name.'
      INSTANCE_NAME_ARG="$2"
      shift 2
      ;;
    --backup-index)
      [[ $# -ge 2 ]] || fail 'missing value for --backup-index.'
      BACKUP_INDEX_ARG="$2"
      shift 2
      ;;
    --backup-file)
      [[ $# -ge 2 ]] || fail 'missing value for --backup-file.'
      BACKUP_FILE_ARG="$2"
      shift 2
      ;;
    --new-name)
      [[ $# -ge 2 ]] || fail 'missing value for --new-name.'
      NEW_NAME_ARG="$2"
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

require_cmd incus
require_cmd jq
require_cmd python3
require_cmd tar

mountpoint -q "${NFS_BACKUP_DIR}" || fail "'${NFS_BACKUP_DIR}' is not a mounted filesystem."

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

incus project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

if [[ -n "${BACKUP_FILE_ARG}" ]]; then
  BACKUP_FILE="${BACKUP_FILE_ARG}"
  [[ -f "${BACKUP_FILE}" ]] || fail "backup file '${BACKUP_FILE}' does not exist."
  INSTANCE_NAME="${INSTANCE_NAME_ARG}"
  [[ -n "${INSTANCE_NAME}" ]] || fail '--instance-name is required to name the restored instance when using --backup-file.'
else
  if [[ -n "${INSTANCE_NAME_ARG}" ]]; then
    INSTANCE_NAME="${INSTANCE_NAME_ARG}"
  else
    mapfile -t AVAILABLE_INSTANCE_DIRS < <(find "${NFS_BACKUP_DIR}/${PROJECT_NAME}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    (( ${#AVAILABLE_INSTANCE_DIRS[@]} > 0 )) || fail "no backups found for project '${PROJECT_NAME}' in '${NFS_BACKUP_DIR}/${PROJECT_NAME}'."
    echo "Instances with backups in project '${PROJECT_NAME}':"
    for INSTANCE_DIR in "${AVAILABLE_INSTANCE_DIRS[@]}"; do
      echo "  - $(basename -- "${INSTANCE_DIR}")"
    done
    read -r -p 'Enter instance name to restore: ' INSTANCE_NAME
  fi
  [[ -n "${INSTANCE_NAME}" ]] || fail 'instance name must not be empty.'

  INSTANCE_BACKUP_DIR="${NFS_BACKUP_DIR}/${PROJECT_NAME}/${INSTANCE_NAME}"
  [[ -d "${INSTANCE_BACKUP_DIR}" ]] || fail "no backups found for instance '${INSTANCE_NAME}' in '${INSTANCE_BACKUP_DIR}'."

  mapfile -t BACKUP_FILES < <(find "${INSTANCE_BACKUP_DIR}" -maxdepth 1 -type f -name "${INSTANCE_NAME}_*.tar.gz" 2>/dev/null | sort -r)
  (( ${#BACKUP_FILES[@]} > 0 )) || fail "no backup files found for instance '${INSTANCE_NAME}' in '${INSTANCE_BACKUP_DIR}'."

  echo "Backups for '${INSTANCE_NAME}' (newest first):"
  for i in "${!BACKUP_FILES[@]}"; do
    printf '%2d) %s\n' "$((i + 1))" "$(basename -- "${BACKUP_FILES[$i]}")"
  done

  if [[ -n "${BACKUP_INDEX_ARG}" ]]; then
    BACKUP_INDEX="${BACKUP_INDEX_ARG}"
  else
    read -r -p 'Enter backup number to restore: ' BACKUP_INDEX
  fi
  [[ "${BACKUP_INDEX}" =~ ^[0-9]+$ ]] || fail 'backup selection must be numeric.'
  (( BACKUP_INDEX >= 1 && BACKUP_INDEX <= ${#BACKUP_FILES[@]} )) || fail 'backup selection is out of range.'
  BACKUP_FILE="${BACKUP_FILES[$((BACKUP_INDEX - 1))]}"
fi

TARGET_NAME="${NEW_NAME_ARG:-${INSTANCE_NAME}}"

incus info "${TARGET_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 && \
  fail "instance '${TARGET_NAME}' already exists in project '${PROJECT_NAME}'. Use --new-name or delete the existing instance first."

# The instance's 1:1 NAT lives in its NIC config (ipv4.address.external),
# which Incus only accepts when a matching network forward exists.
NAT_INFO="$(tar -xOf "${BACKUP_FILE}" --occurrence=1 backup/index.yaml 2>/dev/null | python3 -c '
import sys, yaml
def walk(node):
    if isinstance(node, dict):
        if node.get("ipv4.address.external"):
            yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)
try:
    data = yaml.safe_load(sys.stdin) or {}
except yaml.YAMLError:
    sys.exit(0)
for nic in walk(data):
    print("\t".join([nic["ipv4.address.external"], nic.get("ipv4.address", ""), nic.get("network", "")]))
    break
')"
NAT_PUBLIC=''
NAT_FORWARD_CREATED=''
if [[ -n "${NAT_INFO}" ]]; then
  IFS=$'\t' read -r NAT_PUBLIC NAT_INTERNAL NAT_NETWORK <<< "${NAT_INFO}"
  [[ -n "${NAT_INTERNAL}" && -n "${NAT_NETWORK}" ]] || fail "backup has public IP ${NAT_PUBLIC} but no pinned internal address or network; restore it manually."
  incus network show "${NAT_NETWORK}" --project "${PROJECT_NAME}" >/dev/null 2>&1 \
    || fail "network '${NAT_NETWORK}' from the backup does not exist in project '${PROJECT_NAME}'."
  if incus network forward show "${NAT_NETWORK}" "${NAT_PUBLIC}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
    NAT_OWNER="$(nat_find_owner "${PROJECT_NAME}" "${NAT_PUBLIC}")"
    [[ -z "${NAT_OWNER}" ]] || fail "public IP ${NAT_PUBLIC} still belongs to '${NAT_OWNER}'. Delete that instance first; a restored copy would share its 1:1 NAT identity."
  else
    nat_validate_address "$(nat_network_uplink "${NAT_NETWORK}" "${PROJECT_NAME}")" "${NAT_PUBLIC}" || exit 1
    NAT_FORWARD_CREATED='pending'
  fi
fi

echo
echo 'Ready to restore:'
echo "Project           : ${PROJECT_NAME}"
echo "Backup file        : ${BACKUP_FILE}"
echo "Restored as        : ${TARGET_NAME}"
if [[ -n "${NAT_PUBLIC}" ]]; then
  echo "Public IP          : ${NAT_PUBLIC} -> ${NAT_INTERNAL} (1:1 NAT on '${NAT_NETWORK}')"
fi

if [[ -n "${CONFIRM_ARG}" ]]; then
  CONFIRM='yes'
else
  read -r -p 'Type yes to restore this instance: ' CONFIRM
fi
[[ "${CONFIRM}" == 'yes' ]] || fail 'restore cancelled.'

if [[ -n "${NAT_PUBLIC}" ]]; then
  if [[ "${NAT_FORWARD_CREATED}" == 'pending' ]]; then
    echo "Recreating network forward ${NAT_PUBLIC} -> ${NAT_INTERNAL}..."
    run incus network forward create "${NAT_NETWORK}" "${NAT_PUBLIC}" target_address="${NAT_INTERNAL}" --project "${PROJECT_NAME}"
    NAT_FORWARD_CREATED='yes'
  else
    echo "Reusing existing network forward ${NAT_PUBLIC}, pointing it at ${NAT_INTERNAL}..."
    run incus network forward set "${NAT_NETWORK}" "${NAT_PUBLIC}" target_address="${NAT_INTERNAL}" --project "${PROJECT_NAME}"
  fi
fi

echo "Importing '${BACKUP_FILE}' as '${TARGET_NAME}' into project '${PROJECT_NAME}'..."
if ! incus import "${BACKUP_FILE}" "${TARGET_NAME}" --project "${PROJECT_NAME}"; then
  if [[ "${NAT_FORWARD_CREATED}" == 'yes' ]]; then
    incus network forward delete "${NAT_NETWORK}" "${NAT_PUBLIC}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || true
  fi
  fail "command failed: incus import ${BACKUP_FILE} ${TARGET_NAME} --project ${PROJECT_NAME}"
fi
[[ -z "${NAT_PUBLIC}" ]] || run incus config set "${TARGET_NAME}" "${PUBLIC_IP_CONFIG_KEY}=${NAT_PUBLIC}" --project "${PROJECT_NAME}"

echo
echo 'Restore complete.'
echo "Project  : ${PROJECT_NAME}"
echo "Instance : ${TARGET_NAME}"
echo
echo "The instance was imported stopped. Start it with:"
echo "  incus start ${TARGET_NAME} --project ${PROJECT_NAME}"
if [[ -n "${NAT_PUBLIC}" ]]; then
  echo "Its 1:1 NAT (${NAT_PUBLIC}) is in place. DNS records were not touched; run dns/sync-dns-records.sh if needed."
fi
