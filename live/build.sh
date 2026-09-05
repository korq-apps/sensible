#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Both build entry points mutate live/config and live-build's state. Hold one
# non-blocking lock per checkout so concurrent GNOME/KDE builds cannot replace
# each other's staged package list or chroot midway through a build.
command -v flock >/dev/null 2>&1 \
    || { echo "Error: flock is required (install util-linux)." >&2; exit 1; }
BUILD_LOCK_ID="$(printf '%s' "${REPO_ROOT}" | sha256sum | cut -c1-16)"
BUILD_LOCK="${TMPDIR:-/tmp}/sensible-live-build-${BUILD_LOCK_ID}.lock"
exec 9>"${BUILD_LOCK}"
flock -n 9 \
    || { echo "Error: another Sensible ISO build is already using this checkout." >&2; exit 1; }

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

# These files are executed by live-build or from the live image. Missing paths
# are a broken source tree, and chmod failures must stop the build.
for executable_dir in \
    "${REPO_ROOT}/live/auto" \
    "${REPO_ROOT}/live/config/hooks" \
    "${REPO_ROOT}/live/config/includes.chroot/usr/local/bin"; do
    [ -d "${executable_dir}" ] \
        || { echo "Error: required executable directory is missing: ${executable_dir}" >&2; exit 1; }
    find "${executable_dir}" -type f -exec chmod 0755 {} +
done

# Stage installer and configs into includes.chroot/opt/sensible
OPT_SENSIBLE="${REPO_ROOT}/live/config/includes.chroot/opt/sensible"
mkdir -p "${OPT_SENSIBLE}"
rm -rf "${OPT_SENSIBLE:?}"/*

echo "==> Staging installer and configs into live image includes..."
mkdir -p "${OPT_SENSIBLE}/installer" "${OPT_SENSIBLE}/configs" "${OPT_SENSIBLE}/docs"
rsync -a --delete "${REPO_ROOT}/installer/" "${OPT_SENSIBLE}/installer/"
rsync -a --delete "${REPO_ROOT}/configs/" "${OPT_SENSIBLE}/configs/"
rsync -a --delete "${REPO_ROOT}/docs/" "${OPT_SENSIBLE}/docs/"
chmod 0755 "${OPT_SENSIBLE}/installer/sensible-install.sh"

# Desktop variant. The ISO carries the finished system, so the desktop is
# chosen at build time; the installer never asks.
SENSIBLE_VARIANT="${SENSIBLE_VARIANT:-gnome}"
case "${SENSIBLE_VARIANT}" in
    gnome|kde) ;;
    *) echo "Error: unknown SENSIBLE_VARIANT '${SENSIBLE_VARIANT}' (expected gnome or kde)." >&2; exit 1 ;;
esac
echo "==> Variant: ${SENSIBLE_VARIANT}"

VARIANT_LIST="${REPO_ROOT}/live/variants/${SENSIBLE_VARIANT}.list"
[ -f "${VARIANT_LIST}" ] || { echo "Error: no package list at ${VARIANT_LIST}." >&2; exit 1; }
cp "${VARIANT_LIST}" "${REPO_ROOT}/live/config/package-lists/desktop.list.chroot"

# Record the variant in the image; chroot hooks (e.g. ufw KDE Connect rules)
# and installed-system scripts read it from /etc/sensible/variant.
VARIANT_MARKER="${REPO_ROOT}/live/config/includes.chroot/etc/sensible/variant"
mkdir -p "$(dirname "${VARIANT_MARKER}")"
printf '%s\n' "${SENSIBLE_VARIANT}" > "${VARIANT_MARKER}"

# Resolve every package name before building. A name that has been dropped from
# Testing is otherwise only discovered mid-install, on the user's machine, after
# the disk is wiped -- which is exactly how vdpau-driver-all failed.
echo "==> Checking package names resolve against Debian Testing..."
"${REPO_ROOT}/scripts/check-packages.sh" "${SENSIBLE_VARIANT}"

# Build the builder container image
IMAGE_TAG="sensible-live-builder:latest"
echo "==> Building container image ${IMAGE_TAG}..."
${CONTAINER_ENGINE} build -t "${IMAGE_TAG}" -f "${REPO_ROOT}/live/Dockerfile" "${REPO_ROOT}/live"

# Run live-build inside the container. The stages are driven by
# live/build-stages.sh rather than `lb build`, so the chroot's device nodes can
# be repaired between bootstrap and package installation -- see that script.
echo "==> Running live-build inside container..."
bash "${REPO_ROOT}/scripts/run-build-container.sh" "${CONTAINER_ENGINE}" \
    "${SENSIBLE_BUILD_CONTAINER:-sensible-build-${BUILD_LOCK_ID}-$$}" --privileged \
    -e SENSIBLE_VARIANT="${SENSIBLE_VARIANT}" \
    -v "${REPO_ROOT}:/workspace:rw" \
    -w /workspace/live \
    "${IMAGE_TAG}" \
    bash /workspace/live/build-stages.sh

# Locate generated ISO. live-build's output name varies by version
# (e.g. sensible-debian-testing-amd64.hybrid.iso), so resolve by pattern.
ISO_OUTPUT=""
for candidate in \
    "${REPO_ROOT}/live/sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.iso" \
    "${REPO_ROOT}/live/sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.hybrid.iso"; do
    if [ -f "${candidate}" ]; then
        ISO_OUTPUT="${candidate}"
        break
    fi
done

if [ -z "${ISO_OUTPUT}" ]; then
    for candidate in "${REPO_ROOT}/live"/*.hybrid.iso "${REPO_ROOT}/live"/*.iso; do
        if [ -f "${candidate}" ]; then
            ISO_OUTPUT="${candidate}"
            break
        fi
    done
fi

if [ -n "${ISO_OUTPUT}" ] && [ -f "${ISO_OUTPUT}" ]; then
    TARGET_ISO="${REPO_ROOT}/sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.iso"
    if [ "${ISO_OUTPUT}" != "${TARGET_ISO}" ]; then
        # cp -f: replace a pre-existing target even if it is owned by
        # another user (stale artifact), instead of dying on EACCES.
        cp -f "${ISO_OUTPUT}" "${TARGET_ISO}"
    fi
    (cd "${REPO_ROOT}" && sha256sum "sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.iso" > "sensible-${SENSIBLE_VARIANT}-debian-testing-amd64.iso.sha256")
    echo "============================================================"
    echo " Build successful!"
    echo " ISO:    ${TARGET_ISO}"
    echo " SHA256: $(cat "${TARGET_ISO}.sha256")"
    echo "============================================================"
else
    echo "Error: Output ISO was not produced." >&2
    exit 1
fi
