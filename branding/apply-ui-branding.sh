#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/assets"
HOOK_FILE='/etc/apt/apt.conf.d/99-infnet-incus-ui-branding'
BRAND_NAME='Infinatious Cloud'
MARKER='<!-- infnet-branding -->'

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: apply-ui-branding.sh [--ui-dir DIR] [--install-hook] [--quiet]

Applies the Infinatious Cloud branding (Special Gothic font, logo, favicon,
page title) to the Incus web UI files served by incusd.

The UI ships in the incus-ui-canonical package, so every package upgrade
restores the stock files. The script is idempotent: --install-hook adds an
APT hook that re-runs it after every dpkg run, so upgrades are rebranded
automatically.

Options:
  --ui-dir DIR     UI directory (default: /opt/incus/ui, where Zabbly's
                   incusd wrapper points INCUS_UI).
  --install-hook   Also install the APT post-invoke hook.
  --quiet          Only print warnings and errors.
  --help           Show this help message.
EOF
}

UI_DIR='/opt/incus/ui'
INSTALL_HOOK=''
QUIET=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui-dir)
      [[ $# -ge 2 ]] || fail 'missing value for --ui-dir.'
      UI_DIR="$2"
      shift 2
      ;;
    --install-hook) INSTALL_HOOK='yes'; shift ;;
    --quiet) QUIET='yes'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

say() {
  [[ -n "${QUIET}" ]] || echo "$*"
}

(( EUID == 0 )) || fail 'run this script as root (sudo); the UI files are root-owned.'
[[ -f "${UI_DIR}/index.html" ]] || fail "no Incus UI found at '${UI_DIR}' (is incus-ui-canonical installed?)."
for asset in branding.css logo.svg fonts/special-gothic.ttf; do
  [[ -f "${ASSETS_DIR}/${asset}" ]] || fail "missing branding asset '${ASSETS_DIR}/${asset}'."
done

# Every asset URL carries a version derived from the asset contents. A CDN in
# front of the UI (us-west sits behind Cloudflare, which keeps static files
# well past their max-age) would otherwise keep serving the old logo and
# stylesheet after a change; index.html itself isn't cached, so new versions
# show up on the next page load.
VERSION="$(cat "${ASSETS_DIR}/branding.css" "${ASSETS_DIR}/logo.svg" "${ASSETS_DIR}/fonts/special-gothic.ttf" \
  "${ASSETS_DIR}/favicon-32x32.png" 2>/dev/null | md5sum | cut -c1-10)"

# Our own files live in a namespaced directory the package never touches.
install -d -m 0755 "${UI_DIR}/assets/infnet/fonts"
install -m 0644 "${ASSETS_DIR}/fonts/special-gothic.ttf" "${UI_DIR}/assets/infnet/fonts/special-gothic.ttf"
install -m 0644 "${ASSETS_DIR}/logo.svg" "${UI_DIR}/assets/infnet/logo.svg"
{
  cat "${ASSETS_DIR}/branding.css"
  printf '\n/* Added by apply-ui-branding.sh: versioned logo URL, see above. */\n'
  printf '.p-panel__logo .p-panel__logo-image {\n  content: url("logo.svg?v=%s");\n}\n' "${VERSION}"
} > "${UI_DIR}/assets/infnet/branding.css"
chmod 0644 "${UI_DIR}/assets/infnet/branding.css"

# The logo and favicon paths are also hardcoded in the UI, so those files are
# replaced in place too (for access that bypasses the CDN).
install -m 0644 "${ASSETS_DIR}/logo.svg" "${UI_DIR}/assets/img/incus-logo.svg"
if [[ -f "${ASSETS_DIR}/favicon-32x32.png" ]]; then
  install -m 0644 "${ASSETS_DIR}/favicon-32x32.png" "${UI_DIR}/assets/infnet/favicon-32x32.png"
  install -m 0644 "${ASSETS_DIR}/favicon-32x32.png" "${UI_DIR}/assets/img/favicon-32x32.png"
  sed -i -E "s|href=\"assets/(img\|infnet)/favicon-32x32\.png[^\"]*\"|href=\"assets/infnet/favicon-32x32.png?v=${VERSION}\"|" "${UI_DIR}/index.html"
fi

# Link the stylesheet last in <head> so it follows the UI's own stylesheet
# (added to <head> by the inline loader script) and wins at equal specificity.
INDEX="${UI_DIR}/index.html"
sed -i "/${MARKER}/d" "${INDEX}"
sed -i "s|</head>|    ${MARKER}<link rel=\"stylesheet\" href=\"assets/infnet/branding.css?v=${VERSION}\">\n  </head>|" "${INDEX}"
sed -i "s|<title>Incus UI</title>|<title>${BRAND_NAME}</title>|" "${INDEX}"

# Browser tab titles are built in the main bundle as "<page> | Incus UI".
# The bundle name changes every release, so patch the literal wherever it
# appears and warn (rather than fail) if a future release changes it.
mapfile -t BUNDLES < <(grep -lF '| Incus UI`' "${UI_DIR}"/assets/*.js 2>/dev/null || true)
if (( ${#BUNDLES[@]} > 0 )); then
  sed -i "s/| Incus UI\`/| ${BRAND_NAME}\`/g" "${BUNDLES[@]}"
elif ! grep -qF "| ${BRAND_NAME}\`" "${UI_DIR}"/assets/*.js 2>/dev/null; then
  echo "Warning: tab-title string not found in the UI bundle; titles will still say 'Incus UI'." >&2
fi

say "Branding applied to ${UI_DIR}."

if [[ -n "${INSTALL_HOOK}" ]]; then
  cat > "${HOOK_FILE}" <<EOF
// Re-apply Infinatious Cloud branding after incus-ui-canonical upgrades.
DPkg::Post-Invoke { "if [ -x ${SCRIPT_DIR}/apply-ui-branding.sh ] && [ -f ${UI_DIR}/index.html ]; then ${SCRIPT_DIR}/apply-ui-branding.sh --ui-dir ${UI_DIR} --quiet || true; fi"; };
EOF
  say "Installed APT hook ${HOOK_FILE}."
fi
