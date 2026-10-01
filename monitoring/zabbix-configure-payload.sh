#!/bin/bash
# Runs INSIDE the Zabbix container, pushed there by zabbix-configure.sh.
# Idempotent. Uses the Admin password from /root/zabbix/admin-password.
#   - Discord: enables the built-in "Discord" media type, gives Admin a Discord
#     media (the webhook URL, severities Warning and up) and enables the
#     default "Report problems to Zabbix administrators" action, limited to
#     Warning and up.
#   - API user "svc-infnet-incus" (Super admin role, no frontend access) with
#     token "infnet-incus-scripts" for the repo's scripts. A new token is only
#     generated when none exists; it is stored root-only in
#     /root/zabbix/api-token, where zabbix-configure.sh reads it.
# Environment: DISCORD_WEBHOOK (optional; Discord is left alone without it).
set -euo pipefail

URL='https://127.0.0.1/api_jsonrpc.php'
api() {
  local response
  response="$(curl -sk -H 'Content-Type: application/json-rpc' ${AUTH:+-H "Authorization: Bearer ${AUTH}"} \
    -d "$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc: "2.0", method: $m, params: $p, id: 1}')" "${URL}")"
  if jq -e '.error' <<< "${response}" >/dev/null; then
    echo "Error: $1: $(jq -r '.error | "\(.message) \(.data)"' <<< "${response}")" >&2
    return 1
  fi
  jq -c '.result' <<< "${response}"
}

AUTH=''
AUTH="$(api user.login "$(jq -nc --arg p "$(cat /root/zabbix/admin-password)" '{username: "Admin", password: $p}')" | jq -r '.')"

# --- Discord ---
if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
  MT="$(api mediatype.get '{"filter":{"name":["Discord"]},"output":["mediatypeid","status"]}' | jq -r '.[0].mediatypeid')"
  api mediatype.update "$(jq -nc --arg id "${MT}" '{mediatypeid: $id, status: 0}')" >/dev/null
  ADMIN_ID="$(api user.get '{"filter":{"username":["Admin"]},"output":["userid"]}' | jq -r '.[0].userid')"
  # Severity bitmask: Warning 4 + Average 8 + High 16 + Disaster 32.
  api user.update "$(jq -nc --arg u "${ADMIN_ID}" --arg mt "${MT}" --arg to "${DISCORD_WEBHOOK}" \
    '{userid: $u, medias: [{mediatypeid: $mt, sendto: $to, active: 0, severity: 60, period: "1-7,00:00-24:00"}]}')" >/dev/null
  ACTION="$(api action.get '{"filter":{"name":["Report problems to Zabbix administrators"]},"output":["actionid"]}' | jq -r '.[0].actionid')"
  # Condition type 4 = trigger severity, operator 5 = ">=", value 2 = Warning.
  api action.update "$(jq -nc --arg a "${ACTION}" '{actionid: $a, status: 0, filter: {evaltype: 0, conditions: [{conditiontype: 4, operator: 5, value: "2"}]}}')" >/dev/null
  echo "Discord: media type enabled, Admin notified for Warning and up, action enabled."
fi

# --- Host group for instances ---
api hostgroup.get '{"filter":{"name":["Incus"]},"output":["groupid"]}' | jq -e 'length > 0' >/dev/null \
  || api hostgroup.create '{"name":"Incus"}' >/dev/null
echo "Host group 'Incus' present."

# --- API user and token for the scripts ---
SVC_ID="$(api user.get '{"filter":{"username":["svc-infnet-incus"]},"output":["userid"]}' | jq -r '.[0].userid // empty')"
if [[ -z "${SVC_ID}" ]]; then
  ROLE="$(api role.get '{"filter":{"name":["Super admin role"]},"output":["roleid"]}' | jq -r '.[0].roleid')"
  GROUP="$(api usergroup.get '{"filter":{"name":["No access to the frontend"]},"output":["usrgrpid"]}' | jq -r '.[0].usrgrpid')"
  SVC_ID="$(api user.create "$(jq -nc --arg r "${ROLE}" --arg g "${GROUP}" --arg p "$(openssl rand -base64 30 | tr -d '/+=')" \
    '{username: "svc-infnet-incus", name: "infnet-incus-scripts", passwd: $p, roleid: $r, usrgrps: [{usrgrpid: $g}]}')" | jq -r '.userids[0]')"
  echo "Created API user svc-infnet-incus."
fi
TOKEN_ID="$(api token.get "$(jq -nc --arg u "${SVC_ID}" '{userids: [$u], filter: {name: ["infnet-incus-scripts"]}, output: ["tokenid"]}')" | jq -r '.[0].tokenid // empty')"
if [[ -z "${TOKEN_ID}" ]]; then
  TOKEN_ID="$(api token.create "$(jq -nc --arg u "${SVC_ID}" '{name: "infnet-incus-scripts", userid: $u, description: "infnet-incus-scripts: create/delete-instance.sh, monitoring/sync-zabbix-hosts.sh"}')" | jq -r '.tokenids[0]')"
  TOKEN="$(api token.generate "$(jq -nc --arg t "${TOKEN_ID}" '[$t]')" | jq -r '.[0].token')"
  install -m 600 /dev/null /root/zabbix/api-token
  printf '%s\n' "${TOKEN}" > /root/zabbix/api-token
  echo "Generated API token 'infnet-incus-scripts' (stored in /root/zabbix/api-token)."
else
  echo "API token 'infnet-incus-scripts' already exists (stored in /root/zabbix/api-token)."
fi
