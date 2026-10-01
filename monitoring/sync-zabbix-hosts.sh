#!/usr/bin/env bash
# Makes Zabbix match this cluster's instances (like dns/sync-dns-records.sh
# for DNS): registers every instance of the managed projects (described
# "Project ID: N"), updates addresses, groups and TCP port checks, and removes
# managed hosts of this site (ZABBIX_SITE) whose instance is gone. Idempotent.
#   ./monitoring/sync-zabbix-hosts.sh [--no-prune]
# The Linux agent template is linked when the instance's agent was installed
# by these scripts (/etc/zabbix/zabbix_agent2.d/infnet.conf); templates are
# never unlinked.
set -uo pipefail

fail() { echo "Error: $*" >&2; exit 1; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=/dev/null
source "${REPO_DIR}/.env"
# shellcheck source=/dev/null
source "${REPO_DIR}/dns/technitium-dns.sh"
# shellcheck source=/dev/null
source "${REPO_DIR}/lib/zabbix.sh"

PRUNE=yes
case "${1:-}" in
  --no-prune) PRUNE='' ;;
  --help|-h) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) fail "unknown argument: $1" ;;
esac
zabbix_configured || fail 'Zabbix is not configured in .env (ZABBIX_URL, ZABBIX_API_TOKEN, ZABBIX_SITE).'

# Whether an instance runs an agent installed by these scripts.
has_agent() {
  local instance="$1" project="$2"
  timeout 20 incus exec "${instance}" --project "${project}" -- test -f /etc/zabbix/zabbix_agent2.d/infnet.conf </dev/null >/dev/null 2>&1
}

mapfile -t PROJECTS < <(incus project list -f json | jq -r '.[] | select(.description | test("^Project ID: [0-9]+$")) | .name' | sort)
declare -A SEEN=()
for project in "${PROJECTS[@]}"; do
  while IFS=$'\t' read -r instance status family public_ip; do
    [[ -n "${instance}" ]] || continue
    SEEN[${instance}]=1
    internal_ip="$(instance_internal_ipv4 "${instance}" "${project}")"
    agent='no'
    [[ "${family}" == 'linux' && "${status}" == 'Running' ]] && has_agent "${instance}" "${project}" && agent='yes'
    echo "== ${project}/${instance} (${status}, ${family}, agent ${agent})"
    zabbix_register_instance "${instance}" "${project}" "${family}" "${public_ip}" "${internal_ip}" "${agent}" || echo "   (failed, see above)"
  done < <(incus list --project "${project}" -f json | jq -r '.[] |
    "\(.name)\t\(.status)\t\(if ((.profiles | any(endswith("-win"))) or ((.expanded_config["image.os"] // "") | test("windows"; "i"))) then "win" else "linux" end)\t\(.config["user.public_ipv4"] // "")"')
done

if [[ -n "${PRUNE}" ]]; then
  while IFS=$'\t' read -r host_id host; do
    [[ -n "${host_id}" && -z "${SEEN[${host}]:-}" ]] || continue
    zabbix_api host.delete "$(jq -nc --arg h "${host_id}" '[$h]')" >/dev/null && echo "Removed '${host}' from Zabbix (no such instance on ${ZABBIX_SITE})."
  done < <(zabbix_api host.get "$(jq -nc --arg s "${ZABBIX_SITE}" --arg m "${ZABBIX_MANAGED_TAG}" \
    '{tags: [{tag: "managed-by", value: $m, operator: 1}, {tag: "site", value: $s, operator: 1}], output: ["hostid", "host"]}')" | jq -r '.[] | "\(.hostid)\t\(.host)"')
fi
