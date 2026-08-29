#!/usr/bin/env bash
# Post-install verification: refuse to report success on a system that cannot boot.
#
# Everything here runs against the still-mounted target, after GRUB and the
# initramfs have been generated and before unmount. The installer otherwise
# ends with "Installation finished successfully!" purely because no command
# returned non-zero -- and the failure mode that costs the most is exactly the
# one that stays silent until the machine is rebooted with the installer gone.
# Each check asserts an artifact that must exist for the machine to boot, so a
# missing one is reported here, in front of the person who can still fix it.

# Failure screen: say what broke, show the end of the log, and offer something
# to do about it.
#
# A failed install otherwise ends at a bare shell prompt with the reason already
# scrolled off, on a machine with no installed system to boot into -- so the log
# is only reachable by someone who knows it exists and where it lives.
#
# Only runs with a human present: stdin must be a terminal. Tests and any
# unattended run feed stdin from a file, where a menu would hang the run
# instead of failing it.
show_failure_screen() {
    local stage="$1" exit_code="$2" log_file="${3:-${INSTALL_LOG}}"
    [ -t 0 ] || return 0
    [ "${SENSIBLE_NO_FAILURE_SCREEN:-}" = "1" ] && return 0

    while true; do
        local tail_text="(no installer log was written)"
        if [ -s "${log_file}" ]; then
            # Strip colour escapes: the log keeps the codes log_info and friends
            # emit, and whiptail renders them literally, so an unfiltered tail
            # reads as ^[[1;34m[INFO]^[[0m and buries the actual error.
            tail_text="$(tail -n 12 "${log_file}" \
                | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][A-B0]//g')"
        fi

        local choice
        choice=$(ui_menu "Installation Failed" "\
Sensible stopped while ${stage} (exit code ${exit_code}).

Last lines of the installer log:
${tail_text}

Full log: ${log_file}" \
            "log"      "View the full installer log" \
            "shell"    "Open a shell to investigate" \
            "reboot"   "Reboot this machine" \
            "poweroff" "Power off this machine")

        case "${choice}" in
            log)
                if command -v less >/dev/null 2>&1; then
                    less "${log_file}"
                else
                    # No pager: page it manually rather than flooding the screen
                    # with a log the user cannot scroll back through.
                    tail -n 200 "${log_file}"
                    read -rp "Press Enter to return..." _
                fi
                ;;
            shell)
                echo "Starting a shell. Type 'exit' to return to this screen." >&2
                "${SHELL:-/bin/bash}" || true
                ;;
            reboot)   command -v systemctl >/dev/null 2>&1 && systemctl reboot   || reboot;   return 0 ;;
            poweroff) command -v systemctl >/dev/null 2>&1 && systemctl poweroff || poweroff; return 0 ;;
            *)        return 0 ;;
        esac
    done
}

# Echoes one "- reason" line per problem; returns 1 if any were found.
validate_installed_boot() {
    local root="${1:-${MNT}}"
    local luks="${2:-false}"
    local problems=()
    local esp="${root}/boot/efi/EFI/debian"

    # Kernel and initramfs: update-initramfs can fail while still exiting 0 in
    # a chroot, leaving /boot with a kernel and no matching initrd.
    compgen -G "${root}/boot/vmlinuz-*" >/dev/null \
        || problems+=("- no kernel in /boot (expected vmlinuz-*)")
    compgen -G "${root}/boot/initrd.img-*" >/dev/null \
        || problems+=("- no initramfs in /boot (expected initrd.img-*); the kernel cannot mount the root filesystem")

    # The EFI binaries grub-install should have staged. Either the signed shim
    # chain or plain grubx64 is enough to boot; neither is not.
    if [ ! -f "${esp}/grubx64.efi" ] && [ ! -f "${esp}/shimx64.efi" ]; then
        problems+=("- no GRUB EFI binary at /boot/efi/EFI/debian; firmware would find nothing to boot")
    fi

    # grub.cfg must exist AND carry a real boot entry. An empty or entry-less
    # config still satisfies a file-exists test but drops to a grub> prompt.
    local grub_cfg="${root}/boot/grub/grub.cfg"
    if [ ! -s "${grub_cfg}" ]; then
        problems+=("- /boot/grub/grub.cfg is missing or empty; GRUB would drop to a rescue prompt")
    else
        grep -q "menuentry" "${grub_cfg}" \
            || problems+=("- /boot/grub/grub.cfg contains no menuentry")
        grep -qE "^[[:space:]]*linux" "${grub_cfg}" \
            || problems+=("- /boot/grub/grub.cfg has no linux line to load a kernel")
    fi

    # fstab drives every mount at boot. Match on the mount-point field so a
    # UUID that merely appears in a comment cannot satisfy the check.
    local fstab="${root}/etc/fstab"
    if [ ! -s "${fstab}" ]; then
        problems+=("- /etc/fstab is missing or empty")
    else
        awk '$1 !~ /^#/ && $2 == "/"         { found = 1 } END { exit !found }' "${fstab}" \
            || problems+=("- /etc/fstab has no root (/) entry")
        awk '$1 !~ /^#/ && $2 == "/boot/efi" { found = 1 } END { exit !found }' "${fstab}" \
            || problems+=("- /etc/fstab has no /boot/efi entry; the ESP would not be mounted")
    fi

    # With LUKS the initramfs needs crypttab to know what to unlock; without it
    # the boot stops at an initramfs prompt with no passphrase request.
    if [ "${luks}" = "true" ]; then
        local crypttab="${root}/etc/crypttab"
        if [ ! -s "${crypttab}" ]; then
            problems+=("- encryption is enabled but /etc/crypttab is missing or empty; the root volume would never be unlocked")
        else
            awk '$1 !~ /^#/ && NF >= 3 { found = 1 } END { exit !found }' "${crypttab}" \
                || problems+=("- /etc/crypttab has no mapping entry")
        fi
    fi

    if [ ${#problems[@]} -gt 0 ]; then
        printf '%s\n' "${problems[@]}"
        return 1
    fi
    return 0
}
