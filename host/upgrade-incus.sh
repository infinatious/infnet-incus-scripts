#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SELF="${ROOT_DIR}/host/upgrade-incus.sh"
UEFI="${ROOT_DIR}/branding/uefi-logo.sh"
UEFI_BUILD_DIR="${ROOT_DIR}/branding/assets/uefi"

usage() {
  cat <<'EOF'
Usage: upgrade-incus.sh [--check] [--yes]

Upgrades the Incus packages (Zabbly) on every member of this host's cluster,
one member at a time (a standalone server is just this host), then fixes up
the Infinatious UEFI boot logo. Run it as your normal user on any member; it
uses sudo locally and `ssh -t` + sudo on the other members, so expect a sudo
password prompt per host where sudo needs one.

  1. Compares each member's installed incus package with the newest one the
     repository offers. Stops if every member is current.
  2. Upgrades the other members first and this host last. Instances keep
     running: restarting the Incus daemon doesn't stop containers or VMs. An
     upgraded member waits for the rest before serving the cluster API again,
     so all members are upgraded in one go.
  3. Boot logo: the package hooks re-apply the UI branding and, when the new
     package ships the same VM firmware, the Infinatious firmware. If it ships
     new firmware, the logo is rebuilt once here (needs the upgraded cluster,
     ~10 minutes), copied to the members that had it, and applied there.
     Members that never had the logo applied are left alone.

Running VMs keep their old QEMU and firmware until they are restarted.

Options:
  --check   Only report installed and available versions; change nothing.
  --yes     Don't ask for confirmation before upgrading.
  --help    Show this help message.

Every member needs this repository at the same path and SSH access from this
host (the members' cluster addresses are used).
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

# --- Per-member part, run as root on each member -------------------------------

# Installed incus* packages that come from the Zabbly repository.
local_incus_packages() {
  dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'incus*' 2>/dev/null | awk '$1 == "installed" {print $2}'
}

local_upgrade() {
  local packages=() before after
  (( EUID == 0 )) || fail '--local needs root.'
  mapfile -t packages < <(local_incus_packages)
  (( ${#packages[@]} > 0 )) || fail 'no incus packages are installed here.'
  before="$(dpkg-query -W -f='${Version}' incus)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --only-upgrade "${packages[@]}" >/dev/null
  after="$(dpkg-query -W -f='${Version}' incus)"
  systemctl is-active --quiet incus || systemctl start incus
  echo "$(hostname -s): incus ${before} -> ${after} (${packages[*]})"
}

# --- Orchestration -----------------------------------------------------------

CHECK_ONLY=''
ASSUME_YES=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) shift; local_upgrade; exit 0 ;;
    --check) CHECK_ONLY='yes'; shift ;;
    --yes|-y) ASSUME_YES='yes'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

(( EUID != 0 )) || fail 'run this as your normal user (it uses sudo and ssh itself).'
command -v incus >/dev/null 2>&1 || fail 'incus command not found.'
command -v jq >/dev/null 2>&1 || fail 'jq not found.'

# Members as "name address", with this host's own member last.
LOCAL_NAME="$(incus query /1.0 | jq -r '.environment.server_name')"
MEMBERS=()
if [[ "$(incus query /1.0 | jq -r '.environment.server_clustered')" == 'true' ]]; then
  while read -r name url; do
    address="${url#https://}"; address="${address%:*}"; address="${address#[}"; address="${address%]}"
    [[ "${name}" == "${LOCAL_NAME}" ]] || MEMBERS+=("${name} ${address}")
  done < <(incus cluster list -f json | jq -r '.[] | "\(.server_name) \(.url)"')
fi
MEMBERS+=("${LOCAL_NAME} local")

# Runs a command on a member: directly for this host, over ssh for the others.
on_member() {
  local address="$1"; shift
  if [[ "${address}" == 'local' ]]; then
    bash -c "$*"
  else
    ssh -t -o ConnectTimeout=10 "${address}" "$*"
  fi
}

step 'Available version'
sudo apt-get update -qq
CANDIDATE="$(apt-cache policy incus | awk '/Candidate:/ {print $2}')"
[[ -n "${CANDIDATE}" && "${CANDIDATE}" != '(none)' ]] || fail 'apt has no incus candidate (is the Zabbly repository configured?).'
echo "Newest incus package: ${CANDIDATE}"

step 'Installed versions'
NEEDS=()
for entry in "${MEMBERS[@]}"; do
  read -r name address <<< "${entry}"
  installed="$(on_member "${address}" "dpkg-query -W -f='\${Version}' incus; test -x '${SELF}' || echo ' NO-SCRIPT'" 2>/dev/null | tr -d '\r')" \
    || fail "cannot reach member '${name}' (${address}) over ssh."
  [[ "${installed}" == *NO-SCRIPT* ]] && fail "member '${name}' has no ${SELF}; clone the repository there first."
  if [[ "${installed}" == "${CANDIDATE}" ]]; then
    printf '  %-16s %s (current)\n' "${name}" "${installed}"
  else
    printf '  %-16s %s -> %s\n' "${name}" "${installed}" "${CANDIDATE}"
    NEEDS+=("${entry}")
  fi
done

if (( ${#NEEDS[@]} == 0 )); then
  echo
  echo 'Every member is current; nothing to do.'
  exit 0
fi
[[ -n "${CHECK_ONLY}" ]] && exit 0

if [[ -z "${ASSUME_YES}" ]]; then
  echo
  read -r -p "Upgrade ${#NEEDS[@]} member(s), this host last? Instances keep running. [y/N] " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || { echo 'Cancelled.'; exit 0; }
fi

for entry in "${NEEDS[@]}"; do
  read -r name address <<< "${entry}"
  step "Upgrading ${name}"
  if [[ "${address}" == 'local' ]]; then
    sudo "${SELF}" --local
  else
    on_member "${address}" "sudo '${SELF}' --local" || fail "upgrade failed on '${name}'; fix it and re-run (members already done are skipped)."
  fi
done

step 'Waiting for the cluster to come back'
sudo incus admin waitready --timeout 600 || fail 'Incus did not become ready within 10 minutes; check `journalctl -u incus` on each member.'
incus cluster list 2>/dev/null || true

# Boot logo. Members where it was applied keep a state directory; only those are touched.
step 'UEFI boot logo'
LOGO_MEMBERS=()
for entry in "${MEMBERS[@]}"; do
  read -r name address <<< "${entry}"
  status="$(on_member "${address}" "test -d /var/lib/infnet-uefi-logo && '${UEFI}' status || echo 'not applied'" 2>/dev/null | tr -d '\r' | tail -n1)"
  printf '  %-16s %s\n' "${name}" "${status}"
  [[ "${status}" == 'not applied' ]] || LOGO_MEMBERS+=("${entry}|${status}")
done

REBUILD=''
for item in "${LOGO_MEMBERS[@]}"; do
  case "${item#*|}" in
    Installed:\ Infinatious*) ;;
    # Same firmware build as before, the hook just hasn't run: re-apply, no rebuild.
    *'APT hook will re-apply'*)
      read -r name address <<< "${item%%|*}"
      on_member "${address}" "sudo '${UEFI}' reapply" ;;
    *) REBUILD='yes' ;;
  esac
done

if (( ${#LOGO_MEMBERS[@]} == 0 )); then
  echo 'No member uses the custom boot logo; nothing to do.'
elif [[ -z "${REBUILD}" ]]; then
  echo 'The new package kept the same VM firmware, and the logo is back on every member that had it.'
else
  BUILD_LOG="$(mktemp --suffix=.log /tmp/infnet-uefi-build.XXXXXX)"
  echo "The new package ships VM firmware the logo wasn't built for; rebuilding it once on this host (~10 minutes, log: ${BUILD_LOG})."
  if ! sudo "${UEFI}" build > "${BUILD_LOG}" 2>&1; then
    tail -n 30 "${BUILD_LOG}" >&2
    fail "the boot logo build failed (full log: ${BUILD_LOG}). VMs keep the stock firmware; re-run '${UEFI} build' and 'apply' on each member later."
  fi
  grep '^==> Built' "${BUILD_LOG}" || true
  for item in "${LOGO_MEMBERS[@]}"; do
    read -r name address <<< "${item%%|*}"
    if [[ "${address}" != 'local' ]]; then
      echo "Copying the built firmware to ${name}..."
      on_member "${address}" "mkdir -p '${UEFI_BUILD_DIR}'" >/dev/null
      scp -q "${UEFI_BUILD_DIR}/OVMF_CODE.4MB.fd" "${UEFI_BUILD_DIR}/BUILD_INFO" "${address}:${UEFI_BUILD_DIR}/"
    fi
    on_member "${address}" "sudo '${UEFI}' apply"
  done
fi

step 'Result'
for entry in "${MEMBERS[@]}"; do
  read -r name address <<< "${entry}"
  printf '  %-16s incus %s | %s\n' "${name}" \
    "$(on_member "${address}" "dpkg-query -W -f='\${Version}' incus" 2>/dev/null | tr -d '\r')" \
    "$(on_member "${address}" "test -d /var/lib/infnet-uefi-logo && '${UEFI}' status || echo 'boot logo not used'" 2>/dev/null | tr -d '\r' | tail -n1)"
done
echo
echo 'Running VMs keep their old QEMU and firmware until restarted; restart them when convenient.'
