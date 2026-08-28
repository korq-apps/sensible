#!/usr/bin/env bash
# Generate /etc/fstab and /etc/crypttab strictly using filesystem and partition UUIDs

generate_crypttab_and_fstab() {
    local target_root="$1"
    local boot_part="$2"
    local efi_part="$3"
    local swap_part="$4"
    local root_part="$5"
    local fs_type="$6"
    local enable_luks="$7"

    mkdir -p ${MNT}/etc

    local ROOT_FS_UUID BOOT_UUID EFI_UUID SWAP_UUID ROOT_PART_UUID
    ROOT_FS_UUID=$(blkid -s UUID -o value "$target_root")
    BOOT_UUID=$(blkid -s UUID -o value "$boot_part")
    EFI_UUID=$(blkid -s UUID -o value "$efi_part")
    ROOT_PART_UUID=$(blkid -s UUID -o value "$root_part")

    # Guard: a missing identifier only shows up as a boot failure after reboot.
    require_id "ROOT filesystem UUID" "$ROOT_FS_UUID"
    require_id "BOOT filesystem UUID" "$BOOT_UUID"
    require_id "EFI filesystem UUID" "$EFI_UUID"

    log_info "Generating /etc/crypttab..."
    if [ "$enable_luks" = "true" ]; then
        cat <<EOF > ${MNT}/etc/crypttab
# Persistent LUKS root container (swap lives inside it as a swapfile)
cryptroot UUID=${ROOT_PART_UUID} none luks,discard
EOF
    else
        cat <<EOF > ${MNT}/etc/crypttab
# /etc/crypttab: No encrypted volumes configured.
EOF
    fi

    # Swap: with LUKS it is the swapfile on the encrypted root (hibernation
    # works); without LUKS it is the dedicated plaintext swap partition.
    local SWAP_FSTAB_LINE
    if [ "$enable_luks" = "true" ]; then
        if [ "$fs_type" = "btrfs" ]; then
            SWAP_FSTAB_LINE="/swap/swapfile none swap sw 0 0"
        else
            SWAP_FSTAB_LINE="/swapfile none swap sw 0 0"
        fi
    else
        SWAP_UUID=$(blkid -s UUID -o value "$swap_part")
        require_id "SWAP filesystem UUID" "$SWAP_UUID"
        SWAP_FSTAB_LINE="UUID=${SWAP_UUID} none swap sw 0 0"
    fi

    log_info "Generating /etc/fstab..."
    if [ "$fs_type" = "btrfs" ]; then
        cat <<EOF > ${MNT}/etc/fstab
# /etc/fstab: static file system information (UUID based)
UUID=${ROOT_FS_UUID}  /            btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@          0 0
UUID=${ROOT_FS_UUID}  /home        btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@home      0 0
UUID=${ROOT_FS_UUID}  /.snapshots  btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@snapshots 0 0
UUID=${ROOT_FS_UUID}  /var/log     btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@var_log   0 0
UUID=${ROOT_FS_UUID}  /swap        btrfs  noatime,subvol=@swap                                                   0 0
UUID=${BOOT_UUID}     /boot        ext4   noatime                                                               0 2
UUID=${EFI_UUID}      /boot/efi    vfat   umask=0077                                                            0 2
${SWAP_FSTAB_LINE}
tmpfs                /tmp         tmpfs  defaults,nosuid,nodev                                                 0 0
EOF
    else
        cat <<EOF > ${MNT}/etc/fstab
# /etc/fstab: static file system information (UUID based)
UUID=${ROOT_FS_UUID}  /            ext4   noatime,errors=remount-ro,discard                                     0 1
UUID=${BOOT_UUID}     /boot        ext4   noatime                                                               0 2
UUID=${EFI_UUID}      /boot/efi    vfat   umask=0077                                                            0 2
${SWAP_FSTAB_LINE}
tmpfs                /tmp         tmpfs  defaults,nosuid,nodev                                                 0 0
EOF
    fi

    log_success "Created ${MNT}/etc/crypttab and ${MNT}/etc/fstab successfully."
}
