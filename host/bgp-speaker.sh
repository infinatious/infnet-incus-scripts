#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOT'
Usage: bgp-speaker.sh install [--dry-run]
       bgp-speaker.sh sync [--dry-run]
       bgp-speaker.sh status

Keeps the upstream router's IPv6 routes to the project networks without any
per-project router config. Incus 7.5 does not announce an OVN project network's
own /64 over BGP, so small FRR instances (the "speakers") do it: each peers with
the router over the uplink and announces every routed project /64 with that
project's OVN router address on the uplink as next hop. Settings come from .env:
  BGP_SPEAKERS      the speaker instances, space separated, as name@project
                    (e.g. 'pd33-bgpsp-ct01@infra-routing pd33-bgpsp-ct02@infra-routing'),
                    created with create-instance.sh (Ubuntu, public IPv4)
  BGP_LOCAL_ASN     the speakers' private AS number (e.g. 65100)
  BGP_PEER_ASN      the router's AS number (e.g. 65000)
  BGP_PEER_ADDRESS  the router's address on the uplink network (e.g. 137.152.224.1)
  BGP_PASSWORD      optional TCP-MD5 password, the same on the router

Actions:
  install  Install FRR in each speaker, enable bgpd and write its base
           configuration (the peering), then sync. BGP_SPEAKER_RESET=1 rewrites
           the base even when one exists.
  sync     Bring the announced prefixes in line with the current project
           networks, adding and removing only what differs; BGP sessions are
           never touched.
           deploy-project.sh and delete-project.sh run it after they change a
           network; running it again is always safe.
  status   Show each speaker's sessions and what it announces.
Option --dry-run prints the configuration instead of applying it.
The router's side is printed by host/bgp-udm-config.sh.
EOT
}

fail() { echo "Error: $*" >&2; exit 1; }

ACTION=''
DRY_RUN=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    install|sync|status) ACTION="$1"; shift ;;
    --dry-run) DRY_RUN='yes'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ -n "${ACTION}" ]] || { usage; exit 1; }

[[ -f "${ENV_FILE}" ]] || fail "${ENV_FILE} not found."
# shellcheck source=/dev/null
source "${ENV_FILE}"
: "${BGP_SPEAKERS:?BGP_SPEAKERS not set in ${ENV_FILE}}"
: "${BGP_LOCAL_ASN:?BGP_LOCAL_ASN not set in ${ENV_FILE}}"
: "${BGP_PEER_ASN:?BGP_PEER_ASN not set in ${ENV_FILE}}"
: "${BGP_PEER_ADDRESS:?BGP_PEER_ADDRESS not set in ${ENV_FILE}}"
[[ "${BGP_LOCAL_ASN}" =~ ^[0-9]+$ && "${BGP_PEER_ASN}" =~ ^[0-9]+$ ]] || fail 'BGP_LOCAL_ASN and BGP_PEER_ASN must be numbers.'
[[ "${BGP_LOCAL_ASN}" != "${BGP_PEER_ASN}" ]] || fail 'BGP_LOCAL_ASN and BGP_PEER_ASN must differ (eBGP).'
command -v incus >/dev/null 2>&1 || fail 'incus command not found in PATH.'
command -v jq >/dev/null 2>&1 || fail 'jq not found.'

# Prints one JSON object per routed project network: its /64 and the OVN
# router's address on the uplink (the next hop the router must use).
collect_prefixes() {
  local project network cfg
  while IFS= read -r project; do
    [[ -n "${project}" ]] || continue
    incus network show "${project}" --project "${project}" >/dev/null 2>&1 || continue
    cfg="$(incus query "/1.0/networks/${project}?project=${project}" 2>/dev/null)" || continue
    jq -c --arg p "${project}" '
      select((.config["ipv6.address"] // "none") | test(":"))
      | select((.config["ipv6.nat"] // "false") != "true")
      | {project: $p, address: .config["ipv6.address"], nexthop: (.config["volatile.network.ipv6.address"] // "")}' <<< "${cfg}"
  done < <(incus project list -f json | jq -r '.[] | select(.description | test("^Project ID: [0-9]+$")) | .name' | sort)
}

# The speaker's base configuration (written once by install): the peering and
# the route-maps that let nothing in and only the listed prefixes out.
base_config() {
  local hostname="$1" router_id="$2" password_line=''
  [[ -z "${BGP_PASSWORD:-}" ]] || password_line=" neighbor ${BGP_PEER_ADDRESS} password ${BGP_PASSWORD}"
  cat <<EOT | sed '/^$/d'
frr defaults traditional
hostname ${hostname}
log syslog informational
service integrated-vtysh-config
!
route-map TO-ROUTER deny 9999
route-map FROM-ROUTER deny 10
!
router bgp ${BGP_LOCAL_ASN}
 bgp router-id ${router_id}
 no bgp default ipv4-unicast
 no bgp network import-check
 neighbor ${BGP_PEER_ADDRESS} remote-as ${BGP_PEER_ASN}
 neighbor ${BGP_PEER_ADDRESS} description router
${password_line}
 !
 address-family ipv6 unicast
  neighbor ${BGP_PEER_ADDRESS} activate
  neighbor ${BGP_PEER_ADDRESS} route-map TO-ROUTER out
  neighbor ${BGP_PEER_ADDRESS} route-map FROM-ROUTER in
 exit-address-family
exit
!
EOT
}

# Prints the vtysh commands that bring a speaker's running configuration (in
# $RUNNING) to the prefixes given on stdin (one JSON object per line): only
# what is missing or stale, so an unchanged speaker gets nothing. Names are
# derived from the subnet (prefix-list P<subnet number>, route-map sequence
# 10 x (subnet number + 1)), so a project keeps its entries when others come
# and go and BGP sessions are never touched.
plan_commands() {
  python3 -c '
import ipaddress, json, os, re, sys
asn = sys.argv[1]
running = os.environ.get("RUNNING", "")
want = {}
for line in sys.stdin:
    if not line.strip():
        continue
    r = json.loads(line)
    if not r["nexthop"]:
        proj = r["project"]
        print(f"Warning: project {proj} has no uplink address yet; not announced.", file=sys.stderr)
        continue
    net = ipaddress.ip_interface(r["address"]).network
    num = (int(net.network_address) >> 64) & 0xFF
    want[str(net)] = (f"P{num}", 10 * (num + 1), r["nexthop"])
have_nets = set(re.findall(r"^\s+network (\S+)", running, re.M))
have_maps = set(int(x) for x in re.findall(r"^route-map TO-ROUTER permit (\d+)", running, re.M))
have_lists = set(re.findall(r"^ipv6 prefix-list (\S+) seq", running, re.M))
cmds = []
want_seqs = {seq for _, seq, _ in want.values()}
want_lists = {name for name, _, _ in want.values()}
# add/update
for net, (name, seq, nh) in sorted(want.items()):
    cmds.append(f"ipv6 prefix-list {name} seq 5 permit {net}")
    cmds += [f"route-map TO-ROUTER permit {seq}", f" match ipv6 address prefix-list {name}", f" set ipv6 next-hop global {nh}", "exit"]
if want:
    cmds += [f"router bgp {asn}", " address-family ipv6 unicast"] + [f"  network {n}" for n in sorted(want)] + [" exit-address-family", "exit"]
# remove stale
stale_nets = sorted(have_nets - set(want))
if stale_nets:
    cmds += [f"router bgp {asn}", " address-family ipv6 unicast"] + [f"  no network {n}" for n in stale_nets] + [" exit-address-family", "exit"]
for seq in sorted(have_maps - want_seqs - {9999}):
    cmds.append(f"no route-map TO-ROUTER permit {seq}")
for name in sorted(have_lists - want_lists):
    cmds.append(f"no ipv6 prefix-list {name}")
print("\n".join(cmds))
' "${BGP_LOCAL_ASN}"
}

# The speaker's router ID: its public IPv4, else its project address.
speaker_router_id() {
  local name="$1" project="$2" ip
  ip="$(incus config get "${name}" user.public_ipv4 --project "${project}" 2>/dev/null || true)"
  [[ -n "${ip}" ]] || ip="$(incus query "/1.0/instances/${name}/state?project=${project}" 2>/dev/null \
    | jq -r '.network.eth0.addresses[]? | select(.family == "inet" and .scope == "global") | .address' | head -n1)"
  printf '%s\n' "${ip}"
}

run_in() { local name="$1" project="$2"; shift 2; incus exec "${name}" --project "${project}" -- "$@" </dev/null; }

install_speaker() {
  local name="$1" project="$2" rid
  incus info "${name}" --project "${project}" >/dev/null 2>&1 || { echo "Error: speaker '${name}' not found in project '${project}'." >&2; return 1; }
  rid="$(speaker_router_id "${name}" "${project}")"
  [[ -n "${rid}" ]] || { echo "Error: ${name} has no IPv4 address yet." >&2; return 1; }
  if [[ -n "${DRY_RUN}" ]]; then
    echo "----- ${name} (router ID ${rid})"; base_config "${name}" "${rid}"; return 0
  fi
  if run_in "${name}" "${project}" dpkg -s frr >/dev/null 2>&1; then
    echo "OK       ${name}: FRR already installed."
  else
    echo "Install  ${name}: FRR..."
    run_in "${name}" "${project}" bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq frr' >/dev/null \
      || { echo "Error: installing FRR in ${name} failed." >&2; return 1; }
  fi
  # The base is written only when this speaker has no BGP peering for the
  # configured ASN/peer yet (or with BGP_SPEAKER_RESET=1); after that, sync
  # changes the running configuration incrementally.
  if [[ -z "${BGP_SPEAKER_RESET:-}" ]] \
    && run_in "${name}" "${project}" grep -q "^router bgp ${BGP_LOCAL_ASN}\$" /etc/frr/frr.conf 2>/dev/null \
    && run_in "${name}" "${project}" grep -q "neighbor ${BGP_PEER_ADDRESS} remote-as ${BGP_PEER_ASN}" /etc/frr/frr.conf 2>/dev/null \
    && run_in "${name}" "${project}" grep -q '^bgpd=yes' /etc/frr/daemons; then
    echo "OK       ${name}: BGP base configuration present."
    return 0
  fi
  echo "Write    ${name}: BGP base configuration, bgpd on, FRR restart."
  run_in "${name}" "${project}" sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
  base_config "${name}" "${rid}" | incus file push - "${name}/etc/frr/frr.conf" --project "${project}" --mode 0640 >/dev/null \
    || { echo "Error: writing frr.conf in ${name} failed." >&2; return 1; }
  run_in "${name}" "${project}" chown frr:frr /etc/frr/frr.conf || true
  run_in "${name}" "${project}" systemctl enable frr >/dev/null 2>&1 || true
  run_in "${name}" "${project}" systemctl restart frr || { echo "Error: starting FRR in ${name} failed." >&2; return 1; }
  sleep 3
}

sync_speaker() {
  local name="$1" project="$2" prefixes="$3" running cmds before after count
  run_in "${name}" "${project}" systemctl is-active --quiet frr \
    || { echo "Error: FRR is not running in ${name}; run: bgp-speaker.sh install" >&2; return 1; }
  running="$(run_in "${name}" "${project}" vtysh -c 'show running-config')" || return 1
  cmds="$(RUNNING="${running}" plan_commands <<< "${prefixes}")" || return 1
  if [[ -n "${DRY_RUN}" ]]; then
    echo "----- ${name}"; printf '%s\n' "${cmds:-(nothing to change)}"; return 0
  fi
  count="$(grep -c '^  network ' <<< "${running}")"
  if [[ -z "${cmds}" ]]; then
    echo "OK       ${name}: ${count} prefixes, unchanged."
    return 0
  fi
  before="$(sha256sum <<< "${running}")"
  printf '%s\n' "${cmds}" \
    | incus file push - "${name}/tmp/bgp-sync.vty" --project "${project}" >/dev/null || return 1
  run_in "${name}" "${project}" vtysh -f /tmp/bgp-sync.vty >/dev/null \
    || { echo "Error: applying the configuration in ${name} failed." >&2; return 1; }
  run_in "${name}" "${project}" vtysh -c 'write memory' >/dev/null || true
  after="$(run_in "${name}" "${project}" vtysh -c 'show running-config' | sha256sum)"
  if [[ "${before}" == "${after}" ]]; then
    echo "OK       ${name}: ${count} prefixes, unchanged."
  else
    echo "Updated  ${name}: $(run_in "${name}" "${project}" vtysh -c 'show running-config' | grep -c '^  network ') prefixes (sessions untouched)."
  fi
}

PREFIXES="$(collect_prefixes)"
RC=0
for spec in ${BGP_SPEAKERS}; do
  name="${spec%@*}"; project="${spec#*@}"
  [[ "${spec}" == *@* && -n "${name}" && -n "${project}" ]] || { echo "Error: BGP_SPEAKERS entry '${spec}' is not name@project." >&2; RC=1; continue; }
  case "${ACTION}" in
    install) { install_speaker "${name}" "${project}" && sync_speaker "${name}" "${project}" "${PREFIXES}"; } || RC=1 ;;
    sync) sync_speaker "${name}" "${project}" "${PREFIXES}" || RC=1 ;;
    status)
      echo "===== ${name}"
      run_in "${name}" "${project}" vtysh -c 'show bgp summary' 2>&1 | sed -n '1,14p'
      run_in "${name}" "${project}" vtysh -c 'show bgp ipv6 unicast' 2>&1 | sed -n '1,40p' ;;
  esac
done
exit "${RC}"
