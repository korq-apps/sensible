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

- [ ] `live/Dockerfile` + `live/build.sh`
- [ ] `live/auto/config`: `testing` (Forky), `main contrib non-free non-free-firmware`, `linux-image-amd64`, `iso-hybrid`, GRUB EFI
- [ ] Live packages: systemd, sudo, `rsync`, `debootstrap`, `dialog` or `whiptail`, `gdisk`, `parted`, `cryptsetup`, `btrfs-progs`, `e2fsprogs`, `dosfstools`, NetworkManager, **the same firmware set as the target** (otherwise Wi-Fi laptops cannot install)
- [ ] Boot the ISO in QEMU (UEFI) and confirm a login + `nmcli`
- [ ] Artifact name: `sensible-debian-testing-amd64.iso`

The live session is **not** a desktop. No GNOME/KDE on the ISO in v1. Banner and MOTD say Sensible; command is `sensible-install` (also `lazydeb`).

---

## Phase 2 — Installer engine

`installer/sensible-install.sh` against the spec. Success = reboot into a text or DE-less system with the chosen disk layout.

- [ ] Pre-flight: UEFI, disk list, RAM, minimum size, type-to-confirm wipe
- [ ] Four combinations: Btrfs/Ext4 × LUKS on/off, fixed 1 GiB EFI + 1 GiB BOOT + RAM+10% swap
- [ ] crypttab/fstab as in the spec (UUID fstab; ephemeral `cryptswap` when LUKS; `resume=` only when LUKS is off)
- [ ] User, hostname, locale, keyboard, timezone
- [ ] GRUB EFI + `cryptsetup-initramfs` + Plymouth hook (theme can stay `spinner` until Phase 4)
- [ ] QEMU: each of the four layouts boots; LUKS shows a passphrase prompt; no-LUKS resumes swap UUID in `/proc/cmdline`

---

## Phase 3 — Hardware

Make the installed system useful on a real laptop **before** polishing the DE.

- [ ] Seed the package set from Architecture §6 (firmware names, PipeWire + `libspa-0.2-bluetooth`, PPD, `fwupd`)
- [ ] NVIDIA detect → `nvidia-driver`
- [ ] Enable NetworkManager, bluetooth, `power-profiles-daemon`, `fwupd`
- [ ] Smoke on at least one Intel and one AMD machine if available: Wi-Fi, speakers/mic, suspend (not hibernate-on-LUKS)

---

## Phase 4 — Desktop and apps

- [ ] GNOME (`gnome-core`, gdm3) or Plasma (`kde-plasma-desktop`, sddm), Wayland default
- [ ] Plymouth theme: spinner / breeze
- [ ] `keyd` + `configs/keyd-default.conf` when Mac clipboard is on
- [ ] Defaults: Firefox, VLC, Neovim + LazyVim skel, CLI set, Flatpak + Flathub
- [ ] Checkboxes: Chromium, Brave origin, Audacious, Amberol/Elisa
- [ ] Do not preinstall Slack/Zoom/etc.

---

## Phase 5 — CI

- [ ] `.github/workflows/build-iso.yml`: container `live-build`, APT cache, QEMU UEFI boot smoke, ISO + SHA256 artifacts
- [ ] Scheduled rebuilds so Testing does not rot
- [ ] Tagged GitHub Releases (`sensible-debian-testing-amd64.iso` + SHA256)

---

## Later (not v1)

- Secure Boot (`shim-signed`)
- Hibernation when root is LUKS (swapfile + `resume_offset`)
- Snapper on Btrfs
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
