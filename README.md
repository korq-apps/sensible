# Sensible

**Sensible** (aka **Lazydeb**) is a Debian Testing remix — installer tooling, not a fork. A Korq project. For first-time Debian users and anyone too lazy to fight `debian-installer`.

Debian Testing (Forky), a few clear choices, working hardware, no vendor bloat. Inspired by Omarchy / Archinstall, without the extra religion.

**Installing Sensible? Start with the [download-to-first-boot guide](docs/INSTALL.md).** It covers requirements, checksum verification, USB creation, the full-disk erase warning, installer choices, and first boot.

---

## Current scope

Sensible has grown beyond the original v1 plan: offline GNOME/KDE images,
**Try Sensible**, desktop profiles, the offline manual, unattended input and
hybrid ZRAM/disk swap are implemented. The project is now preparing its **first
official beta**, with the feature scope frozen around the merged baseline.
The maintainer has completed the necessary checks on a Dell XPS 15 (2020),
Lenovo Legion 7 15ASH11, and a Ryzen 7 7800X3D desktop with 64 GB RAM and
Radeon RX 7800 XT. The [beta checklist and draft notes](docs/RELEASE.md) record
that acceptance and the remaining publication steps. Broader test coverage
is follow-up work in the [plan](docs/PLAN.md#where-we-are).

## Why this exists

Debian itself is excellent. Getting to a usable desktop is not:

1. **`debian-installer` fights simple layouts.** Raw LUKS2 + Ext4 or Btrfs without LVM is painful. Guided crypto pushes LVM.
2. **Encrypted boot looks broken.** A stock LUKS install drops to a raw text passphrase prompt instead of a graphical splash.
3. **Hardware is half-enabled.** Wi-Fi firmware, SOF laptop audio, Bluetooth codecs, GPU decode, and power profiles are extra work.
4. **Switching from macOS or Windows feels alien.** Shortcuts, app stores, and “where is Slack?” are the usual friction — not a reason to ship Basecamp.

Sensible is a **reproducible live ISO** plus a **TUI installer**. The boot menu offers **Install Sensible** (the console installer, default) and **Try Sensible** (the baked GNOME or KDE desktop as a live session without starting an installation, with the same installer one click away). It partitions the disk the way people actually want and turns on firmware and PipeWire. Separate GNOME and KDE release images provide the chosen desktop; the installer does not download or switch desktops. Selected third-party packages are pinned at build time; additional apps can come from Flathub after installation. The machine you get is Debian.

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

- **GNOME** — macOS-oriented: Wayland, gestures, dynamic workspaces. Includes **Mac copy/paste** via `keyd` (`Super+C` / `V` / `X`) so terminals do not get `SIGINT`, plus a user-overridable extension profile for monitoring, phone integration, clipboard history, a dock, battery time and screenshot OCR/QR.
- **KDE Plasma** — Windows-oriented: panel, tray, familiar window management.

The live ISO does **not** ship both desktops. Choose the GNOME or KDE release asset before writing the USB. The corresponding desktop is already baked into the offline image and copied to the target.

### Software (defaults vs optional)

**Always installed (working machine):** latest Testing kernel, full `non-free-firmware` set, microcode, PipeWire, NetworkManager, BlueZ, Flatpak, fonts, `fwupd`, Secure Boot chain on the installed system (shim + Debian-signed GRUB). Flathub is preconfigured system-wide with its signing key; app browsing/downloads require a connection, but installation does not.

**Default apps:** Firefox ESR and Chromium; ONLYOFFICE Desktop Editors; Thunderbird; KeePassXC; VLC; Neovim (LazyVim starter in `/etc/skel`); archive support; and modern CLI tools (`ripgrep`, `fd-find`, `fzf`, `bat`, `eza`, `zoxide`, `btop`, `fastfetch`). GNOME adds File Roller and Amberol; KDE adds Okular, Ark, Gwenview, Kate, KCalc, Spectacle, and Elisa. Flatpak and the desktop store integration are ready for use after installation.

ONLYOFFICE's complete official amd64 `.deb` is checksum-pinned and installed
with its dependencies at image-build time; local document editing works offline.
Free office fonts are included instead of the recommended Microsoft font
downloader. There is no extra ONLYOFFICE APT source: updates require a reviewed
new package, not an ordinary Debian upgrade. The [manual](manual/applications.html#onlyoffice)
covers usage, compatibility, updates and optional LibreOffice installation.
Both ISO builds and live UEFI smoke passed for PR #16. User validation of GNOME
and KDE is successful; targeted office acceptance remains separately tracked.

**Desktop profile additions (image configuration):** Shotwell, Extension Manager,
Tweaks and a curated GNOME extension set; digiKam, KDE Connect and Plasma System
Monitor on KDE; pinned LocalSend on both. The GNOME defaults enable Vitals,
GSConnect, Caffeine, Clipboard Indicator, Dash to Dock, Battery Time, Shotzy,
User Themes and AppIndicator support. Caffeine starts inactive, clipboard disk
caching is limited to favorites, Vitals public-IP lookup is off, and users can
override every default. The same profile is baked into the image, so the Try
Sensible live desktop shows it too. LocalSend and the four non-Debian GNOME extensions are
checksum-pinned at image-build time, not downloaded by the installer. Sharing-port
exceptions are configured on both editions; see the [manual](manual/applications.html)
for usage and privacy details. GNOME uses user-overridable Paper icons and Orchis
GTK 3 styling, with Papirus, the full Qogir icon family and Qogir/Matcha/Fluent
GTK 3/4 and Shell alternatives installed globally in `/usr/share/themes/`.
Marble and Graphite remain selectable; Shell/login-screen and libadwaita
styling are not forcibly overridden. Native KDE
profile configuration and deferred themes remain in the
[desktop profile plan](docs/DESKTOP_PROFILES.md). That plan records the successful
CI builds and 2026-09-08 GNOME/KDE user validation separately from the remaining
targeted desktop and installed-system release checks.

**Offline help:** open **Sensible Manual** from the application menu or run
`sensible-manual`. The [local HTML manual](manual/index.html) opens on the
installed user's first desktop login; failed launches retry next login. It
needs no internet connection and remains available from the menu afterward.
Its linked chapters explain [everyday application choices](manual/applications.html)
and give [terminal-tool recipes](manual/terminal-tools.html), including the
distinction between finding filenames, searching contents and filtering lists.

**Curated optional online app:** [Brave Origin](manual/applications.html#brave-origin), the separate `brave-origin` package, with its official one-line installer documented in the manual. It is not preinstalled. Audacious also remains optional/post-install; Flathub is already enabled for adding further apps.

**Not currently offered:** AI CLIs. The [AI tools follow-up plan](docs/AI_TOOLS.md)
evaluates a small open-source core versus opt-in installation, with proprietary
clients optional and a dedicated manual chapter. Any approved image artifacts
will be pinned and verified at build time, never fetched during installation
or first login.

**Included, no question asked:** fingerprint login (`fprintd`, dormant without a reader), oh-my-bash for all users with a two-line Powerline prompt, system-wide git defaults, Powerline symbols and JetBrainsMono Nerd Font, `ufw` firewall (deny incoming / allow outgoing, KDE Connect-aware), and printing/scanning (CUPS driverless + `sane-airscan`) — all baked into the image at build time.

**Unattended installation (implemented in source):** `--config` reads protected
TOML and a separate password file, retains disk-safety checks, and exits without
rebooting. See the [testing instructions](docs/INSTALL.md#unattended-installation-for-testing).
Real installed-disk tests follow; mocked flow coverage is not boot evidence.

**Planned ([shared priority queue](docs/PLAN.md#reconciled-priorities)):**
a later post-install catalog will cover approved optional apps and
developer tools (Docker + Compose, `lazygit`, `gh`); BioPass needs separate
authentication/removal validation. These are not additional installer checkboxes.

Slack, WhatsApp, Zoom, Discord, and the rest belong on **Flathub**, not in the base image.

---

## Hardware goal

Make as much hardware work as Debian Testing allows, on first boot:

- Kernel: `linux-image-amd64` plus `intel-microcode` / `amd64-microcode`
- Firmware: `firmware-linux`, `firmware-misc-nonfree`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-brcm80211`, `firmware-mediatek`, `firmware-sof-signed`, `firmware-cirrus`, `firmware-intel-sound`
- GPU: Mesa Vulkan + VA-API/VDPAU; the offline closure includes `nvidia-driver`, and NVIDIA-specific KMS configuration is enabled only when matching hardware is detected
- Audio / BT: PipeWire + WirePlumber + `libspa-0.2-bluetooth`, plus `alsa-ucm-conf` (no PipeWire package depends on it, yet Intel SOF and SoundWire laptops expose no audio device without it), `alsa-utils` and the Cirrus/TI speaker-amplifier firmware. `sensible-audio-check` names the cause of a silent laptop (muted output, missing firmware file, or a speaker amplifier the running kernel has no quirk for) and the fix; the installer runs it in the live session and shows the findings on the completion screen
- Power: `power-profiles-daemon`
- Device firmware updates: `fwupd` + LVFS
- Secure Boot: shim + Debian-signed GRUB chain on the **installed system** (NVIDIA module and hibernation are blocked under lockdown — documented in Architecture). Secure Boot on the live installer ISO is enabled via live-build (`--uefi-secure-boot enable`) and verified under OVMF with Microsoft keys (`SMOKE_FIRMWARE=sb scripts/smoke-boot.sh`): the kernel reports `secureboot: Secure boot enabled` and loads the Debian Secure Boot CA. Firmware must trust the certificate signing the image's shim; some Windows PCs disable Microsoft's third-party UEFI CA by default. See the [install guide](docs/INSTALL.md#3-boot-the-live-installer) for firmware settings and BitLocker preparation.
- Biometrics: fingerprint via `fprintd` + `libpam-fprintd` (baked; dormant without a reader). Printing/scanning (CUPS driverless + `sane-airscan`) is baked too. BioPass face login is a planned post-install opt-in.

The current target is **amd64 + UEFI**. Legacy BIOS and other architectures are unsupported.

Two audio limits sit outside the image's control, and `sensible-audio-check` names both. Laptops with a Realtek HDA codec and Cirrus CS35L56 speaker amplifiers (Lenovo, Dell and HP list the codec as ALC3306 and similar) need a per-model amplifier tuning file that linux-firmware adds after the laptop ships; the amplifier driver refuses to run without it, so on a laptop newer than the `firmware-cirrus` snapshot in the image the internal speakers stay silent while headphones work. A routine `apt full-upgrade` clears it once Debian packages the newer snapshot (the Lenovo Legion 7 15ASH11's files arrived in firmware-nonfree 20260519-1, which Debian stable does not have; the image tracks Testing). Kernel quirks for brand-new models lag the same way. Debian also packages no AMD SOF DSP firmware, so a board that routes its microphone through the AMD DSP keeps it off.

---

<a id="non-goals-v1"></a>

## Current scope boundaries

- LVM, RAID, preserving another OS on the selected disk, or manual partition editing (Windows on a separate disk needs independent boot files; see the [install guide](docs/INSTALL.md#7-windows-on-a-second-disk))
- Shipping GNOME **and** KDE on the live ISO
- Snaps, Steam, or proprietary service clients in the base image
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

<a id="repository-layout-planned"></a>

## Repository layout

```
.
├── docs/
│   ├── ARCHITECTURE.md     # layers, disk, boot, swap/LUKS decision
│   ├── PLAN.md             # phases and milestones
│   ├── INSTALL.md          # download through first boot and troubleshooting
│   └── INSTALLER_SPEC.md   # installer prompts and exact commands
├── live/                   # live-build config (Dockerfile, hooks, package lists)
├── installer/              # sensible-install.sh + lib/ modules
├── configs/                # keyd, omb-bashrc + gitconfig (baked into the image)
├── manual/                 # offline HTML help and application recipes
├── packaging/manual/       # manual launcher and first-login integration
├── scripts/                # run-qemu.sh — boot the built ISO in UEFI QEMU
└── tests/                  # unit + integration suites (tests/run-tests.sh)
```

---

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — layers, disk, boot, swap/LUKS, software
- [Installation guide](docs/INSTALL.md) — download, verify, write USB, install, and first boot
- [Installer spec](docs/INSTALLER_SPEC.md) — prompts, partitioning, chroot
- [Plan](docs/PLAN.md) — current priorities, implementation history and acceptance gates
- [First release](docs/RELEASE.md) — selected scope, candidate checklist and draft release notes
- [Offline rework](docs/OFFLINE_REWORK.md) — design history and the current offline flow
- [Desktop profiles](docs/DESKTOP_PROFILES.md) — defaults, provenance and targeted acceptance
- [Offline manual](manual/index.html) — installed-system help

Build: `./live/build.sh` (podman/docker) or `sudo ./scripts/build-native.sh` (containerless, on Debian) produces `sensible-$SENSIBLE_VARIANT-debian-testing-amd64.iso` (`SENSIBLE_VARIANT=gnome`, the default, or `kde`). Verify it the way CI does with `./scripts/smoke-boot.sh` (headless UEFI boot assertion), or launch it interactively with `./scripts/run-qemu.sh`. Tests: `tests/run-tests.sh` — no root, no network.

Interactive QEMU runs save private host/serial logs and receive automatic
pre-cleanup installer failure bundles without networking. See
[QEMU testing and diagnostic export](docs/INSTALL.md#qemu-testing-and-diagnostic-export)
for the host collection command and installed-disk boot mode.

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
validation runs once inside the build entry point. Each ISO and checksum is
uploaded as a direct, unarchived file so release assets do not incur redundant
ZIP wrapping.

---

## License

Sensible source (installer, live-build config, docs, configs) is **[MIT](LICENSE)**. Take it, remix it, ship it.

That covers **this repository only**. A built ISO is a pile of Debian packages, each under its own license — GPL kernel, various firmware, Firefox MPL, and so on. Redistributing the ISO means honoring those terms; MIT does not relicense them.
