#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: firewall-manager.sh [--project-id ID --instance NAME] [ACTION]

Lists and edits an instance's inbound firewall: the network ACL named after
the instance that create-instance.sh attaches to its NIC (inbound is rejected
unless a rule allows it; outbound is open). Changes apply immediately.
Without an action it's interactive: pick the project and instance, then add
or remove rules from a menu.

Actions:
  --list                    Show the inbound rules.
  --add PROTO[:PORTS]       Allow inbound traffic. PROTO is tcp, udp, both
                            (tcp and udp), icmp4 or icmp6; PORTS is a port,
                            range or list for tcp/udp, e.g. tcp:443,
                            udp:27015-27030, both:53.
    --source CIDR[,CIDR]    Only from these addresses (default: anywhere).
                            "infnet" means 10.100.0.0/16.
    --description TEXT      Rule description (default: the protocol and ports).
  --remove N                Remove inbound rule number N (as shown by --list).

Examples:
  ./firewall-manager.sh
  ./firewall-manager.sh --project-id 23 --instance pd23-mcrft-ct01 --list
  ./firewall-manager.sh --project-id 23 --instance pd23-mcrft-ct01 --add tcp:8443 --source infnet --description Crafty
  ./firewall-manager.sh --project-id 23 --instance pd23-mcrft-ct01 --remove 5
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

INFNET_CIDR='10.100.0.0/16'
PROJECT_ID_ARG=''
INSTANCE_ARG=''
ACTION=''
ADD_SPEC=''
SOURCE_ARG=''
DESCRIPTION_ARG=''
REMOVE_ARG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) [[ $# -ge 2 ]] || fail 'missing value for --project-id.'; PROJECT_ID_ARG="$2"; shift 2 ;;
    --instance) [[ $# -ge 2 ]] || fail 'missing value for --instance.'; INSTANCE_ARG="$2"; shift 2 ;;
    --list) ACTION='list'; shift ;;
    --add) [[ $# -ge 2 ]] || fail 'missing value for --add.'; ACTION='add'; ADD_SPEC="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || fail 'missing value for --source.'; SOURCE_ARG="$2"; shift 2 ;;
    --description) [[ $# -ge 2 ]] || fail 'missing value for --description.'; DESCRIPTION_ARG="$2"; shift 2 ;;
    --remove) [[ $# -ge 2 ]] || fail 'missing value for --remove.'; ACTION='remove'; REMOVE_ARG="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

command -v incus >/dev/null 2>&1 || fail 'incus command not found in PATH.'
command -v jq >/dev/null 2>&1 || fail 'jq not found.'

# --- Project and instance -------------------------------------------------------

mapfile -t PROJECT_ROWS < <(incus project list -f json \
  | jq -r '.[] | select(.description | test("^Project ID: [0-9]+$")) | "\(.description | ltrimstr("Project ID: "))\t\(.name)"' | sort -n)
(( ${#PROJECT_ROWS[@]} > 0 )) || fail 'no managed projects (described "Project ID: N") found.'

if [[ -z "${PROJECT_ID_ARG}" ]]; then
  echo 'Projects:'
  printf '  %s\n' "${PROJECT_ROWS[@]/$'\t'/)  }"
  read -r -p 'Choose project ID: ' PROJECT_ID_ARG
fi
PROJECT_NAME=''
for row in "${PROJECT_ROWS[@]}"; do
  [[ "${row%%$'\t'*}" == "${PROJECT_ID_ARG}" ]] && PROJECT_NAME="${row#*$'\t'}"
done
[[ -n "${PROJECT_NAME}" ]] || fail "no project with ID '${PROJECT_ID_ARG}'."

if [[ -z "${INSTANCE_ARG}" ]]; then
  mapfile -t INSTANCE_ROWS < <(incus list --project "${PROJECT_NAME}" -f json \
    | jq -r '.[] | "\(.name)\t\(.status)\t\(.config["user.public_ipv4"] // "-")"' | sort)
  (( ${#INSTANCE_ROWS[@]} > 0 )) || fail "project '${PROJECT_NAME}' has no instances."
  echo "Instances in ${PROJECT_NAME}:"
  for i in "${!INSTANCE_ROWS[@]}"; do
    IFS=$'\t' read -r name state ip <<< "${INSTANCE_ROWS[i]}"
    printf '  %2d) %-24s %-8s public IP %s\n' "$(( i + 1 ))" "${name}" "${state}" "${ip}"
  done
  read -r -p 'Choose instance number: ' INDEX
  [[ "${INDEX}" =~ ^[0-9]+$ ]] && (( INDEX >= 1 && INDEX <= ${#INSTANCE_ROWS[@]} )) || fail 'invalid instance number.'
  INSTANCE_ARG="${INSTANCE_ROWS[INDEX - 1]%%$'\t'*}"
fi
INSTANCE="${INSTANCE_ARG}"
incus info "${INSTANCE}" --project "${PROJECT_NAME}" >/dev/null 2>&1 || fail "instance '${INSTANCE}' not found in project '${PROJECT_NAME}'."

ACL_PATH="/1.0/network-acls/${INSTANCE}?project=${PROJECT_NAME}"
incus query "${ACL_PATH}" >/dev/null 2>&1 \
  || fail "instance '${INSTANCE}' has no firewall ACL named after it (instances made by create-instance.sh get one)."

# The ACL only filters traffic if the instance's NIC references it.
ATTACHED="$(incus query "/1.0/instances/${INSTANCE}?project=${PROJECT_NAME}" \
  | jq -r --arg a "${INSTANCE}" '[.expanded_devices[]? | select(.type == "nic") | (."security.acls" // "") | split(",")[]] | index($a) != null')"
[[ "${ATTACHED}" == 'true' ]] || echo "Warning: ACL '${INSTANCE}' isn't attached to any NIC of '${INSTANCE}', so these rules have no effect." >&2

# --- Rules -----------------------------------------------------------------------

show_rules() {
  echo
  echo "Inbound firewall for ${INSTANCE} (project ${PROJECT_NAME}); anything not listed is rejected:"
  incus query "${ACL_PATH}" | jq -r '
    .ingress | to_entries[] |
    "\(.key + 1)\t\(.value.protocol // "any")\t\(.value.destination_port // "-")\t\(.value.source // "anywhere")\t\(.value.action)\(if (.value.state // "enabled") != "enabled" then " (" + .value.state + ")" else "" end)\t\(.value.description // "")"' \
    | awk -F'\t' 'BEGIN {printf "  %-3s %-6s %-18s %-22s %-8s %s\n", "#", "PROTO", "PORTS", "SOURCE", "ACTION", "DESCRIPTION"}
                  {printf "  %-3s %-6s %-18s %-22s %-8s %s\n", $1, $2, $3, $4, $5, $6}'
}

# Replaces the ACL's ingress list with the JSON array in $1.
put_ingress() {
  local acl
  acl="$(incus query "${ACL_PATH}" | jq --argjson ingress "$1" '{description, config, egress, ingress: $ingress}')"
  incus query -X PUT --data "${acl}" "${ACL_PATH}" >/dev/null
}

add_rules() {
  local proto="$1" ports="$2" source="$3" description="$4" protocols new
  case "${proto}" in
    tcp|udp) protocols="${proto}" ;;
    both) protocols='tcp udp' ;;
    icmp4|icmp6) protocols="${proto}"; [[ -z "${ports}" ]] || fail "${proto} rules don't take ports." ;;
    *) fail "unknown protocol '${proto}' (tcp, udp, both, icmp4, icmp6)." ;;
  esac
  if [[ "${proto}" != icmp* ]]; then
    [[ "${ports}" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || fail "invalid ports '${ports}' (e.g. 443, 8000-8100, 80,443)."
  fi
  [[ "${source,,}" == 'infnet' ]] && source="${INFNET_CIDR}"
  [[ -n "${description}" ]] || description="${proto}${ports:+ ${ports}}"
  new="$(incus query "${ACL_PATH}" | jq -c --arg protos "${protocols}" --arg ports "${ports}" --arg source "${source}" --arg desc "${description}" '
    .ingress + [($protos | split(" "))[] | {action: "allow", protocol: ., description: $desc, state: "enabled"}
      + (if $ports != "" then {destination_port: $ports} else {} end)
      + (if $source != "" then {source: $source} else {} end)]')"
  put_ingress "${new}" || fail 'Incus rejected the rule (check the ports and source).'
  echo "Added: allow ${protocols// /+}${ports:+ ${ports}} from ${source:-anywhere} (${description})."
}

remove_rule() {
  local number="$1" count rule new
  count="$(incus query "${ACL_PATH}" | jq '.ingress | length')"
  [[ "${number}" =~ ^[0-9]+$ ]] && (( number >= 1 && number <= count )) || fail "no inbound rule number '${number}' (1-${count})."
  rule="$(incus query "${ACL_PATH}" | jq -c --argjson i "$(( number - 1 ))" '.ingress[$i]')"
  new="$(incus query "${ACL_PATH}" | jq -c --argjson i "$(( number - 1 ))" '.ingress | del(.[$i])')"
  put_ingress "${new}" || fail 'Incus rejected the change.'
  echo "Removed rule ${number}: $(jq -r '"\(.protocol // "any") \(.destination_port // "") from \(.source // "anywhere") (\(.description // ""))"' <<< "${rule}")."
}

# Removing the SSH/RDP rule can cut off remote access; ask first in the menu.
confirm_remove() {
  local number="$1" port answer
  port="$(incus query "${ACL_PATH}" | jq -r --argjson i "$(( number - 1 ))" '.ingress[$i].destination_port // ""')"
  if [[ ",${port}," == *,22,* || ",${port}," == *,3389,* ]]; then
    read -r -p "Rule ${number} allows SSH/RDP; removing it may cut off remote access. Remove it? [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || return 1
  fi
}

case "${ACTION}" in
  list) show_rules; exit 0 ;;
  add)
    add_rules "${ADD_SPEC%%:*}" "$( [[ "${ADD_SPEC}" == *:* ]] && echo "${ADD_SPEC#*:}" )" "${SOURCE_ARG}" "${DESCRIPTION_ARG}"
    show_rules; exit 0 ;;
  remove) remove_rule "${REMOVE_ARG}"; show_rules; exit 0 ;;
esac

# --- Interactive -------------------------------------------------------------------

while true; do
  show_rules
  echo
  echo '  a) Add a rule    r) Remove a rule    d) Done'
  read -r -p 'Choose: ' CHOICE || { echo; exit 0; }
  case "${CHOICE}" in
    a|A)
      read -r -p 'Protocol (tcp, udp, both, icmp4, icmp6) [tcp]: ' PROTO; PROTO="${PROTO:-tcp}"
      PORTS=''
      [[ "${PROTO}" == icmp* ]] || read -r -p 'Ports (e.g. 443, 8000-8100, 80,443): ' PORTS
      read -r -p "Allow from: Enter = anywhere, i = INFNET (${INFNET_CIDR}), or CIDR[,CIDR]: " SOURCE
      [[ "${SOURCE}" == [iI] ]] && SOURCE='infnet'
      read -r -p 'Description: ' DESCRIPTION
      ( add_rules "${PROTO}" "${PORTS}" "${SOURCE}" "${DESCRIPTION}" ) ;;
    r|R)
      read -r -p 'Rule number to remove: ' NUMBER
      if [[ "${NUMBER}" =~ ^[0-9]+$ ]] && confirm_remove "${NUMBER}"; then
        ( remove_rule "${NUMBER}" )
      else
        echo 'Not removed.'
      fi ;;
    d|D|'') exit 0 ;;
    *) echo "Invalid choice '${CHOICE}'." ;;
  esac
done
