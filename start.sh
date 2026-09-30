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

Main menu for the scripts in this repository. Each entry runs the script
without arguments, so it prompts for everything it needs; see README.md for
the command-line flags when scripting.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '') ;;
  *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
esac

# Label, then the command (relative to the repository) - one menu entry each.
MENU=(
  'Deploy a new project'                    'deploy-project.sh'
  'Create an instance'                      'create-instance.sh'
  'Resize an instance'                      'resize-instance.sh'
  'Delete an instance'                      'delete-instance.sh'
  'Delete a project'                        'delete-project.sh'
  'Back up instances now'                   'backup/backup-instances.sh'
  'Back up instances (dry run)'             'backup/backup-instances.sh --dry-run'
  'Restore an instance from backup'         'backup/restore-instance.sh'
  'Sync DNS records'                        'dns/sync-dns-records.sh'
  'Sync DNS records (dry run)'              'dns/sync-dns-records.sh --dry-run'
  'Re-apply web UI branding (sudo)'         'sudo branding/apply-ui-branding.sh'
  'Re-run host setup (sudo, no disk wipe)'  'sudo host/setup-incus-host.sh'
)

show_header() {
  local version projects
  version="$(incus query /1.0 2>/dev/null | jq -r '.environment.server_version // empty' 2>/dev/null)"
  projects="$(incus project list -f json 2>/dev/null | jq -r 'map(.name) | join(", ")' 2>/dev/null)"
  echo
  echo '========================================'
  echo "  INFNET Incus - $(hostname -s)"
  echo "  Incus ${version:-unreachable}${projects:+ | projects: ${projects}}"
  echo '========================================'
}

show_menu() {
  local i
  for (( i = 0; i < ${#MENU[@]}; i += 2 )); do
    printf '  %2d) %s\n' "$(( i / 2 + 1 ))" "${MENU[i]}"
  done
  echo '   q) Quit'
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
  echo "--- ${label} ---"
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

command -v incus >/dev/null 2>&1 || { echo 'Error: incus command not found in PATH.' >&2; exit 1; }

while true; do
  show_header
  show_menu
  read -r -p 'Choose an option: ' CHOICE || { echo; exit 0; }
  case "${CHOICE}" in
    q|Q|quit|exit) exit 0 ;;
    '') continue ;;
  esac
  if [[ "${CHOICE}" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#MENU[@]} / 2 )); then
    INDEX=$(( (CHOICE - 1) * 2 ))
    run_entry "${MENU[INDEX]}" "${MENU[INDEX + 1]}"
  else
    echo "Invalid choice '${CHOICE}'."
  fi
done
