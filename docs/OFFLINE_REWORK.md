# Offline install rework (v2)

Design record for the pivot away from a network installer. Supersedes the
install-time package resolution described in [ARCHITECTURE.md](ARCHITECTURE.md)
§6 and the prompt flow in [INSTALLER_SPEC.md](INSTALLER_SPEC.md); both are
updated as phases land.

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
| Offline model | Copy the live root | The ISO *is* the finished system; install is an `rsync`, not a `dpkg` run |
| Variants | Two ISOs: GNOME (base), KDE (alternative) | Parameterised build, two artifacts, two CI builds; the installer never asks which desktop |
| Live session | Graphical, with an "Install Sensible" launcher | Users see what they are getting and have a browser and Wi-Fi GUI if they want them |
| Identity setup | Delegate to `gnome-initial-setup` on GNOME | Installer drops user/name/timezone/locale prompts on the GNOME variant |
| Third-party setup | Out of the installer, into a post-install tool | Brave and the Flathub remote need network and third-party origins; Debian's Chromium and Flatpak packages are baked into the ISO |
| TUI toolkit | `gum` | In Testing `main`, depends only on `libc6` (~21 MB) |
| Swap | Swapfile inside root, mirroring RAM; no swap partition | Encryption no longer changes the partition layout; minimum disk still scales with RAM |

### Measured sizes (Debian Testing, amd64)

| Full target closure | Packages | Installed | ~squashfs |
| :--- | ---: | ---: | ---: |
| GNOME + firmware + kernel + boot stack | 1194 | 3.50 GiB | ~1.3 GiB |
| KDE Plasma + same | 1307 | 4.31 GiB | ~1.6 GiB |

The current desktop-less ISO is already 1.29 GB, most of it the non-free
firmware set. Expect roughly **2.0 GB (GNOME)** and **2.3 GB (KDE)** — smaller
than Ubuntu's desktop ISO.

## Target architecture

The ISO carries a complete, ready-to-run system. Installation copies it.

```
build:    live-build (variant=gnome|kde) -> full desktop squashfs + firmware
boot:     live session = the real desktop, with an Install launcher
install:  partition -> format -> rsync live root -> de-live -> identity
          -> GRUB -> update-initramfs -> verify -> reboot
first run: gnome-initial-setup collects account, locale, timezone (GNOME)
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

GNOME variant — four screens:

1. Keyboard layout (needed before any passphrase is typed)
2. Target disk
3. Encryption (default on) + passphrase
4. Review and confirm the destructive action

KDE variant adds account creation (username, password) and timezone, because
Plasma has no equivalent first-boot wizard. This divergence is deliberate and
accepted; each variant uses its desktop's best flow.

Everything else becomes an opinionated default: automatic hostname, no
application checklist, no keyd question. The initial rework proposed fixing
Btrfs too, but the existing Btrfs/Ext4 choice was retained because both paths
are fully offline and use packages already carried by the image.

## Build system

`live/auto/config` becomes variant-aware, selected by an environment variable
so CI and local builds share one path:

- `SENSIBLE_VARIANT=gnome` (default) or `kde`
- package lists split into a shared base plus `desktop-gnome` / `desktop-kde`
- artifacts named `sensible-<variant>-debian-testing-amd64.iso`
- the boot splash and `/etc/issue` name the variant

A build-time check resolves the full package closure and **fails the build** if
any name is missing — the check that would have caught `vdpau-driver-all`
before it ever reached a user.

## Testing

- Unit and integration suites continue to cover installer logic with the
  copy path mocked.
- `scripts/smoke-boot.sh` gains a variant argument and boots both ISOs
  (`uefi` and `sb` firmware modes already exist).
- A new acceptance check installs to a scratch disk in QEMU and boots the
  *installed* system, not just the live medium. `validate_installed_boot`
  already asserts the artifacts; this proves them against real firmware.

## Phasing

Each phase leaves the tree releasable.

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
- Whether the KDE variant should also delegate identity setup to
  `plasma-welcome` (it does not create accounts today) or keep the installer
  path permanently.
- Whether the live session offers "try without installing" as an explicit,
  documented mode or simply happens to allow it.
