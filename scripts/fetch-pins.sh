#!/usr/bin/env bash
# Fetch the pinned third-party artifacts of live/pins.env and stage them into
# live-build's includes.chroot, together with the shell/git defaults from
# configs/. Runs at ISO build time inside the builder container (called from
# live/build-stages.sh) -- never at install time, which is offline.
#
# Every download is SHA256-verified against live/pins.env. A moved or rotted
# pin fails the build here, loudly, instead of silently shipping stale code.
# Downloads are cached under live/local/pins so rebuilds stay offline-friendly.
#
# Staged into the image (which the installer copies to the target unchanged):
#   /usr/share/oh-my-bash          pinned oh-my-bash, shared read-only install
#   /etc/skel/.bashrc              configs/omb-bashrc (new users inherit OMB)
#   /etc/skel/.config/nvim         pinned LazyVim starter
#   /usr/local/share/fonts/jetbrains-mono-nerd   pinned JetBrainsMono Nerd Font
#   /etc/gitconfig                 configs/gitconfig (system-wide defaults)
#   /etc/keyd/default.conf         GNOME variant only
#   /usr/share/gnome-shell/extensions   pinned GNOME-only extensions
#   /usr/share/themes                  optional GNOME-only theme collection
#   config/packages.chroot/localsend_amd64.deb   local APT input for both editions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=live/pins.env
source "${REPO_ROOT}/live/pins.env"

CHROOT="${REPO_ROOT}/live/config/includes.chroot"
CACHE="${REPO_ROOT}/live/local/pins"
mkdir -p "${CACHE}"

case "${SENSIBLE_VARIANT:-gnome}" in
    gnome|kde) ;;
    *) echo "Error: unknown SENSIBLE_VARIANT '${SENSIBLE_VARIANT}' (expected gnome or kde)." >&2; exit 1 ;;
esac

for required_tool in curl sha256sum tar unzip python3 dpkg-deb install grep; do
    if ! command -v "${required_tool}" >/dev/null 2>&1; then
        echo "Error: ${required_tool} is required to stage pinned image assets." >&2
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

GNOME_EXTENSION_ROOT="${CHROOT}/usr/share/gnome-shell/extensions"
GNOME_EXTENSION_DOC="${CHROOT}/usr/share/doc/sensible-gnome-extensions"
GNOME_EXTENSION_UUIDS=(
    'Vitals@CoreCoding.com'
    'clipboard-indicator@tudmotu.com'
    'batterytime@typeof.pw'
    'shotzy@SamkitJain660.github.io'
)

# includes.chroot is shared by edition builds. Remove generated GNOME content
# before doing any downloads so a GNOME build can never leak into a later KDE
# build, even when the later staging attempt fails part-way through.
for uuid in "${GNOME_EXTENSION_UUIDS[@]}"; do
    rm -rf "${GNOME_EXTENSION_ROOT:?}/${uuid}"
done
rm -rf "${GNOME_EXTENSION_DOC:?}"
# Theme outputs also belong only to GNOME, even on a reused build workspace.
# shellcheck source=scripts/stage-themes.sh
source "${SCRIPT_DIR}/stage-themes.sh"
clear_staged_themes

stage_gnome_extension() {
    local label="$1" uuid="$2" version="$3" version_tag="$4" sha256="$5" license_file="$6" license_id="$7"
    local archive="${CACHE}/${uuid}-${version_tag}.zip"
    local destination="${GNOME_EXTENSION_ROOT}/${uuid}"

    fetch_verified \
        "https://extensions.gnome.org/download-extension/${uuid}.shell-extension.zip?version_tag=${version_tag}" \
        "${archive}" "${sha256}" "${label} GNOME extension"
    rm -rf "${destination:?}"
    mkdir -p "${destination}"
    if ! python3 - "${archive}" "${destination}" "${uuid}" "${version}" <<'PY'
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

archive, destination, expected_uuid, expected_version = sys.argv[1:]
with zipfile.ZipFile(archive) as bundle:
    names = set()
    for member in bundle.infolist():
        path = PurePosixPath(member.filename)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive member: {member.filename}")
        if stat.S_IFMT(member.external_attr >> 16) == stat.S_IFLNK:
            raise SystemExit(f"archive symlink is not allowed: {member.filename}")
        names.add(member.filename.rstrip("/"))
    if "metadata.json" not in names or "extension.js" not in names:
        raise SystemExit("metadata.json or extension.js is missing")
    metadata = json.loads(bundle.read("metadata.json"))
    if metadata.get("uuid") != expected_uuid:
        raise SystemExit(f"UUID is {metadata.get('uuid')!r}, expected {expected_uuid!r}")
    if str(metadata.get("version")) != expected_version:
        raise SystemExit(
            f"version is {metadata.get('version')!r}, expected {expected_version!r}"
        )
    if "50" not in [str(value) for value in metadata.get("shell-version", [])]:
        raise SystemExit("GNOME Shell 50 is not declared compatible")
    bundle.extractall(Path(destination))
PY
    then
        rm -rf "${destination:?}"
        echo "Error: ${label} archive identity or GNOME Shell compatibility does not match its pin." >&2
        exit 1
    fi

    if [ "${license_file}" = SPDX-GPL-2.0-or-later ]; then
        if ! grep -Fq 'SPDX-License-Identifier: GPL-2.0-or-later' "${destination}/extension.js"; then
            echo "Error: ${label} archive lacks its expected GPL-2.0-or-later notice." >&2
            exit 1
        fi
    elif [ ! -s "${destination}/${license_file}" ]; then
        echo "Error: ${label} archive lacks its expected ${license_file}." >&2
        exit 1
    else
        install -m 0644 "${destination}/${license_file}" \
            "${GNOME_EXTENSION_DOC}/${label// /-}.LICENSE"
    fi

    printf '%s\tUUID=%s\tversion=%s\tversion_tag=%s\tsha256=%s\tlicense=%s\tsource=https://extensions.gnome.org/download-extension/%s.shell-extension.zip?version_tag=%s\n' \
        "${label}" "${uuid}" "${version}" "${version_tag}" "${sha256}" "${license_id}" \
        "${uuid}" "${version_tag}" \
        >> "${GNOME_EXTENSION_DOC}/sources.txt"
}

# --- oh-my-bash: shared read-only install -----------------------------------
OMB_TARBALL="${CACHE}/oh-my-bash-${OH_MY_BASH_COMMIT}.tar.gz"
fetch_verified \
    "https://codeload.github.com/ohmybash/oh-my-bash/tar.gz/${OH_MY_BASH_COMMIT}" \
    "${OMB_TARBALL}" "${OH_MY_BASH_TARBALL_SHA256}" "oh-my-bash"

OMB_DEST="${CHROOT}/usr/share/oh-my-bash"
rm -rf "${OMB_DEST:?}"
mkdir -p "${OMB_DEST}"
tar -xzf "${OMB_TARBALL}" -C "${OMB_DEST}" --strip-components=1
rm -rf "${OMB_DEST}/.github"
if [ ! -s "${OMB_DEST}/themes/powerline-multiline/powerline-multiline.theme.sh" ]; then
    echo "Error: pinned oh-my-bash archive lacks the configured powerline-multiline theme." >&2
    exit 1
fi

mkdir -p "${CHROOT}/etc/skel"
install -m 0644 "${REPO_ROOT}/configs/omb-bashrc" "${CHROOT}/etc/skel/.bashrc"

# --- JetBrainsMono Nerd Font ------------------------------------------------
FONT_ZIP="${CACHE}/JetBrainsMono-${NERD_FONTS_TAG}.zip"
fetch_verified \
    "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_TAG}/JetBrainsMono.zip" \
    "${FONT_ZIP}" "${NERD_FONTS_JETBRAINS_MONO_ZIP_SHA256}" "JetBrainsMono Nerd Font"

FONT_DEST="${CHROOT}/usr/local/share/fonts/jetbrains-mono-nerd"
rm -rf "${FONT_DEST:?}"
mkdir -p "${FONT_DEST}"
unzip -o -j "${FONT_ZIP}" \
    JetBrainsMonoNerdFont-Regular.ttf \
    JetBrainsMonoNerdFont-Italic.ttf \
    JetBrainsMonoNerdFont-Bold.ttf \
    JetBrainsMonoNerdFont-BoldItalic.ttf \
    OFL.txt \
    -d "${FONT_DEST}" >/dev/null

# --- git: system-wide defaults, identity stays per-user ---------------------
install -m 0644 "${REPO_ROOT}/configs/gitconfig" "${CHROOT}/etc/gitconfig"

# --- LazyVim starter ---------------------------------------------------------
LAZYVIM_TARBALL="${CACHE}/lazyvim-starter-${LAZYVIM_STARTER_COMMIT}.tar.gz"
fetch_verified \
    "https://codeload.github.com/LazyVim/starter/tar.gz/${LAZYVIM_STARTER_COMMIT}" \
    "${LAZYVIM_TARBALL}" "${LAZYVIM_STARTER_TARBALL_SHA256}" "LazyVim starter"

LAZYVIM_DEST="${CHROOT}/etc/skel/.config/nvim"
rm -rf "${LAZYVIM_DEST:?}"
mkdir -p "${LAZYVIM_DEST}"
tar -xzf "${LAZYVIM_TARBALL}" -C "${LAZYVIM_DEST}" --strip-components=1

# --- GNOME Shell profile ----------------------------------------------------
if [ "${SENSIBLE_VARIANT:-gnome}" = "gnome" ]; then
    stage_gnome_themes
    mkdir -p "${GNOME_EXTENSION_DOC}"
    : > "${GNOME_EXTENSION_DOC}/sources.txt"
    stage_gnome_extension "Vitals" 'Vitals@CoreCoding.com' \
        "${VITALS_VERSION}" "${VITALS_VERSION_TAG}" "${VITALS_ZIP_SHA256}" LICENSE GPL-2.0
    stage_gnome_extension "Clipboard Indicator" 'clipboard-indicator@tudmotu.com' \
        "${CLIPBOARD_INDICATOR_VERSION}" "${CLIPBOARD_INDICATOR_VERSION_TAG}" \
        "${CLIPBOARD_INDICATOR_ZIP_SHA256}" LICENSE.rst MIT
    stage_gnome_extension "Battery Time" 'batterytime@typeof.pw' \
        "${BATTERY_TIME_VERSION}" "${BATTERY_TIME_VERSION_TAG}" \
        "${BATTERY_TIME_ZIP_SHA256}" SPDX-GPL-2.0-or-later GPL-2.0-or-later
    stage_gnome_extension "Shotzy" 'shotzy@SamkitJain660.github.io' \
        "${SHOTZY_VERSION}" "${SHOTZY_VERSION_TAG}" "${SHOTZY_ZIP_SHA256}" LICENSE GPL-3.0
    cat <<'EOF' >> "${GNOME_EXTENSION_DOC}/sources.txt"
Battery Time license: GPL-2.0-or-later; see its extension.js SPDX notice and /usr/share/common-licenses/GPL-2.
EOF
fi

# --- Variant-owned keyd mapping ---------------------------------------------
KEYD_DEST="${CHROOT}/etc/keyd"
rm -rf "${KEYD_DEST}"
if [ "${SENSIBLE_VARIANT:-gnome}" = "gnome" ]; then
    mkdir -p "${KEYD_DEST}"
    install -m 0644 "${REPO_ROOT}/configs/keyd-default.conf" "${KEYD_DEST}/default.conf"
fi

# --- LocalSend: install through live-build's local APT repository ------------
# A stable, architecture-suffixed filename avoids stale versions accumulating
# when a pin changes. live-build discovers this .deb and resolves its Depends.
LOCALSEND_DEB="${CACHE}/LocalSend-${LOCALSEND_VERSION}-linux-x86-64.deb"
fetch_verified \
    "https://github.com/localsend/localsend/releases/download/v${LOCALSEND_VERSION}/LocalSend-${LOCALSEND_VERSION}-linux-x86-64.deb" \
    "${LOCALSEND_DEB}" "${LOCALSEND_DEB_SHA256}" "LocalSend"
if [ "$(dpkg-deb -f "${LOCALSEND_DEB}" Package)" != localsend ] \
    || [ "$(dpkg-deb -f "${LOCALSEND_DEB}" Version)" != "${LOCALSEND_DEB_VERSION}" ] \
    || [ "$(dpkg-deb -f "${LOCALSEND_DEB}" Architecture)" != amd64 ]; then
    echo "Error: LocalSend package identity does not match its pin." >&2
    exit 1
fi
install -Dm0644 "${LOCALSEND_DEB}" "${REPO_ROOT}/live/config/packages.chroot/localsend_amd64.deb"

LOCALSEND_LICENSE="${CACHE}/LocalSend-${LOCALSEND_VERSION}-LICENSE"
fetch_verified \
    "https://raw.githubusercontent.com/localsend/localsend/v${LOCALSEND_VERSION}/LICENSE" \
    "${LOCALSEND_LICENSE}" "${LOCALSEND_LICENSE_SHA256}" "LocalSend license"
install -Dm0644 "${LOCALSEND_LICENSE}" "${CHROOT}/usr/share/doc/localsend/copyright"
install -Dm0644 "${REPO_ROOT}/live/pins.env" "${CHROOT}/etc/sensible/pins.env"

echo "==> Pins staged: oh-my-bash, skel defaults, Nerd Font, git, keyd, GNOME extensions/themes, LocalSend (${SENSIBLE_VARIANT:-gnome})"
