#!/usr/bin/env bash
# Sensible (aka Lazydeb) Installer — Debian Testing Remix Installer Engine
# https://korq.io

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG_DIR="${SCRIPT_DIR}/../configs"

# Source library modules
# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/disk.sh
source "${LIB_DIR}/disk.sh"
# shellcheck source=lib/fstab.sh
source "${LIB_DIR}/fstab.sh"
# shellcheck source=lib/hardware.sh
source "${LIB_DIR}/hardware.sh"
# shellcheck source=lib/desktop.sh
source "${LIB_DIR}/desktop.sh"
# shellcheck source=lib/apps.sh
source "${LIB_DIR}/apps.sh"

# Trap errors for cleanup
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_err "Installation interrupted or failed with exit code ${exit_code}."
        unmount_target
    fi
}
trap cleanup EXIT

main() {
    check_root
    check_uefi

    local RAM_MIB SWAP_MIB MIN_DISK_MIB
    RAM_MIB=$(get_system_ram_mb)
    SWAP_MIB=$(calc_swap_mb)
    MIN_DISK_MIB=$(calc_min_disk_mb)

    log_info "Detected RAM: ${RAM_MIB} MiB. Planned Swap: ${SWAP_MIB} MiB. Min disk required: ${MIN_DISK_MIB} MiB."

    # Parse candidate disks
    mapfile -t DISK_CANDIDATES < <(list_candidate_disks)
    if [ ${#DISK_CANDIDATES[@]} -eq 0 ]; then
        ui_msgbox "Error" "No suitable target installation disks found."
        exit 1
    fi

    # 1. Welcome
    ui_msgbox "Sensible Installer" "Welcome to Sensible (Lazydeb) — Debian Testing Installer.\n\nThis installer will format the target disk and configure a ready-to-use Debian Testing workstation."

    # 2. Disk Selection
    local TARGET_DISK
    TARGET_DISK=$(ui_menu "Select Target Disk" "Choose the disk where Sensible will be installed (WARNING: ENTIRE DISK WILL BE WIPED):" "${DISK_CANDIDATES[@]}")
    if [ -z "$TARGET_DISK" ]; then
        log_warn "Disk selection cancelled."
        exit 1
    fi

    # 2b. Minimum disk size (spec §1)
    local DISK_SIZE_MIB
    # -d: whole disk only, else a partitioned disk emits one row per partition
    # and DISK_SIZE_MIB becomes multi-line (non-numeric), making the -lt test
    # below silently false -- letting an undersized disk through to the wipe.
    DISK_SIZE_MIB=$(lsblk -d -bno SIZE "$TARGET_DISK" 2>/dev/null | awk '{print int($1 / 1048576)}')
    if [ -z "$DISK_SIZE_MIB" ] || [ "$DISK_SIZE_MIB" -lt "$MIN_DISK_MIB" ]; then
        ui_msgbox "Error: Disk Too Small" "${TARGET_DISK} is ${DISK_SIZE_MIB:-unknown} MiB.\nSensible requires at least ${MIN_DISK_MIB} MiB:\n1 GiB EFI + 1 GiB BOOT + ${SWAP_MIB} MiB swap + 20 GiB root."
        log_err "Selected disk ${TARGET_DISK} is too small: ${DISK_SIZE_MIB:-unknown} MiB < ${MIN_DISK_MIB} MiB."
        exit 1
    fi
    log_info "Selected disk ${TARGET_DISK}: ${DISK_SIZE_MIB} MiB (minimum ${MIN_DISK_MIB} MiB)."

    # 3. Filesystem Selection
    local FS_CHOICE
    FS_CHOICE=$(ui_menu "Filesystem" "Choose root filesystem layout:" \
        "btrfs" "Btrfs with subvolumes (@, @home, @snapshots, @var_log)" \
        "ext4" "Ext4 single volume with fast_commit")
    FS_CHOICE="${FS_CHOICE:-btrfs}"

    # 4. LUKS2 Encryption
    local ENABLE_LUKS
    if ui_yesno "Full Disk Encryption" "Enable LUKS2 encryption for root?\n\n(Argon2id pbkdf, graphical Plymouth passphrase prompt at boot)"; then
        ENABLE_LUKS="true"
    else
        ENABLE_LUKS="false"
    fi

    local LUKS_PASSPHRASE=""
    if [ "$ENABLE_LUKS" = "true" ]; then
        while true; do
            LUKS_PASSPHRASE=$(ui_passwordbox "LUKS Passphrase" "Enter LUKS encryption passphrase (minimum 8 characters):")
            if [ ${#LUKS_PASSPHRASE} -lt 8 ]; then
                ui_msgbox "Invalid Passphrase" "Passphrase must be at least 8 characters long."
                continue
            fi
            local pass2
            pass2=$(ui_passwordbox "Confirm Passphrase" "Re-enter LUKS encryption passphrase:")
            if [ "$LUKS_PASSPHRASE" != "$pass2" ]; then
                ui_msgbox "Mismatch" "Passphrases did not match. Please try again."
                continue
            fi
            break
        done
    fi

    # 5. Desktop Environment
    local DESKTOP_CHOICE
    DESKTOP_CHOICE=$(ui_menu "Desktop Environment" "Choose your desktop environment (Wayland session):" \
        "gnome" "GNOME Desktop (macOS-oriented, gestures, gdm3)" \
        "kde" "KDE Plasma (Windows-oriented, panel, sddm)")
    DESKTOP_CHOICE="${DESKTOP_CHOICE:-gnome}"

    # 6. Mac Clipboard (keyd)
    local ENABLE_KEYD="false"
    local KEYD_DEFAULT="yes"
    [ "$DESKTOP_CHOICE" = "kde" ] && KEYD_DEFAULT="no"
    if ui_yesno "Mac Clipboard (keyd)" "Enable Mac clipboard shortcuts (Super+C/V/X -> Ctrl/Shift+Insert)?\n\nTerminal-safe: does not send SIGINT." "$KEYD_DEFAULT"; then
        ENABLE_KEYD="true"
    fi

    # 7. Optional Software Checkboxes
    local EXTRA_APPS
    EXTRA_APPS=$(ui_checklist "Optional Software" "Select optional software to install:" \
        "chromium" "Chromium Web Browser" OFF \
        "brave" "Brave Browser (Official Apt Origin)" OFF \
        "audacious" "Audacious Audio Player" OFF \
        "native_media" "DE Native Media Player (Amberol/Elisa)" OFF)

    if [[ "$EXTRA_APPS" =~ "native_media" ]]; then
        if [ "$DESKTOP_CHOICE" = "gnome" ]; then
            EXTRA_APPS="${EXTRA_APPS} amberol"
        else
            EXTRA_APPS="${EXTRA_APPS} elisa"
        fi
    fi

    # 8. Hostname
    local HOSTNAME
    HOSTNAME=$(ui_inputbox "Hostname" "Enter system hostname:" "debian")
    HOSTNAME="${HOSTNAME:-debian}"

    # 9. User Account & Password
    local USERNAME=""
    while true; do
        USERNAME=$(ui_inputbox "Username" "Enter primary username (lowercase, starts with letter):" "")
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        fi
        ui_msgbox "Invalid Username" "Username must match regex: ^[a-z_][a-z0-9_-]*$"
    done

    local USERPASS=""
    while true; do
        USERPASS=$(ui_passwordbox "User Password" "Enter password for ${USERNAME} and root recovery:")
        if [ -z "$USERPASS" ]; then
            ui_msgbox "Invalid Password" "Password cannot be empty."
            continue
        fi
        local pass2
        pass2=$(ui_passwordbox "Confirm Password" "Re-enter user password:")
        if [ "$USERPASS" != "$pass2" ]; then
            ui_msgbox "Mismatch" "Passwords did not match. Please try again."
            continue
        fi
        break
    done

    # 9b. Optional autologin — only meaningful with disk encryption: the LUKS
    # passphrase at boot is the authentication, the idle lock protects the
    # session. Without LUKS this would leave the machine wide open.
    local ENABLE_AUTOLOGIN="false"
    if [ "$ENABLE_LUKS" = "true" ]; then
        if ui_yesno "Skip Login Password" "Boot straight into the desktop as ${USERNAME} (no login password)?\n\nThe LUKS passphrase at boot stays required, the screen still locks on idle,\nand the password is kept for sudo and screen unlock. Without LUKS this is not offered." "yes"; then
            ENABLE_AUTOLOGIN="true"
        fi
    else
        log_info "Autologin is only offered with full disk encryption."
    fi

    # 10. Timezone, Locale & Keyboard
    local TIMEZONE
    TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    while true; do
        TIMEZONE=$(ui_inputbox "Timezone" "Enter timezone (e.g. UTC, America/New_York, Europe/London):" "${TIMEZONE:-UTC}")
        TIMEZONE="${TIMEZONE:-UTC}"
        # A typo would create a dangling /etc/localtime (ln -sf does not check).
        if [ -e "/usr/share/zoneinfo/${TIMEZONE}" ]; then
            break
        fi
        ui_msgbox "Invalid Timezone" "/usr/share/zoneinfo/${TIMEZONE} does not exist.\nUse an IANA name like Europe/Berlin or America/New_York."
    done

    local LOCALE="en_US.UTF-8"
    while true; do
        LOCALE=$(ui_inputbox "Locale" "Enter system locale:" "${LOCALE}")
        LOCALE="${LOCALE:-en_US.UTF-8}"
        # Spec §3: the locale must exist in /usr/share/i18n/SUPPORTED.
        # Field-based match: no regex on user input.
        if [ ! -r /usr/share/i18n/SUPPORTED ] || awk -v loc="${LOCALE}" '$1 == loc && $2 == "UTF-8" { found = 1 } END { exit !found }' /usr/share/i18n/SUPPORTED; then
            break
        fi
        ui_msgbox "Invalid Locale" "${LOCALE} was not found in /usr/share/i18n/SUPPORTED (UTF-8).\nExample: en_US.UTF-8"
    done

    local KEYBOARD_LAYOUT
    KEYBOARD_LAYOUT=$(detect_keyboard_layout)
    KEYBOARD_LAYOUT=$(ui_inputbox "Keyboard" "Enter keyboard layout (live session layout pre-filled):" "${KEYBOARD_LAYOUT:-us}")
    KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-us}"

    # 11. Confirmation / Wipe Warning
    local SUMMARY_TEXT
    SUMMARY_TEXT="SUMMARY OF INSTALLATION CHOICES:\n\n"
    SUMMARY_TEXT+="• Target Disk:   ${TARGET_DISK}\n"
    SUMMARY_TEXT+="• Filesystem:    ${FS_CHOICE}\n"
    SUMMARY_TEXT+="• LUKS2 Encrypt: ${ENABLE_LUKS}\n"
    SUMMARY_TEXT+="• Swap Size:     ${SWAP_MIB} MiB\n"
    SUMMARY_TEXT+="• Desktop:       ${DESKTOP_CHOICE}\n"
    SUMMARY_TEXT+="• Mac keyd:      ${ENABLE_KEYD}\n"
    SUMMARY_TEXT+="• Autologin:     ${ENABLE_AUTOLOGIN}\n"
    SUMMARY_TEXT+="• Hostname:      ${HOSTNAME}\n"
    SUMMARY_TEXT+="• Username:      ${USERNAME}\n"
    SUMMARY_TEXT+="• Timezone:      ${TIMEZONE}\n"
    SUMMARY_TEXT+="• Locale:        ${LOCALE}\n"
    SUMMARY_TEXT+="• Keyboard:      ${KEYBOARD_LAYOUT}\n\n"
    SUMMARY_TEXT+="WARNING: ALL DATA ON ${TARGET_DISK} WILL BE PERMANENTLY DESTROYED!\n"
    SUMMARY_TEXT+="To confirm, please type the exact disk path (${TARGET_DISK}) below:"

    local CONFIRM_DISK
    CONFIRM_DISK=$(ui_inputbox "DANGER: Confirm Disk Wipe" "$SUMMARY_TEXT" "")

    if [ "$CONFIRM_DISK" != "$TARGET_DISK" ]; then
        ui_msgbox "Aborted" "Confirmation did not match ${TARGET_DISK}. Installation cancelled."
        exit 1
    fi

    # === EXECUTION PHASE ===
    log_info "Beginning installation onto ${TARGET_DISK}..."

    # Step 1: Partitioning
    partition_disk "$TARGET_DISK" "$SWAP_MIB" "$ENABLE_LUKS"

    # Step 2: Formatting & Mounting
    format_and_mount "$TARGET_DISK" "$FS_CHOICE" "$ENABLE_LUKS" "$LUKS_PASSPHRASE" "$SWAP_MIB"

    # Step 3: Base Deployment
    log_info "Deploying base system..."
    if [ -d "${LIVE_ROOT_SENTINEL:-/lib/live}" ] || [ -f /etc/issue.sensible ]; then
        log_info "Copying live environment root to ${MNT} with rsync..."
        # Exclude the CONTENTS of the API filesystems ('/dev/*'), never the
        # directories themselves ('/dev'): the bind mounts below need existing
        # mountpoints on the target.
        rsync -aAX --info=progress2 \
            --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/tmp/*' \
            --exclude='/run/*' --exclude="${MNT}/*" --exclude='/media/*' --exclude=/lost+found \
            --exclude=/etc/systemd/system/getty@tty1.service.d/autologin.conf \
            --exclude=/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf \
            / "${MNT}/"
    else
        log_info "Bootstrapping Debian Testing to ${MNT} with debootstrap..."
        debootstrap --arch=amd64 testing ${MNT} https://deb.debian.org/debian
    fi
    # Whatever the deploy path produced, the API mountpoints and /tmp must exist.
    mkdir -p "${MNT}/dev" "${MNT}/proc" "${MNT}/sys" "${MNT}/run" "${MNT}/tmp" "${MNT}/mnt" "${MNT}/media"
    chmod 1777 "${MNT}/tmp"
    # Live-session-only: never ship passwordless root autologin to the target.
    rm -f ${MNT}/etc/systemd/system/getty@tty1.service.d/autologin.conf \
          ${MNT}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf

    # The rsync path copies the live session's /etc/machine-id, so every install
    # from one boot would inherit the same identity (journald, DHCP DUIDs and
    # other machine-ID consumers then collide). An empty /etc/machine-id is
    # systemd's documented "first boot" marker: it regenerates one at boot.
    : > "${MNT}/etc/machine-id"
    # Debian usually symlinks this to /etc/machine-id; drop it only if the copy
    # left a real file behind, so the symlink is preserved when present.
    [ -L "${MNT}/var/lib/dbus/machine-id" ] || rm -f "${MNT}/var/lib/dbus/machine-id"

    # Step 4: Bind Mounts & DNS
    log_info "Preparing chroot environment..."
    for d in /dev /dev/pts /proc /sys /run; do
        mount --bind "$d" "${MNT}$d"
    done
    cp /etc/resolv.conf ${MNT}/etc/resolv.conf

    # Step 5: Configure Repos & Generate crypttab / fstab
    configure_apt_sources
    generate_crypttab_and_fstab "$TARGET_ROOT" "$BOOT_PART" "$EFI_PART" "$SWAP_PART" "$ROOT_PART" "$FS_CHOICE" "$ENABLE_LUKS"

    # Step 6: Identity, Locale & Users
    log_info "Configuring hostname, locale, and user accounts..."
    echo "$HOSTNAME" > ${MNT}/etc/hostname
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$HOSTNAME" > ${MNT}/etc/hosts

    chroot ${MNT} ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime 2>/dev/null || true
    echo "$LOCALE UTF-8" > ${MNT}/etc/locale.gen
    echo "LANG=$LOCALE" > ${MNT}/etc/default/locale
    # locale-gen itself runs after Step 7: on a debootstrap base the locales
    # package (which provides it) is not installed yet at this point.

    # Ensure supplemental groups exist before useradd: in a debootstrap base
    # (and on the live image, without bluez) groups like bluetooth/netdev do
    # not exist yet, and a single missing group makes useradd fail wholesale.
    local grp
    for grp in sudo audio video plugdev netdev bluetooth; do
        chroot ${MNT} groupadd -f "$grp" 2>/dev/null || true
    done
    chroot ${MNT} useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth "$USERNAME"
    if ! chroot ${MNT} id -nG "$USERNAME" | grep -qw sudo; then
        log_err "Created user ${USERNAME} is not in the sudo group; refusing to install an admin-less system."
        exit 1
    fi
    log_info "User ${USERNAME} created (groups: $(chroot ${MNT} id -nG "$USERNAME" | tr ' ' ','))."
    echo "${USERNAME}:${USERPASS}" | chroot ${MNT} chpasswd
    echo "root:${USERPASS}" | chroot ${MNT} chpasswd

    # Step 7: Hardware Packages & Services (Phase 3)
    install_hardware_packages

    # Step 7a: Generate locales now that the locales package is present.
    chroot ${MNT} locale-gen || log_warn "locale-gen failed; locales may be incomplete on the target."

    # Step 7b: Keyboard layout through keyboard-configuration (spec §3)
    configure_keyboard "$KEYBOARD_LAYOUT"

    # Step 8: Desktop Environment & Plymouth (Phase 4)
    install_desktop "$DESKTOP_CHOICE" "$ENABLE_KEYD" "$CONFIG_DIR"

    # Step 8b: Session login (autologin) + idle screen lock (Phase 4)
    configure_login "$DESKTOP_CHOICE" "$ENABLE_AUTOLOGIN" "$USERNAME"

    # Step 9: Default Apps & Optional Software
    install_default_apps "$USERNAME"
    install_optional_apps "$EXTRA_APPS"

    # Step 10: GRUB & Initramfs
    log_info "Configuring GRUB and initramfs..."
    local GRUB_CMDLINE="quiet splash loglevel=3"
    if detect_nvidia_gpu; then
        # KMS is required for GDM/KWin to offer a Wayland session on the
        # proprietary driver; without it the DE silently falls back to X11.
        GRUB_CMDLINE+=" nvidia-drm.modeset=1"
    fi
    mkdir -p ${MNT}/etc/default/grub.d
    cat <<EOF > ${MNT}/etc/default/grub.d/installer.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE}"
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
EOF

    # Hibernation: point the kernel at the swap that holds the resume image.
    # LUKS:  swapfile inside the encrypted root (resume_offset in 4K pages).
    # no-LUKS: dedicated plaintext swap partition.
    mkdir -p ${MNT}/etc/initramfs-tools/conf.d
    if [ "$ENABLE_LUKS" = "true" ]; then
        # The Plymouth passphrase dialog decodes keys with the initramfs keymap;
        # without the console keymap a non-US passphrase can never match — the
        # user is locked out of a passphrase they typed correctly.
        if grep -q '^KEYMAP=' ${MNT}/etc/initramfs-tools/initramfs.conf 2>/dev/null; then
            sed -i 's/^KEYMAP=.*/KEYMAP=y/' ${MNT}/etc/initramfs-tools/initramfs.conf
        else
            echo 'KEYMAP=y' >> ${MNT}/etc/initramfs-tools/initramfs.conf
        fi

        local ROOTFS_UUID
        ROOTFS_UUID=$(blkid -s UUID -o value "$TARGET_ROOT")
        require_id "ROOT filesystem UUID" "$ROOTFS_UUID"
        sed -i "s|quiet splash loglevel=3|quiet splash loglevel=3 resume=UUID=${ROOTFS_UUID} resume_offset=${RESUME_OFFSET}|" ${MNT}/etc/default/grub.d/installer.cfg
        echo "RESUME=UUID=${ROOTFS_UUID}" > ${MNT}/etc/initramfs-tools/conf.d/resume
    else
        local SWAP_UUID
        SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
        require_id "SWAP filesystem UUID" "$SWAP_UUID"
        sed -i "s|quiet splash loglevel=3|quiet splash loglevel=3 resume=UUID=${SWAP_UUID}|" ${MNT}/etc/default/grub.d/installer.cfg
        echo "RESUME=UUID=${SWAP_UUID}" > ${MNT}/etc/initramfs-tools/conf.d/resume
    fi

    # Secure Boot chain: shim (MS-signed) -> Debian-signed GRUB -> signed kernel.
    # Works with Secure Boot on and off, so it is always used.
    DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y --no-install-recommends grub-efi-amd64 grub-efi-amd64-signed shim-signed cryptsetup-initramfs

    log_info "Installing GRUB to EFI System Partition..."
    chroot ${MNT} grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
    chroot ${MNT} update-initramfs -u -k all
    chroot ${MNT} update-grub

    # Step 11: Cleanup & Unmount
    unmount_target

    trap - EXIT
    log_success "Installation finished successfully!"
    ui_msgbox "Complete" "Sensible installation has completed successfully!\n\nPlease remove the USB installation drive and reboot the system."
}

# Only execute when run directly; sourcing (tests) can call main() explicitly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
