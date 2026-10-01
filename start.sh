#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: start.sh

Main menu for the scripts in this repository, grouped into categories. Each
entry runs its script without arguments (apart from the flags shown in the
menu), so it prompts for everything it needs; see README.md for the
command-line flags when scripting. Set NO_COLOR to disable colors.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '') ;;
  *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
esac

# Colors only on a terminal, and not with NO_COLOR set. Teal is xterm-256
# color 37, falling back to plain cyan.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  if (( $(tput colors 2>/dev/null || echo 8) >= 256 )); then TEAL=$'\e[38;5;37m'; else TEAL=$'\e[36m'; fi
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
  TEAL='' BOLD='' DIM='' RESET=''
fi

# Categories, numbered in this order. Each has a MENU_<n> array of
# label / command pairs; commands are relative to the repository, and a
# leading "sudo" runs the script as root.
CATEGORIES=(
  'Project Manager'
  'Host Tasks'
  'Instance Manager'
  'Backup Manager'
  'Misc'
)

MENU_1=(
  'Deploy a new project'                          'deploy-project.sh'
  'Delete an empty project'                       'delete-project.sh'
  'Delete a project and all of its instances'     'delete-project.sh --delete-instances'
  'Add missing profiles to a project'             'deploy-project.sh --add-missing-profiles'
  'Add missing profiles to all projects'          'deploy-project.sh --all-projects --add-missing-profiles'
  'Update profile payloads in all projects'       'deploy-project.sh --all-projects --update-payloads'
)
MENU_2=(
  'Check for Incus upgrades'                      'host/upgrade-incus.sh --check'
  'Upgrade Incus on all members (rolling)'        'host/upgrade-incus.sh'
  'Re-run host setup (sudo, no disk wipe)'        'sudo host/setup-incus-host.sh'
  'Re-apply web UI branding (sudo)'               'sudo branding/apply-ui-branding.sh'
  'UEFI boot logo status'                         'branding/uefi-logo.sh status'
)
MENU_3=(
  'Create an instance'                            'create-instance.sh'
  'Resize an instance'                            'resize-instance.sh'
  'Delete an instance'                            'delete-instance.sh'
)
MENU_4=(
  'Back up instances now'                         'backup/backup-instances.sh'
  'Back up instances (dry run)'                   'backup/backup-instances.sh --dry-run'
  'Restore an instance from backup'               'backup/restore-instance.sh'
)
MENU_5=(
  'Sync DNS records'                              'dns/sync-dns-records.sh'
  'Sync DNS records (dry run)'                    'dns/sync-dns-records.sh --dry-run'
  'Manage images and aliases'                     'manage-images.sh'
)

show_header() {
  local title="$1" version members projects
  version="$(incus query /1.0 2>/dev/null | jq -r '.environment.server_version // empty' 2>/dev/null)"
  members="$(incus cluster list -f json 2>/dev/null | jq -r 'sort_by(.server_name) | map(.server_name + (if .status == "Online" then "" else " (" + .status + ")" end)) | join(", ")' 2>/dev/null)"
  projects="$(incus project list -f json 2>/dev/null | jq -r 'map(.name) | join(", ")' 2>/dev/null)"
  clear 2>/dev/null || true
  printf '%s' "${TEAL}${BOLD}"
  cat <<'BANNER'
  ___ _   _ _____ _   _ _____ _____
 |_ _| \ | |  ___| \ | | ____|_   _|
  | ||  \| | |_  |  \| |  _|   | |
  | || |\  |  _| | |\  | |___  | |
 |___|_| \_|_|   |_| \_|_____| |_|
BANNER
  printf '%s' "${RESET}"
  printf '%s\n' "${TEAL} Incus ${version:-unreachable} on $(hostname -s)${RESET}"
  [[ -n "${members}" ]] && printf '%s\n' "${DIM} Cluster: ${members}${RESET}"
  [[ -n "${projects}" ]] && printf '%s\n' "${DIM} Projects: ${projects}${RESET}"
  printf '%s\n\n' "${TEAL} ---------------------------------------- ${BOLD}${title}${RESET}"
}

run_entry() {
  local label="$1" command="$2" status words
  read -r -a words <<< "${command}"
  if [[ "${words[0]}" == 'sudo' ]]; then
    words[1]="${SCRIPT_DIR}/${words[1]}"
  else
    words[0]="${SCRIPT_DIR}/${words[0]}"
  fi
  echo
  printf '%s\n' "${TEAL}--- ${label} ---${RESET}"
  if [[ "${words[0]}" == 'sudo' ]]; then
    sudo bash "${words[@]:1}"
  else
    bash "${words[@]}"
  fi
  status=$?
  echo
  if (( status == 0 )); then
    echo "${label}: done."
  else
    echo "${label}: exited with status ${status}."
  fi
  read -r -p 'Press Enter to return to the menu... ' _ || exit 0
}

# A category's submenu; returns to the main menu on b), exits on e).
category_menu() {
  local number="$1" title="$2" choice i count index
  local -n entries="MENU_${number}"
  count=$(( ${#entries[@]} / 2 ))
  while true; do
    show_header "${number}) ${title}"
    for (( i = 0; i < count; i++ )); do
      printf '  %s%2d)%s %s\n' "${TEAL}" "$(( i + 1 ))" "${RESET}" "${entries[i * 2]}"
    done
    echo
    printf '  %s b)%s Back\n' "${TEAL}" "${RESET}"
    printf '  %s e)%s Exit\n\n' "${TEAL}" "${RESET}"
    read -r -p 'Choose an option: ' choice || { echo; exit 0; }
    case "${choice}" in
      e|E) exit 0 ;;
      b|B) return 0 ;;
      '') continue ;;
    esac
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      index=$(( (choice - 1) * 2 ))
      run_entry "${entries[index]}" "${entries[index + 1]}"
    else
      read -r -p "Invalid choice '${choice}'. Press Enter to continue... " _ || exit 0
    fi
  done
}

command -v incus >/dev/null 2>&1 || { echo 'Error: incus command not found in PATH.' >&2; exit 1; }

while true; do
  show_header 'Main menu'
  for i in "${!CATEGORIES[@]}"; do
    printf '  %s%2d)%s %s\n' "${TEAL}" "$(( i + 1 ))" "${RESET}" "${CATEGORIES[i]}"
  done
  echo
  printf '  %s e)%s Exit\n\n' "${TEAL}" "${RESET}"
  read -r -p 'Choose a category: ' CHOICE || { echo; exit 0; }
  case "${CHOICE}" in
    e|E) exit 0 ;;
    '') continue ;;
  esac
  if [[ "${CHOICE}" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#CATEGORIES[@]} )); then
    category_menu "${CHOICE}" "${CATEGORIES[CHOICE - 1]}"
  else
    read -r -p "Invalid choice '${CHOICE}'. Press Enter to continue... " _ || exit 0
  fi
done
