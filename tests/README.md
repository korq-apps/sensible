# Tests

```bash
tests/run-tests.sh    # no root, no container, no network — plain bash
```

## What is covered

### Unit tests (`tests/unit/`)

| Suite | Covers |
| :--- | :--- |
| `common_test.sh` | MNT override, UI tool detection (whiptail/dialog/text), logging and warning collection, text-mode widgets, network preflight, hostname/username validation, keyboard layout detection/validation/application, `check_root`/`check_uefi` |
| `disk_test.sh` | Partition naming, swap/minimum math, GPT layouts, LUKS2, Btrfs subvolumes and swapfile resume offset, Ext4, candidate filtering, stable disk-identity revalidation, mounted-disk rejection, and installer-owned cleanup |
| `fstab_test.sh` | All four combinations (Btrfs/Ext4 x LUKS on/off): crypttab root by LUKS header UUID (LUKS: root only), swapfile line on the encrypted root, plain swap UUID, `@swap` subvol line, tmpfs, and the blkid-empty abort guards |
| `desktop_test.sh` | GNOME/KDE package sets, Plymouth spinner/breeze, gdm3/sddm enablement, keyd conf deployed from `configs/` (never generated — spec §11), hard-fail on missing conf |
| `apps_test.sh` | Canonical default app set (Architecture §7), Flathub, LazyVim skel + user copy + ownership, Brave official apt origin + signed keyring, quoted whiptail checklist matching, amberol/elisa per tag, no Slack/Zoom/Steam/Snapd |
| `syntax_test.sh` | `bash -n` over every shell script in the repo, executable bits, and live-build hook naming (`*.hook.{chroot,binary}` — anything else is silently skipped) |

### Integration test (`tests/integration/installer_flow_test.sh`)

Runs the installer's **entire `main()` flow** — every prompt driven through the
text-mode UI with piped answers, every external tool (`sgdisk`, `cryptsetup`,
`mkfs.*`, `blkid`, `mount`, `chroot`, `apt-get`, ...) replaced by a bash
function mock that records its invocation. Asserts, per scenario:

- Combo 1: Btrfs + LUKS, GNOME, keyd on, all optional apps, Intel GPU
- Combo 2: Btrfs + no LUKS, KDE, NVIDIA GPU
- Combo 3: Ext4 + LUKS, GNOME, one extra app
- Combo 4: Ext4 + no LUKS, KDE, keyd on
- Combo 5: Ext4 + LUKS, KDE, autologin accepted (SDDM `Session=` required)
- Live-copy deploy path: API mountpoints remain available while live-only installer artifacts are removed
- Aborts: offline cancellation, undersized/no-disk, declined destructive confirmation, and a mandatory post-wipe failure
- Re-prompts: invalid username rejected, valid accepted

Assertions cover generated files (fstab, crypttab, sources.list, hostname,
locale, keyboard, grub `resume=` rules, keyd, brave origin), call sequences
(partition types/sizes, LUKS format args, network checks, live keyboard setup,
stable disk identity, group creation, sudo membership, package sets, theme,
bootloader, owned teardown, and preserved failure logs), plus success/abort exit
codes.

## Testing hooks in production code (behavior-preserving)

- `MNT="${MNT:-/mnt}"` — target mount point; tests point it at a temp dir.
- `installer/sensible-install.sh` only runs `main` when executed directly
  (`[ "${BASH_SOURCE[0]}" = "$0" ]`), so tests can source it.
- `detect_keyboard_layout [file]` accepts an optional file argument.
- `LIVE_KEYBOARD_FILE` and `INSTALL_LOG` redirect live-only state into the test
  workspace.

## Not covered here (future work)

- **E2E on real hardware/virtual disk**: boot the ISO in QEMU, drive the real
  whiptail installer, then inspect (or boot) the installed disk. Blocked on
  having a buildable ISO environment (podman/docker + qemu + expect). The CI
  boot smoke (`build-iso.yml`) already asserts UEFI boot reaches the live
  autologin via serial console.
- Plymouth graphical unlock, `systemctl` behavior of the installed system,
  APT resolution of the package sets against a live Testing mirror.
