# Plan

Sensible (aka Lazydeb) implementation order. Architecture and installer spec are frozen for v1 unless a phase hits a hard Debian constraint.

```
Phase 1  Build harness (live-build ISO, TUI live session)
    → Phase 2  Installer engine (disk + chroot + boot)
        → Phase 3  Hardware packages (firmware, PipeWire, GPU, fwupd)
            → Phase 4  Desktops + keyd + default apps
                → Phase 5  CI and releases
```

Phase 3 is hardware, Phase 4 is desktop. Do not swap those.

---

## Phase 1 — Build harness

Reproducible `live-build` in Docker/Podman. Output: a hybrid UEFI ISO that boots to a console and can see the network.

- [x] `live/Dockerfile` + `live/build.sh`
- [x] `live/auto/config`: `testing` (Forky), `main contrib non-free non-free-firmware`, `linux-image-amd64`, `iso-hybrid`, GRUB EFI
- [x] Live packages: systemd, sudo, `rsync`, `debootstrap`, `dialog` or `whiptail`, `gdisk`, `parted`, `cryptsetup`, `btrfs-progs`, `e2fsprogs`, `dosfstools`, NetworkManager, **the same firmware set as the target** (otherwise Wi-Fi laptops cannot install)
- [ ] Boot the ISO in QEMU (UEFI) and confirm a login + `nmcli` (`scripts/run-qemu.sh` & CI; CI boot smoke pending first green run)
- [x] Artifact name: `sensible-debian-testing-amd64.iso`

The live session is **not** a desktop. No GNOME/KDE on the ISO in v1. Banner and MOTD say Sensible; command is `sensible-install` (also `lazydeb`).

---

## Phase 2 — Installer engine

`installer/sensible-install.sh` against the spec. Success = reboot into a text or DE-less system with the chosen disk layout.

- [x] Pre-flight: UEFI, disk list, RAM, minimum size, type-to-confirm wipe
- [x] Four combinations: Btrfs/Ext4 × LUKS on/off, fixed 1 GiB EFI + 1 GiB BOOT + RAM+10% swap (swapfile inside the LUKS root when encrypted)
- [x] crypttab/fstab as in the spec (UUID fstab; LUKS: swapfile on encrypted root; `resume=`/`resume_offset=` for both modes)
- [x] User, hostname, locale, keyboard, timezone
- [x] GRUB EFI + `cryptsetup-initramfs` + Plymouth hook (theme can stay `spinner` until Phase 4)
- [x] Secure Boot: `shim-signed` + `grub-efi-amd64-signed` chain on the installed system and the live ISO
- [ ] QEMU: each of the four layouts boots; LUKS shows a passphrase prompt; both modes carry `resume=` in `/proc/cmdline`

---

## Phase 3 — Hardware

Make the installed system useful on a real laptop **before** polishing the DE.

- [x] Seed the package set from Architecture §6 (firmware names, PipeWire + `libspa-0.2-bluetooth`, PPD, `fwupd`)
- [x] NVIDIA detect → `nvidia-driver`
- [x] Enable NetworkManager, bluetooth, `power-profiles-daemon`, `fwupd`
- [ ] Smoke on at least one Intel and one AMD machine if available: Wi-Fi, speakers/mic, suspend (not hibernate-on-LUKS)

---

## Phase 4 — Desktop and apps

- [x] GNOME (`gnome-core`, gdm3) or Plasma (`kde-plasma-desktop`, sddm), Wayland default
- [x] Plymouth theme: spinner / breeze
- [x] Optional autologin (LUKS only, default on) + enforced idle screen lock on both DEs
- [x] `keyd` + `configs/keyd-default.conf` when Mac clipboard is on
- [x] Defaults: Firefox, VLC, Neovim + LazyVim skel, CLI set, Flatpak + Flathub
- [x] Checkboxes: Chromium, Brave origin, Audacious, Amberol/Elisa
- [x] Do not preinstall Slack/Zoom/etc.

---

## Phase 5 — CI

- [x] `.github/workflows/build-iso.yml`: container `live-build`, APT cache, QEMU UEFI boot smoke, ISO + SHA256 artifacts
- [x] Scheduled rebuilds so Testing does not rot
- [x] Tagged GitHub Releases (`sensible-debian-testing-amd64.iso` + SHA256)

---

## Later (not v1)

- Snapper on Btrfs (`@swap` already keeps the swapfile out of snapshot sets)
- GUI NVIDIA/MOK enrollment (unsigned NVIDIA module is rejected under Secure Boot lockdown)
- GUI installer
- Super+A / Super+Z if we find a terminal-safe mapping

---

## Risks

| Risk | Mitigation |
| :--- | :--- |
| Testing transition breaks the ISO | Snapshot mirror or retry; do not pin a random half of the archive |
| Wrong firmware package names | Use the Architecture list (`firmware-brcm80211`, not `firmware-broadcom`) |
| Initramfs unlock / Plymouth fail | Unencrypted `/boot`; crypttab only; `update-initramfs -u -k all`; QEMU LUKS job in Phase 2 |
| Brave or AI CLIs add untrusted install paths | Brave only from the documented origin; AI CLIs stay optional and pinned |
| Live ISO too large | No DE on the live image |
