#!/usr/bin/env bash
# Desktop environment, Plymouth themes, Display Manager, and keyd setup

install_desktop() {
    local desktop_env="$1"
    local enable_keyd="$2"
    local config_dir="$3"

    log_info "Installing Desktop Environment: ${desktop_env}..."

    local pkgs=(plymouth plymouth-themes)
    local plymouth_theme="spinner"

    if [ "$desktop_env" = "gnome" ]; then
        pkgs+=(gnome-core gdm3 gnome-software gnome-software-plugin-flatpak)
        plymouth_theme="spinner"
    elif [ "$desktop_env" = "kde" ]; then
        pkgs+=(kde-plasma-desktop sddm plasma-discover plasma-discover-backend-flatpak plymouth-theme-breeze)
        plymouth_theme="breeze"
    fi

    if [ "$enable_keyd" = "true" ]; then
        pkgs+=(keyd)
    fi

    DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y --no-install-recommends "${pkgs[@]}"

    log_info "Configuring Plymouth theme: ${plymouth_theme}..."
    chroot ${MNT} plymouth-set-default-theme -R "$plymouth_theme" 2>/dev/null || true

    if [ "$desktop_env" = "gnome" ]; then
        chroot ${MNT} systemctl enable gdm3.service 2>/dev/null || true
    elif [ "$desktop_env" = "kde" ]; then
        chroot ${MNT} systemctl enable sddm.service 2>/dev/null || true
    fi

    if [ "$enable_keyd" = "true" ]; then
        log_info "Configuring keyd for macOS-style clipboard (Super+C/V/X)..."
        local keyd_conf="${config_dir}/keyd-default.conf"
        if [ ! -f "$keyd_conf" ]; then
            log_err "keyd selected but ${keyd_conf} is missing; refusing to generate a second mapping (spec §11)."
            exit 1
        fi
        mkdir -p ${MNT}/etc/keyd
        cp "$keyd_conf" ${MNT}/etc/keyd/default.conf
        chroot ${MNT} systemctl enable keyd.service 2>/dev/null || true
    fi

    log_success "Desktop environment ${desktop_env} configured successfully."
}
