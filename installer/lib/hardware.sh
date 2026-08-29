#!/usr/bin/env bash
# Hardware enablement: firmware, microcode, kernel, PipeWire, GPU, power profiles

configure_apt_sources() {
    log_info "Configuring Debian Testing APT repositories (main contrib non-free non-free-firmware)..."
    cat <<EOF > ${MNT}/etc/apt/sources.list
deb https://deb.debian.org/debian testing main contrib non-free non-free-firmware
deb-src https://deb.debian.org/debian testing main contrib non-free non-free-firmware
EOF
    chroot ${MNT} apt-get update -y
}

detect_nvidia_gpu() {
    if lspci -nn 2>/dev/null | grep -E "(VGA compatible controller|3D controller)" | grep -qi "10de:"; then
        return 0
    fi
    return 1
}

install_hardware_packages() {
    log_info "Installing core kernel, microcode, and non-free firmware..."
    
    local pkgs=(
        linux-image-amd64
        intel-microcode
        amd64-microcode
        locales
        keyboard-configuration
        console-setup
        firmware-linux
        firmware-misc-nonfree
        firmware-iwlwifi
        firmware-realtek
        firmware-atheros
        firmware-brcm80211
        firmware-mediatek
        firmware-sof-signed
        mesa-vulkan-drivers
        va-driver-all
        vdpau-driver-all
        network-manager
        pipewire
        wireplumber
        pipewire-pulse
        pipewire-audio
        pipewire-alsa
        libspa-0.2-bluetooth
        bluez
        power-profiles-daemon
        fwupd
        wireless-regdb
    )

    if detect_nvidia_gpu; then
        log_info "NVIDIA GPU detected. Adding proprietary nvidia-driver package..."
        pkgs+=(nvidia-driver)
        record_warning "NVIDIA: Secure Boot may block the proprietary driver and hibernation until a MOK is enrolled or Secure Boot is disabled."
    fi

    DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y --no-install-recommends "${pkgs[@]}"

    log_info "Enabling essential hardware systemd services..."
    chroot ${MNT} systemctl enable NetworkManager.service
    chroot ${MNT} systemctl enable bluetooth.service \
        || record_warning "Bluetooth service could not be enabled automatically."
    chroot ${MNT} systemctl enable power-profiles-daemon.service \
        || record_warning "Power profile service could not be enabled automatically."
    chroot ${MNT} systemctl enable fwupd.service \
        || record_warning "Firmware update service could not be enabled automatically."
    log_success "Hardware stack installed and configured."
}
