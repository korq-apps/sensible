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
