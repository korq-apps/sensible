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
- A working Internet connection during installation. Wired Ethernet is the
  simplest option; Wi-Fi can be configured from the live shell.
- AC power connected for a laptop. Do not risk losing power while a disk is
  being partitioned or packages are being installed.

## 1. Download and verify

Open the official [Sensible Releases page](https://github.com/korq-apps/sensible/releases)
and download these two assets from the same release:

- `sensible-gnome-debian-testing-amd64.iso`
- `sensible-gnome-debian-testing-amd64.iso.sha256`

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

The live environment is text-based. The installer starts after a short
countdown, applies your keyboard choice, and checks Internet access before
offering any disk. If it cannot reach Debian, choose the network-setup option,
connect with NetworkManager's text screen, and let the installer retry. You can
also press a key during the countdown, run `nmtui`, connect and exit, then run:

```bash
sensible-install
```

Wired networking normally connects automatically. Sensible checks the Debian
package server once at startup and again before the destructive confirmation.

## 4. Make the installer choices

Read every screen rather than accepting choices blindly:

- **Target disk:** the whole selected disk will be erased. Match its path,
  capacity, and model to the intended drive. Stop if anything is uncertain.
- **Filesystem:** Btrfs creates separate subvolumes and is ready for snapshot
  tools, though those tools are not installed. Ext4 is a simpler traditional
  filesystem. Both are supported.
- **Encryption:** LUKS2 protects the root filesystem and swap at rest; `/boot`
  remains unencrypted. Losing the passphrase means losing access to the data.
- **Desktop:** GNOME is the macOS-oriented choice; KDE Plasma is the
  Windows-oriented choice.
- **Mac clipboard:** optionally maps Super+C/V/X in a terminal-safe way. It is
  on by default for GNOME and off for KDE.
- **Optional software:** the implemented choices are Chromium, Brave,
  Audacious, and Amberol (GNOME) or Elisa (KDE). AI CLIs are not installer
  choices.
- **Identity:** choose the computer name, username, user password, timezone,
  locale, and keyboard layout. The user password is also used for root recovery.
- **Skip login password:** offered only with encryption. The encryption
  passphrase is still required at boot, and the user password is still needed
  for `sudo` and unlocking the screen.

The installer validates and applies the keyboard layout before asking for
either password. On first boot, the encryption prompt uses that same layout.

## 5. Confirm the wipe and install

The final summary names the target disk and repeats the erase warning. Compare
the disk path and all choices one last time. To proceed, type the exact target
disk path shown, such as `/dev/nvme0n1`. Any other input cancels the install.

After confirmation, the erase begins immediately. Terminal output reports
partitioning, copying, package installation, desktop setup, and bootloader
setup; there is not yet a single overall percentage. Downloads and package
installation can take a while. Do not power off, close the lid, remove the USB,
or interrupt the process. Wait for the explicit successful-completion dialog.

When it completes, remove the USB and reboot. If the live installer starts
again, shut down, remove the USB, and boot from the internal disk.

## 6. First boot

- With encryption enabled, expect a graphical disk-unlock prompt first. Enter
  the LUKS passphrase. This is separate from the desktop user password.
- If skip-login was enabled, the desktop opens after disk unlock. Otherwise,
  log in with the username and user password created during installation.
- Without encryption, there is no disk-unlock prompt; log in normally.

Connect to the network, then install Debian updates in a terminal:

```bash
sudo apt update
sudo apt full-upgrade
```

Restart if a kernel or core system component was updated. Use GNOME Software
or KDE Discover to add and update Flatpak applications from Flathub. For
supported device firmware, check LVFS through `fwupd`:

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
- **Package/download failure:** confirm networking with `nmtui` and retry the
  installation. Because the disk may already be partially erased, do not
  assume a failed install left the old system recoverable.
- **Encryption passphrase fails after reboot:** check Caps Lock and the keyboard
  layout used during installation. There is no passphrase recovery mechanism.
- **Secure Boot with proprietary NVIDIA:** Debian's stock boot chain remains
  signed, but the proprietary NVIDIA module may require disabling Secure Boot
  or separately enrolling a Machine Owner Key.

The installer writes a root-only log to `/var/log/sensible-install.log` in the
live session and copies it to the same path on the installed system. If a
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
UEFI/Secure Boot settings, chosen filesystem/encryption/desktop, the exact
error, and the last relevant output. Review logs before posting and remove
usernames, network names, serial numbers, and other private data. Never post
passwords or encryption passphrases.
