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
Usage: backup-instances.sh [--retention-days N] [--project NAME] [--instance NAME]
                           [--tag TAG] [--description TEXT] [--no-prune] [--dry-run]

Exports every instance located on this cluster member to the NFS backup
directory configured in .env, then prunes backups older than the retention
window. Intended to run unattended and identically on every node in the
cluster (e.g. from microcloud-backup.timer) - each node only backs up the
instances currently running on itself.

Options:
  --retention-days N   Override BACKUP_RETENTION_DAYS from .env for this run.
  --project NAME       Only back up instances in this project.
  --instance NAME      Only back up this instance (combine with --project).
  --tag TAG            Tag the backup (e.g. adhoc). Lowercase letters, digits
                       and dashes. Appended to the file name as
                       <instance>_<timestamp>_<tag>.tar.gz.
  --description TEXT   Free-text description stored in the backup's .json
                       metadata sidecar.
  --no-prune           Skip retention pruning for this run.
  --dry-run             Show what would be backed up and pruned without doing it.
  --help                Show this help message.
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
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

RETENTION_DAYS_ARG=''
DRY_RUN=''
PROJECT_FILTER=''
INSTANCE_FILTER=''
BACKUP_TAG=''
BACKUP_DESCRIPTION=''
NO_PRUNE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --retention-days)
      [[ $# -ge 2 ]] || fail 'missing value for --retention-days.'
      RETENTION_DAYS_ARG="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || fail 'missing value for --project.'
      PROJECT_FILTER="$2"
      shift 2
      ;;
    --instance)
      [[ $# -ge 2 ]] || fail 'missing value for --instance.'
      INSTANCE_FILTER="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || fail 'missing value for --tag.'
      BACKUP_TAG="$2"
      shift 2
      ;;
    --description)
      [[ $# -ge 2 ]] || fail 'missing value for --description.'
      BACKUP_DESCRIPTION="$2"
      shift 2
      ;;
    --no-prune)
      NO_PRUNE='yes'
      shift
      ;;
    --dry-run)
      DRY_RUN='yes'
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
[[ -n "${RETENTION_DAYS_ARG}" ]] && RETENTION_DAYS="${RETENTION_DAYS_ARG}"
[[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] || fail 'retention days must be numeric.'
[[ -z "${BACKUP_TAG}" || "${BACKUP_TAG}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || fail 'tag must be 1-32 lowercase letters, digits or dashes.'
(( ${#BACKUP_DESCRIPTION} <= 500 )) || fail 'description must be 500 characters or fewer.'

require_cmd lxc
require_cmd jq

mountpoint -q "${NFS_BACKUP_DIR}" || fail "'${NFS_BACKUP_DIR}' is not a mounted filesystem. Refusing to write backups to local disk."

LOCAL_MEMBER="$(lxc query /1.0 2>/dev/null | jq -r '.environment.server_name // empty')"
[[ -n "${LOCAL_MEMBER}" ]] || fail 'unable to determine local cluster member name via lxc query /1.0.'

prune_old_backups() {
  local instance_dir="$1" instance_name="$2"
  [[ -d "${instance_dir}" ]] || return 0
  mapfile -t OLD_FILES < <(find "${instance_dir}" -maxdepth 1 -type f -name "${instance_name}_*.tar.gz" -mtime "+${RETENTION_DAYS}" 2>/dev/null)
  (( ${#OLD_FILES[@]} > 0 )) || return 0
  for OLD_FILE in "${OLD_FILES[@]}"; do
    if [[ "${DRY_RUN}" == 'yes' ]]; then
      echo "[dry-run] would prune '${OLD_FILE}'"
    else
      echo "Pruning old backup '${OLD_FILE}'..."
      rm -f "${OLD_FILE}" "${OLD_FILE}.json"
    fi
  done
}

write_metadata() {
  local backup_file="$1" project_name="$2" instance_name="$3"
  jq -n \
    --arg project "${project_name}" \
    --arg instance "${instance_name}" \
    --arg member "${LOCAL_MEMBER}" \
    --arg tag "${BACKUP_TAG}" \
    --arg description "${BACKUP_DESCRIPTION}" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson size "$(stat -c %s "${backup_file}")" \
    '{project: $project, instance: $instance, member: $member, tag: $tag, description: $description, created_at: $created_at, size_bytes: $size}' \
    > "${backup_file}.json" || echo "Warning: unable to write metadata sidecar for '${backup_file}'." >&2
}

if [[ "${NO_PRUNE}" == 'yes' ]]; then
  echo "Backing up instances located on cluster member '${LOCAL_MEMBER}' (pruning disabled)..."
else
  echo "Backing up instances located on cluster member '${LOCAL_MEMBER}' (retention: ${RETENTION_DAYS}d)..."
fi

if [[ -n "${PROJECT_FILTER}" ]]; then
  lxc project show "${PROJECT_FILTER}" >/dev/null 2>&1 || fail "project '${PROJECT_FILTER}' does not exist."
  PROJECT_NAMES=("${PROJECT_FILTER}")
else
  mapfile -t PROJECT_NAMES < <(lxc project list --format csv 2>/dev/null | cut -d',' -f1 | sed 's/ (current)$//' || true)
fi
(( ${#PROJECT_NAMES[@]} > 0 )) || fail 'no projects found.'

BACKED_UP=0
MATCHED=0
for PROJECT_NAME in "${PROJECT_NAMES[@]}"; do
  [[ -n "${PROJECT_NAME}" ]] || continue

  mapfile -t INSTANCE_ROWS < <(lxc list --project "${PROJECT_NAME}" -c nL -f csv 2>/dev/null || true)
  (( ${#INSTANCE_ROWS[@]} > 0 )) || continue

  for INSTANCE_ROW in "${INSTANCE_ROWS[@]}"; do
    [[ -n "${INSTANCE_ROW}" ]] || continue
    IFS=',' read -r INSTANCE_NAME INSTANCE_LOCATION <<< "${INSTANCE_ROW}"
    [[ -z "${INSTANCE_FILTER}" || "${INSTANCE_NAME}" == "${INSTANCE_FILTER}" ]] || continue
    if [[ "${INSTANCE_LOCATION}" != "${LOCAL_MEMBER}" ]]; then
      [[ -n "${INSTANCE_FILTER}" ]] && echo "Skipping '${INSTANCE_NAME}': located on '${INSTANCE_LOCATION}', not '${LOCAL_MEMBER}'."
      continue
    fi

    MATCHED=$((MATCHED + 1))
    INSTANCE_DIR="${NFS_BACKUP_DIR}/${PROJECT_NAME}/${INSTANCE_NAME}"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_FILE="${INSTANCE_DIR}/${INSTANCE_NAME}_${TIMESTAMP}${BACKUP_TAG:+_${BACKUP_TAG}}.tar.gz"

    if [[ "${DRY_RUN}" == 'yes' ]]; then
      echo "[dry-run] would back up '${INSTANCE_NAME}' (project '${PROJECT_NAME}') to '${BACKUP_FILE}'"
    else
      mkdir -p "${INSTANCE_DIR}" || fail "unable to create '${INSTANCE_DIR}'."
      echo "Backing up '${INSTANCE_NAME}' (project '${PROJECT_NAME}') to '${BACKUP_FILE}'..."
      run lxc export "${INSTANCE_NAME}" "${BACKUP_FILE}" --project "${PROJECT_NAME}" --optimized-storage --compression gzip
      write_metadata "${BACKUP_FILE}" "${PROJECT_NAME}" "${INSTANCE_NAME}"
      BACKED_UP=$((BACKED_UP + 1))
    fi

    [[ "${NO_PRUNE}" == 'yes' ]] || prune_old_backups "${INSTANCE_DIR}" "${INSTANCE_NAME}"
  done
done

if [[ -n "${INSTANCE_FILTER}" ]] && (( MATCHED == 0 )); then
  fail "instance '${INSTANCE_FILTER}' was not found on cluster member '${LOCAL_MEMBER}'."
fi

echo
if [[ "${DRY_RUN}" == 'yes' ]]; then
  echo 'Dry run complete. No backups were written or pruned.'
else
  echo "Backup complete. ${BACKED_UP} instance(s) backed up on '${LOCAL_MEMBER}'."
fi
