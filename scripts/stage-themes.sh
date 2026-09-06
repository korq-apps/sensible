#!/usr/bin/env bash
# Sourced by fetch-pins.sh: use its verified cache and explicit image root.

clear_staged_themes() {
    local color mode name
    for color in red yellow green blue purple gray; do
        for mode in light dark; do
            rm -rf "${CHROOT:?}/usr/share/themes/Marble-${color}-${mode}"
        done
    done
    # Retired outputs are also removed from a reused build workspace.
    for name in Graphite-Light Graphite-Dark good-old-shell \
        Qogir Qogir-Light Qogir-Dark Matcha-sea Matcha-light-sea Matcha-dark-sea \
        Fluent Fluent-Light Fluent-Dark; do
        rm -rf "${CHROOT:?}/usr/share/themes/${name}"
    done
    for name in Everforest Tokyonight Osaka Catppuccin; do
        for mode in Light Dark; do
            rm -rf "${CHROOT:?}/usr/share/themes/${name}-${mode}"
        done
    done
    for name in Everforest-Light Everforest-Dark Tokyonight-Light Tokyonight-Dark \
        Osaka_Light Osaka_Dark Catppuccin-Latte Catppuccin-Mocha Qogir Qogir-Light Qogir-Dark; do
        rm -rf "${CHROOT:?}/usr/share/icons/${name}"
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
    fetch_verified "https://codeload.github.com/imarkoff/Marble-shell-theme/tar.gz/${MARBLE_COMMIT}" \
        "${marble}" "${MARBLE_TARBALL_SHA256}" Marble
    fetch_verified "https://codeload.github.com/vinceliuice/Graphite-gtk-theme/tar.gz/${GRAPHITE_COMMIT}" \
        "${graphite}" "${GRAPHITE_TARBALL_SHA256}" Graphite
    local name key commit_key sha_key archive
    local additions=()
    for name in Qogir-theme Qogir-icon-theme Matcha-gtk-theme Fluent-gtk-theme; do
        case "$name" in
            Qogir-theme) key=QOGIR ;;
            Qogir-icon-theme) key=QOGIR_ICONS ;;
            Matcha-gtk-theme) key=MATCHA ;;
            Fluent-gtk-theme) key=FLUENT ;;
        esac
        commit_key="${key}_COMMIT"
        sha_key="${key}_TARBALL_SHA256"
        archive="${CACHE}/${name}-${!commit_key}.tar.gz"
        fetch_verified "https://codeload.github.com/vinceliuice/${name}/tar.gz/${!commit_key}" \
            "${archive}" "${!sha_key}" "${name}"
        additions+=("${archive}")
    done

    python3 "${SCRIPT_DIR}/build-theme-assets.py" "${CHROOT}" \
        "${marble}" "${graphite}" "${additions[@]}"
    local docs="${CHROOT}/usr/share/doc/sensible-themes"
    # Carry the exact upstream inputs and our build adapter with the image.
    # No dependency on a future upstream download for corresponding sources.
    install -m 0644 "${marble}" "${graphite}" "${additions[@]}" \
        "${SCRIPT_DIR}/build-theme-assets.py" "${SCRIPT_DIR}/stage-themes.sh" "${docs}/"
    install -m 0644 "${REPO_ROOT}/live/pins.env" "${docs}/pins.env"
    printf '%s\n' \
        "Marble: https://github.com/imarkoff/Marble-shell-theme commit=${MARBLE_COMMIT} sha256=${MARBLE_TARBALL_SHA256} GPL-3.0-or-later" \
        "Graphite: https://github.com/vinceliuice/Graphite-gtk-theme commit=${GRAPHITE_COMMIT} sha256=${GRAPHITE_TARBALL_SHA256} GPL-3.0" \
        'Sensible selection: Marble six accents for Shell 50, light/dark; Graphite grey GTK 3/4 and Shell light/dark.' \
        'No GDM extension, upstream installer, theme-switcher app or libadwaita override is installed or run.' \
        > "${docs}/sources.txt"
    for name in Qogir-theme Qogir-icon-theme Matcha-gtk-theme Fluent-gtk-theme; do
        case "$name" in
            Qogir-theme) key=QOGIR ;;
            Qogir-icon-theme) key=QOGIR_ICONS ;;
            Matcha-gtk-theme) key=MATCHA ;;
            Fluent-gtk-theme) key=FLUENT ;;
        esac
        commit_key="${key}_COMMIT"
        sha_key="${key}_TARBALL_SHA256"
        printf '%s\n' "${name}: https://github.com/vinceliuice/${name} commit=${!commit_key} sha256=${!sha_key} GPL-3.0" \
            >> "${docs}/sources.txt"
    done
    printf '%s\n' \
        'Qogir, Matcha (sea), Fluent and Graphite: GTK 3, GTK 4 and GNOME Shell installed globally with assets/indexes. Shell selection follows upstream >=48 behavior for GNOME 50. No GTK 2, GDM or other-desktop components.' \
        'Matcha GTK 4 and Shell CSS match the pinned manual installer. Known upstream GTK 4 missing references are reported in known-upstream-assets.txt, not used to omit the entire component. New missing assets still fail.' \
        'GTK 3 corrections: replace Qogir/Matcha missing legacy thumbnail image with a solid border; drop Qogir legacy Kooha image-only titlebutton overrides. Other URLs are checked, with only the recorded Matcha GTK 4 exceptions.' \
        'Additional asset repairs: Qogir GTK 4 checkmark URLs use the shipped path; Graphite Shell receives its referenced background/scalable assets.' \
        'Qogir icons: complete base and light/dark recolorings with merged upstream aliases, HiDPI links and Papirus,Adwaita,hicolor fallbacks; licenses/credits retained. Cursors are not installed or selected.' \
        'Qogir icon correction: microphone-sensitivity-muted-symbolic points to the shipped audio-input-microphone-muted-symbolic.svg, also repairing the chained none alias.' \
        'No GTK 2 engine is required: gtk2-engines-murrine is absent from Testing, and selected components omit GTK 2.' \
        >> "${docs}/sources.txt"
}
