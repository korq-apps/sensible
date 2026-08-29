#!/usr/bin/env bash
# Headless UEFI boot smoke test — the exact check CI runs, factored out so it
# can be run locally against a freshly built ISO. Boots the ISO in QEMU with
# OVMF (UEFI) and a serial console, then asserts that live-boot reached the
# systemd banner and the Sensible autologin MOTD.
#
# Usage:  scripts/smoke-boot.sh [ISO]
#   ISO            path to the ISO (default: sensible-$SENSIBLE_VARIANT-debian-testing-amd64.iso)
#   SMOKE_TIMEOUT  seconds to let it boot before stopping    (default: 600)
#   SMOKE_MEM      guest RAM in MiB                           (default: 3072)
#   SMOKE_LOG      serial log path              (default: a temp file, printed)
#   SMOKE_FIRMWARE uefi = plain UEFI, Secure Boot off (default)
#                  sb   = UEFI with Secure Boot enforced (OVMF secboot + MS keys)
#                  bios = legacy BIOS (SeaBIOS)
#
# Exit 0 = both banners seen; 1 = assertion failed or QEMU died unexpectedly.
# Uses KVM when /dev/kvm is usable, otherwise falls back to TCG (as CI does).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default to the variant ISO; SENSIBLE_VARIANT selects which one, and an
# explicit path still wins. Artifacts are per-variant since the desktop is
# chosen at build time rather than at install time.
SENSIBLE_VARIANT="${SENSIBLE_VARIANT:-gnome}"
ISO_PATH="${1:-${REPO_ROOT}/sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.iso}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-600}"
SMOKE_MEM="${SMOKE_MEM:-3072}"

if [ ! -f "${ISO_PATH}" ]; then
    echo "Error: ISO not found at ${ISO_PATH}" >&2
    echo "Build it first (see scripts/build help): ./live/build.sh" >&2
    exit 1
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "Error: qemu-system-x86_64 is not installed." >&2
    exit 1
fi

# Select firmware per SMOKE_FIRMWARE. UEFI modes use an OVMF code+vars pair;
# bios leaves the pair empty so QEMU falls back to SeaBIOS.
SMOKE_FIRMWARE="${SMOKE_FIRMWARE:-uefi}"
OVMF_CODE="" OVMF_VARS=""
case "${SMOKE_FIRMWARE}" in
    uefi)
        # Plain, non-secboot code image so the ISO boots with Secure Boot off.
        for pair in \
            "/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd" \
            "/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd" \
            "/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd" \
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd"; do
            # shellcheck disable=SC2086
            set -- ${pair}
            if [ -f "$1" ] && [ -f "$2" ]; then OVMF_CODE="$1"; OVMF_VARS="$2"; break; fi
        done
        ;;
    sb)
        # Secboot code + Microsoft-key vars: Secure Boot is enforced, so only
        # a properly signed boot chain (shim -> signed GRUB) can boot.
        for pair in \
            "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_VARS_4M.ms.fd" \
            "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd /usr/share/edk2/x64/OVMF_VARS.4m.ms.fd"; do
            # shellcheck disable=SC2086
            set -- ${pair}
            if [ -f "$1" ] && [ -f "$2" ]; then OVMF_CODE="$1"; OVMF_VARS="$2"; break; fi
        done
        ;;
    bios)
        ;;
    *)
        echo "Error: SMOKE_FIRMWARE must be one of: uefi, sb, bios (got '${SMOKE_FIRMWARE}')." >&2
        exit 1
        ;;
esac
if [ -n "${OVMF_VARS}" ] && [ -z "${OVMF_CODE}" ]; then
    echo "Error: no OVMF code/vars pair found for SMOKE_FIRMWARE=${SMOKE_FIRMWARE}. Install 'ovmf' (Debian/Ubuntu) or 'edk2-ovmf' (Arch)." >&2
    ls -la /usr/share/OVMF 2>/dev/null || true
    exit 1
fi
echo "==> Firmware: ${SMOKE_FIRMWARE}${OVMF_CODE:+ (${OVMF_CODE})}"

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT
SERIAL_LOG="${SMOKE_LOG:-${WORK}/boot-serial.log}"
VARS_COPY="${WORK}/OVMF_VARS.fd"
SCRATCH="${WORK}/smoke-disk.qcow2"
if [ -n "${OVMF_VARS}" ]; then
    cp "${OVMF_VARS}" "${VARS_COPY}"
fi
qemu-img create -f qcow2 "${SCRATCH}" 10G >/dev/null

ACCEL=()
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL=(-enable-kvm -cpu host)
    echo "==> Accel: KVM"
else
    ACCEL=(-cpu max)
    echo "==> Accel: TCG (no /dev/kvm) — slower, allow the full timeout"
fi

echo "==> Booting ${ISO_PATH} (firmware ${SMOKE_FIRMWARE}, timeout ${SMOKE_TIMEOUT}s, serial -> ${SERIAL_LOG})"

FW_OPT=()
if [ -n "${OVMF_CODE}" ]; then
    FW_OPT=(
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}"
        -drive if=pflash,format=raw,file="${VARS_COPY}"
    )
fi
MACHINE_OPT=()
if [ "${SMOKE_FIRMWARE}" = "sb" ]; then
    MACHINE_OPT=(-machine q35,smm=on)
fi

set +e
timeout "${SMOKE_TIMEOUT}"s qemu-system-x86_64 \
    "${ACCEL[@]}" \
    "${MACHINE_OPT[@]}" \
    -m "${SMOKE_MEM}" \
    -smp 2 \
    "${FW_OPT[@]}" \
    -cdrom "${ISO_PATH}" \
    -drive file="${SCRATCH}",format=qcow2,if=virtio \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -nographic \
    > "${SERIAL_LOG}" 2>&1
rc=$?
set -e

echo "==> QEMU exit code: ${rc} (124 = stopped after the boot window, expected)"
if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ]; then
    echo "----- last 50 lines of serial log -----" >&2
    tail -n 50 "${SERIAL_LOG}" >&2 || true
    echo "Error: QEMU exited unexpectedly (rc=${rc}) before completing the boot window." >&2
    exit 1
fi

# Strip NULs and ANSI/control escapes before asserting: systemd colourises its
# banner, so its escape codes split "Welcome to Debian" in the raw log and a
# plain grep misses it even on a perfect boot. Assert against the cleaned text.
CLEAN="${WORK}/serial-clean.log"
tr -d '\000' < "${SERIAL_LOG}" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][A-B0]//g' > "${CLEAN}"

fail=0
if grep -q "Welcome to Debian" "${CLEAN}"; then
    echo "  ok: systemd boot banner seen"
else
    echo "  FAIL: systemd 'Welcome to Debian' banner not seen on serial console" >&2
    fail=1
fi
if grep -q "Sensible (aka Lazydeb)" "${CLEAN}"; then
    echo "  ok: Sensible live autologin/MOTD reached"
else
    echo "  FAIL: live session autologin/MOTD ('Sensible (aka Lazydeb)') not reached" >&2
    fail=1
fi

if [ "${fail}" -ne 0 ]; then
    echo "----- last 50 lines of serial log (cleaned) -----" >&2
    tail -n 50 "${CLEAN}" >&2 || true
    echo "Smoke test FAILED." >&2
    exit 1
fi
echo "Smoke test PASSED: UEFI live session reached autologin."
