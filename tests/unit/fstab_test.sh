#!/usr/bin/env bash
# Unit tests for installer/lib/fstab.sh — crypttab/fstab generation for all
# four combinations (Btrfs/Ext4 x LUKS on/off), plus blkid guards.
TEST_NAME="fstab_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/fstab.sh"

TMP_MNT="$(mktemp -d)"
MNT="${TMP_MNT}"
mkdir -p "${MNT}/etc"

# Deterministic identifier map: /dev/sda3 is the LUKS root partition when
# ENABLE_LUKS=true (header UUID) and the plain swap partition otherwise.
blkid() {
    local type="$2" dev="${*: -1}"
    case "${dev}:${type}" in
        /dev/sda1:UUID)     echo "EFI-FS-UUID-1111" ;;
        /dev/sda2:UUID)     echo "BOOT-FS-UUID-2222" ;;
        /dev/sda3:UUID)     if [ "${ENABLE_LUKS:-false}" = "true" ]; then echo "ROOTPART-FS-UUID-4444"; else echo "SWAP-FS-UUID-3333"; fi ;;
        /dev/sda4:UUID)     echo "ROOTPART-FS-UUID-4444" ;;
        /dev/mapper/cryptroot:UUID) echo "ROOTFS-FS-UUID-5555" ;;
    esac
}

t_section "Btrfs + LUKS (swapfile on encrypted @swap subvol)"
ENABLE_LUKS=true
generate_crypttab_and_fstab /dev/mapper/cryptroot /dev/sda2 /dev/sda1 "" /dev/sda3 btrfs true
assert_file_contains "cryptroot by LUKS header UUID" "${MNT}/etc/crypttab" "cryptroot UUID=ROOTPART-FS-UUID-4444 none luks,discard"
assert_file_not_contains "no cryptswap (swapfile design)" "${MNT}/etc/crypttab" "cryptswap"
assert_file_contains "fstab root subvol=@"        "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /            btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@          0 0"
assert_file_contains "fstab subvol=@home"         "${MNT}/etc/fstab" "subvol=@home"
assert_file_contains "fstab subvol=@snapshots"    "${MNT}/etc/fstab" "subvol=@snapshots"
assert_file_contains "fstab subvol=@var_log"      "${MNT}/etc/fstab" "subvol=@var_log"
assert_file_contains "fstab @swap subvolume"      "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /swap        btrfs  noatime,subvol=@swap"
assert_file_contains "fstab swapfile on encrypted root" "${MNT}/etc/fstab" "/swap/swapfile none swap sw 0 0"
assert_file_contains "fstab /boot"                "${MNT}/etc/fstab" "UUID=BOOT-FS-UUID-2222     /boot        ext4   noatime"
assert_file_contains "fstab EFI umask=0077"       "${MNT}/etc/fstab" "UUID=EFI-FS-UUID-1111      /boot/efi    vfat   umask=0077"
assert_file_contains "fstab tmpfs /tmp"           "${MNT}/etc/fstab" "tmpfs                /tmp         tmpfs  defaults,nosuid,nodev"

t_section "Ext4 + no LUKS"
ENABLE_LUKS=false
generate_crypttab_and_fstab /dev/sda4 /dev/sda2 /dev/sda1 /dev/sda3 /dev/sda4 ext4 false
assert_file_contains "crypttab placeholder only" "${MNT}/etc/crypttab" "# /etc/crypttab: No encrypted volumes configured."
assert_file_contains "fstab plain swap by UUID"  "${MNT}/etc/fstab" "UUID=SWAP-FS-UUID-3333 none swap sw 0 0"
assert_file_contains "fstab root uses partition fs UUID" "${MNT}/etc/fstab" "UUID=ROOTPART-FS-UUID-4444  /            ext4   noatime,errors=remount-ro,discard                                     0 1"
assert_file_not_contains "no btrfs subvols"      "${MNT}/etc/fstab" "subvol="

t_section "Btrfs + no LUKS swaps the swap line, keeps subvols"
ENABLE_LUKS=false
generate_crypttab_and_fstab /dev/sda4 /dev/sda2 /dev/sda1 /dev/sda3 /dev/sda4 btrfs false
assert_file_contains "plain swap UUID" "${MNT}/etc/fstab" "UUID=SWAP-FS-UUID-3333 none swap sw 0 0"
assert_file_not_contains "no mapper swap" "${MNT}/etc/fstab" "cryptswap"
assert_file_contains "subvol=@ kept" "${MNT}/etc/fstab" "subvol=@home"

t_section "Ext4 + LUKS (swapfile at encrypted root)"
ENABLE_LUKS=true
generate_crypttab_and_fstab /dev/mapper/cryptroot /dev/sda2 /dev/sda1 "" /dev/sda3 ext4 true
assert_file_not_contains "no cryptswap" "${MNT}/etc/crypttab" "cryptswap"
assert_file_contains "fstab swapfile at root" "${MNT}/etc/fstab" "/swapfile none swap sw 0 0"
assert_file_not_contains "no @swap line for ext4" "${MNT}/etc/fstab" "/swap        btrfs"
assert_file_not_contains "no subvols for ext4" "${MNT}/etc/fstab" "subvol="

t_section "Guards: empty blkid result aborts before writing broken files"
blkid_broken() { echo ""; }
blkid() { blkid_broken "$@"; }
rc="$(run_exiting generate_crypttab_and_fstab /dev/mapper/cryptroot /dev/sda2 /dev/sda1 "" /dev/sda3 btrfs true)"
assert_rc "missing ROOT UUID exits 1" 1 "${rc}"
assert_file_not_contains "fstab not rewritten on failure" "${MNT}/etc/fstab" "SHOULD-NOT-APPEAR"

t_summary
rm -rf "${TMP_MNT}"
