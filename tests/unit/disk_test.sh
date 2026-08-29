#!/usr/bin/env bash
# Unit tests for installer/lib/disk.sh (external tools mocked via functions)
TEST_NAME="disk_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/disk.sh"
PROC_SWAPS="/dev/null"

t_section "get_partition_name (nvme/mmcblk use pN)"
assert_eq "sda"      "/dev/sda3"      "$(get_partition_name /dev/sda 3)"
assert_eq "vda"      "/dev/vda1"      "$(get_partition_name /dev/vda 1)"
assert_eq "nvme0n1"  "/dev/nvme0n1p2" "$(get_partition_name /dev/nvme0n1 2)"
assert_eq "mmcblk0"  "/dev/mmcblk0p4" "$(get_partition_name /dev/mmcblk0 4)"

t_section "swap and minimum disk math (RAM mock)"
free() { printf '              total        used        free\nMem:           8192        1024        7168\n'; }
assert_eq "RAM detection" "8192" "$(get_system_ram_mb)"
assert_eq "swap = RAM + 10%" "9011" "$(calc_swap_mb)"
assert_eq "min disk = 2048 + swap + 20480" "31539" "$(calc_min_disk_mb)"

t_section "partition_disk: GPT layout per spec"
mock_setup
sgdisk()   { mlog "sgdisk $*"; }
wipefs()   { mlog "wipefs $*"; }
partprobe() { mlog "partprobe $*"; }
sleep() { :; }

partition_disk /dev/sda 9011 true
assert_contains "zaps existing tables" "$(cat "${MOCK_LOG}")" "sgdisk --zap-all /dev/sda"
assert_contains "wipes signatures" "$(cat "${MOCK_LOG}")" "wipefs --all --force /dev/sda"
assert_contains "p1 1GiB EFI (ef00)"  "$(cat "${MOCK_LOG}")" "sgdisk -n 1:0:+1024M -t 1:ef00"
assert_contains "p2 1GiB BOOT (8300)" "$(cat "${MOCK_LOG}")" "sgdisk -n 2:0:+1024M -t 2:8300"
assert_contains "p3 LUKS root type 8309 (no swap partition)" "$(cat "${MOCK_LOG}")" "sgdisk -n 3:0:0 -t 3:8309"
assert_not_contains "no swap partition with LUKS" "$(cat "${MOCK_LOG}")" "8200"
assert_not_contains "no p4 with LUKS" "$(cat "${MOCK_LOG}")" "-n 4:0:0"

mock_reset
partition_disk /dev/sda 9011 false
assert_contains "p3 swap (8200)"      "$(cat "${MOCK_LOG}")" "sgdisk -n 3:0:+9011M -t 3:8200"
assert_contains "p4 plain root type 8300" "$(cat "${MOCK_LOG}")" "sgdisk -n 4:0:0 -t 4:8300"
mock_teardown

t_section "format_and_mount: LUKS on, btrfs (swapfile on @swap subvol)"
mock_setup
TMP_MNT="$(mktemp -d)"
MNT="${TMP_MNT}"
mkfs.vfat()   { mlog "mkfs.vfat $*"; }
mkfs.ext4()   { mlog "mkfs.ext4 $*"; }
mkfs.btrfs()  { mlog "mkfs.btrfs $*"; }
mkswap()      { mlog "mkswap $*"; }
cryptsetup()  { mlog "cryptsetup $*"; }
mount()       { mlog "mount $*"; }
umount()      { mlog "umount $*"; }
btrfs()       { mlog "btrfs $*"; if [ "$1" = "inspect-internal" ]; then echo "38400"; fi; }
chattr()      { mlog "chattr $*"; }
fallocate()   { mlog "fallocate $*"; touch "$3"; }

format_and_mount /dev/sda btrfs true "test-pass-123" 9011
assert_contains "LUKS2 argon2id format"     "$(cat "${MOCK_LOG}")" "cryptsetup luksFormat --type luks2 --pbkdf argon2id"
assert_contains "opens cryptroot"           "$(cat "${MOCK_LOG}")" "cryptsetup open /dev/sda3 cryptroot"
assert_eq "TARGET_ROOT is mapper device" "/dev/mapper/cryptroot" "${TARGET_ROOT}"
assert_eq "no swap partition with LUKS" "" "${SWAP_PART}"
assert_contains "btrfs created"             "$(cat "${MOCK_LOG}")" "mkfs.btrfs -f -L ROOT"
assert_contains "subvol @"          "$(cat "${MOCK_LOG}")" "btrfs subvolume create ${MNT}/@"
assert_contains "subvol @home"      "$(cat "${MOCK_LOG}")" "btrfs subvolume create ${MNT}/@home"
assert_contains "subvol @snapshots" "$(cat "${MOCK_LOG}")" "btrfs subvolume create ${MNT}/@snapshots"
assert_contains "subvol @var_log"   "$(cat "${MOCK_LOG}")" "btrfs subvolume create ${MNT}/@var_log"
assert_contains "subvol @swap"      "$(cat "${MOCK_LOG}")" "btrfs subvolume create ${MNT}/@swap"
assert_contains "@swap mounted"     "$(cat "${MOCK_LOG}")" "mount -o noatime,subvol=@swap /dev/mapper/cryptroot ${MNT}/swap"
assert_contains "root mounted with subvol=@" "$(cat "${MOCK_LOG}")" "mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@ /dev/mapper/cryptroot ${MNT}"
assert_contains "EFI mounted umask=0077" "$(cat "${MOCK_LOG}")" "mount -o umask=0077 /dev/sda1 ${MNT}/boot/efi"
assert_contains "NOCOW flag on swapfile" "$(cat "${MOCK_LOG}")" "chattr +C ${MNT}/swap/swapfile"
assert_contains "swapfile sized RAM+10%" "$(cat "${MOCK_LOG}")" "fallocate -l 9011M ${MNT}/swap/swapfile"
assert_contains "swapfile formatted" "$(cat "${MOCK_LOG}")" "mkswap ${MNT}/swap/swapfile"
assert_eq "resume_offset via map-swapfile" "38400" "${RESUME_OFFSET}"
assert_not_contains "no swap partition formatting with LUKS" "$(cat "${MOCK_LOG}")" "mkswap -L SWAP"
mock_teardown

t_section "format_and_mount: LUKS on, ext4 (swapfile at root)"
mock_setup
TMP_MNT="$(mktemp -d)"
MNT="${TMP_MNT}"
mkfs.vfat()   { mlog "mkfs.vfat $*"; }
mkfs.ext4()   { mlog "mkfs.ext4 $*"; }
mkswap()      { mlog "mkswap $*"; }
cryptsetup()  { mlog "cryptsetup $*"; }
mount()       { mlog "mount $*"; }
fallocate()   { mlog "fallocate $*"; touch "$3"; }
filefrag()    { printf 'Filesystem type is: ef53\nFile size of %s is 9011 blocks (256-bit extents)\n 0:        0..   32767:    123456..  1267334:   32768:\n' "$1"; }

format_and_mount /dev/sda ext4 true "test-pass-123" 9011
assert_eq "SWAP_PART empty with LUKS" "" "${SWAP_PART}"
assert_contains "swapfile at ext4 root" "$(cat "${MOCK_LOG}")" "fallocate -l 9011M ${MNT}/swapfile"
assert_contains "swapfile formatted" "$(cat "${MOCK_LOG}")" "mkswap ${MNT}/swapfile"
assert_eq "resume_offset via filefrag" "123456" "${RESUME_OFFSET}"
assert_contains "ext4 fast_commit" "$(cat "${MOCK_LOG}")" "mkfs.ext4 -F -L ROOT -O fast_commit /dev/mapper/cryptroot"
mock_teardown
rm -rf "${TMP_MNT}"

t_section "format_and_mount: LUKS off, ext4 (partition swap, no swapfile)"
mock_setup
mkfs.vfat()   { mlog "mkfs.vfat $*"; }
mkfs.ext4()   { mlog "mkfs.ext4 $*"; }
mkswap()      { mlog "mkswap $*"; }
cryptsetup()  { mlog "cryptsetup $*"; }
mount()       { mlog "mount $*"; }
btrfs()       { mlog "btrfs $*"; }

format_and_mount /dev/sda ext4 false "" 9011
assert_contains "plain swap formatted" "$(cat "${MOCK_LOG}")" "mkswap -L SWAP /dev/sda3"
assert_not_contains "no cryptsetup without LUKS" "$(cat "${MOCK_LOG}")" "cryptsetup"
assert_eq "TARGET_ROOT is raw partition" "/dev/sda4" "${TARGET_ROOT}"
assert_contains "ext4 fast_commit" "$(cat "${MOCK_LOG}")" "mkfs.ext4 -F -L ROOT -O fast_commit /dev/sda4"
assert_contains "ext4 mount options" "$(cat "${MOCK_LOG}")" "mount -o noatime,errors=remount-ro,discard /dev/sda4 ${MNT}"
assert_not_contains "no btrfs without btrfs fs" "$(cat "${MOCK_LOG}")" "subvolume"
mock_teardown
rm -rf "${TMP_MNT}"

t_section "list_candidate_disks: min-size filter and live-medium exclusion"
mock_setup   # fresh call log (earlier sections tore theirs down)
free() { printf 'Mem:           8192        1024        7168\n'; }  # min = 31539 MiB
lsblk() {
    mlog "lsblk $*"
    # Resolve the device as the LAST argument, never a fixed position: the
    # flags differ per call site (disk_below_min passes -d), so hardcoding $3
    # silently reads a flag instead of the device.
    local dev="${!#}"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) printf '/dev/sda 500G disk 0\n/dev/vda 10G disk 0\n/dev/zda 500G disk 0\n' ;;
        *MOUNTPOINTS*) if [ "$dev" = "/dev/zda" ]; then echo "/run/live/medium"; fi; return 0 ;;
        *"-bno SIZE"*) case "$dev" in /dev/sda) echo 536870912000 ;; /dev/vda) echo 10737418240 ;; esac ;;
        *"-dno MODEL"*) case "$dev" in /dev/sda) echo "Samsung SSD 860" ;; esac ;;
    esac
}
mapfile -t CANDS < <(list_candidate_disks)
assert_contains "500G disk listed" "$(printf '%s\n' "${CANDS[@]}")" "/dev/sda"
assert_contains "multi-word model kept intact" "$(printf '%s\n' "${CANDS[@]}")" "Samsung SSD 860"
assert_not_contains "10G disk filtered (below 31539 MiB min)" "$(printf '%s\n' "${CANDS[@]}")" "/dev/vda"
assert_not_contains "live medium excluded" "$(printf '%s\n' "${CANDS[@]}")" "/dev/zda"

t_section "list_candidate_disks: no fallback — only the live medium exists"
mock_reset
lsblk() {
    mlog "lsblk $*"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) printf '/dev/zda 500G disk 0\n' ;;
        *MOUNTPOINTS*) echo "/run/live/medium" ;;
        *"-bno SIZE"*) echo 536870912000 ;;
        *"-dno MODEL"*) echo "LiveUSB" ;;
    esac
}
mapfile -t CANDS < <(list_candidate_disks)
assert_eq "live-only system yields zero candidates (never offered for wipe)" 0 "${#CANDS[@]}"

t_section "disk_below_min"
lsblk() { case "$*" in *"-bno SIZE"*) echo 10737418240 ;; esac; }  # 10 GiB
disk_below_min /dev/vda 31539; assert_rc "10 GiB is below 31539 MiB" 0 $?
lsblk() { case "$*" in *"-bno SIZE"*) echo 68719476736 ;; esac; }  # 64 GiB
disk_below_min /dev/vda 31539; assert_rc "64 GiB is not below minimum" 1 $?

t_section "disk_below_min: pre-partitioned disk (lsblk must be asked for -d)"
# Without -d, lsblk prints the whole-disk row AND one row per partition. The
# multi-line result makes the numeric comparison error out, so an undersized
# disk would slip past the filter. This mock only answers with a single row
# when -d is passed, and reproduces the multi-row output when it is not.
lsblk() {
    case "$*" in
        *"-d "*) echo 10737418240 ;;                            # 10 GiB, whole disk
        *"-bno SIZE"*) printf '10737418240\n1048576\n524288000\n' ;;  # disk + partitions
    esac
}
disk_below_min /dev/vda 31539
assert_rc "undersized pre-partitioned disk still refused" 0 $?
lsblk() {
    case "$*" in
        *"-d "*) echo 536870912000 ;;                           # 500 GiB, whole disk
        *"-bno SIZE"*) printf '536870912000\n1048576\n524288000\n' ;;
    esac
}
disk_below_min /dev/vda 31539
assert_rc "large pre-partitioned disk still accepted" 1 $?

t_section "explain_no_candidates: says WHY nothing qualified"
# The bare "No suitable target installation disks found." gave no way to tell
# an absent disk from an undersized one. Reproduces the common test-VM layout:
# a 20 GiB virtio disk plus the live ISO on an optical device.
lsblk() {
    local dev="${!#}"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) printf '/dev/vda 20G disk 0\n/dev/sr0 1.3G rom 1\n' ;;
        *MOUNTPOINTS*) if [ "$dev" = "/dev/sr0" ]; then echo "/run/live/medium"; fi; return 0 ;;
        *"-d "*) case "$dev" in /dev/vda) echo 21474836480 ;; esac ;;
    esac
}
REASONS="$(explain_no_candidates 31539)"
assert_contains "undersized disk named with its size" "${REASONS}" "/dev/vda"
assert_contains "and the reason it was refused" "${REASONS}" "too small (needs 31539 MiB)"
assert_contains "optical device explained too" "${REASONS}" "not a disk (rom)"

t_section "explain_no_candidates: no block devices at all"
lsblk() { case "$*" in *"NAME,SIZE,TYPE,RO"*) : ;; esac; }
assert_contains "empty machine says so explicitly" "$(explain_no_candidates 31539)" "no block devices detected at all"

t_section "explain_no_candidates: a read-only disk is not silently dropped"
lsblk() {
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) printf '/dev/sda 500G disk 1\n' ;;
        *MOUNTPOINTS*) : ;;
        *"-d "*) echo 536870912000 ;;
    esac
}
assert_contains "read-only disk reported as such" "$(explain_no_candidates 31539)" "read-only"

t_section "validate_target_disk: stable identity and safe state"
lsblk() {
    case "$*" in
        *"-dno TYPE"*) echo disk ;;
        *"-dno RO"*) echo 0 ;;
        *"-dno MAJ:MIN"*) echo 8:0 ;;
        *"-dnbo SIZE"*) echo 536870912000 ;;
        *"-dno SERIAL"*) echo SERIAL-1 ;;
        *"-dno WWN"*) echo WWN-1 ;;
        *MOUNTPOINTS*|*"-nrpo NAME"*|*"-nrpo KNAME"*) : ;;
    esac
}
validate_target_disk /dev/sda 31539 8:0 536870912000 SERIAL-1 WWN-1
assert_rc "unchanged unused disk passes revalidation" 0 $?
validate_target_disk /dev/sda 31539 8:0 536870912000 DIFFERENT WWN-1
assert_rc "serial change fails revalidation" 1 $?
lsblk() {
    case "$*" in
        *"-dno TYPE"*) echo disk ;;
        *"-dno RO"*) echo 0 ;;
        *"-dno MAJ:MIN"*) echo 8:0 ;;
        *"-dnbo SIZE"*) echo 536870912000 ;;
        *"-dno SERIAL"*) echo SERIAL-1 ;;
        *"-dno WWN"*) echo WWN-1 ;;
        *MOUNTPOINTS*) echo /media/data ;;
        *"-nrpo NAME"*|*"-nrpo KNAME"*) : ;;
    esac
}
validate_target_disk /dev/sda 31539 8:0 536870912000 SERIAL-1 WWN-1
assert_rc "new mount fails revalidation" 1 $?

t_section "in-use probes fail closed and detect holders/swap by device ID"
safety_tree="$(mktemp -d)"
mkdir -p "${safety_tree}/sys/sda/holders" "${safety_tree}/sys/sda1/holders"
touch "${safety_tree}/sys/sda1/holders/dm-0"
SYS_CLASS_BLOCK="${safety_tree}/sys"
PROC_SWAPS="${safety_tree}/swaps"
printf 'Filename Type Size Used Priority\n/dev/dm-2 partition 1024 0 -2\n' > "$PROC_SWAPS"
lsblk() {
    case "$*" in
        *MOUNTPOINTS*) return 1 ;;
        *"KNAME"*) printf 'sda\nsda1\n' ;;
        *"-nrno MAJ:MIN /dev/sda"*) printf '8:0\n8:1\n253:2\n' ;;
        *"-dnro MAJ:MIN /dev/dm-2"*) printf '253:2\n' ;;
    esac
}
disk_has_mounts /dev/sda; assert_rc "failed mount probe marks disk in use" 0 $?
disk_has_holders /dev/sda; assert_rc "sysfs holder detected without path-corrupted KNAME" 0 $?
disk_has_active_swap /dev/sda; assert_rc "active mapper swap matched by major:minor" 0 $?
PROC_SWAPS="${safety_tree}/missing-swaps"
disk_has_active_swap /dev/sda; assert_rc "unreadable swap state marks disk in use" 0 $?
SYS_CLASS_BLOCK="/sys/class/block"
PROC_SWAPS="/dev/null"
rm -rf "$safety_tree"

t_section "target mount tree must be unused before installation"
findmnt() { printf '/\n/mnt\n/mnt/external\n'; }
target_mount_tree_busy /mnt; assert_rc "target mount itself is busy" 0 $?
target_mount_tree_busy /safe-target; assert_rc "unmounted target path is available" 1 $?

t_section "unmount_target touches only installer-owned resources"
mock_setup
INSTALLER_OWNS_TARGET_MOUNTS=false
INSTALLER_OPENED_CRYPTROOT=false
mountpoint() { mlog "mountpoint $*"; return 0; }
umount() { mlog "umount $*"; }
cryptsetup() { mlog "cryptsetup $*"; }
unmount_target
assert_eq "no ownership means no mount inspection or unmount" "" "$(cat "${MOCK_LOG}")"
mock_teardown

t_summary
