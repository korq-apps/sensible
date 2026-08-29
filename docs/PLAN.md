# Plan

Sensible (aka Lazydeb) implementation order. Architecture and installer spec
are living sources of truth, not frozen contracts: update them whenever a
beginner-journey, safety, reliability, or verified platform constraint requires
a behavior change. Keep the documents and implementation synchronized.

A checked item means the current repository implements it and has direct code
or automated-test evidence. It does **not** mean the release is ready or that a
mocked installer flow proves a real disk can boot.

```
Phase 1  Build harness (live-build ISO, TUI live session)
    → Phase 2  Installer engine (disk + chroot + boot)
        → Phase 3  Hardware packages (firmware, PipeWire, GPU, fwupd)
            → Phase 4  Desktops + keyd + default apps
                → Phase 5  CI and release plumbing
                    → RELEASE GATE  Beginner journey + reliability
                        → Phase 6  Sensible extras (biometrics, shell, git, firewall, unattended)
```

Phase 3 is hardware, Phase 4 is desktop. Do not swap those.

---

## Phase 1 — Build harness

Reproducible `live-build` in Docker/Podman. Output: a hybrid UEFI ISO that boots
to a console with NetworkManager and the required live firmware available.

- [x] `live/Dockerfile` + `live/build.sh`
- [x] `live/auto/config`: `testing` (Forky), `main contrib non-free non-free-firmware`, `linux-image-amd64`, `iso-hybrid`, GRUB EFI
- [x] Live packages: systemd, sudo, `rsync`, `debootstrap`, `dialog` or `whiptail`, `gdisk`, `parted`, `cryptsetup`, `btrfs-progs`, `e2fsprogs`, `dosfstools`, NetworkManager, **the same firmware set as the target** (otherwise Wi-Fi laptops cannot install)
- [x] `scripts/smoke-boot.sh` and CI boot the ISO in headless UEFI QEMU and assert that the live system reaches the Sensible autologin/MOTD; this is an ISO-boot smoke, not an installed-disk test
- [x] Artifact name: `sensible-debian-testing-amd64.iso`

The live session is **not** a desktop. No GNOME/KDE on the ISO in v1. Banner and MOTD say Sensible; command is `sensible-install` (also `lazydeb`).

---

## Phase 2 — Installer engine

`installer/sensible-install.sh` against the spec. Success = reboot into a text or DE-less system with the chosen disk layout.

- [x] Pre-flight: UEFI, disk list, RAM, minimum size, type-to-confirm wipe
- [x] Four combinations: Btrfs/Ext4 × LUKS on/off, fixed 1 GiB EFI + 1 GiB BOOT + root; swap is a swapfile inside root mirroring RAM in both modes (encrypted with the root when LUKS is on)
- [x] crypttab/fstab as in the spec (UUID fstab; LUKS: swapfile on encrypted root; `resume=`/`resume_offset=` for both modes)
- [x] User, hostname, locale, keyboard, timezone
- [x] GRUB EFI + `cryptsetup-initramfs` + Plymouth hook (theme can stay `spinner` until Phase 4)
- [x] Secure Boot: `shim-signed` + `grub-efi-amd64-signed` chain on the installed system (`grub-install` stages the signed chain + module tree under `/EFI/debian`)
- [x] Secure Boot on the **live ISO** — native live-build `--uefi-secure-boot enable`, with an enforced OVMF Secure Boot smoke path (`SMOKE_FIRMWARE=sb`) that uses Microsoft keys and must reach the live session

The four-layout real-install matrix remains unproved and is part of the release
gate below. Unit and sourced-shell integration tests do not close that gap.

---

## Phase 3 — Hardware

Make the installed system useful on a real laptop **before** polishing the DE.

- [x] Seed the package set from Architecture §6 (firmware names, PipeWire + `libspa-0.2-bluetooth`, PPD, `fwupd`)
- [x] NVIDIA detect → `nvidia-driver`
- [x] Enable NetworkManager, bluetooth, `power-profiles-daemon`, `fwupd`

Physical Intel and AMD smoke coverage is intentionally part of the release gate
below, not an optional follow-up.

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

## Phase 5 — CI and release plumbing

- [x] `.github/workflows/build-iso.yml`: container `live-build`, APT cache, QEMU UEFI boot smoke, ISO + SHA256 artifacts
- [x] Scheduled rebuilds so Testing does not rot
- [x] Tag-only GitHub Release job for `sensible-debian-testing-amd64.iso` + SHA256, isolated from PR-controlled code and gated by repository variable `SENSIBLE_RELEASE_READY == 'true'`

The job existing is not approval to publish. Keep
`SENSIBLE_RELEASE_READY` unset or `false` until every release-gate item below
has evidence for the candidate ISO.

---

## Release gate: Beginner journey and reliability

This phase blocks release publication and comes before extras or visual
redesign. Fix the underlying behavior first; a friendlier screen cannot make an
unsafe disk operation reliable.

- [x] **Network before wipe:** before any destructive confirmation, verify usable Internet access and provide a clear `nmtui` retry/setup path; package downloads must not first reveal a network problem after the old system is erased
- [x] **Keyboard before secrets:** choose and apply the live keyboard layout before NetworkManager Wi-Fi credentials, the LUKS passphrase, or the account password; use that same layout in initramfs. A dedicated visual typing test belongs to the UI pass
- [x] **Robust disk identity and revalidation:** show path, model, capacity, serial/stable identity where available; exclude mounted, swap-active, RAID/LVM/device-mapper, read-only, live, and undersized media; re-read identity and state immediately before wipe and abort on any change
- [x] **Owned cleanup and live sanitization:** track mounts and mappings created by this installer run and clean only those resources; remove live autostart, commands, branding, packages/state, staged source, and reused machine identity from the target
- [x] **Truthful failures and logs:** critical failures produce failure rather than success; non-critical skipped choices are summarized; terminal/package output is retained in root-only `/var/log/sensible-install.log` and copied to the target, including post-wipe failure cleanup when possible
- [x] **Beginner install guide:** `docs/INSTALL.md` covers release download/checksum, trusted USB writing, requirements, destructive scope, network setup, choices, first boot, updates, and honest support/log expectations
- [ ] **Automated install input:** implement the validated `--config answers.toml` path below as release-test infrastructure, including exact `confirm_wipe`; it belongs before the matrix rather than waiting behind the release gate
- [ ] **Real QEMU four-layout boot matrix:** install the release-candidate ISO onto a fresh virtual disk for Btrfs/Ext4 × LUKS on/off, then boot from that installed disk under UEFI (not the ISO); verify expected partitions, mounts, `fstab`/`crypttab`, swap/resume arguments, desktop/login, and the LUKS prompt where applicable. Cover both GNOME and KDE across the matrix, and include an installed-system Secure Boot boot
- [ ] **Physical hardware smoke:** install and first-boot the candidate on at least one Intel and one AMD amd64 UEFI machine; record disk selection, wired/Wi-Fi, graphics, audio input/output, suspend/resume, Secure Boot state, and `fwupd` detection. Document hardware unavailable for a check rather than silently treating it as passed
- [ ] **Release decision:** archive the candidate ISO checksum and matrix/hardware results, review all failures and warnings, then and only then set `SENSIBLE_RELEASE_READY` to `true` for the release tag

Partial implementation does not earn a check. The remaining unchecked items
require release-candidate virtual or physical installation evidence.

**Later UI work:** after the safety mechanics above are implemented and tested,
add a guided/recommended path that explains defaults and keeps an advanced path
for explicit choices. The broader UI redesign may follow; it must not be used
to defer or waive this release gate.

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

---

## Phase 7 — Offline rework (v2)

The installer resolves packages at install time against a moving Testing
archive, which is how `vdpau-driver-all` aborted the hardware stage after the
disk was already wiped. Requiring the network also forces Wi-Fi setup into the
installer. See [OFFLINE_REWORK.md](OFFLINE_REWORK.md) for the design record,
measured sizes and the decision table.

- [ ] Variant-aware `live-build` (`SENSIBLE_VARIANT=gnome|kde`), two ISOs, plus a build-time package-closure check that fails the build on a missing name
- [ ] Install by copying the live root; no `apt` on the install path; de-live the copy (live-boot/live-config, live user, autologin, machine-id) and regenerate fstab/crypttab/initramfs/GRUB
- [ ] Graphical live session with an "Install Sensible" launcher
- [ ] Prompt rework on `gum`: four screens on GNOME (keyboard, disk, encryption, confirm), delegating account/locale/timezone to `gnome-initial-setup`
- [ ] KDE variant, which keeps account creation in the installer (Plasma has no first-boot wizard)
- [ ] `sensible-apps` post-install tool for Brave, Chromium and Flatpak/Flathub, which cannot run offline

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
| Initramfs unlock / Plymouth fail | Unencrypted `/boot`; crypttab only; `update-initramfs -u -k all`; release-gate QEMU LUKS installs |
| Target disk changes between selection and wipe | Stable identity plus immediate pre-wipe revalidation; block release until destructive-device tests pass |
| Network fails only after wipe | Require and retry network connectivity before destructive confirmation |
| Mocked tests hide an unbootable install | Real four-layout installed-disk QEMU matrix is release-blocking |
| Brave or AI CLIs add untrusted install paths | Brave only from the documented origin; AI CLIs stay optional and pinned |
| BioPass is young third-party PAM code (Phase 6) | Checkbox off by default; pinned `.deb` + SHA256; PAM via `pam-auth-update` so removal is clean; `fprintd` covers fingerprint without it |
| Pinned artifacts rot (BioPass, Nerd Font, oh-my-bash, LazyVim) | Versions + SHA256 recorded in one place; CI fails loudly when a pin 404s |
| live-build silently skips misnamed hooks | Hooks must match `*.hook.{chroot,binary}`; unit test enforces the naming |
| Live ISO too large | No DE on the live image |
| Release variable is enabled without evidence | Treat matrix/hardware records as the gate; the variable is only the final switch, never proof by itself |
