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
        # Speaker amplifier (Cirrus CS35L41/CS35L56) and Intel DSP firmware;
        # transitively present today, named so the closure cannot lose them.
        firmware-cirrus
        firmware-intel-sound
        mesa-vulkan-drivers
        va-driver-all
        # No vdpau-driver-all: it no longer exists in Debian Testing, and
        # requesting it aborted the whole hardware stage with apt exit 100.
        # VDPAU now ships inside mesa-libgallium, which mesa-vulkan-drivers
        # already pulls in; mesa-vdpau-drivers is only a transitional package.
        network-manager
        pipewire
        wireplumber
        pipewire-pulse
        pipewire-audio
        pipewire-alsa
        # UCM profiles are what make SOF/SoundWire laptops expose their devices;
        # alsa-utils provides the mixer tools sensible-audio-check relies on.
        alsa-ucm-conf
        alsa-topology-conf
        alsa-utils
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

# The live session runs the same kernel, firmware and audio packages the
# installer copies, so a laptop that is silent here is silent after first boot
# too. Record what sensible-audio-check finds for the completion summary instead
# of letting the user discover it later. The check is read-only and never fatal:
# an unusual live session must not block the install.
record_audio_warnings() {
    local checker="${SENSIBLE_AUDIO_CHECK:-/usr/local/bin/sensible-audio-check}"
    [ -x "$checker" ] || return 0
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        record_warning "Audio: ${line}"
    done < <("$checker" --summary 2>/dev/null)
    return 0
}
