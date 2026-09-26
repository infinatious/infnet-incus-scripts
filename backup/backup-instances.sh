#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

LAST_ERROR=''
fail() {
  LAST_ERROR="$*"
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: backup-instances.sh [--retention-days N] [--weekly-weeks N]
                           [--retention-months N] [--all-members | --member NAME]
                           [--project NAME] [--instance NAME] [--tag TAG]
                           [--description TEXT] [--requested-by NAME]
                           [--no-prune] [--dry-run]

Exports instances to the NFS backup directory configured in .env, then prunes
backups on a tiered retention schedule: every backup is kept for the first
--retention-days days (daily tier); for the following --weekly-weeks weeks,
only the newest backup in each 7-day window survives (weekly tier); beyond
that, only the newest backup in each ~30-day window survives, up to a total
age of --retention-months months from today (monthly tier). Anything older
than that total window is deleted outright.

By default only instances located on the cluster member this lxc client talks
to are backed up, so the script can run unattended and identically on every
node (e.g. from microcloud-backup.timer). From a machine outside the cluster
(such as the MicroCloud Vault VM) use --all-members to back up every instance
through the LXD API.

Every non-dry run writes a JSON run record to <NFS_BACKUP_DIR>/.runs/ and a
<backup>.tar.gz.json metadata sidecar next to each backup.

Options:
  --retention-days N    Override BACKUP_RETENTION_DAYS (default 7): length of
                        the daily tier, in days.
  --weekly-weeks N      Override BACKUP_WEEKLY_RETENTION_WEEKS (default 3):
                        number of weekly buckets after the daily tier.
  --retention-months N  Override BACKUP_RETENTION_MONTHS (default 6): total
                        age, in months, after which a backup is deleted
                        outright regardless of tier.
  --all-members         Back up instances on every cluster member.
  --member NAME         Only back up instances located on this cluster member.
  --project NAME        Only back up instances in this project.
  --instance NAME       Only back up this instance (combine with --project).
  --tag TAG             Tag the backup (e.g. adhoc). Lowercase letters, digits
                        and dashes. Appended to the file name as
                        <instance>_<timestamp>_<tag>.tar.gz.
  --description TEXT    Free-text description stored in the metadata sidecar.
  --requested-by NAME   Who asked for this run (stored in metadata/run record).
  --no-prune            Skip retention pruning for this run.
  --dry-run             Show what would be backed up and pruned without doing it.
  --help                Show this help message.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' not found in PATH."
}

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
: "${NFS_BACKUP_DIR:?NFS_BACKUP_DIR not set in ${ENV_FILE}}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
WEEKLY_WEEKS="${BACKUP_WEEKLY_RETENTION_WEEKS:-3}"
RETENTION_MONTHS="${BACKUP_RETENTION_MONTHS:-6}"
RUN_HISTORY_DAYS="${BACKUP_RUN_HISTORY_DAYS:-90}"

RETENTION_DAYS_ARG=''
WEEKLY_WEEKS_ARG=''
RETENTION_MONTHS_ARG=''
DRY_RUN=''
ALL_MEMBERS=''
MEMBER_FILTER=''
PROJECT_FILTER=''
INSTANCE_FILTER=''
BACKUP_TAG=''
BACKUP_DESCRIPTION=''
REQUESTED_BY=''
NO_PRUNE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --retention-days)
      [[ $# -ge 2 ]] || fail 'missing value for --retention-days.'
      RETENTION_DAYS_ARG="$2"
      shift 2
      ;;
    --weekly-weeks)
      [[ $# -ge 2 ]] || fail 'missing value for --weekly-weeks.'
      WEEKLY_WEEKS_ARG="$2"
      shift 2
      ;;
    --retention-months)
      [[ $# -ge 2 ]] || fail 'missing value for --retention-months.'
      RETENTION_MONTHS_ARG="$2"
      shift 2
      ;;
    --all-members)
      ALL_MEMBERS='yes'
      shift
      ;;
    --member)
      [[ $# -ge 2 ]] || fail 'missing value for --member.'
      MEMBER_FILTER="$2"
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
    --requested-by)
      [[ $# -ge 2 ]] || fail 'missing value for --requested-by.'
      REQUESTED_BY="$2"
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
[[ -n "${WEEKLY_WEEKS_ARG}" ]] && WEEKLY_WEEKS="${WEEKLY_WEEKS_ARG}"
[[ -n "${RETENTION_MONTHS_ARG}" ]] && RETENTION_MONTHS="${RETENTION_MONTHS_ARG}"
[[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] || fail 'retention days must be numeric.'
[[ "${WEEKLY_WEEKS}" =~ ^[0-9]+$ ]] || fail 'weekly retention weeks must be numeric.'
[[ "${RETENTION_MONTHS}" =~ ^[0-9]+$ ]] || fail 'retention months must be numeric.'
[[ "${RUN_HISTORY_DAYS}" =~ ^[0-9]+$ ]] || fail 'BACKUP_RUN_HISTORY_DAYS must be numeric.'
# Tiered retention: every backup is kept for RETENTION_DAYS days (daily tier);
# for the following WEEKLY_WEEKS weeks, only the newest backup in each 7-day
# bucket survives (weekly tier); beyond that, only the newest backup in each
# ~30-day bucket survives, up to a total age of RETENTION_MONTHS months from
# today (monthly tier). WEEKLY_END_DAYS and MONTHLY_TOTAL_DAYS are the day-age
# boundaries between those tiers, used by prune_old_backups below.
WEEKLY_END_DAYS=$(( RETENTION_DAYS + WEEKLY_WEEKS * 7 ))
MONTHLY_TOTAL_DAYS=$(( RETENTION_MONTHS * 30 ))
(( MONTHLY_TOTAL_DAYS >= WEEKLY_END_DAYS )) || fail 'BACKUP_RETENTION_MONTHS must cover at least the daily + weekly window.'
[[ -z "${BACKUP_TAG}" || "${BACKUP_TAG}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || fail 'tag must be 1-32 lowercase letters, digits or dashes.'
[[ -z "${MEMBER_FILTER}" || "${MEMBER_FILTER}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || fail 'invalid member name.'
[[ -z "${REQUESTED_BY}" || "${REQUESTED_BY}" =~ ^[A-Za-z0-9@._+-]{1,128}$ ]] || fail 'requested-by must be 1-128 characters of letters, digits and @._+-'
[[ -n "${ALL_MEMBERS}" && -n "${MEMBER_FILTER}" ]] && fail '--all-members and --member are mutually exclusive.'
(( ${#BACKUP_DESCRIPTION} <= 500 )) || fail 'description must be 500 characters or fewer.'

require_cmd lxc
require_cmd jq

mountpoint -q "${NFS_BACKUP_DIR}" || fail "'${NFS_BACKUP_DIR}' is not a mounted filesystem. Refusing to write backups to local disk."

ENDPOINT_MEMBER="$(lxc query /1.0 2>/dev/null | jq -r '.environment.server_name // empty')"
[[ -n "${ENDPOINT_MEMBER}" ]] || fail 'unable to determine cluster member name via lxc query /1.0.'
RUNNER="${BACKUP_RUNNER_NAME:-$(hostname -s 2>/dev/null || hostname)}"

if [[ -n "${ALL_MEMBERS}" ]]; then
  TARGET_MEMBER=''
  SCOPE_LABEL='all cluster members'
else
  TARGET_MEMBER="${MEMBER_FILTER:-${ENDPOINT_MEMBER}}"
  SCOPE_LABEL="cluster member '${TARGET_MEMBER}'"
fi

# ---------------------------------------------------------------------------
# Run record: one JSON document per non-dry run in ${NFS_BACKUP_DIR}/.runs/,
# written on exit whatever the outcome.
# ---------------------------------------------------------------------------
RUNS_DIR="${NFS_BACKUP_DIR}/.runs"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)_${RUNNER}_$$"
WORK_DIR="$(mktemp -d)"
: > "${WORK_DIR}/files.jsonl"
: > "${WORK_DIR}/failed.jsonl"
: > "${WORK_DIR}/pruned.jsonl"
BACKED_UP=0
FAILED=0
CURRENT_PARTIAL=''

write_run_record() {
  local exit_code="$1" status
  [[ "${DRY_RUN}" == 'yes' ]] && return 0
  if (( exit_code == 0 )); then status='succeeded'; else status='failed'; fi
  mkdir -p "${RUNS_DIR}" 2>/dev/null || return 0
  jq -n \
    --arg id "${RUN_ID}" \
    --arg status "${status}" \
    --argjson exit_code "${exit_code}" \
    --arg runner "${RUNNER}" \
    --arg endpoint_member "${ENDPOINT_MEMBER}" \
    --arg target_member "${TARGET_MEMBER}" \
    --argjson all_members "$([[ -n "${ALL_MEMBERS}" ]] && echo true || echo false)" \
    --arg project "${PROJECT_FILTER}" \
    --arg instance "${INSTANCE_FILTER}" \
    --arg tag "${BACKUP_TAG}" \
    --arg description "${BACKUP_DESCRIPTION}" \
    --arg requested_by "${REQUESTED_BY}" \
    --argjson pruning "$([[ "${NO_PRUNE}" == 'yes' ]] && echo false || echo true)" \
    --argjson retention_days "${RETENTION_DAYS}" \
    --argjson weekly_weeks "${WEEKLY_WEEKS}" \
    --argjson retention_months "${RETENTION_MONTHS}" \
    --arg started_at "${STARTED_AT}" \
    --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson backed_up "${BACKED_UP}" \
    --arg error "${LAST_ERROR}" \
    --slurpfile files "${WORK_DIR}/files.jsonl" \
    --slurpfile failed "${WORK_DIR}/failed.jsonl" \
    --slurpfile pruned "${WORK_DIR}/pruned.jsonl" \
    '{id: $id, status: $status, exit_code: $exit_code, runner: $runner,
      endpoint_member: $endpoint_member,
      scope: {all_members: $all_members, member: $target_member, project: $project, instance: $instance},
      tag: $tag, description: $description, requested_by: $requested_by,
      pruning: $pruning, retention_days: $retention_days,
      weekly_weeks: $weekly_weeks, retention_months: $retention_months,
      started_at: $started_at, finished_at: $finished_at,
      backed_up: $backed_up, files: $files, failed: $failed, pruned: $pruned, error: $error}' \
    > "${RUNS_DIR}/${RUN_ID}.json.tmp" && mv -f "${RUNS_DIR}/${RUN_ID}.json.tmp" "${RUNS_DIR}/${RUN_ID}.json" \
    || echo "Warning: unable to write run record to '${RUNS_DIR}'." >&2
}

on_exit() {
  local code=$?
  # Only ever removes this run's own incomplete export, never a finished backup.
  [[ -n "${CURRENT_PARTIAL}" && -f "${CURRENT_PARTIAL}" ]] && rm -f -- "${CURRENT_PARTIAL}"
  write_run_record "${code}"
  rm -rf -- "${WORK_DIR}"
}
trap on_exit EXIT
trap 'LAST_ERROR="interrupted"; exit 130' INT TERM

rel_path() {
  printf '%s' "${1#"${NFS_BACKUP_DIR}/"}"
}

prune_old_backups() {
  local instance_dir="$1" instance_name="$2"
  [[ -d "${instance_dir}" ]] || return 0
  mapfile -t ALL_FILES < <(find "${instance_dir}" -maxdepth 1 -type f -name "${instance_name}_*.tar.gz" 2>/dev/null)
  (( ${#ALL_FILES[@]} > 0 )) || return 0

  local now_epoch
  now_epoch="$(date +%s)"

  # Grandfather-father-son rotation: a backup younger than RETENTION_DAYS is
  # always kept (daily tier). Older than that, backups are grouped into
  # buckets (7-day buckets through WEEKLY_END_DAYS, then ~30-day buckets
  # through MONTHLY_TOTAL_DAYS) and only the newest backup in each bucket
  # survives; everything past MONTHLY_TOTAL_DAYS is deleted outright.
  local -A BUCKET_BEST_FILE=()
  local -A BUCKET_BEST_AGE=()
  local -a DELETE_CANDIDATES=()
  local f mtime age_days bucket_key

  for f in "${ALL_FILES[@]}"; do
    mtime="$(stat -c %Y "${f}" 2>/dev/null)" || continue
    age_days=$(( (now_epoch - mtime) / 86400 ))

    if (( age_days < RETENTION_DAYS )); then
      continue
    elif (( age_days < WEEKLY_END_DAYS )); then
      bucket_key="w$(( (age_days - RETENTION_DAYS) / 7 ))"
    elif (( age_days < MONTHLY_TOTAL_DAYS )); then
      bucket_key="m$(( (age_days - WEEKLY_END_DAYS) / 30 ))"
    else
      DELETE_CANDIDATES+=("${f}")
      continue
    fi

    if [[ -z "${BUCKET_BEST_FILE[${bucket_key}]:-}" ]] || (( age_days < BUCKET_BEST_AGE[${bucket_key}] )); then
      [[ -n "${BUCKET_BEST_FILE[${bucket_key}]:-}" ]] && DELETE_CANDIDATES+=("${BUCKET_BEST_FILE[${bucket_key}]}")
      BUCKET_BEST_FILE[${bucket_key}]="${f}"
      BUCKET_BEST_AGE[${bucket_key}]="${age_days}"
    else
      DELETE_CANDIDATES+=("${f}")
    fi
  done

  (( ${#DELETE_CANDIDATES[@]} > 0 )) || return 0
  for OLD_FILE in "${DELETE_CANDIDATES[@]}"; do
    if [[ "${DRY_RUN}" == 'yes' ]]; then
      echo "[dry-run] would prune '${OLD_FILE}'"
    else
      echo "Pruning old backup '${OLD_FILE}'..."
      rm -f "${OLD_FILE}" "${OLD_FILE}.json"
      jq -cn --arg p "$(rel_path "${OLD_FILE}")" '$p' >> "${WORK_DIR}/pruned.jsonl"
    fi
  done
}

prune_old_run_records() {
  [[ -d "${RUNS_DIR}" ]] || return 0
  if [[ "${DRY_RUN}" == 'yes' ]]; then
    find "${RUNS_DIR}" -maxdepth 1 -type f -name '*.json' -mtime "+${RUN_HISTORY_DAYS}" -printf "[dry-run] would prune run record '%p'\n" 2>/dev/null
  else
    find "${RUNS_DIR}" -maxdepth 1 -type f -name '*.json' -mtime "+${RUN_HISTORY_DAYS}" -delete 2>/dev/null
  fi
}

write_metadata() {
  local backup_file="$1" project_name="$2" instance_name="$3" location="$4"
  jq -n \
    --arg project "${project_name}" \
    --arg instance "${instance_name}" \
    --arg member "${location}" \
    --arg runner "${RUNNER}" \
    --arg run_id "${RUN_ID}" \
    --arg tag "${BACKUP_TAG}" \
    --arg description "${BACKUP_DESCRIPTION}" \
    --arg requested_by "${REQUESTED_BY}" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson size "$(stat -c %s "${backup_file}")" \
    '{project: $project, instance: $instance, member: $member, runner: $runner, run_id: $run_id,
      tag: $tag, description: $description, requested_by: $requested_by,
      created_at: $created_at, size_bytes: $size}' \
    > "${backup_file}.json" || echo "Warning: unable to write metadata sidecar for '${backup_file}'." >&2
}

if [[ "${NO_PRUNE}" == 'yes' ]]; then
  echo "Backing up instances on ${SCOPE_LABEL} via '${ENDPOINT_MEMBER}' from '${RUNNER}' (pruning disabled)..."
else
  echo "Backing up instances on ${SCOPE_LABEL} via '${ENDPOINT_MEMBER}' from '${RUNNER}' (retention: ${RETENTION_DAYS}d daily, ${WEEKLY_WEEKS}wk weekly, ${RETENTION_MONTHS}mo total)..."
fi

if [[ -n "${PROJECT_FILTER}" ]]; then
  lxc project show "${PROJECT_FILTER}" >/dev/null 2>&1 || fail "project '${PROJECT_FILTER}' does not exist."
  PROJECT_NAMES=("${PROJECT_FILTER}")
else
  mapfile -t PROJECT_NAMES < <(lxc project list --format csv 2>/dev/null | cut -d',' -f1 | sed 's/ (current)$//' || true)
fi
(( ${#PROJECT_NAMES[@]} > 0 )) || fail 'no projects found.'

MATCHED=0
for PROJECT_NAME in "${PROJECT_NAMES[@]}"; do
  [[ -n "${PROJECT_NAME}" ]] || continue

  mapfile -t INSTANCE_ROWS < <(lxc list --project "${PROJECT_NAME}" -c nL -f csv 2>/dev/null || true)
  (( ${#INSTANCE_ROWS[@]} > 0 )) || continue

  for INSTANCE_ROW in "${INSTANCE_ROWS[@]}"; do
    [[ -n "${INSTANCE_ROW}" ]] || continue
    IFS=',' read -r INSTANCE_NAME INSTANCE_LOCATION <<< "${INSTANCE_ROW}"
    [[ -z "${INSTANCE_FILTER}" || "${INSTANCE_NAME}" == "${INSTANCE_FILTER}" ]] || continue
    if [[ -n "${TARGET_MEMBER}" && "${INSTANCE_LOCATION}" != "${TARGET_MEMBER}" ]]; then
      [[ -n "${INSTANCE_FILTER}" ]] && echo "Skipping '${INSTANCE_NAME}': located on '${INSTANCE_LOCATION}', not '${TARGET_MEMBER}'."
      continue
    fi

    MATCHED=$((MATCHED + 1))
    INSTANCE_DIR="${NFS_BACKUP_DIR}/${PROJECT_NAME}/${INSTANCE_NAME}"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_FILE="${INSTANCE_DIR}/${INSTANCE_NAME}_${TIMESTAMP}${BACKUP_TAG:+_${BACKUP_TAG}}.tar.gz"

    if [[ "${DRY_RUN}" == 'yes' ]]; then
      echo "[dry-run] would back up '${INSTANCE_NAME}' (project '${PROJECT_NAME}', member '${INSTANCE_LOCATION}') to '${BACKUP_FILE}'"
    else
      mkdir -p "${INSTANCE_DIR}" || fail "unable to create '${INSTANCE_DIR}'."
      echo "Backing up '${INSTANCE_NAME}' (project '${PROJECT_NAME}', member '${INSTANCE_LOCATION}') to '${BACKUP_FILE}'..."
      # Export to a .partial name and rename on success, so an interrupted or
      # failed export never looks like a restorable backup.
      CURRENT_PARTIAL="${BACKUP_FILE}.partial"
      if lxc export "${INSTANCE_NAME}" "${CURRENT_PARTIAL}" --project "${PROJECT_NAME}" --optimized-storage --compression gzip 2> "${WORK_DIR}/export.err" \
         && mv -f -- "${CURRENT_PARTIAL}" "${BACKUP_FILE}"; then
        CURRENT_PARTIAL=''
        write_metadata "${BACKUP_FILE}" "${PROJECT_NAME}" "${INSTANCE_NAME}" "${INSTANCE_LOCATION}"
        jq -cn --arg p "$(rel_path "${BACKUP_FILE}")" '$p' >> "${WORK_DIR}/files.jsonl"
        BACKED_UP=$((BACKED_UP + 1))
      else
        EXPORT_ERR="$(tr '\n' ' ' < "${WORK_DIR}/export.err" | sed 's/[[:space:]]*$//')"
        echo "Error: backup of '${INSTANCE_NAME}' (project '${PROJECT_NAME}') failed: ${EXPORT_ERR:-lxc export failed}" >&2
        rm -f -- "${CURRENT_PARTIAL}"
        CURRENT_PARTIAL=''
        jq -cn --arg p "${PROJECT_NAME}" --arg i "${INSTANCE_NAME}" --arg m "${INSTANCE_LOCATION}" --arg e "${EXPORT_ERR}" \
          '{project: $p, instance: $i, member: $m, error: $e}' >> "${WORK_DIR}/failed.jsonl"
        FAILED=$((FAILED + 1))
      fi
    fi

    [[ "${NO_PRUNE}" == 'yes' ]] || prune_old_backups "${INSTANCE_DIR}" "${INSTANCE_NAME}"
  done
done

if [[ -n "${INSTANCE_FILTER}" ]] && (( MATCHED == 0 )); then
  fail "instance '${INSTANCE_FILTER}' was not found on ${SCOPE_LABEL}."
fi

[[ "${NO_PRUNE}" == 'yes' ]] || prune_old_run_records

echo
if [[ "${DRY_RUN}" == 'yes' ]]; then
  echo 'Dry run complete. No backups were written or pruned.'
elif (( FAILED > 0 )); then
  LAST_ERROR="${FAILED} of ${MATCHED} instance backup(s) failed"
  echo "Backup finished with errors. ${BACKED_UP} instance(s) backed up, ${FAILED} failed on ${SCOPE_LABEL}." >&2
  exit 1
else
  echo "Backup complete. ${BACKED_UP} instance(s) backed up on ${SCOPE_LABEL}."
fi
