# Install Sensible

This guide takes you from a release download to the first boot. Sensible is an
amd64 Debian Testing installer that uses the whole selected disk.

## Before you start

> **Back up anything you need. The installer permanently erases the entire
> selected disk.** It does not preserve another operating system, create a
> dual-boot setup, or offer manual partitioning. Disconnect drives you do not
> intend to erase if practical.

You need:

- An amd64 (Intel or AMD 64-bit) computer using UEFI, not Legacy/CSM boot.
- A target disk large enough for 1 GiB EFI, 1 GiB `/boot`, swap equal to RAM
  plus 10%, and at least 20 GiB for the system. In other words, the supported
  minimum is about **22 GiB plus 110% of installed RAM** and varies by machine.
  More space is strongly recommended.
- A USB drive large enough for the ISO (8 GB is a practical choice). Writing
  the image erases the USB.
- An Internet connection is optional during installation. The release image
  contains the complete target system; networking is only needed for updates
  and additional applications after first boot.
- AC power connected for a laptop. Do not risk losing power while a disk is
  being partitioned or packages are being installed.

## 1. Download and verify

Open the official [Sensible Releases page](https://github.com/korq-apps/sensible/releases)
and choose either the GNOME or KDE edition. Download its ISO and matching
checksum from the same release, for example:

- `sensible-gnome-debian-testing-amd64.iso`
- `sensible-gnome-debian-testing-amd64.iso.sha256`

Use the `sensible-kde-...` pair instead if you want KDE Plasma. The desktop is
chosen by the release image and is not a question inside the installer.

Keep both files in the same folder. Verification detects an incomplete or
changed download. A successful check should name the ISO and say `OK` or
return `True`.

**Linux:** open a terminal in the download folder and run:

```bash
sha256sum -c sensible-gnome-debian-testing-amd64.iso.sha256
```

**macOS:** open Terminal, change to the download folder, and run:

```bash
shasum -a 256 -c sensible-gnome-debian-testing-amd64.iso.sha256
```

**Windows:** open PowerShell in the download folder and run:

```powershell
$expected = (Get-Content .\sensible-gnome-debian-testing-amd64.iso.sha256).Split()[0]
$actual = (Get-FileHash .\sensible-gnome-debian-testing-amd64.iso -Algorithm SHA256).Hash
$actual -eq $expected
```

If the result is not successful, delete both files and download them again.
Do not write or boot an ISO whose checksum does not match.

## 2. Write the USB

Use a well-known image writer. **Do not copy the ISO onto the USB as an
ordinary file**, and do not download a flashing utility from an untrusted
mirror.

- **Etcher (Linux, macOS, Windows):** choose *Flash from file*, select the ISO,
  select the USB, and flash it.
- **Rufus (Windows):** select the USB and ISO, use GPT/UEFI when offered, then
  start. If Rufus asks how to write this hybrid image, DD image mode is the
  direct image-writing option.
- **GNOME Disks (Linux):** select the USB, open the drive menu, choose *Restore
  Disk Image*, and select the ISO.
- **KDE ISO Image Writer (Linux):** select the ISO and USB, then write it.

Double-check the destination drive by capacity and name before starting. When
the writer reports success, eject the USB safely.

## 3. Boot the live installer

1. Leave the USB connected and restart the computer.
2. Open the firmware boot menu (commonly F12, F10, Esc, or Option on startup).
3. Choose the USB entry marked `UEFI`. Do not choose a Legacy or CSM entry.
4. Secure Boot is supported by the live ISO and installed system, so it can
   remain enabled. If the USB is not listed, confirm that UEFI boot is enabled
   and Legacy/CSM is disabled before changing Secure Boot settings.

The live environment is text-based and opens the branded installer
immediately. Press Enter on the welcome screen, then choose the keyboard layout
before entering any password. Installation is offline and does not wait for a
Debian mirror. If you leave the installer for diagnostics, start it again with:

```bash
sensible-install
```

Networking can still be configured with `nmtui` from the live shell, but it is
not required to complete the installation.

## 4. Make the installer choices

Read every screen rather than accepting choices blindly:

- **Target disk:** the whole selected disk will be erased. Match its path,
  capacity, model, existing volumes, filesystem labels, and mount points to the
  intended drive. Stop if anything is uncertain.
- **Filesystem:** choose Btrfs for compression, subvolumes, and future snapshot
  tooling, or Ext4 for a traditional single root filesystem. Both choices use
  a swapfile inside root and support optional LUKS encryption and hibernation.
- **Encryption:** LUKS2 protects the root filesystem and swap at rest; `/boot`
  remains unencrypted. Losing the passphrase means losing access to the data.
- **Desktop:** already selected by the GNOME or KDE release image. It is shown
  for confirmation but cannot be changed inside the offline installer.
- **Mac clipboard:** the GNOME image enables terminal-safe Super+C/V/X mapping;
  the KDE image leaves it disabled. There is no installer prompt.
- **Additional software:** no optional application checkboxes are currently
  shown. Add applications after first boot through GNOME Software, KDE
  Discover, Flatpak, or APT.
- **Identity:** choose the computer name, username, user password, timezone,
  locale, and keyboard layout. The user password is also used for root recovery.
- **Skip login password:** offered only with encryption. The encryption
  passphrase is still required at boot, and the user password is still needed
  for `sudo` and unlocking the screen.

The installer validates and applies the keyboard layout before asking for
either password. On first boot, the encryption prompt uses that same layout.

## 5. Confirm the wipe and install

The encryption screen repeats the selected disk and warns that everything on
it will be overwritten. Choose the install action to confirm, or go back and
change the disk. Text-mode fallback uses a final yes/no prompt defaulting to
No. The installer does not ask you to retype the device path.

After confirmation and one last device-identity check, the erase begins
immediately. A 12-stage progress bar shows the current operation, percentage,
and elapsed time while detailed command output is kept in
`/var/log/sensible-install.log`. Do not power off, close the lid, remove the
USB, or interrupt the process. Wait for the explicit successful-completion
screen, which reports total installation time.

When it completes, choose **Reboot now**. Optical media is ejected by the live
shutdown hook; remove USB media as the machine restarts. You may instead stay
in the live session for diagnostics.

## 6. First boot

- With encryption enabled, expect a graphical disk-unlock prompt first. Enter
  the LUKS passphrase, which is the same password created for the desktop user.
- If skip-login was enabled, the desktop opens after disk unlock. Otherwise,
  log in with the username and user password created during installation.
- Without encryption, there is no disk-unlock prompt; log in normally.
- The **Sensible Manual** is installed locally at `/usr/share/sensible/manual/`
  and is automatically opened once on first login. It can also be opened at any
  time from the application menu, or with `sensible-manual` from a terminal.

Connect to the network, then install Debian updates in a terminal:

```bash
sudo apt update
sudo apt full-upgrade
```

Restart if a kernel or core system component was updated. Use GNOME Software
or KDE Discover to add and update Flatpak applications from Flathub. Flathub
is **not** pre-configured by the offline installer: check with
`flatpak remotes` and add it when you are online:

```bash
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

For supported device firmware, check LVFS through `fwupd`:

```bash
sudo fwupdmgr refresh
sudo fwupdmgr get-updates
sudo fwupdmgr update
```

Not every device exposes firmware updates through LVFS.

## Troubleshooting and support

- **No UEFI USB entry:** rewrite the image with a supported tool, disable
  Legacy/CSM, and try another USB port. Recheck the SHA256 first.
- **No install disk:** the disk may be read-only, in use as the live medium, or
  below the RAM-dependent minimum. The installer lists why detected devices
  were rejected.
- **Copy or configuration failure:** inspect the failure screen and installer
  log. Because the disk may already be partially erased, do not assume a
  failed install left the old system recoverable.
- **Encryption passphrase fails after reboot:** check Caps Lock and the keyboard
  layout used during installation. There is no passphrase recovery mechanism.
- **Secure Boot with proprietary NVIDIA:** Debian's stock boot chain remains
  signed, but the proprietary NVIDIA module may require disabling Secure Boot
  or separately enrolling a Machine Owner Key.

The installer writes a log to `/var/log/sensible-install.log` in the live
session and copies it to the same path on the installed system. It is readable
by root and members of the `sudo` group. If a
post-wipe failure happens while the target is mounted, it also attempts to copy
the log into that partial target before cleanup. Photograph the exact failure
screen before rebooting in case the target could not be mounted. From the live
shell, these commands can provide useful non-secret context:

```bash
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS
ip link
journalctl -b --no-pager
```

Open a [GitHub issue](https://github.com/korq-apps/sensible/issues) with the
release version, whether SHA256 verification passed, hardware model, firmware
UEFI/Secure Boot settings, release edition and encryption choice, the exact
error, and the last relevant output. Review logs before posting and remove
usernames, network names, serial numbers, and other private data. Never post
passwords or encryption passphrases.
