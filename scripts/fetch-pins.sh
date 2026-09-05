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
#   config/packages.chroot/localsend_amd64.deb   local APT input for both editions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=live/pins.env
source "${REPO_ROOT}/live/pins.env"

CHROOT="${REPO_ROOT}/live/config/includes.chroot"
CACHE="${REPO_ROOT}/live/local/pins"
mkdir -p "${CACHE}"

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

echo "==> Pins staged: oh-my-bash, skel defaults, Nerd Font, git, keyd, LocalSend (${SENSIBLE_VARIANT:-gnome})"
