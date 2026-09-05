# Desktop profiles: GNOME and KDE

Status: **application/dependency slice implemented in image configuration;
full-image and real-session acceptance pending**. Extension activation, further
extensions, native profile defaults and appearance remain planned.
Recorded 2026-09-05, after installer PR #3 was merged. A configured package list
is not evidence that an already published ISO contains these additions.

## Intent

Ship a useful, configured desktop on the first offline boot. Both editions
should cover the same everyday tasks, while retaining their native interfaces.
Equivalent capability does not require identical applications or an equal
number of extensions and widgets.

Keep the existing productivity, browser, media, security and CLI baseline.
This milestone adds to it; it does not remove applications to compensate for
image size. Measure image size, build time and idle resource use as additions
land, and review those costs explicitly.

## Agreed application and feature scope

| Capability | GNOME edition | KDE edition | Delivery decision |
| :--- | :--- | :--- | :--- |
| Photo library | Shotwell | digiKam; keep Gwenview for quick viewing | Include in the respective image |
| Nearby file sharing | LocalSend | LocalSend | Include in both images |
| Manage desktop additions | Extension Manager | Native widget browser and System Settings | Provide working management tools |
| Resource and sensor monitoring | Vitals | Plasma System Monitor and native sensor widgets | Include; choose a restrained default display |
| Phone integration | GSConnect, including supporting dependencies | KDE Connect | Include; pairing remains a user action |
| Keep awake | Caffeine | Native Plasma power-management controls | Available; keep-awake mode off by default |
| Clipboard history | Clipboard Indicator | Native Plasma clipboard/Klipper | Include; review retention/privacy defaults |
| Dock/panel | Dash to Dock | Plasma panel with Icons-only Task Manager | Configure a usable default; exact layout still to be chosen |
| Battery estimate | Battery Time | Native battery widget | Show useful laptop information; avoid empty desktop indicators |
| Screenshot search, OCR and QR | Shotzy | Retain Spectacle; investigate an OCR/search companion | GNOME scope agreed; KDE feature parity still exploratory |
| Themes | User Themes | Native Plasma appearance settings | Prepare support; retain stock appearance until themes are selected |

The requested GNOME extensions are Vitals, GSConnect, Caffeine, Clipboard
Indicator, Dash to Dock, Battery Time, Shotzy and User Themes. Do not silently
substitute similarly named extensions. Record each selected extension's UUID,
upstream URL, version and supported Shell versions when packaging it.

### Additional candidates

- Include GNOME Tweaks for advanced appearance/font settings.
- Include GNOME AppIndicator support for applications with tray indicators.
- Evaluate personal-file backups: Déjà Dup on GNOME and Kup on KDE. The need
  for a backup workflow is identified; the exact applications and default
  configuration need validation before being treated as committed packages.
- Do not add a second clipboard, battery, dock or keep-awake implementation
  to Plasma merely to mirror the GNOME extension list.

These are desktop defaults, not a request to preinstall commercial clients,
enable remote control without pairing, configure cloud accounts, or start
backup jobs without a user-selected destination.

## Packaging and offline behavior

1. Prefer packages from the Debian Testing archive when they provide the
   selected application or extension with the required compatibility.
2. When an agreed default is unavailable there, evaluate a pinned upstream
   release with a verified checksum and redistribution license. LocalSend's
   official 1.18.2 amd64 `.deb` (control version `1.18.2+64`, Apache-2.0) is
   pinned in `live/pins.env`; non-Debian GNOME extensions need the same
   provenance and compatibility checks.
3. Fetch and stage approved artifacts **during the ISO build**, never during
   installation or first login. Build failure is preferable to silently
   shipping an incomplete profile. Include all runtime dependencies.
4. Record a deliberate update path for each non-Debian artifact. Do not rely
   on downloading an unpinned branch, disabling extension-version checks, or
   letting a root-owned installation self-update unexpectedly.
5. Keep optional applications and online repository setup in the planned
   `sensible-apps` workflow. A default being sourced upstream does not imply
   that its installation must require the target machine to be online.

This is an explicit exception to the earlier broad statement that all
third-party applications are post-install only: approved default artifacts may
be included after build-time review. It does not authorize arbitrary upstream
applications. Commercial clients remain excluded.

LocalSend is checksum/identity-checked by `scripts/fetch-pins.sh` and placed in
`config/packages.chroot/localsend_amd64.deb`. live-build's local APT repository
installs it with dependency resolution; a chroot hook requires the pinned version,
launcher and license. Upstream's bundled third-party notices are retained. Both
build paths use this mechanism. No external APT repository, autostart preference
or automatic transfer acceptance is added. Refresh the version, control version,
package checksum and license checksum together after reviewing a release; rerun
dependency/runtime checks and both image builds. Existing installations need a
reviewed upstream package update; Debian upgrades do not update this pin.

GSConnect recommendations are explicit rather than relying only on APT policy:
SSHFS, Nautilus Python integration, the relevant GI bindings and Folks EDS backend.
The live image currently enables recommends; the builder toolchain does not.
GSConnect and AppIndicator are packaged, not added to the enabled-extension list
in this slice. GNOME uses GSConnect; KDE uses KDE Connect. Both editions gain
TCP/UDP 53317 and 1714–1764 UFW rules (IPv4/IPv6 with Debian defaults). These
rules are not restricted to a trusted-network profile; the manual explains the
exposure. Real-device discovery, pairing and transfer remain acceptance checks.

### Integrations that belong in the implementation

**GSConnect:** review both dependencies and recommended functionality, including
SSHFS, Nautilus integration and the relevant introspection libraries. Decide
browser integration separately; do not confuse the native bridge with a
browser extension being installed and enabled. Use GSConnect on GNOME and KDE
Connect on KDE, avoiding competing implementations in one session.

**LocalSend and phone integration:** test discovery and transfer with Sensible's
firewall enabled. Define and document the intended local-network exposure,
including IPv4/IPv6 behavior; do not solve discovery by disabling the firewall.
LocalSend currently documents TCP/UDP port 53317. GSConnect/KDE Connect rules
must be reviewed for both editions, not only KDE. Pairing and incoming-transfer
acceptance must remain explicit user choices.

**Shotzy:** include Tesseract OCR, the selected language data and `zbar-tools`.
Check Debian's language-data paths and actual discovery in Shotzy. Local OCR
and QR decoding should work without internet; Google Lens is an online action.
Document what is uploaded and to which service, and require an explicit user
action before sending screenshot content. Do not claim Spectacle alone offers
the same OCR/search workflow on KDE.

## Configuration policy

- Store maintainable, edition-specific defaults in the repository; choose the
  concrete GNOME and Plasma configuration mechanisms during implementation.
- Apply defaults to a fresh user's session. Do not copy the live user's home,
  hardware identifiers, personal files, tokens, or paired devices.
- Let subsequent user customization take precedence. Do not overwrite it on
  every login or ordinary package update. Provide a documented reset path.
- Preserve the existing authentication model: optional autologin only with
  LUKS, with idle/resume locking. Installing Caffeine must not permanently
  disable those protections.
- Review clipboard history limits, persistence and clearing behavior. Do not
  promise that a clipboard manager can reliably recognize every secret.
- Keep themes stock until the user supplies the shortlist. Theme selection
  includes readability, contrast, GTK/Qt consistency and update compatibility,
  not just screenshots.
- Record package/extension versions in build artifacts so a broken Testing
  upgrade can be reproduced and diagnosed.

## Delivery sequence

The [offline manual](../manual/index.html), ported from PR #2 onto the current
installer, is the foundation for documenting these defaults. Update it as
each profile change is implemented and validated.

| Change | Scope | Required evidence |
| :--- | :--- | :--- |
| 1. Applications and dependencies | Photo tools, LocalSend, phone integration, management tools and approved support packages | Both images build; applications start offline; network integrations work with the firewall |
| 2. GNOME profile | Package/pin the selected extensions and apply fresh-user defaults | Correct Shell compatibility, enabled state, dependency checks, reboot/login/lock tests |
| 3. KDE profile | Native feature configuration, selected apps and evaluation of screenshot OCR/search | Equivalent task coverage, correct panel behavior, reboot/login/lock tests |
| 4. Optional appearance and backups | User-selected themes; validated backup workflow | Readability/accessibility review; successful backup and restore before recommending defaults |

Each change updates the manual and the actual-current-state documentation.
Do not advertise planned features as shipped while this checklist is open.

### Application-slice validation (2026-09-05)

- All 14 local suites pass, including real staging-script tests with tiny pinned
  fixtures and mocked package metadata/firewall commands, and manual coverage.
- Each complete edition package set plus the real LocalSend `.deb` resolves in a
  disposable Debian Testing APT simulation with recommends enabled.
- Real pinned artifacts stage successfully for both editions from verified cache
  with download attempts forbidden; LocalSend identity is `localsend`, amd64,
  `1.18.2+64`. These are builder-side checks, not installed-disk acceptance.
- LocalSend starts and reports its HTTPS listener under Xvfb in a minimal Debian
  container after explicitly installing GTK, Secret Service, EGL/OpenGL ES and
  Mesa support. It stays running until the test timeout. Missing system-bus,
  NetworkManager and portal services in that fixture prevent treating it as a
  complete desktop/network test.
- The real UFW hook succeeds for both editions in a disposable container with a
  private network namespace and NET_ADMIN for netfilter inspection. Generated
  `user.rules` and `user6.rules` contain both TCP/UDP port sets. This checks rule
  generation, not discovery or packet delivery between real devices.
- Full ISO builds, offline real-session startup, file dialogs/tray behavior,
  phone pairing, IPv4/IPv6 transfers, and before/after image/resource costs remain
  unchecked release evidence. The tests do not mark the broader milestone done.

## Acceptance checklist

- [ ] Exact sources, licenses, package names, extension UUIDs and versions recorded.
- [ ] All required artifacts/dependencies available before any target disk is wiped.
- [ ] A new GNOME user and a new KDE user can reach the configured desktop offline.
- [ ] Extensions are actually enabled and functional, not merely installed.
- [ ] LocalSend transfers and GSConnect/KDE Connect pairing work with the firewall on.
- [ ] Local OCR/QR works offline; online screenshot actions have explicit privacy wording.
- [ ] Caffeine/native inhibition is off initially; idle lock, resume lock and autologin remain correct.
- [ ] Clipboard limits, persistence and clearing behavior are tested and documented.
- [ ] Defaults survive reboot without resetting user customizations.
- [ ] Multi-monitor layout and battery/no-battery behavior are checked.
- [ ] Before/after image size, build duration and idle resource use are recorded.
- [ ] The offline manual accurately describes the shipped profile and recovery/reset paths.

These checks supplement, not replace, the release blockers in
[PLAN.md](PLAN.md): [automated input #4](https://github.com/korq-apps/sensible/issues/4),
[installed-disk matrix #5](https://github.com/korq-apps/sensible/issues/5), and
[physical hardware evidence #6](https://github.com/korq-apps/sensible/issues/6).
The expanded asset set also belongs in
[complete offline validation #9](https://github.com/korq-apps/sensible/issues/9).

## Upstream references

Sources reviewed for planning on 2026-09-05; recheck exact versions at packaging
time rather than treating these moving pages as a version lock.

- [Debian Testing GNOME packages](https://packages.debian.org/forky/gnome/)
- [GSConnect package dependencies](https://packages.debian.org/forky/gnome-shell-extension-gsconnect)
- [Vitals](https://extensions.gnome.org/extension/1460/vitals/), [Clipboard Indicator](https://extensions.gnome.org/extension/779/clipboard-indicator/), [Battery Time](https://extensions.gnome.org/extension/5425/battery-time/)
- [LocalSend downloads](https://localsend.org/download) and [network requirements](https://github.com/localsend/localsend#setup)
- [Shotzy and its dependencies](https://github.com/SamkitJain660/Shotzy)
- [digiKam](https://www.digikam.org/about/), [Plasma System Monitor](https://apps.kde.org/plasma-systemmonitor/), [Spectacle](https://apps.kde.org/spectacle/)
- [Déjà Dup](https://apps.gnome.org/DejaDup/) and [Kup](https://apps.kde.org/kup/)
