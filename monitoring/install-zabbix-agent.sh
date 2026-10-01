#!/usr/bin/env bash
# Installs the Zabbix agent (active mode) in an existing Linux instance and
# links the Linux template to its Zabbix host. New instances get the agent from
# their profile's cloud-init instead (deploy-project.sh --update-payloads).
#   ./monitoring/install-zabbix-agent.sh --project-id 20 --instance pd20-dnsag-ct01
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

PROJECT_ID='' INSTANCE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="${2:-}"; shift 2 ;;
    --instance) INSTANCE="${2:-}"; shift 2 ;;
    --help|-h) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ -n "${PROJECT_ID}" && -n "${INSTANCE}" ]] || fail 'usage: install-zabbix-agent.sh --project-id ID --instance NAME'
[[ -n "${ZABBIX_SERVER_ACTIVE:-}" ]] || fail 'ZABBIX_SERVER_ACTIVE is not set in .env.'
PROJECT="$(incus project list -f json | jq -r --arg d "Project ID: ${PROJECT_ID}" '.[] | select(.description == $d) | .name')"
[[ -n "${PROJECT}" ]] || fail "no project with ID ${PROJECT_ID}."
[[ "$(incus list "${INSTANCE}" --project "${PROJECT}" -f csv -c s)" == 'RUNNING' ]] || fail "'${INSTANCE}' isn't running in '${PROJECT}'."

incus file push "${SCRIPT_DIR}/zabbix-agent-install.sh" "${INSTANCE}/root/zabbix-agent-install.sh" --project "${PROJECT}" --mode 0700 || fail 'unable to push the installer.'
incus exec "${INSTANCE}" --project "${PROJECT}" -- bash /root/zabbix-agent-install.sh "${ZABBIX_SERVER_ACTIVE}" "infnet;${PROJECT}" || fail 'agent install failed.'
incus exec "${INSTANCE}" --project "${PROJECT}" -- rm -f /root/zabbix-agent-install.sh

zabbix_register_instance "${INSTANCE}" "${PROJECT}" linux \
  "$(incus config get "${INSTANCE}" user.public_ipv4 --project "${PROJECT}" 2>/dev/null)" \
  "$(instance_internal_ipv4 "${INSTANCE}" "${PROJECT}")" yes
