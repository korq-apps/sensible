#!/usr/bin/env bash
# Installer helper: configures per-user first-login offline manual autostart

configure_user_manual_autostart() {
    local username="$1"

    if [ -z "$username" ]; then
        log_err "configure_user_manual_autostart called without username."
        return 1
    fi

    local template="${MNT}/usr/share/sensible/manual/sensible-manual-autostart.desktop"
    local user_autostart_dir="${MNT}/home/${username}/.config/autostart"
    local dest="${user_autostart_dir}/sensible-manual.desktop"

    if [ ! -f "$template" ]; then
        log_err "Manual autostart template not found at ${template}."
        return 1
    fi

    log_info "Configuring first-login manual autostart for ${username}..."
    mkdir -p "$user_autostart_dir"
    cp "$template" "$dest"
    chroot ${MNT} chown "${username}:${username}" "/home/${username}/.config/autostart" "/home/${username}/.config/autostart/sensible-manual.desktop"
}
