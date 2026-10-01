#!/usr/bin/env bash
# Installs (or re-runs the idempotent install of) a Zabbix server in an
# existing Ubuntu 26.04 container made by create-instance.sh, e.g.:
#   ./create-instance.sh --project-id 25 --environment p --service-code zabbx --profile-type linux --image-alias ubuntu2604 --cpu 4 --ram 8 --disk 100 --public-ip random
#   ./monitoring/install-zabbix-server.sh --project-id 25 --instance pd25-zabbx-ct01
# Then open the web ports with firewall-manager.sh and run zabbix-configure.sh.
set -uo pipefail

fail() { echo "Error: $*" >&2; exit 1; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=/dev/null
source "${REPO_DIR}/.env"
# shellcheck source=/dev/null
source "${REPO_DIR}/dns/technitium-dns.sh"

PROJECT_ID='' INSTANCE='' TITLE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="${2:-}"; shift 2 ;;
    --instance) INSTANCE="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ -n "${PROJECT_ID}" && -n "${INSTANCE}" ]] || { usage; exit 1; }
PROJECT="$(incus project list -f json | jq -r --arg d "Project ID: ${PROJECT_ID}" '.[] | select(.description == $d) | .name')"
[[ -n "${PROJECT}" ]] || fail "no project with ID ${PROJECT_ID}."
incus info "${INSTANCE}" --project "${PROJECT}" >/dev/null 2>&1 || fail "instance '${INSTANCE}' not found in '${PROJECT}'."

PUBLIC_IP="$(incus config get "${INSTANCE}" user.public_ipv4 --project "${PROJECT}" 2>/dev/null)"
[[ -n "${TITLE}" ]] || case "${INSTANCE:0:1}" in p) TITLE='INFNET Zabbix' ;; *) TITLE="INFNET Zabbix (${INSTANCE%%[0-9]*})" ;; esac

incus file push "${SCRIPT_DIR}/zabbix-server-payload.sh" "${INSTANCE}/root/zabbix-server-payload.sh" --project "${PROJECT}" --mode 0700 || fail 'unable to push the payload.'
incus exec "${INSTANCE}" --project "${PROJECT}" -- bash /root/zabbix-server-payload.sh \
  "$(dns_public_name "${INSTANCE}")" "$(dns_internal_name "${INSTANCE}" "${PROJECT}")" "${PUBLIC_IP:-127.0.0.1}" "${TITLE}"
