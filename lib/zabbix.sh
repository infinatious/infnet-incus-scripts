#!/usr/bin/env bash
# Shared Zabbix API helpers: register Incus instances as Zabbix hosts.
# Source this file after loading .env; do not execute it directly.
# Uses ZABBIX_URL, ZABBIX_API_TOKEN, ZABBIX_SITE, ZABBIX_SERVER_IP and
# ZABBIX_PROJECT from .env. All functions are best-effort: Zabbix failures are
# printed as warnings and never abort the calling script.
#
# Each instance becomes a host named after it, in host group
# "Incus/<project>", tagged site/project/env/type and "managed-by:
# infnet-incus-scripts" (only hosts with that tag and this site's tag are
# ever changed or removed). Checks:
#   - ICMP ping, and a TCP check per port the instance's firewall ACL opens to
#     the Zabbix server: run BY the server, against the public IP (or the
#     internal one for instances in the server's own project). Instances
#     without either get no server-side checks.
#   - "Linux by Zabbix agent active" for Linux instances whose agent reports
#     in (installed by the Linux profiles' cloud-init, see
#     monitoring/zabbix-agent-install.sh). Windows agents are set up by hand.

ZABBIX_MANAGED_TAG='infnet-incus-scripts'
ZABBIX_PORT_TAG='acl-port'

zabbix_configured() {
  [[ -n "${ZABBIX_URL:-}" && -n "${ZABBIX_API_TOKEN:-}" && -n "${ZABBIX_SITE:-}" ]]
}

# zabbix_api METHOD PARAMS_JSON: prints .result, or warns and returns 1.
zabbix_api() {
  local method="$1" params="$2" body response
  body="$(jq -nc --arg m "${method}" --argjson p "${params}" '{jsonrpc: "2.0", method: $m, params: $p, id: 1}')" || return 1
  # The server uses a self-signed certificate unless ZABBIX_CA_FILE is set.
  response="$(curl -sS -m 30 ${ZABBIX_CA_FILE:+--cacert "${ZABBIX_CA_FILE}"} ${ZABBIX_CA_FILE:--k} \
    -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer ${ZABBIX_API_TOKEN}" \
    -d "${body}" "${ZABBIX_URL%/}/api_jsonrpc.php" 2>&1)" \
    || { echo "Warning: unable to reach Zabbix at '${ZABBIX_URL}' (${method}): ${response}" >&2; return 1; }
  if jq -e '.error' <<< "${response}" >/dev/null 2>&1; then
    echo "Warning: Zabbix ${method} failed: $(jq -r '.error | "\(.message) \(.data)"' <<< "${response}")" >&2
    return 1
  fi
  jq -c '.result' <<< "${response}"
}

# Host group id for a name, created if missing.
zabbix_group_id() {
  local name="$1" id
  id="$(zabbix_api hostgroup.get "$(jq -nc --arg n "${name}" '{filter: {name: [$n]}, output: ["groupid"]}')" | jq -r '.[0].groupid // empty')"
  [[ -n "${id}" ]] || id="$(zabbix_api hostgroup.create "$(jq -nc --arg n "${name}" '{name: $n}')" | jq -r '.groupids[0] // empty')"
  [[ -n "${id}" ]] && printf '%s\n' "${id}"
}

zabbix_template_id() {
  zabbix_api template.get "$(jq -nc --arg n "$1" '{filter: {host: [$n]}, output: ["templateid"]}')" | jq -r '.[0].templateid // empty'
}

# The managed host of an instance on this site: prints its hostid.
zabbix_host_id() {
  zabbix_api host.get "$(jq -nc --arg h "$1" --arg s "${ZABBIX_SITE}" --arg m "${ZABBIX_MANAGED_TAG}" \
    '{filter: {host: [$h]}, tags: [{tag: "managed-by", value: $m, operator: 1}, {tag: "site", value: $s, operator: 1}], output: ["hostid"]}')" \
    | jq -r '.[0].hostid // empty'
}

# The address the Zabbix server checks an instance on: the internal one in the
# server's own project (hairpin NAT), else the public one, else nothing.
zabbix_check_address() {
  local project="$1" public_ip="$2" internal_ip="$3"
  if [[ -n "${ZABBIX_PROJECT:-}" && "${project}" == "${ZABBIX_PROJECT}" ]]; then
    printf '%s\n' "${internal_ip}"
  else
    printf '%s\n' "${public_ip}"
  fi
}

# TCP ports the instance's ACL lets the Zabbix server reach, one per line:
# single ports (not ranges) of allow rules whose source is anywhere or covers
# ZABBIX_SERVER_IP. In the server's own project every allowed TCP port counts,
# since traffic between instances on one network isn't filtered by source.
zabbix_acl_ports() {
  local instance="$1" project="$2" same_project=0
  [[ -n "${ZABBIX_PROJECT:-}" && "${project}" == "${ZABBIX_PROJECT}" ]] && same_project=1
  incus query "/1.0/network-acls/${instance}?project=${project}" 2>/dev/null \
    | python3 -c '
import ipaddress, json, sys
server, same = sys.argv[1], sys.argv[2] == "1"
acl = json.load(sys.stdin)
ports = set()
for rule in acl.get("ingress") or []:
    if rule.get("action") != "allow" or rule.get("protocol") != "tcp" or rule.get("state") == "disabled":
        continue
    source = (rule.get("source") or "").strip()
    ok = same or not source
    if not ok and server:
        for net in source.split(","):
            try:
                if ipaddress.ip_address(server) in ipaddress.ip_network(net.strip(), strict=False):
                    ok = True
            except ValueError:
                pass
    if not ok:
        continue
    for part in (rule.get("destination_port") or "").split(","):
        part = part.strip()
        if part.isdigit():
            ports.add(int(part))
for port in sorted(ports):
    print(port)
' "${ZABBIX_SERVER_IP:-}" "${same_project}"
}

# Creates or updates an instance's host. Arguments: instance project family
# (linux|win) public_ip internal_ip [agent: yes|no|auto]. With "auto" (the
# default) the Linux agent template is linked for Linux instances.
zabbix_register_instance() {
  local instance="$1" project="$2" family="$3" public_ip="${4:-}" internal_ip="${5:-}" agent="${6:-auto}"
  local address group_id host_id env_code type params templates='[]' tid interfaces tags

  if ! zabbix_configured; then
    echo "Warning: Zabbix is not configured in .env, skipping monitoring for '${instance}'." >&2
    return 0
  fi
  address="$(zabbix_check_address "${project}" "${public_ip}" "${internal_ip}")"
  group_id="$(zabbix_group_id "Incus/${project}")" || return 1

  if [[ -n "${address}" ]]; then
    tid="$(zabbix_template_id 'ICMP Ping')" && [[ -n "${tid}" ]] && templates="$(jq -c --arg t "${tid}" '. + [{templateid: $t}]' <<< "${templates}")"
  fi
  [[ "${agent}" == 'auto' ]] && { [[ "${family}" == 'linux' ]] && agent='yes' || agent='no'; }
  if [[ "${agent}" == 'yes' ]]; then
    tid="$(zabbix_template_id 'Linux by Zabbix agent active')" && [[ -n "${tid}" ]] && templates="$(jq -c --arg t "${tid}" '. + [{templateid: $t}]' <<< "${templates}")"
  fi

  env_code="${instance:0:1}"
  case "${instance}" in *-ct[0-9][0-9]) type='container' ;; *-vs[0-9][0-9]) type='vm' ;; *) type='other' ;; esac
  tags="$(jq -nc --arg s "${ZABBIX_SITE}" --arg p "${project}" --arg e "${env_code}" --arg t "${type}" --arg m "${ZABBIX_MANAGED_TAG}" \
    '[{tag: "site", value: $s}, {tag: "project", value: $p}, {tag: "env", value: $e}, {tag: "type", value: $t}, {tag: "managed-by", value: $m}]')"
  interfaces='[]'
  [[ -n "${address}" ]] && interfaces="$(jq -nc --arg ip "${address}" '[{type: 1, main: 1, useip: 1, ip: $ip, dns: "", port: "10050"}]')"

  host_id="$(zabbix_host_id "${instance}")"
  if [[ -z "${host_id}" ]]; then
    params="$(jq -nc --arg h "${instance}" --arg g "${group_id}" --argjson t "${templates}" --argjson i "${interfaces}" --argjson tags "${tags}" \
      --arg d "Incus ${ZABBIX_SITE} / ${project}${public_ip:+ / public ${public_ip}}${internal_ip:+ / internal ${internal_ip}}" \
      '{host: $h, groups: [{groupid: $g}], templates: $t, interfaces: $i, tags: $tags, description: $d}')"
    host_id="$(zabbix_api host.create "${params}" | jq -r '.hostids[0] // empty')"
    [[ -n "${host_id}" ]] || return 1
    echo "Registered '${instance}' in Zabbix (group Incus/${project}${address:+, checks on ${address}})."
  else
    # Templates are only ever added here, never unlinked: templates someone
    # linked by hand (e.g. a Windows agent) stay.
    params="$(jq -nc --arg id "${host_id}" --arg g "${group_id}" --argjson t "${templates}" --argjson tags "${tags}" \
      '{hostid: $id, groups: [{groupid: $g}], templates: $t, tags: $tags}')"
    zabbix_api host.massadd "$(jq -nc --arg id "${host_id}" --argjson t "${templates}" '{hosts: [{hostid: $id}], templates: $t}')" >/dev/null || return 1
    zabbix_api host.update "$(jq -c 'del(.templates)' <<< "${params}")" >/dev/null || return 1
    zabbix_set_interface "${host_id}" "${address}" || return 1
  fi
  # Containers see the HOST's load average but their own CPU count, so the
  # agent template's per-CPU load trigger fires on busy hosts (false alarms).
  # Their CPU utilisation is per-container and still alerts.
  [[ "${type}" == 'container' ]] && zabbix_set_macro "${host_id}" '{$LOAD_AVG_PER_CPU.MAX.WARN}' '1000' \
    'Containers see the host load average; the per-CPU load trigger is meaningless here'
  zabbix_sync_ports "${instance}" "${project}" "${host_id}"
}

# Creates or updates a host macro.
zabbix_set_macro() {
  local host_id="$1" macro="$2" value="$3" description="${4:-}" existing
  existing="$(zabbix_api usermacro.get "$(jq -nc --arg h "${host_id}" --arg m "${macro}" '{hostids: [$h], filter: {macro: $m}, output: ["hostmacroid", "value"]}')")" || return 1
  if [[ "$(jq -r 'length' <<< "${existing}")" == '0' ]]; then
    zabbix_api usermacro.create "$(jq -nc --arg h "${host_id}" --arg m "${macro}" --arg v "${value}" --arg d "${description}" '{hostid: $h, macro: $m, value: $v, description: $d}')" >/dev/null
  elif [[ "$(jq -r '.[0].value' <<< "${existing}")" != "${value}" ]]; then
    zabbix_api usermacro.update "$(jq -nc --arg id "$(jq -r '.[0].hostmacroid' <<< "${existing}")" --arg v "${value}" '{hostmacroid: $id, value: $v}')" >/dev/null
  fi
}

# Keeps a host's main agent interface on the check address (or removes the
# need for one when there's none; an interface still used by items stays).
zabbix_set_interface() {
  local host_id="$1" address="$2" current
  current="$(zabbix_api hostinterface.get "$(jq -nc --arg h "${host_id}" '{hostids: [$h], filter: {type: 1, main: 1}, output: ["interfaceid", "ip"]}')")" || return 1
  if [[ -z "${address}" ]]; then
    return 0
  elif [[ "$(jq -r 'length' <<< "${current}")" == '0' ]]; then
    zabbix_api hostinterface.create "$(jq -nc --arg h "${host_id}" --arg ip "${address}" '{hostid: $h, type: 1, main: 1, useip: 1, ip: $ip, dns: "", port: "10050"}')" >/dev/null
  elif [[ "$(jq -r '.[0].ip' <<< "${current}")" != "${address}" ]]; then
    zabbix_api hostinterface.update "$(jq -nc --arg id "$(jq -r '.[0].interfaceid' <<< "${current}")" --arg ip "${address}" '{interfaceid: $id, ip: $ip}')" >/dev/null
  fi
}

# Makes the host's TCP port checks match the ACL (minus the host macro
# {$INFNET.SKIP.PORTS}): one simple check
# net.tcp.service[tcp,,PORT] plus a trigger (3 failed checks in a row) per
# port. Arguments: instance project [host_id].
zabbix_sync_ports() {
  local instance="$1" project="$2" host_id="${3:-}" interface_id existing port item_id
  zabbix_configured || return 0
  [[ -n "${host_id}" ]] || host_id="$(zabbix_host_id "${instance}")"
  [[ -n "${host_id}" ]] || return 0
  local -a wanted=()
  # Port checks run from the server, so they need the host's check address.
  interface_id="$(zabbix_api hostinterface.get "$(jq -nc --arg h "${host_id}" '{hostids: [$h], filter: {type: 1, main: 1}, output: ["interfaceid"]}')" | jq -r '.[0].interfaceid // empty')"
  [[ -n "${interface_id}" ]] && mapfile -t wanted < <(zabbix_acl_ports "${instance}" "${project}")
  # Ports listed in the host macro {$INFNET.SKIP.PORTS} (e.g. "443" or
  # "443,8080") are open in the ACL but deliberately not checked.
  local skip
  skip="$(zabbix_api usermacro.get "$(jq -nc --arg h "${host_id}" '{hostids: [$h], filter: {macro: "{$INFNET.SKIP.PORTS}"}, output: ["value"]}')" | jq -r '.[0].value // empty')"
  if [[ -n "${skip}" && ${#wanted[@]} -gt 0 ]]; then
    mapfile -t wanted < <(printf '%s\n' "${wanted[@]}" | grep -vxF -f <(tr ', ' '\n\n' <<< "${skip}" | sed '/^$/d'))
  fi
  existing="$(zabbix_api item.get "$(jq -nc --arg h "${host_id}" --arg t "${ZABBIX_PORT_TAG}" '{hostids: [$h], tags: [{tag: "source", value: $t, operator: 1}], output: ["itemid", "key_"]}')")" || return 1

  # Remove checks for ports no longer open.
  while IFS=$'\t' read -r item_id port; do
    [[ -n "${item_id}" ]] || continue
    if ! printf '%s\n' "${wanted[@]}" | grep -qx "${port}"; then
      zabbix_api item.delete "$(jq -nc --arg i "${item_id}" '[$i]')" >/dev/null && echo "Zabbix: removed the tcp/${port} check from '${instance}'."
    fi
  done < <(jq -r '.[] | select(.key_ | test("^net.tcp.service\\[tcp,,[0-9]+\\]$")) | "\(.itemid)\t\(.key_ | capture("tcp,,(?<p>[0-9]+)").p)"' <<< "${existing}")

  # Add checks for newly opened ports.
  [[ -n "${interface_id}" ]] || return 0
  for port in "${wanted[@]}"; do
    [[ -n "${port}" ]] || continue
    jq -e --arg k "net.tcp.service[tcp,,${port}]" 'any(.[]; .key_ == $k)' <<< "${existing}" >/dev/null && continue
    zabbix_api item.create "$(jq -nc --arg h "${host_id}" --arg i "${interface_id}" --arg p "${port}" --arg t "${ZABBIX_PORT_TAG}" \
      '{hostid: $h, interfaceid: $i, name: ("TCP port " + $p), key_: ("net.tcp.service[tcp,," + $p + "]"), type: 3, value_type: 3, delay: "1m",
        history: "7d", trends: "90d", valuemapid: "0", tags: [{tag: "source", value: $t}, {tag: "component", value: "network"}]}')" >/dev/null || continue
    zabbix_api trigger.create "$(jq -nc --arg h "${instance}" --arg p "${port}" \
      '{description: ("TCP port " + $p + " is not responding on {HOST.NAME}"), priority: 3,
        expression: ("max(/" + $h + "/net.tcp.service[tcp,," + $p + "],#3)=0"),
        tags: [{tag: "scope", value: "availability"}]}')" >/dev/null \
      && echo "Zabbix: added a tcp/${port} check to '${instance}'."
  done
}

# Removes an instance's managed host (with its items and triggers).
zabbix_deregister_instance() {
  local instance="$1" host_id
  if ! zabbix_configured; then
    echo "Warning: Zabbix is not configured in .env, skipping monitoring removal for '${instance}'." >&2
    return 0
  fi
  host_id="$(zabbix_host_id "${instance}")"
  [[ -n "${host_id}" ]] || return 0
  zabbix_api host.delete "$(jq -nc --arg h "${host_id}" '[$h]')" >/dev/null && echo "Removed '${instance}' from Zabbix."
}
