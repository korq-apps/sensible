#!/usr/bin/env bash
# Stage the face-login stack into the live image: the locally built Howdy-next
# package, its pinned recognition models and the Sensible setup tool. Runs at
# ISO build time after fetch-pins.sh (container: live/build-stages.sh; native:
# scripts/build-native.sh). Installation stays inert: no PAM service changes
# until a user runs Face Login Setup on the installed system, and that flow
# has its own timed rollback.
#
# Staged (the installer copies the image to the target unchanged):
#   config/packages.chroot/howdy-next_amd64.deb          local APT input, both editions
#   /usr/share/howdy/models/*.onnx                       pinned OpenCV zoo models, so enrollment is offline
#   /usr/local/lib/sensible/biometrics/                  sensible-biometrics and its modules
#   /usr/local/bin/sensible-biometrics                   launcher symlink
#   /usr/share/applications/sensible-biometrics.desktop  Face Login Setup menu entry
#   /usr/share/doc/sensible-biometrics/sources.txt       provenance record
#
# The package comes from .build/biometrics/dist (scripts/build-howdy-package.sh
# or `sensible-biometrics build`). It is accepted only when build.py confirms it
# was built from the current source pins, patches and packaging, its checksum
# matches the build manifest, and its identity matches live/pins.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=live/pins.env
source "${REPO_ROOT}/live/pins.env"

TOOLS="${REPO_ROOT}/tools/biometrics"
WORK="${SENSIBLE_HOWDY_WORK:-${REPO_ROOT}/.build/biometrics}"
CHROOT="${REPO_ROOT}/live/config/includes.chroot"
CACHE="${REPO_ROOT}/live/local/pins"
STAGED_DEB="${REPO_ROOT}/live/config/packages.chroot/howdy-next_amd64.deb"
mkdir -p "${CACHE}"

for required_tool in python3 sha256sum dpkg-deb install curl ln; do
    if ! command -v "${required_tool}" >/dev/null 2>&1; then
        echo "Error: ${required_tool} is required to stage the face-login stack." >&2
        exit 1
    fi
done

fetch_verified() {
    local url="$1" dest="$2" want="$3" name="$4"
    if [ -f "${dest}" ] \
        && echo "${want}  ${dest}" | sha256sum -c --status 2>/dev/null; then
        echo "==> ${name}: cached copy matches pin"
        return 0
    fi
    echo "==> ${name}: fetching ${url}"
    curl -fL --retry 3 -o "${dest}" "${url}"
    if ! echo "${want}  ${dest}" | sha256sum -c --status 2>/dev/null; then
        rm -f "${dest}"
        echo "Error: ${name} does not match the pinned SHA256 (${want})." >&2
        echo "       Update live/pins.env only after verifying the new artifact." >&2
        exit 1
    fi
}

# --- Howdy-next package: current inputs, matching manifest, pinned identity --
rm -f "${STAGED_DEB}"
if ! PACKAGE="$(python3 "${TOOLS}/build.py" check --work-dir "${WORK}")"; then
    echo "Error: no Howdy-next package built from the current tools/biometrics inputs under ${WORK}/dist." >&2
    echo "       Run scripts/build-howdy-package.sh (container), or as your normal user:" >&2
    echo "       tools/biometrics/sensible-biometrics deps && tools/biometrics/sensible-biometrics build" >&2
    exit 1
fi
PIN_VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "${TOOLS}/sources.json")"
if [ "${HOWDY_NEXT_DEB_VERSION}" != "${PIN_VERSION}" ]; then
    echo "Error: live/pins.env HOWDY_NEXT_DEB_VERSION (${HOWDY_NEXT_DEB_VERSION}) differs from tools/biometrics/sources.json (${PIN_VERSION})." >&2
    exit 1
fi
if ! deb_package=$(dpkg-deb -f "${PACKAGE}" Package) \
    || ! deb_version=$(dpkg-deb -f "${PACKAGE}" Version) \
    || ! deb_arch=$(dpkg-deb -f "${PACKAGE}" Architecture); then
    echo "Error: cannot read Howdy-next package metadata from ${PACKAGE}." >&2
    exit 1
fi
if [ "${deb_package}" != howdy-next ] \
    || [ "${deb_version}" != "${HOWDY_NEXT_DEB_VERSION}" ] \
    || [ "${deb_arch}" != amd64 ]; then
    echo "Error: Howdy-next package identity (${deb_package} ${deb_version} ${deb_arch}) does not match its pin." >&2
    exit 1
fi
PACKAGE_SHA256="$(sha256sum "${PACKAGE}" | cut -d' ' -f1)"
install -Dm0644 "${PACKAGE}" "${STAGED_DEB}"

# --- Recognition models: the exact artifacts Howdy's compiled manifest expects
# Baked here so enrollment on the installed system needs no download; the
# image hook then makes Howdy itself verify them offline.
MODELS_DEST="${CHROOT}/usr/share/howdy/models"
rm -rf "${MODELS_DEST:?}"
mkdir -p "${MODELS_DEST}"
stage_model() {
    local label="$1" directory="$2" file="$3" commit="$4" sha256="$5"
    fetch_verified \
        "https://github.com/opencv/opencv_zoo/raw/${commit}/models/${directory}/${file}" \
        "${CACHE}/${file}" "${sha256}" "${label}"
    install -m0644 "${CACHE}/${file}" "${MODELS_DEST}/${file}"
}
stage_model "YuNet face detector" face_detection_yunet \
    "${HOWDY_YUNET_FILE}" "${HOWDY_YUNET_COMMIT}" "${HOWDY_YUNET_SHA256}"
stage_model "SFace face recognizer" face_recognition_sface \
    "${HOWDY_SFACE_FILE}" "${HOWDY_SFACE_COMMIT}" "${HOWDY_SFACE_SHA256}"

# --- Setup tool: runtime files only, no build recipe ------------------------
# build.py, debian/ and patches/ stay in the checkout: the wizard treats their
# absence as "packaged install" and never attempts a source build here.
TOOL_DEST="${CHROOT}/usr/local/lib/sensible/biometrics"
rm -rf "${TOOL_DEST:?}"
mkdir -p "${TOOL_DEST}" "${CHROOT}/usr/local/bin"
for module in local_ops.py pam_ops.py pam_guard.py pam_session.py recover.py tui.py wizard.py sources.json; do
    install -m0644 "${TOOLS}/${module}" "${TOOL_DEST}/${module}"
done
install -m0755 "${TOOLS}/sensible-biometrics" "${TOOL_DEST}/sensible-biometrics"
ln -sfn ../lib/sensible/biometrics/sensible-biometrics "${CHROOT}/usr/local/bin/sensible-biometrics"
install -Dm0644 "${REPO_ROOT}/packaging/biometrics/sensible-biometrics.desktop" \
    "${CHROOT}/usr/share/applications/sensible-biometrics.desktop"

# --- Provenance --------------------------------------------------------------
DOC="${CHROOT}/usr/share/doc/sensible-biometrics"
mkdir -p "${DOC}"
python3 - "${TOOLS}/sources.json" "${PACKAGE_SHA256}" "${DOC}/sources.txt" \
    "${HOWDY_YUNET_FILE}" "${HOWDY_YUNET_COMMIT}" "${HOWDY_YUNET_SHA256}" \
    "${HOWDY_SFACE_FILE}" "${HOWDY_SFACE_COMMIT}" "${HOWDY_SFACE_SHA256}" <<'PY'
import json
import sys

pins = json.load(open(sys.argv[1]))
package_sha256, destination = sys.argv[2], sys.argv[3]
models = [sys.argv[4:7], sys.argv[7:10]]
lines = [
    "Sensible face login (Howdy-next), built locally from pinned sources",
    f"package=howdy-next_{pins['version']}_amd64.deb",
    f"package_sha256={package_sha256}",
    f"howdy_source={pins['howdy']['url']}",
    f"howdy_sha256={pins['howdy']['sha256']}",
    f"opencv_source={pins['opencv']['url']}",
    f"opencv_sha256={pins['opencv']['sha256']}",
    f"patches={pins['patch_source']}",
    "license=/usr/share/doc/howdy-next/copyright",
]
for filename, commit, sha256 in models:
    lines.append(f"model={filename}\tsha256={sha256}\tsource=https://github.com/opencv/opencv_zoo/tree/{commit}")
lines.append("setup_tool=/usr/local/lib/sensible/biometrics (launcher: Face Login Setup)")
lines.append("pam=unchanged by installation; Face Login Setup enables login with a timed rollback")
open(destination, "w").write("\n".join(lines) + "\n")
PY

echo "==> Face login staged: howdy-next ${HOWDY_NEXT_DEB_VERSION}, YuNet + SFace models, sensible-biometrics"
