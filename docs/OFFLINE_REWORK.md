# Offline install rework (v2)

Design record for the pivot away from a network installer. The implemented
flow is described below and in [PLAN.md](PLAN.md) and
[INSTALLER_SPEC.md](INSTALLER_SPEC.md).

The original graphical live-session and GNOME first-boot account proposals
are superseded: both images boot into the console installer, and both create
the account, hostname, timezone, and locale during installation.

## Why

The installer resolved package names **at install time, against Debian
Testing, on the user's machine, after the disk was already wiped**. Testing
renames and drops packages continuously, so this is a permanent source of
failure rather than bad luck:

- `vdpau-driver-all` was removed from Testing. `apt` exited 100 and took the
  whole hardware stage with it, on every machine, after partitioning.
- `brave-browser` is not a Debian package at all; it needs a third-party origin
  fetched over the network mid-install.

Requiring the network also forces a Wi-Fi configuration step into the
installer, which is a poor experience precisely for the people this project
targets.

Offline inverts the failure: every package is resolved **when we build the
ISO**, so a missing package is a build failure on our machine instead of a
wiped disk on the user's.

## Decisions

| Decision | Choice | Consequence |
| :--- | :--- | :--- |
| Offline model | Copy the live root | Deploy with `rsync`, then purge live-only packages locally with `dpkg`; no package downloads |
| Variants | Two ISOs: GNOME (base), KDE (alternative) | Parameterised build, two artifacts, two CI builds; the installer never asks which desktop |
| Live session | Branded console installer | The selected desktop is carried in the image and starts on the installed system |
| Identity setup | Shared installer forms for GNOME and KDE | Account, hostname, timezone, and locale are configured before first boot |
| Third-party setup | Out of the installer, into a post-install tool | Brave and the Flathub remote need network and third-party origins; Debian's Chromium and Flatpak packages are baked into the ISO |
| TUI toolkit | `gum` | In Testing `main`, depends only on `libc6` (~21 MB) |
| Swap | Swapfile inside root, mirroring RAM; no swap partition | Encryption no longer changes the partition layout; minimum disk still scales with RAM |

### Historical size estimates (before the expanded desktop app set)

| Full target closure | Packages | Installed | ~squashfs |
| :--- | ---: | ---: | ---: |
| GNOME + firmware + kernel + boot stack | 1194 | 3.50 GiB | ~1.3 GiB |
| KDE Plasma + same | 1307 | 4.31 GiB | ~1.6 GiB |

The original desktop-less ISO measured 1.29 GB, mostly firmware. Estimates of
2.0 GB (GNOME) and 2.3 GB (KDE) predate the expanded default applications and
are not measurements of current release candidates.

## Target architecture

The ISO carries a complete, ready-to-run system. Installation copies it.

```
build:    live-build (variant=gnome|kde) -> full desktop squashfs + firmware
boot:     branded console installer
setup:    keyboard -> account -> disk -> filesystem -> encryption -> confirm
install:  partition -> format -> rsync live root -> de-live -> configure target
          -> GRUB -> update-initramfs -> verify -> reboot
first run: log into the account created by the installer (both editions)
```

No `apt` runs during installation, and nothing is fetched.

### De-living the copied root

The live root is not a target root. The copy must remove, in the chroot:

- `live-boot`, `live-config` and the live-only initramfs hooks
- the live `user` account and its passwordless sudo drop-in
- autologin drop-ins for `getty@tty1` and `serial-getty@ttyS0`
- `/etc/machine-id` (truncate; systemd regenerates on first boot)
- the live session's display-manager autologin

and must add or regenerate:

- `/etc/fstab` and `/etc/crypttab` for the real layout
- the initramfs, so `cryptsetup` support is present for LUKS unlocking
- GRUB, installed to the ESP of the target disk

Because nothing can be downloaded, `cryptsetup-initramfs`, `shim-signed` and
`grub-efi-amd64-signed` **must ship in the ISO**, not be installed on demand.

### Installer flow

Both desktop editions use the same flow:

1. Keyboard layout (needed before any passphrase is typed)
2. Account, password, hostname, timezone, locale, and optional name/email
3. Target disk and filesystem (Btrfs or Ext4)
4. Encryption (default on; uses the account password), optional encrypted autologin,
   and destructive confirmation

Desktop and app defaults are selected at build time: no application checklist
or keyd question. The initial rework proposed fixing
Btrfs too, but the existing Btrfs/Ext4 choice was retained because both paths
are fully offline and use packages already carried by the image.

## Build system

`live/auto/config` becomes variant-aware, selected by an environment variable
so CI and local builds share one path:

- `SENSIBLE_VARIANT=gnome` (default) or `kde`
- package lists split into a shared base plus `desktop-gnome` / `desktop-kde`
- artifacts named `sensible-<variant>-debian-testing-amd64.iso`
- the boot splash and `/etc/issue` name the variant

A build-time package-name check fails if an archive query fails or a requested
name is absent. It does not solve dependencies; live-build installs the package
set during image creation. Runtime pre-flight checks boot package status and
non-empty, version-matched kernel/initramfs pairs. These checks do not yet
validate every desktop package or staged asset.

## Testing

- Unit and integration suites continue to cover installer logic with the
  copy path mocked.
- `scripts/smoke-boot.sh` gains a variant argument and boots both ISOs
  (`uefi` and `sb` firmware modes already exist).
- Planned release-blocking acceptance checks install to scratch disks in QEMU and boot the
  *installed* system, not just the live medium. `validate_installed_boot`
  already asserts the artifacts; this proves them against real firmware.

## Phasing

Original sequencing, retained as history. Items 3 and 4 were superseded by
the console/shared-account flow above. Release readiness is governed by the
unchecked acceptance gates in PLAN.md, not by completion of these steps.

1. **Variant build** — parameterise `live-build`, produce the GNOME ISO with a
   full desktop, keep the existing TTY installer. Adds the build-time package
   closure check.
2. **Copy install** — switch the installer to the live-root copy path, add
   de-living, drop all `apt` calls from the install path.
3. **Graphical live session** — desktop live session with an Install launcher.
4. **Prompt rework** — `gum`, the reduced screen set, and first-boot
   delegation on GNOME.
5. **KDE variant** — second ISO and its account-creation path.
6. **Post-install app tool** — `sensible-apps` for Brave, optional alternatives,
   and Flathub remote setup.

## Open questions

- ~~Swap.~~ **Settled:** no swap partition. Swap is a swapfile inside the root
  filesystem in both modes, sized to mirror RAM, so it is encrypted with the
  root when LUKS is on and the partition layout is identical either way. The
  minimum disk stays RAM-dependent (~30 GiB at 8 GiB RAM), so **test VMs need
  ~40 GiB**.
- First-boot identity delegation and a graphical "try without installing"
  session are outside the current console-installer design.
