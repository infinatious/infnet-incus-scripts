#!/usr/bin/env bash
# Runner-side entry point for the web UI: a fixed list of actions that run the
# infnet-incus-scripts, with job logs the UI can read back.
#
#   ops-job.sh list-backups              JSON array of backups on the NFS share
#   ops-job.sh list-jobs                 JSON array of the most recent jobs
#   ops-job.sh start JOBID ACTION JSON   run ACTION in the background
#
# Actions (JSON arguments):
#   backup           {"project","instance","tag","description","requested_by"}
#   restore          {"project","instance","backup_file","in_place","new_name","requested_by"}
#   create-project   {"name","project_id","ipv6"}
#   delete-project   {"project","backup_first","requested_by"}
#   create-instance  {"project","environment","service_code","profile_type","cpu","ram_mib","disk",
#                     "image_alias","empty","public_ip","target","description_suffix",
#                     "firewall_rules":[{"proto","ports","source","description"}]}
#                     The rules are added with firewall-manager.sh once the instance exists.
#   delete-instance  {"project","instance" | "items":[{"project","instance"}],"backup_first","requested_by"}
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

jq_bool() {
  # jq_bool KEY DEFAULT -> true|false from JOB_PARAMS ("//" would treat false as missing)
  jq -r --arg k "$1" --arg d "$2" 'if has($k) and .[$k] != null then (.[$k] | tostring) else $d end' <<< "${JOB_PARAMS}"
}

run_create_project() {
  local name id ipv6
  name="$(jq -r '.name // empty' <<< "${JOB_PARAMS}")"
  id="$(jq -r '.project_id // empty | tostring' <<< "${JOB_PARAMS}")"
  ipv6="$(jq_bool ipv6 true)"
  valid_name "${name}" || { echo "Error: invalid project name."; return 2; }
  [[ "${id}" =~ ^[0-9]+$ ]] && (( id >= 2 && id <= 253 )) || { echo "Error: the project ID must be a number from 2 to 253."; return 2; }
  incus project show "${name}" >/dev/null 2>&1 </dev/null && { echo "Error: project '${name}' already exists."; return 2; }
  local args=(--project-name "${name}" --project-id "${id}")
  [[ "${ipv6}" == "true" ]] || args+=(--no-ipv6)
  "${ROOT_DIR}/deploy-project.sh" "${args[@]}" </dev/null
}

run_delete_project() {
  local project pid backup_first by
  project="$(jq -r '.project // empty' <<< "${JOB_PARAMS}")"
  backup_first="$(jq_bool backup_first true)"
  by="$(jq -r '.requested_by // "web-ui"' <<< "${JOB_PARAMS}")"
  valid_name "${project}" || { echo "Error: invalid project name."; return 2; }
  valid_text "${by}" || { echo "Error: invalid requester."; return 2; }
  pid="$(project_id_of "${project}")"
  [[ -n "${pid}" ]] || { echo "Error: '${project}' is not a project managed by these scripts (no Project ID)."; return 2; }
  if [[ "${backup_first}" == "true" ]]; then
    echo "== Backing up every instance in ${project} first =="
    "${ROOT_DIR}/backup/backup-instances.sh" --all-members --project "${project}" --tag pre-delete \
      --description "before deleting project ${project}" --requested-by "${by}" --no-prune \
      || { echo "Error: the backup failed; nothing was deleted."; return 3; }
  fi
  echo "== Deleting project ${project} (ID ${pid}) and its instances =="
  "${ROOT_DIR}/delete-project.sh" --project-id "${pid}" --delete-instances --yes </dev/null
}

run_create_instance() {
  local project pid env code ptype cpu ram disk image empty pub target suffix
  project="$(jq -r '.project // empty' <<< "${JOB_PARAMS}")"
  env="$(jq -r '.environment // "p"' <<< "${JOB_PARAMS}")"
  code="$(jq -r '.service_code // empty' <<< "${JOB_PARAMS}")"
  ptype="$(jq -r '.profile_type // "linux"' <<< "${JOB_PARAMS}")"
  cpu="$(jq -r '.cpu // empty | tostring' <<< "${JOB_PARAMS}")"
  ram="$(jq -r '.ram_mib // empty | tostring' <<< "${JOB_PARAMS}")"
  disk="$(jq -r '.disk // empty | tostring' <<< "${JOB_PARAMS}")"
  image="$(jq -r '.image_alias // empty' <<< "${JOB_PARAMS}")"
  empty="$(jq_bool empty false)"
  pub="$(jq -r '.public_ip // "random"' <<< "${JOB_PARAMS}")"
  target="$(jq -r '.target // empty' <<< "${JOB_PARAMS}")"
  suffix="$(jq -r '.description_suffix // empty' <<< "${JOB_PARAMS}")"
  valid_name "${project}" || { echo "Error: invalid project."; return 2; }
  [[ "${env}" =~ ^[ptqd]$ ]] || { echo "Error: environment must be p, t, q or d."; return 2; }
  [[ "${code}" =~ ^[A-Za-z0-9]{5}$ ]] || { echo "Error: the service code must be 5 letters or digits."; return 2; }
  case "${ptype}" in linux|win|docker) ;; *) echo "Error: invalid profile type."; return 2 ;; esac
  [[ "${cpu}" =~ ^[0-9]+$ ]] && (( cpu >= 1 && cpu <= 128 )) || { echo "Error: invalid CPU count."; return 2; }
  [[ "${ram}" =~ ^[0-9]+$ ]] && (( ram >= 128 && ram <= 4194304 )) || { echo "Error: invalid RAM."; return 2; }
  [[ "${disk}" =~ ^[0-9]+$ ]] && (( disk >= 1 && disk <= 16384 )) || { echo "Error: invalid disk size."; return 2; }
  [[ -z "${target}" ]] || valid_name "${target}" || { echo "Error: invalid zone."; return 2; }
  valid_text "${suffix}" || { echo "Error: invalid description."; return 2; }
  local fw_specs=() fw_sources=() fw_descs=() rule proto ports source rdesc
  while IFS= read -r rule; do
    [[ -n "${rule}" ]] || continue
    proto="$(jq -r '.proto // empty' <<< "${rule}")"
    ports="$(jq -r '.ports // empty' <<< "${rule}")"
    source="$(jq -r '.source // empty' <<< "${rule}")"
    rdesc="$(jq -r '.description // empty' <<< "${rule}")"
    case "${proto}" in
      tcp|udp|both) [[ "${ports}" =~ ^[0-9]{1,5}([,-][0-9]{1,5})*$ ]] || { echo "Error: invalid firewall ports '${ports}'."; return 2; }
        fw_specs+=("${proto}:${ports}") ;;
      icmp4|icmp6) fw_specs+=("${proto}") ;;
      *) echo "Error: invalid firewall protocol '${proto}'."; return 2 ;;
    esac
    [[ -z "${source}" || "${source}" == infnet || "${source}" =~ ^[0-9A-Fa-f:./,]+$ ]] || { echo "Error: invalid firewall source '${source}'."; return 2; }
    valid_text "${rdesc}" || { echo "Error: invalid firewall description."; return 2; }
    fw_sources+=("${source}"); fw_descs+=("${rdesc}")
  done < <(jq -c '.firewall_rules // [] | .[]' <<< "${JOB_PARAMS}")
  pid="$(project_id_of "${project}")"
  [[ -n "${pid}" ]] || { echo "Error: '${project}' is not a project managed by these scripts (no Project ID)."; return 2; }
  local args=(--project-id "${pid}" --environment "${env}" --service-code "${code}" --profile-type "${ptype}"
    --cpu "${cpu}" --ram-mib "${ram}" --disk "${disk}")
  if [[ "${empty}" == "true" ]]; then
    args+=(--empty)
  else
    valid_name "${image}" || { echo "Error: choose an image."; return 2; }
    args+=(--image-alias "${image}")
  fi
  case "${pub}" in
    none) args+=(--no-public-ip) ;;
    random) args+=(--public-ip random) ;;
    *) [[ "${pub}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Error: invalid public IP."; return 2; }; args+=(--public-ip "${pub}") ;;
  esac
  [[ -z "${target}" ]] || args+=(--target "${target}")
  [[ -z "${suffix}" ]] || args+=(--description-suffix "${suffix}")
  local out rc=0 name i fwargs
  out="$(mktemp)"
  "${ROOT_DIR}/create-instance.sh" "${args[@]}" </dev/null 2>&1 | tee "${out}"
  rc="${PIPESTATUS[0]}"
  name="$(sed -n 's/^Name  *: *//p' "${out}" | head -1)"
  rm -f "${out}"
  (( rc == 0 )) || return "${rc}"
  if (( ${#fw_specs[@]} > 0 )); then
    [[ -n "${name}" ]] || { echo "Error: could not tell the new instance's name; firewall rules were not added."; return 1; }
    echo "== Opening ${#fw_specs[@]} firewall rule(s) on ${name} =="
    for i in "${!fw_specs[@]}"; do
      fwargs=(--project-id "${pid}" --instance "${name}" --add "${fw_specs[$i]}")
      [[ -z "${fw_sources[$i]}" ]] || fwargs+=(--source "${fw_sources[$i]}")
      [[ -z "${fw_descs[$i]}" ]] || fwargs+=(--description "${fw_descs[$i]}")
      "${ROOT_DIR}/firewall-manager.sh" "${fwargs[@]}" </dev/null || rc=1
    done
  fi
  return "${rc}"
}

delete_one_instance() {
  # delete_one_instance PROJECT INSTANCE BACKUP_FIRST BY
  local project="$1" instance="$2" backup_first="$3" by="$4" pid
  valid_name "${project}" && valid_name "${instance}" || { echo "Error: invalid project or instance."; return 2; }
  pid="$(project_id_of "${project}")"
  [[ -n "${pid}" ]] || { echo "Error: '${project}' is not a project managed by these scripts (no Project ID)."; return 2; }
  incus info "${instance}" --project "${project}" >/dev/null 2>&1 </dev/null || { echo "Error: instance '${instance}' not found in '${project}'."; return 2; }
  if [[ "${backup_first}" == "true" ]]; then
    echo "== Backing up ${instance} first =="
    "${ROOT_DIR}/backup/backup-instances.sh" --all-members --project "${project}" --instance "${instance}" \
      --tag pre-delete --description "before deleting ${instance}" --requested-by "${by}" --no-prune \
      || { echo "Error: the backup failed; ${instance} was not deleted."; return 3; }
  fi
  echo "== Deleting ${instance} =="
  "${ROOT_DIR}/delete-instance.sh" --project-id "${pid}" --instance-name "${instance}" --yes </dev/null
}

run_delete_instance() {
  # One instance ("project", "instance") or several ("items": [{"project","instance"}]).
  local backup_first by line project instance code=0 rc
  backup_first="$(jq_bool backup_first true)"
  by="$(jq -r '.requested_by // "web-ui"' <<< "${JOB_PARAMS}")"
  valid_text "${by}" || { echo "Error: invalid requester."; return 2; }
  while IFS=$'\t' read -r project instance; do
    [[ -n "${project}" ]] || continue
    delete_one_instance "${project}" "${instance}" "${backup_first}" "${by}"
    rc=$?
    (( rc == 0 )) || code=${rc}
  done < <(jq -r 'if has("items") then .items[] | "\(.project)\t\(.instance)" else "\(.project // "")\t\(.instance // "")" end' <<< "${JOB_PARAMS}")
  return ${code}
}

start_job() {
  JOB_ID="${1:-}"; JOB_ACTION="${2:-}"; JOB_PARAMS="${3:-}"
  [[ "${JOB_ID}" =~ ^[A-Za-z0-9-]{6,64}$ ]] || fail "invalid job id."
  case "${JOB_ACTION}" in backup|restore|create-project|delete-project|create-instance|delete-instance) ;; *) fail "unknown action '${JOB_ACTION}'." ;; esac
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
      create-project) run_create_project ;;
      delete-project) run_delete_project ;;
      create-instance) run_create_instance ;;
      delete-instance) run_delete_instance ;;
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
