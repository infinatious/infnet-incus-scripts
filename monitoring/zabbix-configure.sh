#!/usr/bin/env bash
# Configures a Zabbix server installed by install-zabbix-server.sh for these
# scripts, and writes the ZABBIX_* settings into this host's .env:
#   ./monitoring/zabbix-configure.sh --project-id 25 --instance pd25-zabbx-ct01 --site us-west
# DISCORD_WEBHOOK=<url> in the environment (or answer the prompt) turns on
# Discord alerts for Warning and up; leave it empty to skip. Copy the ZABBIX_*
# lines to the other members' .env afterwards (the token is the same).
set -uo pipefail

fail() { echo "Error: $*" >&2; exit 1; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${REPO_DIR}/.env"
# shellcheck source=/dev/null
source "${ENV_FILE}"

PROJECT_ID='' INSTANCE='' SITE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="${2:-}"; shift 2 ;;
    --instance) INSTANCE="${2:-}"; shift 2 ;;
    --site) SITE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ -n "${PROJECT_ID}" && -n "${INSTANCE}" && -n "${SITE}" ]] || { usage; exit 1; }
PROJECT="$(incus project list -f json | jq -r --arg d "Project ID: ${PROJECT_ID}" '.[] | select(.description == $d) | .name')"
[[ -n "${PROJECT}" ]] || fail "no project with ID ${PROJECT_ID}."
PUBLIC_IP="$(incus config get "${INSTANCE}" user.public_ipv4 --project "${PROJECT}" 2>/dev/null)"
INTERNAL_IP="$(incus query "/1.0/instances/${INSTANCE}?project=${PROJECT}" | jq -r '.expanded_devices.eth0["ipv4.address"] // empty')"
[[ -n "${PUBLIC_IP}" && -n "${INTERNAL_IP}" ]] || fail "'${INSTANCE}' needs a public IP and a pinned internal address."

if [[ -z "${DISCORD_WEBHOOK+x}" && -t 0 ]]; then
  read -r -p 'Discord webhook URL for alerts (blank to skip): ' DISCORD_WEBHOOK
fi

incus file push "${SCRIPT_DIR}/zabbix-configure-payload.sh" "${INSTANCE}/root/zabbix-configure-payload.sh" --project "${PROJECT}" --mode 0700 || fail 'unable to push the payload.'
incus exec "${INSTANCE}" --project "${PROJECT}" --env DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}" \
  --env FRONTEND_URL="https://${INSTANCE}.${TECHNITIUM_ZONE:-infnet}/" -- bash /root/zabbix-configure-payload.sh || fail 'configuration failed.'
TOKEN="$(incus exec "${INSTANCE}" --project "${PROJECT}" -- cat /root/zabbix/api-token)" || fail 'unable to read the API token.'

# Replace (or append) the ZABBIX_* settings in .env.
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}='${value}'|" "${ENV_FILE}"
  else
    printf "%s='%s'\n" "${key}" "${value}" >> "${ENV_FILE}"
  fi
}
grep -q '^# Zabbix' "${ENV_FILE}" || printf '\n# Zabbix monitoring (monitoring/zabbix-configure.sh)\n' >> "${ENV_FILE}"
set_env ZABBIX_URL "https://${PUBLIC_IP}"
set_env ZABBIX_API_TOKEN "${TOKEN}"
set_env ZABBIX_SITE "${SITE}"
set_env ZABBIX_SERVER_IP "${PUBLIC_IP}"
set_env ZABBIX_SERVER_ACTIVE "${PUBLIC_IP};${INTERNAL_IP}"
set_env ZABBIX_PROJECT "${PROJECT}"
echo "Wrote the ZABBIX_* settings to ${ENV_FILE}."
