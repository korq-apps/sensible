#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
umask 077

usage() {
    echo "Usage: $0 [--offline] [ISO [DISK.qcow2]]"
    echo "       $0 [--offline] --installed DISK.qcow2"
    echo "Fresh private logs: .qemu/run.*/ (or QEMU_LOG_ROOT)."
}
INSTALLED=false
OFFLINE=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --offline) OFFLINE=true; shift ;;
        --installed) INSTALLED=true; shift ;;
        --*) usage >&2; exit 2 ;;
        *) break ;;
    esac
done

# Default to the variant ISO; SENSIBLE_VARIANT selects which one, and an
# explicit path still wins. Artifacts are per-variant since the desktop is
# chosen at build time rather than at install time.
SENSIBLE_VARIANT="${SENSIBLE_VARIANT:-gnome}"
ISO_PATH="${1:-${REPO_ROOT}/sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.iso}"
DISK_PATH="${2:-${REPO_ROOT}/test-disk.qcow2}"
DISK_SIZE="${QEMU_DISK_SIZE:-64G}"
RAM="${QEMU_RAM:-4096}"
CPUS="${QEMU_CPUS:-4}"
if [ "$INSTALLED" = true ]; then
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    DISK_PATH="$1"
    ISO_PATH=""
    [ -f "$DISK_PATH" ] || { echo "Error: installed disk does not exist." >&2; exit 1; }
elif [ "$#" -gt 2 ]; then
    usage >&2
    exit 2
fi

if [ "$INSTALLED" = false ] && [ ! -f "${ISO_PATH}" ]; then
    echo "Error: ISO not found at ${ISO_PATH}" >&2
    echo "Build the ISO first with ./live/build.sh" >&2
    exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "Error: qemu-system-x86_64 is not installed." >&2
    exit 1
fi

# Locate OVMF firmware (prefer pflash code+vars pairing, fall back to -bios)
OVMF_CODE="${QEMU_OVMF_CODE:-}"
if [ -n "$OVMF_CODE" ] && [ ! -f "$OVMF_CODE" ]; then
    echo "Error: requested QEMU_OVMF_CODE does not exist." >&2
    exit 1
fi
for candidate in \
    "${OVMF_CODE}" \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF.fd \
    /usr/share/qemu/OVMF.fd; do
    if [ -f "${candidate}" ]; then
        OVMF_CODE="${candidate}"
        break
    fi
done

OVMF_VARS=""
if [ -n "${OVMF_CODE}" ] && [[ "${OVMF_CODE}" == *OVMF_CODE*.fd ]]; then
    # Matched code/vars pair from the same package. Substitute on the OVMF_CODE
    # stem rather than the whole filename so the split 4M build pairs too:
    # OVMF_CODE_4M.fd -> OVMF_VARS_4M.fd. That is Debian/Ubuntu's default and
    # the first candidate above; matching only *OVMF_CODE.fd left it without a
    # writable VARS image and fell through to -bios with a split CODE file,
    # which cannot boot. smoke-boot.sh pairs the same way.
    OVMF_VARS="${OVMF_CODE/OVMF_CODE/OVMF_VARS}"
    [ -f "${OVMF_VARS}" ] || OVMF_VARS=""
fi
if [ -n "${QEMU_OVMF_VARS:-}" ]; then
    [ -f "$QEMU_OVMF_VARS" ] || { echo "Error: requested QEMU_OVMF_VARS does not exist." >&2; exit 1; }
    OVMF_VARS="$QEMU_OVMF_VARS"
fi

if [ -z "${OVMF_CODE}" ]; then
    echo "Error: OVMF UEFI firmware not found in standard paths." >&2
    echo "Sensible is UEFI-only; install the firmware package and retry:" >&2
    echo "  Debian/Ubuntu: sudo apt-get install ovmf" >&2
    echo "  Arch:          sudo pacman -S edk2-ovmf" >&2
    exit 1
fi

# QEMU's comma-separated option syntax is not a shell quoting mechanism.
# Reject ambiguous paths before creating files or starting the VM.
DISK_PATH="$(realpath -m -- "$DISK_PATH")"
if [ -n "$ISO_PATH" ]; then ISO_PATH="$(realpath -- "$ISO_PATH")"; fi
OVMF_CODE="$(realpath -- "$OVMF_CODE")"
if [ -n "$OVMF_VARS" ]; then OVMF_VARS="$(realpath -- "$OVMF_VARS")"; fi
LOG_ROOT="$(realpath -m -- "${QEMU_LOG_ROOT:-${REPO_ROOT}/.qemu}")"
for path in "$ISO_PATH" "$DISK_PATH" "$OVMF_CODE" "$OVMF_VARS" "$LOG_ROOT"; do
    if [[ "$path" = *','* || "$path" = *$'\n'* ]]; then
        echo "Error: QEMU paths must not contain commas or newlines." >&2
        exit 2
    fi
done

# Create test disk if not existing
if [ ! -f "${DISK_PATH}" ]; then
    echo "==> Creating virtual test disk: ${DISK_PATH} (${DISK_SIZE})..."
    qemu-img create -f qcow2 "${DISK_PATH}" "${DISK_SIZE}"
fi

KVM_OPT=()
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_OPT+=("-enable-kvm" "-cpu" "host")
else
    KVM_OPT+=("-cpu" "max")
fi

BIOS_OPT=()
if [ -n "${OVMF_CODE}" ] && [ -n "${OVMF_VARS}" ]; then
    # Preserve installed UEFI boot entries across ISO and installed-disk boots.
    VARS_COPY="${DISK_PATH}.ovmf-vars.fd"
    if [ ! -e "$VARS_COPY" ]; then cp "${OVMF_VARS}" "${VARS_COPY}"; fi
    BIOS_OPT+=(
        "-drive" "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
        "-drive" "if=pflash,format=raw,file=${VARS_COPY}"
    )
    echo "==> Using OVMF (pflash): ${OVMF_CODE}"
elif [ -n "${OVMF_CODE}" ]; then
    BIOS_OPT+=("-bios" "${OVMF_CODE}")
    echo "==> Using OVMF (bios, no persistent vars): ${OVMF_CODE}"
fi

mkdir -p -- "$LOG_ROOT"
RUN_DIR="$(mktemp -d "${LOG_ROOT}/run.XXXXXXXX")"
RUN_DIR="$(realpath -- "$RUN_DIR")"
MEDIA_OPT=()
if [ "$INSTALLED" = false ]; then MEDIA_OPT=(-cdrom "$ISO_PATH" -boot once=d); fi
NETWORK_OPT=(-netdev user,id=net0 -device virtio-net-pci,netdev=net0)
if [ "$OFFLINE" = true ]; then NETWORK_OPT=(-nic none); fi
QEMU_ARGS=("${KVM_OPT[@]}" "${BIOS_OPT[@]}" -m "$RAM" -smp "$CPUS"
    "${MEDIA_OPT[@]}" -drive "file=${DISK_PATH},format=qcow2,if=virtio"
    "${NETWORK_OPT[@]}" -vga virtio -display "${QEMU_DISPLAY:-default}"
    -serial "file:${RUN_DIR}/serial.log"
    -chardev "file,id=diagnostics,path=${RUN_DIR}/diagnostics.stream"
    -device virtio-serial-pci
    -device virtserialport,chardev=diagnostics,name=org.sensible.diagnostics)
{
    date -u '+UTC: %Y-%m-%dT%H:%M:%SZ'
    qemu-system-x86_64 --version
    printf 'Repository commit: '
    git -C "$REPO_ROOT" rev-parse HEAD
    git -C "$REPO_ROOT" status --short
    if [ -n "$ISO_PATH" ]; then sha256sum -- "$ISO_PATH"; fi
    sha256sum -- "$OVMF_CODE"
    printf 'Command: qemu-system-x86_64'
    printf ' %q' "${QEMU_ARGS[@]}"
    printf '\n'
} > "${RUN_DIR}/host.txt"
echo "==> VM logs: ${RUN_DIR}"
printf '==> Collect after installer failure (VM may stay open):\n    python3 %q %q\n' \
    "${SCRIPT_DIR}/collect-vm-logs.py" "$RUN_DIR"
echo "==> QEMU stderr is saved in ${RUN_DIR}/qemu.log"
exec qemu-system-x86_64 "${QEMU_ARGS[@]}" 2> >(tee "${RUN_DIR}/qemu.log" >&2)
