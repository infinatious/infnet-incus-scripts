#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage: cluster-health.sh

Read-only health report for this host's Incus cluster (or standalone server).
Each check is marked OK, WARN or FAIL:

  Members     status, roles, Incus version, quorum-only flags
  OVN         RAFT leader and every member's replication (read on the leader)
  Gateways    which host carries each project network's uplink traffic
  Instances   per member; warns when a redundant set (…-ct01/…-ct02) shares
              one member
  Storage     storage pool usage per member
  Backups     newest backup of every running instance, the last backup run,
              and the backup timer and NFS mount on every member
  Hosts       pending reboot, UEFI boot logo, expected NFS mounts

Run it as your normal user on any member. Host checks use ssh to the other
members (cluster addresses), and the OVN check uses sudo on the OVN leader,
so expect a sudo prompt where sudo needs a password. Exit status is 1 when
any check FAILs.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '') ;;
  *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
esac

[[ -f "${ENV_FILE}" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"
command -v incus >/dev/null 2>&1 || { echo 'Error: incus command not found.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'Error: jq not found.' >&2; exit 1; }

STORAGE_POOL="${STORAGE_POOL:-zpool}"
NFS_BACKUP_DIR="${NFS_BACKUP_DIR:-/mnt/incus-backups}"
BACKUP_WARN_HOURS="${BACKUP_WARN_HOURS:-36}"
BACKUP_FAIL_HOURS="${BACKUP_FAIL_HOURS:-192}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; TEAL=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN='' YELLOW='' RED='' TEAL='' BOLD='' RESET=''
fi
OKS=0 WARNS=0 FAILS=0
ok()   { OKS=$((OKS + 1));   printf '  %s[ OK ]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { WARNS=$((WARNS + 1)); printf '  %s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf '  %s[FAIL]%s %s\n' "${RED}" "${RESET}" "$*"; }
info() { printf '         %s\n' "$*"; }
section() { printf '\n%s%s%s\n' "${TEAL}${BOLD}" "$*" "${RESET}"; }

# --- Members ---------------------------------------------------------------------

LOCAL_NAME="$(incus query /1.0 | jq -r '.environment.server_name')"
CLUSTERED="$(incus query /1.0 | jq -r '.environment.server_clustered')"
declare -A ADDRESS REAL_ADDRESS HOSTNAME_OF MEMBER_OF_HOST
MEMBERS=()
if [[ "${CLUSTERED}" == 'true' ]]; then
  MEMBERS_JSON="$(incus query /1.0/cluster/members?recursion=1)"
  while read -r name url; do
    address="${url#https://}"; address="${address%:*}"; address="${address#[}"; address="${address%]}"
    MEMBERS+=("${name}"); ADDRESS[${name}]="${address}"; REAL_ADDRESS[${name}]="${address}"
  done < <(jq -r 'sort_by(.server_name)[] | "\(.server_name) \(.url)"' <<< "${MEMBERS_JSON}")
else
  MEMBERS_JSON='[]'; MEMBERS=("${LOCAL_NAME}")
fi
ADDRESS[${LOCAL_NAME}]='local'

# Host names come from OVN's chassis records (hostname + tunnel IP, which is
# the member's cluster address), so they don't depend on ssh.
while IFS=, read -r chassis ip; do
  host="$(sudo ovn-sbctl --no-leader-only --format=csv --data=bare --no-headings --columns=hostname find chassis "name=${chassis}" 2>/dev/null)"
  for m in "${MEMBERS[@]}"; do
    [[ "${REAL_ADDRESS[${m}]:-}" == "${ip}" && -n "${host}" ]] && { HOSTNAME_OF[${m}]="${host}"; MEMBER_OF_HOST[${host}]="${m}"; }
  done
done < <(sudo ovn-sbctl --no-leader-only --format=csv --data=bare --no-headings --columns=chassis_name,ip list encap 2>/dev/null)

# Runs a command on a member: directly here, over ssh on the others.
on_member() {
  local member="$1"; shift
  if [[ "${ADDRESS[${member}]}" == 'local' ]]; then
    bash -c "$*"
  else
    ssh -o ConnectTimeout=8 -o BatchMode=yes "${ADDRESS[${member}]}" "$*"
  fi
}

printf '%sINFNET cluster health%s  (%s, %s)\n' "${BOLD}" "${RESET}" "$(hostname -s)" "$(date '+%F %T %Z')"

section 'Members'
for m in "${MEMBERS[@]}"; do
  if [[ -z "${HOSTNAME_OF[${m}]:-}" ]]; then
    HOSTNAME_OF[${m}]="$(on_member "${m}" hostname -s 2>/dev/null || echo '?')"
    MEMBER_OF_HOST[${HOSTNAME_OF[${m}]}]="${m}"
  fi
  version="$(incus query "/1.0?target=${m}" 2>/dev/null | jq -r '.environment.server_version // "?"')"
  if [[ "${CLUSTERED}" == 'true' ]]; then
    status="$(jq -r --arg m "${m}" '.[] | select(.server_name == $m) | .status' <<< "${MEMBERS_JSON}")"
    roles="$(jq -r --arg m "${m}" '.[] | select(.server_name == $m) | .roles | join(",")' <<< "${MEMBERS_JSON}")"
    placement="$(jq -r --arg m "${m}" '.[] | select(.server_name == $m) | .config["scheduler.instance"] // "all"' <<< "${MEMBERS_JSON}")"
  else
    status='Online'; roles='standalone'; placement='all'
  fi
  line="${m} (${HOSTNAME_OF[${m}]}): ${status}, Incus ${version}, roles ${roles:-none}${placement:+, placement ${placement}}"
  [[ "${status}" == 'Online' ]] && ok "${line}" || bad "${line}"
done
if [[ "${CLUSTERED}" == 'true' ]]; then
  mapfile -t VERSIONS < <(for m in "${MEMBERS[@]}"; do incus query "/1.0?target=${m}" 2>/dev/null | jq -r '.environment.server_version'; done | sort -u)
  (( ${#VERSIONS[@]} <= 1 )) && ok "all members run Incus ${VERSIONS[0]:-?}" || bad "members run different Incus versions: ${VERSIONS[*]}"
  voters="$(jq '[.[] | select(.roles | index("database"))] | length' <<< "${MEMBERS_JSON}")"
  (( voters >= 3 )) && ok "${voters} database voters (tolerates one member down)" || warn "only ${voters} database voter(s): losing a member stops the cluster API"
fi

# --- OVN ---------------------------------------------------------------------------

section 'OVN databases'
# The leader's view has each follower's replication state; find the leader
# from this host's view, then read the status there.
ovn_status() { on_member "$1" "sudo ovn-appctl -t /var/run/ovn/ovn$2_db.ctl cluster/status $3" 2>/dev/null; }
for db in 'nb OVN_Northbound' 'sb OVN_Southbound'; do
  read -r short schema <<< "${db}"
  local_view="$(sudo ovn-appctl -t "/var/run/ovn/ovn${short}_db.ctl" cluster/status "${schema}" 2>/dev/null)"
  if [[ -z "${local_view}" ]]; then
    if [[ -S /run/ovn/ovn${short}_db.sock ]]; then
      ok "${schema}: standalone (not clustered) on this host"
    else
      warn "${schema}: no database on this host; run this report on an OVN database member"
    fi
    continue
  fi
  if grep -q '^Role: leader' <<< "${local_view}"; then
    leader_view="${local_view}"; leader_member="${LOCAL_NAME}"
  else
    leader_sid="$(sed -n 's/^Leader: //p' <<< "${local_view}")"
    leader_ip="$(grep -oE "${leader_sid} at tcp:[0-9.]+" <<< "${local_view}" | head -1 | sed 's/.*tcp://')"
    leader_member=''
    for m in "${MEMBERS[@]}"; do [[ "${ADDRESS[${m}]}" == "${leader_ip}" ]] && leader_member="${m}"; done
    if [[ -z "${leader_member}" ]]; then
      bad "${schema}: no leader (this host's view: $(grep -E '^(Status|Role|Leader):' <<< "${local_view}" | tr '\n' ' '))"
      continue
    fi
    leader_view="$(ovn_status "${leader_member}" "${short}" "${schema}")"
    if [[ -z "${leader_view}" ]]; then
      warn "${schema}: leader is ${leader_member}, but its status needs passwordless sudo there over ssh; run this report on ${leader_member} for per-member replication"
      continue
    fi
  fi
  servers="$(grep -cE ' at tcp:' <<< "${leader_view}")"
  ok "${schema}: leader on ${leader_member}, ${servers} member(s)"
  while read -r line; do
    ip="$(grep -oE 'tcp:[0-9.]+' <<< "${line}" | sed 's/tcp://')"
    [[ "${line}" == *'(self)'* ]] && continue
    age="$(grep -oE 'last msg [0-9]+ ms' <<< "${line}" | grep -oE '[0-9]+')"
    who="${ip}"; for m in "${MEMBERS[@]}"; do [[ "${ADDRESS[${m}]}" == "${ip}" ]] && who="${m}"; done
    if [[ -z "${age}" ]]; then bad "${schema}: ${who} has never answered the leader"
    elif (( age > 5000 )); then bad "${schema}: ${who} last answered the leader ${age} ms ago"
    else ok "${schema}: ${who} in sync (last message ${age} ms ago)"; fi
  done < <(grep -E ' at tcp:' <<< "${leader_view}")
done

# --- Gateways ------------------------------------------------------------------------

section 'Gateways (where each project network meets the uplink)'
CHASSIS_MEMBERS="$(jq -r '[.[] | select(.roles | index("ovn-chassis")) | .server_name] | join(" ")' <<< "${MEMBERS_JSON}")"
while IFS=$'\t' read -r project network; do
  chassis="$(incus network info "${network}" --project "${project}" 2>/dev/null | sed -n 's/^ *Chassis: *//p' | head -1)"
  member="${MEMBER_OF_HOST[${chassis}]:-}"
  label="${project}/${network}: ${chassis:-none}${member:+ (${member})}"
  if [[ -z "${chassis}" ]]; then bad "${label}: no active gateway"
  elif [[ -n "${CHASSIS_MEMBERS}" && -n "${member}" && " ${CHASSIS_MEMBERS} " != *" ${member} "* ]]; then warn "${label}: not an ovn-chassis member"
  else ok "${label}"; fi
done < <(for p in $(incus project list -f json | jq -r '.[].name'); do
  incus network list --project "${p}" -f json 2>/dev/null | jq -r --arg p "${p}" '.[] | select(.type == "ovn") | "\($p)\t\(.name)"'
done | sort -u)

# --- Instances -----------------------------------------------------------------------

section 'Instances'
INSTANCES_JSON="$(incus query '/1.0/instances?all-projects=true&recursion=1')"
for m in "${MEMBERS[@]}"; do
  [[ "${CLUSTERED}" == 'true' ]] || m=''
  counts="$(jq -r --arg m "${m}" '[.[] | select($m == "" or .location == $m)] | "\(map(select(.status == "Running")) | length) running, \(map(select(.status != "Running")) | length) other"' <<< "${INSTANCES_JSON}")"
  ok "${m:-${LOCAL_NAME}}: ${counts}"
done
# Redundant sets: same name apart from the trailing NN of -ctNN/-vsNN.
while IFS=$'\t' read -r base names locations; do
  if [[ "${CLUSTERED}" == 'true' && "${locations}" != *,* ]]; then
    warn "redundant set ${base} (${names}) all runs on ${locations}; one member failure takes out every copy"
  else
    ok "redundant set ${base} is spread over ${locations}"
  fi
done < <(jq -r '[.[] | select(.status == "Running") | {project, name, location, base: (.project + "/" + (.name | sub("(?<t>-(ct|vs))[0-9]+$"; "\(.t)")))}]
  | group_by(.base)[] | select(length > 1)
  | "\(.[0].base)\t\(map(.name) | join(","))\t\(map(.location) | unique | join(","))"' <<< "${INSTANCES_JSON}")
mapfile -t ERRORED < <(jq -r '.[] | select(.status == "Error") | "\(.project)/\(.name) on \(.location)"' <<< "${INSTANCES_JSON}")
(( ${#ERRORED[@]} == 0 )) || for e in "${ERRORED[@]}"; do bad "instance ${e} is in Error state"; done

# --- Resources -----------------------------------------------------------------------

section 'Resource check (headroom per member)'
GIB=1073741824

# bar PCT: a 30-wide bar plus the percentage, green < 70 <= yellow < 85 <= red.
# Values over 100 (overcommitted RAM, load above the thread count) fill the bar.
bar() {
  local pct="$1" width=30 fill i out='' color="${GREEN}"
  (( pct >= 70 )) && color="${YELLOW}"
  (( pct >= 85 )) && color="${RED}"
  fill=$(( pct > 100 ? width : pct * width / 100 ))
  for (( i = 0; i < width; i++ )); do (( i < fill )) && out+='█' || out+='░'; done
  printf '%s%s%s %3d%%' "${color}" "${out}" "${RESET}" "${pct}"
}
# row LEVEL LABEL PCT DETAIL: one status line with a bar (LEVEL is ok/warn/bad).
row() { "$1" "$(printf '%-14s' "$2") $(bar "$3")  $4"; }
gib() { awk -v b="$1" 'BEGIN { v = b / 1073741824; printf (v >= 100 ? "%.0f" : "%.1f"), v }'; }

for m in "${MEMBERS[@]}"; do
  target=''; [[ "${CLUSTERED}" == 'true' ]] && target="?target=${m}"
  printf '  %s%s%s (%s)\n' "${BOLD}" "${m}" "${RESET}" "${HOSTNAME_OF[${m}]:-?}"

  # Live figures from the host itself: threads, load, memory, ZFS ARC.
  # MemAvailable doesn't count the ARC as reclaimable, but everything above
  # the ARC's minimum size is given back under memory pressure.
  stats="$(on_member "${m}" 'nproc; cut -d" " -f1-3 /proc/loadavg
    awk "/^MemTotal:/ {t=\$2} /^MemAvailable:/ {a=\$2} END {print t*1024, a*1024}" /proc/meminfo
    awk "\$1==\"size\" {s=\$3} \$1==\"c_min\" {c=\$3} END {print s+0, c+0}" /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo "0 0"' 2>/dev/null)" || stats=''
  if [[ -n "${stats}" ]]; then
    { read -r threads; read -r load1 load5 load15; read -r mem_total mem_avail; read -r arc arc_min; } <<< "${stats}"
    arc_free=$(( arc > arc_min ? arc - arc_min : 0 ))
    mem_used=$(( mem_total - mem_avail - arc_free ))
    (( mem_used < 0 )) && mem_used=0
  else
    # No ssh: fall back to the Incus API (counts the ARC as used, no load).
    read -r mem_total mem_used threads < <(incus query "/1.0/resources${target}" 2>/dev/null | jq -r '"\(.memory.total) \(.memory.used) \(.cpu.total)"')
    load5=''; arc_free=0
  fi

  # Disk: the storage pool.
  read -r used total < <(incus query "/1.0/storage-pools/${STORAGE_POOL}/resources${target}" 2>/dev/null | jq -r '"\(.space.used) \(.space.total)"')
  if [[ -z "${total:-}" || "${total}" == 'null' || "${total}" == '0' ]]; then
    warn "${STORAGE_POOL}: can't read pool usage"
  else
    pct=$(( used * 100 / total )); lvl=ok; (( pct >= 80 )) && lvl=warn; (( pct >= 90 )) && lvl=bad
    row "${lvl}" "${STORAGE_POOL} used" "${pct}" "$(gib "${used}") of $(gib "${total}") GiB, $(gib $(( total - used ))) GiB free"
  fi

  # Allocated RAM and vCPUs: the limits of the instances placed on this member.
  # limits.memory can be bytes, K/M/G/T(i)B or a % of host RAM; limits.cpu a count or a CPU set.
  if [[ -n "${mem_total:-}" && "${mem_total}" != 'null' && "${mem_total}" != '0' ]]; then
    read -r alloc_run alloc_stop n_run n_unlimited vcpus < <(jq -r --arg m "${target:+${m}}" --argjson total "${mem_total}" '
      def bytes: if . == null then null
        elif test("%$") then (rtrimstr("%") | tonumber) * $total / 100
        else (capture("^(?<n>[0-9.]+)\\s*(?<u>[kKMGTPE]?)(?<i>i?)B?$") // null) as $c
          | if $c == null then null
            else ($c.n | tonumber) * pow(if $c.i == "i" then 1024 else 1000 end; {"":0,"k":1,"K":1,"M":2,"G":3,"T":4,"P":5,"E":6}[$c.u])
            end
        end;
      def cpus: if . == null then 0
        elif test("^[0-9]+$") then tonumber
        else [split(",")[] | if test("-") then (split("-") | map(tonumber) | .[1] - .[0] + 1) else 1 end] | add
        end;
      [.[] | select($m == "" or .location == $m)
        | {running: (.status == "Running"), mem: (.expanded_config["limits.memory"] | bytes), cpu: (.expanded_config["limits.cpu"] | cpus)}] as $i
      | [($i | map(select(.running) | .mem // 0) | add // 0 | floor),
         ($i | map(select(.running | not) | .mem // 0) | add // 0 | floor),
         ($i | map(select(.running)) | length),
         ($i | map(select(.running and .mem == null)) | length),
         ($i | map(select(.running) | .cpu) | add // 0)] | @tsv' <<< "${INSTANCES_JSON}")
    pct=$(( alloc_run * 100 / mem_total )); lvl=ok; (( pct >= 90 )) && lvl=warn
    detail="$(gib "${alloc_run}") of $(gib "${mem_total}") GiB to ${n_run} running"
    if (( alloc_run <= mem_total )); then detail+=", $(gib $(( mem_total - alloc_run ))) GiB unallocated"
    else detail+=", overcommitted by $(gib $(( alloc_run - mem_total ))) GiB"; fi
    (( alloc_stop > 0 )) && detail+=" (+$(gib "${alloc_stop}") GiB stopped)"
    (( n_unlimited > 0 )) && detail+=", ${n_unlimited} without a memory limit"
    row "${lvl}" 'RAM allocated' "${pct}" "${detail}"

    pct=$(( mem_used * 100 / mem_total )); lvl=ok; (( pct >= 85 )) && lvl=warn; (( pct >= 95 )) && lvl=bad
    detail="$(gib "${mem_used}") of $(gib "${mem_total}") GiB, $(gib $(( mem_total - mem_used ))) GiB available"
    (( arc_free > GIB / 10 )) && detail+=" (counts $(gib "${arc_free}") GiB of reclaimable ZFS ARC as free)"
    [[ -z "${stats}" ]] && detail+=' (from the Incus API; includes ZFS ARC)'
    row "${lvl}" 'RAM in use' "${pct}" "${detail}"
  else
    warn "can't read memory"
  fi

  # CPU: 5-minute load average against the thread count.
  if [[ -n "${load5:-}" && -n "${threads:-}" && "${threads}" != '0' ]]; then
    pct="$(awk -v l="${load5}" -v t="${threads}" 'BEGIN { printf "%d", l * 100 / t + 0.5 }')"
    lvl=ok; (( pct >= 80 )) && lvl=warn; (( pct >= 100 )) && lvl=bad
    row "${lvl}" 'CPU load (5m)' "${pct}" "${load5} on ${threads} threads (1m ${load1}, 15m ${load15}); ${vcpus:-0} vCPUs allocated to running instances"
  else
    warn "CPU load: can't reach ${m} over ssh"
  fi
done

# --- Backups -------------------------------------------------------------------------

section 'Backups'
if mountpoint -q "${NFS_BACKUP_DIR}"; then
  now="$(date +%s)"
  # Newest backup per project/instance: "<epoch> <project>/<instance>".
  declare -A NEWEST
  while read -r ts path; do
    key="${path%/*}"; [[ -z "${NEWEST[${key}]:-}" || "${ts%.*}" -gt "${NEWEST[${key}]}" ]] && NEWEST[${key}]="${ts%.*}"
  done < <(sudo find "${NFS_BACKUP_DIR}" -mindepth 3 -maxdepth 3 -name '*.tar.gz' -printf '%T@ %P\n' 2>/dev/null)
  while IFS=$'\t' read -r project name; do
    newest="${NEWEST[${project}/${name}]:-}"
    if [[ -z "${newest}" ]]; then warn "${project}/${name}: no backup found"; continue; fi
    hours=$(( (now - ${newest%.*}) / 3600 ))
    if (( hours >= BACKUP_FAIL_HOURS )); then bad "${project}/${name}: newest backup is ${hours} h old"
    elif (( hours >= BACKUP_WARN_HOURS )); then warn "${project}/${name}: newest backup is ${hours} h old"
    else ok "${project}/${name}: newest backup ${hours} h old"; fi
  done < <(jq -r '.[] | select(.status == "Running") | "\(.project)\t\(.name)"' <<< "${INSTANCES_JSON}" | sort)
  last_run="$(find "${NFS_BACKUP_DIR}/.runs" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  if [[ -n "${last_run}" ]]; then
    result="$(jq -r '.result // .status // "unknown"' "${last_run}" 2>/dev/null)"
    [[ "${result}" =~ ^(success|ok|succeeded)$ ]] && ok "last backup run $(basename "${last_run}" .json): ${result}" || warn "last backup run $(basename "${last_run}" .json): ${result}"
  else
    warn "no backup run records in ${NFS_BACKUP_DIR}/.runs"
  fi
else
  bad "${NFS_BACKUP_DIR} isn't mounted on this host"
fi
for m in "${MEMBERS[@]}"; do
  timer="$(on_member "${m}" "systemctl is-enabled infnet-incus-backup.timer 2>/dev/null; systemctl show infnet-incus-backup.service -p Result --value; mountpoint -q '${NFS_BACKUP_DIR}' && echo mounted || echo not-mounted" 2>/dev/null | tr '\n' ' ')"
  read -r enabled result mounted <<< "${timer}"
  if [[ -z "${timer}" ]]; then warn "${m}: unreachable over ssh"
  elif [[ "${enabled}" != 'enabled' ]]; then bad "${m}: backup timer ${enabled:-missing}"
  elif [[ "${mounted}" != 'mounted' ]]; then bad "${m}: ${NFS_BACKUP_DIR} not mounted (backups of its instances will fail)"
  elif [[ "${result}" != 'success' ]]; then warn "${m}: last backup service result '${result}'"
  else ok "${m}: backup timer enabled, last run ${result}, share mounted"; fi
done

# --- Hosts ---------------------------------------------------------------------------

section 'Hosts'
for m in "${MEMBERS[@]}"; do
  facts="$(on_member "${m}" "
    [ -f /var/run/reboot-required ] && echo 'reboot=yes' || echo 'reboot=no'
    echo \"uptime=\$(uptime -p | sed 's/^up //')\"
    if [ -d /var/lib/infnet-uefi-logo ]; then echo \"logo=\$('${ROOT_DIR}/branding/uefi-logo.sh' status 2>/dev/null | sed 's/^Installed: //')\"; else echo 'logo=not used'; fi
    awk '\$3 ~ /^nfs/ && \$1 !~ /^#/ {print \$2}' /etc/fstab | while read -r d; do mountpoint -q \"\$d\" && echo \"mount=\$d ok\" || echo \"mount=\$d MISSING\"; done
  " 2>/dev/null)"
  if [[ -z "${facts}" ]]; then warn "${m}: unreachable over ssh"; continue; fi
  uptime_s="$(sed -n 's/^uptime=//p' <<< "${facts}")"
  logo="$(sed -n 's/^logo=//p' <<< "${facts}")"
  if grep -q '^reboot=yes' <<< "${facts}"; then warn "${m}: reboot pending (up ${uptime_s})"; else ok "${m}: no reboot pending (up ${uptime_s})"; fi
  case "${logo}" in
    'not used') ;;
    Infinatious*) ok "${m}: UEFI boot logo ${logo}" ;;
    *) warn "${m}: UEFI boot logo: ${logo} (rebuild with the Incus upgrade task, or branding/uefi-logo.sh build && apply)" ;;
  esac
  while read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" == *MISSING ]] && bad "${m}: NFS mount ${line% MISSING} not mounted" || ok "${m}: NFS mount ${line% ok}"
  done < <(sed -n 's/^mount=//p' <<< "${facts}")
done

# --- Summary -------------------------------------------------------------------------

printf '\n%sSummary:%s %s%d OK%s, %s%d WARN%s, %s%d FAIL%s\n' "${BOLD}" "${RESET}" \
  "${GREEN}" "${OKS}" "${RESET}" "${YELLOW}" "${WARNS}" "${RESET}" "${RED}" "${FAILS}" "${RESET}"
(( FAILS == 0 ))
