#!/usr/bin/env bash
# Default applications, LazyVim starter, CLI suite, Flatpak, and optional packages

install_default_apps() {
    local username="$1"

    log_info "Installing the default browser, office, mail, media, password, Flatpak, and CLI suite..."
    local pkgs=(
        firefox-esr
        chromium
        vlc
        neovim
        libreoffice-writer
        libreoffice-calc
        libreoffice-impress
        thunderbird
        keepassxc
        7zip
        unzip
        zip
        ripgrep
        fd-find
        fzf
        bat
        eza
        zoxide
        btop
        fastfetch
        jq
        sudo
        curl
        git
        ca-certificates
        flatpak
        fonts-noto-core
        fonts-noto-color-emoji
        fonts-liberation
        fonts-powerline
    )

    DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y --no-install-recommends "${pkgs[@]}"

    log_info "Keeping Flathub setup outside the offline installer."

    # The pinned starter is staged into /etc/skel while the ISO is built.
    # Never replace it here with a moving network clone.
    log_info "Copying the baked LazyVim starter into the user home..."
    if [ ! -f "${MNT}/etc/skel/.config/nvim/init.lua" ]; then
        record_warning "The baked LazyVim starter is missing from /etc/skel; Neovim itself is installed."
    fi

    if [ -n "$username" ] && [ -d "${MNT}/home/$username" ] \
        && [ -d "${MNT}/etc/skel/.config/nvim" ]; then
        mkdir -p "${MNT}/home/$username/.config"
        cp -r ${MNT}/etc/skel/.config/nvim "${MNT}/home/$username/.config/"
        chroot ${MNT} chown -R "${username}:${username}" "/home/${username}/.config"
    fi

    log_success "Default software suite installed."
}

install_optional_apps() {
    local extra_options="$1" # string or array of selected tags

    # Optional installs never abort the whole installation, but failures are
    # surfaced loudly: the user must know their selection was not applied.
    if [[ "$extra_options" =~ "brave" ]]; then
        log_info "Configuring official Brave Browser apt repository..."
        mkdir -p ${MNT}/usr/share/keyrings ${MNT}/etc/apt/sources.list.d
        if ! curl -fsSLo ${MNT}/usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; then
            record_warning "Brave signing key could not be downloaded, so Brave was not installed."
        else
            echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" > ${MNT}/etc/apt/sources.list.d/brave-browser-release.list
            chroot ${MNT} apt-get update -y || record_warning "Brave package source could not be refreshed."
            if ! DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y brave-browser; then
                record_warning "Brave installation failed; the browser was not installed."
            fi
        fi
    fi

    if [[ "$extra_options" =~ "chromium" ]]; then
        log_info "Installing Chromium..."
        if ! DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y chromium; then
            record_warning "Chromium installation failed; the package was not installed."
        fi
    fi

    if [[ "$extra_options" =~ "audacious" ]]; then
        log_info "Installing Audacious..."
        if ! DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y audacious; then
            record_warning "Audacious installation failed; the package was not installed."
        fi
    fi

    if [[ "$extra_options" =~ "amberol" ]]; then
        log_info "Installing Amberol..."
        if ! DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y amberol; then
            record_warning "Amberol installation failed; the package was not installed."
        fi
    fi

    if [[ "$extra_options" =~ "elisa" ]]; then
        log_info "Installing Elisa..."
        if ! DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y elisa; then
            record_warning "Elisa installation failed; the package was not installed."
        fi
    fi
}
