# Tests

```bash
tests/run-tests.sh    # no root, no container, no network
```

Requires Bash, the usual command-line utilities, and Python 3.9+ (standard
library only) for multi-page manual and desktop-app validation, plus `tar` and
`unzip` for pinned-artifact fixtures. No Python packages are needed.

## What is covered

### Unit tests (`tests/unit/`)

| Suite | Covers |
| :--- | :--- |
| `common_test.sh` | MNT override, UI tool detection (whiptail/dialog/text), logging and warning collection, text-mode widgets, network preflight, hostname/username validation, keyboard layout detection/validation/application, `check_root`/`check_uefi` |
| `disk_test.sh` | Partition naming, swap/minimum math, GPT layouts, LUKS2, Btrfs subvolumes and swapfile resume offset, Ext4, candidate filtering, stable disk-identity revalidation, mounted-disk rejection, and installer-owned cleanup |
| `fstab_test.sh` | All four engine combinations (Btrfs/Ext4 x LUKS on/off): crypttab root by LUKS header UUID, swapfile lines inside root, `@swap` subvolume mounts, tmpfs, and blkid-empty abort guards |
| `desktop_test.sh` | GNOME/KDE package sets, Plymouth spinner/breeze, gdm3/sddm enablement, keyd conf deployed from `configs/` (never generated — spec §11), hard-fail on missing conf |
| `desktop_apps_test.sh` | Real pin-staging script with tiny cached artifacts: checksum/identity failures, cache reuse, fixed local-deb path, license/pin staging; installed-version/asset hook failures; both editions' firewall rules and failure propagation; edition ownership |
| `apps_test.sh` | Canonical default app set (Architecture §7), Flathub, LazyVim skel + user copy + ownership, Brave official apt origin + signed keyring, quoted whiptail checklist matching, amberol/elisa per tag, no Slack/Zoom/Steam/Snapd |
| `manual_test.sh` | Offline chapter assets/links, current app-list coverage, both build paths, missing payload rejection, launcher fallback/retry/idempotency, and scoped per-user autostart ownership |
| `syntax_test.sh` | `bash -n` over every shell script in the repo, executable bits, live-build hook naming (`*.hook.{chroot,binary}` — anything else is silently skipped), and direct-file/release CI guards |
| `ci_runtime_test.sh` | Smoke-test early readiness, deadline failures, premature guest exits, settling, QEMU cancellation, and named-container status/cleanup using process mocks |
| `build_cache_test.sh` | Real stage-driver filesystem operations with mocked build commands: clean state, package-only cache restore, successful snapshot refresh, and preservation of the prior snapshot after failure |
| `package_check_test.sh` | Native Testing-only APT configuration, host-state isolation, missing packages, archive refresh failures, and incomplete package collection |
| `verify_test.sh` | Installed boot artifacts and extracted initramfs mapping/source identity, including stale UUIDs and literal mapping-name matching |

### Integration test (`tests/integration/installer_flow_test.sh`)

Runs the installer's **entire `main()` flow** — every prompt driven through the
text-mode UI with piped answers, every external tool (`sgdisk`, `cryptsetup`,
`mkfs.*`, `blkid`, `mount`, `chroot`, `apt-get`, ...) replaced by a bash
function mock that records its invocation. Asserts, per scenario:

- Btrfs + LUKS, Intel GPU
- Btrfs + no LUKS
- Btrfs + LUKS with NVIDIA detection and KMS arguments
- Ext4 + LUKS with a root swapfile and filefrag resume offset
- Ext4 + no LUKS on the raw root partition
- Live-copy deploy path: API mountpoints remain available while live-only installer artifacts are removed
- Completion: stay-live, successful reboot request, and failed reboot fallback
- Aborts: undersized/no-disk, failed partition-table reread, missing partition devices before formatting, surviving live initramfs diversion, missing cryptsetup closure, declined destructive confirmation, and a mandatory post-wipe failure
- Re-prompts: invalid username rejected, valid accepted

Assertions cover generated files (fstab, crypttab, hostname,
locale, keyboard, grub `resume=` rules, keyd, brave origin), call sequences
(partition types/sizes, LUKS format args, live keyboard setup,
stable disk identity, group creation, sudo membership, offline closure checks, theme,
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

- **E2E installed-disk boot**: boot the ISO in QEMU, drive the real
  Gum installer, then inspect and boot the installed disk. Blocked on
  having a buildable ISO environment (podman/docker + qemu + expect). The CI
  boot smoke (`build-iso.yml`) asserts UEFI boot reaches a stable marker from
  the live serial autologin shell.
- Plymouth graphical unlock and `systemctl` behavior of the installed system.
- Desktop app startup on real GNOME/KDE sessions, file-chooser/tray integration,
  phone pairing and LocalSend transfers with UFW enabled on IPv4/IPv6 networks.
  Mocked rule tests do not prove discovery or firewall behavior on hardware.
- The local suite tests package-gate failure handling; CI performs the live
  Debian Testing archive query before each variant build.
- Native builds query a disposable Testing-only APT index; host repositories,
  installed-package records, update hooks and index files are not used or changed
  by the package gate. The native toolchain installs Python and Debian's archive
  keyring before running it.
