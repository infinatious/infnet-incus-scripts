#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
DNS_LIB_FILE="${SCRIPT_DIR}/technitium-dns.sh"

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sync-dns-records.sh [--dry-run]

Walks every instance in every project that has a stored forward IP
(user.network_forward_ipv4) and makes sure a matching A record exists in
Technitium for <instance-name>.<zone>. Missing records are created and
records pointing at a stale IP are corrected; records that already match
are left untouched. Instances without a forward IP are skipped. Run this
against the whole cluster from any one node - it is not per-member like
backup-instances.sh.

Options:
  --dry-run   Report what would change without writing to Technitium.
  --help      Show this help message.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' not found in PATH."
}

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
[[ -f "${DNS_LIB_FILE}" ]] || fail "${DNS_LIB_FILE} not found."
# shellcheck source=/dev/null
source "${DNS_LIB_FILE}"

DRY_RUN=''
while [[ $# -gt 0 ]]; do
  case "$1" in
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

require_cmd lxc
require_cmd jq
require_cmd curl

technitium_configured || fail 'Technitium is not configured in .env (TECHNITIUM_URL, TECHNITIUM_API_TOKEN, TECHNITIUM_ZONE).'

mapfile -t PROJECT_NAMES < <(lxc project list --format csv -c n 2>/dev/null || true)
(( ${#PROJECT_NAMES[@]} > 0 )) || fail 'no projects found.'

CREATED=0
UPDATED=0
UNCHANGED=0
SKIPPED=0

for PROJECT_NAME in "${PROJECT_NAMES[@]}"; do
  [[ -n "${PROJECT_NAME}" ]] || continue

  mapfile -t INSTANCE_NAMES < <(lxc list --project "${PROJECT_NAME}" -c n -f csv 2>/dev/null || true)
  (( ${#INSTANCE_NAMES[@]} > 0 )) || continue

  for INSTANCE_NAME in "${INSTANCE_NAMES[@]}"; do
    [[ -n "${INSTANCE_NAME}" ]] || continue

    FORWARD_IP="$(lxc config get "${INSTANCE_NAME}" user.network_forward_ipv4 --project "${PROJECT_NAME}" 2>/dev/null || true)"
    if [[ -z "${FORWARD_IP}" ]]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    FQDN="${INSTANCE_NAME}.${TECHNITIUM_ZONE:-infnet}"
    EXISTING_IP="$(dns_lookup_record_ip "${FQDN}" || true)"

    if [[ "${EXISTING_IP}" == "${FORWARD_IP}" ]]; then
      echo "OK       '${FQDN}' -> '${FORWARD_IP}' (project '${PROJECT_NAME}')."
      UNCHANGED=$((UNCHANGED + 1))
      continue
    fi

    if [[ -n "${EXISTING_IP}" ]]; then
      echo "Drifted  '${FQDN}': '${EXISTING_IP}' -> '${FORWARD_IP}' (project '${PROJECT_NAME}')."
      UPDATED=$((UPDATED + 1))
    else
      echo "Missing  '${FQDN}' -> '${FORWARD_IP}' (project '${PROJECT_NAME}')."
      CREATED=$((CREATED + 1))
    fi

    if [[ "${DRY_RUN}" != 'yes' ]]; then
      dns_register_record "${FQDN}" "${FORWARD_IP}" || true
    fi
  done
done

echo
if [[ "${DRY_RUN}" == 'yes' ]]; then
  echo "Dry run complete. Would create ${CREATED}, update ${UPDATED}; ${UNCHANGED} already correct, ${SKIPPED} skipped (no forward IP)."
else
  echo "Sync complete. Created ${CREATED}, updated ${UPDATED}; ${UNCHANGED} already correct, ${SKIPPED} skipped (no forward IP)."
fi
