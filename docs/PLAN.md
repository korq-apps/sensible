# Plan

## Where we are

Phases 1-5 are implemented. The project has since pivoted to an **offline
installer** (Phase 7, design record in [OFFLINE_REWORK.md](OFFLINE_REWORK.md)),
which supersedes parts of the earlier phases: the installer no longer resolves
packages at install time, the desktop is chosen when the ISO is built rather
than asked, and third-party software leaves the install path entirely.

| | Status |
| :--- | :--- |
| Phase 7.1 variant build + package gate | **done** |
| Phase 7.2 copy install | **done** |
| Phase 7.3-7.5 live session, guided prompts, KDE | **done** |
| Phase 7.6 post-install app tool | planned |
| Unattended input (#4) | merged in PR #17 (`553ad1d`); protected TOML/secret files and config-driven integration coverage; real `--config` acceptance belongs to #5 |
| Installer/VM diagnostics | merged in PR #17; bounded pre-cleanup evidence and host export, original failure preserved; real guest failure/export acceptance remains |
| Live desktop and audio | merged in PR #18 (`aa1c44e`); user confirms Try Sensible works as expected; specific installed-security and physical-audio checks remain separate |
| Release gate | blocked on the full installed-disk matrix and physical-hardware evidence; one user-reported install/boot succeeded, not the whole matrix |
| Hybrid ZRAM swap (#11) | implemented on `feat/zram-swap`: `zram-tools`, explicit `/etc/default/zramswap`, swapfile `pri=10`, service enablement, tests and manual; the issue's memory-pressure, failure-injection and hibernate/resume evidence is still required before it ships by default |
| Phase 6 extras | re-scoped below: baked into the ISO, or moved to the post-install tool |
| Desktop profiles | PR #16 merged; both ISO builds/live UEFI smoke checks pass; GNOME and KDE validation reported successful by the user; targeted acceptance and native KDE configuration remain; see [DESKTOP_PROFILES.md](DESKTOP_PROFILES.md) |
| Offline first-login manual | implemented from PR #2 on the current installer; real desktop first-login validation remains pending |

**Priority decision (2026-09-10):** park further unattended-install work and
the next automation/harness slice. The existing #4 implementation and diagnostic
transport stay in place. The user confirms Try Sensible works as expected; do
not schedule another generic live-desktop validation pass as the next feature.

**Recommended next feature, pending selection:** hybrid ZRAM plus the existing
disk swapfile ([#11](https://github.com/korq-apps/sensible/issues/11)), coordinated
with hibernation guidance (#8). User-facing work need not wait for the #5 harness.
Required feature validation can be performed manually on identified VM/hardware
images; parking automation does not mark the release acceptance gates complete.

**Desktop roadmap:** the GNOME profile, complete global theme/icon collection,
Flathub and ONLYOFFICE replacement are merged, not another implementation slice.
Both editions build in CI, and the user reports successful GNOME and KDE
validation. Keep both as the working desktop baseline; collect only the
remaining targeted evidence rather than scheduling another general KDE check.
Native KDE configuration, editor neutrality and backups remain separate work.
The agreed scope and evidence are in [DESKTOP_PROFILES.md](DESKTOP_PROFILES.md).

<a id="reconciled-priorities-2026-09-06"></a>

## Reconciled priorities

This queue governs the next work; the numbered phases below also retain
implementation history. Updated **2026-09-10** after
[PR #17](https://github.com/korq-apps/sensible/pull/17) (`553ad1d`) and
[PR #18](https://github.com/korq-apps/sensible/pull/18) (`aa1c44e`) merged into
`main`. Each PR passed unit/integration tests and both edition ISO/live UEFI
smoke jobs: [#17 CI](https://github.com/korq-apps/sensible/actions/runs/34508025362),
[#18 CI](https://github.com/korq-apps/sensible/actions/runs/34499641262).
Release publication was skipped. The combined `main` build
[34514968804](https://github.com/korq-apps/sensible/actions/runs/34514968804)
was still running at reconciliation: its unit/integration and GNOME ISO/smoke
jobs had passed, the KDE job had not finished. Separate PR builds are not proof
of a completed post-merge image build or graphical-session acceptance.
GitHub issues #4–#9, #11 and #13 remain open as checked on this date. The
user-requested planning pass adds #19–#27 for previously unticketed scopes and
[#28: prioritization index](https://github.com/korq-apps/sensible/issues/28).
No existing issue was closed or relabeled. #4's
implementation is merged; its ticket needs a closure/evidence update linking
PR #17, with the real install/boot matrix retained in #5 rather than reopening
the input implementation.

### Validation snapshot (updated 2026-09-10)

| Evidence | What it establishes | Still outstanding |
| :--- | :--- | :--- |
| PR #16 merged; final PR CI successful | GNOME/KDE ISOs build and reach the live UEFI smoke marker; automated regression suite passes | Installed-disk boots and Secure Boot matrix (#5), physical hardware records (#6) |
| PR #17 merged; PR CI successful | Validated unattended input, controlled disk-path rejection, failure bundles, QEMU export and optional Git metadata are in `main`; both images pass live console smoke | Real `--config` runs, detached-ISO boots and a controlled guest failure/export check in #5 |
| PR #18 merged; PR CI successful | Try Sensible entry/launcher, shared image/installed GNOME defaults, audio closure and `sensible-audio-check` are in `main`; both images pass console smoke | Graphical live sessions and installer launch on both editions, installed lock/autologin isolation, and physical speakers/headphones/microphone evidence; earlier desktop feedback does not establish these new checks |
| User: Try Sensible works as expected (2026-09-10) | Positive validation of the new live-desktop experience; no generic retest is scheduled as the next work item | Specific installed-security and physical-audio scenarios remain independently tracked; no unreported scenario is inferred |
| Local regression run on combined `main` (`aa1c44e`, 2026-09-10) | All 18 suites pass, including 675 installer-flow assertions | Commands/disks in the integration suite are mocked; this does not replace a post-merge ISO build or real session |
| User: latest GNOME build works as expected with the recent changes | Positive GNOME feature smoke/acceptance feedback for this desktop slice | Exact tested ISO checksum/session context and itemized edge-case results were not supplied; do not infer them |
| User: KDE validation done, OK | Positive KDE validation feedback; general validation reported successful for both editions | Exact artifact and itemized results were not supplied; specific release scenarios remain separately tracked |
| User: QEMU installation retry completed and the installed system booted (2026-09-10) | Positive install/boot validation for the tested scenario; the earlier `/boot` mount failure did not recur | Root cause remains unconfirmed. ISO checksum, exact configuration and interactive versus `--config` mode were not recorded for this retry; this does not complete #5's matrix or validate diagnostic export on a real failure |
| Real theme/package/container checks recorded below | Theme component parity, GTK loading, office offline package/runtime checks | Targeted office document fidelity/printing, multi-monitor/accessibility, first-login manual lifecycle, shutdown edge cases and resource measurements |

Do not re-plan the implemented GNOME features or repeat their packaging work
without a reported regression. Keep #13 as the owner of the remaining itemized
GNOME evidence, not an unstarted configuration project. Broad positive feedback
does not assert that every device, file format or security scenario was tested.

### Proposed user-facing delivery order

This replaces the previous infrastructure-first recommendation. The user has
parked unattended automation; the ordering below is a recommendation, not
authorization to implement every item or preinstall new AI clients.
The [GitHub roadmap (#28)](https://github.com/korq-apps/sensible/issues/28)
groups the existing and new issues by readiness, dependencies and proposed
priority. New tickets contain explicit scope, acceptance and exclusions; the
relative effort/risk notes are planning aids, not delivery estimates or dates.

| Order | Bounded change | Completion evidence / existing owner |
| :--- | :--- | :--- |
| Bugfix lane | Wallet/keyring first use and login integration | [#29](https://github.com/korq-apps/sensible/issues/29): reproduce KDE GPG setup failure, verify password-backed/PAM behavior on both desktops, preserve credentials; ahead of cosmetic #27 work, with boot-secret reuse evaluated separately |
| 1 | Hybrid ZRAM + persistent swap, coordinated with hibernation guidance | #11 and #8: explicit priorities, unchanged disk-backed resume target, fallback if ZRAM fails, measured memory pressure and shutdown/hibernate validation; explain supported/unknown hibernation state honestly |
| 2 | Consistent installer Back/Cancel | #7: repeated previous-step navigation without lost answers, stale derived state or accidental disk writes; Gum and fallback tests |
| 3 | Complete offline pre-wipe protection | #9: derive required packages/assets from maintained inputs; fail before wiping on missing or invalid payloads; keep target-side checks |
| 4 | Btrfs snapshots and recovery | [#19](https://github.com/korq-apps/sensible/issues/19): Snapper policy, retention and layout-aware restore; prove recovery with separate `/boot`; do not combine with #11 |
| 5 | Native KDE profile and editor neutrality, in separate small PRs | [#27 KDE](https://github.com/korq-apps/sensible/issues/27): review useful native defaults; [#26 editors](https://github.com/korq-apps/sensible/issues/26): agreed independent quick win, both Vim/Neovim with LazyVim opt-in |
| 6 | Curated AI/CLI manual and optional-app catalog | [#23 manual](https://github.com/korq-apps/sensible/issues/23), [#25 CLI usability](https://github.com/korq-apps/sensible/issues/25), [#24 catalog](https://github.com/korq-apps/sensible/issues/24); [#22 AI delivery](https://github.com/korq-apps/sensible/issues/22) remains decision-gated |

Build provenance/footprint reporting ([#20](https://github.com/korq-apps/sensible/issues/20)) and the #5 automation harness are deferred
infrastructure, not prerequisites for every user-facing PR. #5/#6 remain release
evidence requirements; manual runs can supply evidence while automation is
parked. Discovered safety failures take precedence over this suggested ordering.
Personal-file backups ([#21](https://github.com/korq-apps/sensible/issues/21))
remain a separate design-first workflow from root snapshots. Small editor/manual
changes may land independently rather than wait for a storage project.

### Immediate handoff

1. **Keep the accepted baseline.** Unattended input is merged and parked;
   Try Sensible has positive user validation. No new harness or generic desktop
   retest is the immediate assignment.
2. **Recommend #11 as the next bounded feature.** Retain the current swapfile,
   size rules and resume parameters; add explicit ZRAM configuration/priorities,
   graceful fallback, tests and manual tips. Coordinate #8's wording, without
   assuming ZRAM solves Secure Boot limitations. Before default enablement,
   record memory-pressure, shutdown and applicable hibernate/resume results.
3. **Keep the other useful scopes visible.** #7 navigation, #9 pre-wipe safety,
   Snapper recovery, KDE defaults and the AI manual are distinct follow-ups.
   The reported KDE wallet error now has a separate cross-desktop bugfix scope
   in #29, ahead of cosmetic KDE work; it is not evidence that autologin can
   safely decrypt stored secrets without a supported unlock mechanism.
   These scopes now have linked GitHub tickets in #28; use the existing issues
   rather than creating duplicates when a slice is selected.
4. **Maintain evidence without blocking development on automation.** Record
   targeted #13/#6 checks as available and retain the release gate. No issue
   closures, release publication or feature implementation are performed by
   this planning update; issue creation only makes the backlog actionable.

### Recommendations: adopt, narrow or defer

The external recommendations are proposals, not evidence of prior decisions.

| Recommendation | Disposition and correction |
| :--- | :--- |
| System-level switches for defaults | Adopt the reversibility goal, not one universal switch. Shell defaults are copied into skel; Git already uses `/etc/gitconfig`, and GNOME already uses unlocked system dconf defaults. Separate optional styling from idle/resume locking before adding opt-outs. |
| `sensible-doctor` | Adopt incrementally after shared validators/provenance exist. Start with read-only evidence, explicit unknown states and redacted JSON; do not make a large diagnostic framework a prerequisite for #5. |
| Build provenance / `sensible-info` | Retain as deferred infrastructure, paired with footprint reporting. Distinguish the baked build inventory from the installed system's later package state. |
| Declarative `sensible-apps` | Adopt a small common catalog; reconcile Brave Origin, Audacious, developer tools and optional AI entries. BioPass needs separate PAM/removal validation; LazyVim is an opt-in configuration for the included Neovim, not a reason to remove Neovim. |
| Save interactive answers | Adopt a sanitized export follow-up to #4, not automatic replay authorization. Omit secrets and target disk, clear wipe confirmation, and require fresh inputs/revalidation. |
| Pin Debian archive snapshots | Evaluate after provenance is available. Use one archive selection for the package gate and build; keep a rolling Testing canary or reviewed bump builds. Snapshotting only the target archive is not complete ISO reproducibility. |
| Size/package deltas and a hard budget | Adopt reports now; select warning/failure thresholds after comparable baselines exist. The old numbers in OFFLINE_REWORK.md are already labeled historical, not a current agreed cap or proof of unnoticed regression. |
| Installer dry-run in ISO smoke | Adopt a narrowly defined image/payload check, shared with #9. The existing smoke attaches a disposable 10 GiB disk and waits for live serial markers; no-disk checking needs a distinct mode, not the normal disk-selection flow. |
| Auto-file weekly build failures | Defer until stage classification is useful. Deduplicate/update one tracking issue, distinguish archive failures from infrastructure/pins/tests, and use a trusted write-capable job isolated from PR build code. |
| Generate manual HTML from Markdown | Defer. The manual is already multi-page and has different readers from the developer specs. Reuse structured app metadata first; do not add Pandoc and migrate stable anchors/navigation merely to accompany the AI chapter. |
| Make Vim default / move LazyVim out | Do not adopt the forced-default proposal. User decision: include both Vim and Neovim, retain Debian's editor selection, remove Sensible's `EDITOR`/`VISUAL` override and make LazyVim opt-in. Current source still forces Neovim until this follow-up lands. |

### Small follow-up contracts

#### Merged contract: validated unattended input (#4, PR #17)

The following contract is implemented and merged, not a new feature proposal.
It adds an input adapter to the existing installer, not a second installation
engine. The v1 specification is in
[INSTALLER_SPEC.md](INSTALLER_SPEC.md#unattended-mode-planned--release-test-infrastructure).

1. **Parser and schema:** parse TOML without shell evaluation; reject unknown
   CLI options/keys, duplicate or mistyped fields and missing required values.
   Use a maintained TOML parser available offline in the image; explicitly stage
   and test its runtime dependency. No desktop-selection or optional-app keys.
2. **Shared validation and protected secrets:** factor prompt-independent
   validation out of the form helpers. Keep the existing unified account/root
   recovery/LUKS password contract, supplied through a protected local file.
   Reject invalid identity, locale, timezone, keyboard, filesystem and
   autologin-without-LUKS inputs before applying settings or touching the disk.
3. **One execution path:** normalize interactive/config input into the same
   execution state. Explicit target plus `confirm_wipe = true` replaces only
   the unattended confirmation prompt, never candidate eligibility, minimum
   size, live-media exclusion, identity revalidation or offline boot preflight.
4. **No hidden interaction:** config mode must work without a controlling TTY.
   Skip welcome/forms, repair shells and completion/failure menus. Preserve
   logging and owned-resource cleanup; return success only after verification
   and teardown. V1 exits to its caller; the future VM harness owns poweroff,
   media detachment and booting the installed disk.
5. **Regression evidence:** add parser/secret tests and config-driven integration
   cases for both editions and all filesystem/encryption combinations. Prove
   invalid config, unsafe secrets, insufficient/missing wipe authorization,
   mounted/live/undersized or changed disks cannot reach partitioning. Assert
   no prompts, no secret output, correct failure status and cleanup on mandatory
   post-wipe failures. Existing interactive tests must remain green.
6. **Documentation and handoff:** ship a non-secret example with wipe permission
   disabled, document safe secret provisioning and the exit contract, and update
   the test guide. PR #17 established #4's adapter and fixture evidence; actual
   QEMU installs and detached-ISO boots belong to #5; further automation is
   currently parked by user decision.

The VM investigation also adds bounded pre-cleanup failure bundles and a dedicated
QEMU guest-to-host log channel; see [diagnostic export](INSTALL.md#qemu-testing-and-diagnostic-export).
The mount instrumentation preserves the existing options and does not retry
failed mounts. The user's successful install/boot retry is acceptance evidence,
not proof of a root-cause fix for the earlier intermittent failure.

Not included: profile export, a general dry-run/diagnostics tool, the expanded
#9 payload validator, new apps/themes, editor defaults or storage-policy changes.

#### Later follow-up contracts

**Desktop credentials (#29, bugfix lane):** distinguish KDE's GPG-key setup
error from a missing password for wallet decryption. Verify actual package/PAM
integration, provide a supported password-backed fresh-user path and preserve
existing encrypted stores. Test password login, autologin, available biometrics,
password changes/resets and live-to-installed isolation. Evaluate upstream GDM
disk-secret reuse separately; package configuration alone is not boot evidence.
Keep safe fallback prompts rather than blank passwords, disabled secret storage
or persistent plaintext credentials. No new auth mechanism is implemented by
this plan. See [Architecture](ARCHITECTURE.md#desktop-wallets-and-saved-credentials).

**Installed-disk harness (#5, parked):** retain this contract for when automation
resumes; it is not the immediate next PR. Accept an explicit ISO and record its checksum;
create fresh disposable QCOW2 disks in a private run directory, never accept a
host block device as the destructive target. Provision temporary config/secrets
without passwords in command lines, serial output or published artifacts. Use
the existing `--config` path, with deterministic install/boot markers, bounded
timeouts and failure bundles. A successful installer exit is only the end of
the install phase: detach the ISO, retain firmware variables, unlock LUKS where
applicable and validate the installed root, mounts, crypttab/fstab, swap/resume
configuration and desktop/login. Keep encrypted unlock input private. Record
each case as pass/fail/blocked with the reason; unavailable Secure Boot or session
checks must not silently pass. The first one-case PR builds the harness, not
completion of #5; expand to eight storage/edition cases plus installed Secure
Boot and archive evidence before closing that release gate.

**Sanitized profile export:** follow independently of merged #4; allowlist non-secret
preferences, omit disk identifiers and password hashes as well as passwords,
write with restrictive permissions, and make `confirm_wipe = false` explicit.
An export is an incomplete template, not a ready-to-run destructive command.

**Provenance and footprint (#20, deferred):** record schema/build ID, source commit and dirty
state, UTC build time, variant/architecture, builder image digest or native
toolchain versions, effective source configuration, the actual signed
InRelease/Release identities used, hook/pin digests and package versions.
Capture metadata while it is used, before APT cleanup; a fresh query after the
build is not its provenance. Retain the manifest in the copied target and expose
it through a simple `sensible-info`; report later installed-package drift
separately. Pair external metadata with the final ISO checksum rather than
trying to embed an ISO's own final hash inside itself. Attach per-edition
package inventories/metadata without losing the existing four required ISO and
checksum release assets or fail-closed tests. Report ISO/squashfs bytes, package
counts and largest installed packages; installed package size is not compressed
ISO contribution. Compare against an identified successful `main` build of the
same edition, or say baseline unavailable. No pruning the agreed app set or
arbitrary hard ceiling follows from these reports.

**Shared checks and diagnostics:** an image-check mode must exit without a target
disk, account prompts, network, mounts, formatting or reboot, and report exactly
which payload checks ran. It cannot pass disk suitability tests it did not run.
Reuse a side-effect-free validation module in the normal installer; do not
source its interactive lifecycle or fork a second validation implementation.
Keep installed-target checks as defense in depth. Later `sensible-doctor` may
collect boot/crypttab/swap/resume configuration, service health and pin drift,
with timeouts and `pass`/`fail`/`unknown`/`not-applicable` results. Missing session
access, privileges or hardware is not a pass. Do not auto-escalate, repair,
upload reports or dump raw journals containing identifiers/secrets. A valid
configuration or manifest is not proof of boot, hibernation, firmware operation
or snapshot restore; #5/#6 still require executing those paths.

**Reversible defaults:** consider stock Debian shell startup plus a guarded,
optional Sensible include, without rewriting existing users' dotfiles. Preserve
the selected Powerline theme unless the user opts out. Give system Git defaults
a Sensible-owned include rather than deleting unrelated `/etc/gitconfig` rules.
Keep GNOME appearance/extension defaults separate from screen-lock policy; a
cosmetic reset must not disable locking or weaken privacy defaults. Dconf needs
database regeneration and may need a new session; deleting a file alone is not
a universal live reset. Test fresh/existing users, missing include files and
user overrides, and document per-component disable/re-enable behavior in the
manual instead of starting another overlapping opinions document.
See [GNOME's system-defaults guidance](https://help.gnome.org/system-admin-guide/dconf-custom-defaults.html).

**One optional-app catalog (#24):** start with noninteractive `list`/`status` and one
Debian-backed install/remove path; add source adapters only for approved entries.
Store rationale, source identity, verification, dependencies, license, update
owner, removal behavior and network/first-run requirements as data, not shell
snippets to evaluate. Later adapters may cover Flatpak, scoped signed APT origins
and verified local packages; Python or other AI installation routes need explicit
review, not an arbitrary-command escape hatch. Preserve existing repositories,
shared dependencies and user data during removal. Require explicit privilege
and source-change approval. A Gum checklist is a frontend, not a second backend.
Brave Origin remains the curated browser; do not substitute regular Brave.
BioPass/PAM and LazyVim user-config migrations need dedicated acceptance, not
the assumption that any entry is safely reversible because package removal works.

**Archive control and CI follow-ups:** a candidate snapshot must supply the
same suite/components to bootstrap, chroot and both package-gate paths; record
builder dependencies separately. Preserve signed metadata checks. Any expired
metadata exception must be restricted to the explicit historic snapshot source,
not the installed system's normal update configuration. Keep installed machines
on the intended update channel, not indefinitely frozen at the image timestamp.
Test refreshes and transient archive failures; keep snapshot availability and
cache costs visible. A scheduled rebuild of an unchanged frozen snapshot cannot
detect current Testing transitions: retain a rolling canary or test proposed
snapshot bumps before review. Do not auto-merge them. Provenance, dependency
consistency and byte-for-byte reproducibility are separate claims. A snapshot
constrains Debian input versions; it does not by itself guarantee a solvable
package set or byte-identical ISO outputs. [Debian snapshot documentation](https://snapshot.debian.org/).

**Editor decision (#26, confirmed):** include both `vim` and `neovim`; let Debian's
normal editor selection and user preferences apply. Remove Sensible's exported
`EDITOR=nvim` / `VISUAL=nvim`, do not force a replacement value or a Git editor,
and do not call `update-alternatives --set editor` to choose either editor.
Package maintainer scripts may still register their normal alternatives.
Make LazyVim an explicitly chosen configuration, not a first-launch bootstrap
from a default skel directory. Move its starter/pin staging out of the default
image path, retain its initial-network requirement in optional instructions,
and never delete an existing user's Neovim setup. This does not remove the
already selected Powerline/Nerd Font support. Update package lists, pins, skel,
shell defaults, tests and manual in one small editor-only PR. Verify both plain
editors start offline, ordinary `editor` callers follow Debian's selected
alternative, and later admin/user choices survive. Current image sources remain
Neovim/LazyVim until that PR lands.
[Debian alternatives documentation](https://manpages.debian.org/testing/dpkg/update-alternatives.1.en.html).

---

Sensible (aka Lazydeb) implementation order. Architecture and installer spec
are living sources of truth, not frozen contracts: update them whenever a
beginner-journey, safety, reliability, or verified platform constraint requires
a behavior change. Keep the documents and implementation synchronized.

A checked implementation item means the repository implements it and has direct
code or automated-test evidence. Dated acceptance entries explicitly distinguish
CI, container checks and user-reported feedback. None of these alone means the
release is ready or that a mocked installer flow proves a real disk can boot.

```
Phase 1  Build harness (live-build ISO, TUI live session)
    → Phase 2  Installer engine (disk + chroot + boot)
        → Phase 3  Hardware packages (firmware, PipeWire, GPU, fwupd)
            → Phase 4  Desktops + keyd + default apps
                → Phase 5  CI and release plumbing
                    → RELEASE GATE  Automated input + installed tests + hardware evidence
                        → Phase 6  Sensible extras (biometrics, shell, git, firewall)
```

Phase 3 is hardware, Phase 4 is desktop. Do not swap those.

---

## Phase 1 — Build harness

Reproducible `live-build` in Docker/Podman. Output: a hybrid UEFI ISO that boots
to a console with NetworkManager and the required live firmware available.

- [x] `live/Dockerfile` + `live/build.sh`
- [x] `live/auto/config`: `testing` (Forky), `main contrib non-free non-free-firmware`, `linux-image-amd64`, `iso-hybrid`, GRUB EFI
- [x] Live packages: systemd, sudo, `rsync`, `debootstrap`, `dialog` or `whiptail`, `gdisk`, `parted`, `cryptsetup`, `btrfs-progs`, `e2fsprogs`, `dosfstools`, NetworkManager, **the same firmware set as the target** (otherwise Wi-Fi laptops cannot install)
- [x] `scripts/smoke-boot.sh` and CI boot the ISO in headless UEFI QEMU and assert a stable marker from the live serial autologin shell; this is an ISO-boot smoke, not an installed-disk test
- [x] Artifact names: `sensible-gnome-debian-testing-amd64.iso` and `sensible-kde-debian-testing-amd64.iso`

The default live entry boots to the console installer. The boot menu's "Try
Sensible" entry boots the baked GNOME or KDE closure as a live desktop with an
**Install Sensible** launcher (`sensible-live-desktop.service`, templates in
`live/config/bootloaders/`); the CI smoke covers only the console entry.

---

## Phase 2 — Installer engine

`installer/sensible-install.sh` against the spec. Success = reboot into the
desktop edition baked into the selected release image.

- [x] Pre-flight: UEFI, detailed disk list, RAM, minimum size, destructive confirmation
- [x] Guided Btrfs/Ext4 × LUKS on/off choices, with one fixed three-partition GPT layout and a root-hosted swapfile
- [x] crypttab/fstab as in the spec (UUID fstab; LUKS: swapfile on encrypted root; `resume=`/`resume_offset=` for both modes)
- [x] User, hostname, locale, keyboard, timezone
- [x] GRUB EFI + `cryptsetup-initramfs` + Plymouth hook (theme can stay `spinner` until Phase 4)
- [x] Secure Boot: `shim-signed` + `grub-efi-amd64-signed` chain on the installed system (`grub-install` stages the signed chain + module tree under `/EFI/debian`)
- [x] Secure Boot on the **live ISO** — native live-build `--uefi-secure-boot enable`, with an enforced OVMF Secure Boot smoke path (`SMOKE_FIRMWARE=sb`) that uses Microsoft keys and must reach the live session

The real-install matrix (GNOME/KDE × Btrfs/Ext4 × LUKS on/off) remains
unproved and is part of the release gate below. Unit and sourced-shell
integration tests do not close that gap.

---

## Phase 3 — Hardware

Make the installed system useful on a real laptop **before** polishing the DE.

- [x] Seed the package set from Architecture §6 (firmware names, PipeWire + `libspa-0.2-bluetooth`, PPD, `fwupd`)
- [x] `nvidia-driver` in the offline closure; NVIDIA detection enables its KMS argument
- [x] Enable NetworkManager, bluetooth, `power-profiles-daemon`, `fwupd`

Physical Intel and AMD smoke coverage is intentionally part of the release gate
below, not an optional follow-up.

---

## Phase 4 — Desktop and apps

- [x] GNOME (`gnome-core`, gdm3) or Plasma (`kde-plasma-desktop`, sddm), Wayland default
- [x] Plymouth theme: spinner / breeze
- [x] Optional autologin (LUKS only, default on) + enforced idle screen lock on both DEs
- [x] `keyd` + `configs/keyd-default.conf` when Mac clipboard is on
- [x] Desktop app configuration: Firefox ESR + Chromium, ONLYOFFICE Desktop Editors, Thunderbird, KeePassXC, VLC, Neovim + pinned LazyVim skel, archive support, CLI set, Flatpak, and native GNOME/KDE utilities
- [x] Office replacement source: complete upstream ONLYOFFICE `9.4.0-129`
      amd64 `.deb`, pinned SHA256/identity, free office fonts, XWayland, scoped
      user-overridable office file defaults, build-time payload guard and manual.
      LibreOffice remains an optional post-install Debian alternative. No extra
      APT source; updates to the upstream package require a reviewed new pin.
- [x] PR #16 GNOME/KDE ISO builds and UEFI live-boot smoke pass in CI.
- [x] User reports the latest GNOME build works as expected with recent desktop
      changes (2026-09-08); broad smoke feedback, not an itemized release matrix.
- [x] User reports KDE validation done and OK (2026-09-08); both desktop
      baselines have positive validation, separate from the installed-disk matrix.
- [ ] Remaining office acceptance: test fresh offline GNOME/KDE
      sessions, create/save/reopen DOCX/XLSX/PPTX and representative ODF files,
      PDF export/printing, fonts/scaling, file defaults and user overrides.
      Measure image footprint and runtime memory; audit corresponding-source
      availability/notices for release redistribution. Fixture/container checks
      do not establish visual fidelity or replace this release gate.

Office preparation evidence (2026-09-06): the downloaded upstream `.deb` matches
the release asset's SHA256. Real cached staging and installation into a fresh
Debian Testing container succeeded with networking disabled, including the
production payload/linker hook and office MIME lookups. An ordinary-user Xvfb
launch and normal window close passed without sandbox-disabling flags. An earlier
test's forced SIGTERM cleanup produced SIGSEGV; the host recorded no core, so
the mechanism is unresolved and shutdown still needs checking in real sessions.

- [x] Flathub is preconfigured system-wide with its signing key via a static
      `.flatpakrepo`; the build hook initializes/verifies it without downloading
      app metadata. No installer/first-login network setup or preinstalled Flatpaks.
- [x] Debian-packaged Chromium and the native GNOME/KDE media utilities are
      baked into their images; Brave and alternative apps remain post-install
- [x] Do not preinstall Slack/Zoom/etc.
- [ ] Implement the agreed [desktop profiles](DESKTOP_PROFILES.md): Shotwell /
      digiKam, LocalSend, GNOME extensions, native KDE equivalents and reviewed
      defaults. Keep optional theme and backup choices distinct from shipped scope.
  - [x] Application/dependency configuration: photo tools, pinned LocalSend,
        phone integration, management tools, explicit runtime deps and sharing rules.
  - [x] Both edition ISO builds and live UEFI smoke jobs pass for PR #16.
  - [ ] Complete targeted offline app startup and actual discovery/transfer
        checks with UFW enabled. Both editions have positive user validation;
        record itemized results and image/resource impact before release.
  - [x] GNOME profile image configuration: curated extension activation,
        build-validated pins/dependencies, titlebar buttons and privacy-conscious
        fresh-user defaults. These are dconf defaults, not locks.
  - [x] Optional GNOME themes: pinned Marble Shell and Graphite GTK 3/4 + Shell
        assets, sources/licenses, build guards and offline manual guidance.
        Flat Remix/Transparent Shell remain blocked as recorded in the desktop
        profile plan.
  - [x] Requested GNOME appearance follow-up: Paper icons and Orchis GTK 3 as
        unlocked defaults; Papirus plus pinned Qogir/Matcha/Fluent GTK 3/4 + Shell
        standard/light/dark and complete Qogir icon variants, including SVG loader,
        cache/alias validation and manual selection/reset instructions. Retire the
        earlier four palette collections and Good-Old-Shell. Install complete
        GNOME components globally; no forced Shell/GDM/personal CSS override.
        Murrine omitted because Testing removed it; the selected GTK 3/4
        components do not depend on GTK 2.
  - [ ] Remaining theme session acceptance beyond the reported GNOME smoke:
        readability, scaling, menus/overview, dock,
        GTK 3/4 apps, libadwaita boundaries and unchanged login/lock behavior;
        confirm return to stock.
  - [ ] Validate the GNOME extensions in a real offline session across login,
        lock/reboot, laptop/desktop and multi-monitor cases; confirm user changes
        survive. Implement and validate the native KDE profile separately.
- [x] Offline HTML manual, permanent menu launcher, and per-user first-login
      autostart, shared by both build paths; unit and mocked installer tests.
- [ ] Validate first-login opening and subsequent-login suppression on real
      installed GNOME and KDE desktops, offline.

---

## Phase 5 — CI and release plumbing

- [x] `.github/workflows/build-iso.yml`: container `live-build`, APT cache, QEMU UEFI boot smoke, and direct, unarchived ISO + SHA256 artifacts
- [x] Scheduled rebuilds so Testing does not rot
- [x] Tag-only GitHub Release job attaches both variant ISOs + SHA256 files, isolated from PR-controlled code and gated by repository variable `SENSIBLE_RELEASE_READY == 'true'`

The job existing is not approval to publish. Keep
`SENSIBLE_RELEASE_READY` unset or `false` until every release-gate item below
has evidence for the candidate ISO.

---

## Release gate: Beginner journey and reliability

This phase blocks release publication and comes before extras or visual
redesign. Fix the underlying behavior first; a friendlier screen cannot make an
unsafe disk operation reliable.

- [x] **Offline before wipe:** the complete target closure is baked into the ISO, so no mirror check or package download can first fail after the old system is erased
- [x] **Keyboard before secrets:** choose and apply the live keyboard layout before NetworkManager Wi-Fi credentials, the LUKS passphrase, or the account password; use that same layout in initramfs. A dedicated visual typing test belongs to the UI pass
- [x] **Robust disk identity and revalidation:** show path, model, capacity, serial/stable identity where available; exclude mounted, swap-active, RAID/LVM/device-mapper, read-only, live, and undersized media; re-read identity and state immediately before wipe and abort on any change
- [x] **Owned cleanup and live sanitization:** track mounts and mappings created by this installer run and clean only those resources; remove live autostart, commands, branding, packages/state, staged source, and reused machine identity from the target
- [x] **Truthful failures and logs:** critical failures produce failure rather than success; non-critical skipped choices are summarized; terminal/package output is retained in sudo-readable `/var/log/sensible-install.log` and copied to the target, including post-wipe failure cleanup when possible
- [x] **Beginner install guide:** `docs/INSTALL.md` covers release download/checksum, trusted USB writing, requirements, destructive scope, offline flow, choices, first boot, updates, and honest support/log expectations
- [x] **Automated install input (source/fixture evidence):** protected `--config answers.toml` input, shared validation, explicit `confirm_wipe = true`, unchanged disk revalidation and exit-only completion; all eight mocked config combinations and failure-path regressions. See [INSTALLER_SPEC.md](INSTALLER_SPEC.md#unattended-mode). Real ISO execution remains part of the installed-disk gate below.
- [ ] **Real QEMU installed-boot matrix:** install each GNOME/KDE release image onto fresh virtual disks for Btrfs/Ext4 × LUKS on/off, then boot from those installed disks under UEFI (not the ISO); verify expected partitions, mounts, `fstab`/`crypttab`, swap/resume arguments, desktop/login, and the LUKS prompt where applicable. Include an installed-system Secure Boot boot
- [ ] **Physical hardware smoke:** install and first-boot the candidate on at least one Intel and one AMD amd64 UEFI machine; record disk selection, wired/Wi-Fi, graphics, audio input/output (`sensible-audio-check` output, internal speakers and headphones separately), suspend/resume, Secure Boot state, and `fwupd` detection. Document hardware unavailable for a check rather than silently treating it as passed
- [ ] **Release decision:** archive the candidate ISO checksum and matrix/hardware results, review all failures and warnings, then and only then set `SENSIBLE_RELEASE_READY` to `true` for the release tag

Partial implementation does not earn a check. The remaining unchecked items
require release-candidate virtual or physical installation evidence.

Release-blocking work is tracked in [#4: automated input](https://github.com/korq-apps/sensible/issues/4),
[#5: installed-disk QEMU matrix](https://github.com/korq-apps/sensible/issues/5)
(depends on #4), and [#6: physical hardware evidence](https://github.com/korq-apps/sensible/issues/6).
The final release decision still requires candidate checksums and reviewed results.

Additional follow-ups: [#7: back-navigation](https://github.com/korq-apps/sensible/issues/7),
[#8: Secure Boot/hibernation messaging](https://github.com/korq-apps/sensible/issues/8),
and [#9: complete offline package/asset validation](https://github.com/korq-apps/sensible/issues/9).
Current pre-flight validates boot package status and non-empty, version-matched
kernel/initramfs pairs; it does not validate the complete desktop/asset set.

**Later UI work:** after the safety mechanics above are implemented and tested,
add a guided/recommended path that explains defaults and keeps an advanced path
for explicit choices. The broader UI redesign may follow; it must not be used
to defer or waive this release gate.

---

## Phase 6 — Sensible extras (re-scoped for offline)

These were designed for a network installer that could `apt install` per-user
choices mid-run. Offline changes what each one *is*: anything from Debian is
**baked into the ISO** at build time (it costs image size, not install time,
and the package gate proves it resolves), anything third-party or optional
moves to the **post-install tool**, and the checkbox questions disappear
because the answer is decided when the image is built.

The newer [desktop profile plan](DESKTOP_PROFILES.md) establishes an explicit
exception for approved default applications/extensions sourced upstream: they
may be pinned, verified and baked at build time. This does not add downloads
to installation or first login; unselected optional software stays post-install.

The "bake into the ISO" items below live in `live/` (package lists,
`scripts/fetch-pins.sh` + `live/pins.env`, and the ufw hook), staged into the
image that the installer copies. The post-install items do not exist yet;
Architecture/spec sections mark them **(planned — post-install tool)**.

**Bake into the ISO** (Debian packages, no question asked):

- [x] Fingerprint login: `fprintd` + `libpam-fprintd` (Debian main; enrollment via GNOME/KDE settings, dormant without a reader). Already unconditional, so it simply joins the variant package list
- [x] oh-my-bash for all users: pinned clone → `/usr/share/oh-my-bash`, `configs/omb-bashrc` → `/etc/skel/.bashrc` (uses the verified `powerline-multiline` theme and wires zoxide/fzf/`batcat`/`fdfind`/eza). Debian's `fonts-powerline` and the pinned Nerd Font provide prompt symbols. **Offline:** fetched during the ISO build, not the install, so the pin is verified once on our machine; `/etc/skel` is populated in the image, which also removes the `useradd -m` ordering problem the network design had. `scripts/fetch-pins.sh` + `live/pins.env`
- [x] JetBrainsMono Nerd Font: pinned nerd-fonts release + SHA256 (Debian packages none). **Offline:** downloaded and checksummed at ISO build time by `scripts/fetch-pins.sh`; a rotted pin fails our build instead of a user's install. Only the four standard-spacing faces are baked, to keep the ISO small
- [x] git defaults: `configs/gitconfig` → `/etc/gitconfig` in the image. The installer still offers optional name/email for the user's `~/.gitconfig`; dropping those prompts is deferred to the first-boot/UI pass
- [x] `ufw` enabled, deny incoming / allow outgoing (config-file enable, never `ufw enable` in chroot); both editions allow TCP/UDP 53317 for LocalSend and TCP/UDP 1714–1764 for GSConnect/KDE Connect. Debian's IPv6-enabled defaults generate IPv4/IPv6 rules across interfaces and source addresses, not only trusted networks — `live/config/hooks/live/0300-ufw.hook.chroot`
- [x] Printing/scanning: `cups` + `ipp-usb` + `sane-airscan`; `simple-scan` (GNOME) / `skanlite` (KDE)
- [x] Audio: `alsa-ucm-conf` (SOF/SoundWire laptops expose no device without it), `alsa-topology-conf`, `alsa-utils`, and explicit `firmware-cirrus`/`firmware-intel-sound` in the closure; `sensible-audio-check` baked and run by the installer so live-session findings reach the completion screen; live mixer state dropped from the target. Known limit: Realtek + Cirrus CS35L56 laptops newer than Testing's `firmware-cirrus` snapshot stay silent (headphones work) until their per-model tuning migrates, brand-new models can additionally wait for a kernel quirk, and Debian packages no AMD SOF DSP firmware

**Move to the post-install tool** (`sensible-apps`, online, after first boot):

- [ ] Developer tools: `docker.io` + `docker-compose` + `lazygit` + `gh`; user **not** added to the docker group (root-equivalent). Was an installer checkbox, which is exactly the kind of question the offline rework removes, and these cost nothing to add after first boot
- [ ] BioPass face login: pinned `.deb` + SHA256 from [TickLabVN/biopass](https://github.com/TickLabVN/biopass), PAM via `pam-auth-update`. Third-party and young, so it does not belong in the offline image. This desktop PAM integration does not unlock LUKS; biometric authentication alone supplies no wallet/keyring decryption password, so access may still prompt unless another supported unlock path applies (see #29). State both limitations where it is offered.
- [x] Brave Origin is documented as a curated optional online app with its official installer; it is not preinstalled.
- [ ] One declarative post-install catalog for Brave Origin, Audacious and
  approved developer/AI tools, introduced through the small backend/adapters
  described in the reconciled queue above; Flathub itself is already configured.

**AI and CLI follow-ups (planned, tracked in #22–#25; AI delivery decision pending):**

- [ ] [Curated AI manual](AI_TOOLS.md): tool-selection rationale, safe usage,
  official optional installation/update/removal recipes, and current Linux
  support for Claude Code, Claude Desktop and ChatGPT desktop.
- [ ] Evaluate OpenCode as the first open-source CLI candidate and LLM as a
  complement. Decide small preinstalled core versus all-opt-in delivery before
  packaging; keep proprietary clients optional and installation/first login
  offline. Codex CLI, Gemini CLI and Aider are curated alternatives, not an
  agreement to bundle every agent.
- [ ] Evaluate tmux/tealdeer and an isolated Python-tool installation mechanism;
  reconcile with the existing `gh`/`lazygit` developer-tools scope above.
- [ ] Evaluate optional local inference separately; no bundled model weights,
  automatic downloads or inference services by default.

Acceptance requirements and issue-ready scopes are in [AI_TOOLS.md](AI_TOOLS.md).
These do not supersede the installer/release gate or desktop acceptance work.

---

## Phase 7 — Offline rework (v2)

The former installer resolved packages at install time against a moving
Testing archive, which is how `vdpau-driver-all` aborted the hardware stage
after the disk was already wiped. The current flow copies a build-validated
package closure from the live image and requires no network. See
[OFFLINE_REWORK.md](OFFLINE_REWORK.md) for the design record and decision table.

- [x] Variant-aware `live-build` (`SENSIBLE_VARIANT=gnome|kde`), two ISOs, plus a build-time package-closure check that fails the build on a missing name. Also fixed the chroot device nodes rootless podman cannot create, which silently made `/dev/null` a regular file
- [x] **Install by copying the live root.** No package download or archive
  resolution occurs on the install path. The implementation:
  - take the live-root copy branch unconditionally and delete the `debootstrap` fallback, so there is one deploy path rather than two that diverge
  - de-live the copy in the chroot: purge `live-boot`/`live-config`, remove the live `user` and its passwordless sudo drop-in, drop the getty autologin drop-ins, truncate `/etc/machine-id`, restore `graphical.target`
  - regenerate what is layout-specific: `fstab`, `crypttab`, the initramfs (so `cryptsetup` support is present), and GRUB on the target ESP
  - drop the hardware/desktop/apps package stages, whose names are now fixed when the ISO is built
  - keep `validate_installed_boot` as the gate; it already asserts the artifacts this path must produce
- [x] Branded console live session that launches straight into the installer
- [x] "Try Sensible" live desktop boot entry with a pinned installer launcher; `ptyxis`/`konsole` named per edition so `Terminal=true` launchers and the manual's terminal recipes work
- [x] Searchable Gum prompts with a branded welcome, detailed disk selection,
  filesystem and identity/locale choices, one destructive confirmation, and
  staged progress
- [x] GNOME and KDE build variants; both keep account creation in the installer
- [ ] `sensible-apps` post-install tool: the shared catalog tracked in Phase 6
      and the reconciled queue, not a separate implementation

---

## Loose ends

Small, real, and not owned by any phase.

- [x] **Concurrency guard on the build.** Both build entry points now take a
      shared per-checkout `flock` before touching staged config or live-build
      state. Two `./live/build.sh` runs share
      `live/` and destroy each other: the second one's pre-clean deletes the
      first's chroot mid-debootstrap. This happened during development and cost
      two builds. A race that does not crash can also produce a half-populated ISO.
- [x] **Keep one partition layout.** Btrfs and Ext4, with LUKS on or off, all
      use EFI + BOOT + ROOT with swap inside the root filesystem. The release
      matrix still covers all four storage combinations per desktop variant.
- [ ] **Retire the `resume=` claim where Secure Boot is on.** Hibernation is
      configured and works with SB off, but the kernel refuses it under
      lockdown. The installed system should say so rather than appearing to
      support hibernation it will decline.

---

## Adopted from Omarchy

Reviewed in this session; the design record is in
[OFFLINE_REWORK.md](OFFLINE_REWORK.md). Landed already: dialogs sized to their
content (the former confirmation summary was being truncated), an actionable
failure screen with a log tail and recovery menu, errors that offer the fix
rather than a dead end, and post-install boot verification.

Worth taking, not yet taken:

- [ ] **One sourceable form module** holding every question with its validation,
      shared by the installer and any first-boot path so wording and rules
      cannot drift. This is the natural home for back-navigation
- [ ] **Back-navigation** via an explicit status protocol (`0` ok / `1` back /
      `130` side-channel), so a wrong answer on screen 3 does not mean starting
      over
- [ ] **A step runner** (`run_logged`-style): each step in its own `bash -eE`
      child with stdin closed, a machine-parseable Starting/Completed/Failed
      grammar, and a debug switch — a progress display can then read the log
- [ ] **Acceptance testing that boots the installed disk**, not just the live
      medium. Omarchy drives QEMU via QMP with OCR and virtual keystrokes;
      `validate_installed_boot` asserts the artifacts, but nothing yet proves
      them against real firmware

---

## Storage and recovery follow-ups

These are user-facing candidates in the proposed queue, not gated on building
an unattended harness first. Their own real-system acceptance is still required.

- **Hybrid ZRAM and disk swap ([#11](https://github.com/korq-apps/sensible/issues/11)).**
  Implemented on `feat/zram-swap` as compressed RAM swap ahead of the persistent
  RAM-sized swapfile, not instead of it; merge waits for the issue's evidence. Retain the disk-backed hibernation target and require the
  issue's memory-pressure, fallback, shutdown and hibernate/resume tests across
  the existing storage matrix. Coordinate Secure Boot messaging with #8. This
  is independent of Btrfs snapshots; do not combine both storage changes in one PR.
- **Separate follow-up after desktop apps: Btrfs snapshots and recovery ([#19](https://github.com/korq-apps/sensible/issues/19)).**
  Configure Snapper only when Btrfs is selected; leave Ext4 unchanged. Reuse the
  existing mounted `@snapshots` layout safely rather than blindly running
  `snapper create-config /` over `/.snapshots`. Include snapshot creation policy
  (timeline and/or APT hooks), cleanup/retention limits and a tested first baseline.
  Evaluate pinned, build-time `grub-btrfs` integration separately from permanent
  restoration: booting a snapshot is not itself a rollback. Resolve the explicit
  `subvol=@` mount, separate ext4 `/boot` and kernel/module consistency, encrypted
  root discovery (LUKS2 Argon2id), read-only boot writability and Secure Boot before
  documenting a recovery command. Do not advertise `snapper rollback` plus
  `update-grub` as sufficient for this layout. Require installed-disk reboot and
  restore evidence with LUKS on/off. Home, logs and swap are separate subvolumes;
  root snapshots do not replace personal-file backups. No target-time source
  cloning/builds; snapshot tooling is not yet implemented.

## Later (not v1)

- TPM2 LUKS auto-unlock (`systemd-cryptenroll` or clevis + `clevis-initramfs`); with biometrics this completes the Windows Hello flow — PCR policy must account for the unencrypted `/boot`, and Secure Boot in v1 strengthens the measurements
- FIDO2 hardware keys for sudo/polkit (`libpam-u2f`, enrollment via `pamu2fcfg`)
- GUI NVIDIA/MOK enrollment (unsigned NVIDIA module is rejected under Secure Boot lockdown)
- GUI installer
- Super+A / Super+Z if we find a terminal-safe mapping

---

## Risks

| Risk | Mitigation |
| :--- | :--- |
| Testing transition breaks the ISO | Capture actual archive provenance; evaluate consistent snapshot inputs and a rolling canary, not mixed archive states or blind retries |
| Wrong firmware package names | Use the Architecture list (`firmware-brcm80211`, not `firmware-broadcom`) |
| Initramfs unlock / Plymouth fail | Unencrypted `/boot`; crypttab only; `update-initramfs -u -k all`; release-gate QEMU LUKS installs |
| Target disk changes between selection and wipe | Stable identity plus immediate pre-wipe revalidation; block release until destructive-device tests pass |
| Offline closure is incomplete | Validate every Debian package at build time and fail closed if the archive query itself fails |
| Mocked tests hide an unbootable install | Real GNOME/KDE × Btrfs/Ext4 × LUKS on/off installed-disk QEMU matrix is release-blocking |
| Brave or AI CLIs add untrusted install paths | Official optional install routes; any approved AI image artifacts require pins, license/dependency review and an installed-system update path ([AI_TOOLS.md](AI_TOOLS.md)) |
| BioPass is young third-party PAM code (Phase 6) | Checkbox off by default; pinned `.deb` + SHA256; PAM via `pam-auth-update` so removal is clean; `fprintd` covers fingerprint without it |
| Pinned artifacts rot (BioPass, Nerd Font, oh-my-bash, LazyVim) | Versions + SHA256 recorded in one place; CI fails loudly when a pin 404s |
| live-build silently skips misnamed hooks | Hooks must match `*.hook.{chroot,binary}`; unit test enforces the naming |
| Live ISO too large | Keep separate GNOME/KDE images and review every addition to the baked offline closure |
| Release variable is enabled without evidence | Treat matrix/hardware records as the gate; the variable is only the final switch, never proof by itself |
