#!/usr/bin/env bash
# Integration test: runs the installer's full main() flow end-to-end with
# every destructive/external tool mocked, driven through the text-mode UI via
# piped answers. Covers the guided flow: keyboard → user → disk → filesystem
# → encryption → confirm.

TEST_NAME="installer_flow_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

source "${INSTALLER_DIR}/sensible-install.sh"
UI_TOOL="text"
SENSIBLE_TEST_MODE=1

check_root() { :; }
check_uefi()  { :; }
sleep()       { :; }

WORK="$(mktemp -d /tmp/sensible-flow-test.XXXXXX)"
ANSWERS="${WORK}/answers.txt"
OUT="${WORK}/stdout.log"
ERR="${WORK}/stderr.log"
MOCK_NVIDIA=0
MOCK_LIVE_USER=1
MOCK_MISSING_PACKAGE=""
MOCK_LEAVE_LIVE_INITRAMFS=0
MOCK_SYSTEMCTL_REBOOT_RC=0
MOCK_REBOOT_RC=0
LIVE_KEYBOARD_FILE="${WORK}/live-keyboard"
INSTALL_LOG="${WORK}/sensible-install.log"
PROC_SWAPS="${WORK}/swaps"
printf 'Filename Type Size Used Priority\n' > "$PROC_SWAPS"
declare -A MOCK_MOUNTS=()

free()         { printf '              total        used        free\nMem:           8192        1024        7168\n'; }

lsblk() {
    mlog "lsblk $*"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) echo "/dev/sda 500G disk 0" ;;
        *MOUNTPOINTS*) : ;;
        *"-dnbo SIZE"*|*"-bno SIZE"*) echo 536870912000 ;;
        *"-dno MAJ:MIN"*) echo "8:0" ;;
        *"-dno TYPE"*) echo "disk" ;;
        *"-dno RO"*) echo "0" ;;
        *"-dno SERIAL"*) echo "TEST-SERIAL-001" ;;
        *"-dno WWN"*) echo "TEST-WWN-001" ;;
        *"-dno MODEL"*) echo "TestDisk" ;;
    esac
}

sgdisk()      { mlog "sgdisk $*"; }
rsync()       {
    mlog "rsync $*"
    mkdir -p "${MNT}/etc/profile.d" "${MNT}/usr/local/bin" "${MNT}/opt/sensible/configs" "${MNT}/boot" "${MNT}/etc/initramfs-tools" "${MNT}/run/live" "${MNT}/etc/live" "${MNT}/etc/sudoers.d" "${MNT}/etc/keyd" "${MNT}/etc/skel/.config/nvim" "${MNT}/var/lib/dpkg/info" "${MNT}/usr/sbin" "${MNT}/usr/bin"
    cp "${REPO_ROOT}/configs/keyd-default.conf" "${MNT}/etc/keyd/default.conf"
    printf '%s\n' 'require("config.lazy")' > "${MNT}/etc/skel/.config/nvim/init.lua"
    if [ "${MOCK_LIVE_USER}" = "1" ]; then
        printf 'user:x:999:999:Live User:/home/user:/bin/bash\n' > "${MNT}/etc/passwd"
        printf 'user:!:20000:0:99999:7:::\n' > "${MNT}/etc/shadow"
        printf 'sudo:x:27:user\n' > "${MNT}/etc/group"
        printf 'user ALL=(ALL) NOPASSWD: ALL\n' > "${MNT}/etc/sudoers.d/live-user"
        mkdir -p "${MNT}/home/user"
        touch "${MNT}/home/user/.bashrc"
        mkdir -p "${MNT}/etc/gdm3" "${MNT}/etc/sddm.conf.d"
        printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=user\n' > "${MNT}/etc/gdm3/daemon.conf"
        printf '[Autologin]\nUser=user\n' > "${MNT}/etc/sddm.conf.d/autologin.conf"
    fi
    touch "${MNT}/etc/profile.d/99-sensible-autostart.sh" \
          "${MNT}/etc/profile.d/99-sensible-firmware-check.sh" \
          "${MNT}/usr/local/bin/sensible-install" "${MNT}/usr/local/bin/lazydeb"
    # The live root carries the full baked closure: kernel and initramfs are
    # copied by rsync, NOT installed by apt on the offline path.
    touch "${MNT}/boot/vmlinuz-7.1.0-amd64" "${MNT}/boot/initrd.img-7.1.0-amd64"
    # live-build ships update-initramfs disabled inside the image; the installer
    # must re-enable it or every initramfs regen on the target silently no-ops.
    printf 'update_initramfs=no\n' > "${MNT}/etc/initramfs-tools/update-initramfs.conf"
    # live-build also ships live-system markers in /run/live, /etc/live; if those
    # leak into the chroot, update-initramfs refuses to regenerate regardless of
    # the conf file. The installer must strip them.
    touch -d '2025-01-01' "${MNT}/boot/vmlinuz-7.1.0-amd64" "${MNT}/boot/initrd.img-7.1.0-amd64"
    mkdir -p "${MNT}/run/live/medium"
    touch "${MNT}/etc/live/version"
    # live-tools diverts the real initramfs-tools command.  This is the exact
    # ISO state behind the repeated failure: the wrapper inherits boot=live
    # from /proc and silently refuses to regenerate the target initramfs.
    touch "${MNT}/usr/sbin/update-initramfs.orig.initramfs-tools" \
          "${MNT}/usr/bin/live-update-initramfs"
    chmod +x "${MNT}/usr/sbin/update-initramfs.orig.initramfs-tools" \
             "${MNT}/usr/bin/live-update-initramfs"
    ln -s ../bin/live-update-initramfs "${MNT}/usr/sbin/update-initramfs"
    # The baked closure includes cryptsetup-initramfs (dpkg info files present)
    touch "${MNT}/var/lib/dpkg/info/cryptsetup-initramfs.list" \
          "${MNT}/var/lib/dpkg/info/cryptsetup-initramfs.md5sums"
}
wipefs()      { mlog "wipefs $*"; }
partprobe()   { mlog "partprobe $*"; }
mkfs.vfat()   { mlog "mkfs.vfat $*"; }
mkfs.ext4()   { mlog "mkfs.ext4 $*"; }
mkfs.btrfs()  { mlog "mkfs.btrfs $*"; }
mkswap()      { mlog "mkswap $*"; }
cryptsetup()  { mlog "cryptsetup $*"; }
mount()       {
    mlog "mount $*"
    local target="${*: -1}"
    MOCK_MOUNTS["$target"]=1
    # Track the kind of mount so we can assert /run is a fresh tmpfs and not a
    # bind of the live host's /run (which carries /run/live/medium and makes
    # update-initramfs refuse to regenerate inside the chroot).
    if [ "${1:-}" = "-t" ] && [ "${2:-}" = "tmpfs" ]; then
        MOCK_TMPFS_MOUNTS["$target"]="${3:-tmpfs}"
        # Simulate a real tmpfs mount: the target now shows an empty filesystem
        # even if the rsync mock previously copied live markers into it. This is
        # what the chroot would see and what update-initramfs cares about.
        find "${target:?}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
}
declare -A MOCK_TMPFS_MOUNTS=()
umount()      {
    mlog "umount $*"
    local target="${*: -1}" mounted
    if [ "${1:-}" = "-R" ]; then
        for mounted in "${!MOCK_MOUNTS[@]}"; do
            [[ "$mounted" = "$target" || "$mounted" = "$target/"* ]] && unset 'MOCK_MOUNTS[$mounted]'
        done
    else
        unset 'MOCK_MOUNTS[$target]'
    fi
}
mountpoint()  {
    mlog "mountpoint $*"
    local target="${*: -1}"
    [ "${MOCK_MOUNTS[$target]:-0}" = "1" ]
}
btrfs()       { mlog "btrfs $*"; if [ "$1" = "inspect-internal" ]; then echo "38400"; fi; }
chattr()      { mlog "chattr $*"; }
fallocate()   { mlog "fallocate $*"; touch "$3"; }
filefrag()    { mlog "filefrag $*"; echo " 0:        0..       0:    38400..    38400:       1:"; }
debootstrap() { mlog "debootstrap $*"; }
timedatectl() { mlog "timedatectl $*"; echo "Europe/Berlin"; }
setupcon()     { mlog "setupcon $*"; }
sync()         { mlog "sync $*"; }
systemctl()    { mlog "systemctl $*"; [ "${1:-}" != "reboot" ] || return "${MOCK_SYSTEMCTL_REBOOT_RC}"; }
reboot()       { mlog "reboot $*"; return "${MOCK_REBOOT_RC}"; }
network_ready() { mlog "network_ready"; return 0; }
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
blkid() {
    local type="$2" dev="${*: -1}"
    case "${dev}:${type}" in
        /dev/sda1:UUID)     echo "EFI-FS-UUID-1111" ;;
        /dev/sda2:UUID)     echo "BOOT-FS-UUID-2222" ;;
        /dev/sda3:UUID)     echo "ROOTPART-FS-UUID-4444" ;;
        /dev/mapper/cryptroot:UUID) echo "ROOTFS-FS-UUID-5555" ;;
    esac
}
chroot() {
    mlog "chroot $*"
    shift
    if [ "${1:-}" = "getent" ] && [ "${2:-}" = "passwd" ]; then
        if [ "${2:-}" = "passwd" ] && [ "${3:-}" = "user" ] && [ "${MOCK_LIVE_USER}" = "1" ]; then return 0; fi
        return 1
    fi
    if [ "${1:-}" = "id" ] && [ "${2:-}" = "-nG" ]; then echo "sudo audio video plugdev netdev bluetooth"; fi
    if [ "${1:-}" = "dpkg-query" ]; then
        local queried_package="${4:-}"
        if [ "${MOCK_MISSING_PACKAGE:-}" = "${queried_package}" ]; then return 1; fi
        # Every package the closure check asks about is installed (baked ISO)
        echo "ii  ${queried_package}  1.0  amd64  test"
        return 0
    fi
    if [ "${1:-}" = "userdel" ]; then
        sed -i '/^user:/d' "${MNT}/etc/passwd" "${MNT}/etc/shadow" 2>/dev/null
        sed -i 's/:user\([,:]*\)/:\1/g' "${MNT}/etc/group" 2>/dev/null
        rm -rf "${MNT}/home/user"
        return 0
    fi
    case "${1:-}" in
        apt-get) mkdir -p "${MNT}/boot"; touch "${MNT}/boot/vmlinuz-7.1.0-amd64" ;;
        dpkg)
            # Simulate live-tools.postrm removing its diversion and restoring
            # initramfs-tools' original executable during the joint purge.
            if [ "${2:-}" = "--purge" ] && [[ " $* " = *" live-tools "* ]] \
                && [ "${MOCK_LEAVE_LIVE_INITRAMFS}" != "1" ]; then
                rm -f "${MNT}/usr/sbin/update-initramfs"
                mv "${MNT}/usr/sbin/update-initramfs.orig.initramfs-tools" \
                   "${MNT}/usr/sbin/update-initramfs"
            fi
            ;;
        update-initramfs)
            # Simulate a real regeneration: stamp the initrd newer than the kernel.
            # update-initramfs also stamps it after itself, so a missing/old stamp
            # in the target means it never ran -- exactly the screenshot bug.
            touch "${MNT}/boot/initrd.img-7.1.0-amd64" ;;
        plymouth-set-default-theme) : ;;
        grub-install) mkdir -p "${MNT}/boot/efi/EFI/debian"; touch "${MNT}/boot/efi/EFI/debian/grubx64.efi" "${MNT}/boot/efi/EFI/debian/shimx64.efi" ;;
        update-grub) mkdir -p "${MNT}/boot/grub"; printf "menuentry 'Debian GNU/Linux' {\n    linux /boot/vmlinuz-7.1.0-amd64 root=UUID=ROOT ro\n    initrd /boot/initrd.img-7.1.0-amd64\n}\n" > "${MNT}/boot/grub/grub.cfg" ;;
    esac
    return 0
}

# validate_installed_boot now inspects the generated initramfs rather than
# trusting its timestamp. The integration suite mocks update-initramfs, so its
# matching extractor must expose the cryptroot entry that regeneration would
# have embedded in a real image.
unmkinitramfs() {
    local _image="$1" destination="$2"
    mlog "unmkinitramfs $*"
    mkdir -p "${destination}/cryptroot"
    if [ -s "${MNT}/etc/crypttab" ]; then
        cp "${MNT}/etc/crypttab" "${destination}/cryptroot/crypttab"
    else
        : > "${destination}/cryptroot/crypttab"
    fi
}

# Guided flow: keyboard → user → disk → filesystem → encryption → autologin
# → final yes/no
build_answers() {
    local luks="$1"  # yes/no
    local final_confirm="${2:-yes}" username="${3:-alice}" completion_action="${4:-live}"
    local filesystem_choice="${5:-btrfs}" filesystem_answer="1"
    local enc_answer="y" # y=encrypted, n=unencrypted
    [ "$luks" = "yes" ] && enc_answer="y" || enc_answer="n"
    [ "$filesystem_choice" = "ext4" ] && filesystem_answer="2"
    {
        printf 'us\n'                     # keyboard
        printf '%s\n' "${username}"       # username
        printf 'pw1234567\npw1234567\n'   # password + confirm (unified for LUKS+user, mandatory 8 chars)
        printf 'sensible-box\n'           # hostname
        printf 'Europe/Berlin\n'          # timezone
        printf 'en_US.UTF-8\n'            # locale
        printf '\n'                       # full name (skip)
        printf '\n'                       # email (skip)
        printf 'y\n'                      # user summary confirm "Does this look right?"
        printf '1\n'                      # disk menu -> /dev/sda (first entry)
        printf '%s\n' "${filesystem_answer}" # filesystem: 1=btrfs, 2=ext4
        printf '%s\n' "${enc_answer}"     # encryption yes/no (text mode ui_yesno)
        if [ "$luks" = "yes" ]; then printf 'y\n'; fi  # autologin prompt (LUKS only)
        if [ "$final_confirm" = "no" ]; then printf 'n\n'; else printf 'y\n'; fi
        if [ "${completion_action}" = "reboot" ]; then
            printf '1\n'                   # reboot/eject in completion menu
        else
            printf '2\n'                   # remain in the live session
        fi
    } > "${ANSWERS}"
}

prep_target() {
    MNT="${WORK}/target"
    rm -rf "${MNT}"
    mkdir -p "${MNT}/etc" "${MNT}/etc/apt" "${MNT}/etc/default" "${MNT}/home/alice"
    MOCK_MOUNTS=()
}

run_flow() {
    prep_target
    local previous_live_root="${LIVE_ROOT_SENTINEL+x}"
    local previous_live_value="${LIVE_ROOT_SENTINEL:-}"
    LIVE_ROOT_SENTINEL="${WORK}"
    mock_setup
    : > "${OUT}"; : > "${ERR}"
    set +e
    ( set -e; main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" )
    RC=$?
    set -e
    cp "${MOCK_LOG}" "${WORK}/calls.log"
    mock_teardown
    if [ -n "${previous_live_root}" ]; then
        LIVE_ROOT_SENTINEL="${previous_live_value}"
    else
        unset LIVE_ROOT_SENTINEL
    fi
}

log_text() { cat "${WORK}/calls.log"; }
output_text() { cat "${OUT}" "${ERR}"; }

assert_common_success() {
    assert_rc "main returns 0" 0 "${RC}"
    assert_contains "success logged" "$(output_text)" "Installation finished successfully!"
    assert_contains "completion action menu shown" "$(output_text)" "Installation Complete"
    assert_contains "completion reports elapsed installation time" "$(output_text)" "Installed in:"
    assert_contains "completion offers reboot and eject" "$(output_text)" "Reboot now and eject optical installation media"
    assert_file_contains "hostname written" "${MNT}/etc/hostname" "sensible-box"
    assert_file_contains "hosts entry" "${MNT}/etc/hosts" "127.0.1.1 sensible-box"
    assert_file_contains "locale.gen" "${MNT}/etc/locale.gen" "en_US.UTF-8 UTF-8"
    assert_file_contains "default locale" "${MNT}/etc/default/locale" "LANG=en_US.UTF-8"
    assert_file_contains "keyboard layout applied" "${MNT}/etc/default/keyboard" 'XKBLAYOUT="us"'
    assert_file_not_exists "no root autologin leak into target (tty1)" "${MNT}/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    assert_file_not_exists "no live installer autostart profile" "${MNT}/etc/profile.d/99-sensible-autostart.sh"
    assert_file_not_exists "no live serial smoke marker" "${MNT}/etc/profile.d/98-sensible-serial-ready.sh"
    assert_file_exists "installer log preserved on target" "${MNT}/var/log/sensible-install.log"
    assert_contains "live keyboard applied" "$(log_text)" "setupcon --force --keyboard-only"
    assert_contains "timezone symlink attempted via chroot" "$(log_text)" "chroot ${MNT} ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime"
    assert_contains "groups pre-created" "$(log_text)" "chroot ${MNT} groupadd -f bluetooth"
    assert_contains "user added to sudo group" "$(log_text)" "chroot ${MNT} useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth alice"
    assert_contains "user password set" "$(log_text)" "chroot ${MNT} chpasswd"
    assert_contains "grub-install efi debian id" "$(log_text)" "chroot ${MNT} grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck"
    assert_contains "signed GRUB package is present in the offline closure" "$(log_text)" "dpkg-query -W -f=\${db:Status-Abbrev} grub-efi-amd64-signed"
    assert_contains "shim package is present in the offline closure" "$(log_text)" "dpkg-query -W -f=\${db:Status-Abbrev} shim-signed"
    assert_contains "initramfs updated" "$(log_text)" "chroot ${MNT} update-initramfs -u -k all"
    assert_contains "grub config regenerated" "$(log_text)" "chroot ${MNT} update-grub"
    assert_contains "teardown unmounts target without recursion" "$(log_text)" "umount ${MNT}"
    assert_not_contains "teardown never recursively unmounts" "$(log_text)" "umount -R ${MNT}"
    assert_contains "EFI partition formatted" "$(log_text)" "mkfs.vfat -F32 -n EFI /dev/sda1"
    assert_contains "BOOT partition formatted" "$(log_text)" "mkfs.ext4 -F -L BOOT /dev/sda2"
    assert_not_contains "offline install does not resolve hardware packages" "$(log_text)" "apt-get install"
    assert_not_contains "offline install does not resolve applications" "$(log_text)" "git clone"
    assert_not_contains "no Flathub setup during offline install" "$(log_text)" "flatpak remote-add"
    assert_contains "hardware uses copied live closure" "$(output_text)" "hardware support is already in the copied live image"
    assert_contains "applications use copied live closure" "$(output_text)" "applications are already in the copied live image"
    assert_file_exists "baked LazyVim starter copied to the user" "${MNT}/home/alice/.config/nvim/init.lua"
    assert_file_exists "GNOME keyd mapping survives de-living" "${MNT}/etc/keyd/default.conf"
    assert_contains "GNOME keyd service enabled" "$(log_text)" "systemctl enable keyd.service"
    assert_file_not_exists "no passwordless live sudo policy remains" "${MNT}/etc/sudoers.d/live-user"
    assert_file_not_exists "live user home removed" "${MNT}/home/user"
    if grep -q '^user:' "${MNT}/etc/passwd" 2>/dev/null; then
        t_fail "live user removed from passwd" "user entry remains"
    else
        t_ok
    fi
    if [ -f "${MNT}/etc/gdm3/daemon.conf" ]; then
        assert_file_not_contains "live user is absent from display-manager autologin" "${MNT}/etc/gdm3/daemon.conf" "AutomaticLogin=user"
    else
        t_ok
    fi
}

t_section "Offline source is mandatory and checked before partitioning"
build_answers no
prep_target
mock_setup
unset LIVE_ROOT_SENTINEL
: > "${OUT}"; : > "${ERR}"
set +e
( set -e; main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" )
rc=$?
set -e
cp "${MOCK_LOG}" "${WORK}/calls.log"
mock_teardown
assert_rc "missing live source aborts" 1 "${rc}"
assert_contains "missing source explains no disk change" "$(cat "${OUT}" "${ERR}")" "no disk was changed"
assert_not_contains "missing source does not partition" "$(cat "${WORK}/calls.log")" "sgdisk"

# Normal scenarios use the baked live-root fixture.
t_section "Combo 1: Btrfs + LUKS, single password, Intel GPU"
build_answers yes yes alice reboot
LIVE_ROOT_SENTINEL="${WORK}"
MOCK_NVIDIA=0
run_flow
assert_common_success
assert_contains "reboot action flushes pending writes" "$(log_text)" "sync"
assert_contains "chosen completion action requests reboot" "$(log_text)" "systemctl reboot"
assert_not_contains "successful systemd reboot needs no fallback" "$(log_text)" $'\nreboot'
assert_contains "LUKS root is p3 type 8309" "$(log_text)" "sgdisk -n 3:0:0 -t 3:8309"
assert_contains "LUKS2 argon2id" "$(log_text)" "cryptsetup luksFormat --type luks2 --pbkdf argon2id --hash sha512 --key-size 512 --batch-mode /dev/sda3"
assert_contains "cryptroot opened" "$(log_text)" "cryptsetup open /dev/sda3 cryptroot"
assert_contains "btrfs on mapper" "$(log_text)" "mkfs.btrfs -f -L ROOT /dev/mapper/cryptroot"
assert_contains "subvol @swap created" "$(log_text)" "btrfs subvolume create ${MNT}/@swap"
assert_contains "swapfile created NOCOW" "$(log_text)" "chattr +C ${MNT}/swap/swapfile"
assert_contains "swapfile mirrors RAM (8192M)" "$(log_text)" "fallocate -l 8192M ${MNT}/swap/swapfile"
assert_file_contains "crypttab: cryptroot by header UUID only" "${MNT}/etc/crypttab" "cryptroot UUID=ROOTPART-FS-UUID-4444 none luks,discard,initramfs"
assert_file_contains "fstab: root subvol=@" "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /            btrfs"
assert_file_contains "fstab: @swap subvolume" "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /swap        btrfs  noatime,subvol=@swap"
assert_file_contains "fstab: swapfile on encrypted root" "${MNT}/etc/fstab" "/swap/swapfile none swap sw 0 0"
assert_file_contains "resume= via swapfile offset" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=ROOTFS-FS-UUID-5555 resume_offset=38400"
assert_file_contains "initramfs RESUME set" "${MNT}/etc/initramfs-tools/conf.d/resume" "RESUME=UUID=ROOTFS-FS-UUID-5555"
assert_file_contains "initramfs keymap carried" "${MNT}/etc/initramfs-tools/initramfs.conf" "KEYMAP=y"
# Regression guard: the CRYPTSETUP=y conf-hook write was removed -- since
# buster that file only carries KEYFILE_PATTERN and the cryptsetup-initramfs
# hook copies the binaries unconditionally. Early unlock is driven by the
# "initramfs" crypttab option (asserted above via fstab), and the generated
# initramfs is checked for the mapping by validate_installed_boot (unit
# tests). The installer must not resurrect the dead knob.
assert_file_not_exists "no dead CRYPTSETUP=y conf-hook written" "${MNT}/etc/cryptsetup-initramfs/conf-hook"
assert_not_contains "no misleading conf-hook log line" "$(log_text)" "CRYPTSETUP=y in conf-hook"
assert_contains "breeze or spinner theme present" "$(log_text)" "plymouth-set-default-theme -R"

t_section "Combo 2: Btrfs + no LUKS, no encryption"
build_answers no
MOCK_NVIDIA=0
run_flow
assert_common_success
assert_not_contains "stay-live completion action does not reboot" "$(log_text)" "systemctl reboot"
assert_contains "stay-live choice is acknowledged" "$(output_text)" "Remaining in the live session"
assert_contains "p3 typed plain 8300" "$(log_text)" "sgdisk -n 3:0:0 -t 3:8300"
assert_not_contains "no cryptsetup without LUKS" "$(log_text)" "luksFormat"
assert_contains "btrfs on raw partition" "$(log_text)" "mkfs.btrfs -f -L ROOT /dev/sda3"
assert_contains "swapfile created without LUKS too" "$(log_text)" "swap/swapfile"
assert_file_contains "crypttab placeholder" "${MNT}/etc/crypttab" "No encrypted volumes configured"
assert_file_contains "fstab: swapfile, not a partition" "${MNT}/etc/fstab" "/swap/swapfile none swap sw 0 0"
assert_file_contains "resume points at the root fs" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=ROOTPART-FS-UUID-4444"

t_section "Combo 3: Btrfs + LUKS, NVIDIA GPU enables modeset for the baked driver"
build_answers yes
MOCK_NVIDIA=1
run_flow
assert_common_success
assert_file_contains "nvidia-drm.modeset=1 on NVIDIA" "${MNT}/etc/default/grub.d/installer.cfg" "nvidia-drm.modeset=1"
assert_not_contains "NVIDIA detection does not install packages online" "$(log_text)" "apt-get install"

t_section "Combo 4: Ext4 + LUKS uses a root swapfile and filefrag resume offset"
build_answers yes yes alice live ext4
MOCK_NVIDIA=0
run_flow
assert_common_success
assert_contains "ext4 on encrypted mapper" "$(log_text)" "mkfs.ext4 -F -L ROOT -O fast_commit /dev/mapper/cryptroot"
assert_contains "ext4 swapfile created at root" "$(log_text)" "fallocate -l 8192M ${MNT}/swapfile"
assert_not_contains "ext4 creates no btrfs subvolumes" "$(log_text)" "btrfs subvolume create"
assert_file_contains "ext4 encrypted root in fstab" "${MNT}/etc/fstab" "UUID=ROOTFS-FS-UUID-5555  /            ext4"
assert_file_contains "ext4 swapfile in fstab" "${MNT}/etc/fstab" "/swapfile none swap sw 0 0"
assert_file_contains "ext4 encrypted resume offset" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=ROOTFS-FS-UUID-5555 resume_offset=38400"

t_section "Combo 5: Ext4 + no LUKS formats the raw root partition"
build_answers no yes alice live ext4
MOCK_NVIDIA=0
run_flow
assert_common_success
assert_contains "ext4 on raw partition" "$(log_text)" "mkfs.ext4 -F -L ROOT -O fast_commit /dev/sda3"
assert_not_contains "plain ext4 uses no cryptsetup" "$(log_text)" "luksFormat"
assert_contains "plain ext4 swapfile created at root" "$(log_text)" "fallocate -l 8192M ${MNT}/swapfile"
assert_file_contains "plain ext4 root in fstab" "${MNT}/etc/fstab" "UUID=ROOTPART-FS-UUID-4444  /            ext4"
assert_file_contains "plain ext4 resume offset" "${MNT}/etc/default/grub.d/installer.cfg" "resume=UUID=ROOTPART-FS-UUID-4444 resume_offset=38400"

t_section "Live-copy deploy path: excludes keep API dirs, mountpoints exist (offline skips apt)"
build_answers no
MOCK_NVIDIA=0
LIVE_ROOT_SENTINEL="${WORK}"
run_flow
unset LIVE_ROOT_SENTINEL
# Offline copy: rsync deploy, no network apt anywhere, single-transaction live purge
assert_rc "offline live-copy install succeeds" 0 "${RC}"
assert_contains "rsync deploy used" "$(log_text)" "rsync -aAX"
assert_not_contains "debootstrap not used on the live path" "$(log_text)" "debootstrap"
assert_not_contains "no apt-get update on the live path" "$(log_text)" "apt-get update"
assert_not_contains "no apt-get install on the live path" "$(log_text)" "apt-get install"
assert_not_contains "no apt-get purge on the live path" "$(log_text)" "apt-get purge"
assert_contains "excludes /dev CONTENTS, keeps the directory" "$(log_text)" "--exclude=/dev/*"
assert_contains "hardware comes from copied closure" "$(output_text)" "hardware support is already in the copied live image"
assert_contains "desktop comes from copied closure" "$(output_text)" "desktop is already in the copied live image"
assert_contains "boot closure is checked without package installation" "$(log_text)" "dpkg-query -W"
# Regression: live-build ships update_initramfs=no in the image; without
# re-enabling it the target keeps the LIVE initramfs (no cryptsetup) and LUKS
# boots to an unlock prompt that cannot succeed.
assert_file_contains "update-initramfs re-enabled on target" "${MNT}/etc/initramfs-tools/update-initramfs.conf" "update_initramfs=yes"
# Runtime state and persistent live markers must not leak into the target.
assert_file_not_exists "live /etc/live/version marker stripped" "${MNT}/etc/live/version"
# A fresh /run prevents the installed root from retaining the USB's runtime
# mount. The live-tools wrapper must still be removed: it sees boot=live via
# /proc and emits the reported "update-initramfs is disabled" message when
# /run/live/medium is absent.
assert_contains "/run mounted as a fresh tmpfs (not a bind of live /run)" "$(log_text)" "mount -t tmpfs tmpfs ${MNT}/run"
assert_file_not_exists "live /run/live marker hidden by /run tmpfs" "${MNT}/run/live/medium"
# Regression: prove update-initramfs actually regenerated the initrd (the mock
# re-touches it; an unmodified mtime means the script silently skipped).
if [ -f "${MNT}/boot/vmlinuz-7.1.0-amd64" ] && [ -f "${MNT}/boot/initrd.img-7.1.0-amd64" ]; then
    kernel_mtime=$(stat -c %Y "${MNT}/boot/vmlinuz-7.1.0-amd64" 2>/dev/null || echo 0)
    initrd_mtime=$(stat -c %Y "${MNT}/boot/initrd.img-7.1.0-amd64" 2>/dev/null || echo 0)
    assert_rc "initrd regenerated (mtime >= kernel)" 1 "$([ "$initrd_mtime" -ge "$kernel_mtime" ] && echo 1 || echo 0)"
fi
assert_contains "update-initramfs was invoked" "$(log_text)" "update-initramfs -u -k all"
# The actual fix: live-tools owns the update-initramfs diversion and
# live-boot-initramfs-tools owns the live hooks. Purge both with the other live
# packages in the same transaction, which also respects live-config's split
# package dependency.
assert_contains "live stack purged in ONE dpkg transaction" "$(log_text)" "dpkg --purge live-boot live-boot-initramfs-tools live-config live-config-systemd live-tools"
assert_file_exists "real update-initramfs restored after live-tools purge" "${MNT}/usr/sbin/update-initramfs"
if [ ! -L "${MNT}/usr/sbin/update-initramfs" ]; then
    t_ok
else
    t_fail "live update-initramfs diversion removed" "still points to $(readlink "${MNT}/usr/sbin/update-initramfs")"
fi

t_section "Abort: live-tools diversion surviving purge is caught before initramfs generation"
build_answers no
MOCK_LEAVE_LIVE_INITRAMFS=1
LIVE_ROOT_SENTINEL="${WORK}"
run_flow
unset LIVE_ROOT_SENTINEL
MOCK_LEAVE_LIVE_INITRAMFS=0
assert_rc "surviving live update-initramfs wrapper aborts install" 1 "${RC}"
assert_contains "failure names the live-tools diversion" "$(output_text)" "live-tools still diverts update-initramfs"
assert_not_contains "diverted update-initramfs is never invoked" "$(log_text)" "update-initramfs -u -k all"

t_section "Completion: failed reboot commands leave a clear manual-reboot message"
build_answers no yes alice reboot
MOCK_SYSTEMCTL_REBOOT_RC=1
MOCK_REBOOT_RC=1
run_flow
MOCK_SYSTEMCTL_REBOOT_RC=0
MOCK_REBOOT_RC=0
assert_rc "failed reboot commands return nonzero" 1 "${RC}"
assert_contains "systemd reboot attempted first" "$(log_text)" "systemctl reboot"
assert_contains "legacy reboot attempted as fallback" "$(log_text)" $'\nreboot'
assert_contains "manual reboot instructions shown" "$(output_text)" "Remove the installation media and reboot manually"
assert_contains "completed install is still reported before reboot failure" "$(output_text)" "Installation finished successfully!"

t_section "Abort: undersized disk refused before partitioning"
prep_target
mock_setup
LIVE_ROOT_SENTINEL="${WORK}"
lsblk() {
    mlog "lsblk $*"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) echo "/dev/sda 10G disk 0" ;;
        *MOUNTPOINTS*) : ;;
        *"-dnbo SIZE"*|*"-bno SIZE"*) echo 10737418240 ;;
    esac
}
printf 'us\nalice\npw1234567\npw1234567\nsensible-box\nEurope/Berlin\nen_US.UTF-8\n\n\ny\n1\n' > "${ANSWERS}"
: > "${OUT}"; : > "${ERR}"
set +e
( set -e; main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" )
rc=$?
set -e
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
unset LIVE_ROOT_SENTINEL
assert_rc "installer exits 1 when no disk is large enough" 1 "${rc}"
assert_contains "no-candidates error surfaced" "$(output_text)" "No disk qualified as an installation target"
assert_contains "error names the rejected disk" "$(output_text)" "/dev/sda"
assert_not_contains "no partitioning happened" "$(log_text)" "sgdisk"
lsblk() {
    mlog "lsblk $*"
    case "$*" in
        *"NAME,SIZE,TYPE,RO"*) echo "/dev/sda 500G disk 0" ;;
        *MOUNTPOINTS*) : ;;
        *"-dnbo SIZE"*|*"-bno SIZE"*) echo 536870912000 ;;
        *"-dno MAJ:MIN"*) echo "8:0" ;;
        *"-dno TYPE"*) echo "disk" ;;
        *"-dno RO"*) echo "0" ;;
        *"-dno SERIAL"*) echo "TEST-SERIAL-001" ;;
        *"-dno WWN"*) echo "TEST-WWN-001" ;;
        *"-dno MODEL"*) echo "TestDisk" ;;
    esac
}

t_section "Abort: declining the final destructive confirmation changes nothing"
build_answers yes no
prep_target
mock_setup
LIVE_ROOT_SENTINEL="${WORK}"
set +e
( set -e; main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" )
rc=$?
set -e
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
unset LIVE_ROOT_SENTINEL
assert_rc "installer aborts when final confirmation is declined" 1 "${rc}"
assert_not_contains "no partitioning after decline" "$(log_text)" "sgdisk"

t_section "Password confirm mismatch re-prompts, then succeeds"
prep_target
mock_setup
LIVE_ROOT_SENTINEL="${WORK}"
{
    printf 'us\n'                       # keyboard
    printf 'alice\n'                    # username
    printf 'pw1234567\n'                # password 1
    printf 'wrongpass\n'                # mismatch
    printf 'pw1234567\npw1234567\n'     # retry success
    printf 'sensible-box\n'
    printf 'Europe/Berlin\n'
    printf 'en_US.UTF-8\n'
    printf '\n'                         # full name
    printf '\n'                         # email
    printf 'y\n'                        # summary confirm
    printf '1\n'                        # disk
    printf '1\n'                        # btrfs filesystem
    printf 'y\n'                        # encryption yes
    printf 'y\n'                        # autologin
    printf 'y\n'                        # final destructive confirmation
    printf '2\n'                        # remain in live session
} > "${ANSWERS}"
: > "${OUT}"; : > "${ERR}"
set +e
( set -e; main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" )
rc=$?
set -e
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
unset LIVE_ROOT_SENTINEL
assert_rc "install succeeds after password re-prompt" 0 "${rc}"
assert_contains "user 'alice' created" "$(log_text)" "useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth alice"

t_section "Username re-prompt: invalid input rejected, valid accepted"
prep_target
mock_setup
LIVE_ROOT_SENTINEL="${WORK}"
{
    printf 'us\n'
    printf 'Bad Name\n'                 # username #1: invalid (space)
    printf 'alice\n'                    # username #2: valid
    printf 'pw1234567\npw1234567\n'
    printf 'sensible-box\n'
    printf 'Europe/Berlin\n'
    printf 'en_US.UTF-8\n'
    printf '\n'
    printf '\n'
    printf 'y\n'
    printf '1\n'
    printf '1\n'                        # btrfs filesystem
    printf 'n\n'                        # no encryption
    printf 'y\n'                        # final destructive confirmation
    printf '2\n'                        # remain in live session
} > "${ANSWERS}"
: > "${OUT}"; : > "${ERR}"
set +e
( set -e; main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" )
rc=$?
set -e
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
unset LIVE_ROOT_SENTINEL
assert_rc "install succeeds after username re-prompt" 0 "${rc}"
assert_contains "user 'alice' created (not 'Bad Name')" "$(log_text)" "useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth alice"

t_section "Post-wipe mandatory failure: no false success, log preserved"
build_answers no
MOCK_MISSING_PACKAGE="shim-signed"
run_flow
MOCK_MISSING_PACKAGE=""
assert_ne "mandatory post-wipe failure returns nonzero" 0 "${RC}"
assert_not_contains "failure never prints success" "$(output_text)" "Installation finished successfully!"
assert_file_exists "failure log copied into partial target" "${MNT}/var/log/sensible-install.log"
assert_file_contains "failure log identifies the missing boot package" "${MNT}/var/log/sensible-install.log" "shim-signed"
assert_contains "failure cleanup unmounts owned target" "$(log_text)" "umount ${MNT}"

t_section "Abort: LUKS with closure missing cryptsetup-initramfs fails loudly"
build_answers yes
prep_target
mock_setup
MOCK_LIVE_USER=0
# Simulate an ISO built WITHOUT cryptsetup-initramfs in the closure: rsync
# copies everything except its dpkg info files.
rsync() {
    mlog "rsync $*"
    mkdir -p "${MNT}/etc/profile.d" "${MNT}/usr/local/bin" "${MNT}/opt/sensible" "${MNT}/boot" "${MNT}/etc/initramfs-tools" "${MNT}/var/lib/dpkg/info"
    touch "${MNT}/boot/vmlinuz-7.1.0-amd64" "${MNT}/boot/initrd.img-7.1.0-amd64"
    printf 'update_initramfs=no\n' > "${MNT}/etc/initramfs-tools/update-initramfs.conf"
    # NOTE: no cryptsetup-initramfs.* files in var/lib/dpkg/info
}
LIVE_ROOT_SENTINEL="${WORK}"
: > "${OUT}"; : > "${ERR}"
set +e
( set -e; main < "${ANSWERS}" > "${OUT}" 2> "${ERR}" )
rc=$?
set -e
cp "${MOCK_LOG}" "${WORK}/calls.log"; mock_teardown
unset LIVE_ROOT_SENTINEL
MOCK_LIVE_USER=1
assert_rc "install aborts when cryptsetup-initramfs is missing from closure" 1 "${rc}"
assert_contains "error names the missing package and the fix" "$(output_text)" "cryptsetup-initramfs is not installed in the target closure"
# Restore the full-closure rsync mock for any later sections
rsync() {
    mlog "rsync $*"
    mkdir -p "${MNT}/etc/profile.d" "${MNT}/usr/local/bin" "${MNT}/opt/sensible" "${MNT}/boot" "${MNT}/etc/initramfs-tools" "${MNT}/run/live" "${MNT}/etc/live" "${MNT}/var/lib/dpkg/info"
    touch "${MNT}/etc/profile.d/99-sensible-autostart.sh" \
          "${MNT}/etc/profile.d/99-sensible-firmware-check.sh" \
          "${MNT}/usr/local/bin/sensible-install" "${MNT}/usr/local/bin/lazydeb"
    touch "${MNT}/boot/vmlinuz-7.1.0-amd64" "${MNT}/boot/initrd.img-7.1.0-amd64"
    printf 'update_initramfs=no\n' > "${MNT}/etc/initramfs-tools/update-initramfs.conf"
    touch -d '2025-01-01' "${MNT}/boot/vmlinuz-7.1.0-amd64" "${MNT}/boot/initrd.img-7.1.0-amd64"
    mkdir -p "${MNT}/run/live/medium"
    touch "${MNT}/etc/live/version"
    touch "${MNT}/var/lib/dpkg/info/cryptsetup-initramfs.list" \
          "${MNT}/var/lib/dpkg/info/cryptsetup-initramfs.md5sums"
}

rm -rf "${WORK}"
trap - EXIT
t_summary
