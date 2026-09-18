# Install Sensible

This guide takes you from a release download to the first boot. Sensible is an
amd64 Debian Testing installer that uses the whole selected disk.

## Before you start

> **Back up anything you need. The installer permanently erases the entire
> selected disk.** It does not preserve another operating system on that
> disk, create a dual-boot setup, or offer manual partitioning. Disconnect
> drives you do not intend to erase if practical.

The installer targets only the selected disk, but also updates the computer's
firmware boot entries. A computer with two drives can keep Windows on one and
install Sensible on the other if Windows has its own boot files. Read
[Windows on a second disk](#7-windows-on-a-second-disk) first: Windows may use
BitLocker/device encryption, and boot or firmware changes can require its
recovery key even when the Windows disk is not erased.

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
and choose either the GNOME or KDE edition. The first beta provides a `.torrent`
for each edition, seeded by the project. Open it in a BitTorrent client to
download the intact ISO, and download its matching `.iso.sha256` from the same
GitHub release. No joining or extraction is needed. A `.magnet.txt` attachment
also contains a magnet link that can be added to a torrent client. Future direct
HTTP mirrors, when available, will be linked from the release notes.

After the download, you should have these files, for example:

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
4. Secure Boot is supported through Debian's signed shim/GRUB chain. Firmware
   must trust the certificate used by the image's shim. If the USB is not
   listed, confirm that UEFI boot is enabled and Legacy/CSM is disabled.
5. A Secure Boot violation, or a return to the firmware menu before GRUB,
   can mean the firmware does not trust Microsoft's third-party UEFI CA.
   Lenovo documents this default on Windows-preinstalled
   [Secured-core PCs](https://download.lenovo.com/pccbbs/mobiles_pdf/Enable_Secure_Boot_for_Linux_Secured-core_PCs.pdf).
   In their firmware setup, open Security → Secure Boot and enable
   **Allow Microsoft 3rd Party UEFI CA**, then save and retry. Other models
   may use different names or policies; check their firmware documentation.
   **Before changing firmware settings on a Windows machine, save its BitLocker
   recovery key and suspend protection if enabled**; see
   [Windows on a second disk](#7-windows-on-a-second-disk).

Temporarily disabling Secure Boot can help isolate a trust problem, but does
not diagnose every black screen or boot failure. Re-enable it after resolving
trust if you want signature enforcement. Both the ISO and installed system
need a trusted boot chain. Firmware resets and *Restore factory keys* can
change that trust; factory defaults do not necessarily enable third-party CAs.
If the switch is already enabled, recheck the image checksum and consult the
vendor's firmware guidance: damaged media, revoked loaders and firmware bugs
can also prevent boot.

The boot menu offers two ways in:

- **Install Sensible** (default, boots after 10 seconds): a text console that
  opens the branded installer immediately. Press Enter on the welcome screen,
  then choose the keyboard layout before entering any password. If you leave
  the installer for diagnostics, start it again with `sensible-install`.
- **Try Sensible**: the same live system booted into the GNOME or KDE desktop
  of the edition you downloaded, without starting an installation. It uses
  the image's kernel, firmware and applications, so it is useful for checking
  hardware before installing (`sensible-audio-check` works here
  too). The live account is `user` with the password `live`. When ready, open
  **Install Sensible** from the dash (GNOME) or from the desktop icon and
  application menu (KDE); it runs the same installer in a terminal window.
  Keep that window open until the installer reports completion: closing it
  mid-install interrupts a partially erased disk. A disk you opened in the
  file manager is mounted and therefore excluded from installation until you
  unmount it. The normal live session is temporary; save anything you want
  to keep elsewhere before rebooting. Opening a disk and editing files on it
  can still change that disk. Live autologin and lock settings differ from the
  installed user's settings, so a successful trial does not test installed login.

Installation is offline in both modes and does not wait for a Debian mirror.
Networking can be configured with `nmtui` from the console or from the
desktop's network menu, but it is not required to complete the installation.

## 4. Make the installer choices

Read every screen rather than accepting choices blindly:

- **Target disk:** the whole selected disk will be erased. Match its path,
  capacity, model, existing volumes, filesystem labels, and mount points to the
  intended drive. Stop if anything is uncertain. Other disks, including a
  Windows disk, are not written.
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
- Log in with the username and user password created during installation. This
  password unlocks your saved-password keyring in the same step, so apps do not
  prompt again. It is the same string as the LUKS passphrase.
- If you enabled automatic login, the desktop opens after disk unlock with no
  password. This is insecure and not recommended (see below).
- Without encryption, there is no disk-unlock prompt; log in normally.

Your saved application passwords live in a keyring, managed by the Passwords
and Keys app on GNOME (KDE Wallet on KDE). Only a
password entered at login can unlock them: neither automatic login nor
fingerprint/face login supplies it, because no password reaches the system on
those paths and the disk passphrase is not available to the keyring. So the
first login after a boot uses your account password; fingerprint/face then
cover the lock screen and `sudo`. If you chose automatic login on GNOME, there
is no password to unlock the keyring, so Sensible stores it unencrypted to avoid
prompts — your saved passwords are then not protected by a password. Use
**Passwords and Keys** to put a password back on it, or to inspect saved
secrets. A keyring password can differ from the account password only if you
later change the account password with `passwd` alone; do not delete the store
if an unlock fails. The
[manual's saved-credentials guidance](../manual/index.html#desktop-credentials)
covers this and KDE's GPG-key setup error. Reusing the disk-unlock secret for
the keyring is not a supported Sensible feature.

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

## 7. Windows on a second disk

Sensible does not preserve Windows on the disk selected for installation.
A Windows installation on another disk can remain usable, provided its EFI boot
files are also on a disk you keep. Windows sometimes puts boot files on a
different disk from `C:`; if practical, confirm it boots with the intended
Sensible disk disconnected before erasing that disk.

- **Boot order:** the installer registers a `debian` firmware entry and normally
  puts it first. Use **Windows Boot Manager** in the firmware boot menu for
  Windows, or adjust the order in firmware setup. Sensible does not configure
  a Windows entry in GRUB. Chainloading Windows through GRUB can trigger
  BitLocker recovery depending on its validation policy; direct firmware boot
  is the documented route. Existing Linux entries named `debian` can be affected
  by GRUB registration even when their disks are not selected.
- **BitLocker/device encryption:** check its state before changing firmware.
  Firmware policy and boot-manager changes can cause a recovery prompt; the
  result depends on the machine's BitLocker configuration. See Microsoft's
  [recovery overview](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/recovery-overview).
  Save the 48-digit recovery key off the machine. It may be in the
  [Microsoft account used to set up Windows](https://account.microsoft.com/devices/recoverykey),
  with your work/school administrator, or in your saved backup. From an
  administrator PowerShell in Windows, inspect status and existing protectors:

  ```powershell
  manage-bde -status C:
  manage-bde -protectors -get C:
  ```

  Confirm that you have the recovery password matching the drive's key ID;
  do not post this output. **Protection Off does not mean decrypted**: it can
  mean protection is suspended while the data remains encrypted. Check
  Conversion Status and Percentage Encrypted as well. Microsoft documents the
  distinction in [GetProtectionStatus](https://learn.microsoft.com/en-us/windows/win32/secprov/getprotectionstatus-win32-encryptablevolume).

  For an encrypted, protected system drive, suspend protection before firmware
  changes. The following keeps it suspended across the required restarts:

  ```powershell
  Suspend-BitLocker -MountPoint "C:" -RebootCount 0
  ```

  Once firmware changes are complete, boot Windows directly through Windows
  Boot Manager and **resume protection promptly**:

  ```powershell
  Resume-BitLocker -MountPoint "C:"
  manage-bde -status C:
  ```

  Verify Protection On. Suspension temporarily leaves the encryption key
  available without normal TPM protection; `-RebootCount 0` stays suspended
  until you resume it. See Microsoft's
  [suspend/resume instructions](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/suspend-bitlocker-protection-non-microsoft-updates).
- **Clock:** Windows normally treats the hardware clock as local time, while
  Sensible uses UTC. If switching systems produces a time offset, make Windows
  use UTC from an administrator PowerShell:

  ```powershell
  reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
  ```

  Restart Windows. The alternative, `sudo timedatectl set-local-rtc 1` on
  Sensible, uses local time but can cause timezone/daylight-saving problems;
  [systemd recommends UTC](https://manpages.debian.org/testing/systemd/timedatectl.1.en.html).
- **Reading the Windows disk from Sensible:** Fast Startup can leave NTFS
  hibernated, preventing safe read-write access. Disable Fast Startup in Windows
  (Power Options → *Choose what the power buttons do*) and shut it down fully.
  `powercfg /h off` in an administrator terminal also disables Windows
  hibernation. These steps do not unlock BitLocker-encrypted volumes.

## Troubleshooting and support

- **No UEFI USB entry:** rewrite the image with a supported tool, disable
  Legacy/CSM, and try another USB port. Recheck the SHA256 first.
- **UEFI USB entry present, but Secure Boot refuses it:** check third-party CA
  trust as described in [Boot the live installer](#3-boot-the-live-installer).
  A firmware certificate-name scan is not a signature or revocation check and
  cannot prove that a particular loader is trusted. If using a multi-boot USB
  tool, retry a direct write of the Sensible ISO to isolate its extra boot chain.
- **Windows asks for a BitLocker recovery key:** use the matching saved key
  and boot Windows through Windows Boot Manager. Firmware or boot-policy changes
  are possible causes, not the only ones. If prompts recur, investigate the
  cause in Windows before suspending/resuming protection; do not assume entering
  the key once resolves every case. See [Windows on a second disk](#7-windows-on-a-second-disk).
- **Windows shows the wrong time after Sensible ran:** hardware clock
  convention; see [Windows on a second disk](#7-windows-on-a-second-disk).
- **No install disk:** the disk may be read-only, in use as the live medium, or
  below the RAM-dependent minimum. The installer lists why detected devices
  were rejected.
- **Copy or configuration failure:** inspect the failure screen and installer
  log. Because the disk may already be partially erased, do not assume a
  failed install left the old system recoverable.
- **Encryption passphrase fails after reboot:** check Caps Lock and the keyboard
  layout used during installation. There is no passphrase recovery mechanism.
- **Black screen after hibernation in QEMU/KVM:** the tested virtio-GPU setup
  (QEMU 11.1.1, guest kernel `7.1.13+deb14-amd64`) restored the hibernation image
  but stalled in the graphics driver. Standard VGA restored KDE successfully
  with unchanged swap sizing and resume configuration. Select VGA for a fresh
  cold boot before repeating the test (`-vga std` in a manual QEMU command).
  Do not change virtual hardware while a hibernation image is awaiting resume.
- **Secure Boot with proprietary NVIDIA:** Debian's stock boot chain remains
  signed, but the proprietary NVIDIA module may require disabling Secure Boot
  or separately enrolling a Machine Owner Key.
- **No sound, or silent speakers while headphones work:** run
  `sensible-audio-check` in a terminal on the installed system, then
  `sudo sensible-audio-check` for driver detail. It names the cause and the
  fix: a per-model amplifier tuning file missing from the installed
  `firmware-cirrus` (the usual reason on a laptop newer than Debian's firmware
  snapshot), a muted output (`sensible-audio-check --unmute`), another
  missing firmware file and the package that ships it, or a speaker amplifier
  the running kernel has no quirk for yet. The firmware and kernel cases
  affect very new laptops with Realtek codecs and Cirrus/TI amplifiers and
  clear with `sudo apt full-upgrade` once Debian Testing ships the firmware
  or kernel that knows the model. The installer shows the same finding on its
  completion screen when the live session is affected.

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
