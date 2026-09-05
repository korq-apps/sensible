# Installer specification

Blueprint for `installer/sensible-install.sh`. On the live ISO the command is `sensible-install` (alias `lazydeb`). Behavior must match [Architecture](ARCHITECTURE.md). This file is the command-level source of truth.

---

## 1. Constraints

- **UEFI only.** Exit if `/sys/firmware/efi` is missing.
- **One disk, full wipe.** No dual-boot, no custom partition editor in v1.
- **Minimum disk:** `2048 + SWAP_MIB + 20480` MiB (1 GiB EFI + 1 GiB BOOT + swap + 20 GiB root). Refuse smaller disks.
- The live image contains the complete target system plus `cryptsetup`, `btrfs-progs`, `e2fsprogs`, `dosfstools`, `gdisk`, NetworkManager, and firmware. There is no thin/debootstrap fallback.
- **Offline installation.** The release image contains the complete target closure. NetworkManager remains available for diagnostics, but no mirror check or download is required before the wipe.
- Exclude disks with mounted descendants, active swap, or holders. Capture major:minor, byte size, serial and WWN where available, then re-read all identity/state immediately before partitioning.
- Unlock is **`/etc/crypttab` + `cryptsetup-initramfs`**. Do not set `cryptdevice=` or `GRUB_ENABLE_CRYPTODISK`.

---

## 2. Flow

```
Pre-flight (UEFI, unused target mountpoint)
    → Branded welcome; select and apply live keyboard
    → Disks, RAM, size/state check; remaining regional settings
    → Remaining prompts (--config answers file: planned — Phase 6)
    → Explicit destructive confirmation (no device-path retyping)
    → Recheck selected disk identity/state
    → Partition, format, mount
    → Deploy the live root with rsync and remove live-only state
    → Chroot: fstab/crypttab, identity + user, locale-gen,
      keyboard, desktop/login configuration, GRUB + initramfs
    → Unmount, close mappings, “remove USB and reboot”
```

The target mount point is `${MNT:-/mnt}`; the variable exists so the test
suite (`tests/`) can run the full flow unprivileged against a temp directory.

---

## 3. Prompts

| Field | Default | Notes |
| :--- | :--- | :--- |
| Target disk | none | Show path/size/model; record major:minor, byte size, serial and WWN; exclude every in-use disk and revalidate before wipe |
| Filesystem | Btrfs | Choose Btrfs (subvolumes/compression) or Ext4 (traditional single root) |
| LUKS2 | Yes | If yes: passphrase twice, min 8 characters |
| Swap | Swapfile inside root, mirroring RAM | Shown, not editable in v1 |
| Desktop | Build variant | GNOME or KDE Plasma release image; shown, not prompted |
| Mac clipboard (`keyd`) | On for GNOME, off for KDE | Fixed by build variant; Super+C/V/X only |
| Hostname | `debian` | RFC 1123 syntax and maximum 63 bytes for the Linux static hostname. Stay `debian` — the box is Debian, not a derivative. |
| Username | none | `^[a-z_][a-z0-9_-]*$`, maximum 32 characters, and not an existing or known package-owned account; recheck after target packages before `useradd` |
| User password | none | Twice; root password set to the same value for recovery |
| Timezone | `timedatectl` or `UTC` | zoneinfo |
| Locale | `en_US.UTF-8` | Must be in `/usr/share/i18n/SUPPORTED` |
| Keyboard | live console layout | Validate and apply to the live console before either password; write the same layout through target `keyboard-configuration` |
| Skip login password (autologin) | On (only offered with LUKS) | GDM/SDDM autologin; the LUKS passphrase stays the single authentication and the idle screen lock is always enforced |
| Full name | empty | Optional GECOS + git `user.name` |
| Email | empty | Optional git `user.email`, written only to the user's `~/.gitconfig` |

Firefox ESR, Chromium, LibreOffice Writer/Calc/Impress, Thunderbird, KeePassXC,
VLC, Neovim, Flatpak, firmware, archive support, the CLI set, and the
variant-native utilities are always installed — not checkboxes.

**Planned prompts (Phase 6, not implemented):**

| Field | Default | Notes |
| :--- | :--- | :--- |
| BioPass face login | Off | Pinned `.deb` + SHA256; IR camera recommended. Fingerprint (`fprintd`) is not a prompt — always installed |
| Developer tools | Off | `docker.io` + `docker-compose`, `lazygit`, `gh`; user **not** added to the docker group |

### Unattended mode (planned — Phase 6)

`sensible-install --config answers.toml` reads every prompt from a file and asks nothing. Same validation as interactive mode; any missing or invalid key aborts **before** partitioning. `confirm_wipe = true` is still required as explicit destructive authorization, without making interactive users retype a device they selected and confirmed. Primary consumer is CI: running LUKS on/off for each desktop release image end-to-end in QEMU.

```toml
disk            = "/dev/vda"
confirm_wipe    = true               # required explicit authorization
filesystem      = "btrfs"            # btrfs or ext4
luks            = true
luks_passphrase = "correct-horse"
autologin       = true              # only honored when luks = true
biopass         = false
hostname        = "debian"
username        = "user"
full_name       = ""                # optional: GECOS + git user.name
email           = ""                # optional: git user.email
user_password   = "hunter2hunter2"
dev_tools       = false
timezone        = "UTC"
locale          = "en_US.UTF-8"
keyboard        = "us"
```

---

## 4. Partitioning

```bash
RAM_MIB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MIB=$RAM_MIB

sgdisk --zap-all "$DISK"
wipefs --all --force "$DISK"

# p1 (EFI, 1 GiB, ef00) and p2 (BOOT, 1 GiB, 8300) always:
sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
sgdisk -n 2:0:+1024M -t 2:8300 -c 2:"Linux Boot" "$DISK"

# p3 is the root in both modes; swap is always a swapfile inside it, so only
# the partition type differs.
if [ "$ENABLE_LUKS" = true ]; then
  sgdisk -n 3:0:0 -t 3:8309 -c 3:"Linux LUKS" "$DISK"
else
  sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux Root" "$DISK"
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
  # printf, not `echo -n`: bash's echo consumes option-shaped arguments, so a
  # passphrase such as "-nnnnnnn" would reach cryptsetup as an empty key.
  printf '%s' "$PASSPHRASE" | cryptsetup luksFormat \
    --type luks2 --pbkdf argon2id --hash sha512 --key-size 512 --batch-mode \
    "$ROOT_PART"
  printf '%s' "$PASSPHRASE" | cryptsetup open "$ROOT_PART" cryptroot
  TARGET_ROOT=/dev/mapper/cryptroot
else
  TARGET_ROOT=$ROOT_PART
fi

# Swap is a swapfile inside root in both modes; LUKS encrypts it with root.
# It must be created only AFTER format_and_mount has made the root filesystem
# and mounted it (Btrfs: the @swap subvolume at /swap), otherwise the file is
# allocated on the installer's own /mnt instead of inside the target.
create_swapfile "$FS_TYPE" "$SWAP_MIB"   # after mounting root; see §5.1
```

### 5.1 Swapfile (both encryption modes) and `resume_offset`

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

Copy the live root unconditionally. The selected desktop and complete package
closure are already present, and the install path performs no archive or
third-party downloads. Exclude the **contents** of the API
filesystems (`/dev/*`), never the directories themselves (`/dev`): a
whole-directory exclude leaves the target without the mountpoints the bind
mounts below require, and the install aborts.

```bash
rsync -aAX --info=progress2 \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/tmp/*' \
  --exclude='/run/*' --exclude='/mnt/*' --exclude='/media/*' --exclude=/lost+found \
  / /mnt/
```

Whatever the deploy path produced, ensure the skeleton exists:

```bash
mkdir -p /mnt/{dev,proc,sys,run,tmp,mnt,media}
chmod 1777 /mnt/tmp
```

After a live-root copy, remove the live installer profile scripts, command
wrappers, staged `/opt/sensible` source/docs, live issue/MOTD branding, root
autologin units, and live-only package/state trees. Reset `machine-id`. Purge
`live-boot`, `live-config`, and `live-config-systemd` before rebuilding the
target initramfs.

Bind the API filesystems before any chroot, but mount a fresh tmpfs at target
`/run` so live runtime state cannot leak into initramfs generation:

```bash
for d in /dev /dev/pts /proc /sys; do
  mount --bind "$d" "/mnt$d"
done
mount -t tmpfs tmpfs /mnt/run
```

---

## 7. `crypttab` and `fstab`

Always use **filesystem UUIDs** in fstab, not `/dev/mapper/...`. `ROOT_FS_UUID` is `blkid` of `$TARGET_ROOT` (the Ext4/Btrfs). `ROOT_PART_UUID` is `blkid` of the LUKS **partition**.

### crypttab

```bash
# LUKS on: persistent root only — swap is a swapfile inside the container
# cryptroot UUID=<ROOT_PART_UUID> none luks,discard,initramfs

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

No LUKS, either filesystem: the swap line is identical to the encrypted case —
`/swapfile` on Ext4, `/swap/swapfile` on Btrfs — because swap is a file inside
the root filesystem in both modes. There is no swap partition and no
`UUID=<SWAP_UUID>` entry. On Btrfs the `@swap` subvolume is created and mounted
at `/swap` either way; encryption changes only whether the filesystem holding
it is encrypted.

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

Keyboard is selected, validated against installed XKB symbols, and applied with
`setupcon --force --keyboard-only` before collecting LUKS or account passwords.
After target packages are installed, write that same layout through
`keyboard-configuration`. Install desktop packages before creating the human
user so package-owned accounts such as `sddm` already exist and cannot collide:

```bash
printf 'keyboard-configuration keyboard-configuration/layoutcode select %s\n' "$KBLAYOUT" \
  | chroot /mnt debconf-set-selections
DEBIAN_FRONTEND=noninteractive chroot /mnt dpkg-reconfigure -f noninteractive keyboard-configuration
# and write /mnt/etc/default/keyboard with XKBLAYOUT="$KBLAYOUT"
```

---

## 9. Packages in chroot

These packages are resolved and installed while building the variant ISO, not
after the target disk is wiped:

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
  firefox-esr chromium vlc neovim
  libreoffice-writer libreoffice-calc libreoffice-impress
  thunderbird keepassxc
  7zip unzip zip
  ripgrep fd-find fzf bat eza zoxide btop fastfetch jq
  fonts-noto-core fonts-noto-color-emoji fonts-liberation

If GNOME:
  gnome-core gdm3 gnome-software gnome-software-plugin-flatpak dconf-cli
  file-roller amberol simple-scan
  plymouth theme: spinner

If KDE:
  kde-plasma-desktop sddm plasma-discover plasma-discover-backend-flatpak
  okular ark gwenview kate kcalc kde-spectacle elisa skanlite
  plymouth theme: breeze (package plymouth-theme-breeze if needed)

Always in the closure:
  nvidia-driver  (hardware detection only enables nvidia-drm.modeset=1)

GNOME variant:
  keyd + configs/keyd-default.conf
```

Enable: `NetworkManager`, `bluetooth`, `power-profiles-daemon`, `fwupd`, `gdm3` or `sddm`, and `keyd` when selected.

### Phase 6 additions — baked at build time (implemented)

Under the offline model the Phase 6 "bake into the ISO" items no longer run in
the installer at all: they are part of the image the installer copies. The
package names live in the live-build lists, which `scripts/check-packages.sh`
validates against Testing before every build:

```text
Always (baked into the target closure):
  fprintd libpam-fprintd          # dormant without a reader
  cups ipp-usb sane-airscan
  ufw
  printer-driver-all (already in the variant lists)

GNOME adds:  simple-scan
KDE adds:    skanlite
```

Shell/font/git content is staged into `includes.chroot` when the ISO is built
by `scripts/fetch-pins.sh`; pins and SHA256s live in `live/pins.env`, and a
checksum mismatch fails the build. Because `/etc/skel` is populated in the
image, the installer's `useradd -m` inherits everything — the "populate skel
before user creation" ordering problem the network design had does not exist:

```bash
# scripts/fetch-pins.sh, at build time:
#   oh-my-bash tarball (pinned commit, SHA256-verified) → /usr/share/oh-my-bash
#   configs/omb-bashrc                                 → /etc/skel/.bashrc
#   LazyVim starter tarball (pinned commit + SHA256)    → /etc/skel/.config/nvim
#   JetBrainsMono Nerd Font (pinned release, SHA256)   → /usr/local/share/fonts/jetbrains-mono-nerd
#   configs/gitconfig                                  → /etc/gitconfig
#   configs/keyd-default.conf (GNOME only)              → /etc/keyd/default.conf
# Root keeps the stock Debian bashrc. Identity stays per-user (~/.gitconfig).
```

Firewall (ufw) is configured by `live/config/hooks/live/0300-ufw.hook.chroot`
at build time. Defaults in `/etc/default/ufw` are already deny incoming /
allow outgoing. Never run `ufw enable` in the chroot — it would touch the live
kernel's netfilter. The hook adds allow rules while ufw is still marked
disabled (they are only written to `/etc/ufw/user.rules`), then flips
`ENABLED=yes` in `/etc/ufw/ufw.conf` and enables `ufw.service`:

```bash
# 0300-ufw.hook.chroot (reads /etc/sensible/variant, staged by build.sh)
case "$(cat /etc/sensible/variant)" in
gnome|kde)
  ufw allow 1714:1764/tcp   # GSConnect / KDE Connect
  ufw allow 1714:1764/udp
  ufw allow 53317/tcp       # LocalSend transfer
  ufw allow 53317/udp       # LocalSend discovery
  ;;
esac
sed -i 's/^ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw
```

With Debian's default IPv6-enabled UFW configuration, the hook writes matching
IPv4 and IPv6 rules. The exceptions apply across interfaces and source addresses,
not only trusted networks; the offline manual warns users about that exposure.

### Planned — post-install tool (`sensible-apps`)

These stay optional or third-party/online and move out of the installer entirely:

```text
Brave:            official apt origin + brave-browser (never from Debian)
Audacious:        optional alternative media player from Debian
Flathub:          configure the third-party remote after first boot
Developer tools:  docker.io docker-compose lazygit gh; systemctl enable docker;
                  the user is NOT added to the docker group (root-equivalent)
BioPass:          pinned biopass_<ver>_amd64.deb from GitHub releases, SHA256
                  verified; PAM wiring via the package's pam-auth-update
                  profile; enrollment happens post-install in the BioPass app
```

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

If NVIDIA was detected, append `nvidia-drm.modeset=1` to `GRUB_CMDLINE_LINUX_DEFAULT` — without KMS the display managers silently fall back to X11.

If LUKS is on, carry the console keymap into the initramfs so the Plymouth passphrase dialog uses the layout the user chose (a non-US user must not be locked out of a passphrase they typed correctly):

```bash
sed -i 's/^KEYMAP=.*/KEYMAP=y/' /mnt/etc/initramfs-tools/initramfs.conf   # append if absent
```

Append the hibernation parameters to `GRUB_CMDLINE_LINUX_DEFAULT` and write `RESUME=` for the initramfs:

```bash
# Both modes: resume=UUID=<ROOT_FS_UUID> resume_offset=<RESUME_OFFSET>
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
# Session= is required by SDDM — with only User= autologin never engages.
# "plasma" = /usr/share/wayland-sessions/plasma.desktop.
[Autologin]
User=<username>
Session=plasma
```

Caveats (by design): logout immediately logs back in, and gnome-keyring is not
unlocked by autologin (first use prompts once).

---

## 13. Teardown

```bash
# Only when this installer run successfully created the corresponding resource:
flush installer log; cp it to /mnt/var/log/sensible-install.log
umount known installer-created bind and subvolume mounts, deepest first
umount /mnt  # never recursive; an unknown child mount is not ours to remove
[ "$INSTALLER_OPENED_CRYPTROOT" = true ] && cryptsetup close cryptroot
# The swapfile lives inside the root filesystem — nothing else to close.
```

The installer records terminal and package output in the root-owned,
sudo-group-readable `/var/log/sensible-install.log`. On post-wipe failure it copies that log into
the partial target when possible before owned cleanup. A critical operation or
failed teardown prevents the success dialog; optional failures are retained and
shown in the completion warning summary.
