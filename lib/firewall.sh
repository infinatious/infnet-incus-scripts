#!/usr/bin/env bash
# Per-instance inbound firewall helpers (Incus network ACLs).
# Source this file after loading .env and lib/public-ip.sh (it uses
# nat_set_nic); do not execute it directly.
#
# 1:1 NAT forwards every port to the instance, so what is reachable is
# decided here instead: each instance gets its own ACL, named after the
# instance and attached to its NIC. Inbound traffic is rejected except for
# the ACL's rules (ICMP, plus SSH for Linux or RDP for Windows, by default);
# outbound traffic is allowed. OVN ACLs are stateful, and Incus adds baseline rules
# for DHCP, DNS and ping to the network's router, so replies and network
# services keep working. Open more ports for one machine by adding ingress
# rules to its ACL (web UI: Networks > ACLs, or
# `incus network acl rule add <instance> ingress ...`).

# Prints "<port> <service>" for the default inbound rule of a profile family.
fw_default_rule() {
  case "$1" in
    win) echo '3389 RDP' ;;
    *) echo '22 SSH' ;;
  esac
}

# Creates the instance's ACL with its default inbound rules, unless it exists.
# With scope "internal" (instances that have no public IPv4, once routed IPv6
# is on) the IPv4 rules are unchanged but the IPv6 ones only admit
# ipv6_internal_cidrs: routed IPv6 would otherwise make such an instance
# reachable from anywhere, which its missing public IP is meant to prevent.
# IPv4 rules carry the source 0.0.0.0/0 then, so they match IPv4 only.
fw_create_acl() {
  local instance="$1" project="$2" family="$3" scope="${4:-public}" port service internal
  incus network acl show "${instance}" --project "${project}" >/dev/null 2>&1 && return 0
  read -r port service <<< "$(fw_default_rule "${family}")"
  # </dev/null: incus reads YAML from stdin when it is not a terminal.
  incus network acl create "${instance}" --description "Inbound firewall for ${instance}" --project "${project}" </dev/null || return 1
  if [[ "${scope}" == 'internal' ]]; then
    internal="$(ipv6_internal_cidrs)"
    incus network acl rule add "${instance}" ingress action=allow protocol=tcp destination_port="${port}" source=0.0.0.0/0 \
      description="${service}" --project "${project}" || return 1
    incus network acl rule add "${instance}" ingress action=allow protocol=tcp destination_port="${port}" source="${internal}" \
      description="${service} (IPv6, internal)" --project "${project}" || return 1
    incus network acl rule add "${instance}" ingress action=allow protocol=icmp4 description=ICMP --project "${project}" || return 1
    incus network acl rule add "${instance}" ingress action=allow protocol=icmp6 source="${internal}" \
      description="ICMPv6 (internal)" --project "${project}"
    return
  fi
  incus network acl rule add "${instance}" ingress action=allow protocol=tcp destination_port="${port}" \
    description="${service}" --project "${project}" || return 1
  incus network acl rule add "${instance}" ingress action=allow protocol=icmp4 description=ICMP --project "${project}" || return 1
  incus network acl rule add "${instance}" ingress action=allow protocol=icmp6 description=ICMPv6 --project "${project}"
}

# Narrows the default rules of an existing instance's ACL the way
# fw_create_acl "internal" does: the SSH/RDP rule becomes IPv4-only plus an
# internal-only IPv6 twin, and the ICMPv6 rule takes the internal sources.
# Only untouched default rules (matched by description, no source) change;
# anything added by hand stays. Safe to repeat. Prints what it did.
fw_make_ipv6_internal() {
  local instance="$1" project="$2" path acl new internal
  path="/1.0/network-acls/${instance}?project=${project}"
  acl="$(incus query "${path}" 2>/dev/null)" || return 0
  internal="$(ipv6_internal_cidrs)"
  new="$(jq -c --arg internal "${internal}" '
    .ingress | (map(
      if ((.source // "") == "") and (.action == "allow") and (.protocol == "tcp") and ((.description // "") == "SSH" or (.description // "") == "RDP")
        then [(. + {source: "0.0.0.0/0"}), (. + {source: $internal, description: ((.description) + " (IPv6, internal)")})]
      elif ((.source // "") == "") and (.action == "allow") and (.protocol == "icmp6") and ((.description // "") == "ICMPv6")
        then [. + {source: $internal, description: "ICMPv6 (internal)"}]
      else [.] end) | add)' <<< "${acl}")" || return 1
  if [[ "$(jq -c '.ingress' <<< "${acl}")" == "${new}" ]]; then
    return 0
  fi
  incus query -X PUT --data "$(jq -c --argjson ingress "${new}" '{description, config, egress, ingress: $ingress}' <<< "${acl}")" "${path}" >/dev/null \
    || { echo "Error: unable to narrow the IPv6 rules of firewall '${instance}'." >&2; return 1; }
  echo "Firewall '${instance}': IPv6 limited to internal sources (${internal})."
}

# Prints the NIC keys that attach an instance's ACL.
fw_nic_keys() {
  printf '%s\n' "security.acls=$1" 'security.acls.default.ingress.action=reject' 'security.acls.default.egress.action=allow'
}

# Deletes the instance's ACL. Run after the instance is deleted.
fw_delete_acl() {
  local instance="$1" project="$2"
  incus network acl show "${instance}" --project "${project}" >/dev/null 2>&1 || return 0
  incus network acl delete "${instance}" --project "${project}"
}
