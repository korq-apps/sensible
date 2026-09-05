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

Sensible is a **reproducible live ISO** plus a **TUI installer**. It partitions the disk the way people actually want and turns on firmware and PipeWire. Separate GNOME and KDE release images provide the chosen desktop; the installer does not download or switch desktops. Third-party apps stay on Flatpak. Nothing commercial is baked in. The machine you get is Debian.

---

## Installation profile

### Disk (four combinations, one partition layout)

Choose Btrfs or Ext4, each with optional LUKS2. All four combinations use one
GPT partition layout — no LVM:

| Partition | Size | Filesystem | Mount |
| :--- | :--- | :--- | :--- |
| EFI | 1 GiB | FAT32 | `/boot/efi` |
| BOOT | 1 GiB | Ext4 | `/boot` (always unencrypted) |
| *(swap)* | mirrors physical RAM | swapfile | **a swapfile inside the root filesystem, never a partition** — encrypted with the root when LUKS is on. Hibernation works in both modes (Secure Boot lockdown blocks it; see [Architecture](docs/ARCHITECTURE.md#3-swap-luks-and-hibernation)) |
| ROOT | rest of disk | Btrfs or Ext4, optional LUKS2 | `/` |

- **Btrfs**: subvolumes `@`, `@home`, `@snapshots`, `@var_log` (Snapper/Timeshift-ready; snapshot tools themselves are optional later).
- **Ext4**: traditional single root filesystem with `fast_commit` enabled.
- **LUKS2**: Argon2id, TRIM/`discard`. Unlock is a **Plymouth** graphical dialog, not a console prompt.

`/boot` stays unencrypted on purpose so GRUB and Plymouth stay fast and simple. That is a known evil-maid tradeoff, documented in Architecture.

### Desktop release

- **GNOME** — macOS-oriented: Wayland, gestures, dynamic workspaces. Includes **Mac copy/paste** via `keyd` (`Super+C` / `V` / `X`) so terminals do not get `SIGINT`.
- **KDE Plasma** — Windows-oriented: panel, tray, familiar window management.

The live ISO does **not** ship both desktops. Choose the GNOME or KDE release asset before writing the USB. The corresponding desktop is already baked into the offline image and copied to the target.

### Software (defaults vs optional)

**Always installed (working machine):** latest Testing kernel, full `non-free-firmware` set, microcode, PipeWire, NetworkManager, BlueZ, Flatpak, fonts, `fwupd`, Secure Boot chain on the installed system (shim + Debian-signed GRUB). The Flathub remote is added later by the planned `sensible-apps` tool or manually after first boot.

**Default apps:** Firefox ESR and Chromium; LibreOffice Writer, Calc, and Impress; Thunderbird; KeePassXC; VLC; Neovim (LazyVim starter in `/etc/skel`); archive support; and modern CLI tools (`ripgrep`, `fd-find`, `fzf`, `bat`, `eza`, `zoxide`, `btop`, `fastfetch`). GNOME adds File Roller and Amberol; KDE adds Okular, Ark, Gwenview, Kate, KCalc, Spectacle, and Elisa. Flatpak and the desktop store integration are ready for use after installation.

**Not currently offered by the offline installer:** Brave, Audacious, and Flathub remote setup. Install additional applications after first boot; commercial applications belong on Flathub rather than in the base image.

**Not currently offered:** AI CLIs. If added later, they will be optional and use pinned artifacts rather than `curl | sh` from the ISO.

**Included, no question asked:** fingerprint login (`fprintd`, dormant without a reader), oh-my-bash for all users with a sensible `.bashrc`, system-wide git defaults, JetBrainsMono Nerd Font, `ufw` firewall (deny incoming / allow outgoing, KDE Connect-aware), and printing/scanning (CUPS driverless + `sane-airscan`) — all baked into the image at build time.

**Planned ([Phase 6](docs/PLAN.md#phase-6--sensible-extras-re-scoped-for-offline), post-install tool):** BioPass face login (pinned `.deb`), developer-tools checkbox (Docker + Compose, `lazygit`, `gh`), and unattended `--config` installs.

Slack, WhatsApp, Zoom, Discord, and the rest belong on **Flathub**, not in the base image.

---

## Hardware goal

Make as much hardware work as Debian Testing allows, on first boot:

- Kernel: `linux-image-amd64` plus `intel-microcode` / `amd64-microcode`
- Firmware: `firmware-linux`, `firmware-misc-nonfree`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-brcm80211`, `firmware-mediatek`, `firmware-sof-signed`
- GPU: Mesa Vulkan + VA-API/VDPAU; the offline closure includes `nvidia-driver`, and NVIDIA-specific KMS configuration is enabled only when matching hardware is detected
- Audio / BT: PipeWire + WirePlumber + `libspa-0.2-bluetooth`
- Power: `power-profiles-daemon`
- Device firmware updates: `fwupd` + LVFS
- Secure Boot: shim + Debian-signed GRUB chain on the **installed system** (NVIDIA module and hibernation are blocked under lockdown — documented in Architecture). Secure Boot on the live installer ISO is enabled via live-build (`--uefi-secure-boot enable`) and verified under OVMF with Microsoft keys (`SMOKE_FIRMWARE=sb scripts/smoke-boot.sh`): the kernel reports `secureboot: Secure boot enabled` and loads the Debian Secure Boot CA.
- Biometrics: fingerprint via `fprintd` + `libpam-fprintd` (baked; dormant without a reader). Printing/scanning (CUPS driverless + `sane-airscan`) is baked too. BioPass face login is a planned post-install opt-in.

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
├── configs/                # keyd, omb-bashrc + gitconfig (baked into the image)
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

CI builds both desktop editions and tests each under UEFI and Secure Boot.
Smoke tests stop after both serial boot markers appear and QEMU remains alive
for `SMOKE_SETTLE` seconds (default 5); `SMOKE_TIMEOUT` (default 600) is the
failure deadline, not a mandatory wait. This checks live serial readiness, not
graphical-desktop health or installed-disk boot.

New pushes supersede older builds of the same PR. Named build containers and
QEMU guests are cleaned up on cancellation. Container builds reuse only `.deb`
downloads under `live/.cache/live-build` and checksum-verified pins under
`live/local/pins`; chroots, bootstrap snapshots, APT indexes and stage state are
rebuilt. CI restores those downloads after checkout and saves a new per-edition
snapshot after successful runs, including weekly rebuilds. Package-name
validation runs once inside the build entry point, and ISO uploads disable
additional artifact compression.

---

## License

Sensible source (installer, live-build config, docs, configs) is **[MIT](LICENSE)**. Take it, remix it, ship it.

That covers **this repository only**. A built ISO is a pile of Debian packages, each under its own license — GPL kernel, various firmware, Firefox MPL, and so on. Redistributing the ISO means honoring those terms; MIT does not relicense them.
