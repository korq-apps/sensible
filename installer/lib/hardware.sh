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
        log_warn "NVIDIA + Secure Boot: the proprietary module is unsigned and is"
        log_warn "rejected by the kernel's lockdown. Hibernation is also blocked by"
        log_warn "lockdown. Either disable Secure Boot or enroll a MOK for DKMS."
    fi

    DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y --no-install-recommends "${pkgs[@]}"

    log_info "Enabling essential hardware systemd services..."
    chroot ${MNT} systemctl enable NetworkManager.service bluetooth.service power-profiles-daemon.service fwupd.service 2>/dev/null || true
    log_success "Hardware stack installed and configured."
}
