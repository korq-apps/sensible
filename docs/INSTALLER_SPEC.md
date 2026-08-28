# Installer specification

Blueprint for `installer/sensible-install.sh`. On the live ISO the command is `sensible-install` (alias `lazydeb`). Behavior must match [Architecture](ARCHITECTURE.md). This file is the command-level source of truth.

---

## 1. Constraints

- **UEFI only.** Exit if `/sys/firmware/efi` is missing.
- **One disk, full wipe.** No dual-boot, no custom partition editor in v1.
- **Minimum disk:** `2048 + SWAP_MIB + 20480` MiB (1 GiB EFI + 1 GiB BOOT + swap + 20 GiB root). Refuse smaller disks.
- Live image already has `cryptsetup`, `btrfs-progs`, `e2fsprogs`, `dosfstools`, `gdisk`, NetworkManager, firmware, and either a squashfs or `debootstrap`.
- Unlock is **`/etc/crypttab` + `cryptsetup-initramfs`**. Do not set `cryptdevice=` or `GRUB_ENABLE_CRYPTODISK`.

---

## 2. Flow

```
Pre-flight (UEFI, disks, RAM, size check)
    → Prompts
    → Type-the-disk-name confirmation
    → Partition, format, mount
    → Deploy base (squashfs rsync, or debootstrap)
    → Chroot: packages, user, fstab/crypttab, Plymouth, GRUB, keyd
    → Unmount, close mappings, “remove USB and reboot”
```

The target mount point is `${MNT:-/mnt}`; the variable exists so the test
suite (`tests/`) can run the full flow unprivileged against a temp directory.

---

## 3. Prompts

| Field | Default | Notes |
| :--- | :--- | :--- |
| Target disk | none | `lsblk -dpno NAME,SIZE,MODEL`; skip the live USB if known |
| Filesystem | Btrfs | Btrfs or Ext4 |
| LUKS2 | Yes | If yes: passphrase twice, min 8 characters |
| Swap | RAM + 10% | Shown, not editable in v1 |
| Desktop | GNOME | GNOME or KDE Plasma |
| Mac clipboard (`keyd`) | On for GNOME, off for KDE | Super+C/V/X only |
| Extra browsers | none | Chromium; Brave (official apt origin) |
| Extra media | none | Audacious; Amberol (GNOME) or Elisa (KDE) |
| Hostname | `debian` | RFC 1123. Stay `debian` — the box is Debian, not a derivative. |
| Username | none | `^[a-z_][a-z0-9_-]*$` |
| User password | none | Twice; root password set to the same value for recovery |
| Timezone | `timedatectl` or `UTC` | zoneinfo |
| Locale | `en_US.UTF-8` | Must be in `/usr/share/i18n/SUPPORTED` |
| Keyboard | live console layout | written through `keyboard-configuration` |
| Skip login password (autologin) | On (only offered with LUKS) | GDM/SDDM autologin; the LUKS passphrase stays the single authentication and the idle screen lock is always enforced |

Firefox, VLC, Neovim, Flatpak, firmware, and the CLI set are always installed — not checkboxes.

---

## 4. Partitioning

```bash
RAM_MIB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MIB=$((RAM_MIB + RAM_MIB / 10))

sgdisk --zap-all "$DISK"
wipefs --all --force "$DISK"

# p1 (EFI, 1 GiB, ef00) and p2 (BOOT, 1 GiB, 8300) always:
sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
sgdisk -n 2:0:+1024M -t 2:8300 -c 2:"Linux Boot" "$DISK"

if [ "$ENABLE_LUKS" = true ]; then
  # No swap partition: swap is a swapfile inside the encrypted root.
  sgdisk -n 3:0:0 -t 3:8309 -c 3:"Linux LUKS" "$DISK"
else
  sgdisk -n 3:0:+"${SWAP_MIB}"M -t 3:8200 -c 3:"Linux Swap" "$DISK"
  sgdisk -n 4:0:0 -t 4:8300 -c 4:"Linux Root" "$DISK"
fi

partprobe "$DISK"
```

Names: `${DISK}pN` on nvme/mmcblk, `${DISK}N` on sd/vd.

---

## 5. Format and mount

```bash
mkfs.vfat -F32 -n EFI "$EFI_PART"
mkfs.ext4 -F -L BOOT "$BOOT_PART"

if [ "$ENABLE_LUKS" = true ]; then
  echo -n "$PASSPHRASE" | cryptsetup luksFormat \
    --type luks2 --pbkdf argon2id --hash sha512 --key-size 512 --batch-mode \
    "$ROOT_PART"
  echo -n "$PASSPHRASE" | cryptsetup open "$ROOT_PART" cryptroot
  TARGET_ROOT=/dev/mapper/cryptroot
  # Swap is a swapfile on the encrypted root: encrypted at rest and resumable.
  create_swapfile "$FS_TYPE" "$SWAP_MIB"   # see §5.1
else
  TARGET_ROOT=$ROOT_PART
  mkswap -L SWAP "$SWAP_PART"
fi
```

### 5.1 Swapfile (LUKS only) and `resume_offset`

Btrfs: dedicated `@swap` subvolume mounted at `/swap` (no compression, never
snapshotted). Ext4: `/swapfile` at the root.

```bash
# Btrfs
touch /mnt/swap/swapfile && chattr +C /mnt/swap/swapfile
fallocate -l "${SWAP_MIB}M" /mnt/swap/swapfile
# Ext4
fallocate -l "${SWAP_MIB}M" /mnt/swapfile

chmod 600 "$SWAPFILE"; mkswap "$SWAPFILE"

# resume_offset (4K pages):
#   Btrfs: btrfs inspect-internal map-swapfile -r "$SWAPFILE"
#   Ext4:  filefrag -v "$SWAPFILE" | first extent physical start
```

### Btrfs

```bash
mkfs.btrfs -f -L ROOT "$TARGET_ROOT"
mount "$TARGET_ROOT" /mnt
for vol in @ @home @snapshots @var_log @swap; do
  btrfs subvolume create "/mnt/$vol"
done
umount /mnt

BTRFS_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async"
mount -o "${BTRFS_OPTS},subvol=@" "$TARGET_ROOT" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,boot,swap}
mount -o "${BTRFS_OPTS},subvol=@home" "$TARGET_ROOT" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$TARGET_ROOT" /mnt/.snapshots
mount -o "${BTRFS_OPTS},subvol=@var_log" "$TARGET_ROOT" /mnt/var/log
mount -o "noatime,subvol=@swap" "$TARGET_ROOT" /mnt/swap
mount "$BOOT_PART" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
```

### Ext4

```bash
mkfs.ext4 -F -L ROOT -O fast_commit "$TARGET_ROOT"
mount "$TARGET_ROOT" /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
```

---

## 6. Deploy base

Prefer copying the live root (fast, offline):

```bash
rsync -aAX --info=progress2 \
  --exclude=/dev --exclude=/proc --exclude=/sys --exclude=/tmp \
  --exclude=/run --exclude=/mnt --exclude=/media --exclude=/lost+found \
  / /mnt/
```

If the live image is a thin installer (no desktop squash), `debootstrap --arch=amd64 testing /mnt https://deb.debian.org/debian` instead, then `sources.list` with `main contrib non-free non-free-firmware`.

Bind-mount before any chroot:

```bash
for d in /dev /dev/pts /proc /sys /run; do
  mount --bind "$d" "/mnt$d"
done
cp /etc/resolv.conf /mnt/etc/resolv.conf
```

---

## 7. `crypttab` and `fstab`

Always use **filesystem UUIDs** in fstab, not `/dev/mapper/...`. `ROOT_FS_UUID` is `blkid` of `$TARGET_ROOT` (the Ext4/Btrfs). `ROOT_PART_UUID` is `blkid` of the LUKS **partition**.

### crypttab

```bash
# LUKS on: persistent root only — swap is a swapfile inside the container
# cryptroot UUID=<ROOT_PART_UUID> none luks,discard

# LUKS off: empty crypttab
```

All blkid-derived identifiers must be non-empty: abort the install rather than write a broken fstab/crypttab.

### fstab templates

Btrfs + LUKS (swapfile on the encrypted `@swap` subvolume):

```
UUID=<ROOT_FS_UUID>  /            btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@          0 0
UUID=<ROOT_FS_UUID>  /home        btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@home      0 0
UUID=<ROOT_FS_UUID>  /.snapshots  btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@snapshots 0 0
UUID=<ROOT_FS_UUID>  /var/log     btrfs  noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@var_log   0 0
UUID=<ROOT_FS_UUID>  /swap        btrfs  noatime,subvol=@swap                                                   0 0
UUID=<BOOT_UUID>     /boot        ext4   noatime                                                               0 2
UUID=<EFI_UUID>      /boot/efi    vfat   umask=0077                                                            0 2
/swap/swapfile       none         swap   sw                                                                    0 0
tmpfs                /tmp         tmpfs  defaults,nosuid,nodev                                                 0 0
```

Ext4 + LUKS: one `/` line (`ext4  noatime,errors=remount-ro,discard  0 1`), same boot/efi/tmpfs, swap line is `/swapfile none swap sw 0 0`.

No LUKS, either filesystem: swap line is `UUID=<SWAP_UUID> none swap sw 0 0` and there is no `@swap`/swapfile line.

---

## 8. Identity, locale, user

```bash
echo "$HOSTNAME" > /mnt/etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$HOSTNAME" > /mnt/etc/hosts

chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$LOCALE UTF-8" > /mnt/etc/locale.gen   # or uncomment in locale.gen
chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/default/locale

# Ensure supplemental groups exist: a debootstrap base (and the live image,
# without bluez) lacks bluetooth/netdev, and one missing group makes
# useradd fail wholesale — which would leave no user for chpasswd.
for grp in sudo audio video plugdev netdev bluetooth; do
  chroot /mnt groupadd -f "$grp"
done
chroot /mnt useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth "$USERNAME"
# sudo group membership is mandatory: verify it, never install an admin-less system.
chroot /mnt id -nG "$USERNAME" | grep -qw sudo
echo "$USERNAME:$USERPASS" | chroot /mnt chpasswd
echo "root:$USERPASS" | chroot /mnt chpasswd
```

Keyboard: take the live console layout (`/etc/default/keyboard`, `XKBLAYOUT`) and write it through `keyboard-configuration` after packages are installed:

```bash
printf 'keyboard-configuration keyboard-configuration/layoutcode select %s\n' "$KBLAYOUT" \
  | chroot /mnt debconf-set-selections
DEBIAN_FRONTEND=noninteractive chroot /mnt dpkg-reconfigure -f noninteractive keyboard-configuration
# and write /mnt/etc/default/keyboard with XKBLAYOUT="$KBLAYOUT"
```

---

## 9. Packages in chroot

Order: apt sources → `apt-get update` → firmware/kernel → DE → defaults → optionals.

```text
Always:
  linux-image-amd64 intel-microcode amd64-microcode
  locales keyboard-configuration console-setup
  firmware-linux firmware-misc-nonfree firmware-iwlwifi firmware-realtek
  firmware-atheros firmware-brcm80211 firmware-mediatek firmware-sof-signed
  cryptsetup cryptsetup-initramfs
  plymouth plymouth-themes
  grub-efi-amd64 grub-efi-amd64-signed shim-signed
  network-manager pipewire wireplumber pipewire-pulse pipewire-audio
  libspa-0.2-bluetooth bluez
  power-profiles-daemon fwupd
  flatpak
  firefox vlc neovim
  ripgrep fd-find fzf bat eza zoxide btop fastfetch jq
  fonts-noto-core fonts-noto-color-emoji fonts-liberation

If GNOME:
  gnome-core gdm3 gnome-software gnome-software-plugin-flatpak dconf-cli
  plymouth theme: spinner

If KDE:
  kde-plasma-desktop sddm plasma-discover plasma-discover-backend-flatpak
  plymouth theme: breeze (package plymouth-theme-breeze if needed)

If NVIDIA GPU:
  nvidia-driver

If keyd:
  keyd  (package, or a pinned .deb — no live git build in the installer)

If Brave:
  official apt origin + brave-browser

If Chromium / Audacious / Amberol / Elisa:
  distro packages
```

```bash
chroot /mnt flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

mkdir -p /mnt/etc/skel/.config/nvim
git clone --depth 1 https://github.com/LazyVim/starter /mnt/etc/skel/.config/nvim
rm -rf /mnt/etc/skel/.config/nvim/.git
# also copy onto the created user if /etc/skel was applied before this step
```

Enable: `NetworkManager`, `bluetooth`, `power-profiles-daemon`, `fwupd`, `gdm3` or `sddm`, and `keyd` when selected.

---

## 10. Plymouth and GRUB

```bash
if [ "$DESKTOP_ENV" = gnome ]; then
  chroot /mnt plymouth-set-default-theme -R spinner
else
  chroot /mnt plymouth-set-default-theme -R breeze
fi
```

`/etc/default/grub.d/installer.cfg`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
```

Append the hibernation parameters to `GRUB_CMDLINE_LINUX_DEFAULT` and write `RESUME=` for the initramfs:

```bash
# LUKS on:  resume=UUID=<ROOT_FS_UUID> resume_offset=<RESUME_OFFSET>
# LUKS off: resume=UUID=<SWAP_UUID>
echo "RESUME=UUID=<...>" > /mnt/etc/initramfs-tools/conf.d/resume
```

Secure Boot: `grub-install` picks up the signed image from `grub-efi-amd64-signed` and installs `shimx64.efi` alongside `grubx64.efi` on the ESP (`shim-signed`). This works with Secure Boot on and off — no prompt, no conditional.

```bash
# bootloader-id stays debian: firmware boot menu should say Debian.
chroot /mnt grub-install --target=x86_64-efi \
  --efi-directory=/boot/efi --bootloader-id=debian --recheck
chroot /mnt update-initramfs -u -k all
chroot /mnt update-grub
```

---

## 11. keyd (when enabled)

Install `configs/keyd-default.conf` — do not generate a second mapping in the script.

```
[ids]
*

[meta]
c = C-insert
v = S-insert
x = C-x
```

`systemctl enable keyd`. No Super+A / Super+Z (see Architecture).

---

## 12. Session login and screen lock

With LUKS enabled the installer offers autologin (default **on**): the boot
passphrase authenticates once, the desktop starts without a login prompt, and
the password remains set for sudo, screen unlock, and the keyring. Without
LUKS the prompt is never shown.

Screen lock defaults are written for both desktops regardless of the choice:

- GNOME: system dconf defaults — `idle-delay=300`, `lock-enabled=true`,
  `lock-delay=0` (`/etc/dconf/profile/user` + `/etc/dconf/db/local.d/`), then
  `dconf update` (hence `dconf-cli` in the GNOME package set).
- KDE: `/etc/xdg/kscreenlockerrc` — `Autolock=true`, `Timeout=5`,
  `LockOnResume=true` (covers resume from suspend).

```bash
# GNOME (gdm3), /etc/gdm3/daemon.conf:
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=<username>

# KDE (sddm), /etc/sddm.conf.d/autologin.conf:
[Autologin]
User=<username>
```

Caveats (by design): logout immediately logs back in, and gnome-keyring is not
unlocked by autologin (first use prompts once).

---

## 13. Teardown

```bash
umount -R /mnt
[ "$ENABLE_LUKS" = true ] && cryptsetup close cryptroot
# cryptswap is not opened during install
```
