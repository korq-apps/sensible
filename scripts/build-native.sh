#!/usr/bin/env bash
# Containerless live-build — the same ISO as live/build.sh, but built directly
# on a Debian host instead of inside podman/docker. Handy when you already run
# Debian Testing (forky/sid) and want to skip the container round-trip.
#
# live-build must run as root (debootstrap, mount, chroot), so run this with:
#     sudo scripts/build-native.sh
#
# The resulting sensible-debian-testing-amd64.iso (+ .sha256) is written to the
# repo root and chowned back to the invoking user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: live-build needs root. Re-run: sudo scripts/build-native.sh" >&2
    exit 1
fi

# Build toolchain — keep in sync with live/Dockerfile.
DEPS=(
    live-build debootstrap
    syslinux-utils isolinux xorriso squashfs-tools mtools dosfstools
    grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed grub-efi-ia32-bin
    shim-signed sbsigntool
    rsync curl ca-certificates git coreutils util-linux findutils cpio bc procps
)

echo "==> Installing live-build toolchain (apt)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "${DEPS[@]}"

# Ensure executable bits on auto scripts, hooks, and staged binaries.
chmod +x "${REPO_ROOT}/live/auto/"* 2>/dev/null || true
chmod -R +x "${REPO_ROOT}/live/config/hooks/" 2>/dev/null || true
chmod -R +x "${REPO_ROOT}/live/config/includes.chroot/usr/local/bin/" 2>/dev/null || true

# Stage installer + configs + docs into the live image (same as live/build.sh).
OPT_SENSIBLE="${REPO_ROOT}/live/config/includes.chroot/opt/sensible"
echo "==> Staging installer and configs into ${OPT_SENSIBLE}..."
mkdir -p "${OPT_SENSIBLE}/installer" "${OPT_SENSIBLE}/configs" "${OPT_SENSIBLE}/docs"
rm -rf "${OPT_SENSIBLE:?}"/*
mkdir -p "${OPT_SENSIBLE}/installer" "${OPT_SENSIBLE}/configs" "${OPT_SENSIBLE}/docs"
rsync -a --delete "${REPO_ROOT}/installer/" "${OPT_SENSIBLE}/installer/"
rsync -a --delete "${REPO_ROOT}/configs/" "${OPT_SENSIBLE}/configs/"
rsync -a --delete "${REPO_ROOT}/docs/" "${OPT_SENSIBLE}/docs/"
chmod -R +x "${OPT_SENSIBLE}/installer/" 2>/dev/null || true

echo "==> Running live-build (lb clean --purge && lb config && lb build)..."
cd "${REPO_ROOT}/live"
lb clean --purge
lb config
lb build

# Locate the generated ISO (live-build's output name varies by version).
ISO_OUTPUT=""
for candidate in \
    "${REPO_ROOT}/live/sensible-debian-testing-amd64.iso" \
    "${REPO_ROOT}/live/sensible-debian-testing-amd64.hybrid.iso" \
    "${REPO_ROOT}/live"/*.hybrid.iso "${REPO_ROOT}/live"/*.iso; do
    if [ -f "${candidate}" ]; then ISO_OUTPUT="${candidate}"; break; fi
done

if [ -z "${ISO_OUTPUT}" ] || [ ! -f "${ISO_OUTPUT}" ]; then
    echo "Error: output ISO was not produced." >&2
    exit 1
fi

TARGET_ISO="${REPO_ROOT}/sensible-debian-testing-amd64.iso"
# cp -f: replace a pre-existing target even if it is owned by another user.
[ "${ISO_OUTPUT}" != "${TARGET_ISO}" ] && cp -f "${ISO_OUTPUT}" "${TARGET_ISO}"
( cd "${REPO_ROOT}" && sha256sum sensible-debian-testing-amd64.iso > sensible-debian-testing-amd64.iso.sha256 )

# Hand the artifacts back to the user who invoked sudo.
if [ -n "${SUDO_USER:-}" ]; then
    chown "${SUDO_USER}:$(id -gn "${SUDO_USER}")" \
        "${TARGET_ISO}" "${TARGET_ISO}.sha256" 2>/dev/null || true
fi

echo "============================================================"
echo " Build successful!"
echo " ISO:    ${TARGET_ISO}"
echo " SHA256: $(cat "${TARGET_ISO}.sha256")"
echo ""
echo " Now smoke-test it (no root needed):"
echo "   scripts/smoke-boot.sh"
echo "============================================================"
