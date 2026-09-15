# Installer specification

Current implementation contract for `installer/sensible-install.sh`. On the live ISO the command is `sensible-install` (alias `lazydeb`). Behavior must match [Architecture](ARCHITECTURE.md). This file is the command-level source of truth.

---

## 1. Constraints

- **UEFI only.** Exit if `/sys/firmware/efi` is missing.
- **One disk, full wipe.** No dual-boot on the target disk, no custom partition editor. Partitioning and filesystem writes are confined to the selected disk; GRUB registration also updates shared UEFI NVRAM. Separate-disk boot considerations are in the [install guide](INSTALL.md#7-windows-on-a-second-disk).
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
    → Remaining prompts (or validated --config input for unattended installation)
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
| LUKS2 | Yes | Uses the account password entered twice, min 8 characters; no separate encryption password prompt |
| Swap | ZRAM (50% of RAM, lz4, priority 100) ahead of a swapfile inside root mirroring RAM (priority 10) | Shown, not editable; only the swapfile can hold a hibernation image |
| Desktop | Build variant | GNOME or KDE Plasma release image; shown, not prompted |
| Mac clipboard (`keyd`) | On for GNOME, off for KDE | Fixed by build variant; Super+C/V/X only |
| Hostname | `debian` | RFC 1123 syntax and maximum 63 bytes for the Linux static hostname. Stay `debian` — the box is Debian, not a derivative. |
| Username | none | `^[a-z_][a-z0-9_-]*$`, maximum 32 characters, and not an existing or known package-owned account; recheck after target packages before `useradd` |
| User password | none | Twice; root password set to the same value for recovery |
| Timezone | `timedatectl` or `UTC` | zoneinfo |
| Locale | `en_US.UTF-8` | Must be in `/usr/share/i18n/SUPPORTED` |
| Keyboard | live console layout | Validate and apply to the live console before either password; write the same layout through target `keyboard-configuration` |
| Skip login password (autologin) | On (only offered with LUKS) | GDM/SDDM autologin after disk unlock; saved-secret access may still prompt; idle screen lock remains enabled |
| Full name | empty | Optional GECOS + git `user.name` |
| Email | empty | Optional git `user.email`, written only to the user's `~/.gitconfig` |

Firefox ESR, Chromium, ONLYOFFICE Desktop Editors, Thunderbird, KeePassXC,
VLC, Neovim, Flatpak, firmware, archive support, the CLI set, and the
variant-native utilities are always installed — not checkboxes.

**Planned post-install choices (not installer prompts):**

| Field | Default | Notes |
| :--- | :--- | :--- |
| Howdy-next face setup | Off | Standalone local build/configuration/test tools ([guide](BIOMETRICS.md)); guided login activation with timed rollback. Fingerprint (`fprintd`) is always installed |
| Developer tools | Off | `docker.io` + `docker-compose`, `lazygit`, `gh`; user **not** added to the docker group |

<a id="unattended-mode-planned--release-test-infrastructure"></a>

### Unattended mode

`sensible-install --config answers.toml` reads every prompt from a file and asks nothing. Same validation as interactive mode; any missing or invalid key aborts **before** partitioning. `confirm_wipe = true` is still required as explicit destructive authorization, without making interactive users retype a device they selected and confirmed. Primary consumer is CI: running LUKS on/off for each desktop release image end-to-end in QEMU.

Merged in PR #17 for #4, with rootless parser and mocked full-flow evidence;
real image installation/boot validation remains in #5.
Use an image containing this implementation, not an earlier release.
The Python 3.11+ standard-library `tomllib` reader parses data and rejects
unsupported keys; optional applications belong to the planned post-install
catalog, not this file. Config mode preserves the current
unified password contract and reads the secret from a separate protected file,
not inline TOML, command-line arguments or environment variables. The same
password sets the user/root recovery password and, when enabled, LUKS.
Any later saved interactive profile must omit secrets and disk selection and
set `confirm_wipe = false`; reusing preferences never reuses wipe authorization.

```toml
disk            = "/dev/vda"
confirm_wipe    = false              # change to true only after reviewing the target
filesystem      = "btrfs"            # btrfs or ext4
luks            = true
autologin       = true              # rejected when luks = false
hostname        = "debian"
username        = "alice"
full_name       = ""                # optional: GECOS + git user.name
email           = ""                # optional: git user.email
password_file   = "/run/sensible-secrets/password" # protected local file
timezone        = "UTC"
locale          = "en_US.UTF-8"
keyboard        = "us"
```

Unattended safety and completion contract:

- Require all displayed fields except `full_name` and `email`; those default to
  empty strings. Types are strict; reject unknown keys, inline password fields,
  separate LUKS secrets and unsupported values rather than silently ignoring them.
- Require root-owned regular config and secret files, mode `0600` or `0400`;
  reject symlinks (including path components), hard links and special files.
  Read from checked open file
  descriptors so path replacement cannot bypass the checks. The secret is one
  non-empty UTF-8 line with an optional final newline; reject embedded newlines,
  CR and NUL, and apply the same minimum-eight-character password validation as
  interactive input. Limit config files to 64 KiB and secret files to 4 KiB.
  Optional identity fields reject control characters and `"`, `\`, `:`, `;`,
  `#`, which cannot safely be written to the current GECOS/Git identity format.
- Parse and validate all input before applying keyboard or target settings.
  Opening a diagnostic log is allowed; do not copy secrets/config into the
  target, log their contents or include them in parser errors or shell tracing.
  The copy operation excludes both input paths; it does not copy their contents
  into the installed system. Operators retain ownership of their input files; the installer does not
  delete them automatically. Prefer ephemeral `/run` storage for CI secrets.
- Keep disk selection explicit, enforce the same eligibility/identity checks,
  and revalidate immediately before wipe. A config file never bypasses boot
  preflight or authorizes cleanup of resources owned by another process.
- No prompts, repair shells or terminal requirement, including on failure.
  Return `0` after installation verification, log finalization and owned-resource
  teardown succeed; return nonzero on failure with a clear stage diagnostic.
  Config mode does not reboot or power off: the caller handles media removal and boot.
- [The checked-in example](../configs/answers.example.toml) is non-secret and
  has `confirm_wipe = false`. Neither this example nor a saved preference file
  authorizes an erase without explicit editing. `python3` is in the live
  package list and the setup hook fails the build if `tomllib` is unavailable.

Provisioning and invocation are covered in the
[advanced install guide](INSTALL.md#unattended-installation-for-testing).

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

Compressed RAM swap runs ahead of that file (issue #11). The image ships
`zram-tools` with an explicit `/etc/default/zramswap` (`ALGO=lz4`,
`PERCENT=50`, `PRIORITY=100`), and the installer enables `zramswap.service`
on the target. The swapfile's fstab entry carries `pri=10`, so the kernel
fills `/dev/zram0` first and spills to disk only when it is full. Hibernation
writes to one swap area, the swapfile selected by `resume=`/`resume_offset=`,
which are unchanged; ZRAM capacity is never counted as persistent swap and
does not reduce the minimum disk size. `zramswap.service` is a oneshot wanted
by `multi-user.target`: a failed ZRAM setup leaves the swapfile active and is
visible in `systemctl status zramswap`. Writeback is not configured.

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
wrappers, the "Try Sensible" desktop launcher and its preparation unit,
staged `/opt/sensible` source/docs, live issue/MOTD branding, root
autologin units, and live-only package/state trees. Reset `machine-id` and
delete `/var/lib/alsa/asound.state` (mixer levels `alsa-state.service` stored
for the live console). Purge `live-boot`, `live-config`, and
`live-config-systemd` before rebuilding the target initramfs.

Before the completion summary, run `sensible-audio-check --summary` from the
live root and record each printed line as a warning (`record_audio_warnings`
in `installer/lib/hardware.sh`). The live session runs the same kernel and
firmware the target copies, so a silent laptop is silent after first boot too.
The check is read-only; a missing or failing checker never aborts the install.

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
/swap/swapfile       none         swap   sw,pri=10                                                             0 0
tmpfs                /tmp         tmpfs  defaults,nosuid,nodev                                                 0 0
```

Ext4 + LUKS: one `/` line (`ext4  noatime,errors=remount-ro,discard  0 1`), same boot/efi/tmpfs, swap line is `/swapfile none swap sw,pri=10 0 0`.

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
  firmware-cirrus firmware-intel-sound
  cryptsetup cryptsetup-initramfs
  plymouth plymouth-themes
  grub-efi-amd64 grub-efi-amd64-signed shim-signed
  network-manager pipewire wireplumber pipewire-pulse pipewire-audio pipewire-alsa
  alsa-ucm-conf alsa-topology-conf alsa-utils
  libspa-0.2-bluetooth bluez
  power-profiles-daemon fwupd
  flatpak
  firefox-esr chromium vlc neovim
  onlyoffice-desktopeditors (pinned local .deb, not a Debian archive package)
  fonts-dejavu fonts-crosextra-carlito xwayland desktop-file-utils libnss3 libnspr4 libpulse0
  thunderbird keepassxc
  7zip unzip zip
  ripgrep fd-find fzf bat eza zoxide btop fastfetch jq
  fonts-noto-core fonts-noto-color-emoji fonts-liberation

If GNOME:
  gnome-core gdm3 gnome-software gnome-software-plugin-flatpak dconf-cli ptyxis
  file-roller amberol simple-scan
  gnome-shell-extension-manager gnome-tweaks
  paper-icon-theme papirus-icon-theme orchis-gtk-theme gtk-update-icon-cache librsvg2-common
  gnome-shell-extension-gsconnect gnome-shell-extension-appindicator
  gnome-shell-extension-caffeine gnome-shell-extension-dashtodock
  gnome-shell-extension-user-theme gir1.2-gtop-2.0 lm-sensors
  tesseract-ocr tesseract-ocr-eng zbar-tools
  plymouth theme: spinner

If KDE:
  kde-plasma-desktop sddm plasma-discover plasma-discover-backend-flatpak konsole
  okular ark gwenview kate kcalc kde-spectacle elisa skanlite
  plymouth theme: breeze (package plymouth-theme-breeze if needed)

Always in the closure:
  nvidia-driver  (hardware detection only enables nvidia-drm.modeset=1)

GNOME variant:
  keyd + configs/keyd-default.conf
```

Enable: `NetworkManager`, `bluetooth`, `power-profiles-daemon`, `fwupd`, `gdm3` or `sddm`, and `keyd` when selected.

ONLYOFFICE uses the complete upstream package, version/architecture/SHA256-pinned
in `live/pins.env` and staged through live-build's local APT repository. Its
package name is a documented exception to the Debian package-name gate, not a
host-repository lookup. `0255-office.hook.chroot` checks the installed identity,
full editor/converter/launcher/license payload, linked libraries and free fonts.
A build-only APT preference blocks the recommended Microsoft font downloader;
NSS/NSPR and PulseAudio client libraries missing from upstream metadata are
explicit in the shared closure. Office MIME defaults are user-overridable and
leave PDF/plain-text defaults alone. No ONLYOFFICE repository is enabled, so
upgrades require a reviewed upstream `.deb`; LibreOffice is optional post-install.

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
#   GNOME-only extension zips (pinned EGO version tags) → /usr/share/gnome-shell/extensions
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

Flathub is already enabled for both editions via the image's static system
remote definition and signing key. The build hook initializes/verifies it
without downloading app metadata; no installer/first-login network setup is
required. Actual Flatpak browsing, app installation and updates require network.

These stay optional or third-party/online and move out of the installer entirely:

```text
Brave Origin:     official Brave apt source + brave-origin (never from Debian);
                  official online installer documented in the manual
Audacious:        optional alternative media player from Debian
Developer tools:  docker.io docker-compose lazygit gh; systemctl enable docker;
                  the user is NOT added to the docker group (root-equivalent)
Howdy-next:       standalone build/install, camera configuration, enrollment
                  and guided PAM activation with testing and timed rollback;
                  see BIOMETRICS.md
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
passphrase unlocks the disk, the desktop starts without a login prompt, and
the password remains set for sudo, screen unlock, and the keyring. Without
LUKS the prompt is never shown. The prompt also states that skipping the
login prompt does not unlock the edition's saved-password store, KDE Wallet
or GNOME Keyring, which may ask for its own password the first time a program
uses it. Autologin passes no typed password to PAM; whether GDM's cached
disk-passphrase path unlocks GNOME Keyring on real hardware is unverified, so
the wording promises neither outcome (see #29 and
[Architecture: desktop wallets](ARCHITECTURE.md#desktop-wallets-and-saved-credentials)).

Screen lock defaults are written for both desktops regardless of the choice:

- GNOME: system dconf defaults — `idle-delay=300`, `lock-enabled=true`,
  `lock-delay=0`; Close/Minimize/Maximize titlebar buttons; the curated extension
  list; Paper icons and Orchis GTK 3 theme; Caffeine inactive without fullscreen/media auto-inhibition; Clipboard
  Indicator persistence limited to favorites with image caching off; and Vitals
  public-IP lookup off. These live in `/etc/dconf/profile/user` plus
  `/etc/dconf/db/local.d/`, followed by `dconf update`; no dconf locks are added,
  so later user choices win. The keyfile is `configs/gnome-dconf-defaults`:
  `0260-gnome-profile.hook.chroot` bakes it into the image, so the "Try
  Sensible" live desktop shows the same profile, and `configure_login`
  re-applies the same file to the target (hard failure if it is missing).
- KDE: `/etc/xdg/kscreenlockerrc` — `Autolock=true`, `Timeout=5`,
  `LockOnResume=true` (covers resume from suspend).

GNOME appearance assets: the Debian packages above plus pinned Qogir, Matcha
(sea accent) and Fluent standard/light/dark variants and the full Qogir
icon collection; existing Marble/Graphite options remain. Qogir/Matcha/Fluent/
Graphite include GTK 3, GTK 4 and GNOME Shell components, installed globally
under `/usr/share/themes/`. No forced Shell, GDM or personal libadwaita CSS
override. The new collections omit GTK 2 components because
`gtk2-engines-murrine` is no longer available in Testing. See the
[desktop profile](DESKTOP_PROFILES.md) for provenance and acceptance status.

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

Caveats: logout immediately logs back in. Skipping the display-manager login
does not guarantee password-free access to saved credentials. Autologin or
biometric authentication alone does not supply the wallet/keyring password;
password login can unlock a matching store through PAM. Prompts may recur
according to wallet locking policy, so do not promise exactly one per session.

[#29](https://github.com/korq-apps/sensible/issues/29) plans KDE first-use and
cross-desktop PAM acceptance without changing existing encrypted wallets,
installed screen locking or the LUKS-only autologin choice. It separately
evaluates GDM's upstream cached disk-password mechanism; current package
configuration is not proof of working boot-to-keyring unlock. See
[Architecture: desktop wallets](ARCHITECTURE.md#desktop-wallets-and-saved-credentials).
Neither empty-password persistent wallets nor plaintext saved passwords are
an acceptable way to suppress a prompt. This is a planned integration contract,
not a claim that the fix or a new secret-handoff mechanism has shipped.

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
