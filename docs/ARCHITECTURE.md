# Architecture

**Sensible** (aka Lazydeb) is a Korq remix of Debian Testing (Forky): four layers, one disk layout, two desktops. The installed OS is Debian.

---

## 1. Layers

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Desktop (one variant carried in the offline ISO)   │
│   GNOME or KDE Plasma                                       │
│   GNOME: keyd Mac clipboard (Super+C/V/X)                   │
│   Flatpak · Firefox ESR · Neovim · CLI extras               │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Hardware services (on the target)                  │
│   Testing kernel + microcode + non-free firmware            │
│   PipeWire / WirePlumber / BlueZ / NetworkManager           │
│   Mesa + NVIDIA closure · fwupd · PPD                       │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: Disk, unlock, boot                                 │
│   GPT: EFI + BOOT + ROOT; swapfile inside root              │
│   ROOT = Btrfs or Ext4, optional LUKS2                      │
│   Plymouth graphical unlock (LUKS only)                     │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: Live ISO (`live-build`)                            │
│   Console installer (default) or "Try Sensible" desktop ·   │
│   firmware so Wi-Fi works · `sensible-install` (`lazydeb`) ·│
│   hybrid UEFI ISO                                           │
└─────────────────────────────────────────────────────────────┘
```

The live image is an **installer appliance** carrying the complete target closure, including one desktop variant. Installation is offline; firmware and NetworkManager remain useful for hardware support and optional diagnostics, but reaching a mirror is not a prerequisite.

The boot menu's default entry is the console installer, which the CI serial smoke test asserts. "Try Sensible" boots the same live root with `sensible.session=desktop systemd.unit=graphical.target`: the display manager auto-logs the throwaway live account into the baked desktop, `sensible-live-desktop.service` disables the idle lock for that account and pins an **Install Sensible** launcher (a `Terminal=true` entry running the same installer), and the installer strips the launcher, the unit and the live account from the target. Menu templates live in `live/config/bootloaders/`.

---

## 2. Disk layout

GPT table, no LVM. LUKS and no-LUKS differ in exactly one thing: the root
partition's type. Swap is a swapfile inside the root filesystem in both modes,
never a partition, so encryption does not change the layout.

```
/dev/nvme0n1 (example)                          LUKS on            LUKS off
├── p1  1 GiB    EF00   FAT32    /boot/efi     yes                yes
├── p2  1 GiB    8300   Ext4     /boot          yes                yes
└── p3  rest     8309/8300        /              LUKS2             plain
```

Current fixed sizes: EFI **1024 MiB**, BOOT **1024 MiB**, ROOT **remainder**,
with a swapfile inside root **mirroring detected RAM**. Keeping swap in a file
means it inherits the root's encryption without a key of its own, can be resized
without touching the partition table, and leaves the layout identical either
way. 1 GiB `/boot` is enough for a few Testing kernels plus initramfs; we are not leaving this as a 1–2 GiB range in the installer.

Partitioning and filesystem writes target the selected disk: `sgdisk --zap-all`
and `wipefs` run against that device, and GRUB uses its mounted ESP.
`grub-install --bootloader-id=debian` also updates shared UEFI NVRAM and normally
puts the Debian entry first. This is not a guarantee that all existing boot
entries stay unchanged, particularly for another installation using the same
`debian` identifier. The image does not request `os-prober` or configure Windows
chainloading. Start a separate Windows disk through Windows Boot Manager in the
firmware menu; changing the boot path or firmware policy can trigger BitLocker
recovery. The [install guide](INSTALL.md#7-windows-on-a-second-disk) covers
recovery-key preparation, clock settings and Fast Startup. Separate disks must
also have independent boot files; preserving a Windows data partition cannot
preserve an ESP erased on the selected disk.

### Btrfs

Subvolumes, then mount with `noatime,compress=zstd:1,space_cache=v2,discard=async` (`@swap` is mounted without compression — NOCOW):

| Subvolume | Mount |
| :--- | :--- |
| `@` | `/` |
| `@home` | `/home` |
| `@snapshots` | `/.snapshots` |
| `@var_log` | `/var/log` |
| `@swap` | `/swap` (swapfile host; never snapshotted) |

Ready for Snapper or Timeshift. Those tools are **not currently installed**.

### Ext4

The guided installer offers Ext4 as the traditional alternative to Btrfs. It
uses a single filesystem on the unlocked root (or raw partition),
`noatime,errors=remount-ro,discard`, and `fast_commit` at `mkfs` time.

### Why `/boot` is unencrypted

Plymouth and GRUB then work like a normal desktop: kernel and initramfs load immediately, graphical unlock follows. `GRUB_ENABLE_CRYPTODISK` and Arch-style `cryptdevice=` are **not used**. Debian unlocks via `/etc/crypttab` + `cryptsetup-initramfs`.

Tradeoff: an attacker with physical access can tamper with `/boot`. Secure Boot (§4) mitigates this: the boot chain is signature-verified, and the kernel locks down unsigned module loading.

---

## 3. Swap, LUKS, and hibernation

The rule, as implemented:

| Root encryption | Swap | Hibernation |
| :--- | :--- | :--- |
| Off | `/dev/zram0` (priority 100) ahead of a swapfile inside the plain root (`@swap` on Btrfs, priority 10), `resume=UUID=<rootfs> resume_offset=<n>` | Enabled* |
| On | `/dev/zram0` (priority 100) ahead of a swapfile **inside the LUKS root** (`@swap` subvol on Btrfs / `/swapfile` on Ext4, priority 10), `resume=UUID=<rootfs> resume_offset=<n>` | Enabled* |

`*` The installer writes resume configuration in both modes without a Secure
Boot condition. Hibernation writes an unverified resume image, so the kernel
blocks it under Secure Boot lockdown. With SB off, resume is configured, but
successful hibernation still needs hardware/driver validation.

Why the swapfile design wins:

- Swap inside the LUKS container is encrypted at rest — same protection the old ephemeral `cryptswap` gave, without giving up resume.
- The initramfs unlocks `cryptroot` first (crypttab + Plymouth), so the kernel can then read the swapfile and resume. `resume_offset` (4K pages) comes from `btrfs inspect-internal map-swapfile -r` (Btrfs) or `filefrag -v` (Ext4) at install time.
- The dedicated `@swap` subvolume keeps the swapfile out of any future snapshot set (a snapshotted swapfile breaks resume consistency).
- Plain swap next to a LUKS root would leak memory — that design is gone.

Hybrid ZRAM in front of that file (issue #11):

- `zram-tools` is in the offline closure; `/etc/default/zramswap` states `ALGO=lz4`, `PERCENT=50`, `PRIORITY=100` explicitly rather than relying on package defaults. The installer enables `zramswap.service` on the target.
- The swapfile keeps `pri=10` in fstab: routine memory pressure is absorbed by compressed RAM, the disk sees swap I/O only after ZRAM is full. `swapon --show` lists `/dev/zram0` above the file.
- Hibernation uses exactly one swap area, the swapfile named by `resume=`/`resume_offset=`. ZRAM contents are part of the memory image, so they survive a successful resume, and the swapfile must still hold the whole image; its RAM-sized allocation and the minimum-disk rule are unchanged.
- Failure mode: the service is a oneshot wanted by `multi-user.target`. If `modprobe zram` or the device setup fails, boot continues on the swapfile and `systemctl status zramswap` shows the reason. No ZRAM writeback is configured; the swapfile already plays that role.
- Measured memory-pressure, shutdown and hibernate/resume behaviour on installed systems is acceptance evidence for #11, not something the fixture tests can show.

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
- Firmware trust is a precondition for both paths: firmware must accept the
  certificate signing the image's shim, and revocation policy must permit its
  boot chain. [Debian's `shim-signed` 1.51 sources](https://sources.debian.org/src/shim-signed/1.51/)
  include Microsoft 2011 and 2023 signed inputs. This is package-source evidence,
  not a boot test of every ISO on 2023-only firmware; retain the package version
  and exact image when recording such a result. Recorded result: the 2026-09-09
  GNOME image (`.disk/info` stamp `20260909-15:00`) carries shim-signed
  1.51+16.1-2, and `sbverify --list` on its `EFI/boot/bootx64.efi` shows both
  the Microsoft Corporation UEFI CA 2011 and the Microsoft UEFI CA 2023
  signature; its `grubx64.efi` (grub2 2.14-3) is Debian-CA signed with SBAT
  `grub,5`, the latest published `SbatLevel` generation. A Lenovo laptop whose
  `db` held only the Windows, Lenovo and Option ROM certificates rejected that
  shim until the third-party CA was enabled, and booted with Secure Boot on
  afterwards.
- Some Windows PCs disable Microsoft's third-party CA by default. Lenovo
  documents **Allow Microsoft 3rd Party UEFI CA** for its
  [Secured-core PCs](https://download.lenovo.com/pccbbs/mobiles_pdf/Enable_Secure_Boot_for_Linux_Secured-core_PCs.pdf).
  Firmware updates/resets can change that policy. Enabling the appropriate
  trust setting can restore boot with Secure Boot enabled; the installer cannot
  repair a pre-GRUB firmware rejection. See the install guide for BitLocker
  preparation before firmware changes.

Caveats (documented, not solved): the proprietary **NVIDIA** module is unsigned, so with SB on the kernel's lockdown rejects it — disable SB or enroll a MOK for DKMS. Lockdown also blocks **hibernation** (see §3).

---

## 5. Desktops

Display manager is implied by the DE: **gdm3** with GNOME, **sddm** with Plasma. Wayland sessions are the default.

### GNOME (macOS-oriented)

Gestures, overview, dynamic workspaces. The GNOME image enables **Mac clipboard** (`keyd`).

`keyd` mapping (input-device level, DE-agnostic):

| Chord | Sends | Why |
| :--- | :--- | :--- |
| Super+C | Ctrl+Insert | Copy in GTK/Qt **and** terminals (not Ctrl+C / SIGINT) |
| Super+V | Shift+Insert | Paste in GUI and terminals |
| Super+X | Ctrl+X | Cut in GUI; inert in most terminals |

Super tap alone stays with the DE (GNOME Overview). We do **not** map Super+A / Super+Z: those become Ctrl+A / Ctrl+Z and break terminals (beginning-of-line / SIGTSTP). Same class of bug as Super+C → SIGINT.

### KDE Plasma (Windows-oriented)

Panel, launcher, tray, Alt+Tab. The KDE image leaves `keyd` disabled.

### Login: autologin with LUKS, idle lock always

Single-user, disk-encrypted desktop: the LUKS passphrase at boot is the
authentication, so the installer offers to **skip the login password**
(GDM `AutomaticLogin` / SDDM `[Autologin]`), default **on**, **only when LUKS
is enabled** — without disk encryption autologin would leave the machine wide
open. The user's password is still set (sudo, keyring, screen unlock).

Idle screen lock is always enforced, independent of the choice: GNOME gets
system dconf defaults (`idle-delay=300`, `lock-enabled`, `lock-delay=0`), KDE
gets `/etc/xdg/kscreenlockerrc` with `Autolock` + `LockOnResume` (resume from
suspend is covered). Known tradeoffs: logout logs back in immediately;
autologin alone does not supply a wallet/keyring decryption password, so secret
access may still prompt. SDDM autologin requires `Session=`
alongside `User=` — the installer writes `Session=plasma` (the Wayland
session file name); with only `User=` autologin never engages.

### Desktop wallets and saved credentials

Session authentication and decrypting saved secrets are separate operations.
Password login can unlock a matching password-backed wallet/keyring through
the desktop's PAM integration; this needs image-level verification, not just
package presence.

**GNOME autologin keyring (implemented).** Autologin gives `pam_gnome_keyring`
no password, so the first session has no login keyring and the first app to
store a secret forks its own keyring with a separate password, prompting again
per app. On a **GNOME autologin** install the installer therefore writes an
**empty-password `login` keyring** (`installer/lib/keyring.sh`, plaintext
`~/.local/share/keyrings/login.keyring` + `default`, owned by the user): the
daemon auto-unlocks it and it is the default collection from the first login, so
secret access never prompts and no second keyring appears. This is scoped to
autologin only, where the LUKS passphrase is already the access boundary; a
GNOME **password** login keeps its PAM-unlocked encrypted keyring, and **face
login without autologin** keeps an encrypted keyring asked for once per session.
`seahorse` (Passwords and Keys) ships so users can add a password to the Login
keyring, or opt other accounts into auto-unlock. KDE Wallet is separate work
(see below); this covers GNOME only.

KDE's GPG wallet backend instead requires an encryption-capable
OpenPGP key, and the KDE Wallet Service new-wallet dialog preselects GPG
(`knewwalletdialogintro.ui`, kwallet 6.28.0). The KDE live-session error
reported on 2026-09-10 is therefore the expected result of accepting that
default without a key, not a biometric or PAM failure.
[KDE backend guidance](https://docs.kde.org/stable_kf6/en/kwalletmanager/kwalletmanager/introduction.html).

Evidence from the 2026-09-10 KDE image (`kwallet6 6.28.0-1`,
`libpam-kwallet5 6.7.4-3`): `pam-auth-update` enables `pam_kwallet5.so` in
`common-auth` and `common-session`; `pam_kwallet5` derives a salted key from
the typed login password and hands it to the daemon over a private socket,
and the daemon creates a Blowfish `kdewallet` from that key when none exists,
so a password login is designed to create and unlock the wallet without any
dialog. `sddm-autologin` authenticates with `pam_permit.so` only, so an
autologin session receives no key: with no wallet yet, as in Try Sensible,
the first request opens the new-wallet dialog; an existing wallet is asked
for its password instead. kwallet-pam 6.7.x has no cached
disk-passphrase source comparable to GDM's `pam_gdm`. Real-session
verification is still owed to #29.

The correction is planned in [#29](https://github.com/korq-apps/sensible/issues/29),
not implemented by this documentation: prefer a supported password-backed
first-use path, verify Debian PAM integration on both desktops, preserve existing
wallets and keep live-user credential state out of installed accounts. Do not
silently generate private keys, remove wallet passwords or disable secret storage.

There is a supported upstream mechanism worth testing before declaring all
autologin unlock impossible: [GDM's pam_gdm](https://github.com/GNOME/gdm/blob/main/pam_gdm/pam_gdm.c)
can pass a cached cryptsetup password into PAM. The inspected Debian
`gdm3_50.2-1` build-cache package includes `pam_gdm.so` followed by
`pam_gnome_keyring.so` in `gdm-autologin`. This is configuration evidence only;
the actual initramfs cache, matching secrets and successful session unlock are
unverified. KDE/SDDM needs an independent assessment. Preserve a safe unlock
prompt when the secret is unavailable; no custom persistent password handoff.

### Biometric login

Two tiers, because fingerprint and face have very different maturity on Debian:

- **Fingerprint — always installed.** `fprintd` + `libpam-fprintd` (Debian main). Enrollment lives in GNOME Settings / Plasma System Settings; nothing to configure at install time, dormant without a supported reader.
- **Face — baked, opt-in.** [Howdy-next](BIOMETRICS.md) is compiled from pinned
  sources in a Debian Testing container and staged into both editions with its
  recognition models and the **Face Login Setup** launcher; installation touches
  no PAM service. The wizard enables login per account after a verified
  enrollment, with a timed rollback, and can turn it off again.

Facts to not relearn later:

- **Biometrics never unlock LUKS.** The Plymouth passphrase dialog at boot is untouched; face/fingerprint cover session login, lock screen, `sudo`, and polkit only.
- **Biometric authentication does not itself decrypt a password-protected wallet.** Without another supported source of the unlock secret, first access may prompt. This differs from biometric screen unlock when the session's wallet is already open; wallet locking policy still applies. See [GNOME's archived PAM explanation](https://wiki.gnome.org/Projects/GnomeKeyring/Pam) and the cross-desktop acceptance work in #29.

---

## 6. Hardware

| Area | Packages / behavior |
| :--- | :--- |
| CPU | `intel-microcode`, `amd64-microcode` |
| Firmware | `firmware-linux`, `firmware-misc-nonfree`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-brcm80211`, `firmware-mediatek`, `firmware-sof-signed`, `firmware-cirrus` (per-model CS35L41/CS35L56 speaker-amplifier tuning), `firmware-intel-sound` |
| Wi-Fi / BT | NetworkManager, `iwd` or `wpa_supplicant`, BlueZ, `libspa-0.2-bluetooth` |
| Audio | PipeWire, WirePlumber, `pipewire-pulse`, `pipewire-audio`, `pipewire-alsa`, `alsa-ucm-conf` (nothing in PipeWire depends on it; without the UCM profiles SOF and SoundWire laptops expose no device), `alsa-topology-conf`, `alsa-utils`; `sensible-audio-check` is baked as a read-only diagnostic with an opt-in `--unmute`, and the installer runs its `--summary` in the live session to record findings as completion warnings |
| GPU | `mesa-vulkan-drivers`, `va-driver-all` (VDPAU comes from `mesa-libgallium` via mesa; `vdpau-driver-all` was removed from Testing); the offline closure includes `nvidia-driver`, while NVIDIA KMS configuration is enabled only when `lspci` sees matching hardware |
| Power | `power-profiles-daemon` (not TLP — it fights PPD and both DEs) |
| Biometrics | `fprintd`, `libpam-fprintd` (baked); `howdy-next` compiled from pinned sources and baked inert, enabled per account by Face Login Setup — see §5 |
| Print / scan | `cups`, `ipp-usb` (driverless IPP-over-USB), `sane-airscan`; `simple-scan` with GNOME, `skanlite` with KDE |
| Updates | `fwupd` (LVFS), `wireless-regdb` |
| Repos on the target | `main`, `contrib`, `non-free`, `non-free-firmware` |

`firmware-broadcom` is not a Debian package name; Broadcom Wi-Fi is `firmware-brcm80211`. `firmware-linux-nonfree` is a leftover name — do not list it.

NVIDIA: the proprietary stack is baked into the offline closure because installation cannot fetch it after the live root is copied. There is no nouveau-vs-proprietary prompt. The installer adds `nvidia-drm.modeset=1` only when NVIDIA is detected — without KMS, GDM/KWin silently fall back to X11 on exactly the hardware being special-cased.

Audio: the image can only be as new as Testing's firmware and kernel. Laptops with a Realtek HDA codec and Cirrus CS35L54/56/57 speaker amplifiers (the codec vendors list as ALC3306, ALC3287 and similar) need a per-model tuning file, `cirrus/cs35l56-*-dsp1-misc-<system name>*`, that linux-firmware adds model by model; the amplifier driver refuses to run without it because the BIOS leaves the DSP unpatched, so the internal speakers stay silent while headphones work until `firmware-cirrus` catches up (`apt full-upgrade`). The kernel side is generic since 6.12, which binds any CS35L54/56/57 found in ACPI, but brand-new models can still need a quirk for lesser features such as the mic-mute LED or a ghost AMD-DSP microphone. `sensible-audio-check` checks the tuning file directly, reports an unbound amplifier with the codec subsystem ID a report needs, and the weekly rebuilds pick up firmware and kernel as they migrate. Debian packages no AMD SOF DSP firmware, so boards that route the microphone through the AMD DSP keep it off. The installer deletes the live session's `/var/lib/alsa/asound.state` so the installed system initialises its mixer from the ALSA defaults rather than from the live console's levels.

---

## 7. Software (canonical list)

Keep this list the single source of truth. README and the installer spec should not invent extra default apps.

### Base (always)

`sudo`, `locales`, `keyboard-configuration`, `console-setup`, NetworkManager, `fwupd`, Flatpak, fonts (`fonts-noto-core`, `fonts-noto-color-emoji`, `fonts-liberation`), `git`, `curl`, `ca-certificates`.

The default interactive shell uses Oh My Bash's `powerline-multiline` theme. Debian's `fonts-powerline` supplies separator glyphs; JetBrainsMono Nerd Font comes from a pinned nerd-fonts release for the prompt and LazyVim's broader icon set. The build verifies that the pinned Oh My Bash archive still contains the configured theme. UFW defaults to deny incoming / allow outgoing, with TCP/UDP 1714–1764 for GSConnect/KDE Connect and TCP/UDP 53317 for LocalSend on both editions. With Debian's IPv6-enabled UFW defaults these cover IPv4 and IPv6, across all interfaces/source addresses rather than only trusted networks. The manual documents that exposure. The Nerd Font is baked by `scripts/fetch-pins.sh` (pin + SHA256 in `live/pins.env`); the UFW hook writes rules while UFW is still disabled and flips `ENABLED=yes` in `/etc/ufw/ufw.conf` — never `ufw enable` in a chroot.

The desktop-app slice adds Shotwell, Extension Manager and Tweaks on GNOME; digiKam, KDE Connect and Plasma System Monitor on KDE. The GNOME image enables Debian's GSConnect, AppIndicator, Caffeine, Dash to Dock and User Themes extensions plus checksum-pinned Vitals, Clipboard Indicator, Battery Time and Shotzy. A system dconf database supplies user-overridable extension, titlebar and privacy defaults; it does not lock settings, and it is baked from `configs/gnome-dconf-defaults` by the build hook so the "Try Sensible" live desktop and the installed system share one profile. A build hook validates packages/assets against the installed Shell major, compiles upstream schemas and bridges Shotzy's `/usr/share/tessdata` expectation to Debian's versioned Tesseract data. Both editions gain LocalSend: its official amd64 `.deb` and license are pinned/verified during the build, then live-build's local package repository resolves dependencies. This adds no install-time download or external APT source. Pinned artifact updates require review; ordinary Debian updates do not update them. See [desktop profiles](DESKTOP_PROFILES.md) for provenance, maintenance and pending real-session acceptance.

### Default apps

| Kind | Package |
| :--- | :--- |
| Browser | Firefox ESR (`firefox-esr`) |
| Alternate browser | Chromium (`chromium`) |
| Office | ONLYOFFICE Desktop Editors (pinned official amd64 `.deb`); LibreOffice is an optional post-install alternative |
| Mail | Thunderbird |
| Passwords | KeePassXC |
| Media | VLC |
| Editor | Neovim + LazyVim starter copied to `/etc/skel/.config/nvim` |
| Archives | `7zip`, `unzip`, `zip`; File Roller on GNOME, Ark on KDE |
| GNOME utilities | The `gnome-core` PDF/image viewers, text editor, calculator, disks and calendar; plus Amberol, Shotwell, Tweaks and Extension Manager |
| KDE utilities | Okular, Gwenview, Kate, KCalc, Spectacle, and Elisa |
| CLI | `ripgrep`, `fd-find`, `fzf`, `bat`, `eza`, `zoxide`, `btop`, `fastfetch`, `jq` |

### Offline office suite

Both images replace the default LibreOffice Writer/Calc/Impress packages with
the unmodified official `onlyoffice-desktopeditors` amd64 `.deb`. The release
version, Debian control version and SHA256 are pinned in `live/pins.env`.
`fetch-pins.sh` rejects checksum/metadata mismatches before staging the package
under a fixed local-repository filename; it retains the entire upstream payload,
including editor resources, converter, templates, icons, branding and licenses.
Provenance is recorded in `/usr/share/doc/sensible-office/sources.txt`.

live-build resolves the dependencies at build time. Free DejaVu, Carlito and
Liberation fonts are included; a build-only APT preference excludes the
recommended `ttf-mscorefonts-installer` network downloader without disabling
Recommends for the rest of the image. XWayland is explicit for the upstream
X11/Qt interface, as are NSS/NSPR and PulseAudio client libraries omitted from
upstream's dependency metadata. The office hook verifies installed identity,
payload, fonts, linked libraries and desktop entry; it also rejects an accidental
second office suite or Microsoft font downloader in the image.

`/etc/xdg/mimeapps.list` supplies user-overridable office-document defaults only;
it does not change PDF or plain-text handlers. There is no account enrollment,
installer download or extra ONLYOFFICE APT repository. Debian upgrades do not
update the pinned editor: maintainers review newer artifacts for future images,
and the manual describes verified local-package updates and optional LibreOffice.
Both edition ISO builds and live UEFI smoke passed for PR #16; on 2026-09-08 the
user reported successful GNOME and KDE validation with recent changes.
Targeted document fidelity/printing, session edge cases and release
corresponding-source availability remain acceptance checks in [PLAN.md](PLAN.md).

### Offline manual

Both build entry points use `scripts/stage-manual.sh` to install local HTML/CSS,
`sensible-manual`, a permanent application-menu launcher, and an inactive
autostart template. The installer checks this payload before partitioning and
copies the template into only the installed user's autostart directory. A
successful desktop URI dispatch records a per-user marker and removes that
autostart entry; a failed dispatch retries next login. No global live-session
autostart or first-login downloads are added. The permanent launcher ignores
the marker. Actual GNOME/KDE session launch remains a real-desktop test gate.

The local manual has a main setup/recovery guide and linked application and
terminal-tool chapters. Every chapter is staged and required by the pre-wipe
payload check; tests validate local links and documented default-package coverage.

### Desktop profiles

[DESKTOP_PROFILES.md](DESKTOP_PROFILES.md) records the milestone and acceptance
evidence. Application/dependency configuration, the GNOME profile and optional
GNOME themes are now implemented in the image sources with user-overridable
defaults. Native Plasma configuration and appearance, plus backup choices,
remain planned. PR #16 passed both ISO/live-smoke jobs, and both desktop editions
have positive user validation. The profile plan distinguishes that evidence from
remaining targeted session checks and the installed-system release matrix.

### Shell (all users)

oh-my-bash from a **shared, read-only install** — not per-user clones:

- A pinned upstream commit vendored to `/usr/share/oh-my-bash` (pin + SHA256 in `live/pins.env`; staged by `scripts/fetch-pins.sh` at build time).
- `/etc/skel/.bashrc` comes from `configs/omb-bashrc`: `OSH=/usr/share/oh-my-bash`, the `powerline-multiline` theme with the shipped Powerline/Nerd Font support, auto-update off (the install is root-owned; pin updates are reviewed for future images), git/ssh completions.
- The same file **activates the CLI set we already install** — `zoxide init`, fzf keybindings, `eza` ls aliases, and `bat`/`fd` aliases for Debian's renamed `batcat`/`fdfind` binaries. Installing tools nobody wired up is not sensible.
- `/etc/skel` is populated when the ISO is built, so the installer's `useradd -m` inherits it — the ordering problem the network design had does not exist here. Root keeps the stock Debian bashrc.

### Git (all users)

System-wide defaults in `/etc/gitconfig` from `configs/gitconfig` — `init.defaultBranch=main`, `pull.rebase=true`, `push.autoSetupRemote=true`, `fetch.prune=true`, `rebase.autostash=true`. Nothing else; users override in `~/.gitconfig`.

Identity is **per-user, never system-wide**: the installer optionally asks for full name and email (also reused for the account's GECOS field) and writes the first user's `~/.gitconfig`. Skipping the prompts leaves git fully working, just without identity until the user sets it.

No credential helper is configured: Debian ships no packaged libsecret helper (`git-credential-libsecret` is not a package; the contrib helper must be compiled), and we do not build software in the installer. GitHub auth is `gh auth login` when Developer tools are selected.

### Optional software

**Not currently offered by the offline installer:** Brave Origin and Audacious. Brave Origin (`brave-origin`, distinct from regular Brave) is a curated optional online app; the manual links its official installer and explains the added APT source/key. It is not a local package input or a preinstalled browser.

GNOME's unlocked system dconf defaults select Paper icons and the Orchis GTK 3
theme. Paper, Papirus and Orchis come from Debian packages, with no Shell/GDM or
personal CSS override. The optional image collection contains Marble (six accents,
light/dark), Graphite (grey Light/Dark), and Qogir, Matcha (sea accent)
and Fluent (standard/light/dark), plus complete Qogir icon variants. All four
application-theme families include GTK 3, GTK 4 and GNOME Shell components
under `/usr/share/themes/`; Shell selection follows upstream's >=48 layout on
GNOME 50. Installing globally does not force libadwaita to use a custom theme.
`fetch-pins.sh` verifies six source archives; the adapters compile Sass and
install CSS, image assets and theme indexes in temporary directories. Upstream
installers are not run against the host or user settings. Both build paths
include Python and `sassc`; Qogir's target runtime includes the SVG loader and
icon-cache tool. KDE staging removes only named generated outputs.

The replacements omit GTK 2 and non-GNOME desktop components. Qogir/Matcha's
missing document-thumbnail image is replaced with a solid border, and Qogir's
legacy Kooha image-only button rules are omitted. Qogir GTK 4's checkmark URLs
use the actual shipped paths, and Graphite Shell includes its referenced background.
Matcha's GTK 4 and Shell CSS are retained as in the upstream installer; an exact
reviewed set of missing GTK 4 image references is reported in
`known-upstream-assets.txt`, not treated as proof the theme is unusable. New
missing files and unsafe paths still fail validation. Qogir source icons and alias trees are merged with HiDPI links and
upstream light/dark recoloring. Indexed directories and aliases must resolve
inside each set; fallback icons use shipped Papirus/Adwaita/hicolor. Licenses
and author credits are retained. Testing no longer carries Murrine; Stable is
not added to recover GTK 2. Everforest/Tokyonight/Osaka/Catppuccin and
Good-Old-Shell are retired and cleared from reused staging roots.
The image hook checks Shell 50, appearance packages and required assets, then
builds the added icon caches. Sources, licenses and build adapters accompany the
image in `/usr/share/doc/sensible-themes/`. These pinned assets are not updated
by Debian APT. Selection/reset instructions and limitations are in the manual;
both ISO builds pass and GNOME has positive user smoke feedback. Targeted
readability/accessibility, reset/persistence and session edge cases remain in
the desktop profile acceptance checklist.

**Later, not implemented:** the [AI tools plan](AI_TOOLS.md) evaluates a small
open-source CLI core versus all-opt-in delivery, with proprietary clients kept
optional. No AI tools or installer checkboxes are currently added. Approved
image artifacts would be pinned and verified at build time; optional online
recipes and desktop-client support require separate validation.

**Planned (post-install catalog):** Developer tools — `docker.io`, `docker-compose` (the v2 rewrite in Testing), `lazygit`, `gh`. Developer tools deliberately do **not** add the user to the `docker` group — membership is root-equivalent, so the default is `sudo docker` (a user can opt in later, knowing the tradeoff).

### Explicitly not installed

Steam, Slack, WhatsApp, Zoom, Discord, Spotify, Snapd, any SaaS “default client”. Flathub is preconfigured system-wide via the checked-in upstream `.flatpakrepo` (including its GPG key) in `/usr/share/flatpak/remotes.d/`. Flatpak initializes it locally during the image hook; no app metadata, apps or runtimes are downloaded by that step. GNOME Software/KDE Discover can use it once online. The installed system inherits the remote and definition from the live root; the installer does not contact Flathub.

---

## 8. Scope

**Implemented baseline:** amd64, UEFI only, single-disk wipe, Btrfs or Ext4 with LUKS on/off, separate offline GNOME and KDE images, console installation or Try Sensible with an installer launcher, selectable locales, desktop profiles, offline help and hardware enablement. Hardware coverage and release acceptance remain bounded by the evidence in [PLAN.md](PLAN.md); the original v1 boundary no longer describes the feature set.

**Unattended input:** `--config` is an adapter to the same offline installer,
not a separate execution engine. A Python `tomllib` helper reads protected
config/secret descriptors and passes a fixed NUL-delimited record through a
private pipe; Bash reuses the form validators. Config mode preserves disk
eligibility, identity revalidation and boot checks, excludes both input files
from the copy, suppresses interactive UI and exits after verification/cleanup.
There is no automatic reboot; the caller owns the next boot. Fixture evidence
does not replace installed-disk acceptance. See [INSTALLER_SPEC.md](INSTALLER_SPEC.md#unattended-mode).

**Planned (post-install tool):** developer tools (§7). Face login is baked (§5); a signed Sensible APT repository for `howdy-next` and the Sensible tools is the planned delivery path for updates between images.

**Later:** Btrfs Snapper and evaluated `grub-btrfs` recovery integration (a separate follow-up after desktop apps; see the layout/restore acceptance requirements in [PLAN.md](PLAN.md)), TPM2 LUKS auto-unlock (`systemd-cryptenroll` or clevis; PCR policy must account for the unencrypted `/boot`), FIDO2 keys for sudo/polkit (`libpam-u2f`), GUI NVIDIA/MOK enrollment flow, Calamares if someone wants a GUI, other arches.

**Scope boundaries:** LVM as the guided path, dual-DE live ISO and bundling proprietary service clients remain outside the current design. The installed system remains Debian.
