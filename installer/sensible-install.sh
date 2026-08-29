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
# shellcheck source=lib/verify.sh
source "${LIB_DIR}/verify.sh"

# Trap errors for cleanup
CURRENT_STAGE="pre-flight"
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        local failure_text="Installation interrupted or failed during ${CURRENT_STAGE:-pre-flight} (exit code ${exit_code})."
        if [ "$INSTALL_LOG_ACTIVE" = "true" ]; then
            log_err "$failure_text"
            stop_install_log || true
        else
            log_err "$failure_text"
        fi
        # Keep a plain, synchronous marker for support and for the copy below.
        printf '[ERROR] %s\n' "$failure_text" >> "$INSTALL_LOG" \
            || log_warn "Could not append the final failure to ${INSTALL_LOG}."
        if [ "${INSTALLER_OWNS_TARGET_MOUNTS:-false}" = "true" ]; then
            preserve_install_log || log_warn "Could not copy the installer log into the partial target."
        fi
        if ! unmount_target; then
            log_err "Automatic cleanup was incomplete. Do not reboot until ${MNT} is unmounted and the cryptroot mapping is closed."
        fi
    fi
}

main() {
    check_root
    start_install_log
    trap cleanup EXIT
    check_uefi

    CURRENT_STAGE="pre-flight"
    if target_mount_tree_busy "$MNT"; then
        ui_msgbox "Error: Installation Mount In Use" "${MNT} or a path below it is already mounted. Sensible will not reuse or unmount resources it did not create. Unmount that path, then restart the installer."
        exit 1
    fi

    # 1. Welcome, keyboard, and network pre-flight. Keyboard comes first so a
    # Wi-Fi password entered in NetworkManager uses the intended layout too.
    ui_msgbox "Sensible Installer" "Welcome to Sensible (Lazydeb) — Debian Testing Installer.\n\nThis installer will erase one selected disk and configure a ready-to-use Debian workstation. Internet access is required, and no disk is changed until the final confirmation."

    local KEYBOARD_LAYOUT
    KEYBOARD_LAYOUT=$(detect_keyboard_layout)
    while true; do
        KEYBOARD_LAYOUT=$(ui_inputbox "Keyboard" "Enter keyboard layout. It will be applied before network or account passwords:" "${KEYBOARD_LAYOUT:-us}")
        KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-us}"
        if ! validate_keyboard_layout "$KEYBOARD_LAYOUT"; then
            ui_msgbox "Invalid Keyboard" "Keyboard layout '${KEYBOARD_LAYOUT}' is not installed. Use a layout code such as us, gb, de, fr, or es."
            continue
        fi
        if ! apply_live_keyboard "$KEYBOARD_LAYOUT" "${LIVE_KEYBOARD_FILE:-/etc/default/keyboard}"; then
            ui_msgbox "Keyboard Setup Failed" "Sensible could not apply '${KEYBOARD_LAYOUT}' to this console. Choose another layout; passwords will not be requested until it succeeds."
            continue
        fi
        break
    done

    ensure_network || exit 1

    local RAM_MIB SWAP_MIB MIN_DISK_MIB
    RAM_MIB=$(get_system_ram_mb)
    SWAP_MIB=$(calc_swap_mb)
    MIN_DISK_MIB=$(calc_min_disk_mb)

    log_info "Detected RAM: ${RAM_MIB} MiB. Planned Swap: ${SWAP_MIB} MiB. Min disk required: ${MIN_DISK_MIB} MiB."

    # Parse candidate disks
    mapfile -t DISK_CANDIDATES < <(list_candidate_disks)
    if [ ${#DISK_CANDIDATES[@]} -eq 0 ]; then
        ui_msgbox "Error: No Installable Disk" "\
No disk qualified as an installation target.

Detected block devices:
$(explain_no_candidates "${MIN_DISK_MIB}")

Sensible needs a disk of at least ${MIN_DISK_MIB} MiB:
  1 GiB EFI + 1 GiB /boot + ${SWAP_MIB} MiB swap + 20 GiB root

Swap is sized to RAM + 10% so the system can hibernate, so the minimum
grows with RAM (this machine has ${RAM_MIB} MiB). In a VM, give the guest
a bigger virtual disk, or less RAM."
        exit 1
    fi

    # 2. Disk Selection
    local TARGET_DISK
    TARGET_DISK=$(ui_menu "Select Target Disk" "Choose the disk where Sensible will be installed (WARNING: ENTIRE DISK WILL BE WIPED):" "${DISK_CANDIDATES[@]}")
    if [ -z "$TARGET_DISK" ]; then
        log_warn "Disk selection cancelled."
        exit 1
    fi

    # 2b. Minimum disk size (spec §1)
    local DISK_SIZE_MIB DISK_SIZE_BYTES DISK_MAJMIN DISK_SERIAL DISK_WWN DISK_MODEL
    # -d: whole disk only, else a partitioned disk emits one row per partition
    # and DISK_SIZE_MIB becomes multi-line (non-numeric), making the -lt test
    # below silently false -- letting an undersized disk through to the wipe.
    DISK_SIZE_BYTES=$(disk_property "$TARGET_DISK" SIZE)
    DISK_SIZE_MIB=$(awk -v bytes="${DISK_SIZE_BYTES:-0}" 'BEGIN { print int(bytes / 1048576) }')
    if [ -z "$DISK_SIZE_MIB" ] || [ "$DISK_SIZE_MIB" -lt "$MIN_DISK_MIB" ]; then
        ui_msgbox "Error: Disk Too Small" "${TARGET_DISK} is ${DISK_SIZE_MIB:-unknown} MiB.\nSensible requires at least ${MIN_DISK_MIB} MiB:\n1 GiB EFI + 1 GiB BOOT + ${SWAP_MIB} MiB swap + 20 GiB root."
        log_err "Selected disk ${TARGET_DISK} is too small: ${DISK_SIZE_MIB:-unknown} MiB < ${MIN_DISK_MIB} MiB."
        exit 1
    fi
    DISK_MAJMIN=$(disk_property "$TARGET_DISK" MAJ:MIN)
    DISK_SERIAL=$(disk_property "$TARGET_DISK" SERIAL)
    DISK_WWN=$(disk_property "$TARGET_DISK" WWN)
    DISK_MODEL=$(disk_property "$TARGET_DISK" MODEL)
    if [ -z "$DISK_MAJMIN" ] || [ -z "$DISK_SIZE_BYTES" ]; then
        ui_msgbox "Error: Disk Identification Failed" "Sensible could not read a stable identity for ${TARGET_DISK}. No changes were made."
        exit 1
    fi
    log_info "Selected disk ${TARGET_DISK}: ${DISK_SIZE_MIB} MiB (minimum ${MIN_DISK_MIB} MiB)."

    # 3. Filesystem Selection
    local FS_CHOICE
    FS_CHOICE=$(ui_menu "Filesystem" "Choose root filesystem layout:" \
        "btrfs" "Btrfs with subvolumes (@, @home, @snapshots, @var_log)" \
        "ext4" "Ext4 single volume with fast_commit")
    FS_CHOICE="${FS_CHOICE:-btrfs}"

    # 4. Remaining regional settings
    local TIMEZONE
    TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    while true; do
        TIMEZONE=$(ui_inputbox "Timezone" "Enter timezone (e.g. UTC, America/New_York, Europe/London):" "${TIMEZONE:-UTC}")
        TIMEZONE="${TIMEZONE:-UTC}"
        if valid_timezone "$TIMEZONE"; then
            break
        fi
        ui_msgbox "Invalid Timezone" "/usr/share/zoneinfo/${TIMEZONE} does not exist.\nUse an IANA name like Europe/Berlin or America/New_York."
    done

    local LOCALE="en_US.UTF-8"
    while true; do
        LOCALE=$(ui_inputbox "Locale" "Enter system locale:" "${LOCALE}")
        LOCALE="${LOCALE:-en_US.UTF-8}"
        if [ -r /usr/share/i18n/SUPPORTED ] \
            && awk -v loc="${LOCALE}" '$1 == loc && $2 == "UTF-8" { found = 1 } END { exit !found }' /usr/share/i18n/SUPPORTED; then
            break
        fi
        ui_msgbox "Invalid Locale" "${LOCALE} was not found in /usr/share/i18n/SUPPORTED (UTF-8).\nExample: en_US.UTF-8"
    done

    # 5. LUKS2 Encryption
    local ENABLE_LUKS
    if ui_yesno "Protect Your Files (Recommended)" "Encrypt the Debian system and your personal files?\n\nYou will enter this passphrase whenever the computer starts. It cannot be recovered if forgotten. The small boot partition remains unencrypted and is protected by Secure Boot."; then
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

    # 6. Desktop Environment
    local DESKTOP_CHOICE
    DESKTOP_CHOICE=$(ui_menu "Desktop Environment" "Choose your desktop environment (Wayland session):" \
        "gnome" "GNOME Desktop (macOS-oriented, gestures, gdm3)" \
        "kde" "KDE Plasma (Windows-oriented, panel, sddm)")
    DESKTOP_CHOICE="${DESKTOP_CHOICE:-gnome}"

    # 7. Mac Clipboard (keyd)
    local ENABLE_KEYD="false"
    local KEYD_DEFAULT="yes"
    [ "$DESKTOP_CHOICE" = "kde" ] && KEYD_DEFAULT="no"
    if ui_yesno "Mac Clipboard (keyd)" "Enable Mac clipboard shortcuts (Super+C/V/X -> Ctrl/Shift+Insert)?\n\nTerminal-safe: does not send SIGINT." "$KEYD_DEFAULT"; then
        ENABLE_KEYD="true"
    fi

    # 8. Optional Software Checkboxes
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

    # 9. Hostname
    local HOSTNAME="debian"
    while true; do
        HOSTNAME=$(ui_inputbox "Computer Name" "Choose a name for this computer:" "$HOSTNAME")
        HOSTNAME="${HOSTNAME:-debian}"
        if valid_hostname "$HOSTNAME"; then
            break
        fi
        ui_msgbox "Invalid Computer Name" "Use letters, numbers, hyphens, and dots. Each part must start and end with a letter or number."
    done

    # 10. User Account & Password
    local USERNAME=""
    while true; do
        USERNAME=$(ui_inputbox "Username" "Enter primary username (lowercase, starts with letter):" "")
        if valid_username "$USERNAME"; then
            break
        fi
        ui_msgbox "Invalid Username" "Use up to 32 lowercase letters, numbers, hyphens, or underscores, starting with a letter or underscore. Reserved system account names cannot be used."
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

    # 10b. Optional autologin — only meaningful with disk encryption: the LUKS
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

    # 11. Confirmation / Wipe Warning
    ensure_network || exit 1

    local SUMMARY_TEXT
    SUMMARY_TEXT="SUMMARY OF INSTALLATION CHOICES:\n\n"
    SUMMARY_TEXT+="• Target Disk:   ${TARGET_DISK} (${DISK_MODEL:-Unknown model})\n"
    SUMMARY_TEXT+="• Disk Serial:   ${DISK_SERIAL:-Not reported}\n"
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

    if ! validate_target_disk "$TARGET_DISK" "$MIN_DISK_MIB" "$DISK_MAJMIN" "$DISK_SIZE_BYTES" "$DISK_SERIAL" "$DISK_WWN"; then
        ui_msgbox "Disk Changed or In Use" "${TARGET_DISK} no longer matches the selected disk, is now in use, or cannot be identified safely. No disk was changed. Restart the installer and check the disk selection."
        exit 1
    fi

    # === EXECUTION PHASE ===
    CURRENT_STAGE="partitioning the selected disk"
    log_info "Beginning installation onto ${TARGET_DISK}..."

    # Step 1: Partitioning
    partition_disk "$TARGET_DISK" "$SWAP_MIB" "$ENABLE_LUKS"

    # Step 2: Formatting & Mounting
    CURRENT_STAGE="formatting and mounting filesystems"
    format_and_mount "$TARGET_DISK" "$FS_CHOICE" "$ENABLE_LUKS" "$LUKS_PASSPHRASE" "$SWAP_MIB"

    # Step 3: Base Deployment
    CURRENT_STAGE="deploying the Debian base system"
    log_info "Deploying base system..."
    local DEPLOYED_FROM_LIVE="false"
    if [ -d "${LIVE_ROOT_SENTINEL:-/lib/live}" ] || [ -f /etc/issue.sensible ]; then
        DEPLOYED_FROM_LIVE="true"
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

    # Strip every live-only launcher and identity marker. Leaving these behind
    # would make a later tty login offer the destructive installer again.
    rm -f "${MNT}/etc/profile.d/99-sensible-autostart.sh" \
          "${MNT}/etc/profile.d/99-sensible-firmware-check.sh" \
          "${MNT}/usr/local/bin/sensible-install" \
          "${MNT}/usr/local/bin/lazydeb" \
          "${MNT}/etc/issue.sensible"
    rm -rf "${MNT}/opt/sensible"
    printf 'Debian GNU/Linux testing \\n \\l\n' > "${MNT}/etc/issue"
    printf 'Debian GNU/Linux testing\n' > "${MNT}/etc/issue.net"
    : > "${MNT}/etc/motd"

    # The rsync path copies the live session's /etc/machine-id, so every install
    # from one boot would inherit the same identity (journald, DHCP DUIDs and
    # other machine-ID consumers then collide). An empty /etc/machine-id is
    # systemd's documented "first boot" marker: it regenerates one at boot.
    : > "${MNT}/etc/machine-id"
    # Debian usually symlinks this to /etc/machine-id; drop it only if the copy
    # left a real file behind, so the symlink is preserved when present.
    [ -L "${MNT}/var/lib/dbus/machine-id" ] || rm -f "${MNT}/var/lib/dbus/machine-id"

    # Step 4: Bind Mounts & DNS
    CURRENT_STAGE="preparing the installed system"
    log_info "Preparing chroot environment..."
    for d in /dev /dev/pts /proc /sys /run; do
        mount --bind "$d" "${MNT}$d"
    done
    rm -f "${MNT}/etc/resolv.conf"
    cp -L /etc/resolv.conf "${MNT}/etc/resolv.conf"

    # Step 5: Configure Repos & Generate crypttab / fstab
    configure_apt_sources
    generate_crypttab_and_fstab "$TARGET_ROOT" "$BOOT_PART" "$EFI_PART" "$SWAP_PART" "$ROOT_PART" "$FS_CHOICE" "$ENABLE_LUKS"

    # Step 6: Identity and locale. User creation waits until package-owned
    # service accounts exist, preventing names such as sddm from colliding.
    log_info "Configuring hostname and locale..."
    echo "$HOSTNAME" > ${MNT}/etc/hostname
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$HOSTNAME" > ${MNT}/etc/hosts

    chroot ${MNT} ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$LOCALE UTF-8" > ${MNT}/etc/locale.gen
    echo "LANG=$LOCALE" > ${MNT}/etc/default/locale
    # locale-gen itself runs after Step 7: on a debootstrap base the locales
    # package (which provides it) is not installed yet at this point.

    # Step 7: Hardware Packages & Services (Phase 3)
    CURRENT_STAGE="installing hardware support"
    install_hardware_packages

    # Step 7a: Generate locales now that the locales package is present.
    chroot ${MNT} locale-gen

    # Step 7b: Keyboard layout through keyboard-configuration (spec §3)
    configure_keyboard "$KEYBOARD_LAYOUT"

    # Step 8: Desktop Environment & Plymouth (Phase 4)
    CURRENT_STAGE="installing the desktop"
    install_desktop "$DESKTOP_CHOICE" "$ENABLE_KEYD" "$CONFIG_DIR"

    CURRENT_STAGE="creating the user account"
    if chroot ${MNT} getent passwd "$USERNAME" >/dev/null 2>&1; then
        log_err "Username ${USERNAME} is reserved by an installed system package."
        exit 1
    fi
    local grp
    for grp in sudo audio video plugdev netdev bluetooth; do
        chroot ${MNT} groupadd -f "$grp"
    done
    chroot ${MNT} useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth "$USERNAME"
    if ! chroot ${MNT} id -nG "$USERNAME" | grep -qw sudo; then
        log_err "Created user ${USERNAME} is not in the sudo group; refusing to install an admin-less system."
        exit 1
    fi
    log_info "User ${USERNAME} created (groups: $(chroot ${MNT} id -nG "$USERNAME" | tr ' ' ','))."
    echo "${USERNAME}:${USERPASS}" | chroot ${MNT} chpasswd
    echo "root:${USERPASS}" | chroot ${MNT} chpasswd

    # Step 8b: Session login (autologin) + idle screen lock (Phase 4)
    configure_login "$DESKTOP_CHOICE" "$ENABLE_AUTOLOGIN" "$USERNAME"

    # Step 9: Default Apps & Optional Software
    CURRENT_STAGE="installing applications"
    install_default_apps "$USERNAME"
    install_optional_apps "$EXTRA_APPS"

    # Live packages are useful only while booted from the ISO. Purge them before
    # rebuilding initramfs so no live-boot hooks survive on the installed disk.
    if [ "$DEPLOYED_FROM_LIVE" = "true" ]; then
        local live_pkg
        for live_pkg in live-config-systemd live-config live-boot; do
            if chroot ${MNT} dpkg-query -W -f='${db:Status-Abbrev}' "$live_pkg" 2>/dev/null | grep -q '^ii '; then
                DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get purge -y "$live_pkg"
            fi
        done
        rm -rf "${MNT}/lib/live" "${MNT}/usr/lib/live" "${MNT}/var/lib/live"
    fi

    # Step 10: GRUB & Initramfs
    CURRENT_STAGE="installing the bootloader"
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

    # Step 11: Verify the installed system can actually boot. Everything above
    # can succeed command-by-command and still leave an unbootable machine, and
    # that only shows up after the reboot, with the installer gone.
    CURRENT_STAGE="verifying the installed system can boot"
    local BOOT_PROBLEMS
    if ! BOOT_PROBLEMS=$(validate_installed_boot "${MNT}" "${ENABLE_LUKS}"); then
        log_err "Post-install verification failed; the installed system would not boot."
        ui_msgbox "Error: Installed System Cannot Boot" "\
Sensible finished writing to ${TARGET_DISK}, but the result would not boot:

${BOOT_PROBLEMS}

Nothing has been unmounted yet, so the target is still available at ${MNT}
for inspection. The installer log is at ${INSTALL_LOG}.

Reporting this as a successful install would only surface the problem after
a reboot, with the installer gone."
        exit 1
    fi
    log_success "Post-install verification passed: kernel, initramfs, GRUB, and fstab are in place."

    # Step 12: Flush and preserve the log before target teardown.
    CURRENT_STAGE="finalizing the installer log"
    stop_install_log
    preserve_install_log || record_warning "The installer log could not be copied to the installed system."

    CURRENT_STAGE="safely unmounting the installed system"
    unmount_target

    trap - EXIT
    log_success "Installation finished successfully!"
    local COMPLETE_TEXT="Sensible installation completed successfully.\n\nInstalled to: ${TARGET_DISK}\nDesktop: ${DESKTOP_CHOICE}\nEncryption: ${ENABLE_LUKS}\n\nRemove the USB installation drive and reboot."
    if [ ${#INSTALL_WARNINGS[@]} -gt 0 ]; then
        COMPLETE_TEXT+="\n\nCompleted with warnings:\n"
        local warning
        for warning in "${INSTALL_WARNINGS[@]}"; do
            COMPLETE_TEXT+="- ${warning}\n"
        done
    fi
    [ "$ENABLE_LUKS" = "true" ] && COMPLETE_TEXT+="\nOn first boot, enter the encryption passphrase you created."
    ui_msgbox "Complete" "$COMPLETE_TEXT"
}

# Only execute when run directly; sourcing (tests) can call main() explicitly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
