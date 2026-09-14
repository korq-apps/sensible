# First official beta release

Status as of **2026-09-14**, reviewed source baseline **`58b1d02`**:
**ready for beta release preparation; hardware acceptance complete by maintainer
confirmation, publication pending.** The first official release is a **beta**.
On 2026-09-14 the maintainer confirmed that all necessary checks were completed
on the hardware available to them and explicitly removed the exhaustive test
matrix as a prerequisite for this beta. That decision supersedes the earlier
release checklist. The proposed first tag is `v1.0.0-beta.1`; it has not been created yet.

## Scope reconciliation

| Original v1 (`f52f133`) | Merged release scope |
| :--- | :--- |
| Console live ISO, network-installed desktop | Separate offline GNOME/KDE images; console installer plus Try Sensible with an installer launcher |
| Four filesystem/encryption choices | Btrfs/Ext4 × LUKS on/off, one EFI + BOOT + ROOT layout, persistent swapfile inside root |
| Secure Boot deferred | Debian-signed boot chain, ordinary UEFI and Secure Boot live smoke in CI; broader installed Secure Boot coverage remains follow-up work |
| Encrypted-root hibernation deferred | Disk-backed resume configuration with LUKS on/off; accepted KDE/VGA resume with Secure Boot off; hybrid ZRAM now preferred for runtime swap |
| Basic desktop/default apps | Curated GNOME profile/themes, KDE edition and native apps, ONLYOFFICE, LocalSend, Flathub and expanded CLI defaults |
| Build, smoke and tagged-release plumbing | Both edition builds/checksums, weekly rebuilds, direct-file artifacts, isolated tag-only publication job |
| No unattended input or first-login manual milestone | Validated protected TOML input, failure diagnostics/export, offline manual and first-login integration |

Native KDE styling, Back/Cancel improvements, Snapper recovery, personal backups,
editor neutrality, AI tooling/manuals and the optional-app catalog remain
post-release features. Broader pre-wipe validation (#9), Secure Boot messaging
(#8) and wallet integration (#29) must be reviewed against candidate findings;
an actual safety or supported-path failure takes precedence over this scope freeze.
An open roadmap issue alone does not make every enhancement a release requirement.

## Evidence at reconciliation

- All **19 local test suites pass** at `58b1d02`, including **684 installer-flow
  assertions**. Disk commands in that suite are mocked.
- [PR #33 CI](https://github.com/korq-apps/sensible/actions/runs/34783736035)
  passed tests, GNOME/KDE builds, and ordinary UEFI and Secure Boot live smoke
  for both images. Publication was skipped.
- The preceding [main build at `c6bdbc6`](https://github.com/korq-apps/sensible/actions/runs/34783417313)
  passed. The [post-merge build at `58b1d02`](https://github.com/korq-apps/sensible/actions/runs/34821712306)
  was **queued** when checked; the PR build is not a completed candidate build.
- Earlier user reports accept GNOME, KDE and Try Sensible. Recorded installed
  KDE validation covers ZRAM/swap and VGA hibernate/resume. PR #33 additionally
  marks controlled pressure/spillover, failure fallback and shutdown checks
  complete; its per-edition/layout comparison remains unchecked. Preserve the
  exact scope and older image identities in the [validation record](PLAN.md#validation-snapshot-updated-2026-09-14).
- GitHub returned no releases visible to the current account. Reading
  `SENSIBLE_RELEASE_READY` returned HTTP 403; its current value is **unknown**.
- #4 and #11 remain open despite merged implementations. #13 owns remaining
  GNOME evidence; #29 includes merged source diagnosis and first-use guidance
  with further session coverage retained as follow-up work. #5/#6 remain open
  under their older release-blocker titles; the beta decision below supersedes
  that classification locally. Remote issues have not been updated.

## Tested hardware and beta acceptance

The maintainer reports completing all necessary checks on these owned machines
(2026-09-14):

| Machine | Reported configuration | Beta acceptance |
| :--- | :--- | :--- |
| Dell XPS 15 (2020) | Laptop | Tested; accepted by maintainer |
| Lenovo Legion 7 15ASH11 | Laptop | Tested; accepted by maintainer |
| Custom desktop PC | Ryzen 7 7800X3D, 64 GB RAM, Radeon RX 7800 XT | Tested; accepted by maintainer |

This hardware report, earlier GNOME/KDE/Try Sensible feedback, installed KDE
swap/hibernation evidence and passing automated checks form the beta acceptance
basis. Per-machine ISO checksums, edition/storage combinations and firmware
settings were not enumerated; the report is recorded at its supplied level of
detail without requesting a repeat test campaign.

The full eight-case installed-disk matrix (#5), expanded hardware records (#6),
itemized desktop/manual/credential checks and comparative performance testing
remain follow-up coverage. They are **not blockers for this beta** and are not
marked as completed tests. Existing known limitations remain documented; new
reported defects should be triaged for fixes or release-note updates.

## Beta publication checklist

- [x] Maintainer accepts the first-beta scope and testing completed on owned hardware.
- [x] Record the tested hardware and known limitations.
- [ ] Finalize `v1.0.0-beta.1` and its source commit.
- [ ] Complete the selected build's existing CI checks and retain both edition
  ISO files with matching SHA256 files.
- [ ] Finalize these beta notes and publish as a GitHub **pre-release**, using
  the existing tag/publication gate. Do not present the beta as a stable release.

No new hardware campaign, exhaustive matrix or automation framework is required
for this beta. Broader coverage can grow through subsequent testing and feedback.

## Release summary

Sensible's first official **beta** release provides offline GNOME and KDE installation
images based on Debian Testing (Forky) for amd64 UEFI machines. Choose Install
Sensible or explore the desktop with Try Sensible before installing.

- Guided full-disk installation with Btrfs or Ext4 and optional LUKS2 encryption.
- Hardware firmware, PipeWire audio, network, printing/scanning and desktop
  applications included in the image; no installation-time package downloads.
- Curated desktop defaults, ONLYOFFICE, LocalSend, Flathub integration and an
  offline manual available from the application menu and on first login.
- Compressed ZRAM swap ahead of a persistent disk swapfile; disk-backed
  hibernation with Secure Boot off, subject to hardware/driver support.
- Protected unattended configuration and diagnostic export for testing.
- Clearer wallet/keyring first-use guidance, Secure Boot firmware-trust
  instructions and precautions for Windows on a separate disk.

Tested by the maintainer on a Dell XPS 15 (2020), Lenovo Legion 7 15ASH11,
and a custom Ryzen 7 7800X3D desktop with 64 GB RAM and Radeon RX 7800 XT.
This is a beta with testing concentrated on those machines; broader hardware
and configuration coverage will follow through testing and feedback.

Known limits to retain in the published notes:

- Installation erases the selected disk. Same-disk OS preservation, manual
  partition editing, legacy BIOS and non-amd64 systems are unsupported.
- Secure Boot needs firmware trust for the image's shim. Kernel lockdown blocks
  hibernation and unsigned NVIDIA modules; live Secure Boot success alone does
  not establish installed-system acceptance.
- A virtio-GPU VM can stall after hibernation image restoration; the recorded
  KDE test resumes successfully with standard VGA. Physical results vary.
- Autologin can leave saved-password stores locked. Fresh KDE users choosing
  GPG need a suitable key; the manual describes the password-backed alternative.
- Very recent hardware can need newer firmware/kernel support. AMD SOF DSP
  firmware availability and per-model speaker-amplifier files remain limitations.
- The system tracks Debian Testing. ONLYOFFICE is a pinned upstream package
  without an additional APT source; its updates need a reviewed new package.

See the [installation guide](INSTALL.md) for checksum verification, USB creation,
firmware settings, installation, first boot and troubleshooting.

## Download delivery

Release ISOs must remain single, directly usable files. Split downloads are
excluded by the maintainer's decision. The latest PR build produced roughly
3.57 GiB GNOME and 4.05 GiB KDE images, both above GitHub's per-asset limit.
The inspected local GNOME SquashFS already uses XZ compression. Further size
work may help, but fitting both images below 2 GiB has not been demonstrated.

The recommended first-beta route is one torrent per intact ISO, seeded by the
existing `it-m5plus` runner, with `.torrent` and SHA256 files attached to GitHub.
Read-only checks on 2026-09-14 confirmed that its Transmission service is active,
peer port 51414 reports open, DHT/peer exchange are enabled, and about 242 GB is
free on the root filesystem. Keep release copies outside the CI checkout so
build cleanup cannot remove seeded files. No torrents were added by this check.

Cloudflare R2 is the preferred optional direct-download mirror. The current
pair totals about 8.19 GB, within the Standard free allowance of 10 GB-month,
assuming no other account usage. The allowance also includes 1 million Class A
and 10 million Class B operations monthly; egress is free. Additional Standard
storage is $0.015/GB-month. Two equally sized release pairs retained throughout
a month would incur about $0.11 storage, allowing for rounding and assuming no
other usage. These are allowances, not a hard spending cap. Use a custom domain
for public downloads; `r2.dev` is a rate-limited development endpoint.
Sources checked 2026-09-14: [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
and [public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/).

Internet Archive is an additional preservation/direct-download option. Its
[upload guide](https://help.archive.org/help/uploading-a-basic-guide/) supports
software uploads with a free account. Its [BitTorrent documentation](https://help.archive.org/help/archive-bittorrents/)
explains that importing our torrent does not make Archive a seed for that
original torrent: it creates a separate Archive torrent. Keep edition/version
artifacts immutable and verify mirror checksums before linking them.

The prepared tag workflow retains each verified ISO outside the CI checkout,
creates a torrent and waits for Transmission to report complete, error-free
seeding. Its publication job attaches both torrents, magnet-link text files and
SHA256 files. R2/Archive accounts have not been configured; no tag or release
has been published yet.

The publishable notes are in [v1.0.0-beta.1.md](releases/v1.0.0-beta.1.md).

## Publication handoff

1. Select a beta version/tag and source commit, then finalize the notes with
   the tested hardware and known limitations. Maintainer hardware acceptance is
   already recorded above.
2. Use the existing workflow's `v*` tag and `SENSIBLE_RELEASE_READY` publication
   switch. Recheck the variable with an account able to read it. Ensure the
   GitHub release is marked **pre-release**. The prepared workflow changes
   set that flag for a prerelease tag; they are not committed or active yet.
3. The tag workflow builds fresh images from Debian Testing and seeds them
   from `/srv/storage/sensible-releases/<tag>/<edition>/`. Keep the tag-run
   build and smoke results and the published checksums as the artifact record;
   do not attribute those exact bytes to earlier hardware tests.
4. Verify both intact ISO downloads and their SHA256 files, and attach the
   beta notes and download links. Broader test coverage stays in the follow-up backlog.

This document prepares the beta. It does not create a tag, enable publication,
close issues or claim an official release already exists.
