#!/usr/bin/env bash
# Sourced by fetch-pins.sh: use its verified cache and explicit image root.

clear_staged_themes() {
    local color mode name
    for color in red yellow green blue purple gray; do
        for mode in light dark; do
            rm -rf "${CHROOT:?}/usr/share/themes/Marble-${color}-${mode}"
        done
    done
    for name in Graphite-Light Graphite-Dark good-old-shell; do
        rm -rf "${CHROOT:?}/usr/share/themes/${name}"
    done
    rm -rf "${CHROOT:?}/usr/share/doc/sensible-themes"
}

stage_gnome_themes() {
    if ! command -v sassc >/dev/null 2>&1; then
        echo 'Error: sassc is required to build the pinned GNOME theme collection.' >&2
        exit 1
    fi
    local marble="${CACHE}/marble-${MARBLE_COMMIT}.tar.gz"
    local graphite="${CACHE}/graphite-${GRAPHITE_COMMIT}.tar.gz"
    local old_shell="${CACHE}/good-old-shell-${GOOD_OLD_SHELL_VERSION}.tar.gz"
    local old_source="${CACHE}/good-old-shell-source-${GOOD_OLD_SHELL_COMMIT}.tar.gz"
    fetch_verified "https://codeload.github.com/imarkoff/Marble-shell-theme/tar.gz/${MARBLE_COMMIT}" \
        "${marble}" "${MARBLE_TARBALL_SHA256}" Marble
    fetch_verified "https://codeload.github.com/vinceliuice/Graphite-gtk-theme/tar.gz/${GRAPHITE_COMMIT}" \
        "${graphite}" "${GRAPHITE_TARBALL_SHA256}" Graphite
    fetch_verified "https://github.com/mx-2/gnome-shell-sass/releases/download/${GOOD_OLD_SHELL_VERSION}/good-old-shell-${GOOD_OLD_SHELL_VERSION}.tar.gz" \
        "${old_shell}" "${GOOD_OLD_SHELL_TARBALL_SHA256}" Good-Old-Shell
    fetch_verified "https://codeload.github.com/mx-2/gnome-shell-sass/tar.gz/${GOOD_OLD_SHELL_COMMIT}" \
        "${old_source}" "${GOOD_OLD_SHELL_SOURCE_SHA256}" Good-Old-Shell-source

    python3 "${SCRIPT_DIR}/build-theme-assets.py" "${CHROOT}" \
        "${marble}" "${graphite}" "${old_shell}" "${old_source}"
    local docs="${CHROOT}/usr/share/doc/sensible-themes"
    # Carry the exact upstream inputs and our build adapter with the image.
    # No dependency on a future upstream download for corresponding sources.
    install -m 0644 "${marble}" "${graphite}" "${old_shell}" "${old_source}" \
        "${SCRIPT_DIR}/build-theme-assets.py" "${SCRIPT_DIR}/stage-themes.sh" "${docs}/"
    install -m 0644 "${REPO_ROOT}/live/pins.env" "${docs}/pins.env"
    printf '%s\n' \
        "Marble: https://github.com/imarkoff/Marble-shell-theme commit=${MARBLE_COMMIT} sha256=${MARBLE_TARBALL_SHA256} GPL-3.0-or-later" \
        "Graphite: https://github.com/vinceliuice/Graphite-gtk-theme commit=${GRAPHITE_COMMIT} sha256=${GRAPHITE_TARBALL_SHA256} GPL-3.0" \
        "Good-Old-Shell: https://github.com/mx-2/gnome-shell-sass version=${GOOD_OLD_SHELL_VERSION} commit=${GOOD_OLD_SHELL_COMMIT} sha256=${GOOD_OLD_SHELL_TARBALL_SHA256} source-sha256=${GOOD_OLD_SHELL_SOURCE_SHA256} GPL-2.0-or-later" \
        'Sensible selection: Shell 50; Marble six accents, light/dark; Good-Old-Shell session assets only; Graphite grey GTK 3 light/dark only.' \
        'No GDM extension, upstream installer, theme-switcher app or libadwaita override is installed or run.' \
        > "${docs}/sources.txt"
}
