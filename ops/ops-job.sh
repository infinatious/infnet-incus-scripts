#!/usr/bin/env bash
# Runner-side entry point for the web UI: a fixed list of actions that run the
# infnet-incus-scripts, with job logs the UI can read back.
#
#   ops-job.sh list-backups              JSON array of backups on the NFS share
#   ops-job.sh list-jobs                 JSON array of the most recent jobs
#   ops-job.sh start JOBID ACTION JSON   run ACTION in the background
#
# Actions (JSON arguments):
#   backup   {"project","instance","tag","description","requested_by"}
#   restore  {"project","instance","backup_file","in_place","new_name","requested_by"}
#
# Jobs live in ${OPS_JOBS_DIR:-/var/lib/infnet-ops/jobs}/JOBID/{log,status.json}.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
JOBS_DIR="${OPS_JOBS_DIR:-/var/lib/infnet-ops/jobs}"

fail() { echo "Error: $*" >&2; exit 1; }

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
: "${NFS_BACKUP_DIR:?NFS_BACKUP_DIR not set in ${ENV_FILE}}"
command -v jq >/dev/null 2>&1 || fail "jq not found."

NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'
TEXT_RE='^[^[:cntrl:]]{0,200}$'

valid_name() { [[ "$1" =~ ${NAME_RE} ]]; }
valid_text() { [[ "$1" =~ ${TEXT_RE} ]]; }

list_backups() {
  local mount_ok='true'
  mountpoint -q "${NFS_BACKUP_DIR}" || mount_ok='false'
  # One sidecar per backup: <dir>/<project>/<instance>/<file>.tar.gz.json
  find "${NFS_BACKUP_DIR}" -mindepth 3 -maxdepth 3 -name '*.tar.gz.json' -print0 2>/dev/null \
    | while IFS= read -r -d '' sidecar; do
        local tarball="${sidecar%.json}"
        [[ -f "${tarball}" ]] || continue
        jq -c --arg file "${tarball}" --arg size "$(stat -c %s "${tarball}" 2>/dev/null || echo 0)" \
          '. + {file: $file, size_bytes: (.size_bytes // ($size | tonumber))}' "${sidecar}" 2>/dev/null
      done \
    | jq -s --argjson mounted "${mount_ok}" '{mounted: $mounted, backups: (sort_by(.created_at) | reverse)}'
}

list_jobs() {
  mkdir -p "${JOBS_DIR}"
  local d
  for d in $(ls -1t "${JOBS_DIR}" 2>/dev/null | head -30); do
    [[ -f "${JOBS_DIR}/${d}/status.json" ]] && cat "${JOBS_DIR}/${d}/status.json"
  done | jq -s '.'
}

project_id_of() {
  incus query "/1.0/projects/$1" 2>/dev/null </dev/null | jq -r '.description // empty' | sed -n 's/^Project ID: *\([0-9][0-9]*\).*/\1/p' | head -1
}

write_status() {
  # write_status STATE [EXIT]
  local state="$1" code="${2:-}"
  jq -n --arg id "${JOB_ID}" --arg action "${JOB_ACTION}" --arg state "${state}" \
    --arg code "${code}" --arg started "${JOB_STARTED}" --arg params "${JOB_PARAMS}" \
    --arg finished "$([[ "${state}" == running ]] && echo '' || date -u +%FT%TZ)" \
    '{id: $id, action: $action, state: $state, exit_code: (if $code == "" then null else ($code | tonumber) end),
      started_at: $started, finished_at: (if $finished == "" then null else $finished end),
      params: ($params | fromjson)}' > "${JOB_DIR}/status.json.tmp" \
    && mv "${JOB_DIR}/status.json.tmp" "${JOB_DIR}/status.json"
}

run_backup() {
  local project instance tag desc by
  project="$(jq -r '.project // empty' <<< "${JOB_PARAMS}")"
  instance="$(jq -r '.instance // empty' <<< "${JOB_PARAMS}")"
  tag="$(jq -r '.tag // "adhoc"' <<< "${JOB_PARAMS}")"
  desc="$(jq -r '.description // empty' <<< "${JOB_PARAMS}")"
  by="$(jq -r '.requested_by // "web-ui"' <<< "${JOB_PARAMS}")"
  valid_name "${project}" && valid_name "${instance}" && valid_name "${tag}" || { echo "Error: invalid project, instance or tag."; return 2; }
  valid_text "${desc}" && valid_text "${by}" || { echo "Error: invalid description or requester."; return 2; }
  "${ROOT_DIR}/backup/backup-instances.sh" --all-members --project "${project}" --instance "${instance}" \
    --tag "${tag}" --description "${desc}" --requested-by "${by}" --no-prune
}

run_restore() {
  local project instance file in_place new_name by pid
  project="$(jq -r '.project // empty' <<< "${JOB_PARAMS}")"
  instance="$(jq -r '.instance // empty' <<< "${JOB_PARAMS}")"
  file="$(jq -r '.backup_file // empty' <<< "${JOB_PARAMS}")"
  # jq's "//" treats false as missing, so test for false explicitly.
  in_place="$(jq -r 'if .in_place == false then "false" else "true" end' <<< "${JOB_PARAMS}")"
  new_name="$(jq -r '.new_name // empty' <<< "${JOB_PARAMS}")"
  by="$(jq -r '.requested_by // "web-ui"' <<< "${JOB_PARAMS}")"
  valid_name "${project}" && valid_name "${instance}" || { echo "Error: invalid project or instance."; return 2; }
  valid_text "${by}" || { echo "Error: invalid requester."; return 2; }
  [[ -z "${new_name}" ]] || valid_name "${new_name}" || { echo "Error: invalid new name."; return 2; }
  case "${file}" in
    "${NFS_BACKUP_DIR}"/*.tar.gz) ;;
    *) echo "Error: backup file must be a .tar.gz under ${NFS_BACKUP_DIR}."; return 2 ;;
  esac
  [[ "${file}" != *..* && -f "${file}" ]] || { echo "Error: backup file not found."; return 2; }
  pid="$(project_id_of "${project}")"
  [[ -n "${pid}" ]] || { echo "Error: cannot find the project ID of '${project}'."; return 2; }

  if [[ "${in_place}" == "true" ]]; then
    if incus info "${instance}" --project "${project}" >/dev/null 2>&1 </dev/null; then
      echo "== Safety backup of the current ${instance} before replacing it =="
      "${ROOT_DIR}/backup/backup-instances.sh" --all-members --project "${project}" --instance "${instance}" \
        --tag pre-restore --description "before restore from $(basename "${file}")" --requested-by "${by}" --no-prune \
        || { echo "Error: the safety backup failed; nothing was changed."; return 3; }
      echo "== Deleting the current ${instance} =="
      "${ROOT_DIR}/delete-instance.sh" --project-id "${pid}" --instance-name "${instance}" --yes \
        || { echo "Error: deleting the current instance failed."; return 4; }
    fi
    echo "== Restoring ${instance} from ${file} =="
    "${ROOT_DIR}/backup/restore-instance.sh" --project-id "${pid}" --instance-name "${instance}" --backup-file "${file}" --yes
  else
    [[ -n "${new_name}" ]] || { echo "Error: a new name is required when not restoring in place."; return 2; }
    echo "== Restoring ${instance} from ${file} as ${new_name} =="
    "${ROOT_DIR}/backup/restore-instance.sh" --project-id "${pid}" --instance-name "${instance}" --backup-file "${file}" \
      --new-name "${new_name}" --no-public-ip --yes
  fi
}

start_job() {
  JOB_ID="${1:-}"; JOB_ACTION="${2:-}"; JOB_PARAMS="${3:-}"
  [[ "${JOB_ID}" =~ ^[A-Za-z0-9-]{6,64}$ ]] || fail "invalid job id."
  case "${JOB_ACTION}" in backup|restore) ;; *) fail "unknown action '${JOB_ACTION}'." ;; esac
  jq -e 'type == "object"' <<< "${JOB_PARAMS}" >/dev/null 2>&1 || fail "arguments must be a JSON object."
  JOB_DIR="${JOBS_DIR}/${JOB_ID}"
  [[ ! -e "${JOB_DIR}" ]] || fail "job ${JOB_ID} already exists."
  mkdir -p "${JOB_DIR}" || fail "cannot create ${JOB_DIR}."
  JOB_STARTED="$(date -u +%FT%TZ)"
  write_status running
  (
    exec >> "${JOB_DIR}/log" 2>&1
    echo "[$(date -u +%T)] ${JOB_ACTION} started"
    case "${JOB_ACTION}" in
      backup) run_backup ;;
      restore) run_restore ;;
    esac
    code=$?
    echo "[$(date -u +%T)] finished with exit code ${code}"
    write_status "$([[ ${code} -eq 0 ]] && echo succeeded || echo failed)" "${code}"
  ) </dev/null &
  disown
  echo "started ${JOB_ID}"
}

case "${1:-}" in
  list-backups) list_backups ;;
  list-jobs) list_jobs ;;
  start) shift; start_job "$@" ;;
  *) echo "Usage: ops-job.sh list-backups | list-jobs | start JOBID ACTION JSON" >&2; exit 1 ;;
esac
