# Architecture

**Sensible** (aka Lazydeb) is a Korq remix of Debian Testing (Forky): four layers, one disk layout, two desktops. The installed OS is Debian.

---

## 1. Layers

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Desktop (installed onto the target, not the ISO)   │
│   GNOME or KDE Plasma                                       │
│   Optional keyd Mac clipboard (Super+C/V/X)                 │
│   Flatpak + Flathub · Firefox · Neovim · CLI extras         │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Hardware services (on the target)                  │
│   Testing kernel + microcode + non-free firmware            │
│   PipeWire / WirePlumber / BlueZ / NetworkManager           │
│   Mesa (+ nvidia-driver if detected) · fwupd · PPD          │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: Disk, unlock, boot                                 │
│   GPT: EFI + BOOT + SWAP + ROOT                             │
│   ROOT = Btrfs or Ext4, optional LUKS2                      │
│   Plymouth graphical unlock (LUKS only)                     │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: Live ISO (`live-build`)                            │
│   Console / TUI only · firmware so Wi-Fi works in the live  │
│   session · `sensible-install` (`lazydeb`) · hybrid UEFI ISO│
└─────────────────────────────────────────────────────────────┘
```

The live image is an **installer appliance**, not a full desktop. That keeps ISO size down and avoids shipping two DEs. Firmware and NetworkManager **do** belong on the live image so a laptop can reach a mirror during install.

---

## 2. Disk layout

GPT table, no LVM. LUKS and no-LUKS differ in exactly one thing: where swap lives.

```
/dev/nvme0n1 (example)                          LUKS on            LUKS off
├── p1  1 GiB    EF00   FAT32    /boot/efi     yes                yes
├── p2  1 GiB    8300   Ext4     /boot          yes                yes
├── p3  RAM+10%  8200   swap     (plain)        —                  yes
└── pN  rest     8309/8300        /              p3, LUKS2          p4
```

Sizes are fixed for v1: EFI **1024 MiB**, BOOT **1024 MiB**, SWAP **detected RAM + 10%**, ROOT **remainder**. 1 GiB `/boot` is enough for a few Testing kernels plus initramfs; we are not leaving this as a 1–2 GiB range in the installer.

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

Single filesystem on the unlocked root (or the raw partition). Options: `noatime,errors=remount-ro,discard`. `fast_commit` at `mkfs` time.

### Why `/boot` is unencrypted

Plymouth and GRUB then work like a normal desktop: kernel and initramfs load immediately, graphical unlock follows. `GRUB_ENABLE_CRYPTODISK` and Arch-style `cryptdevice=` are **not used**. Debian unlocks via `/etc/crypttab` + `cryptsetup-initramfs`.

Tradeoff: an attacker with physical access can tamper with `/boot`. Secure Boot (§4) mitigates this: the boot chain is signature-verified, and the kernel locks down unsigned module loading.

---

## 3. Swap, LUKS, and hibernation

The rule, as implemented:

| Root encryption | Swap | Hibernation |
| :--- | :--- | :--- |
| Off | Plain partition (`p3`), `resume=UUID=<swap>` in GRUB | Enabled |
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

Gestures, overview, dynamic workspaces. Optional **Mac clipboard** (`keyd`), default **on** for this DE.

`keyd` mapping (input-device level, DE-agnostic):

| Chord | Sends | Why |
| :--- | :--- | :--- |
| Super+C | Ctrl+Insert | Copy in GTK/Qt **and** terminals (not Ctrl+C / SIGINT) |
| Super+V | Shift+Insert | Paste in GUI and terminals |
| Super+X | Ctrl+X | Cut in GUI; inert in most terminals |

Super tap alone stays with the DE (GNOME Overview). We do **not** map Super+A / Super+Z in v1: those become Ctrl+A / Ctrl+Z and break terminals (beginning-of-line / SIGTSTP). Same class of bug as Super+C → SIGINT.

### KDE Plasma (Windows-oriented)

Panel, launcher, tray, Alt+Tab. `keyd` is offered but default **off**.

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

### Biometric login (planned — Phase 6)

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
| GPU | `mesa-vulkan-drivers`, `va-driver-all`, `vdpau-driver-all`; `nvidia-driver` + `firmware-misc-nonfree` if `lspci` sees NVIDIA |
| Power | `power-profiles-daemon` (not TLP — it fights PPD and both DEs) |
| Biometrics | `fprintd`, `libpam-fprintd`; BioPass optional — see §5 **(planned — Phase 6)** |
| Print / scan | `cups`, `ipp-usb` (driverless IPP-over-USB), `sane-airscan`; `simple-scan` with GNOME, `skanlite` with KDE **(planned — Phase 6)** |
| Updates | `fwupd` (LVFS), `wireless-regdb` |
| Repos on the target | `main`, `contrib`, `non-free`, `non-free-firmware` |

`firmware-broadcom` is not a Debian package name; Broadcom Wi-Fi is `firmware-brcm80211`. `firmware-linux-nonfree` is a leftover name — do not list it.

NVIDIA: detect at install time, install proprietary stack when present. No nouveau-vs-prop prompt in v1. The installer adds `nvidia-drm.modeset=1` to the kernel command line whenever NVIDIA is detected — without KMS, GDM/KWin silently fall back to X11 and the Wayland-by-default promise breaks on exactly the hardware we special-cased.

---

## 7. Software (canonical list)

Keep this list the single source of truth. README and the installer spec should not invent extra default apps.

### Base (always)

`sudo`, `locales`, `keyboard-configuration`, `console-setup`, NetworkManager, `fwupd`, Flatpak, fonts (`fonts-noto-core`, `fonts-noto-color-emoji`, `fonts-liberation`), `git`, `curl`, `ca-certificates`.

**Planned — Phase 6:** JetBrainsMono Nerd Font from a pinned nerd-fonts release (Debian packages no Nerd Fonts; LazyVim and the fancier prompt themes want one), and `ufw` enabled with default deny incoming / allow outgoing — on KDE, ports 1714–1764 tcp/udp are allowed so KDE Connect keeps working (a silent-breakage trap otherwise).

### Default apps

| Kind | Package |
| :--- | :--- |
| Browser | Firefox |
| Media | VLC |
| Editor | Neovim + LazyVim starter copied to `/etc/skel/.config/nvim` |
| CLI | `ripgrep`, `fd-find`, `fzf`, `bat`, `eza`, `zoxide`, `btop`, `fastfetch`, `jq` |

### Shell (all users) — planned, Phase 6

oh-my-bash from a **shared, read-only install** — not per-user clones:

- A pinned upstream tag vendored to `/usr/share/oh-my-bash` (`.git` stripped).
- `/etc/skel/.bashrc` comes from `configs/omb-bashrc`: `OSH=/usr/share/oh-my-bash`, the `font` theme (no patched-font dependency), auto-update off (the install is root-owned; updates come with the OS), git/ssh completions.
- The same file **activates the CLI set we already install** — `zoxide init`, fzf keybindings, `eza` ls aliases, and `bat`/`fd` aliases for Debian's renamed `batcat`/`fdfind` binaries. Installing tools nobody wired up is not sensible.
- Requires `/etc/skel` to be complete **before** `useradd -m` (today the installer copies LazyVim into the created user's home as a workaround — that reordering lands with this work). Root keeps the stock Debian bashrc.

### Git (all users) — planned, Phase 6

System-wide defaults in `/etc/gitconfig` from `configs/gitconfig` — `init.defaultBranch=main`, `pull.rebase=true`, `push.autoSetupRemote=true`, `fetch.prune=true`, `rebase.autostash=true`. Nothing else; users override in `~/.gitconfig`.

Identity is **per-user, never system-wide**: the installer optionally asks for full name and email (also reused for the account's GECOS field) and writes the first user's `~/.gitconfig`. Skipping the prompts leaves git fully working, just without identity until the user sets it.

No credential helper is configured: Debian ships no packaged libsecret helper (`git-credential-libsecret` is not a package; the contrib helper must be compiled), and we do not build software in the installer. GitHub auth is `gh auth login` when Developer tools are selected.

### Optional software

**Current installer checkboxes:** Chromium; Brave from [the official apt origin](https://brave.com/linux/); Audacious; Amberol (GNOME) or Elisa (KDE).

**Later, not implemented:** AI CLIs may be added as an optional module with pinned artifacts. They are not current installer checkboxes.

**Planned — Phase 6:** BioPass face login (pinned `.deb`, see §5); Developer tools — `docker.io`, `docker-compose` (the v2 rewrite in Testing), `lazygit`, `gh`. Developer tools deliberately do **not** add the user to the `docker` group — membership is root-equivalent, so the default is `sudo docker` (a user can opt in later, knowing the tradeoff).

### Explicitly not installed

Steam, Slack, WhatsApp, Zoom, Discord, Spotify, Snapd, any SaaS “default client”. Flathub is configured so the user can add them.

---

## 8. Scope

**In v1:** amd64, UEFI only, single-disk wipe, the four disk combinations above, GNOME or KDE, English-first locales (other locales selectable), working Wi-Fi/audio/GPU on common laptops.

**Planned (Phase 6):** biometrics (§5), oh-my-bash + git defaults (§7), ufw, printing/scanning, developer tools, `--config` unattended installs.

**Later:** Btrfs Snapper (+ `grub-btrfs` boot-menu rollback), TPM2 LUKS auto-unlock (`systemd-cryptenroll` or clevis; PCR policy must account for the unencrypted `/boot`), FIDO2 keys for sudo/polkit (`libpam-u2f`), GUI NVIDIA/MOK enrollment flow, Calamares if someone wants a GUI, other arches.

**Never (Sensible):** LVM as the guided path, dual-DE live ISO, shipping commercial apps, pretending this is not Debian.
