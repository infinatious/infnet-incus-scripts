#!/usr/bin/env bash
# Adds, lists and removes reverse proxy hosts on Nginx Proxy Manager, with the
# matching internal DNS record in Technitium.
#
#   npm-proxy-host.sh --list
#   npm-proxy-host.sh --add --domain app.infinatio.us --forward http://inf-10020.phxaz.infinatio.us:3000 [--websockets] [--max-body 10G] [--no-dns]
#   npm-proxy-host.sh --remove --domain app.infinatio.us [--keep-cert] [--no-dns]
#
# --add:
#   - creates (or reuses) a Let's Encrypt certificate through the Cloudflare DNS
#     challenge, with the same Cloudflare token as the existing certificates;
#   - creates the proxy host: SSL forced, HTTP/2, like the existing hosts;
#   - points <domain> at NPM_DNS_TARGET in the Technitium zone that contains
#     it (e.g. the forwarder zone infinatio.us: only the overridden names
#     answer internally, everything else resolves as it does publicly).
#     --create-zone makes such a forwarder zone when none exists yet.
# Public DNS (Cloudflare) is not touched.
# --remove deletes the proxy host, its certificate (unless another host uses
# it, or --keep-cert) and the DNS record.
# Without arguments it asks what to do (start.sh -> Misc).
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

fail() { echo "Error: $*" >&2; exit 1; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
[[ -f "${REPO_DIR}/.env" ]] || fail "${REPO_DIR}/.env not found."
# shellcheck source=/dev/null
source "${REPO_DIR}/.env"
# shellcheck source=/dev/null
source "${REPO_DIR}/dns/technitium-dns.sh"

ACTION='' DOMAIN='' FORWARD='' WEBSOCKETS=0 MAX_BODY='' DNS=yes KEEP_CERT='' CREATE_ZONE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) ACTION='list'; shift ;;
    --add) ACTION='add'; shift ;;
    --remove) ACTION='remove'; shift ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --forward) FORWARD="${2:-}"; shift 2 ;;
    --websockets) WEBSOCKETS=1; shift ;;
    --max-body) MAX_BODY="${2:-}"; shift 2 ;;
    --no-dns) DNS=''; shift ;;
    --keep-cert) KEEP_CERT=yes; shift ;;
    --create-zone) CREATE_ZONE=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "${NPM_URL:-}" && -n "${NPM_EMAIL:-}" && -n "${NPM_PASSWORD:-}" ]] \
  || fail 'set NPM_URL, NPM_EMAIL and NPM_PASSWORD in .env (an NPM user for these scripts; see README "Reverse proxy").'
command -v jq >/dev/null 2>&1 || fail 'jq not found.'

# --- NPM API -------------------------------------------------------------------------

NPM_TOKEN="$(curl -sS -m 20 -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg i "${NPM_EMAIL}" --arg s "${NPM_PASSWORD}" '{identity: $i, secret: $s}')" \
  "${NPM_URL%/}/api/tokens" | jq -r '.token // empty')"
[[ -n "${NPM_TOKEN}" ]] || fail "unable to log in to NPM at ${NPM_URL} as ${NPM_EMAIL}."

# npm_api METHOD PATH [JSON]: prints the response body; fails on an API error.
npm_api() {
  local method="$1" path="$2" data="${3:-}" response
  response="$(curl -sS -m 300 -X "${method}" -H "Authorization: Bearer ${NPM_TOKEN}" -H 'Content-Type: application/json' \
    ${data:+-d "${data}"} "${NPM_URL%/}/api${path}")" || { echo "Error: NPM ${method} ${path}: unreachable" >&2; return 1; }
  if jq -e 'type == "object" and has("error")' <<< "${response}" >/dev/null 2>&1; then
    echo "Error: NPM ${method} ${path}: $(jq -r '.error.message // .error' <<< "${response}")" >&2
    return 1
  fi
  printf '%s\n' "${response}"
}

# The Cloudflare credentials of the existing DNS-challenge certificates: from
# the API if it returns them, else from NPM's credentials file in its instance.
cloudflare_credentials() {
  local creds id
  creds="$(npm_api GET '/nginx/certificates' | jq -r '[.[] | select(.meta.dns_provider == "cloudflare") | .meta.dns_provider_credentials // empty] | last // empty')"
  if [[ -z "${creds}" && -n "${NPM_INSTANCE:-}" && -n "${NPM_PROJECT:-}" ]]; then
    id="$(npm_api GET '/nginx/certificates' | jq -r '[.[] | select(.meta.dns_provider == "cloudflare") | .id] | max // empty')"
    [[ -n "${id}" ]] && creds="$(incus exec "${NPM_INSTANCE}" --project "${NPM_PROJECT}" -- \
      cat "${NPM_DATA_DIR:-/opt/nginx-proxy-manager}/letsencrypt/credentials/credentials-${id}" 2>/dev/null)"
  fi
  [[ -n "${creds}" ]] || return 1
  printf '%s\n' "${creds}"
}

# --- Technitium ----------------------------------------------------------------------

# The zone holding a name (longest matching suffix), as "<zone>\t<type>".
dns_zone_for() {
  local name="$1"
  curl -sS -G "${TECHNITIUM_URL%/}/api/zones/list" --data-urlencode "token=${TECHNITIUM_API_TOKEN}" \
    | jq -r --arg n "${name}" '[.response.zones[] | select(.name as $z | $n == $z or ($n | endswith("." + $z)))]
      | sort_by(.name | length) | last // empty | "\(.name)\t\(.type)"'
}

# Records can only be changed on the zone's primary node; on a secondary copy
# the request is relayed to it (cluster "node" parameter).
dns_zone_node() {
  local zone="$1" type="$2"
  [[ "${type}" == Secondary* ]] || return 0
  curl -sS -G "${TECHNITIUM_URL%/}/api/zones/records/get" --data-urlencode "token=${TECHNITIUM_API_TOKEN}" \
    --data-urlencode "domain=${zone}" --data-urlencode "zone=${zone}" \
    | jq -r '.response.records[]? | select(.type == "SOA") | .rData.primaryNameServer' | head -n1
}

technitium() {
  local endpoint="$1"; shift
  local response
  response="$(curl -sS -G "${TECHNITIUM_URL%/}/api/${endpoint}" --data-urlencode "token=${TECHNITIUM_API_TOKEN}" "$@")" || return 1
  [[ "$(jq -r '.status' <<< "${response}" 2>/dev/null)" == 'ok' ]] || { echo "Error: Technitium ${endpoint}: $(jq -r '.errorMessage // .' <<< "${response}")" >&2; return 1; }
}

dns_set() {
  local domain="$1" mode="$2" zone_row zone type node
  technitium_configured || { echo 'Warning: Technitium is not configured in .env; skipping DNS.' >&2; return 0; }
  [[ -n "${NPM_DNS_TARGET:-}" ]] || { echo 'Warning: NPM_DNS_TARGET is not set in .env; skipping DNS.' >&2; return 0; }
  zone_row="$(dns_zone_for "${domain}")"
  if [[ -z "${zone_row}" ]]; then
    if [[ "${mode}" == 'add' && -n "${CREATE_ZONE}" ]]; then
      zone="${domain#*.}"
      technitium zones/create --data-urlencode "zone=${zone}" --data-urlencode 'type=Forwarder' \
        --data-urlencode 'forwarder=this-server' --data-urlencode "catalog=${TECHNITIUM_CATALOG_ZONE:-cluster-catalog.dns.infnet}" \
        || return 1
      echo "Created forwarder zone '${zone}' (everything not overridden resolves publicly)."
      zone_row="${zone}"$'\t''Forwarder'
    else
      echo "Warning: no Technitium zone contains '${domain}'; DNS left alone. Use --create-zone with --add to make a forwarder zone." >&2
      return 0
    fi
  fi
  IFS=$'\t' read -r zone type <<< "${zone_row}"
  node="$(dns_zone_node "${zone}" "${type}")"
  if [[ "${mode}" == 'add' ]]; then
    technitium zones/records/add ${node:+--data-urlencode "node=${node}"} --data-urlencode "zone=${zone}" --data-urlencode "domain=${domain}" \
      --data-urlencode 'type=A' --data-urlencode "ipAddress=${NPM_DNS_TARGET}" --data-urlencode 'ttl=300' \
      --data-urlencode 'overwrite=true' --data-urlencode "comments=NPM proxy host (proxy/npm-proxy-host.sh)" \
      && echo "DNS: ${domain} -> ${NPM_DNS_TARGET} in zone '${zone}'."
  else
    technitium zones/records/delete ${node:+--data-urlencode "node=${node}"} --data-urlencode "zone=${zone}" --data-urlencode "domain=${domain}" \
      --data-urlencode 'type=A' --data-urlencode "ipAddress=${NPM_DNS_TARGET}" \
      && echo "DNS: removed ${domain} -> ${NPM_DNS_TARGET} from zone '${zone}'."
  fi
}

# --- Actions -------------------------------------------------------------------------

list_hosts() {
  npm_api GET '/nginx/proxy-hosts' | jq -r '["DOMAIN", "FORWARD TO", "CERT", "ON"], (sort_by(.domain_names[0])[] |
    [(.domain_names | join(",")), "\(.forward_scheme)://\(.forward_host):\(.forward_port)", (.certificate_id | tostring), (if .enabled then "yes" else "no" end)]) | @tsv' \
    | column -t -s $'\t'
}

add_host() {
  local scheme host port existing cert_id creds advanced='' body status
  [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail "invalid domain '${DOMAIN}'."
  [[ "${FORWARD}" =~ ^(https?)://([^:/]+):([0-9]+)/?$ ]] || fail "--forward must look like http://host:port or https://host:port."
  scheme="${BASH_REMATCH[1]}" host="${BASH_REMATCH[2]}" port="${BASH_REMATCH[3]}"

  existing="$(npm_api GET '/nginx/proxy-hosts' | jq -r --arg d "${DOMAIN}" '.[] | select(.domain_names | index($d)) | .id')"
  [[ -z "${existing}" ]] || fail "NPM already has a proxy host for ${DOMAIN} (id ${existing})."

  cert_id="$(npm_api GET '/nginx/certificates' | jq -r --arg d "${DOMAIN}" '[.[] | select(.domain_names | index($d))] | last | .id // empty')"
  if [[ -n "${cert_id}" ]]; then
    echo "Reusing certificate ${cert_id} for ${DOMAIN}."
  else
    creds="$(cloudflare_credentials)" || fail 'no Cloudflare credentials found on the existing certificates (set NPM_INSTANCE/NPM_PROJECT in .env).'
    echo "Requesting a Let's Encrypt certificate for ${DOMAIN} (Cloudflare DNS challenge, ~1 minute)..."
    cert_id="$(npm_api POST '/nginx/certificates' "$(jq -nc --arg d "${DOMAIN}" --arg c "${creds}" \
      '{provider: "letsencrypt", nice_name: $d, domain_names: [$d],
        meta: {dns_challenge: true, dns_provider: "cloudflare", dns_provider_credentials: $c, propagation_seconds: 30}}')" \
      | jq -r '.id // empty')"
    [[ -n "${cert_id}" ]] || fail "certificate request for ${DOMAIN} failed (see above)."
    echo "Certificate ${cert_id} issued."
  fi

  [[ -n "${MAX_BODY}" ]] && advanced="client_max_body_size ${MAX_BODY};"
  body="$(jq -nc --arg d "${DOMAIN}" --arg s "${scheme}" --arg h "${host}" --argjson p "${port}" --argjson c "${cert_id}" \
    --argjson ws "${WEBSOCKETS}" --arg adv "${advanced}" \
    '{domain_names: [$d], forward_scheme: $s, forward_host: $h, forward_port: $p, certificate_id: $c,
      ssl_forced: true, http2_support: true, hsts_enabled: false, hsts_subdomains: false, block_exploits: false,
      caching_enabled: false, allow_websocket_upgrade: ($ws == 1), access_list_id: 0, advanced_config: $adv, meta: {}, locations: []}')"
  existing="$(npm_api POST '/nginx/proxy-hosts' "${body}" | jq -r '.id // empty')"
  [[ -n "${existing}" ]] || fail "creating the proxy host failed (certificate ${cert_id} was kept)."
  echo "Proxy host ${existing}: https://${DOMAIN} -> ${scheme}://${host}:${port}."

  [[ -n "${DNS}" ]] && dns_set "${DOMAIN}" add

  if [[ -n "${NPM_DNS_TARGET:-}" ]]; then
    # NPM reloads nginx in the background, so give the new host a moment.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      status="$(curl -sk -o /dev/null -m 15 -w '%{http_code}' --resolve "${DOMAIN}:443:${NPM_DNS_TARGET}" "https://${DOMAIN}/")"
      [[ "${status}" != '000' ]] && break
      sleep 2
    done
    echo "Check: https://${DOMAIN}/ via ${NPM_DNS_TARGET} answered HTTP ${status}$( [[ "${status}" =~ ^(502|504|000)$ ]] && echo ' - the backend may be unreachable from NPM (firewall group?)')."
  fi
}

remove_host() {
  local host_id cert_id users
  host_id="$(npm_api GET '/nginx/proxy-hosts' | jq -r --arg d "${DOMAIN}" '.[] | select(.domain_names | index($d)) | .id')"
  if [[ -n "${host_id}" ]]; then
    cert_id="$(npm_api GET "/nginx/proxy-hosts/${host_id}" | jq -r '.certificate_id // 0')"
    npm_api DELETE "/nginx/proxy-hosts/${host_id}" >/dev/null || fail "unable to delete proxy host ${host_id}."
    echo "Deleted proxy host ${host_id} (${DOMAIN})."
    if [[ -z "${KEEP_CERT}" && "${cert_id}" != '0' ]]; then
      users="$(npm_api GET '/nginx/proxy-hosts' | jq --argjson c "${cert_id}" '[.[] | select(.certificate_id == $c)] | length')"
      if [[ "${users}" == '0' ]]; then
        npm_api DELETE "/nginx/certificates/${cert_id}" >/dev/null && echo "Deleted certificate ${cert_id}."
      else
        echo "Kept certificate ${cert_id}: ${users} other host(s) use it."
      fi
    fi
  else
    echo "NPM has no proxy host for ${DOMAIN}."
  fi
  [[ -n "${DNS}" ]] && dns_set "${DOMAIN}" remove
}

# --- Main ----------------------------------------------------------------------------

if [[ -z "${ACTION}" ]]; then
  list_hosts
  echo
  read -r -p 'a) Add a proxy host   r) Remove one   Enter = done: ' CHOICE
  case "${CHOICE}" in
    a|A)
      ACTION='add'
      read -r -p 'Domain (e.g. app.infinatio.us): ' DOMAIN
      read -r -p 'Forward to (http://host:port or https://host:port): ' FORWARD
      read -r -p 'Websocket support? [y/N] ' ANSWER; [[ "${ANSWER}" =~ ^[Yy]$ ]] && WEBSOCKETS=1
      read -r -p 'Max upload size (e.g. 10G; Enter = nginx default 1M): ' MAX_BODY ;;
    r|R)
      ACTION='remove'
      read -r -p 'Domain to remove: ' DOMAIN ;;
    *) exit 0 ;;
  esac
fi

case "${ACTION}" in
  list) list_hosts ;;
  add) [[ -n "${DOMAIN}" && -n "${FORWARD}" ]] || fail '--add needs --domain and --forward.'; add_host ;;
  remove) [[ -n "${DOMAIN}" ]] || fail '--remove needs --domain.'; remove_host ;;
esac
