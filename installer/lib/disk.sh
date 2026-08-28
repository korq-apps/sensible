#!/usr/bin/env bash
# Disk partitioning, LUKS2 encryption, filesystems, and mount operations

get_system_ram_mb() {
    free -m | awk '/^Mem:/{print $2}'
}

calc_swap_mb() {
    local ram_mb
    ram_mb=$(get_system_ram_mb)
    echo $((ram_mb + ram_mb / 10))
}

calc_min_disk_mb() {
    local swap_mb
    swap_mb=$(calc_swap_mb)
    # 1024 EFI + 1024 BOOT + SWAP + 20480 ROOT
    echo $((2048 + swap_mb + 20480))
}

disk_below_min() {
    local name="$1" min_mib="$2"
    local size_bytes
    # -d: whole disk only. Without it lsblk also prints every partition row, so
    # a pre-partitioned disk yields multi-line output, the numeric test below
    # errors out, and an undersized disk survives filtering.
    size_bytes=$(lsblk -d -bno SIZE "$name" 2>/dev/null || echo 0)
    [ "${size_bytes:-0}" -lt $((min_mib * 1048576)) ]
}

list_candidate_disks() {
    # List candidate disks excluding loop devices, optical drives, and live
    # mounts. Disks below the minimum install size (spec §1) are refused.
    # Parsing uses only space-free lsblk columns (NAME,SIZE,TYPE[,RO]); MODEL
    # may contain spaces and is queried per-disk for display only.
    # Deliberately no fallback: if nothing survives the filters (e.g. the
    # only disk is the live USB), returning an empty list is the safe answer.
    local min_mib
    min_mib=$(calc_min_disk_mb)
    local candidates=()
    local name size type ro model
    while read -r name size type ro; do
        if [ "$type" = "disk" ] && [ "$ro" = "0" ]; then
            # Exclude disks mounted on /run/live or /
            if ! lsblk -no MOUNTPOINTS "$name" 2>/dev/null | grep -E '^/(run/live/medium|run/live/findiso|)$' | grep -v '^$' >/dev/null; then
                if disk_below_min "$name" "$min_mib"; then
                    log_warn "Skipping ${name}: smaller than the ${min_mib} MiB minimum."
                    continue
                fi
                model=$(lsblk -dno MODEL "$name" 2>/dev/null | head -n 1)
                candidates+=("$name" "${size} - ${model:-Generic_Disk}")
            fi
        fi
    done < <(lsblk -dpno NAME,SIZE,TYPE,RO 2>/dev/null)

    if [ ${#candidates[@]} -gt 0 ]; then
        printf '%s\n' "${candidates[@]}"
    fi
}

get_partition_name() {
    local disk="$1"
    local num="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

partition_disk() {
    local disk="$1"
    local swap_mb="$2"
    local enable_luks="$3"

    log_info "Wiping existing partition tables on ${disk}..."
    sgdisk --zap-all "$disk" >/dev/null 2>&1 || true
    wipefs --all --force "$disk" >/dev/null 2>&1 || true

    if [ "$enable_luks" = "true" ]; then
        # LUKS: no swap partition — swap lives in a swapfile inside the
        # encrypted root, which enables hibernation (resume_offset).
        log_info "Creating GPT layout (EFI: 1024M, BOOT: 1024M, ROOT+swapfile: rest)..."
        sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI System Partition" "$disk"
        sgdisk -n 2:0:+1024M -t 2:8300 -c 2:"Linux Boot" "$disk"
        sgdisk -n 3:0:0 -t 3:8309 -c 3:"Linux LUKS" "$disk"
    else
        log_info "Creating GPT layout (EFI: 1024M, BOOT: 1024M, SWAP: ${swap_mb}M, ROOT: rest)..."
        sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI System Partition" "$disk"
        sgdisk -n 2:0:+1024M -t 2:8300 -c 2:"Linux Boot" "$disk"
        sgdisk -n 3:0:+"${swap_mb}"M -t 3:8200 -c 3:"Linux Swap" "$disk"
        sgdisk -n 4:0:0 -t 4:8300 -c 4:"Linux Root" "$disk"
    fi

    partprobe "$disk" 2>/dev/null || true
    sleep 2
}

resume_offset_of() {
    # Physical offset (in 4K pages) of a swapfile, for the kernel's
    # resume_offset= parameter.
    local swapfile="$1" fs_type="$2"
    if [ "$fs_type" = "btrfs" ]; then
        btrfs inspect-internal map-swapfile -r "$swapfile"
    else
        # First extent's physical start, in 4K blocks. Use sub(), not
        # split(..): a multi-char split string is an ERE in awk.
        filefrag -v "$swapfile" | awk '$1 == "0:" { n = $4; sub(/\.\..*$/, "", n); print n }'
    fi
}

create_swapfile() {
    # Swapfile used for both runtime swap and hibernation. With LUKS it lives
    # inside the encrypted root, so resume works and swap stays encrypted.
    # Btrfs: dedicated @swap subvolume, NOCOW, not compressed, not snapshotted.
    local fs_type="$1" swap_mb="$2"

    if [ "$fs_type" = "btrfs" ]; then
        SWAPFILE="/swap/swapfile"
        local swapfile="${MNT}/swap/swapfile"
        log_info "Creating ${swap_mb}M NOCOW swapfile on the @swap subvolume..."
        touch "$swapfile"
        chattr +C "$swapfile"
        fallocate -l "${swap_mb}M" "$swapfile"
    else
        SWAPFILE="/swapfile"
        local swapfile="${MNT}/swapfile"
        log_info "Creating ${swap_mb}M swapfile..."
        fallocate -l "${swap_mb}M" "$swapfile"
    fi

    chmod 600 "$swapfile"
    mkswap "$swapfile"
    RESUME_OFFSET=$(resume_offset_of "$swapfile" "$fs_type")
    require_id "swapfile resume offset" "${RESUME_OFFSET}"
    log_info "Swapfile ready at ${SWAPFILE} (resume_offset=${RESUME_OFFSET})."
}

format_and_mount() {
    local disk="$1"
    local fs_type="$2"
    local enable_luks="$3"
    local passphrase="$4"
    local swap_mb="$5"

    EFI_PART=$(get_partition_name "$disk" 1)
    BOOT_PART=$(get_partition_name "$disk" 2)
    if [ "$enable_luks" = "true" ]; then
        ROOT_PART=$(get_partition_name "$disk" 3)
        SWAP_PART=""
    else
        SWAP_PART=$(get_partition_name "$disk" 3)
        ROOT_PART=$(get_partition_name "$disk" 4)
    fi

    log_info "Formatting EFI (${EFI_PART}) and BOOT (${BOOT_PART})..."
    mkfs.vfat -F32 -n EFI "$EFI_PART"
    mkfs.ext4 -F -L BOOT "$BOOT_PART"

    if [ "$enable_luks" = "true" ]; then
        log_info "Setting up LUKS2 container on ${ROOT_PART}..."
        # printf, never `echo -n`: bash's echo eats option-shaped arguments, so
        # a valid passphrase like "-nnnnnnn" is parsed as the -n flag and
        # cryptsetup would receive an empty key -- after the disk is already
        # partitioned. printf '%s' passes every byte through verbatim.
        printf '%s' "$passphrase" | cryptsetup luksFormat \
            --type luks2 --pbkdf argon2id --hash sha512 --key-size 512 --batch-mode \
            "$ROOT_PART"

        printf '%s' "$passphrase" | cryptsetup open "$ROOT_PART" cryptroot
        TARGET_ROOT="/dev/mapper/cryptroot"
    else
        TARGET_ROOT="$ROOT_PART"
        log_info "Formatting plaintext SWAP on ${SWAP_PART}..."
        mkswap -L SWAP "$SWAP_PART"
    fi

    mkdir -p ${MNT}

    if [ "$fs_type" = "btrfs" ]; then
        log_info "Creating Btrfs filesystem on ${TARGET_ROOT} with subvolumes..."
        mkfs.btrfs -f -L ROOT "$TARGET_ROOT"
        mount "$TARGET_ROOT" ${MNT}
        btrfs subvolume create ${MNT}/@
        btrfs subvolume create ${MNT}/@home
        btrfs subvolume create ${MNT}/@snapshots
        btrfs subvolume create ${MNT}/@var_log
        btrfs subvolume create ${MNT}/@swap
        umount ${MNT}

        local BTRFS_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async"
        mount -o "${BTRFS_OPTS},subvol=@" "$TARGET_ROOT" ${MNT}
        mkdir -p ${MNT}/{home,.snapshots,var/log,boot,swap}
        mount -o "${BTRFS_OPTS},subvol=@home" "$TARGET_ROOT" ${MNT}/home
        mount -o "${BTRFS_OPTS},subvol=@snapshots" "$TARGET_ROOT" ${MNT}/.snapshots
        mount -o "${BTRFS_OPTS},subvol=@var_log" "$TARGET_ROOT" ${MNT}/var/log
        mount -o "noatime,subvol=@swap" "$TARGET_ROOT" ${MNT}/swap
    else
        log_info "Creating Ext4 filesystem on ${TARGET_ROOT}..."
        mkfs.ext4 -F -L ROOT -O fast_commit "$TARGET_ROOT"
        mount -o "noatime,errors=remount-ro,discard" "$TARGET_ROOT" ${MNT}
        mkdir -p ${MNT}/boot
    fi

    if [ "$enable_luks" = "true" ]; then
        create_swapfile "$fs_type" "$swap_mb"
    fi

    mount -o "noatime" "$BOOT_PART" ${MNT}/boot
    mkdir -p ${MNT}/boot/efi
    mount -o "umask=0077" "$EFI_PART" ${MNT}/boot/efi
    log_success "Filesystems formatted and mounted to ${MNT} successfully."
}

unmount_target() {
    log_info "Unmounting target filesystems..."
    if mountpoint -q ${MNT}/dev/pts; then umount ${MNT}/dev/pts || true; fi
    if mountpoint -q ${MNT}/dev; then umount ${MNT}/dev || true; fi
    if mountpoint -q ${MNT}/proc; then umount ${MNT}/proc || true; fi
    if mountpoint -q ${MNT}/sys; then umount ${MNT}/sys || true; fi
    if mountpoint -q ${MNT}/run; then umount ${MNT}/run || true; fi

    if mountpoint -q ${MNT}/boot/efi; then umount ${MNT}/boot/efi || true; fi
    if mountpoint -q ${MNT}/boot; then umount ${MNT}/boot || true; fi
    if mountpoint -q ${MNT}/swap; then umount ${MNT}/swap || true; fi
    if mountpoint -q ${MNT}/home; then umount ${MNT}/home || true; fi
    if mountpoint -q ${MNT}/.snapshots; then umount ${MNT}/.snapshots || true; fi
    if mountpoint -q ${MNT}/var/log; then umount ${MNT}/var/log || true; fi
    if mountpoint -q ${MNT}; then umount -R ${MNT} 2>/dev/null || umount ${MNT} || true; fi

    if [ -e /dev/mapper/cryptroot ]; then
        log_info "Closing LUKS mapping cryptroot..."
        cryptsetup close cryptroot 2>/dev/null || true
    fi
}
