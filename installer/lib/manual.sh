#!/usr/bin/env bash
# Installer helper: configures per-user first-login offline manual autostart

require_manual_payload() {
    local root="$1" asset
    for asset in usr/share/sensible/manual/index.html \
        usr/share/sensible/manual/applications.html \
        usr/share/sensible/manual/terminal-tools.html \
        usr/share/sensible/manual/manual.css \
        usr/share/sensible/manual/sensible-manual-autostart.desktop \
        usr/share/applications/sensible-manual.desktop \
        usr/local/bin/sensible-manual; do
        if [ ! -f "${root%/}/${asset}" ] || [ ! -s "${root%/}/${asset}" ]; then
            log_err "Offline manual asset missing or empty: ${asset}."
            return 1
        fi
    done
    if [ ! -x "${root%/}/usr/local/bin/sensible-manual" ]; then
        log_err "Offline manual opener is not executable."
        return 1
    fi
    return 0
}

configure_user_manual_autostart() {
    local username="${1:-}"

    # This account already exists on the target. Validate the path component,
    # not account availability (the setup form's validator checks the latter).
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "${#username}" -gt 32 ]; then
        log_err "configure_user_manual_autostart requires a valid username."
        return 1
    fi

    local template="${MNT}/usr/share/sensible/manual/sensible-manual-autostart.desktop"
    local user_autostart_dir="${MNT}/home/${username}/.config/autostart"
    local dest="${user_autostart_dir}/sensible-manual.desktop"

    require_manual_payload "$MNT" || return 1
    if [ ! -d "${MNT}/home/${username}" ] || [ -L "${MNT}/home/${username}" ]; then
        log_err "Manual autostart requires an existing user home directory."
        return 1
    fi

    log_info "Configuring first-login manual autostart for ${username}..."
    # Own newly created parents, without recursively changing unrelated files.
    local directory
    for directory in "${MNT}/home/${username}/.config" "$user_autostart_dir"; do
        if [ -L "$directory" ]; then
            log_err "Refusing a symlink in the manual autostart path: ${directory}."
            return 1
        fi
        if [ ! -d "$directory" ]; then
            mkdir "$directory" || return 1
            chroot "$MNT" chown "${username}:${username}" "${directory#"${MNT}"}" || return 1
        fi
    done
    if [ -L "$dest" ]; then
        log_err "Refusing a symlink at the manual autostart destination."
        return 1
    fi
    cp "$template" "$dest" || return 1
    chroot "$MNT" chown "${username}:${username}" \
        "/home/${username}/.config/autostart/sensible-manual.desktop"
}
