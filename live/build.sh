#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Container engine detection
if command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
else
    echo "Error: Neither podman nor docker found in PATH." >&2
    exit 1
fi

echo "==> Using container engine: ${CONTAINER_ENGINE}"

# Ensure executable permissions on auto scripts & hooks
chmod +x "${REPO_ROOT}/live/auto/"* 2>/dev/null || true
chmod -R +x "${REPO_ROOT}/live/config/hooks/" 2>/dev/null || true
chmod -R +x "${REPO_ROOT}/live/config/includes.chroot/usr/local/bin/" 2>/dev/null || true

# Stage installer and configs into includes.chroot/opt/sensible
OPT_SENSIBLE="${REPO_ROOT}/live/config/includes.chroot/opt/sensible"
mkdir -p "${OPT_SENSIBLE}"
rm -rf "${OPT_SENSIBLE:?}"/*

echo "==> Staging installer and configs into live image includes..."
mkdir -p "${OPT_SENSIBLE}/installer" "${OPT_SENSIBLE}/configs" "${OPT_SENSIBLE}/docs"
rsync -a --delete "${REPO_ROOT}/installer/" "${OPT_SENSIBLE}/installer/"
rsync -a --delete "${REPO_ROOT}/configs/" "${OPT_SENSIBLE}/configs/"
rsync -a --delete "${REPO_ROOT}/docs/" "${OPT_SENSIBLE}/docs/"
chmod -R +x "${OPT_SENSIBLE}/installer/" 2>/dev/null || true

# Prepare cache directory
CACHE_DIR="${REPO_ROOT}/live/.cache/apt"
mkdir -p "${CACHE_DIR}"

# Build the builder container image
IMAGE_TAG="sensible-live-builder:latest"
echo "==> Building container image ${IMAGE_TAG}..."
${CONTAINER_ENGINE} build -t "${IMAGE_TAG}" -f "${REPO_ROOT}/live/Dockerfile" "${REPO_ROOT}/live"

# Run live-build inside container
echo "==> Running live-build inside container..."
${CONTAINER_ENGINE} run --rm --privileged \
    -v "${REPO_ROOT}:/workspace:rw" \
    -v "${CACHE_DIR}:/var/cache/apt/archives:rw" \
    -w /workspace/live \
    "${IMAGE_TAG}" \
    bash -c "lb clean --purge && lb config && lb build"

# Locate generated ISO
ISO_OUTPUT=""
if [ -f "${REPO_ROOT}/live/sensible-debian-testing-amd64.iso" ]; then
    ISO_OUTPUT="${REPO_ROOT}/live/sensible-debian-testing-amd64.iso"
elif [ -f "${REPO_ROOT}/live/live-image-amd64.hybrid.iso" ]; then
    ISO_OUTPUT="${REPO_ROOT}/live/live-image-amd64.hybrid.iso"
fi

if [ -n "${ISO_OUTPUT}" ] && [ -f "${ISO_OUTPUT}" ]; then
    TARGET_ISO="${REPO_ROOT}/sensible-debian-testing-amd64.iso"
    if [ "${ISO_OUTPUT}" != "${TARGET_ISO}" ]; then
        cp "${ISO_OUTPUT}" "${TARGET_ISO}"
    fi
    (cd "${REPO_ROOT}" && sha256sum sensible-debian-testing-amd64.iso > sensible-debian-testing-amd64.iso.sha256)
    echo "============================================================"
    echo " Build successful!"
    echo " ISO:    ${TARGET_ISO}"
    echo " SHA256: $(cat "${TARGET_ISO}.sha256")"
    echo "============================================================"
else
    echo "Error: Output ISO was not produced." >&2
    exit 1
fi
