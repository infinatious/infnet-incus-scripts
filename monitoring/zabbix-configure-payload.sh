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
#   - Frontend URL (Administration > General > Other) and the global macro
#     {$ZABBIX.URL}: webhook media types like Discord link back to the problem
#     with it and fail without it.
# Environment: DISCORD_WEBHOOK (optional; Discord is left alone without it),
# FRONTEND_URL (e.g. https://pd25-zabbx-ct01.infnet/).
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

# Logs in again before each section: some changes (e.g. to Admin's own
# media) end the current session, and the next call then fails.
login() {
  AUTH=''
  AUTH="$(api user.login "$(jq -nc --arg p "$(cat /root/zabbix/admin-password)" '{username: "Admin", password: $p}')" | jq -r '.')"
}

# --- Frontend URL ---
login
if [[ -n "${FRONTEND_URL:-}" ]]; then
  api settings.update "$(jq -nc --arg u "${FRONTEND_URL}" '{url: $u}')" >/dev/null
  # The webhook media types (Discord, Mattermost, ...) read it from the global
  # macro {$ZABBIX.URL}, not from the setting.
  MACRO_ID="$(api usermacro.get '{"globalmacro":true,"filter":{"macro":"{$ZABBIX.URL}"},"output":["globalmacroid"]}' | jq -r '.[0].globalmacroid // empty')"
  if [[ -n "${MACRO_ID}" ]]; then
    api usermacro.updateglobal "$(jq -nc --arg id "${MACRO_ID}" --arg u "${FRONTEND_URL}" '{globalmacroid: $id, value: $u}')" >/dev/null
  else
    api usermacro.createglobal "$(jq -nc --arg u "${FRONTEND_URL}" '{macro: "{$ZABBIX.URL}", value: $u, description: "Frontend URL for webhook media types"}')" >/dev/null
  fi
  echo "Frontend URL (and {\$ZABBIX.URL}) set to ${FRONTEND_URL}."
fi

# --- Discord ---
login
if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
  # Zabbix's Discord script calls /api/v10/..., which the legacy
  # discordapp.com host rejects ("Invalid API version"); discord.com accepts it.
  DISCORD_WEBHOOK="${DISCORD_WEBHOOK/\/\/discordapp.com\//\/\/discord.com\/}"
  MT="$(api mediatype.get '{"filter":{"name":["Discord"]},"output":["mediatypeid","status"]}' | jq -r '.[0].mediatypeid')"
  api mediatype.update "$(jq -nc --arg id "${MT}" '{mediatypeid: $id, status: 0}')" >/dev/null
  ADMIN_ID="$(api user.get '{"filter":{"username":["Admin"]},"output":["userid"]}' | jq -r '.[0].userid')"
  # Severity bitmask: Warning 4 + Average 8 + High 16 + Disaster 32.
  api user.update "$(jq -nc --arg u "${ADMIN_ID}" --arg mt "${MT}" --arg to "${DISCORD_WEBHOOK}" \
    '{userid: $u, medias: [{mediatypeid: $mt, sendto: $to, active: 0, severity: 60, period: "1-7,00:00-24:00"}]}')" >/dev/null
  # Only actual issues reach Discord:
  #   - severity Average and up (condition type 4 = trigger severity,
  #     operator 5 = ">=", value 3 = Average); Warning-level problems stay in
  #     the web UI only;
  #   - only problems still open after 5 minutes (the message is escalation
  #     step 2 of 5-minute steps), so short blips never notify;
  #   - recoveries go only to whoever got the problem ("notify all involved").
  #   - Problems in maintenance are suppressed (pause_suppressed).
  ACTION_JSON="$(api action.get '{"filter":{"name":["Report problems to Zabbix administrators"]},"output":["actionid"],"selectOperations":"extend"}')"
  ACTION="$(jq -r '.[0].actionid' <<< "${ACTION_JSON}")"
  OPS="$(jq -c '[.[0].operations[] | del(.operationid, .actionid) | .esc_step_from = "2" | .esc_step_to = "2" | .esc_period = "0"
    | (if .opmessage then .opmessage |= del(.operationid) else . end)
    | (if .opmessage_grp then .opmessage_grp |= map({usrgrpid}) else . end)
    | (if .opmessage_usr then .opmessage_usr |= map({userid}) else . end)]' <<< "${ACTION_JSON}")"
  api action.update "$(jq -nc --arg a "${ACTION}" --argjson ops "${OPS}" '{actionid: $a, status: 0, esc_period: "5m", pause_suppressed: 1,
    filter: {evaltype: 0, conditions: [{conditiontype: 4, operator: 5, value: "3"}]},
    operations: $ops, recovery_operations: [{operationtype: 11, opmessage: {default_msg: 1}}]}')" >/dev/null
  echo "Discord: media type enabled; Admin notified for Average and up, after 5 minutes; recoveries only for notified problems."
fi

# --- Host group for instances ---
login
api hostgroup.get '{"filter":{"name":["Incus"]},"output":["groupid"]}' | jq -e 'length > 0' >/dev/null \
  || api hostgroup.create '{"name":"Incus"}' >/dev/null
echo "Host group 'Incus' present."

# --- API user and token for the scripts ---
login
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
