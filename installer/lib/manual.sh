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
        # If running in test mode or minimal chroot without manual staged, warn rather than fail
        log_warn "Manual autostart template not found at ${template}; skipping first-login autostart."
        return 0
    fi

    log_info "Configuring first-login manual autostart for ${username}..."
    mkdir -p "$user_autostart_dir"
    cp "$template" "$dest"
    chroot ${MNT} chown -R "${username}:${username}" "/home/${username}/.config" 2>/dev/null || true
}
