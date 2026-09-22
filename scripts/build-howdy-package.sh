#!/usr/bin/env bash
# Build, or validate and reuse, the Howdy-next .deb that stage-biometrics.sh
# bakes into the ISO. The build runs inside a Debian Testing container so the
# package's Depends are computed against the same archive the image is
# bootstrapped from, not against a developer's host.
#
# A package already under .build/biometrics/dist is reused only when it was
# built from the current tools/biometrics inputs (source pins, patches and
# packaging; see build.py check) AND still installs against today's Testing
# (apt-get --simulate inside the fresh container). A soname bump in Testing
# therefore triggers a rebuild here, before the ISO build can fail on it.
#
# Usage: scripts/build-howdy-package.sh [podman|docker]
#   SENSIBLE_HOWDY_WORK        build tree (default: .build/biometrics)
#   SENSIBLE_HOWDY_JOBS        compile parallelism (default: build.py's CPU-based choice)
#   SENSIBLE_HOWDY_IMAGE       container image (default: debian:testing-slim, as live/Dockerfile)
#   SENSIBLE_BUILD_CONTAINER   container name prefix, so CI cleanup can find it
#
# Without a container engine the script only requires an existing build tree;
# stage-biometrics.sh verifies it. Build one as your normal user with
#   tools/biometrics/sensible-biometrics deps && tools/biometrics/sensible-biometrics build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- container side ---------------------------------------------------------
# Re-invoked inside the container with the tools directory mounted read-only
# at /work/tools and the build tree read-write at /work/build.
if [ "${1:-}" = "--inside" ]; then
    TOOLS=/work/tools
    WORK=/work/build
    owner="$(stat -c '%u:%g' "${WORK}")"
    restore_owner() {
        # The bind mount surfaces the host's identity; hand every file back so
        # the caller (and CI's checkout/cache steps) can read and delete them.
        chown -R -h "${owner}" "${WORK}" || echo "Warning: could not restore ownership of ${WORK}." >&2
    }
    trap restore_owner EXIT
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 ca-certificates >/dev/null
    if package="$(python3 "${TOOLS}/build.py" check --work-dir "${WORK}" 2>/dev/null)"; then
        if apt-get --simulate --no-remove install "${package}" >/dev/null 2>&1; then
            echo "==> Howdy-next: reusing $(basename "${package}"); it still installs on current Testing"
            exit 0
        fi
        echo "==> Howdy-next: cached package no longer installs on current Testing; rebuilding"
        # The private OpenCV prefix is keyed only by our source inputs, not by
        # the Testing library set. A soname transition is exactly why the cached
        # package stopped installing, so a plain rebuild would relink against the
        # stale prefix and fail again. Discard the extracted/compiled trees so
        # OpenCV and Howdy recompile against current Testing; the pinned source
        # tarballs under downloads/ are kept.
        rm -rf "${WORK}"/source-* "${WORK}/dist"
    else
        echo "==> Howdy-next: no package built from the current inputs; building"
    fi
    python3 "${TOOLS}/build.py" deps --yes
    # Upstream's test suite and dpkg-buildpackage expect an unprivileged builder.
    id builder >/dev/null 2>&1 || useradd --create-home --shell /bin/bash builder
    chown -R builder:builder "${WORK}"
    jobs=()
    if [ -n "${SENSIBLE_HOWDY_JOBS:-}" ]; then
        jobs=(--jobs "${SENSIBLE_HOWDY_JOBS}")
    fi
    runuser -u builder -- env HOME=/home/builder python3 "${TOOLS}/build.py" build --work-dir "${WORK}" "${jobs[@]}"
    package="$(runuser -u builder -- env HOME=/home/builder python3 "${TOOLS}/build.py" check --work-dir "${WORK}")"
    apt-get --simulate --no-remove install "${package}" >/dev/null
    echo "==> Howdy-next: built $(basename "${package}")"
    exit 0
fi

# --- host side ---------------------------------------------------------------
WORK="${SENSIBLE_HOWDY_WORK:-${REPO_ROOT}/.build/biometrics}"
TOOLS="${REPO_ROOT}/tools/biometrics"
IMAGE="${SENSIBLE_HOWDY_IMAGE:-debian:testing-slim}"

ENGINE="${1:-}"
if [ -z "${ENGINE}" ]; then
    if command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    fi
fi

if [ ! -d "${WORK}" ]; then
    mkdir -p "${WORK}"
    # Under sudo (build-native.sh) keep the tree usable by the developer's
    # own `sensible-biometrics build` afterwards.
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        chown "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${WORK}"
    fi
fi

if [ -z "${ENGINE}" ]; then
    if python3 "${TOOLS}/build.py" check --work-dir "${WORK}" >/dev/null; then
        echo "==> Howdy-next: no container engine; using the package under ${WORK}/dist (staging verifies it)"
        exit 0
    fi
    echo "Error: neither podman nor docker is available to build the Howdy-next package, and no" >&2
    echo "       package built from the current tools/biometrics inputs exists under ${WORK}/dist." >&2
    echo "       As your normal user: tools/biometrics/sensible-biometrics deps && tools/biometrics/sensible-biometrics build" >&2
    exit 1
fi

NAME="${SENSIBLE_BUILD_CONTAINER:-sensible-howdy-$$}-howdy"
echo "==> Howdy-next: checking or building the package in ${IMAGE} (${ENGINE})..."
bash "${SCRIPT_DIR}/run-build-container.sh" "${ENGINE}" "${NAME}" \
    -e SENSIBLE_HOWDY_JOBS="${SENSIBLE_HOWDY_JOBS:-}" \
    -v "${TOOLS}:/work/tools:ro" \
    -v "${SCRIPT_DIR}:/work/scripts:ro" \
    -v "${WORK}:/work/build:rw" \
    -w /work \
    "${IMAGE}" \
    bash /work/scripts/build-howdy-package.sh --inside

if ! python3 "${TOOLS}/build.py" check --work-dir "${WORK}" >/dev/null; then
    echo "Error: the container run finished without a package built from the current inputs." >&2
    exit 1
fi
