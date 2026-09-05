#!/usr/bin/env bash
# Headless UEFI boot smoke test — the exact check CI runs, factored out so it
# can be run locally against a freshly built ISO. Boots the ISO in QEMU with
# OVMF (UEFI) and a serial console, then asserts that live-boot reached the
# systemd banner and a stable marker emitted by the serial autologin shell.
#
# Usage:  scripts/smoke-boot.sh [ISO]
#   ISO            path to the ISO (default: sensible-$SENSIBLE_VARIANT-debian-testing-amd64.iso)
#   SMOKE_TIMEOUT  maximum seconds to wait for boot          (default: 600)
#   SMOKE_SETTLE   seconds to keep QEMU alive after readiness (default: 5)
#   SMOKE_MEM      guest RAM in MiB                           (default: 3072)
#   SMOKE_LOG      serial log path              (default: a temp file, printed)
#   SMOKE_FIRMWARE uefi = plain UEFI, Secure Boot off (default)
#                  sb   = UEFI with Secure Boot enforced (OVMF secboot + MS keys)
#                  bios = legacy BIOS (SeaBIOS)
#
# Exit 0 = both banners seen; 1 = assertion failed or QEMU died unexpectedly.
# Uses KVM when /dev/kvm is usable, otherwise falls back to TCG (as CI does).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default to the variant ISO; SENSIBLE_VARIANT selects which one, and an
# explicit path still wins. Artifacts are per-variant since the desktop is
# chosen at build time rather than at install time.
SENSIBLE_VARIANT="${SENSIBLE_VARIANT:-gnome}"
ISO_PATH="${1:-${REPO_ROOT}/sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.iso}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-600}"
SMOKE_SETTLE="${SMOKE_SETTLE:-5}"
SMOKE_MEM="${SMOKE_MEM:-3072}"
for setting in SMOKE_TIMEOUT SMOKE_SETTLE; do
    if [[ ! "${!setting}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: ${setting} must be a positive integer in seconds." >&2
        exit 1
    fi
done

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
if [ "${SMOKE_FIRMWARE}" != "bios" ] \
    && { [ -z "${OVMF_CODE}" ] || [ -z "${OVMF_VARS}" ]; }; then
    echo "Error: no OVMF code/vars pair found for SMOKE_FIRMWARE=${SMOKE_FIRMWARE}. Install 'ovmf' (Debian/Ubuntu) or 'edk2-ovmf' (Arch)." >&2
    if [ -d /usr/share/OVMF ]; then
        if ! ls -la /usr/share/OVMF >&2; then
            echo "Warning: could not list /usr/share/OVMF while diagnosing missing firmware." >&2
        fi
    fi
    exit 1
fi
echo "==> Firmware: ${SMOKE_FIRMWARE}${OVMF_CODE:+ (${OVMF_CODE})}"

WORK="$(mktemp -d)"
QEMU_PID=""
QEMU_RC=0
stop_qemu() {
    local attempt
    [ -n "${QEMU_PID}" ] || return 0
    if kill -0 "${QEMU_PID}" 2>/dev/null; then
        if ! kill -TERM "${QEMU_PID}" 2>/dev/null; then
            echo "Warning: QEMU exited while stopping it." >&2
        fi
        for attempt in 1 2 3 4 5; do
            if ! kill -0 "${QEMU_PID}" 2>/dev/null; then break; fi
            sleep 1
        done
        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            if ! kill -KILL "${QEMU_PID}" 2>/dev/null; then
                echo "Warning: could not force-stop QEMU." >&2
            fi
        fi
    fi
    QEMU_RC=0
    wait "${QEMU_PID}" || QEMU_RC=$?
    QEMU_PID=""
}
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_qemu
    rm -rf "${WORK}"
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SERIAL_LOG="${SMOKE_LOG:-${WORK}/boot-serial.log}"
CLEAN="${WORK}/serial-clean.log"
# Use the same normalization while polling and for the final assertions.
clean_serial_log() {
    tr -d '\000' < "${SERIAL_LOG}" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][A-B0]//g' > "${CLEAN}"
}
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
    echo "==> Accel: TCG (no /dev/kvm) — slower, retaining the full boot deadline"
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

: > "${SERIAL_LOG}"
qemu-system-x86_64 \
    "${ACCEL[@]}" \
    "${MACHINE_OPT[@]}" \
    -m "${SMOKE_MEM}" \
    -smp 2 \
    "${FW_OPT[@]}" \
    -cdrom "${ISO_PATH}" \
    -drive file="${SCRATCH}",format=qcow2,if=virtio \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -nographic \
    > "${SERIAL_LOG}" 2>&1 &
QEMU_PID=$!

started=${SECONDS}
ready_at=-1
completed=0
while kill -0 "${QEMU_PID}" 2>/dev/null; do
    clean_serial_log
    if grep -q "Welcome to Debian" "${CLEAN}" \
        && grep -q "SENSIBLE_LIVE_SERIAL_READY" "${CLEAN}"; then
        if [ "${ready_at}" -lt 0 ]; then
            ready_at=${SECONDS}
            echo "==> Boot markers reached; checking QEMU stays alive for ${SMOKE_SETTLE}s"
        fi
        if [ "$((SECONDS - ready_at))" -ge "${SMOKE_SETTLE}" ]; then
            completed=1
            break
        fi
    fi
    if [ "$((SECONDS - started))" -ge "${SMOKE_TIMEOUT}" ]; then break; fi
    sleep 1
done
stop_qemu
echo "==> QEMU exit code: ${QEMU_RC}; elapsed $((SECONDS - started))s"

# Strip NULs and ANSI/control escapes before asserting: systemd colourises its
# banner, so its escape codes split "Welcome to Debian" in the raw log and a
# plain grep misses it even on a perfect boot. Assert against the cleaned text.
clean_serial_log

fail=0
if [ "${completed}" -ne 1 ]; then
    echo "  FAIL: QEMU exited or the boot deadline expired before readiness settled" >&2
    fail=1
elif [ "${QEMU_RC}" -ne 0 ] && [ "${QEMU_RC}" -ne 143 ]; then
    echo "  FAIL: QEMU failed while completing the smoke test (rc=${QEMU_RC})" >&2
    fail=1
fi
if grep -q "Welcome to Debian" "${CLEAN}"; then
    echo "  ok: systemd boot banner seen"
else
    echo "  FAIL: systemd 'Welcome to Debian' banner not seen on serial console" >&2
    fail=1
fi
if grep -q "SENSIBLE_LIVE_SERIAL_READY" "${CLEAN}"; then
    echo "  ok: Sensible live serial autologin reached"
else
    echo "  FAIL: live serial autologin marker not reached" >&2
    fail=1
fi

if [ "${fail}" -ne 0 ]; then
    echo "----- last 50 lines of serial log (cleaned) -----" >&2
    if ! tail -n 50 "${CLEAN}" >&2; then
        echo "Warning: cleaned serial log could not be read." >&2
    fi
    echo "Smoke test FAILED." >&2
    exit 1
fi
echo "Smoke test PASSED: ${SMOKE_FIRMWARE} live session reached serial autologin."
