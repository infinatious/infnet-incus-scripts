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
Usage: backup-instances.sh [--retention-days N] [--dry-run]

Exports every instance located on this cluster member to the NFS backup
directory configured in .env, then prunes backups older than the retention
window. Intended to run unattended and identically on every node in the
cluster (e.g. from microcloud-backup.timer) - each node only backs up the
instances currently running on itself.

Options:
  --retention-days N   Override BACKUP_RETENTION_DAYS from .env for this run.
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --retention-days)
      [[ $# -ge 2 ]] || fail 'missing value for --retention-days.'
      RETENTION_DAYS_ARG="$2"
      shift 2
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
      rm -f "${OLD_FILE}"
    fi
  done
}

echo "Backing up instances located on cluster member '${LOCAL_MEMBER}' (retention: ${RETENTION_DAYS}d)..."

mapfile -t PROJECT_NAMES < <(lxc project list --format csv -c n 2>/dev/null || true)
(( ${#PROJECT_NAMES[@]} > 0 )) || fail 'no projects found.'

BACKED_UP=0
for PROJECT_NAME in "${PROJECT_NAMES[@]}"; do
  [[ -n "${PROJECT_NAME}" ]] || continue

  mapfile -t INSTANCE_ROWS < <(lxc list --project "${PROJECT_NAME}" -c nL -f csv 2>/dev/null || true)
  (( ${#INSTANCE_ROWS[@]} > 0 )) || continue

  for INSTANCE_ROW in "${INSTANCE_ROWS[@]}"; do
    [[ -n "${INSTANCE_ROW}" ]] || continue
    IFS=',' read -r INSTANCE_NAME INSTANCE_LOCATION <<< "${INSTANCE_ROW}"
    [[ "${INSTANCE_LOCATION}" == "${LOCAL_MEMBER}" ]] || continue

    INSTANCE_DIR="${NFS_BACKUP_DIR}/${PROJECT_NAME}/${INSTANCE_NAME}"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_FILE="${INSTANCE_DIR}/${INSTANCE_NAME}_${TIMESTAMP}.tar.gz"

    if [[ "${DRY_RUN}" == 'yes' ]]; then
      echo "[dry-run] would back up '${INSTANCE_NAME}' (project '${PROJECT_NAME}') to '${BACKUP_FILE}'"
    else
      mkdir -p "${INSTANCE_DIR}" || fail "unable to create '${INSTANCE_DIR}'."
      echo "Backing up '${INSTANCE_NAME}' (project '${PROJECT_NAME}') to '${BACKUP_FILE}'..."
      run lxc export "${INSTANCE_NAME}" "${BACKUP_FILE}" --project "${PROJECT_NAME}" --optimized-storage --compression gzip
      BACKED_UP=$((BACKED_UP + 1))
    fi

    prune_old_backups "${INSTANCE_DIR}" "${INSTANCE_NAME}"
  done
done

echo
if [[ "${DRY_RUN}" == 'yes' ]]; then
  echo 'Dry run complete. No backups were written or pruned.'
else
  echo "Backup complete. ${BACKED_UP} instance(s) backed up on '${LOCAL_MEMBER}'."
fi
