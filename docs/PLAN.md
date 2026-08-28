# Plan

Sensible (aka Lazydeb) implementation order. Architecture and installer spec are frozen for v1 unless a phase hits a hard Debian constraint.

```
Phase 1  Build harness (live-build ISO, TUI live session)
    → Phase 2  Installer engine (disk + chroot + boot)
        → Phase 3  Hardware packages (firmware, PipeWire, GPU, fwupd)
            → Phase 4  Desktops + keyd + default apps
                → Phase 5  CI and releases
                    → Phase 6  Sensible extras (biometrics, shell, git, firewall, unattended)
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
- [x] Secure Boot: `shim-signed` + `grub-efi-amd64-signed` chain on the installed system (`grub-install` stages the signed chain + module tree under `/EFI/debian`)
- [ ] Secure Boot on the **live ISO** — back in scope via `--uefi-secure-boot enable`, pending a UEFI boot test. The earlier hand-rolled attempt dropped to a `grub>` rescue prompt because the Debian signed GRUB has a fixed `/EFI/debian` prefix and needs both a bootstrap `grub.cfg` and its full module tree staged there; live-build's own support is meant to handle that, so verify with `scripts/smoke-boot.sh` (OVMF) before trusting it. See git history for the `0100-secure-boot.hook.binary` attempt.
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

## Phase 6 — Sensible extras (planned, not implemented)

Agreed additions that extend the v1 installer. Architecture/spec sections for these are marked **(planned — Phase 6)**; nothing below exists in `installer/` yet.

- [ ] Fingerprint login: `fprintd` + `libpam-fprintd` always installed (Debian main; enrollment via GNOME/KDE settings, dormant without a reader)
- [ ] BioPass face login checkbox (off): pinned `.deb` + SHA256 from [TickLabVN/biopass](https://github.com/TickLabVN/biopass), PAM via `pam-auth-update`; biometrics never unlock LUKS, and fingerprint login leaves the keyring locked — both documented
- [ ] oh-my-bash for all users: pinned clone → `/usr/share/oh-my-bash`, `configs/omb-bashrc` → `/etc/skel/.bashrc` (wires zoxide/fzf/`batcat`/`fdfind`/eza); requires moving skel population before `useradd -m` (today LazyVim is copied into the user home as a workaround)
- [ ] JetBrainsMono Nerd Font: pinned nerd-fonts release + SHA256 (Debian packages none; LazyVim and prompt themes want one)
- [ ] git defaults: `configs/gitconfig` → `/etc/gitconfig`; optional full-name/email prompts → GECOS + first user's `~/.gitconfig` (no packaged libsecret credential helper exists — do not invent one)
- [ ] `ufw` enabled, deny incoming / allow outgoing (config-file enable, never `ufw enable` in chroot); KDE Connect ports 1714–1764 tcp/udp allowed on KDE
- [ ] Printing/scanning: `cups` + `ipp-usb` + `sane-airscan`; `simple-scan` (GNOME) / `skanlite` (KDE)
- [ ] Developer tools checkbox (off): `docker.io` + `docker-compose` + `lazygit` + `gh`; user **not** added to the docker group (root-equivalent)
- [ ] `--config answers.toml` unattended mode: every prompt from a file, same validation, `confirm_wipe` must repeat the disk name — unblocks the Phase 2 QEMU install matrix in CI

---

## Later (not v1)

- Snapper on Btrfs (`@swap` already keeps the swapfile out of snapshot sets) + `grub-btrfs` boot-menu rollback
- TPM2 LUKS auto-unlock (`systemd-cryptenroll` or clevis + `clevis-initramfs`); with biometrics this completes the Windows Hello flow — PCR policy must account for the unencrypted `/boot`, and Secure Boot in v1 strengthens the measurements
- FIDO2 hardware keys for sudo/polkit (`libpam-u2f`, enrollment via `pamu2fcfg`)
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
| BioPass is young third-party PAM code (Phase 6) | Checkbox off by default; pinned `.deb` + SHA256; PAM via `pam-auth-update` so removal is clean; `fprintd` covers fingerprint without it |
| Pinned artifacts rot (BioPass, Nerd Font, oh-my-bash, LazyVim) | Versions + SHA256 recorded in one place; CI fails loudly when a pin 404s |
| live-build silently skips misnamed hooks | Hooks must match `*.hook.{chroot,binary}`; unit test enforces the naming |
| Live ISO too large | No DE on the live image |
