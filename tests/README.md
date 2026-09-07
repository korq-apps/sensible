# Tests

```bash
tests/run-tests.sh    # no root, no container, no network
```

Requires Bash, the usual command-line utilities, `tar`, `unzip`, and **Python
3.9+ with `tarfile.data_filter` available** (standard library only). The Python
version alone is insufficient: extraction filters were also
[backported to older Python releases](https://docs.python.org/3.9/library/tarfile.html#extraction-filters).
Check the interpreter's capability, as the theme builder does:

```bash
python3 -c 'import sys, tarfile; sys.exit(0 if sys.version_info >= (3, 9) and hasattr(tarfile, "data_filter") else "Python 3.9+ with tarfile.data_filter is required")'
```

No third-party Python packages are needed for the fixture tests.
Theme fixture tests double `sassc`; real theme builds require the builder's
`sassc` package as well as Python.

Office fixture tests exercise the real pin-staging flow and `0255-office` hook:
checksum/metadata/status failures, stale staged-package removal, missing editor,
converter/template/icon/license files, missing runtime fonts/libraries, failed
desktop registration, exclusion of LibreOffice/Microsoft font downloader, and
office-only MIME defaults. The tiny fixtures do not launch the real application.
ONLYOFFICE is explicitly exempted from the Debian package-name lookup; its free
font dependencies are still checked against Testing.

For release acceptance, install the pinned `.deb` and cached Testing dependencies
in a disposable container with networking disabled, run the production hook,
then test ordinary-user launches and create/save/reopen/export/print in both
real desktop sessions. Do not disable the Chromium sandbox to make a test pass.
The upstream package's undeclared NSS/NSPR and PulseAudio client libraries are
explicit dependencies; the hook rejects unresolved links even if APT succeeds.
The chroot-only APT preference must leave `ttf-mscorefonts-installer` without an
install candidate during the build and must not persist in the finished image.

### Optional real theme/icon loading check

Both optional theme checkers require Python assertions. They fail immediately
under `-O`, `-OO` or an assertion-disabling `PYTHONOPTIMIZE` setting, before GTK
imports or validation can be skipped. The rootless fixture suite tests all four
invocation forms and normal help output without requiring GTK or a display.

After staging the GNOME assets into a **disposable Debian image/container**,
install its icon/SVG dependencies (`papirus-icon-theme`, `librsvg2-common`,
`gtk-update-icon-cache`) and test-only `python3-gi`, `gir1.2-gtk-3.0`, `gir1.2-gtk-4.0`, `xvfb`
and `xauth`. Copy the staged themes/icons into that container's `/usr/share`
(not the host desktop), generate Qogir's icon caches, then run:

```bash
xvfb-run -a python3 /repo/tests/lib/check_theme_runtime.py --gtk 3
xvfb-run -a python3 /repo/tests/lib/check_theme_runtime.py --gtk 4
```

Run this inside the container's shell, or use an init-enabled container; do not
make `xvfb-run` PID 1, where its X server readiness signal can leave it waiting.

The check compares named GTK discovery against the exact installed CSS, rejects
CSS parse errors (apart from deprecation notices), renders application/folder/
symbolic icons at normal and HiDPI scales, and exercises inherited fallback icons.
It does not change user settings. It is intentionally outside the rootless,
offline fixture runner and does not replace full GNOME session acceptance.

To compare Matcha with its real manual installation, run the pinned upstream
installer **only inside that disposable container** (it also writes editor styles
outside its theme destination). From the extracted pinned Matcha repository:

```bash
mkdir -p /tmp/matcha-upstream
bash install.sh -d /tmp/matcha-upstream -t sea
python3 /repo/tests/lib/check_theme_upstream.py /tmp/matcha-upstream /usr/share/themes
```

The comparator is read-only: it requires all upstream GTK 3/4 and Shell paths,
identical symlink targets and matching file bytes, except the intentionally
compiled/adapted GTK 3 CSS. The fixture suite separately protects the restored
components, known upstream Matcha GTK 4 references, new missing-file failures,
and path confinement even for a known reference.

## What is covered

### Unit tests (`tests/unit/`)

| Suite | Covers |
| :--- | :--- |
| `common_test.sh` | MNT override, UI tool detection (whiptail/dialog/text), logging and warning collection, text-mode widgets, network preflight, hostname/username validation, keyboard layout detection/validation/application, `check_root`/`check_uefi` |
| `disk_test.sh` | Partition naming, swap/minimum math, GPT layouts, LUKS2, Btrfs subvolumes and swapfile resume offset, Ext4, candidate filtering, stable disk-identity revalidation, mounted-disk rejection, and installer-owned cleanup |
| `fstab_test.sh` | All four engine combinations (Btrfs/Ext4 x LUKS on/off): crypttab root by LUKS header UUID, swapfile lines inside root, `@swap` subvolume mounts, tmpfs, and blkid-empty abort guards |
| `desktop_test.sh` | GNOME/KDE package sets, Plymouth spinner/breeze, gdm3/sddm enablement, keyd conf deployed from `configs/` (never generated — spec §11), hard-fail on missing conf, and GNOME's unlocked dconf extension/titlebar/privacy and Paper/Orchis defaults |
| `desktop_apps_test.sh` | Real pin/theme staging with tiny cached artifacts: checksum/identity/compatibility/license/path/asset/compiler failures, Qogir/Matcha/Fluent/Graphite GTK 3/4 and Shell installation, Qogir alias overlay and light/dark recoloring, known CSS corrections, icon directory/link/index/fallback validation, cache reuse, GNOME/KDE cleanup and fixed local-deb paths; LocalSend/GNOME-profile/theme hooks, Shell-version/package/schema/OCR/icon-cache guards; static Flathub source/key and enabled-remote guards; both editions' firewall rules and edition ownership |
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
  installer through validated unattended input (#4), then inspect and boot the
  installed disk (#5). Virtualization/build tooling is also required; a passing
  ISO build alone does not provide this missing harness. The CI
  boot smoke (`build-iso.yml`) asserts UEFI boot reaches a stable marker from
  the live serial autologin shell.
- Plymouth graphical unlock and `systemctl` behavior of the installed system.
- Desktop app startup on real GNOME/KDE sessions, file-chooser/tray integration,
  phone pairing and LocalSend transfers with UFW enabled on IPv4/IPv6 networks.
  Mocked rule tests do not prove discovery or firewall behavior on hardware.
- Actual GNOME Shell extension activation, panel/multi-monitor layout, Shotzy
  OCR/QR/Lens behavior, battery/no-battery behavior, and persistence of user
  overrides through logout, reboot and package upgrades.
- Theme readability, transparency/contrast, scaling, GTK 3/4 application styling,
  return to stock, and unchanged GDM/login/lock behavior in real sessions.
- The local suite tests package-gate failure handling; CI performs the live
  Debian Testing archive query before each variant build.
- Native builds query a disposable Testing-only APT index; host repositories,
  installed-package records, update hooks and index files are not used or changed
  by the package gate. The native toolchain installs Python and Debian's archive
  keyring before running it.
