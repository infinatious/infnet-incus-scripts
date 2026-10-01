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

Makes sure Technitium matches every instance in every project:
  <instance>.<zone>             -> its 1:1 NAT public IP (user.public_ipv4),
                                   for instances that have one
  <instance>.<project>.<zone>   -> its internal address (10.x.x.y), for all
and for every managed project (described "Project ID: N"):
  <project>.<zone>              -> the project network's gateway (10.x.x.1);
                                   another site's gateway for a project of the
                                   same name is left alone
plus the network's DNS domain set to <project>.<zone>. Missing records are
created and records pointing at a stale address are corrected; records that
already match are left untouched. On a cluster, run this from any
one member - it covers every member, unlike backup-instances.sh.

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

require_cmd incus
require_cmd jq
require_cmd curl

technitium_configured || fail 'Technitium is not configured in .env (TECHNITIUM_URL, TECHNITIUM_API_TOKEN, TECHNITIUM_ZONE).'

mapfile -t PROJECT_NAMES < <(incus project list -f json 2>/dev/null | jq -r '.[].name' || true)
(( ${#PROJECT_NAMES[@]} > 0 )) || fail 'no projects found.'

CREATED=0
UPDATED=0
UNCHANGED=0
SKIPPED=0

# Makes one name point at an address: "replace" for instance names (one
# address each), "add" for project names (each site adds its own gateway).
sync_record() {
  local fqdn="$1" ip="$2" mode="$3" label="$4" existing
  existing="$(dns_lookup_record_ips "${fqdn}" || true)"
  if grep -qxF "${ip}" <<< "${existing}" && { [[ "${mode}" == 'add' ]] || [[ "$(grep -c . <<< "${existing}")" == 1 ]]; }; then
    echo "OK       '${fqdn}' -> '${ip}' (${label})."
    UNCHANGED=$((UNCHANGED + 1))
    return 0
  fi
  if [[ -n "${existing}" && "${mode}" == 'replace' ]]; then
    echo "Drifted  '${fqdn}': '$(paste -sd, <<< "${existing}")' -> '${ip}' (${label})."
    UPDATED=$((UPDATED + 1))
  else
    echo "Missing  '${fqdn}' -> '${ip}' (${label})."
    CREATED=$((CREATED + 1))
  fi
  [[ "${DRY_RUN}" == 'yes' ]] || dns_register_record "${fqdn}" "${ip}" "${mode}" || true
}

for PROJECT_NAME in "${PROJECT_NAMES[@]}"; do
  [[ -n "${PROJECT_NAME}" ]] || continue

  # Managed projects: <project>.<zone> -> gateway, and the network's DNS domain.
  if incus query "/1.0/projects/${PROJECT_NAME}" 2>/dev/null | jq -e '.description | test("^Project ID: [0-9]+$")' >/dev/null \
    && incus network show "${PROJECT_NAME}" --project "${PROJECT_NAME}" >/dev/null 2>&1; then
    GATEWAY_IPV4="$(incus network get "${PROJECT_NAME}" ipv4.address --project "${PROJECT_NAME}" 2>/dev/null)"
    [[ -n "${GATEWAY_IPV4}" && "${GATEWAY_IPV4}" != 'none' ]] \
      && sync_record "$(dns_project_name "${PROJECT_NAME}")" "${GATEWAY_IPV4%/*}" add "gateway of project '${PROJECT_NAME}'"
    WANT_DOMAIN="$(dns_project_name "${PROJECT_NAME}")"
    HAVE_DOMAIN="$(incus network get "${PROJECT_NAME}" dns.domain --project "${PROJECT_NAME}" 2>/dev/null)"
    if [[ "${HAVE_DOMAIN}" != "${WANT_DOMAIN}" ]]; then
      echo "Network  '${PROJECT_NAME}' DNS domain: '${HAVE_DOMAIN:-incus (default)}' -> '${WANT_DOMAIN}'."
      [[ "${DRY_RUN}" == 'yes' ]] || incus network set "${PROJECT_NAME}" dns.domain="${WANT_DOMAIN}" --project "${PROJECT_NAME}" || true
    fi
  fi

  mapfile -t INSTANCE_NAMES < <(incus list --project "${PROJECT_NAME}" -c n -f csv 2>/dev/null || true)
  (( ${#INSTANCE_NAMES[@]} > 0 )) || continue

  for INSTANCE_NAME in "${INSTANCE_NAMES[@]}"; do
    [[ -n "${INSTANCE_NAME}" ]] || continue

    PUBLIC_IP="$(incus config get "${INSTANCE_NAME}" user.public_ipv4 --project "${PROJECT_NAME}" 2>/dev/null || true)"
    INTERNAL_IP="$(instance_internal_ipv4 "${INSTANCE_NAME}" "${PROJECT_NAME}")"
    if [[ -n "${PUBLIC_IP}" ]]; then
      sync_record "$(dns_public_name "${INSTANCE_NAME}")" "${PUBLIC_IP}" replace "public, project '${PROJECT_NAME}'"
    fi
    if [[ -n "${INTERNAL_IP}" ]]; then
      sync_record "$(dns_internal_name "${INSTANCE_NAME}" "${PROJECT_NAME}")" "${INTERNAL_IP}" replace "internal, project '${PROJECT_NAME}'"
    fi
    [[ -n "${PUBLIC_IP}${INTERNAL_IP}" ]] || SKIPPED=$((SKIPPED + 1))
  done
done

echo
if [[ "${DRY_RUN}" == 'yes' ]]; then
  echo "Dry run complete. Would create ${CREATED}, update ${UPDATED}; ${UNCHANGED} already correct, ${SKIPPED} skipped (no address known)."
else
  echo "Sync complete. Created ${CREATED}, updated ${UPDATED}; ${UNCHANGED} already correct, ${SKIPPED} skipped (no address known)."
fi
