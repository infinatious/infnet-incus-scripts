#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: resize-instance.sh --project-id ID [--instance-index N] [--cpu N] [--ram GIB] [--boot-disk GIB] [--yes]

Options:
  --project-id ID       Numeric project ID to select the project.
  --instance-index N    Numeric instance list index (1-based) to resize.
  --cpu N               New CPU core count.
  --ram GIB             New RAM size in GiB.
  --boot-disk GIB       New boot disk size in GiB.
  --yes                 Skip the confirmation prompt.
  --help                Show this help message.

Examples:
  ./resize-instance.sh --project-id 42 --instance-index 1 --cpu 4 --ram 8 --boot-disk 60 --yes
EOF
}

run() {
  "$@" || fail "command failed: $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' not found in PATH."
}

PROJECT_ID_ARG=''
INSTANCE_INDEX_ARG=''
NEW_CPU_ARG=''
NEW_RAM_ARG=''
NEW_BOOT_ARG=''
CONFIRM_ARG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      [[ $# -ge 2 ]] || fail 'missing value for --project-id.'
      PROJECT_ID_ARG="$2"
      shift 2
      ;;
    --instance-index)
      [[ $# -ge 2 ]] || fail 'missing value for --instance-index.'
      INSTANCE_INDEX_ARG="$2"
      shift 2
      ;;
    --cpu)
      [[ $# -ge 2 ]] || fail 'missing value for --cpu.'
      NEW_CPU_ARG="$2"
      shift 2
      ;;
    --ram)
      [[ $# -ge 2 ]] || fail 'missing value for --ram.'
      NEW_RAM_ARG="$2"
      shift 2
      ;;
    --boot-disk)
      [[ $# -ge 2 ]] || fail 'missing value for --boot-disk.'
      NEW_BOOT_ARG="$2"
      shift 2
      ;;
    --yes)
      CONFIRM_ARG='yes'
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

require_cmd incus
require_cmd python3

mapfile -t PROJECT_OPTIONS < <(
  incus project list -f json 2>/dev/null \
    | jq -r '.[] | select(.description | test("^Project ID: [0-9]+$")) | "\(.description | ltrimstr("Project ID: "))\t\(.name)"'
)
(( ${#PROJECT_OPTIONS[@]} > 0 )) || fail 'no projects with project ID metadata were found.'

echo 'Available projects:'
for PROJECT_ENTRY in "${PROJECT_OPTIONS[@]}"; do
  IFS=$'\t' read -r PROJECT_ID PROJECT_NAME <<< "${PROJECT_ENTRY}"
  printf '%2s) %s\n' "${PROJECT_ID}" "${PROJECT_NAME}"
done
if [[ -n "${PROJECT_ID_ARG}" ]]; then
  SELECTED_PROJECT_ID="${PROJECT_ID_ARG}"
else
  read -r -p 'Choose project ID: ' SELECTED_PROJECT_ID
fi
[[ "${SELECTED_PROJECT_ID}" =~ ^[0-9]+$ ]] || fail 'project selection must be numeric.'
PROJECT_NAME="$(awk -F '\t' -v pid="${SELECTED_PROJECT_ID}" '$1 == pid {print $2}' <<< "$(printf '%s\n' "${PROJECT_OPTIONS[@]}")")"
[[ -n "${PROJECT_NAME}" ]] || fail "project ID '${SELECTED_PROJECT_ID}' is not available."

incus project show "${PROJECT_NAME}" >/dev/null 2>&1 || fail "project '${PROJECT_NAME}' does not exist."

mapfile -t INSTANCE_ROWS < <(incus list --project "${PROJECT_NAME}" -c nds4t -f csv 2>/dev/null || true)
(( ${#INSTANCE_ROWS[@]} > 0 )) || fail "no instances found in project '${PROJECT_NAME}'."

echo 'Instances:'
for i in "${!INSTANCE_ROWS[@]}"; do
  IFS=',' read -r NAME DESCRIPTION STATE IPV4 TYPE <<< "${INSTANCE_ROWS[$i]}"
  printf '%2d) %-32s type=%-4s state=%-10s ipv4=%-15s desc=%s\n' "$((i + 1))" "$NAME" "${TYPE:--}" "${STATE:-unknown}" "${IPV4:--}" "${DESCRIPTION:--}"
done

if [[ -n "${INSTANCE_INDEX_ARG}" ]]; then
  INSTANCE_INDEX="${INSTANCE_INDEX_ARG}"
else
  read -r -p 'Enter instance number to resize: ' INSTANCE_INDEX
fi
[[ "${INSTANCE_INDEX}" =~ ^[0-9]+$ ]] || fail 'instance selection must be numeric.'
(( INSTANCE_INDEX >= 1 && INSTANCE_INDEX <= ${#INSTANCE_ROWS[@]} )) || fail 'instance selection is out of range.'

SELECTED_ROW="${INSTANCE_ROWS[$((INSTANCE_INDEX - 1))]}"
IFS=',' read -r INSTANCE_NAME INSTANCE_DESCRIPTION INSTANCE_STATE INSTANCE_IPV4 INSTANCE_TYPE_DISPLAY <<< "${SELECTED_ROW}"

CURRENT_CPU="$(incus config get "${INSTANCE_NAME}" limits.cpu --project "${PROJECT_NAME}" 2>/dev/null || true)"
CURRENT_RAM="$(incus config get "${INSTANCE_NAME}" limits.memory --project "${PROJECT_NAME}" 2>/dev/null || true)"
CURRENT_BOOT="$(incus config device get "${INSTANCE_NAME}" root size --project "${PROJECT_NAME}" 2>/dev/null || true)"
PUBLIC_IP="$(incus config get "${INSTANCE_NAME}" user.public_ipv4 --project "${PROJECT_NAME}" 2>/dev/null || true)"

[[ -n "${CURRENT_CPU}" ]] || CURRENT_CPU='inherited'
[[ -n "${CURRENT_RAM}" ]] || CURRENT_RAM='inherited'
[[ -n "${CURRENT_BOOT}" ]] || CURRENT_BOOT='inherited'

INSTANCE_TYPE='ct'
if [[ "${INSTANCE_TYPE_DISPLAY}" == 'VIRTUAL-MACHINE' || "${INSTANCE_TYPE_DISPLAY}" == 'virtual-machine' ]]; then
  INSTANCE_TYPE='vs'
fi
if [[ "${INSTANCE_TYPE_DISPLAY}" == 'CONTAINER' || "${INSTANCE_TYPE_DISPLAY}" == 'container' ]]; then
  INSTANCE_TYPE='ct'
fi

IMAGE_TEXT='unknown'
if [[ -n "${INSTANCE_DESCRIPTION}" && "${INSTANCE_DESCRIPTION}" == image=* ]]; then
  IMAGE_TEXT="$(printf '%s\n' "${INSTANCE_DESCRIPTION}" | sed -n 's/^image=\([^;]*\).*/\1/p')"
fi

echo
echo 'Selected instance:'
echo "Name          : ${INSTANCE_NAME}"
echo "Type          : ${INSTANCE_TYPE}"
echo "State         : ${INSTANCE_STATE:--}"
echo "Current CPU   : ${CURRENT_CPU}"
echo "Current RAM   : ${CURRENT_RAM}"
echo "Current Boot  : ${CURRENT_BOOT}"
echo "Instance IP   : ${INSTANCE_IPV4:--}"
echo "Public IP     : ${PUBLIC_IP:--}"
echo "Description   : ${INSTANCE_DESCRIPTION:--}"
echo

echo 'Enter new values.'
if [[ -n "${NEW_CPU_ARG}" ]]; then
  NEW_CPU="${NEW_CPU_ARG}"
else
  read -r -p "CPU cores [${CURRENT_CPU}]: " NEW_CPU
fi
if [[ -n "${NEW_RAM_ARG}" ]]; then
  NEW_RAM="${NEW_RAM_ARG}"
else
  read -r -p "RAM in GiB [${CURRENT_RAM}]: " NEW_RAM
fi
if [[ -n "${NEW_BOOT_ARG}" ]]; then
  NEW_BOOT="${NEW_BOOT_ARG}"
else
  read -r -p "Boot disk in GiB [${CURRENT_BOOT}]: " NEW_BOOT
fi

[[ -n "${NEW_CPU}" ]] || NEW_CPU="${CURRENT_CPU}"
[[ -n "${NEW_RAM}" ]] || NEW_RAM="${CURRENT_RAM}"
[[ -n "${NEW_BOOT}" ]] || NEW_BOOT="${CURRENT_BOOT}"

[[ "${NEW_CPU}" =~ ^[0-9]+$ ]] || fail 'CPU cores must be numeric.'
if [[ "${NEW_RAM}" =~ ^[0-9]+$ ]]; then
  NEW_RAM="${NEW_RAM}GiB"
fi
[[ "${NEW_RAM}" =~ ^[0-9]+GiB$ ]] || fail 'RAM must be a whole number of GiB.'
if [[ "${NEW_BOOT}" =~ ^[0-9]+$ ]]; then
  NEW_BOOT="${NEW_BOOT}GiB"
fi
[[ "${NEW_BOOT}" =~ ^[0-9]+GiB$ ]] || fail 'boot disk must be a whole number of GiB.'

CURRENT_BOOT_GIB="${CURRENT_BOOT%GiB}"
NEW_BOOT_GIB="${NEW_BOOT%GiB}"
if [[ "${CURRENT_BOOT}" != "inherited" ]]; then
  [[ "${CURRENT_BOOT_GIB}" =~ ^[0-9]+$ ]] || fail 'unable to parse current boot disk size.'
  (( NEW_BOOT_GIB >= CURRENT_BOOT_GIB )) || fail 'boot disk shrink is not allowed; choose the same or a larger size.'
fi

echo
echo 'Planned changes:'
echo "Instance      : ${INSTANCE_NAME}"
echo "CPU           : ${CURRENT_CPU} -> ${NEW_CPU}"
echo "RAM           : ${CURRENT_RAM} -> ${NEW_RAM}"
echo "Boot disk     : ${CURRENT_BOOT} -> ${NEW_BOOT}"
if [[ -n "${CONFIRM_ARG}" ]]; then
  CONFIRM='yes'
else
  read -r -p 'Type yes to apply these changes: ' CONFIRM
fi
[[ "${CONFIRM}" == 'yes' ]] || fail 'resize cancelled.'

WAS_RUNNING=0
RESTART_NEEDED=0
if [[ "${INSTANCE_STATE}" == 'RUNNING' ]]; then
  WAS_RUNNING=1
fi

if [[ "${CURRENT_BOOT}" != "${NEW_BOOT}" && ${WAS_RUNNING} -eq 1 ]]; then
  read -r -p "Instance '${INSTANCE_NAME}' is running and must be stopped for boot disk changes. Stop it now? Type yes to stop, anything else to abort: " STOP_CONFIRM
  [[ "${STOP_CONFIRM}" == 'yes' ]] || fail 'resize cancelled because the instance must be powered off for boot disk changes.'
  echo "Stopping instance '${INSTANCE_NAME}' for root disk resize..."
  # Without a timeout this waits forever if the guest ignores the shutdown.
  incus stop "${INSTANCE_NAME}" --timeout 120 --project "${PROJECT_NAME}" \
    || fail "'${INSTANCE_NAME}' did not shut down within 2 minutes; shut it down from inside the guest (or run 'incus stop --force ${INSTANCE_NAME} --project ${PROJECT_NAME}') and re-run the resize."
  RESTART_NEEDED=1
elif [[ "${CURRENT_BOOT}" != "${NEW_BOOT}" ]]; then
  echo "Instance '${INSTANCE_NAME}' is already stopped for boot disk resize."
fi

echo "Updating CPU to ${NEW_CPU}..."
run incus config set "${INSTANCE_NAME}" limits.cpu "${NEW_CPU}" --project "${PROJECT_NAME}"

echo "Updating RAM to ${NEW_RAM}..."
run incus config set "${INSTANCE_NAME}" limits.memory "${NEW_RAM}" --project "${PROJECT_NAME}"

echo "Updating root disk size to ${NEW_BOOT}..."
if incus config device show "${INSTANCE_NAME}" --project "${PROJECT_NAME}" 2>/dev/null | grep -q '^root:'; then
  run incus config device set "${INSTANCE_NAME}" root size="${NEW_BOOT}" --project "${PROJECT_NAME}"
else
  run incus config device override "${INSTANCE_NAME}" root size="${NEW_BOOT}" --project "${PROJECT_NAME}"
fi

if (( RESTART_NEEDED == 1 )); then
  echo "Starting instance '${INSTANCE_NAME}'..."
  run incus start "${INSTANCE_NAME}" --project "${PROJECT_NAME}"
fi

UPDATED_IPV4="$(incus list "${INSTANCE_NAME}" --project "${PROJECT_NAME}" -c 4 -f csv 2>/dev/null | head -n1 || true)"
[[ -n "${UPDATED_IPV4}" ]] || UPDATED_IPV4="${INSTANCE_IPV4}"

echo
echo 'Resize complete.'
echo "Project      : ${PROJECT_NAME}"
echo "Instance     : ${INSTANCE_NAME}"
echo "CPU          : ${NEW_CPU}"
echo "RAM          : ${NEW_RAM}"
echo "Boot disk    : ${NEW_BOOT}"
echo "Instance IP  : ${UPDATED_IPV4:--}"
echo "Public IP    : ${PUBLIC_IP:--}"
echo "Description  : ${INSTANCE_DESCRIPTION:--}"

