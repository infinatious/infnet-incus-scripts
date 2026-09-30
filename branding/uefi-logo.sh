#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo 'Error: run this script with bash, do not source it.' >&2
  return 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOGO="${SCRIPT_DIR}/assets/uefi-logo.bmp"
BUILD_DIR="${SCRIPT_DIR}/assets/uefi"
FIRMWARE='/opt/incus/share/qemu/OVMF_CODE.4MB.fd'
STATE_DIR='/var/lib/infnet-uefi-logo'
HOOK_FILE='/etc/apt/apt.conf.d/99-infnet-uefi-logo'
ZABBLY_RAW='https://raw.githubusercontent.com/zabbly/incus/daily'

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: uefi-logo.sh build | apply | revert | status | reapply [--quiet]

Replaces the boot logo in the VM firmware (OVMF) with branding/assets/
uefi-logo.bmp. The logo is compiled into the firmware, so it has to be
rebuilt: `build` compiles OVMF in a throwaway container exactly the way
Zabbly builds it for the incus package (same edk2 tag, patches and flags,
read from Zabbly's public build workflow), with only the logo swapped.

  build    Build branding/assets/uefi/OVMF_CODE.4MB.fd (takes ~10 minutes).
  apply    Back up the package's OVMF_CODE.4MB.fd, install the built one,
           and install an APT hook for package upgrades. VMs pick it up on
           their next boot; running VMs are not touched.
  revert   Restore the package's firmware and remove the hook.
  status   Show which firmware is installed.
  reapply  Used by the APT hook. After an upgrade restores stock firmware,
           re-installs ours only if the package firmware is the same build
           we branded; a newer one is left in place, with a warning to run
           build + apply again, so VMs never get downgraded firmware.

Only the firmware code changes; each VM's variable store (Secure Boot keys,
boot entries) is untouched.
EOF
}

sha() {
  sha256sum "$1" | cut -d' ' -f1
}

cmd_build() {
  local image container tag
  command -v incus >/dev/null || fail 'incus command not found.'
  [[ -f "${LOGO}" ]] || fail "missing ${LOGO}."
  tag="$(curl -fsSL "${ZABBLY_RAW}/.github/workflows/builds.yml" | sed -n 's/^ *EDK2_TAG: *"\(.*\)".*/\1/p' | head -n1)"
  [[ -n "${tag}" ]] || fail "could not read EDK2_TAG from Zabbly's build workflow."
  image='images:ubuntu/26.04'
  incus image list --project default -f json | jq -e '.[] | select(.type == "container" and ((.aliases | map(.name)) | index("ubuntu2604")))' >/dev/null 2>&1 \
    && image='ubuntu2604'
  container="zz-ovmf-build-$$"
  echo "==> Building OVMF ${tag} with the Infinatious logo in container '${container}' (${image})"
  incus launch "${image}" "${container}" --project default -c limits.cpu="$(nproc)" </dev/null >/dev/null
  # Expanded now: the trap runs after this function's locals are gone.
  trap "incus delete -f '${container}' --project default >/dev/null 2>&1 || true" EXIT
  for _ in $(seq 1 60); do
    incus exec "${container}" --project default -- getent hosts github.com >/dev/null 2>&1 && break
    sleep 2
  done
  incus file push "${LOGO}" "${container}/root/Logo.bmp" --project default
  incus exec "${container}" --project default -- bash -euo pipefail -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git build-essential uuid-dev iasl nasm python3 curl >/dev/null
    git clone -q https://github.com/tianocore/edk2 /build/edk2 --recurse-submodules --shallow-submodules --depth 1 -b '${tag}'
    cd /build/edk2
    for p in edk2-0001-force-DUID-LLT.patch edk2-0003-boot-delay.patch edk2-0004-gcc-errors.patch \
             edk2-0005-Revert-ArmVirtPkg-make-EFI_LOADER_DATA-non-executabl.patch \
             edk2-0006-disable-EFI-memory-attributes-protocol.patch \
             edk2-0007-OvmfPkg-X64-add-opt-org-tianocore-UninstallMemAttrProtocol-support.patch; do
      curl -fsSL '${ZABBLY_RAW}/patches/'\$p | patch -s -p1
    done
    cp /root/Logo.bmp MdeModulePkg/Logo/Logo.bmp
    sed -i \"s#02/02/2022#\$(date +%m/%d/%Y)#g\" OvmfPkg/SmbiosPlatformDxe/SmbiosPlatformDxe.c
    # edk2's setup scripts use unset variables, so drop -u for the build.
    set +u
    export PYTHON_COMMAND=python3
    . ./edksetup.sh >/dev/null
    make -s -C BaseTools ARCH=X64 >/dev/null
    build -a X64 -t GCC -b RELEASE -p OvmfPkg/OvmfPkgX64.dsc \
      -DSMM_REQUIRE=TRUE -DSECURE_BOOT_ENABLE=TRUE \
      -DNETWORK_IP4_ENABLE=TRUE -DNETWORK_IP6_ENABLE=TRUE -DNETWORK_TLS_ENABLE=TRUE -DNETWORK_HTTP_BOOT_ENABLE=TRUE \
      -DTPM2_ENABLE=TRUE -DTPM2_CONFIG_ENABLE=TRUE --pcd PcdUninstallMemAttrProtocol=TRUE \
      -DFD_SIZE_4MB >/build/build.log 2>&1 || { tail -30 /build/build.log; exit 1; }
    cp Build/*/*/FV/OVMF_CODE.fd /build/OVMF_CODE.4MB.fd
  "
  mkdir -p "${BUILD_DIR}"
  incus file pull "${container}/build/OVMF_CODE.4MB.fd" "${BUILD_DIR}/OVMF_CODE.4MB.fd" --project default
  printf 'edk2=%s\nbuilt=%s\nsha256=%s\n' "${tag}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sha "${BUILD_DIR}/OVMF_CODE.4MB.fd")" > "${BUILD_DIR}/BUILD_INFO"
  echo "==> Built ${BUILD_DIR}/OVMF_CODE.4MB.fd (edk2 ${tag}). Install it with: sudo $0 apply"
}

cmd_apply() {
  local custom="${BUILD_DIR}/OVMF_CODE.4MB.fd"
  (( EUID == 0 )) || fail 'apply needs root (sudo).'
  [[ -f "${custom}" ]] || fail "no built firmware at ${custom}; run '$0 build' first."
  [[ -f "${FIRMWARE}" ]] || fail "${FIRMWARE} not found (is incus installed?)."
  [[ "$(stat -c %s "${custom}")" == "$(stat -c %s "${FIRMWARE}")" ]] \
    || fail 'the built firmware and the package firmware differ in size (different FD layout); rebuild before applying.'
  mkdir -p "${STATE_DIR}"
  if [[ "$(sha "${FIRMWARE}")" != "$(sha "${custom}")" ]]; then
    install -m 0644 "${FIRMWARE}" "${STATE_DIR}/OVMF_CODE.4MB.fd.orig"
  fi
  sha "${STATE_DIR}/OVMF_CODE.4MB.fd.orig" > "${STATE_DIR}/orig.sha256"
  install -m 0644 "${custom}" "${STATE_DIR}/OVMF_CODE.4MB.fd.infnet"
  install -m 0644 "${custom}" "${FIRMWARE}"
  cat > "${HOOK_FILE}" <<EOF
// Keep the Infinatious UEFI boot logo across incus package upgrades.
DPkg::Post-Invoke { "if [ -x ${SCRIPT_DIR}/uefi-logo.sh ] && [ -f ${STATE_DIR}/orig.sha256 ]; then ${SCRIPT_DIR}/uefi-logo.sh reapply --quiet || true; fi"; };
EOF
  echo "Installed the Infinatious firmware (${FIRMWARE}); VMs use it from their next boot."
}

cmd_reapply() {
  local quiet="${1:-}" current
  [[ -f "${STATE_DIR}/orig.sha256" && -f "${FIRMWARE}" ]] || return 0
  current="$(sha "${FIRMWARE}")"
  if [[ "${current}" == "$(sha "${STATE_DIR}/OVMF_CODE.4MB.fd.infnet")" ]]; then
    [[ -n "${quiet}" ]] || echo 'Infinatious firmware is installed.'
  elif [[ "${current}" == "$(cat "${STATE_DIR}/orig.sha256")" ]]; then
    install -m 0644 "${STATE_DIR}/OVMF_CODE.4MB.fd.infnet" "${FIRMWARE}"
    [[ -n "${quiet}" ]] || echo 'Re-installed the Infinatious firmware over the reinstalled stock firmware.'
  else
    echo "Warning: incus shipped new VM firmware; keeping it (stock logo). Rebuild the Infinatious one: ${SCRIPT_DIR}/uefi-logo.sh build && sudo ${SCRIPT_DIR}/uefi-logo.sh apply" >&2
  fi
}

cmd_revert() {
  (( EUID == 0 )) || fail 'revert needs root (sudo).'
  [[ -f "${STATE_DIR}/OVMF_CODE.4MB.fd.orig" ]] || fail 'no saved stock firmware to restore.'
  if [[ "$(sha "${FIRMWARE}")" == "$(sha "${STATE_DIR}/OVMF_CODE.4MB.fd.infnet")" ]]; then
    install -m 0644 "${STATE_DIR}/OVMF_CODE.4MB.fd.orig" "${FIRMWARE}"
  fi
  rm -f "${HOOK_FILE}"
  rm -rf "${STATE_DIR}"
  echo 'Stock firmware restored; VMs use it from their next boot.'
}

cmd_status() {
  local current
  current="$(sha "${FIRMWARE}")"
  if [[ -f "${STATE_DIR}/OVMF_CODE.4MB.fd.infnet" && "${current}" == "$(sha "${STATE_DIR}/OVMF_CODE.4MB.fd.infnet")" ]]; then
    echo "Installed: Infinatious firmware ($(sed -n 's/^edk2=//p' "${BUILD_DIR}/BUILD_INFO" 2>/dev/null || echo 'unknown build'))"
  elif [[ -f "${STATE_DIR}/orig.sha256" && "${current}" == "$(cat "${STATE_DIR}/orig.sha256")" ]]; then
    echo 'Installed: stock firmware (the APT hook will re-apply the Infinatious one on the next dpkg run)'
  else
    echo 'Installed: stock firmware'
  fi
}

case "${1:-}" in
  build) cmd_build ;;
  apply) cmd_apply ;;
  revert) cmd_revert ;;
  status) cmd_status ;;
  reapply) cmd_reapply "${2:-}" ;;
  --help|-h|'') usage ;;
  *) fail "unknown command '$1' (see --help)." ;;
esac
