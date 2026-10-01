#!/usr/bin/env bash
# Shared Technitium DNS API helpers.
# Source this file after loading .env; do not execute it directly.
# Uses TECHNITIUM_URL, TECHNITIUM_API_TOKEN, TECHNITIUM_ZONE, and
# TECHNITIUM_DNS_TTL from .env. All functions are best-effort: DNS failures
# are printed as warnings and never abort the calling script.
#
# Names, all in the one TECHNITIUM_ZONE (default infnet):
#   <instance>.<zone>             instance's public IP (unique across sites;
#                                 only instances with one)
#   <instance>.<project>.<zone>   instance's internal address (10.x.x.y), for
#                                 every instance
#   <project>.<zone>              the project network's gateway (10.x.x.1). Both
#                                 sites can have a project of the same name, so
#                                 each site only adds and removes its own
#                                 gateway address in that record set.

technitium_configured() {
  [[ -n "${TECHNITIUM_URL:-}" && -n "${TECHNITIUM_API_TOKEN:-}" && -n "${TECHNITIUM_ZONE:-}" ]]
}

# Sets <fqdn> to <ip>, replacing other A records unless the third argument
# is "add" (then <ip> is added next to any existing ones).
dns_register_record() {
  local fqdn="$1" ip="$2" mode="${3:-replace}" ttl="${TECHNITIUM_DNS_TTL:-3600}" response overwrite=true
  [[ "${mode}" == 'add' ]] && overwrite=false

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
    --data-urlencode "overwrite=${overwrite}" 2>&1)"
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

dns_zone() { printf '%s\n' "${TECHNITIUM_ZONE:-infnet}"; }

dns_public_name() { printf '%s\n' "$1.$(dns_zone)"; }
dns_internal_name() { printf '%s\n' "$1.$2.$(dns_zone)"; }
dns_project_name() { printf '%s\n' "$1.$(dns_zone)"; }

# <instance>.<zone> -> public IP.
dns_register_public() { dns_register_record "$(dns_public_name "$1")" "$2"; }
# <instance>.<project>.<zone> -> internal address.
dns_register_internal() { dns_register_record "$(dns_internal_name "$1" "$2")" "$3"; }

# Removes an instance's names: the public one (if it had a public IP) and the
# internal one, whatever address it currently holds.
dns_deregister_instance() {
  local instance="$1" project="$2" public_ip="${3:-}" name ip rc=0
  [[ -z "${public_ip}" ]] || dns_deregister_record "$(dns_public_name "${instance}")" "${public_ip}" || rc=1
  technitium_configured || return "${rc}"
  name="$(dns_internal_name "${instance}" "${project}")"
  while read -r ip; do
    [[ -n "${ip}" ]] && { dns_deregister_record "${name}" "${ip}" || rc=1; }
  done < <(dns_lookup_record_ips "${name}" || true)
  return "${rc}"
}

# An instance's internal IPv4 on its eth0, from its running state, else the
# address pinned on the NIC.
instance_internal_ipv4() {
  local instance="$1" project="$2" ip
  ip="$(incus query "/1.0/instances/${instance}/state?project=${project}" 2>/dev/null \
    | jq -r '.network.eth0.addresses[]? | select(.family == "inet" and .scope == "global") | .address' | head -n1)"
  [[ -n "${ip}" ]] || ip="$(incus query "/1.0/instances/${instance}?project=${project}" 2>/dev/null \
    | jq -r '.expanded_devices.eth0["ipv4.address"] // empty')"
  printf '%s\n' "${ip}"
}

# Adds this site's gateway address to <project>.<zone>, leaving the other
# site's address (same project name) in place.
dns_register_project() { dns_register_record "$(dns_project_name "$1")" "$2" add; }
dns_deregister_project() { dns_deregister_record "$(dns_project_name "$1")" "$2"; }

# All A record addresses of a name, one per line.
dns_lookup_record_ips() {
  local fqdn="$1" response
  technitium_configured || return 1
  response="$(curl -sS -G "${TECHNITIUM_URL%/}/api/zones/records/get" \
    --data-urlencode "token=${TECHNITIUM_API_TOKEN}" \
    --data-urlencode "domain=${fqdn}" \
    --data-urlencode "zone=${TECHNITIUM_ZONE}" \
    --data-urlencode "listZone=false" 2>&1)" || return 1
  [[ "$(jq -r '.status // empty' <<< "${response}" 2>/dev/null)" == 'ok' ]] || return 1
  jq -r '.response.records[]? | select(.type == "A") | .rData.ipAddress // empty' <<< "${response}" 2>/dev/null
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

  echo "Removed DNS record '${fqdn}' -> '${ip}' from Technitium."
  return 0
}
