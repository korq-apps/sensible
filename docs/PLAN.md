# Plan

## Where we are

Phases 1-5 are implemented. The project has since pivoted to an **offline
installer** (Phase 7, design record in [OFFLINE_REWORK.md](OFFLINE_REWORK.md)),
which supersedes parts of the earlier phases: the installer no longer resolves
packages at install time, the desktop is chosen when the ISO is built rather
than asked, and third-party software leaves the install path entirely.

| | Status |
| :--- | :--- |
| Phase 7.1 variant build + package gate | **done** |
| Phase 7.2 copy install | **done** |
| Phase 7.3-7.5 live session, guided prompts, KDE | **done** |
| Phase 7.6 post-install app tool | planned |
| Release gate | blocked on automated config input, real installed-disk tests, and physical-hardware evidence |
| Phase 6 extras | re-scoped below: baked into the ISO, or moved to the post-install tool |
| Desktop profiles | agreed scope, not implemented; see [DESKTOP_PROFILES.md](DESKTOP_PROFILES.md) |
| Offline first-login manual | implemented from PR #2 on the current installer; real desktop first-login validation remains pending |

**Next step:** exercise both release variants across Btrfs/Ext4 and LUKS on/off
by installing to real QEMU disks, then boot those disks without the ISO attached.

**Desktop roadmap:** build on the offline manual and deliver
applications/dependencies, the GNOME profile, the KDE profile,
and selected themes/backup workflow as focused changes. The agreed scope is
recorded in [DESKTOP_PROFILES.md](DESKTOP_PROFILES.md); it does not waive the
release gate or claim these additions are already shipped.

---

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
- [x] `scripts/smoke-boot.sh` and CI boot the ISO in headless UEFI QEMU and assert a stable marker from the live serial autologin shell; this is an ISO-boot smoke, not an installed-disk test
- [x] Artifact names: `sensible-gnome-debian-testing-amd64.iso` and `sensible-kde-debian-testing-amd64.iso`

The live session boots to the console installer even though the selected GNOME
or KDE target closure is baked into its squashfs for offline copying.

---

## Phase 2 — Installer engine

`installer/sensible-install.sh` against the spec. Success = reboot into the
desktop edition baked into the selected release image.

- [x] Pre-flight: UEFI, detailed disk list, RAM, minimum size, destructive confirmation
- [x] Guided Btrfs/Ext4 × LUKS on/off choices, with one fixed three-partition GPT layout and a root-hosted swapfile
- [x] crypttab/fstab as in the spec (UUID fstab; LUKS: swapfile on encrypted root; `resume=`/`resume_offset=` for both modes)
- [x] User, hostname, locale, keyboard, timezone
- [x] GRUB EFI + `cryptsetup-initramfs` + Plymouth hook (theme can stay `spinner` until Phase 4)
- [x] Secure Boot: `shim-signed` + `grub-efi-amd64-signed` chain on the installed system (`grub-install` stages the signed chain + module tree under `/EFI/debian`)
- [x] Secure Boot on the **live ISO** — native live-build `--uefi-secure-boot enable`, with an enforced OVMF Secure Boot smoke path (`SMOKE_FIRMWARE=sb`) that uses Microsoft keys and must reach the live session

The real-install matrix (GNOME/KDE × Btrfs/Ext4 × LUKS on/off) remains
unproved and is part of the release gate below. Unit and sourced-shell
integration tests do not close that gap.

---

## Phase 3 — Hardware

Make the installed system useful on a real laptop **before** polishing the DE.

- [x] Seed the package set from Architecture §6 (firmware names, PipeWire + `libspa-0.2-bluetooth`, PPD, `fwupd`)
- [x] `nvidia-driver` in the offline closure; NVIDIA detection enables its KMS argument
- [x] Enable NetworkManager, bluetooth, `power-profiles-daemon`, `fwupd`

Physical Intel and AMD smoke coverage is intentionally part of the release gate
below, not an optional follow-up.

---

## Phase 4 — Desktop and apps

- [x] GNOME (`gnome-core`, gdm3) or Plasma (`kde-plasma-desktop`, sddm), Wayland default
- [x] Plymouth theme: spinner / breeze
- [x] Optional autologin (LUKS only, default on) + enforced idle screen lock on both DEs
- [x] `keyd` + `configs/keyd-default.conf` when Mac clipboard is on
- [x] Complete desktop defaults: Firefox ESR + Chromium, LibreOffice Writer/Calc/Impress, Thunderbird, KeePassXC, VLC, Neovim + pinned LazyVim skel, archive support, CLI set, Flatpak, and native GNOME/KDE utilities
- [ ] Flathub remote setup moves to `sensible-apps`; the offline installer does
      not contact a third-party origin
- [x] Debian-packaged Chromium and the native GNOME/KDE media utilities are
      baked into their images; Brave and alternative apps remain post-install
- [x] Do not preinstall Slack/Zoom/etc.
- [ ] Implement the agreed [desktop profiles](DESKTOP_PROFILES.md): Shotwell /
      digiKam, LocalSend, GNOME extensions, native KDE equivalents and reviewed
      defaults. Keep optional theme and backup choices distinct from shipped scope.
  - [x] Application/dependency configuration: photo tools, pinned LocalSend,
        phone integration, management tools, explicit runtime deps and sharing rules.
  - [ ] Build both images; test offline app startup and actual discovery/transfer
        with UFW enabled. Record image size/build-time impact before release.
  - [ ] Curated extension activation, remaining extensions and desktop defaults.
- [x] Offline HTML manual, permanent menu launcher, and per-user first-login
      autostart, shared by both build paths; unit and mocked installer tests.
- [ ] Validate first-login opening and subsequent-login suppression on real
      installed GNOME and KDE desktops, offline.

---

## Phase 5 — CI and release plumbing

- [x] `.github/workflows/build-iso.yml`: container `live-build`, APT cache, QEMU UEFI boot smoke, ISO + SHA256 artifacts
- [x] Scheduled rebuilds so Testing does not rot
- [x] Tag-only GitHub Release job for both variant ISOs + SHA256 files, isolated from PR-controlled code and gated by repository variable `SENSIBLE_RELEASE_READY == 'true'`

The job existing is not approval to publish. Keep
`SENSIBLE_RELEASE_READY` unset or `false` until every release-gate item below
has evidence for the candidate ISO.

---

## Release gate: Beginner journey and reliability

This phase blocks release publication and comes before extras or visual
redesign. Fix the underlying behavior first; a friendlier screen cannot make an
unsafe disk operation reliable.

- [x] **Offline before wipe:** the complete target closure is baked into the ISO, so no mirror check or package download can first fail after the old system is erased
- [x] **Keyboard before secrets:** choose and apply the live keyboard layout before NetworkManager Wi-Fi credentials, the LUKS passphrase, or the account password; use that same layout in initramfs. A dedicated visual typing test belongs to the UI pass
- [x] **Robust disk identity and revalidation:** show path, model, capacity, serial/stable identity where available; exclude mounted, swap-active, RAID/LVM/device-mapper, read-only, live, and undersized media; re-read identity and state immediately before wipe and abort on any change
- [x] **Owned cleanup and live sanitization:** track mounts and mappings created by this installer run and clean only those resources; remove live autostart, commands, branding, packages/state, staged source, and reused machine identity from the target
- [x] **Truthful failures and logs:** critical failures produce failure rather than success; non-critical skipped choices are summarized; terminal/package output is retained in sudo-readable `/var/log/sensible-install.log` and copied to the target, including post-wipe failure cleanup when possible
- [x] **Beginner install guide:** `docs/INSTALL.md` covers release download/checksum, trusted USB writing, requirements, destructive scope, offline flow, choices, first boot, updates, and honest support/log expectations
- [ ] **Automated install input:** implement the validated `--config answers.toml` path below as release-test infrastructure, including explicit `confirm_wipe = true`; it belongs before the matrix rather than waiting behind the release gate
- [ ] **Real QEMU installed-boot matrix:** install each GNOME/KDE release image onto fresh virtual disks for Btrfs/Ext4 × LUKS on/off, then boot from those installed disks under UEFI (not the ISO); verify expected partitions, mounts, `fstab`/`crypttab`, swap/resume arguments, desktop/login, and the LUKS prompt where applicable. Include an installed-system Secure Boot boot
- [ ] **Physical hardware smoke:** install and first-boot the candidate on at least one Intel and one AMD amd64 UEFI machine; record disk selection, wired/Wi-Fi, graphics, audio input/output, suspend/resume, Secure Boot state, and `fwupd` detection. Document hardware unavailable for a check rather than silently treating it as passed
- [ ] **Release decision:** archive the candidate ISO checksum and matrix/hardware results, review all failures and warnings, then and only then set `SENSIBLE_RELEASE_READY` to `true` for the release tag

Partial implementation does not earn a check. The remaining unchecked items
require release-candidate virtual or physical installation evidence.

Release-blocking work is tracked in [#4: automated input](https://github.com/korq-apps/sensible/issues/4),
[#5: installed-disk QEMU matrix](https://github.com/korq-apps/sensible/issues/5)
(depends on #4), and [#6: physical hardware evidence](https://github.com/korq-apps/sensible/issues/6).
The final release decision still requires candidate checksums and reviewed results.

Additional follow-ups: [#7: back-navigation](https://github.com/korq-apps/sensible/issues/7),
[#8: Secure Boot/hibernation messaging](https://github.com/korq-apps/sensible/issues/8),
and [#9: complete offline package/asset validation](https://github.com/korq-apps/sensible/issues/9).
Current pre-flight validates boot package status and non-empty, version-matched
kernel/initramfs pairs; it does not validate the complete desktop/asset set.

**Later UI work:** after the safety mechanics above are implemented and tested,
add a guided/recommended path that explains defaults and keeps an advanced path
for explicit choices. The broader UI redesign may follow; it must not be used
to defer or waive this release gate.

---

## Phase 6 — Sensible extras (re-scoped for offline)

These were designed for a network installer that could `apt install` per-user
choices mid-run. Offline changes what each one *is*: anything from Debian is
**baked into the ISO** at build time (it costs image size, not install time,
and the package gate proves it resolves), anything third-party or optional
moves to the **post-install tool**, and the checkbox questions disappear
because the answer is decided when the image is built.

The newer [desktop profile plan](DESKTOP_PROFILES.md) establishes an explicit
exception for approved default applications/extensions sourced upstream: they
may be pinned, verified and baked at build time. This does not add downloads
to installation or first login; unselected optional software stays post-install.

The "bake into the ISO" items below live in `live/` (package lists,
`scripts/fetch-pins.sh` + `live/pins.env`, and the ufw hook), staged into the
image that the installer copies. The post-install items do not exist yet;
Architecture/spec sections mark them **(planned — post-install tool)**.

**Bake into the ISO** (Debian packages, no question asked):

- [x] Fingerprint login: `fprintd` + `libpam-fprintd` (Debian main; enrollment via GNOME/KDE settings, dormant without a reader). Already unconditional, so it simply joins the variant package list
- [x] oh-my-bash for all users: pinned clone → `/usr/share/oh-my-bash`, `configs/omb-bashrc` → `/etc/skel/.bashrc` (wires zoxide/fzf/`batcat`/`fdfind`/eza). **Offline:** fetched during the ISO build, not the install, so the pin is verified once on our machine; `/etc/skel` is populated in the image, which also removes the `useradd -m` ordering problem the network design had. `scripts/fetch-pins.sh` + `live/pins.env`
- [x] JetBrainsMono Nerd Font: pinned nerd-fonts release + SHA256 (Debian packages none). **Offline:** downloaded and checksummed at ISO build time by `scripts/fetch-pins.sh`; a rotted pin fails our build instead of a user's install. Only the four standard-spacing faces are baked, to keep the ISO small
- [x] git defaults: `configs/gitconfig` → `/etc/gitconfig` in the image. The installer still offers optional name/email for the user's `~/.gitconfig`; dropping those prompts is deferred to the first-boot/UI pass
- [x] `ufw` enabled, deny incoming / allow outgoing (config-file enable, never `ufw enable` in chroot); KDE Connect ports 1714–1764 tcp/udp allowed on KDE — `live/config/hooks/live/0300-ufw.hook.chroot`
- [x] Printing/scanning: `cups` + `ipp-usb` + `sane-airscan`; `simple-scan` (GNOME) / `skanlite` (KDE)

**Move to the post-install tool** (`sensible-apps`, online, after first boot):

- [ ] Developer tools: `docker.io` + `docker-compose` + `lazygit` + `gh`; user **not** added to the docker group (root-equivalent). Was an installer checkbox, which is exactly the kind of question the offline rework removes, and these cost nothing to add after first boot
- [ ] BioPass face login: pinned `.deb` + SHA256 from [TickLabVN/biopass](https://github.com/TickLabVN/biopass), PAM via `pam-auth-update`. Third-party and young, so it does not belong in the offline image; biometrics never unlock LUKS and fingerprint login leaves the keyring locked — both must be stated where it is offered
- [ ] Brave, Audacious, and Flathub remote setup — optional or third-party additions moved here by the offline decision

---

## Phase 7 — Offline rework (v2)

The former installer resolved packages at install time against a moving
Testing archive, which is how `vdpau-driver-all` aborted the hardware stage
after the disk was already wiped. The current flow copies a build-validated
package closure from the live image and requires no network. See
[OFFLINE_REWORK.md](OFFLINE_REWORK.md) for the design record and decision table.

- [x] Variant-aware `live-build` (`SENSIBLE_VARIANT=gnome|kde`), two ISOs, plus a build-time package-closure check that fails the build on a missing name. Also fixed the chroot device nodes rootless podman cannot create, which silently made `/dev/null` a regular file
- [x] **Install by copying the live root.** No package download or archive
  resolution occurs on the install path. The implementation:
  - take the live-root copy branch unconditionally and delete the `debootstrap` fallback, so there is one deploy path rather than two that diverge
  - de-live the copy in the chroot: purge `live-boot`/`live-config`, remove the live `user` and its passwordless sudo drop-in, drop the getty autologin drop-ins, truncate `/etc/machine-id`, restore `graphical.target`
  - regenerate what is layout-specific: `fstab`, `crypttab`, the initramfs (so `cryptsetup` support is present), and GRUB on the target ESP
  - drop the hardware/desktop/apps package stages, whose names are now fixed when the ISO is built
  - keep `validate_installed_boot` as the gate; it already asserts the artifacts this path must produce
- [x] Branded console live session that launches straight into the installer
- [x] Searchable Gum prompts with a branded welcome, detailed disk selection,
  filesystem and identity/locale choices, one destructive confirmation, and
  staged progress
- [x] GNOME and KDE build variants; both keep account creation in the installer
- [ ] `sensible-apps` post-install tool for Brave, Audacious, and Flathub remote setup

---

## Loose ends

Small, real, and not owned by any phase.

- [x] **Concurrency guard on the build.** Both build entry points now take a
      shared per-checkout `flock` before touching staged config or live-build
      state. Two `./live/build.sh` runs share
      `live/` and destroy each other: the second one's pre-clean deletes the
      first's chroot mid-debootstrap. This happened during development and cost
      two builds. A race that does not crash can also produce a half-populated ISO.
- [x] **Keep one partition layout.** Btrfs and Ext4, with LUKS on or off, all
      use EFI + BOOT + ROOT with swap inside the root filesystem. The release
      matrix still covers all four storage combinations per desktop variant.
- [ ] **Retire the `resume=` claim where Secure Boot is on.** Hibernation is
      configured and works with SB off, but the kernel refuses it under
      lockdown. The installed system should say so rather than appearing to
      support hibernation it will decline.

---

## Adopted from Omarchy

Reviewed in this session; the design record is in
[OFFLINE_REWORK.md](OFFLINE_REWORK.md). Landed already: dialogs sized to their
content (the former confirmation summary was being truncated), an actionable
failure screen with a log tail and recovery menu, errors that offer the fix
rather than a dead end, and post-install boot verification.

Worth taking, not yet taken:

- [ ] **One sourceable form module** holding every question with its validation,
      shared by the installer and any first-boot path so wording and rules
      cannot drift. This is the natural home for back-navigation
- [ ] **Back-navigation** via an explicit status protocol (`0` ok / `1` back /
      `130` side-channel), so a wrong answer on screen 3 does not mean starting
      over
- [ ] **A step runner** (`run_logged`-style): each step in its own `bash -eE`
      child with stdin closed, a machine-parseable Starting/Completed/Failed
      grammar, and a debug switch — a progress display can then read the log
- [ ] **Acceptance testing that boots the installed disk**, not just the live
      medium. Omarchy drives QEMU via QMP with OCR and virtual keystrokes;
      `validate_installed_boot` asserts the artifacts, but nothing yet proves
      them against real firmware

---

## Later (not v1)

- **Separate follow-up after desktop apps: Btrfs snapshots and recovery.**
  Configure Snapper only when Btrfs is selected; leave Ext4 unchanged. Reuse the
  existing mounted `@snapshots` layout safely rather than blindly running
  `snapper create-config /` over `/.snapshots`. Include snapshot creation policy
  (timeline and/or APT hooks), cleanup/retention limits and a tested first baseline.
  Evaluate pinned, build-time `grub-btrfs` integration separately from permanent
  restoration: booting a snapshot is not itself a rollback. Resolve the explicit
  `subvol=@` mount, separate ext4 `/boot` and kernel/module consistency, encrypted
  root discovery (LUKS2 Argon2id), read-only boot writability and Secure Boot before
  documenting a recovery command. Do not advertise `snapper rollback` plus
  `update-grub` as sufficient for this layout. Require installed-disk reboot and
  restore evidence with LUKS on/off. Home, logs and swap are separate subvolumes;
  root snapshots do not replace personal-file backups. No target-time source
  cloning/builds or snapshot tooling added by the current desktop-app slice.
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
| Offline closure is incomplete | Validate every Debian package at build time and fail closed if the archive query itself fails |
| Mocked tests hide an unbootable install | Real GNOME/KDE × Btrfs/Ext4 × LUKS on/off installed-disk QEMU matrix is release-blocking |
| Brave or AI CLIs add untrusted install paths | Brave only from the documented origin; AI CLIs stay optional and pinned |
| BioPass is young third-party PAM code (Phase 6) | Checkbox off by default; pinned `.deb` + SHA256; PAM via `pam-auth-update` so removal is clean; `fprintd` covers fingerprint without it |
| Pinned artifacts rot (BioPass, Nerd Font, oh-my-bash, LazyVim) | Versions + SHA256 recorded in one place; CI fails loudly when a pin 404s |
| live-build silently skips misnamed hooks | Hooks must match `*.hook.{chroot,binary}`; unit test enforces the naming |
| Live ISO too large | Keep separate GNOME/KDE images and review every addition to the baked offline closure |
| Release variable is enabled without evidence | Treat matrix/hardware records as the gate; the variable is only the final switch, never proof by itself |
