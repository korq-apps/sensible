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
- A target disk large enough for 1 GiB EFI, 1 GiB `/boot`, a swapfile equal to
  detected RAM, and at least 20 GiB for the system. For example, a machine with
  8 GiB RAM needs a target disk of at least 30 GiB.
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

Connect to the network, then install Debian updates in a terminal:

```bash
sudo apt update
sudo apt full-upgrade
```

Restart if a kernel or core system component was updated. Flathub is already
enabled system-wide on both editions, with its signing key. Use GNOME Software
or KDE Discover when online; no Flatpak apps/runtimes are preinstalled. Check it
with `flatpak remotes --system`. For an older image only, add the source online:

```bash
sudo flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
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

## QEMU testing and diagnostic export

Use an ISO built from sources containing the diagnostic collector. From the
repository on the **host**, launch a disposable virtual disk (created as 64 GiB
if absent; never point this command at a disk you need to preserve):

```bash
./scripts/run-qemu.sh --offline sensible-gnome-debian-testing-amd64.iso test-disk.qcow2
```

Omit `--offline` to use QEMU user networking. Neither mode forwards host ports
or shares a host directory. The launcher prints a fresh private `.qemu/run.*`
directory and an exact collection command. On installer failure, leave the VM
open and run that command in another **host** terminal, for example:

```bash
python3 scripts/collect-vm-logs.py .qemu/run.ABC12345
```

Replace the example directory with the printed path. The installer automatically
captures evidence **before cleanup**, saves a private archive under `/run` in
the live guest, and sends it over a dedicated virtio-serial port. This works
without networking, SSH, manual mounts, or copying output from the VM console.
Collection/export is best-effort and time-bounded (40 seconds plus a 2-second
kill grace); it never retries the failed mount or changes the original exit code.

The host directory contains:

- `diagnostics-<sha256>.tar.gz`: checksum-checked guest report, installer log,
  exact failed mount arguments, kernel messages, mount table, filesystem/device
  signatures, udev properties, boot superblock and tool versions. Each probe's
  exit status, timeout or output truncation is recorded in `report.json`.
- `host.txt`: ISO SHA256, launcher repository revision/dirty status, firmware
  hash, QEMU version and launch arguments. The ISO hash identifies the tested
  artifact; the host checkout revision is not necessarily its build revision.
- `serial.log`: serial console output (installed systems only produce it if
  configured to use a serial console).
- `qemu.log`: QEMU's own error output.

The receiver never extracts guest archives. Empty, incomplete, oversized or
corrupt transfers fail explicitly; retry an incomplete transfer once export has
finished. Bundles are limited to 32 MiB and a run's stream to 128 MiB. Host logs
survive guest shutdown; guest `/run` bundles do not. Check the local bundle path
in the installer log if export fails. Collection does not include answer files,
password files, the shell environment or `/etc/shadow`, but logs can contain
usernames, paths, UUIDs, device serials and other identifiers. **Review and redact
before sharing**, including the host/serial logs; do not post an entire run
directory indiscriminately.

For a manual report in an updated live guest's root shell (evidence is then
from the current state, not necessarily the point of failure):

```bash
python3 /opt/sensible/installer/collect-diagnostics.py --device /dev/vda2 --boot-device /dev/vda2
```

Use your actual boot partition. The same host collection command retrieves it.
An older ISO lacks this collector: rebuild once before reproducing the failure.
The transport and capture tests are not a substitute for a fresh-ISO VM run.

After a successful installation, close the VM and boot the same disk without
the ISO. The launcher preserves its UEFI variable store between runs:

```bash
./scripts/run-qemu.sh --offline --installed test-disk.qcow2
```

Host requirements: QEMU, OVMF, Python 3 and the repository's usual GNU utilities.
`QEMU_RAM`, `QEMU_CPUS`, `QEMU_DISPLAY`, `QEMU_LOG_ROOT`, `QEMU_OVMF_CODE` and
`QEMU_OVMF_VARS` override the launcher defaults. The VM remains interactive;
this does not yet automate the installed-boot acceptance matrix.

## Unattended installation for testing

This advanced mode is implemented in the current sources for installer testing;
use an ISO built with this feature. The real installed-disk boot matrix is still
pending. Interactive installation remains the default.

`sensible-install --config FILE` uses the same whole-disk installation path and
safety checks, without questions, repair shells or a completion menu. It does
not select a different desktop: the ISO edition determines that.

In the **live environment's root Bash shell**, prepare protected temporary input:

```bash
set +ax
umask 077
install -d -m 0700 /run/sensible-secrets
install -m 0600 /opt/sensible/configs/answers.example.toml /run/sensible-secrets/answers.toml
read -r -s -p 'Account and disk password (at least 8 characters): ' sensible_password
printf '\n'
printf '%s\n' "$sensible_password" > /run/sensible-secrets/password
unset sensible_password
nano /run/sensible-secrets/answers.toml
```

The variable `sensible_password` holds the hidden input briefly in this shell;
it is not exported to child processes, and `unset` removes the variable after
writing the protected file. Do not type a literal password into a command or
commit either input file. `/run` is temporary storage, not encrypted storage.

Review the disk with `lsblk`, fill in the user, locale, keyboard, filesystem and
encryption settings, and **only then set `confirm_wipe = true`**. The template's
`false` value intentionally refuses installation. Account and root recovery
use the supplied password, as does LUKS when enabled; autologin requires LUKS.
Configure the live keyboard before typing a password if it differs from the
layout you want to use after installation.

When you are certain the selected disk may be erased:

```bash
sensible-install --config /run/sensible-secrets/answers.toml
```

Both files must be root-owned regular files with mode `0600` or `0400`; symlinks,
hard links and special files are rejected. The password file contains one UTF-8
line; the optional final newline is removed, but other whitespace is preserved.
Full field and size constraints are in the [configuration contract](INSTALLER_SPEC.md#unattended-mode).

Exit status `0` means verification, log finalization and teardown succeeded.
Nonzero means failure; check the stage diagnostic and `/var/log/sensible-install.log`.
After success the machine stays in the live session. The operator or VM harness
must detach installation media and initiate the installed-disk boot separately.
Input files are excluded from the target copy and left in place for their owner
to remove; they are not automatically deleted or included in diagnostic output.
