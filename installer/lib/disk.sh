#!/usr/bin/env bash
# Disk partitioning, LUKS2 encryption, filesystems, and mount operations

INSTALLER_OWNS_TARGET_MOUNTS="${INSTALLER_OWNS_TARGET_MOUNTS:-false}"
INSTALLER_OPENED_CRYPTROOT="${INSTALLER_OPENED_CRYPTROOT:-false}"
SYS_CLASS_BLOCK="${SYS_CLASS_BLOCK:-/sys/class/block}"
PROC_SWAPS="${PROC_SWAPS:-/proc/swaps}"

get_system_ram_mb() {
    free -m | awk '/^Mem:/{print $2}'
}

calc_swap_mb() {
    # Swap mirrors RAM: it is a swapfile inside the root filesystem, so it
    # costs root space rather than a partition, and matching RAM is what makes
    # hibernation possible at all.
    get_system_ram_mb
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

disk_has_mounts() {
    local mountpoints
    mountpoints=$(lsblk -nrpo MOUNTPOINTS "$1" 2>/dev/null) || return 0
    grep -q '[^[:space:]]' <<< "$mountpoints"
}

disk_has_active_swap() {
    local disk="$1" device_ids swaps swap_device swap_id
    device_ids=$(lsblk -nrno MAJ:MIN "$disk" 2>/dev/null) || return 0
    [ -r "$PROC_SWAPS" ] || return 0
    swaps=$(<"$PROC_SWAPS") || return 0
    while read -r swap_device _; do
        [ "$swap_device" != "Filename" ] || continue
        [ -n "$swap_device" ] || continue
        swap_id=$(lsblk -dnro MAJ:MIN "$swap_device" 2>/dev/null) || return 0
        grep -qxF "$swap_id" <<< "$device_ids" && return 0
    done <<< "$swaps"
    return 1
}

disk_has_holders() {
    local disk="$1" knames kname holder
    knames=$(lsblk -nrno KNAME "$disk" 2>/dev/null) || return 0
    while read -r kname; do
        [ -n "$kname" ] || continue
        kname="${kname##*/}"
        for holder in "${SYS_CLASS_BLOCK}/${kname}/holders/"*; do
            [ -e "$holder" ] && return 0
        done
    done <<< "$knames"
    return 1
}

target_mount_tree_busy() {
    local target mounts mount_target
    target="${1%/}"
    mounts=$(findmnt -rn -o TARGET 2>/dev/null) || return 0
    while read -r mount_target; do
        [ "$mount_target" = "$target" ] && return 0
        [[ "$mount_target" = "$target/"* ]] && return 0
    done <<< "$mounts"
    return 1
}

disk_is_in_use() {
    disk_has_mounts "$1" || disk_has_active_swap "$1" || disk_has_holders "$1"
}

disk_property() {
    local disk="$1" property="$2"
    if [ "$property" = "SIZE" ]; then
        lsblk -dnbo SIZE "$disk" 2>/dev/null | head -n 1
    else
        local value=""
        IFS= read -r value < <(lsblk -dno "$property" "$disk" 2>/dev/null)
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        printf '%s\n' "$value"
    fi
}

validate_target_disk() {
    local disk="$1" min_mib="$2" expected_majmin="$3" expected_size="$4"
    local expected_serial="$5" expected_wwn="$6"
    local type ro majmin size serial wwn

    type=$(disk_property "$disk" TYPE)
    ro=$(disk_property "$disk" RO)
    majmin=$(disk_property "$disk" MAJ:MIN)
    size=$(disk_property "$disk" SIZE)
    serial=$(disk_property "$disk" SERIAL)
    wwn=$(disk_property "$disk" WWN)

    [ "$type" = "disk" ] && [ "$ro" = "0" ] || return 1
    [ -n "$size" ] && [ "$size" -ge $((min_mib * 1048576)) ] || return 1
    [ "$majmin" = "$expected_majmin" ] && [ "$size" = "$expected_size" ] || return 1
    [ "$serial" = "$expected_serial" ] && [ "$wwn" = "$expected_wwn" ] || return 1
    ! disk_is_in_use "$disk" || return 1
    [ ! -e /dev/mapper/cryptroot ] || return 1
}

explain_no_candidates() {
    # Per-device reason, shown only when nothing survived the filters.
    # "No suitable target installation disks found." on its own gives someone
    # no way to tell an absent disk from an undersized one, and the minimum
    # here scales with RAM, so the cause is rarely obvious.
    #
    # Deliberately re-scans instead of sharing state with list_candidate_disks:
    # that runs in a subshell (mapfile < <(...)), so globals set inside it
    # would not survive. Filter order mirrors list_candidate_disks exactly.
    local min_mib="$1"
    local name size type ro found=0
    while read -r name size type ro; do
        found=1
        if [ "$type" != "disk" ]; then
            printf '  %-12s %-8s not a disk (%s)\n' "$name" "$size" "$type"
        elif [ "$ro" != "0" ]; then
            printf '  %-12s %-8s read-only\n' "$name" "$size"
        elif disk_has_mounts "$name"; then
            printf '  %-12s %-8s has a mounted filesystem\n' "$name" "$size"
        elif disk_has_active_swap "$name"; then
            printf '  %-12s %-8s contains active swap\n' "$name" "$size"
        elif disk_has_holders "$name"; then
            printf '  %-12s %-8s is used by RAID, LVM, or device-mapper\n' "$name" "$size"
        elif disk_below_min "$name" "$min_mib"; then
            printf '  %-12s %-8s too small (needs %s MiB)\n' "$name" "$size" "$min_mib"
        else
            printf '  %-12s %-8s eligible\n' "$name" "$size"
        fi
    done < <(lsblk -dpno NAME,SIZE,TYPE,RO 2>/dev/null)
    [ "$found" -eq 1 ] || printf '  (no block devices detected at all)\n'
}

block_display_property() {
    local device="$1" property="$2" value=""
    IFS= read -r value < <(lsblk -dno "$property" "$device" 2>/dev/null)
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

get_disk_identity() {
    local device="$1" size vendor model label
    size=$(block_display_property "$device" SIZE)
    vendor=$(block_display_property "$device" VENDOR)
    model=$(block_display_property "$device" MODEL)
    label=""
    if [[ -n $vendor && -n $model ]]; then
        if [[ $model == *$vendor* ]]; then label="$model"; else label="$vendor $model"; fi
    elif [[ -n $model ]]; then label="$model"
    elif [[ -n $vendor ]]; then label="$vendor"
    fi
    local display="$device"
    [[ -n $size ]] && display="$display ($size)"
    [[ -n $label ]] && display="$display - $label"
    printf '%s\n' "$display"
}

get_volume_info() {
    local volume="$1" type="$2"
    local name size fstype label mountpoint display
    name="${volume##*/}"
    size=$(block_display_property "$volume" SIZE)
    fstype=$(block_display_property "$volume" FSTYPE)
    label=$(block_display_property "$volume" LABEL)
    [ -n "$label" ] || label=$(block_display_property "$volume" PARTLABEL)
    mountpoint=$(block_display_property "$volume" MOUNTPOINT)

    display="$name"
    [ -n "$size" ] && display+="  $size"
    if [ -n "$fstype" ]; then
        display+="  $fstype"
    else
        display+="  ${type:-volume}, no filesystem"
    fi
    [ -n "$label" ] && display+="  label: $label"
    [ -n "$mountpoint" ] && display+="  mounted: $mountpoint"
    printf '%s\n' "$display"
}

get_disk_volume_summary() {
    local device="$1" volume type info summary=""
    while read -r volume type; do
        [ -n "$volume" ] || continue
        [ "$volume" != "$device" ] || continue
        info=$(get_volume_info "$volume" "$type")
        [ -z "$summary" ] || summary+="; "
        summary+="$info"
    done < <(lsblk -nrpo NAME,TYPE "$device" 2>/dev/null)
    printf '%s\n' "${summary:-no existing volumes}"
}

get_disk_inventory_entry() {
    local device="$1" volume type info identity found=false entry
    identity=$(get_disk_identity "$device")
    entry="$identity"
    while read -r volume type; do
        [ -n "$volume" ] || continue
        [ "$volume" != "$device" ] || continue
        info=$(get_volume_info "$volume" "$type")
        entry+=$'\n'"    - $info"
        found=true
    done < <(lsblk -nrpo NAME,TYPE "$device" 2>/dev/null)
    [ "$found" = true ] || entry+=$'\n'"    - no existing volumes"
    printf '%s\n' "$entry"
}

get_disk_info() {
    local device="$1" identity volumes
    identity=$(get_disk_identity "$device")
    volumes=$(get_disk_volume_summary "$device")
    printf '%s | %s\n' "$identity" "$volumes"
}

get_root_disk() {
    local device="$1" parent
    [[ -n $device ]] || return 1
    device=$(readlink -f "$device" 2>/dev/null || printf "%s\n" "$device")
    while true; do
        parent=$(lsblk -dno PKNAME "$device" 2>/dev/null | tail -n1)
        [[ -n $parent ]] || break
        device="/dev/$parent"
    done
    if [[ $(lsblk -dno TYPE "$device" 2>/dev/null) == "disk" ]]; then
        printf "%s\n" "$device"
    fi
}

wait_for_device() {
    local i
    for i in $(seq 1 10); do
        [[ -b "$1" ]] && return 0
        udevadm settle 2>/dev/null || true
        sleep 1
    done
    return 1
}

disk_step() {
    local desc="$1"; shift
    local output status=0
    output=$("$@" 2>&1) || status=$?
    [[ -n $output ]] && printf '%s\n' "$output"
    (( status == 0 )) && return 0
    log_err "$desc failed (exit $status): $output"
    return $status
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
            # Never offer a disk with mounted filesystems, active swap, or
            # device-mapper/RAID/LVM holders. The live medium is covered by
            # the mounted-filesystem check as well.
            # Also exclude the live boot disk itself
            local boot_source exclude_disk
            boot_source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || findmnt -no SOURCE /run/live/medium 2>/dev/null || true)
            if [ -n "$boot_source" ]; then
                exclude_disk=$(get_root_disk "$boot_source" 2>/dev/null || true)
                if [ -n "$exclude_disk" ] && [ "$name" = "$exclude_disk" ]; then
                    continue
                fi
            fi
            if ! disk_is_in_use "$name"; then
                if disk_below_min "$name" "$min_mib"; then
                    log_warn "Skipping ${name}: smaller than the ${min_mib} MiB minimum."
                    continue
                fi
                model=$(lsblk -dno MODEL "$name" 2>/dev/null | head -n 1)
                # Use get_disk_info for richer display
                local info
                info=$(get_disk_info "$name")
                # But for ui_menu we need key + description split: key is device path
                candidates+=("$name" "${info#$name }")
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

    # One layout in both modes: EFI, BOOT, ROOT. Swap is always a swapfile
    # inside the root filesystem, never a partition -- so it inherits the
    # root's encryption instead of needing a separate key, it can be resized
    # later without touching the partition table, and enabling encryption does
    # not change the partition layout at all.
    log_info "Creating GPT layout (EFI: 1024M, BOOT: 1024M, ROOT+swapfile: rest)..."
    sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI System Partition" "$disk"
    sgdisk -n 2:0:+1024M -t 2:8300 -c 2:"Linux Boot" "$disk"
    if [ "$enable_luks" = "true" ]; then
        sgdisk -n 3:0:0 -t 3:8309 -c 3:"Linux LUKS" "$disk"
    else
        sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux Root" "$disk"
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
    # Swap is always a swapfile inside the root filesystem, in both modes.
    # With LUKS that means it is encrypted with the root and needs no key of
    # its own; without it, it still avoids a fixed partition and can be resized
    # later. Doubles as the hibernation image (see resume_offset).
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
    ROOT_PART=$(get_partition_name "$disk" 3)
    SWAP_PART=""

    log_info "Formatting EFI (${EFI_PART}) and BOOT (${BOOT_PART})..."
    mkfs.vfat -F32 -n EFI "$EFI_PART"
    mkfs.ext4 -F -L BOOT "$BOOT_PART"

    if [ "$enable_luks" = "true" ]; then
        if [ -e /dev/mapper/cryptroot ]; then
            log_err "/dev/mapper/cryptroot already exists; refusing to reuse a mapping not created by this installer."
            return 1
        fi
        log_info "Setting up LUKS2 container on ${ROOT_PART}..."
        # printf, never `echo -n`: bash's echo eats option-shaped arguments, so
        # a valid passphrase like "-nnnnnnn" is parsed as the -n flag and
        # cryptsetup would receive an empty key -- after the disk is already
        # partitioned. printf '%s' passes every byte through verbatim.
        printf '%s' "$passphrase" | cryptsetup luksFormat \
            --type luks2 --pbkdf argon2id --hash sha512 --key-size 512 --batch-mode \
            "$ROOT_PART"

        printf '%s' "$passphrase" | cryptsetup open "$ROOT_PART" cryptroot
        INSTALLER_OPENED_CRYPTROOT="true"
        TARGET_ROOT="/dev/mapper/cryptroot"
    else
        TARGET_ROOT="$ROOT_PART"
    fi

    mkdir -p ${MNT}

    if [ "$fs_type" = "btrfs" ]; then
        log_info "Creating Btrfs filesystem on ${TARGET_ROOT} with subvolumes..."
        mkfs.btrfs -f -L ROOT "$TARGET_ROOT"
        mount "$TARGET_ROOT" ${MNT}
        INSTALLER_OWNS_TARGET_MOUNTS="true"
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
        INSTALLER_OWNS_TARGET_MOUNTS="true"
        mkdir -p ${MNT}/boot
    fi

    # Always, not only under LUKS: swap is a swapfile in both modes now, so
    # there is no partition to fall back to when encryption is off.
    create_swapfile "$fs_type" "$swap_mb"

    mount -o "noatime" "$BOOT_PART" ${MNT}/boot
    mkdir -p ${MNT}/boot/efi
    mount -o "umask=0077" "$EFI_PART" ${MNT}/boot/efi
    log_success "Filesystems formatted and mounted to ${MNT} successfully."
}

unmount_target() {
    if [ "$INSTALLER_OWNS_TARGET_MOUNTS" = "true" ]; then
        log_info "Unmounting installer-owned target filesystems..."
        local path
        # sys/firmware/efi/efivars first: it is a bind inside the /sys bind,
        # so it must come down before its parent (deepest first).
        for path in sys/firmware/efi/efivars dev/pts dev proc sys run boot/efi boot swap home .snapshots var/log; do
            if mountpoint -q "${MNT}/${path}"; then
                umount "${MNT}/${path}" || return 1
            fi
        done
        if mountpoint -q "${MNT}"; then
            # Never recurse here: an unexpected nested mount was not created
            # by this installer and must make cleanup fail rather than be torn
            # down behind another process's back.
            umount "${MNT}" || return 1
        fi
        if mountpoint -q "${MNT}"; then
            log_err "Target ${MNT} is still mounted. Do not reboot until it is safely unmounted."
            return 1
        fi
        INSTALLER_OWNS_TARGET_MOUNTS="false"
    fi

    if [ "$INSTALLER_OPENED_CRYPTROOT" = "true" ]; then
        log_info "Closing LUKS mapping cryptroot..."
        cryptsetup close cryptroot || return 1
        INSTALLER_OPENED_CRYPTROOT="false"
    fi
}
