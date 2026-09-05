# Architecture

**Sensible** (aka Lazydeb) is a Korq remix of Debian Testing (Forky): four layers, one disk layout, two desktops. The installed OS is Debian.

---

## 1. Layers

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Desktop (one variant carried in the offline ISO)   │
│   GNOME or KDE Plasma                                       │
│   GNOME: keyd Mac clipboard (Super+C/V/X)                   │
│   Flatpak · Firefox ESR · Neovim · CLI extras               │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Hardware services (on the target)                  │
│   Testing kernel + microcode + non-free firmware            │
│   PipeWire / WirePlumber / BlueZ / NetworkManager           │
│   Mesa + NVIDIA closure · fwupd · PPD                       │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: Disk, unlock, boot                                 │
│   GPT: EFI + BOOT + ROOT; swapfile inside root              │
│   ROOT = Btrfs or Ext4, optional LUKS2                      │
│   Plymouth graphical unlock (LUKS only)                     │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: Live ISO (`live-build`)                            │
│   Console / TUI only · firmware so Wi-Fi works in the live  │
│   session · `sensible-install` (`lazydeb`) · hybrid UEFI ISO│
└─────────────────────────────────────────────────────────────┘
```

The live image is an **installer appliance** carrying the complete target closure, including one desktop variant. Installation is offline; firmware and NetworkManager remain useful for hardware support and optional diagnostics, but reaching a mirror is not a prerequisite.

---

## 2. Disk layout

GPT table, no LVM. LUKS and no-LUKS differ in exactly one thing: the root
partition's type. Swap is a swapfile inside the root filesystem in both modes,
never a partition, so encryption does not change the layout.

```
/dev/nvme0n1 (example)                          LUKS on            LUKS off
├── p1  1 GiB    EF00   FAT32    /boot/efi     yes                yes
├── p2  1 GiB    8300   Ext4     /boot          yes                yes
└── p3  rest     8309/8300        /              LUKS2             plain
```

Sizes are fixed for v1: EFI **1024 MiB**, BOOT **1024 MiB**, ROOT **remainder**,
with a swapfile inside root **mirroring detected RAM**. Keeping swap in a file
means it inherits the root's encryption without a key of its own, can be resized
without touching the partition table, and leaves the layout identical either
way. 1 GiB `/boot` is enough for a few Testing kernels plus initramfs; we are not leaving this as a 1–2 GiB range in the installer.

### Btrfs

Subvolumes, then mount with `noatime,compress=zstd:1,space_cache=v2,discard=async` (`@swap` is mounted without compression — NOCOW):

| Subvolume | Mount |
| :--- | :--- |
| `@` | `/` |
| `@home` | `/home` |
| `@snapshots` | `/.snapshots` |
| `@var_log` | `/var/log` |
| `@swap` | `/swap` (swapfile host; never snapshotted) |

Ready for Snapper or Timeshift. Those tools are **not** installed in v1.

### Ext4

The guided installer offers Ext4 as the traditional alternative to Btrfs. It
uses a single filesystem on the unlocked root (or raw partition),
`noatime,errors=remount-ro,discard`, and `fast_commit` at `mkfs` time.

### Why `/boot` is unencrypted

Plymouth and GRUB then work like a normal desktop: kernel and initramfs load immediately, graphical unlock follows. `GRUB_ENABLE_CRYPTODISK` and Arch-style `cryptdevice=` are **not used**. Debian unlocks via `/etc/crypttab` + `cryptsetup-initramfs`.

Tradeoff: an attacker with physical access can tamper with `/boot`. Secure Boot (§4) mitigates this: the boot chain is signature-verified, and the kernel locks down unsigned module loading.

---

## 3. Swap, LUKS, and hibernation

The rule, as implemented:

| Root encryption | Swap | Hibernation |
| :--- | :--- | :--- |
| Off | Swapfile inside the plain root (`@swap` on Btrfs), `resume=UUID=<rootfs> resume_offset=<n>` | Enabled* |
| On | Swapfile **inside the LUKS root** (`@swap` subvol on Btrfs / `/swapfile` on Ext4), `resume=UUID=<rootfs> resume_offset=<n>` | Enabled* |

`*` Hibernation writes an unverified resume image, so the kernel blocks it under Secure Boot lockdown. With SB off, hibernation works in both modes.

Why the swapfile design wins:

- Swap inside the LUKS container is encrypted at rest — same protection the old ephemeral `cryptswap` gave, without giving up resume.
- The initramfs unlocks `cryptroot` first (crypttab + Plymouth), so the kernel can then read the swapfile and resume. `resume_offset` (4K pages) comes from `btrfs inspect-internal map-swapfile -r` (Btrfs) or `filefrag -v` (Ext4) at install time.
- The dedicated `@swap` subvolume keeps the swapfile out of any future snapshot set (a snapshotted swapfile breaks resume consistency).
- Plain swap next to a LUKS root would leak memory — that design is gone.

---

## 4. Boot flow

```
UEFI
  → shim (MS-signed)
  → GRUB (Debian-signed, files on unencrypted /boot)
  → kernel + initramfs (Debian-signed)
  → Plymouth  (if LUKS: passphrase dialog; theme = spinner on GNOME, breeze on KDE)
  → unlock cryptroot (crypttab) if needed
  → resume from swap(file) if a hibernation image exists
  → mount /, /boot, /boot/efi, activate swap
  → display manager (gdm3 or sddm)
  → GNOME or Plasma
```

With LUKS on, the installer sets `KEYMAP=y` in `/etc/initramfs-tools/initramfs.conf`: the Plymouth passphrase dialog decodes keys with the initramfs keymap, and without the console keymap a non-US passphrase can never match — a lockout on a passphrase the user typed correctly.

### Secure Boot

Secure Boot is supported by both the **live installer ISO** and the **installed system**.

- Target (installed system): `shim-signed` + `grub-efi-amd64-signed` (always installed). `grub-install` lays down the signed chain and grub's own module tree under `/EFI/debian`, so the signed GRUB finds its config and modules. Shim falls through transparently when SB is off, so there is no prompt and no downside.
- Live ISO: built with live-build's native `--uefi-secure-boot enable` support, which supplies Debian's signed shim/GRUB chain. Sensible also stages the redirect config required at GRUB's embedded `/EFI/debian` prefix. The Secure Boot smoke path uses OVMF Secure Boot firmware with Microsoft keys and must reach the live session, proving that unsigned fallback code did not boot.
- Kernel and firmware updates stay bootable: everything in the installed chain is Debian-signed; no MOK enrollment needed for stock packages.

Caveats (documented, not solved): the proprietary **NVIDIA** module is unsigned, so with SB on the kernel's lockdown rejects it — disable SB or enroll a MOK for DKMS. Lockdown also blocks **hibernation** (see §3).

---

## 5. Desktops

Display manager is implied by the DE: **gdm3** with GNOME, **sddm** with Plasma. Wayland sessions are the default.

### GNOME (macOS-oriented)

Gestures, overview, dynamic workspaces. The GNOME image enables **Mac clipboard** (`keyd`).

`keyd` mapping (input-device level, DE-agnostic):

| Chord | Sends | Why |
| :--- | :--- | :--- |
| Super+C | Ctrl+Insert | Copy in GTK/Qt **and** terminals (not Ctrl+C / SIGINT) |
| Super+V | Shift+Insert | Paste in GUI and terminals |
| Super+X | Ctrl+X | Cut in GUI; inert in most terminals |

Super tap alone stays with the DE (GNOME Overview). We do **not** map Super+A / Super+Z in v1: those become Ctrl+A / Ctrl+Z and break terminals (beginning-of-line / SIGTSTP). Same class of bug as Super+C → SIGINT.

### KDE Plasma (Windows-oriented)

Panel, launcher, tray, Alt+Tab. The KDE image leaves `keyd` disabled.

### Login: autologin with LUKS, idle lock always

Single-user, disk-encrypted desktop: the LUKS passphrase at boot is the
authentication, so the installer offers to **skip the login password**
(GDM `AutomaticLogin` / SDDM `[Autologin]`), default **on**, **only when LUKS
is enabled** — without disk encryption autologin would leave the machine wide
open. The user's password is still set (sudo, keyring, screen unlock).

Idle screen lock is always enforced, independent of the choice: GNOME gets
system dconf defaults (`idle-delay=300`, `lock-enabled`, `lock-delay=0`), KDE
gets `/etc/xdg/kscreenlockerrc` with `Autolock` + `LockOnResume` (resume from
suspend is covered). Known tradeoffs: logout logs back in immediately; the
keyring is not unlocked by autologin. SDDM autologin requires `Session=`
alongside `User=` — the installer writes `Session=plasma` (the Wayland
session file name); with only `User=` autologin never engages.

### Biometric login

Two tiers, because fingerprint and face have very different maturity on Debian:

- **Fingerprint — always installed.** `fprintd` + `libpam-fprintd` (Debian main). Enrollment lives in GNOME Settings / Plasma System Settings; nothing to configure at install time, dormant without a supported reader.
- **Face (and unified face + fingerprint UX) — installer checkbox, default off.** [BioPass](https://github.com/TickLabVN/biopass) (MIT): PAM module plus GUI enrollment, local models (YOLO-Face detection, EdgeFace recognition, MiniFASv2/MobileNetV3 anti-spoofing), polkit prompts, PAM wiring via `pam-auth-update`. Installed as a **pinned `.deb` with a recorded SHA256** — same third-party policy as Brave and the AI CLIs. Off by default because the project is young, models are fetched at first run, and real anti-spoofing wants an IR camera. Enrollment happens post-install in the BioPass app; the installer only installs.

Facts to not relearn later:

- **Biometrics never unlock LUKS.** The Plymouth passphrase dialog at boot is untouched; face/fingerprint cover session login, lock screen, `sudo`, and polkit only.
- **Fingerprint login leaves the GNOME Keyring locked** (the keyring is encrypted with the password), so the first secret access after a biometric login still prompts. Known papercut — documented, not "fixed". Same class of caveat as autologin above.
- Landscape check (2026): Howdy is face-only and semi-maintained, `howdy-next` and `authFace` are young and face-only. BioPass is the only serious multi-modal candidate.

---

## 6. Hardware

| Area | Packages / behavior |
| :--- | :--- |
| CPU | `intel-microcode`, `amd64-microcode` |
| Firmware | `firmware-linux`, `firmware-misc-nonfree`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-brcm80211`, `firmware-mediatek`, `firmware-sof-signed` |
| Wi-Fi / BT | NetworkManager, `iwd` or `wpa_supplicant`, BlueZ, `libspa-0.2-bluetooth` |
| Audio | PipeWire, WirePlumber, `pipewire-pulse`, `pipewire-audio`, `pipewire-alsa` |
| GPU | `mesa-vulkan-drivers`, `va-driver-all` (VDPAU comes from `mesa-libgallium` via mesa; `vdpau-driver-all` was removed from Testing); the offline closure includes `nvidia-driver`, while NVIDIA KMS configuration is enabled only when `lspci` sees matching hardware |
| Power | `power-profiles-daemon` (not TLP — it fights PPD and both DEs) |
| Biometrics | `fprintd`, `libpam-fprintd` (baked); BioPass optional — see §5 **(planned — post-install tool)** |
| Print / scan | `cups`, `ipp-usb` (driverless IPP-over-USB), `sane-airscan`; `simple-scan` with GNOME, `skanlite` with KDE |
| Updates | `fwupd` (LVFS), `wireless-regdb` |
| Repos on the target | `main`, `contrib`, `non-free`, `non-free-firmware` |

`firmware-broadcom` is not a Debian package name; Broadcom Wi-Fi is `firmware-brcm80211`. `firmware-linux-nonfree` is a leftover name — do not list it.

NVIDIA: the proprietary stack is baked into the offline closure because installation cannot fetch it after the live root is copied. There is no nouveau-vs-proprietary prompt in v1. The installer adds `nvidia-drm.modeset=1` only when NVIDIA is detected — without KMS, GDM/KWin silently fall back to X11 on exactly the hardware being special-cased.

---

## 7. Software (canonical list)

Keep this list the single source of truth. README and the installer spec should not invent extra default apps.

### Base (always)

`sudo`, `locales`, `keyboard-configuration`, `console-setup`, NetworkManager, `fwupd`, Flatpak, fonts (`fonts-noto-core`, `fonts-noto-color-emoji`, `fonts-liberation`), `git`, `curl`, `ca-certificates`.

JetBrainsMono Nerd Font from a pinned nerd-fonts release (Debian packages no Nerd Fonts; LazyVim and the fancier prompt themes want one), and `ufw` enabled with default deny incoming / allow outgoing — on KDE, ports 1714–1764 tcp/udp are allowed so KDE Connect keeps working (a silent-breakage trap otherwise). Both are baked at build time: the font by `scripts/fetch-pins.sh` (pin + SHA256 in `live/pins.env`), `ufw` by `live/config/hooks/live/0300-ufw.hook.chroot`, which writes allow rules while ufw is still disabled and flips `ENABLED=yes` in `/etc/ufw/ufw.conf` — never `ufw enable` in a chroot.

### Default apps

| Kind | Package |
| :--- | :--- |
| Browser | Firefox ESR (`firefox-esr`) |
| Alternate browser | Chromium (`chromium`) |
| Office | LibreOffice Writer, Calc, and Impress |
| Mail | Thunderbird |
| Passwords | KeePassXC |
| Media | VLC |
| Editor | Neovim + LazyVim starter copied to `/etc/skel/.config/nvim` |
| Archives | `7zip`, `unzip`, `zip`; File Roller on GNOME, Ark on KDE |
| GNOME utilities | The `gnome-core` PDF/image viewers, text editor, calculator, disks and calendar; plus Amberol |
| KDE utilities | Okular, Gwenview, Kate, KCalc, Spectacle, and Elisa |
| CLI | `ripgrep`, `fd-find`, `fzf`, `bat`, `eza`, `zoxide`, `btop`, `fastfetch`, `jq` |

### Offline manual

Both build entry points use `scripts/stage-manual.sh` to install local HTML/CSS,
`sensible-manual`, a permanent application-menu launcher, and an inactive
autostart template. The installer checks this payload before partitioning and
copies the template into only the installed user's autostart directory. A
successful desktop URI dispatch records a per-user marker and removes that
autostart entry; a failed dispatch retries next login. No global live-session
autostart or first-login downloads are added. The permanent launcher ignores
the marker. Actual GNOME/KDE session launch remains a real-desktop test gate.

### Planned desktop profiles

The next desktop milestone is specified in
[DESKTOP_PROFILES.md](DESKTOP_PROFILES.md). It is **planned, not shipped**:
additional photo/sharing applications, curated GNOME extensions and native
Plasma equivalents, with user-overridable defaults. Approved upstream default
artifacts may be pinned and verified at image-build time; installation and
first-login setup must remain offline. The current software table above stays
the record of implemented behavior until those changes land.

### Shell (all users)

oh-my-bash from a **shared, read-only install** — not per-user clones:

- A pinned upstream commit vendored to `/usr/share/oh-my-bash` (pin + SHA256 in `live/pins.env`; staged by `scripts/fetch-pins.sh` at build time).
- `/etc/skel/.bashrc` comes from `configs/omb-bashrc`: `OSH=/usr/share/oh-my-bash`, the `font` theme (no patched-font dependency), auto-update off (the install is root-owned; updates come with the OS), git/ssh completions.
- The same file **activates the CLI set we already install** — `zoxide init`, fzf keybindings, `eza` ls aliases, and `bat`/`fd` aliases for Debian's renamed `batcat`/`fdfind` binaries. Installing tools nobody wired up is not sensible.
- `/etc/skel` is populated when the ISO is built, so the installer's `useradd -m` inherits it — the ordering problem the network design had does not exist here. Root keeps the stock Debian bashrc.

### Git (all users)

System-wide defaults in `/etc/gitconfig` from `configs/gitconfig` — `init.defaultBranch=main`, `pull.rebase=true`, `push.autoSetupRemote=true`, `fetch.prune=true`, `rebase.autostash=true`. Nothing else; users override in `~/.gitconfig`.

Identity is **per-user, never system-wide**: the installer optionally asks for full name and email (also reused for the account's GECOS field) and writes the first user's `~/.gitconfig`. Skipping the prompts leaves git fully working, just without identity until the user sets it.

No credential helper is configured: Debian ships no packaged libsecret helper (`git-credential-libsecret` is not a package; the contrib helper must be compiled), and we do not build software in the installer. GitHub auth is `gh auth login` when Developer tools are selected.

### Optional software

**Not currently offered by the offline installer:** Brave and Audacious. These belong in a post-install application tool or the desktop's software center.

**Later, not implemented:** AI CLIs may be added as an optional module with pinned artifacts. They are not current installer checkboxes.

**Planned (post-install tool):** BioPass face login (pinned `.deb`, see §5); Developer tools — `docker.io`, `docker-compose` (the v2 rewrite in Testing), `lazygit`, `gh`. Developer tools deliberately do **not** add the user to the `docker` group — membership is root-equivalent, so the default is `sudo docker` (a user can opt in later, knowing the tradeoff).

### Explicitly not installed

Steam, Slack, WhatsApp, Zoom, Discord, Spotify, Snapd, any SaaS “default client”. The planned post-install tool configures Flathub so the user can add them without making the offline installer contact a third-party origin.

---

## 8. Scope

**In v1:** amd64, UEFI only, single-disk wipe, Btrfs or Ext4 with LUKS on/off, separate GNOME and KDE images, selectable locales, and working Wi-Fi/audio/GPU on common laptops.

**Planned (post-install tool):** developer tools and BioPass (§5, §7). `--config` unattended installs are release-test infrastructure (PLAN.md).

**Later:** Btrfs Snapper (+ `grub-btrfs` boot-menu rollback), TPM2 LUKS auto-unlock (`systemd-cryptenroll` or clevis; PCR policy must account for the unencrypted `/boot`), FIDO2 keys for sudo/polkit (`libpam-u2f`), GUI NVIDIA/MOK enrollment flow, Calamares if someone wants a GUI, other arches.

**Never (Sensible):** LVM as the guided path, dual-DE live ISO, shipping commercial apps, pretending this is not Debian.
