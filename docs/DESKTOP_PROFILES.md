# Desktop profiles: GNOME and KDE

Status, reconciled **2026-09-10**: **PRs #16–#18 are merged; both editions passed
each PR's ISO build and live console smoke.** Earlier user feedback confirms
successful GNOME and KDE validation, and the user now confirms Try Sensible
works as expected. This does not assert every hardware/audio scenario passed.
The application baseline, GNOME profile,
Paper/Orchis defaults, global replacement themes/icons and ONLYOFFICE are no
longer pending implementation. Native KDE profile/appearance configuration,
editor neutrality and backup choices remain planned. PR #18 adds the Try
Sensible live desktop and bakes the shared GNOME dconf profile into the image;
those are implemented and the live-desktop experience has positive validation.

Issue #13 remains open for targeted GNOME acceptance; preserve the successful
user smoke report without treating it as evidence for every checklist item.
The [shared priority queue](PLAN.md#reconciled-priorities) now parks further
unattended automation and prioritizes user-facing features; release evidence
remains required, but a new harness is not a prerequisite. General validation of both
desktops is reported successful. Historical entries below
retain their original dates and test scope; the current evidence is recorded in
[Merged desktop slice and user feedback](#merged-desktop-slice-and-user-feedback-2026-09-08)
and [Merged live-desktop and audio slice](#merged-live-desktop-and-audio-slice-2026-09-10).

The [GitHub prioritization index (#28)](https://github.com/korq-apps/sensible/issues/28)
links the planned desktop scopes: [native KDE defaults (#27)](https://github.com/korq-apps/sensible/issues/27),
[editor neutrality (#26)](https://github.com/korq-apps/sensible/issues/26),
[personal backups (#21)](https://github.com/korq-apps/sensible/issues/21) and
[Btrfs recovery (#19)](https://github.com/korq-apps/sensible/issues/19).
KDE defaults and backup-tool selection need a design choice; the editor decision
is already confirmed. Personal backups and system snapshots remain distinct.

The KDE wallet-creation error reported on 2026-09-10 is tracked separately in
[#29: wallet/keyring integration](https://github.com/korq-apps/sensible/issues/29),
ahead of cosmetic KDE work. It covers both desktops: password-backed first use,
PAM/password-login unlock, honest autologin/biometric prompts, preservation of
existing credentials and isolation of live-user state. Supported reuse of a
disk-unlock secret is a separate evaluation, not an assumed fix. The report
does not invalidate the otherwise successful Try Sensible feedback.

## Intent

Ship a useful, configured desktop on the first offline boot. Both editions
should cover the same everyday tasks, while retaining their native interfaces.
Equivalent capability does not require identical applications or an equal
number of extensions and widgets.

Keep the agreed productivity, browser, media, security and CLI capabilities.
PR #16 deliberately replaces LibreOffice with ONLYOFFICE, with LibreOffice
documented as optional; this is a selected office workflow, not image-size
pruning. Measure image size, build time and idle resource use as changes land.

## Agreed application and feature scope

| Capability | GNOME edition | KDE edition | Delivery decision |
| :--- | :--- | :--- | :--- |
| Office suite | ONLYOFFICE Desktop Editors | ONLYOFFICE Desktop Editors | Complete pinned upstream package installed offline; free fonts, scoped office defaults and manual update guidance; LibreOffice optional |
| Photo library | Shotwell | digiKam; keep Gwenview for quick viewing | Include in the respective image |
| Nearby file sharing | LocalSend | LocalSend | Include in both images |
| Flatpak application source | Flathub via GNOME Software | Flathub via KDE Discover | System remote/key preconfigured offline; downloads require network; no Flatpak apps/runtimes preinstalled |
| Optional browser | Brave Origin | Brave Origin | Curated online alternative, not preinstalled; official installer and source/key implications documented in the manual |
| Manage desktop additions | Extension Manager | Native widget browser and System Settings | Provide working management tools |
| Resource and sensor monitoring | Vitals | Plasma System Monitor and native sensor widgets | Include; choose a restrained default display |
| Phone integration | GSConnect, including supporting dependencies | KDE Connect | Include; pairing remains a user action |
| Keep awake | Caffeine | Native Plasma power-management controls | Available; keep-awake mode off by default |
| Clipboard history | Clipboard Indicator | Native Plasma clipboard/Klipper | Include; review retention/privacy defaults |
| Dock/panel | Dash to Dock | Plasma panel with Icons-only Task Manager | GNOME enables the upstream dock default; detailed GNOME/KDE layouts remain user-configurable |
| Window controls | Close, Minimize and Maximize titlebar buttons | Native Plasma titlebar controls | Apply as a fresh-user GNOME default; never overwrite later user changes |
| Battery estimate | Battery Time | Native battery widget | Show useful laptop information; avoid empty desktop indicators |
| Screenshot search, OCR and QR | Shotzy | Retain Spectacle; investigate an OCR/search companion | GNOME scope agreed; KDE feature parity still exploratory |
| Themes | Paper icons and Orchis GTK 3 defaults; Papirus; Qogir/Matcha/Fluent GTK 3/4 + Shell and Qogir icons; existing Marble/Graphite choices | Native Plasma appearance settings; theme shortlist still pending | Merged offline GNOME assets and overridable defaults; positive user smoke feedback; targeted acceptance remains; no forced Shell/GDM/personal CSS override |

The requested GNOME extensions are Vitals, GSConnect, Caffeine, Clipboard
Indicator, Dash to Dock, Battery Time, Shotzy and User Themes. Do not silently
substitute similarly named extensions. Record each selected extension's UUID,
upstream URL, version and supported Shell versions when packaging it.

### Additional considerations

- GNOME Tweaks is included by the application slice. The GNOME profile uses a
  system dconf default to enable the Close, Minimize and Maximize
  titlebar buttons for fresh users; users remain free to change that layout.
- GNOME AppIndicator support is packaged and enabled with the curated set.
  Actual tray behavior remains a real-session acceptance check.
- Evaluate personal-file backups: Déjà Dup on GNOME and Kup on KDE. The need
  for a backup workflow is identified; the exact applications and default
  configuration need validation before being treated as committed packages.
- Do not add a second clipboard, battery, dock or keep-awake implementation
  to Plasma merely to mirror the GNOME extension list.
- Confirmed editor follow-up: include both Vim and Neovim in both editions,
  leave Debian's editor selection/user preferences intact, and make LazyVim
  configuration opt-in. Remove Sensible's forced `EDITOR`/`VISUAL` values rather
  than replacing them with Vim. This is not yet implemented; current sources
  still include the Neovim/LazyVim default.

These are desktop defaults, not a request to preinstall commercial clients,
enable remote control without pairing, configure cloud accounts, or start
backup jobs without a user-selected destination.

## Packaging and offline behavior

1. Prefer packages from the Debian Testing archive when they provide the
   selected application or extension with the required compatibility.
2. When an agreed default is unavailable there, evaluate a pinned upstream
   release with a verified checksum and redistribution license. ONLYOFFICE's
   official amd64 `.deb` (`9.4.0-129`, retained upstream notices), LocalSend's
   official 1.18.2 amd64 `.deb` (control version `1.18.2+64`, Apache-2.0) and
   four non-Debian GNOME extension archives are pinned in `live/pins.env` with
   provenance, license and compatibility checks.
3. Fetch and stage approved artifacts **during the ISO build**, never during
   installation or first login. Build failure is preferable to silently
   shipping an incomplete profile. Include all runtime dependencies.
4. Record a deliberate update path for each non-Debian artifact. Do not rely
   on downloading an unpinned branch, disabling extension-version checks, or
   letting a root-owned installation self-update unexpectedly.
5. Keep optional applications and online repository setup in the planned
   `sensible-apps` workflow or documented manual instructions. Flathub's static
   definition/key is already image data, not an online setup task. A default
   being sourced upstream does not imply that installation must be online.

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

ONLYOFFICE follows the same build-time local-package model, retaining the entire
upstream payload and adding the runtime libraries missing from its dependency
metadata. It has no added update repository: the manual explains reviewed local
package updates and optional LibreOffice installation. See the
[office architecture](ARCHITECTURE.md#offline-office-suite) for the font policy,
payload/linker guard and user-overridable office-only file associations.

The curated GNOME extension closure is explicit:

| Extension | Source / reviewed version | UUID | License / Shell range |
| :--- | :--- | :--- | :--- |
| GSConnect | Debian `gnome-shell-extension-gsconnect` (72-1 reviewed) | `gsconnect@andyholmes.github.io` | Debian package; coupled to Testing's Shell |
| AppIndicator | Debian `gnome-shell-extension-appindicator` (64-2 reviewed) | `ubuntu-appindicators@ubuntu.com` | Debian package; coupled to Testing's Shell |
| Caffeine | Debian `gnome-shell-extension-caffeine` (60-1 reviewed) | `caffeine@patapon.info` | Debian package; coupled to Testing's Shell |
| Dash to Dock | Debian `gnome-shell-extension-dashtodock` (106-1 reviewed) | `dash-to-dock@micxgx.gmail.com` | Debian package; coupled to Testing's Shell |
| User Themes | Debian `gnome-shell-extension-user-theme` (50.2-2 reviewed) | `user-theme@gnome-shell-extensions.gcampax.github.com` | Debian package; coupled to Testing's Shell |
| Vitals | extensions.gnome.org v85, version tag 74743 | `Vitals@CoreCoding.com` | GPL-2.0; Shell 45–51 |
| Clipboard Indicator | extensions.gnome.org v71, version tag 70694 | `clipboard-indicator@tudmotu.com` | MIT; Shell 46–50 |
| Battery Time | extensions.gnome.org v10, version tag 72194 | `batterytime@typeof.pw` | GPL-2.0-or-later SPDX notice; Shell 45–50 |
| Shotzy | extensions.gnome.org v8, version tag 71980 | `shotzy@SamkitJain660.github.io` | GPL-3.0; Shell 49–50 |

`scripts/fetch-pins.sh` checksum-checks and safely extracts the four upstream
archives only for GNOME, verifies UUID/version/Shell 50 metadata and retains
license/source records. `0260-gnome-profile.hook.chroot` then checks the actual
installed Shell major and full runtime closure before the ISO is published.
Debian-packaged extensions follow Debian updates; updating an upstream extension
requires reviewing a new EGO version tag, version, archive checksum, license and
Shell range together in `live/pins.env`.

GSConnect recommendations are explicit rather than relying only on APT policy:
SSHFS, Nautilus Python integration, the relevant GI bindings and Folks EDS backend.
The live image currently enables recommends; the builder toolchain does not.
GSConnect and AppIndicator are also in GNOME's enabled-extension default. GNOME
uses GSConnect; KDE uses KDE Connect. Both editions gain
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

**Shotzy:** Tesseract OCR, English language data and `zbar-tools` are included.
Debian stores `eng.traineddata` in `/usr/share/tesseract-ocr/5/tessdata`, while
Shotzy v8 expects `/usr/share/tessdata`; the image hook validates the former and
creates the latter as a relative compatibility link. Local OCR
and QR decoding should work without internet; Google Lens is an online action.
Document what is uploaded and to which service, and require an explicit user
action before sending screenshot content. Do not claim Spectacle alone offers
the same OCR/search workflow on KDE.

## GNOME appearance defaults and installed alternatives

The user's revised selection removes Everforest, Tokyonight, Osaka, Catppuccin
and Good-Old-Shell from the image. Keep cleanup entries for those named outputs
so a reused build cannot accidentally retain them. Paper/Orchis defaults and
Marble/Graphite remain; Qogir, Qogir icons, Matcha and Fluent replace the withdrawn
collections. The user reported incomplete icons after applying the earlier
themes; a working selection command alone is not acceptance evidence.

### Debian packages and defaults

GNOME includes `paper-icon-theme`, `papirus-icon-theme`, `orchis-gtk-theme`,
`gtk-update-icon-cache` and `librsvg2-common`. The installed user's unlocked
dconf defaults select Paper icons and Orchis GTK 3 styling; personal overrides
take precedence. The cache tool indexes Qogir and the SVG loader renders its
vector icons. Paper, Papirus and Orchis update through Debian APT.

Testing no longer provides `gtk2-engines-murrine`
([removal notice](https://tracker.debian.org/news/1703411/gtk2-engines-murrine-removed-from-testing/)).
The selected GTK 3/4 and Shell components do not need it. We do not mix Stable repositories
into the target, ship unusable GTK 2 components, force libadwaita configuration
links or change GDM. Debian's Orchis Shell component is not selected or validated
as part of this profile.

### Installed upstream assets

| Source | Installed choices | Pin and scope |
| :--- | :--- | :--- |
| [Qogir GTK](https://github.com/vinceliuice/Qogir-theme) | Qogir, Qogir-Light, Qogir-Dark | `e7b3146860e5e981a075b4b56facf8e1c2ae5abb`; default blue, standard/light/dark GTK 3/4 + Shell |
| [Qogir icons](https://github.com/vinceliuice/Qogir-icon-theme) | Qogir, Qogir-Light, Qogir-Dark | `c633057ba0d27a504b3255144071c9691ed0264a`; full app/device/folder/symbolic icon collection, light/dark recolorings and HiDPI aliases; no cursor selection |
| [Matcha](https://github.com/vinceliuice/Matcha-gtk-theme) | Matcha-sea, Matcha-light-sea, Matcha-dark-sea | `923789ae6a8a4d239aa5935ad4c3b56219e74568`; sea-green accent, standard/light/dark GTK 3/4 + Shell |
| [Fluent](https://github.com/vinceliuice/Fluent-gtk-theme) | Fluent, Fluent-Light, Fluent-Dark | `7a49a464b0188c340101c52965c18190b1c694cf`; default blue, standard/light/dark GTK 3/4 + Shell; separate Fluent icons not bundled |
| [Marble](https://github.com/imarkoff/Marble-shell-theme) | Six accents, light/dark | Existing `df788bc3d9d2147bcdeaedb907b90ced64f0ad48` pin, generated for Shell 50; GPL-3.0-or-later |
| [Graphite](https://github.com/vinceliuice/Graphite-gtk-theme) | Graphite-Light, Graphite-Dark | Existing `364173f47407164948788e4abb5e2eb46600f71a` pin, grey GTK 3/4 + Shell; GPL-3.0 |

All four replacement repositories carry GPL-3.0 licenses; retain their license
files and author credits. Full SHA256 values and revisions are in `live/pins.env`.
Their upstream activity varies (Matcha's reviewed tip is from August 2025);
selection does not imply a promise about future maintenance or Shell 50 support.
Flat Remix and Transparent Shell are not included: the earlier compatibility/
redistribution gates remain unresolved.

### Installation and dependency handling

Both builders use `scripts/stage-themes.sh` and
`scripts/build-theme-assets.py`. Download six verified archives at build time,
install GTK 3, GTK 4 and GNOME Shell components plus assets and `index.theme`
under `/usr/share/themes`, and Qogir icons under `/usr/share/icons`. Compile
Sass where appropriate; retain Matcha's GTK 4 CSS and Qogir/Matcha/Fluent's
Shell CSS exactly as their manual installers do. Shell layout selection follows
upstream's >=48 branch on GNOME 50. No upstream installer runs against the host
or user's home: their default flows can also alter other desktops and editor
styles outside the requested theme destination. Target installation and first
login need no network or build tools.

The earlier GTK-3-only payload was incomplete for the requested GNOME themes.
It omitted GTK 4 and Shell directories that the user demonstrated in a manual
Matcha installation. Do not repeat that omission based on an asset audit or
because upstream's latest Shell directory is named 48 rather than 50.

Two narrowly scoped corrections avoid upstream missing assets: Qogir/Matcha's
legacy document-thumbnail PNG becomes a solid border, and Qogir's old Kooha
image-only window-button overrides are dropped so ordinary GTK controls render.
Qogir's GTK 4 checkmark URLs are corrected to their actual shipped paths;
Graphite Shell also receives its referenced background and scalable assets.
Matcha's GTK 4 styles retain an exact reviewed set of upstream missing-image
references, reported in `known-upstream-assets.txt`. Missing references alone
are not evidence that the entire theme fails to render. New missing files and
unsafe paths remain fatal; GTK 4 and Shell are not discarded.

Qogir needs both its source icon directories and its separate alias tree.
Merge them with aliases replacing the corresponding source entries, reproduce
the upstream light/dark recolorings, and retain all sizes and symbolic icons.
Each installed variant is self-contained. Validate indexed directories and links,
repair the pinned muted/none microphone aliases to the shipped muted icon,
and replace the unshipped Breeze fallback with Papirus/Adwaita/hicolor. The chroot
hook checks installed packages/assets and builds the caches. Do not infer complete
icon coverage from a folder SVG alone.

The full archives, licenses, pins, author credits and build adapter accompany
the image under `/usr/share/doc/sensible-themes/`. Pinned assets update through
reviewed image changes, not ordinary APT upgrades. A KDE rebuild removes only
the named generated GNOME outputs, including retired assets; unrelated themes
and icons remain untouched.

### Selection and acceptance

The manual leads with the globally installed themes and application/Shell/icon
selection commands. Tweaks supplies Shell and icon selectors. Matcha and Fluent
do not install an icon theme of the same name. Marble is Shell-only; the other
four theme families provide application and Shell choices. Global installation
does not force libadwaita styling; a reversible, non-overwriting personal CSS
import is documented separately as opt-in. `gsettings set` selects installed
assets; it does not download a missing theme. The [manual](../manual/applications.html#themes) includes exact
installed names, dependency notes, troubleshooting, and separate reset paths
for Sensible's Orchis/Paper defaults and stock Adwaita.

The replacement slice must pass real Sass compilation, complete asset/link
checks (with recorded upstream exceptions), icon-cache generation and GTK 3/4 theme/icon loading, in addition to fixture
tests and the Testing package gate.
Full ISO build/boot, visual contrast/scaling, application coverage, user override
persistence and login/lock acceptance remain open; headless loading is not a
substitute for that review. Uniform libadwaita/Flatpak styling is not promised.

### Initial replacement-theme validation (2026-09-06, before GTK 4/Shell correction)

- All 14 local suites pass, including checksum, compiler, missing-asset,
  icon-alias/fallback, dependency and retired-output cleanup regressions.
- The current GNOME package-name gate passes against an isolated Debian Testing
  index (155 collected names, with Brave's documented third-party exception).
  This checks archive availability, not a full image dependency solve.
- Actual pinned archives compile and stage successfully through `fetch-pins.sh`
  with network disabled: 23 theme directories (including Marble/Graphite) and
  three complete Qogir icon variants. Retired themes/icons are absent from the
  regenerated payload.
- In a disposable Debian Testing container, GTK 3 discovers all nine replacement
  themes by name and loads both their normal and dark CSS without non-deprecation
  parse errors. All three icon caches build and validate. GTK renders 117 sampled
  application/folder/symbolic icons across normal/HiDPI sizes, plus an inherited
  fallback for each variant. This is real loading evidence, not a GNOME session
  or exhaustive visual review. The repeatable check is
  `tests/lib/check_theme_runtime.py`.
- Staged themes/icons/source records occupy approximately 16/160/41 MiB;
  the previous icon payload alone occupied 697 MiB. These are uncompressed
  workspace measurements, not a measured ISO-size reduction.

### GTK 4 and Shell packaging correction (2026-09-06)

- The user's comparison showed the earlier image had only `gtk-3.0/` and an
  index, while a manual Matcha install contained GTK 4 and Shell components.
  Those omissions are corrected for Matcha, Qogir, Fluent and Graphite.
- Actual pinned archives compile/stage with all three GNOME component directories.
  A separate run of the pinned Matcha `install.sh -d ... -t sea` produces the
  same 251 GNOME component paths per variant (standard/light/dark). GTK 4 and
  Shell file bytes and symlink targets match; GTK 3 CSS keeps the documented
  compilation/adaptations. `tests/lib/check_theme_upstream.py` repeats the check.
- GTK 4.22.4 and GTK 3.24.52 both discover all eleven application-theme variants
  by name and load normal/dark CSS without non-deprecation parsing errors. The
  Qogir cache and 117 sampled-icon rendering checks plus inherited fallbacks
  pass again. Matcha is included in both toolkit runs, not skipped.
- Shell assets follow each upstream installer's selection for GNOME 50;
  this is packaging/parity evidence, not proof of Shell visual compatibility.
  Full ISO, real-session rendering, libadwaita behavior, accessibility and
  login/lock checks remain pending.

## Configuration policy

- Store maintainable, edition-specific defaults in the repository. GNOME uses
  an unlocked system dconf database, `configs/gnome-dconf-defaults`, baked into
  the image by `0260-gnome-profile.hook.chroot` and re-applied by the
  installer; choose the Plasma mechanism with its slice.
- Apply defaults to a fresh user's session. Do not copy the live user's home,
  hardware identifiers, personal files, tokens, or paired devices.
- Let subsequent user customization take precedence. Do not overwrite it on
  every login or ordinary package update. Provide a documented reset path.
- Follow the planned component-level opt-outs in PLAN.md: keep appearance and
  extension defaults separate from security/privacy settings. Removing a theme
  or dock opinion must not remove idle/resume lock configuration. Git and GNOME
  already use system defaults; the shell's skel copy is the main shared-include
  migration candidate. Test existing-user behavior, not just new home directories.
- Enable GNOME's Close, Minimize and Maximize titlebar buttons through a
  fresh-user dconf default. Preserve the normal right-side order unless the
  broader profile explicitly changes it.
- Preserve the existing authentication model: optional autologin only with
  LUKS, with idle/resume locking. Installing Caffeine must not permanently
  disable those protections.
- Review clipboard history limits, persistence and clearing behavior. Do not
  promise that a clipboard manager can reliably recognize every secret.
- Paper/Orchis are explicitly selected GNOME defaults in the implementation;
  release acceptance still requires readability, contrast, GTK/Qt behavior and
  update compatibility checks. Keep Shell/GDM stock and offer clear reset paths.
- Record package/extension versions in build artifacts so a broken Testing
  upgrade can be reproduced and diagnosed.

## Delivery sequence

The [offline manual](../manual/index.html), ported from PR #2 onto the current
installer, is the foundation for documenting these defaults. Update it as
each profile change is implemented and validated.

| Change | Scope | Required evidence |
| :--- | :--- | :--- |
| 1. Applications and dependencies | Merged photo tools, LocalSend, phone integration, management tools, ONLYOFFICE and support packages | Both images build and pass live smoke; positive GNOME/KDE user validation; targeted application/network/office checks remain |
| 2. GNOME profile | Merged selected extensions, fresh-user defaults, titlebar buttons and complete global GNOME themes/icons | Build guards and automated checks pass; latest GNOME build works as expected per user; targeted edge-case evidence remains |
| 3. KDE profile | Native feature configuration, selected apps and evaluation of screenshot OCR/search | Equivalent task coverage, correct panel behavior, reboot/login/lock tests |
| 4. Optional appearance and backups | GNOME theme assets included; native KDE appearance and validated backup workflow pending | GNOME readability/accessibility and session review; successful backup and restore before recommending defaults |

Each change updates the manual and the actual-current-state documentation.
Distinguish merged/shipped image configuration from itemized acceptance instead
of describing this entire milestone as unimplemented while a checklist is open.

The separate [AI tools and CLI follow-up plan](AI_TOOLS.md) covers cross-edition
tool selection and optional desktop-client guidance. It does not add AI clients
to this profile or replace the outstanding session acceptance checks above.

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

### GNOME-profile configuration validation (2026-09-05)

- Tiny, checksum-valid EGO fixture archives exercise the real staging script for
  exact UUID/version/Shell compatibility, licenses, source manifests and
  GNOME-to-KDE cleanup. Negative cases cover wrong metadata and missing notices.
- The real image hook is exercised with external-command doubles for the Debian
  package closure, installed Shell major, schema compilation, extension assets,
  license records and Shotzy's Tesseract compatibility link. It rejects a Shell
  version jump or missing dependency instead of publishing a partial profile.
- Installer unit coverage checks all nine enabled UUIDs, titlebar buttons,
  inactive Caffeine, memory-only non-favorite clipboard history, disabled image
  caching and disabled Vitals public-IP lookup. These are dconf defaults without
  locks, so they are designed to yield to per-user changes.
- Full GNOME ISO build and a real offline Wayland session still need to prove
  actual activation, panel layout, OCR/QR, login/lock/reboot behavior, battery and
  no-battery behavior, multi-monitor behavior and user-setting persistence.

### Merged desktop slice and user feedback (2026-09-08)

- [PR #16](https://github.com/korq-apps/sensible/pull/16) merged on 2026-09-07
  as `c7015b4`. Its final head `5c702c8` passed unit/integration checks and both
  GNOME/KDE ISO builds plus live UEFI smoke in
  [CI run 34102104112](https://github.com/korq-apps/sensible/actions/runs/34102104112).
  Release publication was skipped. These are live-boot checks, not the installed
  disk or Secure Boot matrix.
- On 2026-09-08 the user reported that the latest GNOME build works as expected
  considering the recent changes. Record this as positive GNOME feature smoke
  feedback and the working baseline for follow-ups. The report did not identify
  an ISO checksum or enumerate individual tests, so it cannot be tied to an
  exact artifact or used to check off every hardware/session scenario.
- The user subsequently confirmed on 2026-09-08: KDE validation is done and OK.
  Both desktops therefore have positive user validation. Exact ISO identities
  and individual scenarios were not specified; retain targeted evidence gaps
  without treating general KDE validation as pending.
- Do not repeat GNOME packaging or add more themes merely because the remaining
  checklist is open. Remaining desktop evidence consists of focused
  checks for office documents/printing, first-login manual behavior, lock/reset
  and override persistence, transfers/OCR and multi-monitor/battery cases.
- ONLYOFFICE's earlier forced-SIGTERM headless shutdown fault remains unresolved;
  normal window closure passed in the container test. General positive GNOME
  feedback does not establish that this specific shutdown case was exercised.

### Merged live-desktop and audio slice (2026-09-10)

- [PR #18](https://github.com/korq-apps/sensible/pull/18) merged as `aa1c44e`.
  [Its CI](https://github.com/korq-apps/sensible/actions/runs/34499641262)
  passed unit/integration checks and both edition ISO/console UEFI smoke jobs.
  This does not test the new graphical boot entry. Combined post-merge image
  validation is tracked in the [shared plan](PLAN.md#validation-snapshot-updated-2026-09-10).
- Implemented: Try Sensible live account/session preparation and installer
  launcher; explicit terminal packages; one `configs/gnome-dconf-defaults`
  source for live and installed GNOME; removal of live desktop artifacts from
  the target; additional ALSA/firmware packages and `sensible-audio-check`.
- The user confirms Try Sensible works as expected. Record this as positive
  live-desktop validation, not another generic retest assignment. Separately
  retain checks that the installed system has its own account/locking behavior
  with no live launcher/autologin leftovers.
  A throwaway live account with idle locking disabled is not an installed-user
  security default.
- Collect speaker, headphone and microphone results on real Intel/AMD hardware
  under #6, with checker output and the exact image identity. Package presence
  and fixture coverage do not prove a model-specific amplifier or microphone
  works; known firmware/kernel limitations remain explicit.

## Acceptance checklist

- [x] Selected package/artifact sources, license notices, extension UUIDs and pins
      recorded; final release corresponding-source/redistribution audit remains separate.
- [x] Build hooks reject missing/incompatible pinned desktop assets and required dependencies.
- [x] Both edition ISO builds and live UEFI smoke pass for the final PR #16 head.
- [x] Positive user-reported smoke of the latest GNOME build recorded on 2026-09-08.
- [x] User reports KDE validation completed successfully on 2026-09-08.
- [x] PR #18 live-desktop/audio implementation merged; PR ISO/console smoke checks pass.
- [x] User reports Try Sensible works as expected (2026-09-10); exact per-edition scenarios were not enumerated.
- [ ] Installed users retain the intended lock/autologin policy; live desktop state and launchers are removed.
- [ ] #29: fresh KDE wallet creation works without mandatory GPG setup; matching password login unlocks the store on both desktops, and existing/live credentials are handled safely. Autologin/biometric and optional disk-secret paths have explicit tested or deferred outcomes.
- [ ] Complete shared package/asset validation before any target disk is wiped (#9).
- [ ] A new GNOME user and a new KDE user can reach the configured desktop offline.
- [ ] Extensions are actually enabled and functional, not merely installed.
- [ ] LocalSend transfers and GSConnect/KDE Connect pairing work with the firewall on.
- [ ] Local OCR/QR works offline; online screenshot actions have explicit privacy wording.
- [ ] Caffeine/native inhibition is off initially; idle lock, resume lock and autologin remain correct.
- [ ] Clipboard limits, persistence and clearing behavior are tested and documented.
- [ ] Defaults survive reboot without resetting user customizations.
- [ ] Close, Minimize and Maximize titlebar buttons appear for a fresh GNOME
      user, and later user changes survive logout, reboot and upgrades.
- [ ] Multi-monitor layout and battery/no-battery behavior are checked.
- [ ] Before/after image size, build duration and idle resource use are recorded.
- [x] Offline manual entries cover the implemented applications, themes, defaults
      and selection/reset paths, with automated package/link coverage.
- [ ] Verify the first-login manual opens offline and does not reopen on later
      logins, for installed GNOME and KDE users.
- [ ] Verify office document round trips, PDF export/printing, file associations,
      normal shutdown and user overrides in real sessions on both editions.

These checks supplement, not replace, the release blockers in
[PLAN.md](PLAN.md): merged [automated input #4](https://github.com/korq-apps/sensible/issues/4),
[installed-disk matrix #5](https://github.com/korq-apps/sensible/issues/5), and
[physical hardware evidence #6](https://github.com/korq-apps/sensible/issues/6).
The expanded asset set also belongs in
[complete offline validation #9](https://github.com/korq-apps/sensible/issues/9).
GNOME extension activation and fresh-user defaults, including the titlebar
buttons, are implemented under
[desktop-profile issue #13](https://github.com/korq-apps/sensible/issues/13);
the issue remains the home for real-session acceptance evidence.

## Upstream references

Sources reviewed for planning on 2026-09-05; recheck exact versions at packaging
time rather than treating these moving pages as a version lock.

- [Debian Testing GNOME packages](https://packages.debian.org/forky/gnome/)
- [GSConnect package dependencies](https://packages.debian.org/forky/gnome-shell-extension-gsconnect)
- [Vitals](https://extensions.gnome.org/extension/1460/vitals/), [Clipboard Indicator](https://extensions.gnome.org/extension/779/clipboard-indicator/), [Battery Time](https://extensions.gnome.org/extension/5425/battery-time/), and [Shotzy](https://extensions.gnome.org/extension/9707/shotzy/)
- [LocalSend downloads](https://localsend.org/download) and [network requirements](https://github.com/localsend/localsend#setup)
- [Shotzy source and dependency notes](https://github.com/SamkitJain660/Shotzy)
- [digiKam](https://www.digikam.org/about/), [Plasma System Monitor](https://apps.kde.org/plasma-systemmonitor/), [Spectacle](https://apps.kde.org/spectacle/)
- [Déjà Dup](https://apps.gnome.org/DejaDup/) and [Kup](https://apps.kde.org/kup/)
