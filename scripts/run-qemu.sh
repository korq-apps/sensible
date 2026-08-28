#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ISO_PATH="${1:-${REPO_ROOT}/sensible-debian-testing-amd64.iso}"
DISK_PATH="${2:-${REPO_ROOT}/test-disk.qcow2}"
DISK_SIZE="64G"
RAM="4096"
CPUS="4"

if [ ! -f "${ISO_PATH}" ]; then
    echo "Error: ISO not found at ${ISO_PATH}" >&2
    echo "Build the ISO first with ./live/build.sh" >&2
    exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "Error: qemu-system-x86_64 is not installed." >&2
    exit 1
fi

# Locate OVMF firmware (prefer pflash code+vars pairing, fall back to -bios)
OVMF_CODE=""
for candidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
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

if [ -z "${OVMF_CODE}" ]; then
    echo "Error: OVMF UEFI firmware not found in standard paths." >&2
    echo "Sensible is UEFI-only; install the firmware package and retry:" >&2
    echo "  Debian/Ubuntu: sudo apt-get install ovmf" >&2
    echo "  Arch:          sudo pacman -S edk2-ovmf" >&2
    exit 1
fi

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
    # Fresh working copy of the EFI variable store per test disk
    VARS_COPY="${DISK_PATH}.ovmf-vars.fd"
    cp "${OVMF_VARS}" "${VARS_COPY}"
    BIOS_OPT+=(
        "-drive" "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
        "-drive" "if=pflash,format=raw,file=${VARS_COPY}"
    )
    echo "==> Using OVMF (pflash): ${OVMF_CODE}"
elif [ -n "${OVMF_CODE}" ]; then
    BIOS_OPT+=("-bios" "${OVMF_CODE}")
    echo "==> Using OVMF (bios, no persistent vars): ${OVMF_CODE}"
fi

echo "==> Launching QEMU with ISO: ${ISO_PATH}..."
exec qemu-system-x86_64 \
    "${KVM_OPT[@]}" \
    "${BIOS_OPT[@]}" \
    -m "${RAM}" \
    -smp "${CPUS}" \
    -cdrom "${ISO_PATH}" \
    -drive file="${DISK_PATH}",format=qcow2,if=virtio \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -vga virtio \
    -display default
