# Sensible

**Sensible** (aka **Lazydeb**) is a Debian Testing remix — installer tooling, not a fork. A Korq project. For first-time Debian users and anyone too lazy to fight `debian-installer`.

Debian Testing (Forky), a few clear choices, working hardware, no vendor bloat. Inspired by Omarchy / Archinstall, without the extra religion.

**Installing Sensible? Start with the [download-to-first-boot guide](docs/INSTALL.md).** It covers requirements, checksum verification, USB creation, the full-disk erase warning, installer choices, and first boot.

---

## Why this exists

Debian itself is excellent. Getting to a usable desktop is not:

1. **`debian-installer` fights simple layouts.** Raw LUKS2 + Ext4 or Btrfs without LVM is painful. Guided crypto pushes LVM.
2. **Encrypted boot looks broken.** A stock LUKS install drops to a raw text passphrase prompt instead of a graphical splash.
3. **Hardware is half-enabled.** Wi-Fi firmware, SOF laptop audio, Bluetooth codecs, GPU decode, and power profiles are extra work.
4. **Switching from macOS or Windows feels alien.** Shortcuts, app stores, and “where is Slack?” are the usual friction — not a reason to ship Basecamp.

Sensible is a **reproducible live ISO** plus a **TUI installer**. It partitions the disk the way people actually want, turns on firmware and PipeWire, and offers GNOME or KDE. Third-party apps stay on Flatpak. Nothing commercial is baked in. The machine you get is Debian.

---

## What you choose at install time

### Disk (4 combinations, one layout)

Two filesystems, each with optional LUKS2. One GPT layout — no LVM:

| Partition | Size | Filesystem | Mount |
| :--- | :--- | :--- | :--- |
| EFI | 1 GiB | FAT32 | `/boot/efi` |
| BOOT | 1 GiB | Ext4 | `/boot` (always unencrypted) |
| *(swap)* | mirrors physical RAM | swapfile | **a swapfile inside the root filesystem, never a partition** — encrypted with the root when LUKS is on. Hibernation works in both modes (Secure Boot lockdown blocks it; see [Architecture](docs/ARCHITECTURE.md#3-swap-luks-and-hibernation)) |
| ROOT | rest of disk | Btrfs **or** Ext4, optional LUKS2 | `/` |

- **Btrfs**: subvolumes `@`, `@home`, `@snapshots`, `@var_log` (Snapper/Timeshift-ready; snapshot tools themselves are optional later).
- **Ext4**: single volume, `fast_commit`.
- **LUKS2**: Argon2id, TRIM/`discard`. Unlock is a **Plymouth** graphical dialog, not a console prompt.

`/boot` stays unencrypted on purpose so GRUB and Plymouth stay fast and simple. That is a known evil-maid tradeoff, documented in Architecture.

### Desktop

- **GNOME** — macOS-oriented: Wayland, gestures, dynamic workspaces. Optional **Mac copy/paste** via `keyd` (`Super+C` / `V` / `X`) so terminals do not get `SIGINT`.
- **KDE Plasma** — Windows-oriented: panel, tray, familiar window management.

The live ISO does **not** ship both desktops. It is a console/TUI installer environment. The chosen DE is installed onto the target disk.

### Software (defaults vs optional)

**Always installed (working machine):** latest Testing kernel, full `non-free-firmware` set, microcode, PipeWire, NetworkManager, BlueZ, Flatpak + Flathub, fonts, `fwupd`, Secure Boot chain on the installed system (shim + Debian-signed GRUB).

**Default apps:** Firefox, VLC, Neovim (LazyVim starter in `/etc/skel`), modern CLI tools (`ripgrep`, `fd-find`, `fzf`, `bat`, `eza`, `zoxide`, `btop`, `fastfetch`).

**Installer checkboxes (off unless selected):** Chromium, Brave (official apt origin, not a Flatpak), Audacious, and a DE-native player (Amberol on GNOME, Elisa on KDE).

**Not currently offered:** AI CLIs. If added later, they will be optional and use pinned artifacts rather than `curl | sh` from the ISO.

**Planned ([Phase 6](docs/PLAN.md#phase-6--sensible-extras-planned-not-implemented)):** fingerprint login (`fprintd`) always on, BioPass face login checkbox, oh-my-bash for all users with a sensible `.bashrc`, system git defaults + optional name/email prompts, JetBrainsMono Nerd Font, `ufw` firewall (KDE Connect-aware), printing/scanning, developer-tools checkbox (Docker + Compose, `lazygit`, `gh`), unattended `--config` installs.

Slack, WhatsApp, Zoom, Discord, and the rest are **Flathub**, not preinstalled.

---

## Hardware goal

Make as much hardware work as Debian Testing allows, on first boot:

- Kernel: `linux-image-amd64` plus `intel-microcode` / `amd64-microcode`
- Firmware: `firmware-linux`, `firmware-misc-nonfree`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-brcm80211`, `firmware-mediatek`, `firmware-sof-signed`
- GPU: Mesa Vulkan + VA-API/VDPAU; proprietary `nvidia-driver` only when an NVIDIA GPU is detected
- Audio / BT: PipeWire + WirePlumber + `libspa-0.2-bluetooth`
- Power: `power-profiles-daemon`
- Device firmware updates: `fwupd` + LVFS
- Secure Boot: shim + Debian-signed GRUB chain on the **installed system** (NVIDIA module and hibernation are blocked under lockdown — documented in Architecture). Secure Boot on the live installer ISO is enabled via live-build (`--uefi-secure-boot enable`) and verified under OVMF with Microsoft keys (`SMOKE_FIRMWARE=sb scripts/smoke-boot.sh`): the kernel reports `secureboot: Secure boot enabled` and loads the Debian Secure Boot CA.
- Planned (Phase 6): fingerprint via `fprintd` + `libpam-fprintd`, BioPass face login opt-in, printing/scanning (CUPS driverless + `sane-airscan`)

First target is **amd64 + UEFI**. Legacy BIOS and other arches are out of scope for v1.

---

## Non-goals (v1)

- LVM, RAID, dual-boot, or manual partition editing
- Shipping GNOME **and** KDE on the live ISO
- Snaps, Steam, or any vendor/SaaS client in the base image
- Encrypted `/boot` / `GRUB_ENABLE_CRYPTODISK`
- Supporting non-UEFI machines

---

## Name

| | |
| :--- | :--- |
| Product | **Sensible** |
| Informal | **Lazydeb** (same thing — live ISO command alias) |
| What it is | Debian Testing remix / on-ramp. Not a fork, not a new distro. |
| Publisher | [Korq](https://korq.io) |
| ISO | `sensible-gnome-debian-testing-amd64.iso` (GNOME, default) / `sensible-kde-...` |
| Installer | `sensible-install` (also `lazydeb`) |

The installed system hostname defaults to `debian`. The UEFI boot entry stays **Debian**. Plymouth and the live banner say **Sensible**.

---

## Repository layout (planned)

```
.
├── docs/
│   ├── ARCHITECTURE.md     # layers, disk, boot, swap/LUKS decision
│   ├── PLAN.md             # phases and milestones
│   └── INSTALLER_SPEC.md   # installer prompts and exact commands
├── live/                   # live-build config (Dockerfile, hooks, package lists)
├── installer/              # sensible-install.sh + lib/ modules
├── configs/                # keyd, omb-bashrc + gitconfig (Phase 6)
├── scripts/                # run-qemu.sh — boot the built ISO in UEFI QEMU
└── tests/                  # unit + integration suites (tests/run-tests.sh)
```

---

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — layers, disk, boot, swap/LUKS, software
- [Installation guide](docs/INSTALL.md) — download, verify, write USB, install, and first boot
- [Installer spec](docs/INSTALLER_SPEC.md) — prompts, partitioning, chroot
- [Plan](docs/PLAN.md) — implementation order

Build: `./live/build.sh` (podman/docker) or `sudo ./scripts/build-native.sh` (containerless, on Debian) produces `sensible-$SENSIBLE_VARIANT-debian-testing-amd64.iso` (`SENSIBLE_VARIANT=gnome`, the default, or `kde`). Verify it the way CI does with `./scripts/smoke-boot.sh` (headless UEFI boot assertion), or launch it interactively with `./scripts/run-qemu.sh`. Tests: `tests/run-tests.sh` — no root, no network.

---

## License

Sensible source (installer, live-build config, docs, configs) is **[MIT](LICENSE)**. Take it, remix it, ship it.

That covers **this repository only**. A built ISO is a pile of Debian (and optional third-party) packages, each under its own license — GPL kernel, various firmware, Firefox MPL, Brave if you tick that box, and so on. Redistributing the ISO means honoring those terms; MIT does not relicense them.
