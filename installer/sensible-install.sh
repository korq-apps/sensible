#!/usr/bin/env bash
# Sensible (aka Lazydeb) Installer — Debian Testing Remix Installer Engine
# https://korq.io
# Gum-based TUI, Omarchy-inspired flow: keyboard → user → disk → encryption → confirm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG_DIR="${SCRIPT_DIR}/../configs"

# Source library modules — order matters: ui first, then common, then setup-form
# shellcheck source=lib/ui.sh
source "${LIB_DIR}/ui.sh"
# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/setup-form.sh
source "${LIB_DIR}/setup-form.sh"
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
        printf '[ERROR] %s\n' "$failure_text" >> "$INSTALL_LOG" \
            || log_warn "Could not append the final failure to ${INSTALL_LOG}."
        if [ "${INSTALLER_OWNS_TARGET_MOUNTS:-false}" = "true" ]; then
            preserve_install_log || log_warn "Could not copy the installer log into the partial target."
        fi
        if ! unmount_target; then
            log_err "Automatic cleanup was incomplete. Do not reboot until ${MNT} is unmounted and the cryptroot mapping is closed."
        fi
        show_failure_screen "${CURRENT_STAGE:-pre-flight}" "$exit_code" "$INSTALL_LOG" || true
    fi
}

# ── Helpers for Omarchy-style flow ──

abort() {
    gum style "${1:-Aborted installation}" 2>/dev/null || log_err "${1:-Aborted}"
    echo
    gum style "You can retry by running: sensible-install" 2>/dev/null || true
    exit 1
}

# Unified user form: username → password (double) → hostname → timezone → locale
# Optional full name/email collected but not required.
# Returns 0 on success, 1 on back (caller should re-prompt keyboard)
_user_form_inner() {
    sensible_prompt_username || return $?
    sensible_prompt_password || return $?
    sensible_prompt_hostname || return $?
    sensible_prompt_timezone || return $?
    sensible_prompt_locale || return $?
    # Optional identity last (skippable)
    sensible_prompt_identity || return $?
    return 0
}

user_form_flow() {
    local status
    while true; do
        step "Let's set up your user account..."
        _user_form_inner && status=0 || status=$?
        if (( status != 0 )); then
            (( status == SETUP_FORM_BACK )) && return $SETUP_FORM_BACK
            (( status == SETUP_FORM_SIGNAL )) && abort
            return $status
        fi

        # Summary table (like Omarchy configurator:273)
        echo
        local summary="Field,Value
Username,$username
Password,$(printf "%${#password}s" | tr ' ' '*')
Hostname,$hostname
Timezone,$timezone
Locale,$locale_val
Full name,${full_name:-[Skipped]}
Email,${email_address:-[Skipped]}
Keyboard,$keyboard"

        if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
            echo -e "$summary" | gum table -s "," -p 2>/dev/tty | sed "s/^/${PADDING_LEFT_SPACES}/" 2>/dev/tty || echo "$summary"
            echo
            if gum confirm --affirmative "Yes, looks good" --negative "No, change it" "Does this look right?" 2>/dev/tty; then
                break
            else
                continue
            fi
        else
            # Text fallback: simple confirm
            echo "$summary" >&2
            echo >&2
            if ui_yesno "Confirm" "Does this look right?" "yes"; then
                break
            fi
        fi
    done
    return 0
}

keyboard_form() {
    step "Let's set up your machine..."
    say --foreground 8 "Keyboard is applied before any password is typed."
    echo
    sensible_prompt_keyboard
    local rc=$?
    if [ $rc -ne 0 ]; then
        return $rc
    fi
    if [[ $(tty 2>/dev/null) == "/dev/tty"* ]]; then
        loadkeys "$keyboard" 2>/dev/null || true
    fi
    return 0
}

disk_form() {
    step "Let's select where to install Sensible..."
    local boot_source exclude_disk
    boot_source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || findmnt -no SOURCE /run/live/medium 2>/dev/null || true)
    exclude_disk=""
    if [ -n "$boot_source" ]; then
        exclude_disk=$(get_root_disk "$boot_source" 2>/dev/null || true)
    fi

    local available
    available=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E '/dev/(sd|hd|vd|nvme|mmcblk|xv)' || true)
    if [ -n "$exclude_disk" ]; then
        available=$(echo "$available" | grep -Fvx "$exclude_disk" || true)
    fi

    # Filter to only candidates (in-use checks)
    local filtered=""
    local dev
    while IFS= read -r dev; do
        [ -z "$dev" ] && continue
        if disk_is_in_use "$dev" 2>/dev/null; then continue; fi
        if disk_below_min "$dev" "$MIN_DISK_MIB" 2>/dev/null; then continue; fi
        filtered+="$dev"$'\n'
    done <<< "$available"

    if [ -z "$(echo "$filtered" | tr -d '[:space:]')" ]; then
        # Fall back to list_candidate_disks for full filtering + message
        local candidates
        mapfile -t candidates < <(list_candidate_disks)
        if [ ${#candidates[@]} -eq 0 ]; then
            return 1
        fi
        # Use ui_menu for fallback
        disk=$(ui_menu "Select Target Disk" "Choose the disk where Sensible will be installed (WARNING: ENTIRE DISK WILL BE WIPED):" "${candidates[@]}")
        echo "$disk"
        return 0
    fi

    local disk_options=""
    while IFS= read -r device; do
        [ -n "$device" ] || continue
        local info
        info=$(get_disk_info "$device")
        disk_options+="$info"$'\n'
    done <<< "$filtered"

    local selected_display
    if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
        selected_display=$(echo "$disk_options" | gum choose --header "Select install disk (entire disk will be wiped)" 2>/dev/tty) || return 1
    else
        # Text/whiptail fallback: build candidates array
        local candidates=()
        while IFS= read -r device; do
            [ -n "$device" ] || continue
            local info size model
            size=$(lsblk -dno SIZE "$device" 2>/dev/null | head -n1)
            model=$(lsblk -dno MODEL "$device" 2>/dev/null | head -n1)
            candidates+=("$device" "${size} - ${model:-Generic_Disk}")
        done <<< "$filtered"
        selected_display=$(ui_menu "Select Target Disk" "Choose the disk where Sensible will be installed (WARNING: ENTIRE DISK WILL BE WIPED):" "${candidates[@]}")
    fi
    disk=$(echo "$selected_display" | awk '{print $1}')
    echo "$disk"
}

confirm_encryption() {
    local mode="encrypted" rc
    while true; do
        clear_logo
        echo
        say "Everything on ${disk} will be overwritten. There is no recovery."
        echo
        if [ "$mode" = "encrypted" ]; then
            say --foreground 8 "Press Ctrl+C for unencrypted install. Encryption recommended."
            if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
                gum confirm --affirmative "Yes, install (encrypted)" --negative "No, change disk" "Confirm overwriting ${disk}?" 2>/dev/tty
                rc=$?
            else
                ui_yesno "Confirm" "Encrypt the system? Password you just set will unlock the disk at boot (recommended)." "yes"
                rc=$?
                if [ $rc -eq 0 ]; then encrypt_installation=true; return 0; else return 1; fi
            fi
        else
            if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
                gum confirm --affirmative "Yes, install without encryption" --negative "No, change disk" "Confirm overwriting ${disk} (unencrypted)?" 2>/dev/tty
                rc=$?
            else
                ui_yesno "Confirm" "Install WITHOUT encryption? Anyone with the disk can read your files." "no"
                rc=$?
                if [ $rc -eq 0 ]; then encrypt_installation=true; return 0; else return 1; fi
            fi
        fi
        case $rc in
            0)  if [ "$mode" = "encrypted" ]; then encrypt_installation=true; else encrypt_installation=false; fi; return 0 ;;
            1)  return 1 ;;
            130) if [ "$mode" = "encrypted" ]; then mode="unencrypted"; else mode="encrypted"; fi ;;
            255) return 1 ;;
            *)  abort ;;
        esac
    done
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

    # Terminal settle + greeter (only on real TTY, not in tests)
    if [ -t 0 ] && command -v gum >/dev/null 2>&1; then
        wait_for_stable_terminal
        greeter
    else
        if [ -t 0 ]; then
            ui_msgbox "Sensible Installer" "Welcome to Sensible (Lazydeb) — Debian Testing Installer.\n\nThis installer will erase one selected disk and configure a ready-to-use Debian workstation. No disk is changed until the final confirmation."
        fi
    fi

    # ── 1. Keyboard ──
    if ! keyboard_form; then
        log_warn "Keyboard setup cancelled."
        exit 1
    fi

    # ── 2. User account (username → password(confirm) → hostname → timezone → locale) ──
    # Globals set by setup-form: keyboard, username, password, hostname, timezone, locale_val, full_name, email_address
    # Also sets USERPASS, LUKS_PASSPHRASE to same password (unified)
    username=""; password=""; hostname="debian"; timezone=""; locale_val="en_US.UTF-8"; full_name=""; email_address=""
    # shellcheck disable=SC2034
    USERPASS=""; LUKS_PASSPHRASE=""
    local user_rc
    user_form_flow && user_rc=0 || user_rc=$?
    if [ $user_rc -ne 0 ]; then
        if [ $user_rc -eq $SETUP_FORM_BACK ]; then
            # Back from user form → re-ask keyboard
            keyboard_form || exit 1
            user_form_flow || exit 1
        else
            exit 1
        fi
    fi
    # Compat aliases for later execution phase
    HOSTNAME="$hostname"
    TIMEZONE="$timezone"
    LOCALE="$locale_val"
    USERNAME="$username"
    USERPASS="$password"
    LUKS_PASSPHRASE="$password"
    KEYBOARD_LAYOUT="$keyboard"

    local RAM_MIB SWAP_MIB MIN_DISK_MIB
    RAM_MIB=$(get_system_ram_mb)
    SWAP_MIB=$(calc_swap_mb)
    MIN_DISK_MIB=$(calc_min_disk_mb)
    log_info "Detected RAM: ${RAM_MIB} MiB. Planned Swap: ${SWAP_MIB} MiB. Min disk required: ${MIN_DISK_MIB} MiB."

    # ── 3. Disk selection with rescan loop ──
    local TARGET_DISK=""
    local NO_DISK_TEXT NO_DISK_CHOICE
    while true; do
        # Try gum-based disk_form first
        local chosen
        chosen=$(disk_form 2>/dev/tty) || chosen=""
        # disk_form prints chosen disk to stdout; if empty, fall back to candidate list logic
        if [ -n "$chosen" ]; then
            TARGET_DISK="$chosen"
            break
        fi

        # Fallback: check if any candidate exists at all
        mapfile -t DISK_CANDIDATES < <(list_candidate_disks)
        if [ ${#DISK_CANDIDATES[@]} -gt 0 ]; then
            TARGET_DISK=$(ui_menu "Select Target Disk" "Choose the disk where Sensible will be installed (WARNING: ENTIRE DISK WILL BE WIPED):" "${DISK_CANDIDATES[@]}")
            [ -n "$TARGET_DISK" ] && break
        fi

        NO_DISK_TEXT="\
No disk qualified as an installation target.

Detected block devices:
$(explain_no_candidates "${MIN_DISK_MIB}")

Sensible needs a disk of at least ${MIN_DISK_MIB} MiB:
  1 GiB EFI + 1 GiB /boot + 20 GiB root + a ${SWAP_MIB} MiB swapfile in it

The swapfile mirrors RAM so the system can hibernate, so the minimum grows
with RAM (this machine has ${RAM_MIB} MiB). In a VM, give the guest a bigger
virtual disk, or less RAM."

        if [ ! -t 0 ]; then
            ui_msgbox "Error: No Installable Disk" "${NO_DISK_TEXT}"
            exit 1
        fi

        NO_DISK_CHOICE=$(ui_menu "Error: No Installable Disk" "${NO_DISK_TEXT}" \
            "rescan" "Look again (after attaching or resizing a disk)" \
            "shell"  "Open a shell to inspect or repartition disks" \
            "quit"   "Quit the installer")
        case "${NO_DISK_CHOICE}" in
            rescan) continue ;;
            shell)
                echo "Starting a shell. Type 'exit' to return to the installer." >&2
                "${SHELL:-/bin/bash}" || true
                ;;
            *) exit 1 ;;
        esac
    done

    # Export for disk_form helper (confirm step)
    disk="$TARGET_DISK"

    if [ -z "$TARGET_DISK" ]; then
        log_warn "Disk selection cancelled."
        exit 1
    fi

    local DISK_SIZE_MIB DISK_SIZE_BYTES DISK_MAJMIN DISK_SERIAL DISK_WWN DISK_MODEL
    DISK_SIZE_BYTES=$(disk_property "$TARGET_DISK" SIZE)
    DISK_SIZE_MIB=$(awk -v bytes="${DISK_SIZE_BYTES:-0}" 'BEGIN { print int(bytes / 1048576) }')
    if [ -z "$DISK_SIZE_MIB" ] || [ "$DISK_SIZE_MIB" -lt "$MIN_DISK_MIB" ]; then
        ui_msgbox "Error: Disk Too Small" "${TARGET_DISK} is ${DISK_SIZE_MIB:-unknown} MiB.\nSensible requires at least ${MIN_DISK_MIB} MiB:\n1 GiB EFI + 1 GiB BOOT + 20 GiB root + a ${SWAP_MIB} MiB swapfile in it."
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

    # ── 4. Encryption (hidden toggle, default encrypted) ──
    local ENABLE_LUKS="true"
    local encrypt_installation=true
    # Gum path with Ctrl-C toggle; text fallback uses simple yes/no
    if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
        local enc_confirmed=false
        while true; do
            if confirm_encryption; then
                enc_confirmed=true
                break
            else
                # User chose "No, change disk" -> re-pick disk
                chosen=$(disk_form 2>/dev/tty) || chosen=""
                if [ -z "$chosen" ]; then
                    log_warn "Disk selection cancelled."
                    exit 1
                fi
                TARGET_DISK="$chosen"
                disk="$TARGET_DISK"
                # Re-validate new disk
                DISK_SIZE_BYTES=$(disk_property "$TARGET_DISK" SIZE)
                DISK_SIZE_MIB=$(awk -v bytes="${DISK_SIZE_BYTES:-0}" 'BEGIN { print int(bytes / 1048576) }')
                DISK_MAJMIN=$(disk_property "$TARGET_DISK" MAJ:MIN)
                DISK_SERIAL=$(disk_property "$TARGET_DISK" SERIAL)
                DISK_WWN=$(disk_property "$TARGET_DISK" WWN)
                DISK_MODEL=$(disk_property "$TARGET_DISK" MODEL)
            fi
        done
        if [ "$encrypt_installation" = "true" ]; then ENABLE_LUKS="true"; else ENABLE_LUKS="false"; fi
    else
        # Text mode: simple yes/no
        if ui_yesno "Protect Your Files (Recommended)" "Encrypt the system and your files?\n\nYou will enter the password at boot (the same password you just set). It cannot be recovered if forgotten. The boot partition stays unencrypted and is protected by Secure Boot." "yes"; then
            ENABLE_LUKS="true"
            encrypt_installation=true
        else
            ENABLE_LUKS="false"
            encrypt_installation=false
        fi
    fi

    # Fixed choices for offline model (no prompts)
    local FS_CHOICE="btrfs"
    local DESKTOP_CHOICE="${SENSIBLE_VARIANT:-gnome}"
    # Validate variant
    case "$DESKTOP_CHOICE" in gnome|kde) ;; *) DESKTOP_CHOICE="gnome" ;; esac
    local ENABLE_KEYD="false"
    [ "$DESKTOP_CHOICE" = "gnome" ] && ENABLE_KEYD="true"
    local EXTRA_APPS=""

    local ENABLE_AUTOLOGIN="false"
    if [ "$ENABLE_LUKS" = "true" ]; then
        if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
            clear_logo; echo
            say "The disk passphrase at boot will unlock the system."
            echo
            if gum confirm --affirmative "Yes, skip login" --negative "No, ask for login" "Boot straight into the desktop (no login password)?" 2>/dev/tty; then
                ENABLE_AUTOLOGIN="true"
            fi
        else
            if ui_yesno "Skip Login Password" "Boot straight into the desktop as ${USERNAME} (no login password)?\n\nThe disk passphrase at boot stays required, the screen still locks on idle,\nand the password is kept for sudo and screen unlock. Without LUKS this is not offered." "yes"; then
                ENABLE_AUTOLOGIN="true"
            fi
        fi
    else
        log_info "Autologin is only offered with full disk encryption."
    fi

    # ── 5. Confirmation ──
    local SUMMARY_TEXT
    SUMMARY_TEXT="SUMMARY OF INSTALLATION CHOICES:\n\n"
    SUMMARY_TEXT+="• Target Disk:   ${TARGET_DISK} (${DISK_MODEL:-Unknown model})\n"
    SUMMARY_TEXT+="• Disk Serial:   ${DISK_SERIAL:-Not reported}\n"
    SUMMARY_TEXT+="• Filesystem:    ${FS_CHOICE}\n"
    SUMMARY_TEXT+="• LUKS2 Encrypt: ${ENABLE_LUKS}\n"
    SUMMARY_TEXT+="• Swap Size:     ${SWAP_MIB} MiB\n"
    SUMMARY_TEXT+="• Desktop:       ${DESKTOP_CHOICE}\n"
    SUMMARY_TEXT+="• Hostname:      ${HOSTNAME}\n"
    SUMMARY_TEXT+="• Username:      ${USERNAME}\n"
    SUMMARY_TEXT+="• Timezone:      ${TIMEZONE}\n"
    SUMMARY_TEXT+="• Locale:        ${LOCALE}\n"
    SUMMARY_TEXT+="• Keyboard:      ${KEYBOARD_LAYOUT}\n\n"
    SUMMARY_TEXT+="WARNING: ALL DATA ON ${TARGET_DISK} WILL BE PERMANENTLY DESTROYED!\n"
    SUMMARY_TEXT+="To confirm, please type the exact disk path (${TARGET_DISK}) below:"

    local CONFIRM_DISK
    if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
        clear_logo; echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "DANGER: Confirm Disk Wipe"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" "$SUMMARY_TEXT"
        echo
        CONFIRM_DISK=$(gum input --placeholder "${TARGET_DISK}" --width 60 2>/dev/tty) || CONFIRM_DISK=""
    else
        CONFIRM_DISK=$(ui_inputbox "DANGER: Confirm Disk Wipe" "$SUMMARY_TEXT" "")
    fi

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

    partition_disk "$TARGET_DISK" "$SWAP_MIB" "$ENABLE_LUKS"

    CURRENT_STAGE="formatting and mounting filesystems"
    format_and_mount "$TARGET_DISK" "$FS_CHOICE" "$ENABLE_LUKS" "$LUKS_PASSPHRASE" "$SWAP_MIB"

    CURRENT_STAGE="deploying the Debian base system"
    log_info "Deploying base system..."
    local DEPLOYED_FROM_LIVE="false"
    if [ -d "${LIVE_ROOT_SENTINEL:-/lib/live}" ] || [ -f /etc/issue.sensible ]; then
        DEPLOYED_FROM_LIVE="true"
        log_info "Copying live environment root to ${MNT} with rsync..."
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
    mkdir -p "${MNT}/dev" "${MNT}/proc" "${MNT}/sys" "${MNT}/run" "${MNT}/tmp" "${MNT}/mnt" "${MNT}/media"
    chmod 1777 "${MNT}/tmp"
    rm -f ${MNT}/etc/systemd/system/getty@tty1.service.d/autologin.conf \
          ${MNT}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf

    rm -f "${MNT}/etc/profile.d/99-sensible-autostart.sh" \
          "${MNT}/etc/profile.d/99-sensible-firmware-check.sh" \
          "${MNT}/usr/local/bin/sensible-install" \
          "${MNT}/usr/local/bin/lazydeb" \
          "${MNT}/etc/issue.sensible"
    rm -rf "${MNT}/opt/sensible"
    printf 'Debian GNU/Linux testing \\n \\l\n' > "${MNT}/etc/issue"
    printf 'Debian GNU/Linux testing\n' > "${MNT}/etc/issue.net"
    : > "${MNT}/etc/motd"

    : > "${MNT}/etc/machine-id"
    [ -L "${MNT}/var/lib/dbus/machine-id" ] || rm -f "${MNT}/var/lib/dbus/machine-id"

    # live-build disables update-initramfs inside the image (update_initramfs=no
    # in update-initramfs.conf) so the ISO build doesn't churn initramfs. The
    # copied target inherits that flag, and then EVERY regeneration here —
    # plymouth-set-default-theme -R, update-initramfs -u — silently no-ops
    # ("I: update-initramfs is disabled"), leaving the LIVE initramfs in /boot.
    # Without a rebuilt initramfs the LUKS root cannot be unlocked at boot.
    # Re-enable before anything regenerates it.
    if [ -f "${MNT}/etc/initramfs-tools/update-initramfs.conf" ]; then
        sed -i 's/^update_initramfs=.*/update_initramfs=yes/' "${MNT}/etc/initramfs-tools/update-initramfs.conf"
        log_info "Re-enabled update-initramfs on the target (live-build ships it disabled)"
    fi

    if [ "$ENABLE_LUKS" = "true" ]; then
        # cryptsetup-initramfs must actually be installed in the target: it
        # provides the initramfs hook, boot scripts, and askpass. It ships in
        # the variant closure lists; a warn-only check here lets an unbootable
        # system through, so abort instead. Tested via the dpkg database (no
        # chroot needed -- this runs before the bind mounts).
        if [ -d "${MNT}/var/lib/dpkg/info" ] \
            && ! ls "${MNT}"/var/lib/dpkg/info/cryptsetup-initramfs.* >/dev/null 2>&1; then
            log_err "cryptsetup-initramfs is not installed in the target closure; the initramfs cannot unlock LUKS. Rebuild the ISO with cryptsetup-initramfs in the variant package list."
            exit 1
        fi
        # No CRYPTSETUP=y conf-hook write here: since buster that file only
        # carries KEYFILE_PATTERN, and the hook copies /sbin/cryptsetup,
        # /sbin/dmsetup, and askpass unconditionally. What actually decides
        # early unlock is the "initramfs" option in /etc/crypttab (fstab.sh),
        # which makes the hook write the mapping into the initramfs crypttab
        # even though root-device detection fails inside a chroot.
        # validate_installed_boot checks the generated initramfs for that
        # mapping before we dare report success.
    fi

    if [ -d "${MNT}/etc/systemd/system" ]; then
        ln -sfn /lib/systemd/system/graphical.target \
                "${MNT}/etc/systemd/system/default.target"
    fi

    CURRENT_STAGE="preparing the installed system"
    log_info "Preparing chroot environment..."
    for d in /dev /dev/pts /proc /sys; do
        mount --bind "$d" "${MNT}$d"
    done
    # /run is mounted as a fresh tmpfs, not a bind of the live host's /run.
    # Runtime state from the installer must not become target state.  In
    # particular, /run/live/medium belongs to the USB, not the installed root.
    # live-tools' update-initramfs diversion is removed below; merely hiding
    # /run/live is not enough, because the wrapper also sees boot=live through
    # the bound /proc and then emits the exact disabled message from the report.
    # A fresh tmpfs is also enough for `chroot systemctl enable ...`, which
    # only writes to /etc/systemd/system.
    log_info "Mounting fresh tmpfs on ${MNT}/run (must NOT be a bind of the live /run)"
    if ! mount -t tmpfs tmpfs "${MNT}/run"; then
        log_err "Could not mount tmpfs on ${MNT}/run. The live /run contains /run/live/medium, which makes update-initramfs refuse to regenerate and leaves the LUKS root un-unlockable. Aborting rather than producing an unbootable install."
        return 1
    fi
    # grub-install sets the NVRAM boot entry through efivarfs, which is a
    # SUBMOUNT of /sys — a plain /sys bind does not carry it, and grub-install
    # then only warns "EFI variables cannot be set on this system", leaving the
    # machine without a boot entry. Bind it explicitly.
    if [ -d /sys/firmware/efi/efivars ] && [ -d "${MNT}/sys/firmware/efi" ]; then
        mount --bind /sys/firmware/efi/efivars "${MNT}/sys/firmware/efi/efivars" || true
    fi
    rm -f "${MNT}/etc/resolv.conf"
    cp -L /etc/resolv.conf "${MNT}/etc/resolv.conf"

    # Strip live-environment markers from the chroot.  Keep dpkg's package
    # metadata intact so the later purge can run maintainer scripts and undo
    # diversions cleanly.
    rm -f "${MNT}/etc/live/version" "${MNT}"/etc/initramfs-tools/scripts/*-live 2>/dev/null || true

    # Offline: when we copied the live root, the package closure is already
    # baked in the ISO. Do not apt-get update or install — it would hit
    # deb.debian.org and fail offline, as in the screenshot. The check-packages
    # gate guarantees the closure at build time.
    if [ "${DEPLOYED_FROM_LIVE}" != "true" ]; then
        configure_apt_sources
    else
        log_info "Offline install — skipping apt update (live root already contains the closure)"
    fi
    generate_crypttab_and_fstab "$TARGET_ROOT" "$BOOT_PART" "$EFI_PART" "$SWAP_PART" "$ROOT_PART" "$FS_CHOICE" "$ENABLE_LUKS"

    log_info "Configuring hostname and locale..."
    echo "$HOSTNAME" > ${MNT}/etc/hostname
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$HOSTNAME" > ${MNT}/etc/hosts

    chroot ${MNT} ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$LOCALE UTF-8" > ${MNT}/etc/locale.gen
    echo "LANG=$LOCALE" > ${MNT}/etc/default/locale

    CURRENT_STAGE="installing hardware support"
    if [ "${DEPLOYED_FROM_LIVE}" != "true" ]; then
        install_hardware_packages
    else
        log_info "Offline install — skipping hardware apt install (firmware baked in)"
        # Still enable services that would have been enabled
        chroot ${MNT} systemctl enable NetworkManager.service 2>/dev/null || true
        chroot ${MNT} systemctl enable bluetooth.service 2>/dev/null || true
        chroot ${MNT} systemctl enable power-profiles-daemon.service 2>/dev/null || true
        chroot ${MNT} systemctl enable fwupd.service 2>/dev/null || true
    fi

    chroot ${MNT} locale-gen 2>/dev/null || log_warn "locale-gen failed (locales not yet in closure?)"

    configure_keyboard "$KEYBOARD_LAYOUT"

    CURRENT_STAGE="installing the desktop"
    if [ "${DEPLOYED_FROM_LIVE}" != "true" ]; then
        install_desktop "$DESKTOP_CHOICE" "$ENABLE_KEYD" "$CONFIG_DIR"
    else
        log_info "Offline install — skipping desktop apt install (DE baked in)"
        # Ensure display manager and keyd are enabled if their packages are present
        if [ "$DESKTOP_CHOICE" = "gnome" ]; then
            chroot ${MNT} systemctl enable gdm3.service 2>/dev/null || true
        else
            chroot ${MNT} systemctl enable sddm.service 2>/dev/null || true
        fi
        if [ -f "${MNT}/etc/keyd/default.conf" ] || [ "$ENABLE_KEYD" = "true" ]; then
            chroot ${MNT} systemctl enable keyd.service 2>/dev/null || true
        fi
        # Plymouth theme already baked — ensure it matches variant
        local plymouth_theme="spinner"
        [ "$DESKTOP_CHOICE" = "kde" ] && plymouth_theme="breeze"
        chroot ${MNT} plymouth-set-default-theme -R "$plymouth_theme" 2>/dev/null || true
    fi

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

    # Store optional identity for git/GECOS if provided
    if [ -n "${full_name:-}" ]; then
        chroot ${MNT} chfn -f "$full_name" "$USERNAME" 2>/dev/null || true
        mkdir -p "${MNT}/home/${USERNAME}"
        # git identity for user (per-user, not system)
        if [ -n "${email_address:-}" ]; then
            cat > "${MNT}/home/${USERNAME}/.gitconfig" <<EOF
[user]
	name = $full_name
	email = $email_address
EOF
            chroot ${MNT} chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.gitconfig" 2>/dev/null || true
        fi
    fi

    configure_login "$DESKTOP_CHOICE" "$ENABLE_AUTOLOGIN" "$USERNAME"

    CURRENT_STAGE="installing applications"
    if [ "${DEPLOYED_FROM_LIVE}" != "true" ]; then
        install_default_apps "$USERNAME"
    else
        log_info "Offline install — skipping default-apps apt install (apps baked in)"
        # Still ensure LazyVim skel and flathub where possible, without network
        mkdir -p "${MNT}/etc/skel/.config/nvim" 2>/dev/null || true
        if [ ! -f "${MNT}/etc/skel/.config/nvim/init.lua" ] && [ -d "${MNT}/usr/share/sensible/nvim-starter" ]; then
            cp -r "${MNT}/usr/share/sensible/nvim-starter" "${MNT}/etc/skel/.config/nvim" 2>/dev/null || true
        fi
        if [ -n "$USERNAME" ] && [ -d "${MNT}/home/$USERNAME" ] && [ -d "${MNT}/etc/skel/.config/nvim" ]; then
            mkdir -p "${MNT}/home/$USERNAME/.config"
            cp -r "${MNT}/etc/skel/.config/nvim" "${MNT}/home/$USERNAME/.config/" 2>/dev/null || true
            chroot ${MNT} chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config" 2>/dev/null || true
        fi
        chroot ${MNT} flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
    fi

    if [ "$DEPLOYED_FROM_LIVE" = "true" ]; then
        CURRENT_STAGE="removing live-environment packages"
        # Purge the whole live stack in ONE transaction. Purging one at a time
        # hits an unsatisfiable dependency state: `live-config` Depends:
        # `live-config-systemd`, so removing only the -systemd split makes apt's
        # solver fail with "Unable to satisfy dependencies ... Solver timed out"
        # (exit 100) — after the disk was already written. All live-* packages
        # are local removals; `dpkg --purge` needs no network and no solver.
        local LIVE_PKGS=()
        local live_pkg
        # live-tools is boot-critical here: it diverts Debian's real
        # /usr/sbin/update-initramfs to live-update-initramfs.  Inside this
        # chroot that wrapper still sees "boot=live" through the bound /proc,
        # but the fresh /run deliberately hides /run/live/medium, so it exits
        # 0 without rebuilding anything.  Its postrm restores the original
        # command when live-tools is removed.  Remove the live initramfs hooks
        # at the same time so later kernel upgrades build an installed-system
        # initramfs rather than a live one.
        for live_pkg in live-boot live-boot-initramfs-tools live-config live-config-systemd live-tools; do
            if chroot ${MNT} dpkg-query -W -f='${db:Status-Abbrev}' "$live_pkg" 2>/dev/null | grep -q '^ii '; then
                LIVE_PKGS+=("$live_pkg")
            fi
        done
        if [ ${#LIVE_PKGS[@]} -gt 0 ]; then
            log_info "Purging live packages offline: ${LIVE_PKGS[*]}"
            DEBIAN_FRONTEND=noninteractive chroot ${MNT} dpkg --purge "${LIVE_PKGS[@]}" \
                || record_warning "Live packages could not be purged cleanly: ${LIVE_PKGS[*]}"
        fi
        rm -rf "${MNT}/lib/live" "${MNT}/usr/lib/live" "${MNT}/var/lib/live"

        # Do not trust dpkg's aggregate exit alone: a maintainer-script failure
        # can leave the live-tools diversion behind, and the wrapper deliberately
        # exits 0 after printing that update-initramfs is disabled.  That exact
        # state produces a stale initramfs with no cryptroot mapping.
        local update_initramfs_path="${MNT}/usr/sbin/update-initramfs"
        local update_initramfs_target=""
        if [ -L "${update_initramfs_path}" ]; then
            update_initramfs_target=$(readlink "${update_initramfs_path}" 2>/dev/null || true)
        fi
        if [ ! -x "${update_initramfs_path}" ]; then
            log_err "The target has no executable /usr/sbin/update-initramfs after removing live packages."
            return 1
        fi
        if [ "${update_initramfs_target##*/}" = "live-update-initramfs" ]; then
            log_err "live-tools still diverts update-initramfs in the target; refusing to build an initramfs with the live-system wrapper."
            return 1
        fi
    fi

    CURRENT_STAGE="installing the bootloader"
    log_info "Configuring GRUB and initramfs..."
    local GRUB_CMDLINE="quiet splash loglevel=3"
    if detect_nvidia_gpu; then
        GRUB_CMDLINE+=" nvidia-drm.modeset=1"
    fi
    mkdir -p ${MNT}/etc/default/grub.d
    cat <<EOF > ${MNT}/etc/default/grub.d/installer.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE}"
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
EOF

    mkdir -p ${MNT}/etc/initramfs-tools/conf.d
    if [ "$ENABLE_LUKS" = "true" ]; then
        if grep -q '^KEYMAP=' ${MNT}/etc/initramfs-tools/initramfs.conf 2>/dev/null; then
            sed -i 's/^KEYMAP=.*/KEYMAP=y/' ${MNT}/etc/initramfs-tools/initramfs.conf
        else
            echo 'KEYMAP=y' >> ${MNT}/etc/initramfs-tools/initramfs.conf
        fi
    fi

    local ROOTFS_UUID
    ROOTFS_UUID=$(blkid -s UUID -o value "$TARGET_ROOT")
    require_id "ROOT filesystem UUID" "$ROOTFS_UUID"
    sed -i "s|quiet splash loglevel=3|quiet splash loglevel=3 resume=UUID=${ROOTFS_UUID} resume_offset=${RESUME_OFFSET}|" ${MNT}/etc/default/grub.d/installer.cfg
    echo "RESUME=UUID=${ROOTFS_UUID}" > ${MNT}/etc/initramfs-tools/conf.d/resume

    if [ "${DEPLOYED_FROM_LIVE}" != "true" ]; then
        DEBIAN_FRONTEND=noninteractive chroot ${MNT} apt-get install -y --no-install-recommends grub-efi-amd64 grub-efi-amd64-signed shim-signed cryptsetup-initramfs
    else
        log_info "Offline install — skipping grub/shim/cryptsetup apt install (already in closure)"
        # Verify required packages are present offline
        for pkg in grub-efi-amd64 shim-signed cryptsetup-initramfs; do
            if ! chroot ${MNT} dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii '; then
                log_warn "Offline closure missing $pkg — boot may fail (rebuild ISO with variant closure)"
            fi
        done
    fi

    log_info "Installing GRUB to EFI System Partition..."
    chroot ${MNT} grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
    chroot ${MNT} update-initramfs -u -k all
    chroot ${MNT} update-grub

    CURRENT_STAGE="verifying the installed system can boot"
    local BOOT_PROBLEMS
    if ! BOOT_PROBLEMS=$(validate_installed_boot "${MNT}" "${ENABLE_LUKS}"); then
        log_err "Post-install verification failed; the installed system would not boot."
        ui_msgbox "Error: Installed System Cannot Boot" "\
Sensible finished writing to ${TARGET_DISK}, but the result would not boot:

${BOOT_PROBLEMS}

The disk has been written, so it is not left in its original state. The
installer log is at ${INSTALL_LOG}, and a copy is placed on the target
before it is unmounted.

Reporting this as a successful install would only surface the problem after
a reboot, with the installer gone."
        exit 1
    fi
    log_success "Post-install verification passed: kernel, initramfs, GRUB, and fstab are in place."

    CURRENT_STAGE="finalizing the installer log"
    stop_install_log
    preserve_install_log || record_warning "The installer log could not be copied to the installed system."

    CURRENT_STAGE="safely unmounting the installed system"
    unmount_target

    trap - EXIT
    log_success "Installation finished successfully!"
    local COMPLETE_TEXT="Sensible installation completed successfully.

Installed to: ${TARGET_DISK}
Desktop: ${DESKTOP_CHOICE}
Encryption: ${ENABLE_LUKS}"
    if [ ${#INSTALL_WARNINGS[@]} -gt 0 ]; then
        COMPLETE_TEXT+=$'\n\nCompleted with warnings:'
        local warning
        for warning in "${INSTALL_WARNINGS[@]}"; do
            COMPLETE_TEXT+=$'\n- '"${warning}"
        done
    fi
    [ "$ENABLE_LUKS" = "true" ] && COMPLETE_TEXT+=$'\n\nOn first boot, enter the encryption passphrase (same as your login password).'

    local completion_action
    if ! completion_action=$(ui_menu "Installation Complete" "${COMPLETE_TEXT}

What would you like to do next?" \
        "reboot" "Reboot now and eject optical installation media" \
        "live"   "Stay in the live session"); then
        # Esc/Escape in a graphical menu is the non-destructive choice.
        completion_action="live"
    fi

    case "${completion_action}" in
        reboot)
            log_info "Reboot requested. Optical installation media will be ejected during shutdown; remove USB media as the machine restarts."
            sync
            # Debian live-tools runs live-medium-eject from systemd's shutdown
            # hook. Calling it here would be too early: the running squashfs
            # may still need the medium before systemd reaches final shutdown.
            if command -v systemctl >/dev/null 2>&1 && systemctl reboot; then
                return 0
            fi
            if command -v reboot >/dev/null 2>&1 && reboot; then
                return 0
            fi
            log_err "The reboot command failed. Remove the installation media and reboot manually."
            ui_msgbox "Reboot Failed" "The installation is complete, but Sensible could not reboot this machine.\n\nRemove the installation media and reboot manually."
            return 1
            ;;
        live)
            log_info "Remaining in the live session. Remove the installation media before the next boot."
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
