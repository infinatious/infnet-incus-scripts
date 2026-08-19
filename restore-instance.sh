#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

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

require_cmd lxc

mountpoint -q "${NFS_BACKUP_DIR}" || fail "'${NFS_BACKUP_DIR}' is not a mounted filesystem."

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

lxc project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

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

lxc info "${TARGET_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1 && \
  fail "instance '${TARGET_NAME}' already exists in project '${PROJECT_NAME}'. Use --new-name or delete the existing instance first."

echo
echo 'Ready to restore:'
echo "Project           : ${PROJECT_NAME}"
echo "Backup file        : ${BACKUP_FILE}"
echo "Restored as        : ${TARGET_NAME}"

if [[ -n "${CONFIRM_ARG}" ]]; then
  CONFIRM='yes'
else
  read -r -p 'Type yes to restore this instance: ' CONFIRM
fi
[[ "${CONFIRM}" == 'yes' ]] || fail 'restore cancelled.'

echo "Importing '${BACKUP_FILE}' as '${TARGET_NAME}' into project '${PROJECT_NAME}'..."
run lxc import "${BACKUP_FILE}" "${TARGET_NAME}" --project "${PROJECT_NAME}"

echo
echo 'Restore complete.'
echo "Project  : ${PROJECT_NAME}"
echo "Instance : ${TARGET_NAME}"
echo
echo "The instance was imported stopped. Start it with:"
echo "  lxc start ${TARGET_NAME} --project ${PROJECT_NAME}"
echo 'If the original instance had a network forward, recreate it manually with `lxc network forward create` once the restored instance has an address.'
