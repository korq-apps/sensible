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

### Secure Boot

The full chain is signed and Secure Boot is **supported in v1**, on the installed system and on the live ISO:

- Target: `shim-signed` + `grub-efi-amd64-signed` (always installed). Shim falls through transparently when SB is off, so there is no prompt and no downside.
- Live ISO: a binary hook injects `shimx64.efi` and the signed `grubx64.efi` into the ISO EFI image (`live/config/hooks/binary/0100-secure-boot.hook.binary`), then `sbverify`-checks both signatures at build time. The media boots with SB on or off.
- Kernel and firmware updates stay bootable: everything in the chain is Debian-signed; no MOK enrollment needed for stock packages.

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
| Updates | `fwupd` (LVFS), `wireless-regdb` |
| Repos on the target | `main`, `contrib`, `non-free`, `non-free-firmware` |

`firmware-broadcom` is not a Debian package name; Broadcom Wi-Fi is `firmware-brcm80211`. `firmware-linux-nonfree` is a leftover name — do not list it.

NVIDIA: detect at install time, install proprietary stack when present. No nouveau-vs-prop prompt in v1.

---

## 7. Software (canonical list)

Keep this list the single source of truth. README and the installer spec should not invent extra default apps.

### Base (always)

`sudo`, `locales`, `keyboard-configuration`, `console-setup`, NetworkManager, `fwupd`, Flatpak, fonts (`fonts-noto-core`, `fonts-noto-color-emoji`, `fonts-liberation`), `git`, `curl`, `ca-certificates`.

### Default apps

| Kind | Package |
| :--- | :--- |
| Browser | Firefox |
| Media | VLC |
| Editor | Neovim + LazyVim starter copied to `/etc/skel/.config/nvim` |
| CLI | `ripgrep`, `fd-find`, `fzf`, `bat`, `eza`, `zoxide`, `btop`, `fastfetch`, `jq` |

### Optional (installer checkboxes)

Chromium; Brave from [the official apt origin](https://brave.com/linux/); Audacious; Amberol (GNOME) or Elisa (KDE); AI CLIs only as a later optional module with pinned artifacts.

### Explicitly not installed

Steam, Slack, WhatsApp, Zoom, Discord, Spotify, Snapd, any SaaS “default client”. Flathub is configured so the user can add them.

---

## 8. Scope

**In v1:** amd64, UEFI only, single-disk wipe, the four disk combinations above, GNOME or KDE, English-first locales (other locales selectable), working Wi-Fi/audio/GPU on common laptops.

**Later:** Btrfs Snapper, GUI NVIDIA/MOK enrollment flow, Calamares if someone wants a GUI, other arches.

**Never (Sensible):** LVM as the guided path, dual-DE live ISO, shipping commercial apps, pretending this is not Debian.
