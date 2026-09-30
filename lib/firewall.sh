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
fw_create_acl() {
  local instance="$1" project="$2" family="$3" port service
  incus network acl show "${instance}" --project "${project}" >/dev/null 2>&1 && return 0
  read -r port service <<< "$(fw_default_rule "${family}")"
  # </dev/null: incus reads YAML from stdin when it is not a terminal.
  incus network acl create "${instance}" --description "Inbound firewall for ${instance}" --project "${project}" </dev/null || return 1
  incus network acl rule add "${instance}" ingress action=allow protocol=tcp destination_port="${port}" \
    description="${service}" --project "${project}" || return 1
  incus network acl rule add "${instance}" ingress action=allow protocol=icmp4 description=ICMP --project "${project}" || return 1
  incus network acl rule add "${instance}" ingress action=allow protocol=icmp6 description=ICMPv6 --project "${project}"
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
