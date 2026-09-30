#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

# Projects are created with features.images=false, so every instance is
# launched from the default project's images.
PROJECT='default'

usage() {
  cat <<'EOF'
Usage: manage-images.sh

Menu for the images in the default project, which create-instance.sh picks
from: list them, import one from the images: server, add, rename or remove
aliases, and delete images.

create-instance.sh lists an image for the Windows profile only when an alias
contains "win", and for the Linux profile only when none does.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '') ;;
  *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
esac

command -v incus >/dev/null 2>&1 || { echo 'Error: incus command not found in PATH.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'Error: jq command not found in PATH.' >&2; exit 1; }

IMAGE_ROWS=()

# Loads IMAGE_ROWS as "fingerprint<TAB>aliases<TAB>type<TAB>size MiB<TAB>description".
load_images() {
  mapfile -t IMAGE_ROWS < <(incus image list --project "${PROJECT}" -f json 2>/dev/null | jq -r '
    sort_by(.properties.description // "") | .[]
    | [.fingerprint,
       ((.aliases | map(.name) | join(", ")) | if . == "" then "-" else . end),
       .type,
       ((.size / 1048576) | floor | tostring),
       (.properties.description // "")] | @tsv')
}

list_images() {
  local i fp aliases type size desc
  load_images
  if (( ${#IMAGE_ROWS[@]} == 0 )); then
    echo 'No images in the default project.'
    return 1
  fi
  printf '  %-3s %-24s %-12s %-16s %8s  %s\n' '#' 'ALIASES' 'FINGERPRINT' 'TYPE' 'SIZE' 'DESCRIPTION'
  for i in "${!IMAGE_ROWS[@]}"; do
    IFS=$'\t' read -r fp aliases type size desc <<< "${IMAGE_ROWS[$i]}"
    printf '  %-3s %-24s %-12s %-16s %6sMiB  %s\n' "$((i + 1))" "${aliases}" "${fp:0:12}" "${type}" "${size}" "${desc}"
  done
}

# Lists images and prints the fingerprint of the one the user picks.
pick_image() {
  local choice
  list_images >&2 || return 1
  read -r -p 'Image number: ' choice
  [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#IMAGE_ROWS[@]} )) \
    || { echo 'Invalid image number.' >&2; return 1; }
  cut -f1 <<< "${IMAGE_ROWS[$((choice - 1))]}"
}

valid_alias() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || { echo "Invalid alias '$1' (letters, digits, . _ - / only)." >&2; return 1; }
}

import_image() {
  local remote_image kind alias vm_flag=()
  echo 'Remote image from the images: server, e.g. ubuntu/26.04/cloud, debian/13/cloud, rockylinux/9/cloud.'
  echo 'Browse the list with: incus image list images: <name>'
  read -r -p 'Remote image: ' remote_image
  [[ -n "${remote_image}" ]] || { echo 'No image given.'; return 1; }
  read -r -p 'Container or VM? [c/v]: ' kind
  case "${kind,,}" in
    c|container) ;;
    v|vm) vm_flag=(--vm) ;;
    *) echo 'Answer c or v.'; return 1 ;;
  esac
  read -r -p 'Alias for it (e.g. ubuntu2604, ubuntu2604-vm): ' alias
  valid_alias "${alias}" || return 1
  incus image alias list --project "${PROJECT}" -f json 2>/dev/null | jq -r '.[].name' | grep -qxF "${alias}" \
    && { echo "Alias '${alias}' already exists."; return 1; }
  echo "Importing images:${remote_image} as '${alias}'..."
  incus image copy "images:${remote_image}" local: --alias "${alias}" --project "${PROJECT}" "${vm_flag[@]}" </dev/null
}

add_alias() {
  local fp alias
  fp="$(pick_image)" || return 1
  read -r -p 'New alias: ' alias
  valid_alias "${alias}" || return 1
  incus image alias create "${alias}" "${fp}" --project "${PROJECT}" </dev/null && echo "Alias '${alias}' -> ${fp:0:12} added."
}

rename_alias() {
  local old new
  read -r -p 'Alias to rename: ' old
  read -r -p 'New name: ' new
  valid_alias "${new}" || return 1
  incus image alias rename "${old}" "${new}" --project "${PROJECT}" && echo "Alias '${old}' renamed to '${new}'."
}

remove_alias() {
  local alias
  read -r -p 'Alias to remove (the image stays): ' alias
  [[ -n "${alias}" ]] || return 1
  incus image alias delete "${alias}" --project "${PROJECT}" && echo "Alias '${alias}' removed."
}

delete_image() {
  local fp confirm
  fp="$(pick_image)" || return 1
  echo 'Instances already created from it keep working; new ones can no longer use it.'
  read -r -p "Type yes to delete image ${fp:0:12}: " confirm
  [[ "${confirm}" == 'yes' ]] || { echo 'Cancelled.'; return 1; }
  incus image delete "${fp}" --project "${PROJECT}" && echo "Image ${fp:0:12} deleted."
}

while true; do
  echo
  echo '=== Images (default project) ==='
  echo '  1) List images'
  echo '  2) Import an image from images:'
  echo '  3) Add an alias to an image'
  echo '  4) Rename an alias'
  echo '  5) Remove an alias'
  echo '  6) Delete an image'
  echo '  q) Quit'
  read -r -p 'Choose an option: ' CHOICE || { echo; exit 0; }
  echo
  case "${CHOICE}" in
    1) list_images ;;
    2) import_image ;;
    3) add_alias ;;
    4) rename_alias ;;
    5) remove_alias ;;
    6) delete_image ;;
    q|Q|quit|exit) exit 0 ;;
    '') ;;
    *) echo "Invalid choice '${CHOICE}'." ;;
  esac
done
