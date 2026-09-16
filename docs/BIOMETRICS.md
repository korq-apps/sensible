# Local biometric tools

The face-login stack is baked into the Sensible image: `howdy-next` compiled
from pinned sources, its recognition models and this setup tool
(`/usr/local/bin/sensible-biometrics`, **Face Login Setup** in the menu). From a
checkout on Debian Testing amd64 the same tool also builds the package and runs
every step locally; no ISO build is needed for that. See
[Image integration](#image-integration) for what the image build does.

## Guided setup

```bash
tools/biometrics/sensible-biometrics launcher
```

Open **Face Login Setup** from the applications menu. The current launcher opens
a guided terminal wizard; users select choices and enter passwords at sudo/PAM
prompts, without typing setup commands. `sensible-biometrics setup` starts the
same flow directly.

The wizard installs the runtime if needed, selects an IR camera, previews the
image, enrolls a face and verifies a successful match.
It then enables the detected desktop's login/unlock
services, tests them, and asks the user to try the real lock screen with both
face and password before keeping the change. Administrator commands (`sudo`)
are an optional selection, off by default; enabling it means a face match runs
`sudo` without a password, with the account password kept as a fallback, so the
wizard warns before offering it. Reopening the launcher offers **Turn off face login**.

A failed face check can be retried in place, and a fresh check can be resumed
for 15 minutes if the configuration, enrollment and authentication policy are
unchanged. The account password itself is not tested before activation; it
predates this tool and is out of scope. The final lock-screen test asks
separately about face unlock, password fallback and keeping the changes.

Activation has a five-minute rollback timer. Closing the wizard, cancelling,
failing a service test or declining the final confirmation restores the previous
PAM configuration. A root-owned recovery copy outside the checkout handles
timer expiry and unconfirmed setup after a reboot. Enrollment/configuration
progress stays local so setup can resume.

Automatic activation currently supports the standard Debian local-password
stack with GDM, or SDDM plus KDE screen unlock. It refuses unfamiliar/MFA/domain
authentication policies before setup changes them. A camera that needs additional
IR emitter support stops at the preview check. Live desktop behavior still needs
the guided acceptance check on each system; automated tests do not prove it.

## PAM activation and recovery

`pam-enable` is the operation that edits the selected `/etc/pam.d/` services.
It requires a fresh `verify face` result for the same account, enrollment,
camera configuration and authentication policy.
`pam-check` tests the enabled services; `pam-confirm` keeps the change only after
those tests pass. The wizard runs these operations in order.

The generated rules restrict face authentication to the selected account and
fall back to the existing password stack on non-match, error or a missing Howdy
module. Account/session rules and service restrictions remain in place. A PAM
`substack` makes the password stack one conditional target; this follows
[Linux-PAM's control-flow semantics](https://github.com/linux-pam/linux-pam/blob/master/doc/man/pam.conf-syntax.xml).
Shared `common-auth`, SSH, console login and polkit are not edited.

```bash
tools/biometrics/sensible-biometrics pam-status
tools/biometrics/sensible-biometrics pam-disable
```

`pam-disable` restores the saved service configuration. Recovery preserves later
administrator edits outside the exact managed block. If an administrator changes
the block itself or its permissions, automatic recovery stops and retains the
original bytes in `/var/lib/sensible-biometrics/pam.json` for reconciliation.
This protects against setup failures; it is not a guarantee against arbitrary
system or administrator changes. A confirmed setup retains its recovery backup.
Unreconcilable edits stop automatic retries and leave an error in the recovery
service's journal. Transient I/O errors or a busy package manager remain retryable.
These can delay restoration beyond the nominal five-minute deadline.

Configuration writes take the APT/dpkg frontend and database locks and recheck
contents, file identity and permissions immediately before replacement. These
are advisory locks: do not manually edit Howdy or the selected PAM services
during setup or recovery. Arbitrary root writers that ignore these locks cannot
be excluded by the final check. Interactive PAM tests use a separate lock so
they do not prevent timed recovery; cleanup refuses to remove a running test.

## Build and install

```bash
tools/biometrics/sensible-biometrics deps
tools/biometrics/sensible-biometrics prepare
tools/biometrics/sensible-biometrics build --jobs 4
tools/biometrics/sensible-biometrics install
```

`deps` installs build dependencies and `pamtester` through Debian APT; sudo
asks for your password in the terminal. `prepare` downloads hash-pinned source
archives and applies the included compatibility patches. `build` compiles
OpenCV and Howdy-next as your normal user, runs the upstream tests, and creates
`.build/biometrics/dist/howdy-next_3.4.0-6+sensible1_amd64.deb` with a checksum and
build manifest that also records the identity of the pins, patches and
packaging files it was built from (`build.py check` accepts only a matching
package). Adjust `--jobs` to suit available CPU and memory. Build logs are
printed to the terminal; capture them locally if needed.
Build directories and their parents must not be group/world writable because
upstream security tests check their fixture paths. A custom `--work-dir` must
meet the same requirement.

`install` checks the package identity and hash, simulates dependency resolution,
then installs with APT's package-removal guard. It accepts an explicit local
artifact with `--package PATH --sha256 HASH`. No third-party APT repository is
added. Existing Howdy packages that require removal need separate reconciliation.

The native build uses [Howdy-next 3.4.0](https://codeberg.org/nathawat/howdy-next)
and a private OpenCV 5 runtime. Debian's OpenCV 4 cannot satisfy this version.
The available third-party binary package depends on obsolete FFmpeg libraries
in Testing; rebuilding locally avoids that mismatch. Camera capture uses V4L2,
so FFmpeg is disabled in this build. Debian supplies the other dependencies.
Source pins and compatibility-patch provenance live next to the tool. Upstream
GPL and third-party license notices are included with the package.

## Image integration

The ISO carries face login ready to enable, offline:

- `scripts/build-howdy-package.sh` builds `howdy-next` from the pinned sources
  in a Debian Testing container (podman or docker), so its dependencies match
  the archive the image is bootstrapped from. A package already under
  `.build/biometrics/dist` is reused only while `build.py check` confirms it was
  built from the current pins, patches and packaging files and
  `apt-get --simulate` still installs it on today's Testing; a library
  transition in Testing rebuilds it instead of breaking the ISO build later. CI
  runs this once per workflow (`package` job, cached by the tools' contents)
  and hands the package to both edition builds. Without a container engine the
  script accepts a package built by `sensible-biometrics build` as your normal
  user.
- `scripts/stage-biometrics.sh`, called by `live/build-stages.sh` and
  `scripts/build-native.sh` after `fetch-pins.sh`, verifies that package
  against its manifest and `live/pins.env`, stages it into live-build's local
  package directory, fetches the two OpenCV zoo models named by Howdy's compiled
  manifest (hash-pinned in `live/pins.env`) into `/usr/share/howdy/models`,
  installs the tool under `/usr/local/lib/sensible/biometrics` with the
  `/usr/local/bin/sensible-biometrics` launcher and the Face Login Setup menu
  entry, and records provenance in `/usr/share/doc/sensible-biometrics/sources.txt`.
- The `0280-biometrics` chroot hook fails the build unless the pinned package is
  installed, `howdy download-models` accepts the baked models without fetching
  anything, the tool starts, the launcher resolves, the configuration has the
  keys the tool manages, and no PAM service or polkit rule references Howdy.
  Installation is inert; the wizard's per-account activation with timed
  rollback is the only path that changes login.

The packaged install carries no build recipe. If the package is ever removed,
Face Login Setup asks for it to be reinstalled with APT instead of compiling.
The source-build commands above remain the developer path and are what CI runs.
Fixture tests cover the staging script and the hook with tool doubles; whether
the package installs in the chroot and Howdy accepts the models is proven only
by the image build itself.

Planned next: a signed Sensible APT repository for `howdy-next` and the Sensible
tools, so installed systems receive rebuilt packages when Testing moves rather
than waiting for a new image.

## Configure and check the camera

```bash
tools/biometrics/sensible-biometrics probe
tools/biometrics/sensible-biometrics configure --dry-run
tools/biometrics/sensible-biometrics configure
tools/biometrics/sensible-biometrics models
tools/biometrics/sensible-biometrics preview
```

`probe` inspects capabilities, pixel formats and stable device links. It excludes
metadata-only nodes and suggests a unique IR candidate. Monochrome formats are
hints, not proof of working IR illumination. Inaccessible or ambiguous devices
need attention; no RGB fallback is silently selected. Use `probe --json` for a
local machine-readable report; it contains device paths and package/PAM details.
Reports are not written into the repository automatically.

`configure` updates only `[video] device_path` and `timeout` in
`/etc/howdy/config.ini`, preserves the other settings and comments, and saves a
root-only rollback record. For multiple cameras, pass `--device` with a stable
capture link reported by the probe. `--timeout` sets the scan deadline in seconds
(default 4). An explicit device selection permits testing another capture stream.

`models` uses Howdy's hash-verified download command. The build selects the FP32
SFace model required by this OpenCV version; existing embeddings from a different
model are not interchangeable. `preview` opens Howdy's camera window and passes
only the display-related environment variables through sudo. Check that the
correct stream gives a usable image. Emitter setup is hardware-dependent and is
not automated yet; dark frames need investigation before enrollment.

## Enroll and test authentication

```bash
tools/biometrics/sensible-biometrics enroll
tools/biometrics/sensible-biometrics list
tools/biometrics/sensible-biometrics pam-test
tools/biometrics/sensible-biometrics pam-test --password-fallback
```

The target account defaults to the invoking desktop user; use `--user NAME`
when necessary. Root and system accounts are rejected. Enrollment requires your
participation in front of the camera. It adds a model using Howdy's native CLI.

`pam-test` creates `/etc/pam.d/sensible-howdy-test`, calls `pamtester` for face
authentication and account checks, then removes the temporary service. Face-only
mode has no password success path. `--password-fallback` tests face authentication
followed by the existing password stack on failure. The test deadline is 30
seconds, adjustable with `--timeout`.

The guided `verify` check uses a separate bounded PAM worker to distinguish
authentication from account-check results. Any PAM conversation stays inside
`libpam_misc`; Python receives status codes, not passwords.

### Optional no-face diagnostic

The rejection check is available separately for troubleshooting; it is not part
of guided setup or a requirement for activation:

```bash
tools/biometrics/sensible-biometrics verify face
tools/biometrics/sensible-biometrics verify reject --delay 5
```

After the countdown starts, move fully out of the camera view and stay out until
the result appears. A normal scan timeout without a match is the expected passing
result. A match means this diagnostic did not confirm rejection; it does not mark
setup as failed or change login settings. `verify reject` tests authentication
alone so an account failure cannot count as face rejection.

Try a successful face match, a non-match/covered camera, and both correct and
incorrect passwords in fallback mode. A preview window opening is not an
authentication test. These tests do not establish desktop lock-screen behavior.
These individual test commands do not enable login; use the guided setup above.

## Undo and recovery

```bash
tools/biometrics/sensible-biometrics restore-config
tools/biometrics/sensible-biometrics pam-cleanup
```

`restore-config` restores the original config bytes and permissions. It refuses
to overwrite unrelated changes made after setup. `pam-cleanup` is only needed
if an interrupted process left the temporary test service; it removes only the
recognized test contents. Enrollment remains managed by Howdy's native
`remove`/`clear` commands. Removing the package is an ordinary APT operation;
review retained enrollment/configuration data separately.

## Development

Run `bash tests/unit/biometrics_test.sh` for offline discovery and local-tool
regressions. `prepare` can be exercised without root or build dependencies.
Build/install and live camera/PAM results must be checked separately; fixture
success does not establish recognition performance.

The activation tests run both filesystem failure scenarios and real Linux-PAM
control-flow checks against temporary services and stub modules, without changing
host authentication. Real PAM checks require `libpam0g-dev`, a C compiler and a
host environment that preserves root ownership of PAM modules.

The launcher currently uses a terminal wizard. It draws the Sensible logo, step
boxes and status marks with ANSI colour and box-drawing characters when stdout
is a terminal; piped output, `NO_COLOR=1` or `TERM=dumb` give plain text, and a
non-UTF-8 terminal gets ASCII glyphs. `probe` without `--json` uses the same
layout. Presentation lives in `tui.py`, which the root-owned recovery copy never
imports. Graphical presentation and image integration can follow the local flow. Fingerprint uses Debian's existing fprintd tools.
Face authentication does not supply a LUKS or wallet/keyring decryption password.

Earlier local evaluation found BioPass performed poorly compared with older
Howdy; it is not part of the current implementation path.
