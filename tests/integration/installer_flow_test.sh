#!/usr/bin/env bash
# Integration test: runs the installer's full main() flow end-to-end with
# every destructive/external tool mocked, driven through the text-mode UI via
# piped answers. Covers all four disk combinations (Btrfs/Ext4 x LUKS on/off)
# plus desktop/keyd/apps/NVIDIA variants and abort paths.
#
# Assumptions: /lib/live does not exist on test hosts, so the debootstrap
# branch is taken deterministically.
TEST_NAME="installer_flow_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

source "${INSTALLER_DIR}/sensible-install.sh"   # guarded: main() not invoked on source
UI_TOOL="text"                                   # deterministic UI under test

check_root() { :; }
check_uefi()  { :; }
sleep()       { :; }

WORK="$(mktemp -d /tmp/sensible-flow-test.XXXXXX)"
ANSWERS="${WORK}/answers.txt"
OUT="${WORK}/stdout.log"
ERR="${WORK}/stderr.log"
MOCK_NVIDIA=0

# --- global mocks (installed tools) ----------------------------------------
free()         { printf '              total        used        free\nMem:           8192        1024        7168\n'; }

lsblk() {
    mlog "lsblk $*"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) echo "/dev/sda 500G disk 0" ;;
        *MOUNTPOINTS*) : ;;
        *"-bno SIZE"*) echo 536870912000 ;;
        *"-dno MODEL"*) echo "TestDisk" ;;
    esac
}

sgdisk()      { mlog "sgdisk $*"; }
wipefs()      { mlog "wipefs $*"; }
partprobe()   { mlog "partprobe $*"; }
mkfs.vfat()   { mlog "mkfs.vfat $*"; }
mkfs.ext4()   { mlog "mkfs.ext4 $*"; }
mkfs.btrfs()  { mlog "mkfs.btrfs $*"; }
mkswap()      { mlog "mkswap $*"; }
cryptsetup()  { mlog "cryptsetup $*"; }
mount()       { mlog "mount $*"; }
umount()      { mlog "umount $*"; }
mountpoint()  { mlog "mountpoint $*"; return 0; }
btrfs()       { mlog "btrfs $*"; if [ "$1" = "inspect-internal" ]; then echo "38400"; fi; }
chattr()      { mlog "chattr $*"; }
fallocate()   { mlog "fallocate $*"; touch "$3"; }
filefrag()    { mlog "filefrag $*"; echo " 0:        0..       0:    38400..    38400:       1:"; }
debootstrap() { mlog "debootstrap $*"; }
timedatectl() { mlog "timedatectl $*"; echo "Europe/Berlin"; }
git()         { mlog "git $*"; if [ "$1" = "clone" ]; then local t="${@: -1}"; mkdir -p "$t"; echo "test" > "$t/init.lua"; fi; }
curl()        { mlog "curl $*"; touch "$2"; }
lspci() {
    mlog "lspci $*"
    if [ "${MOCK_NVIDIA}" = "1" ]; then
        echo "01:00.0 VGA compatible controller [0301]: NVIDIA Corporation GA106 [10de:2531]"
    else
        echo "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics"
    fi
}
# Deterministic identifier map; /dev/sda3 is LUKS root or plain swap
# depending on the current run's ENABLE_LUKS (visible via dynamic scoping).
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
chroot() {
    mlog "chroot $*"
    shift
    if [ "${1:-}" = "id" ] && [ "${2:-}" = "-nG" ]; then
        echo "sudo audio video plugdev netdev bluetooth"
    fi
    return 0
}

# --- flow driver ------------------------------------------------------------
build_answers() {
    # fs luks de keyd extras [confirm_disk] [username]
    local fs="$1" luks="$2" de="$3" keyd="$4" extras="$5"
    local confirm="${6:-/dev/sda}" username="${7:-alice}"
    {
        printf '\n'                       # welcome msgbox
        printf '1\n'                      # disk menu -> /dev/sda
        case "$fs"   in btrfs) printf '1\n' ;; ext4) printf '2\n' ;; esac
        case "$luks" in
            yes) printf 'y\npass12345\npass12345\n' ;;
            no)  printf 'n\n' ;;
        esac
        case "$de"   in gnome) printf '1\n' ;; kde) printf '2\n' ;; esac
        case "$keyd" in yes) printf 'y\n' ;; no) printf 'n\n' ;; esac
        printf '%s\n' "${extras}"         # optional software checklist
        printf 'sensible-box\n'           # hostname
        printf '%s\n' "${username}"       # username
        printf 'pw1234567\npw1234567\n'   # user password + confirm
        printf 'Europe/Berlin\n'          # timezone
        printf 'en_US.UTF-8\n'            # locale
        printf 'us\n'                     # keyboard
        printf '%s\n' "${confirm}"        # type-to-confirm wipe
        printf '\n'                       # enter on the final "Complete" msgbox
    } > "${ANSWERS}"
}

prep_target() {
    MNT="${WORK}/target"
    rm -rf "${MNT}"
    mkdir -p "${MNT}/etc" "${MNT}/etc/apt" "${MNT}/etc/default" "${MNT}/home/alice"
}

# main() uses exit() on abort paths, so always invoke it in a subshell.
run_flow() {
    prep_target
    mock_setup
    : > "${OUT}"; : > "${ERR}"
    RC=0
    ( main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" ) || RC=$?
    cp "${MOCK_LOG}" "${WORK}/calls.log"
    mock_teardown
}

log_text() { cat "${WORK}/calls.log"; }

# Shared assertions for a successful run
assert_common_success() {
    assert_rc "main returns 0" 0 "${RC}"
    assert_contains "success logged" "$(cat "${ERR}")" "Installation finished successfully!"
    assert_contains "completion dialog shown" "$(cat "${ERR}")" "has completed successfully"
    assert_file_contains "sources.list: testing + full archive areas" "${MNT}/etc/apt/sources.list" "deb https://deb.debian.org/debian testing main contrib non-free non-free-firmware"
    assert_file_contains "hostname written" "${MNT}/etc/hostname" "sensible-box"
    assert_file_contains "hosts entry" "${MNT}/etc/hosts" "127.0.1.1 sensible-box"
    assert_file_contains "locale.gen" "${MNT}/etc/locale.gen" "en_US.UTF-8 UTF-8"
    assert_file_contains "default locale" "${MNT}/etc/default/locale" "LANG=en_US.UTF-8"
    assert_file_contains "keyboard layout applied" "${MNT}/etc/default/keyboard" 'XKBLAYOUT="us"'
    assert_contains "timezone symlink attempted via chroot" "$(log_text)" "chroot ${MNT} ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime"
    assert_contains "groups pre-created" "$(log_text)" "chroot ${MNT} groupadd -f bluetooth"
    assert_contains "user added to sudo group" "$(log_text)" "chroot ${MNT} useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth alice"
    assert_contains "user password set" "$(log_text)" "chroot ${MNT} chpasswd"
    assert_contains "grub-install efi debian id" "$(log_text)" "chroot ${MNT} grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck"
    assert_contains "Secure Boot chain installed (shim + signed GRUB)" "$(log_text)" "grub-efi-amd64 grub-efi-amd64-signed shim-signed cryptsetup-initramfs"
    assert_contains "initramfs updated" "$(log_text)" "chroot ${MNT} update-initramfs -u -k all"
    assert_contains "grub config regenerated" "$(log_text)" "chroot ${MNT} update-grub"
    assert_contains "teardown unmounts target" "$(log_text)" "umount -R ${MNT}"
    assert_contains "EFI partition formatted" "$(log_text)" "mkfs.vfat -F32 -n EFI /dev/sda1"
    assert_contains "BOOT partition formatted" "$(log_text)" "mkfs.ext4 -F -L BOOT /dev/sda2"
    assert_contains "hardware: firmware-brcm80211 (not firmware-broadcom)" "$(log_text)" "firmware-brcm80211"
    assert_contains "hardware: PipeWire bluetooth codec" "$(log_text)" "libspa-0.2-bluetooth"
    assert_contains "hardware: power-profiles-daemon" "$(log_text)" "power-profiles-daemon"
    assert_contains "hardware: fwupd" "$(log_text)" "fwupd"
    assert_contains "apps: firefox" "$(log_text)" "firefox"
    assert_contains "apps: neovim" "$(log_text)" "neovim"
    assert_contains "apps: flathub" "$(log_text)" "flatpak remote-add --if-not-exists flathub"
    assert_contains "apps: LazyVim starter" "$(log_text)" "git clone --depth 1 https://github.com/LazyVim/starter"
    assert_file_exists "LazyVim in user home" "${MNT}/home/alice/.config/nvim/init.lua"
}

# ============================================================================
t_section "Combo 1: Btrfs + LUKS, GNOME, keyd on, all extras, Intel GPU"
build_answers btrfs yes gnome yes "chromium brave audacious native_media"
MOCK_NVIDIA=0
run_flow
assert_common_success
assert_contains "LUKS root is p3 type 8309" "$(log_text)" "sgdisk -n 3:0:0 -t 3:8309"
assert_not_contains "no swap partition with LUKS" "$(log_text)" "8200"
assert_not_contains "no p4 with LUKS" "$(log_text)" "-n 4:0:0"
assert_contains "LUKS2 argon2id" "$(log_text)" "cryptsetup luksFormat --type luks2 --pbkdf argon2id --hash sha512 --key-size 512 --batch-mode /dev/sda3"
assert_contains "cryptroot opened" "$(log_text)" "cryptsetup open /dev/sda3 cryptroot"
assert_contains "btrfs on mapper" "$(log_text)" "mkfs.btrfs -f -L ROOT /dev/mapper/cryptroot"
assert_contains "subvol @swap created" "$(log_text)" "btrfs subvolume create ${MNT}/@swap"
assert_contains "@swap mounted" "$(log_text)" "mount -o noatime,subvol=@swap /dev/mapper/cryptroot ${MNT}/swap"
assert_contains "swapfile created NOCOW, RAM+10%" "$(log_text)" "chattr +C ${MNT}/swap/swapfile"
assert_contains "swapfile sized 9011M" "$(log_text)" "fallocate -l 9011M ${MNT}/swap/swapfile"
assert_contains "swapfile formatted" "$(log_text)" "mkswap ${MNT}/swap/swapfile"
assert_file_contains "crypttab: cryptroot by header UUID only" "${MNT}/etc/crypttab" "cryptroot UUID=ROOTPART-FS-UUID-4444 none luks,discard"
assert_file_not_contains "no cryptswap (swapfile design)" "${MNT}/etc/crypttab" "cryptswap"
assert_file_contains "fstab: root subvol=@" "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /            btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@"
assert_file_contains "fstab: @swap subvolume" "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /swap        btrfs  noatime,subvol=@swap"
assert_file_contains "fstab: swapfile on encrypted root" "${MNT}/etc/fstab" "/swap/swapfile none swap sw 0 0"
assert_file_contains "resume= via swapfile offset (hibernation on LUKS)" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=ROOTFS-FS-UUID-5555 resume_offset=38400"
assert_file_contains "initramfs RESUME set" "${MNT}/etc/initramfs-tools/conf.d/resume" "RESUME=UUID=ROOTFS-FS-UUID-5555"
assert_contains "GNOME packages" "$(log_text)" "gnome-core gdm3 gnome-software gnome-software-plugin-flatpak"
assert_contains "spinner theme" "$(log_text)" "plymouth-set-default-theme -R spinner"
assert_contains "gdm3 enabled" "$(log_text)" "systemctl enable gdm3.service"
assert_file_contains "keyd conf deployed from configs/" "${MNT}/etc/keyd/default.conf" "c = C-insert"
assert_contains "chromium installed" "$(log_text)" "apt-get install -y chromium"
assert_file_contains "brave official origin" "${MNT}/etc/apt/sources.list.d/brave-browser-release.list" "https://brave-browser-apt-release.s3.brave.com/ stable main"
assert_contains "amberol for GNOME native_media" "$(log_text)" "apt-get install -y amberol"
assert_not_contains "no elisa on GNOME" "$(log_text)" "apt-get install -y elisa"
assert_not_contains "no NVIDIA driver without GPU" "$(log_text)" "nvidia-driver"

t_section "Combo 2: Btrfs + no LUKS, KDE, keyd off, NVIDIA GPU"
build_answers btrfs no kde no "native_media"
MOCK_NVIDIA=1
run_flow
assert_common_success
assert_contains "p4 typed plain 8300" "$(log_text)" "sgdisk -n 4:0:0 -t 4:8300"
assert_contains "swap partition sized RAM+10%" "$(log_text)" "sgdisk -n 3:0:+9011M -t 3:8200"
assert_contains "plain swap formatted" "$(log_text)" "mkswap -L SWAP /dev/sda3"
assert_not_contains "no cryptsetup without LUKS" "$(log_text)" "luksFormat"
assert_contains "btrfs on raw partition" "$(log_text)" "mkfs.btrfs -f -L ROOT /dev/sda4"
assert_not_contains "no swapfile without LUKS" "$(log_text)" "swap/swapfile"
assert_file_contains "crypttab placeholder" "${MNT}/etc/crypttab" "No encrypted volumes configured"
assert_file_contains "fstab: plain swap by UUID" "${MNT}/etc/fstab" "UUID=SWAP-FS-UUID-3333 none swap sw 0 0"
assert_file_contains "resume=UUID for partition swap" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=SWAP-FS-UUID-3333"
assert_file_contains "initramfs RESUME set" "${MNT}/etc/initramfs-tools/conf.d/resume" "RESUME=UUID=SWAP-FS-UUID-3333"
assert_contains "KDE packages" "$(log_text)" "kde-plasma-desktop sddm plasma-discover plasma-discover-backend-flatpak plymouth-theme-breeze"
assert_contains "breeze theme" "$(log_text)" "plymouth-set-default-theme -R breeze"
assert_contains "sddm enabled" "$(log_text)" "systemctl enable sddm.service"
assert_file_not_exists "no keyd conf when declined" "${MNT}/etc/keyd/default.conf"
assert_contains "NVIDIA driver added on detection" "$(log_text)" "nvidia-driver"
assert_contains "elisa for KDE native_media" "$(log_text)" "apt-get install -y elisa"
assert_not_contains "no amberol on KDE" "$(log_text)" "apt-get install -y amberol"

t_section "Combo 3: Ext4 + LUKS, GNOME, keyd off, one extra"
build_answers ext4 yes gnome no "audacious"
MOCK_NVIDIA=0
run_flow
assert_common_success
assert_contains "LUKS root is p3 type 8309" "$(log_text)" "sgdisk -n 3:0:0 -t 3:8309"
assert_contains "ext4 on mapper" "$(log_text)" "mkfs.ext4 -F -L ROOT -O fast_commit /dev/mapper/cryptroot"
assert_not_contains "no btrfs subvols" "$(log_text)" "subvolume create"
assert_file_contains "fstab: ext4 root" "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /            ext4   noatime,errors=remount-ro,discard"
assert_file_contains "fstab: swapfile at encrypted root" "${MNT}/etc/fstab" "/swapfile none swap sw 0 0"
assert_file_contains "resume= via swapfile offset" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=ROOTFS-FS-UUID-5555 resume_offset=38400"
assert_file_not_exists "no keyd conf" "${MNT}/etc/keyd/default.conf"
assert_contains "audacious installed" "$(log_text)" "apt-get install -y audacious"

t_section "Combo 4: Ext4 + no LUKS, KDE, keyd on"
build_answers ext4 no kde yes ""
MOCK_NVIDIA=0
run_flow
assert_common_success
assert_contains "ext4 on raw partition" "$(log_text)" "mkfs.ext4 -F -L ROOT -O fast_commit /dev/sda4"
assert_file_contains "plain swap UUID" "${MNT}/etc/fstab" "UUID=SWAP-FS-UUID-3333 none swap sw 0 0"
assert_file_contains "resume=UUID set" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=SWAP-FS-UUID-3333"
assert_file_contains "keyd conf deployed" "${MNT}/etc/keyd/default.conf" "v = S-insert"

t_section "Abort: undersized disk refused before partitioning"
prep_target
mock_setup
lsblk() {
    mlog "lsblk $*"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) echo "/dev/sda 10G disk 0" ;;
        *MOUNTPOINTS*) : ;;
        *"-bno SIZE"*) echo 10737418240 ;;
    esac
}
printf '\n1\n' > "${ANSWERS}"   # welcome + disk pick only; never reached
: > "${OUT}"; : > "${ERR}"
rc=0; ( main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" ) || rc=$?
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
assert_rc "installer exits 1 when no disk is large enough" 1 "${rc}"
assert_contains "no-candidates error surfaced" "$(cat "${ERR}")" "No suitable target installation disks found"
assert_not_contains "no partitioning happened" "$(log_text)" "sgdisk"
lsblk() {
    mlog "lsblk $*"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) echo "/dev/sda 500G disk 0" ;;
        *MOUNTPOINTS*) : ;;
        *"-bno SIZE"*) echo 536870912000 ;;
        *"-dno MODEL"*) echo "TestDisk" ;;
    esac
}

t_section "Abort: wipe confirmation must match disk exactly"
build_answers btrfs yes gnome yes "" "/dev/wrong-disk"
prep_target
mock_setup
rc=0; ( main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" ) || rc=$?
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
assert_rc "installer aborts on mismatched confirmation" 1 "${rc}"
assert_not_contains "no partitioning on mismatch" "$(log_text)" "sgdisk"

t_section "Username re-prompt: invalid input rejected, valid accepted"
prep_target
mock_setup
{
    printf '\n'                       # welcome
    printf '1\n'                      # disk
    printf '1\n'                      # fs btrfs
    printf 'n\n'                      # no LUKS
    printf '1\n'                      # gnome
    printf 'n\n'                      # no keyd
    printf '\n'                       # no extras
    printf 'sensible-box\n'           # hostname
    printf 'Bad Name\n'               # username #1: invalid
    printf '\n'                       # enter for the invalid-username msgbox
    printf 'alice\n'                  # username #2: valid
    printf 'pw1234567\npw1234567\n'   # password + confirm
    printf 'Europe/Berlin\n'
    printf 'en_US.UTF-8\n'
    printf 'us\n'
    printf '/dev/sda\n'
    printf '\n'                       # enter on the final "Complete" msgbox
} > "${ANSWERS}"
: > "${OUT}"; : > "${ERR}"
rc=0; ( main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" ) || rc=$?
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
assert_rc "install succeeds after re-prompt" 0 "${rc}"
assert_contains "user 'alice' created (not 'Bad Name')" "$(log_text)" "useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth alice"

rm -rf "${WORK}"
trap - EXIT   # drop the installer's cleanup trap before exiting the test shell
t_summary
