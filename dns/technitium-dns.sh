#!/usr/bin/env bash
# Shared Technitium DNS API helpers.
# Source this file after loading .env; do not execute it directly.
# Uses TECHNITIUM_URL, TECHNITIUM_API_TOKEN, TECHNITIUM_ZONE, and
# TECHNITIUM_DNS_TTL from .env. All functions are best-effort: DNS failures
# are printed as warnings and never abort the calling script.

technitium_configured() {
  [[ -n "${TECHNITIUM_URL:-}" && -n "${TECHNITIUM_API_TOKEN:-}" && -n "${TECHNITIUM_ZONE:-}" ]]
}

dns_register_record() {
  local fqdn="$1" ip="$2" ttl="${TECHNITIUM_DNS_TTL:-3600}" response

  if ! technitium_configured; then
    echo "Warning: Technitium DNS is not configured in .env, skipping DNS registration for '${fqdn}'." >&2
    return 0
  fi

  response="$(curl -sS -G "${TECHNITIUM_URL%/}/api/zones/records/add" \
    --data-urlencode "token=${TECHNITIUM_API_TOKEN}" \
    --data-urlencode "domain=${fqdn}" \
    --data-urlencode "zone=${TECHNITIUM_ZONE}" \
    --data-urlencode "type=A" \
    --data-urlencode "ipAddress=${ip}" \
    --data-urlencode "ttl=${ttl}" \
    --data-urlencode "overwrite=true" 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "Warning: unable to reach Technitium DNS server at '${TECHNITIUM_URL}' to register '${fqdn}'." >&2
    return 1
  fi
  if [[ "$(jq -r '.status // empty' <<< "${response}" 2>/dev/null)" != 'ok' ]]; then
    echo "Warning: Technitium DNS registration for '${fqdn}' -> '${ip}' failed: ${response}" >&2
    return 1
  fi

  echo "Registered DNS record '${fqdn}' -> '${ip}' in Technitium."
  return 0
}

dns_lookup_record_ip() {
  local fqdn="$1" response ip

  technitium_configured || return 1

  response="$(curl -sS -G "${TECHNITIUM_URL%/}/api/zones/records/get" \
    --data-urlencode "token=${TECHNITIUM_API_TOKEN}" \
    --data-urlencode "domain=${fqdn}" \
    --data-urlencode "zone=${TECHNITIUM_ZONE}" \
    --data-urlencode "listZone=false" 2>&1)"
  [[ $? -eq 0 ]] || return 1
  [[ "$(jq -r '.status // empty' <<< "${response}" 2>/dev/null)" == 'ok' ]] || return 1

  ip="$(jq -r '.response.records[]? | select(.type == "A") | .rData.ipAddress // empty' <<< "${response}" 2>/dev/null | head -n1)"
  [[ -n "${ip}" ]] || return 1

  printf '%s\n' "${ip}"
}

dns_deregister_record() {
  local fqdn="$1" ip="$2" response

  if ! technitium_configured; then
    echo "Warning: Technitium DNS is not configured in .env, skipping DNS removal for '${fqdn}'." >&2
    return 0
  fi

  response="$(curl -sS -G "${TECHNITIUM_URL%/}/api/zones/records/delete" \
    --data-urlencode "token=${TECHNITIUM_API_TOKEN}" \
    --data-urlencode "domain=${fqdn}" \
    --data-urlencode "zone=${TECHNITIUM_ZONE}" \
    --data-urlencode "type=A" \
    --data-urlencode "ipAddress=${ip}" 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "Warning: unable to reach Technitium DNS server at '${TECHNITIUM_URL}' to remove '${fqdn}'." >&2
    return 1
  fi
  if [[ "$(jq -r '.status // empty' <<< "${response}" 2>/dev/null)" != 'ok' ]]; then
    echo "Warning: Technitium DNS removal for '${fqdn}' failed: ${response}" >&2
    return 1
  fi

  echo "Removed DNS record '${fqdn}' from Technitium."
  return 0
}
