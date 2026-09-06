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
        pkgs+=(gnome-core gdm3 gnome-software gnome-software-plugin-flatpak dconf-cli)
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
    chroot ${MNT} plymouth-set-default-theme -R "$plymouth_theme"

    if [ "$desktop_env" = "gnome" ]; then
        chroot ${MNT} systemctl enable gdm3.service
    elif [ "$desktop_env" = "kde" ]; then
        chroot ${MNT} systemctl enable sddm.service
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
        chroot ${MNT} systemctl enable keyd.service
    fi

    log_success "Desktop environment ${desktop_env} configured successfully."
}

configure_login() {
    # Session login model: with LUKS the boot passphrase is the single
    # authentication step, so the desktop may auto-login — while the idle
    # screen lock (always configured) protects the running session.
    local desktop_env="$1" autologin="$2" username="$3"

    # Screen lock on idle (and on resume from suspend) for both desktops.
    if [ "$desktop_env" = "gnome" ]; then
        log_info "Configuring GNOME profile and idle screen lock (5 min)..."
        mkdir -p ${MNT}/etc/dconf/profile ${MNT}/etc/dconf/db/local.d
        printf 'user-db:user\nsystem-db:local\n' > ${MNT}/etc/dconf/profile/user
        # These are system defaults, not dconf locks: each user can still
        # disable an extension or change any preference in Settings/Tweaks.
        cat <<EOF > ${MNT}/etc/dconf/db/local.d/00-sensible-desktop
[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0

[org/gnome/desktop/wm/preferences]
button-layout='appmenu:minimize,maximize,close'

[org/gnome/shell]
enabled-extensions=['ubuntu-appindicators@ubuntu.com', 'gsconnect@andyholmes.github.io', 'caffeine@patapon.info', 'clipboard-indicator@tudmotu.com', 'dash-to-dock@micxgx.gmail.com', 'batterytime@typeof.pw', 'shotzy@SamkitJain660.github.io', 'user-theme@gnome-shell-extensions.gcampax.github.com', 'Vitals@CoreCoding.com']

[org/gnome/shell/extensions/caffeine]
user-enabled=false
restore-state=false
enable-fullscreen=false
enable-mpris=false

[org/gnome/shell/extensions/clipboard-indicator]
cache-only-favorites=true
cache-images=false

[org/gnome/shell/extensions/vitals]
include-public-ip=false
EOF
        chroot ${MNT} dconf update
    else
        log_info "Configuring KDE idle screen lock (5 min)..."
        mkdir -p ${MNT}/etc/xdg
        cat <<EOF > ${MNT}/etc/xdg/kscreenlockerrc
[Daemon]
Autolock=true
Timeout=5
LockOnResume=true
EOF
    fi

    if [ "$autologin" != "true" ]; then
        return 0
    fi
    if [ -z "$username" ]; then
        log_err "Autologin was enabled without a username."
        return 1
    fi

    if [ "$desktop_env" = "gnome" ]; then
        log_info "Enabling GDM automatic login for ${username}..."
        mkdir -p ${MNT}/etc/gdm3
        cat <<EOF > ${MNT}/etc/gdm3/daemon.conf
# Written by sensible-install
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=${username}
EOF
    else
        log_info "Enabling SDDM automatic login for ${username}..."
        mkdir -p ${MNT}/etc/sddm.conf.d
        # SDDM requires Session= alongside User= or autologin never engages.
        # "plasma" = /usr/share/wayland-sessions/plasma.desktop (Wayland default).
        cat <<EOF > ${MNT}/etc/sddm.conf.d/autologin.conf
# Written by sensible-install
[Autologin]
User=${username}
Session=plasma
EOF
    fi
}
