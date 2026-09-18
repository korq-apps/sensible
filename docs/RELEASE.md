# First official beta release

Status as of **2026-09-14**: [**v1.0.0-beta.1 is published**](https://github.com/korq-apps/sensible/releases/tag/v1.0.0-beta.1)
as a GitHub **pre-release**, from source commit
`ed3db234d8ae34da883186457800f47121a872d2`. GNOME and KDE are available as intact
ISO files over BitTorrent, seeded by the project's runner.

The maintainer confirmed that all necessary checks were completed on owned
hardware and accepted that evidence for this first beta. The exhaustive test
matrix remains follow-up coverage; it is not a beta prerequisite. This decision
supersedes the earlier release checklist.

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
editor neutrality, AI tooling/manuals, biometric setup and the optional-app catalog remain
post-release features. Broader pre-wipe validation (#9), Secure Boot messaging
(#8) and wallet integration (#29) must be reviewed against candidate findings;
an actual safety or supported-path failure takes precedence over this scope freeze.
An open roadmap issue alone does not make every enhancement a release requirement.

## Evidence and publication record

- The [tag build](https://github.com/korq-apps/sensible/actions/runs/34828166637) at `ed3db23` passed all **20 test suites**, including
  **684 installer-flow assertions** and the release-seeding suite. Disk commands
  in the installer-flow suite are mocked. Both edition builds and their ordinary
  UEFI and Secure Boot live smoke checks passed.
- Both complete ISOs were SHA256-checked before retention and fully verified by
  Transmission. A 2 MiB piece from each was transferred from the runner over
  BitTorrent and checked against its torrent piece hash. This transfer check was
  over the LAN; Transmission separately reported the public peer port open.
- GitHub's six published assets (torrent, magnet text and ISO SHA256 per edition)
  were downloaded and checked against the retained seed metadata. The torrent
  names, sizes, piece counts and magnet infohashes were validated.
- [PR #33 CI](https://github.com/korq-apps/sensible/actions/runs/34783736035)
  passed tests, GNOME/KDE builds, and ordinary UEFI and Secure Boot live smoke
  for both images. Publication was skipped.
- The preceding [main build at `c6bdbc6`](https://github.com/korq-apps/sensible/actions/runs/34783417313)
  passed. The [post-merge build at `58b1d02`](https://github.com/korq-apps/sensible/actions/runs/34821712306)
  also passed. The tag build above identifies the published candidate.
- Earlier user reports accept GNOME, KDE and Try Sensible. Recorded installed
  KDE validation covers ZRAM/swap and VGA hibernate/resume. PR #33 additionally
  marks controlled pressure/spillover, failure fallback and shutdown checks
  complete; its per-edition/layout comparison remains unchecked. Preserve the
  exact scope and older image identities in the [validation record](PLAN.md#validation-snapshot-updated-2026-09-14).
- `SENSIBLE_RELEASE_READY` is enabled. The published GitHub release is explicitly
  marked as a pre-release; the tag identifies the source and the asset checksums
  identify the final image bytes.
- #4 and #11 remain open despite merged implementations. #13 owns remaining
  GNOME evidence; #29 includes merged source diagnosis and first-use guidance
  with further session coverage retained as follow-up work. #5/#6 remain open
  under their older release-blocker titles; the beta decision below supersedes
  that classification locally. Remote issues have not been updated.

### Published image identities

Both files belong to `v1.0.0-beta.1` from `ed3db23`:

| Edition | ISO bytes | BitTorrent infohash |
| :--- | ---: | :--- |
| GNOME | 3,841,982,464 | `14236c2601cf0b5e576e9b0370a17662fdc48495` |
| KDE | 4,347,205,632 | `beed113cbc8a89b42d9aa1164e18e32e40860c5c` |

```text
b4bdf229bc3a980b195562551a1b72e6add2bffa842a3e82e7aa5891e5264a9b  sensible-gnome-debian-testing-amd64.iso
bafd5dfef29c58113f950259057704998ea285425bf91598658299e877cc2120  sensible-kde-debian-testing-amd64.iso
```

## Tested hardware and beta acceptance

The necessary hardware checks are complete and accepted for the beta.

Hardware validation, earlier GNOME/KDE/Try Sensible feedback, installed KDE
swap/hibernation evidence and passing automated checks form the beta acceptance
basis. Per-machine ISO checksums, edition/storage combinations and firmware
settings were not enumerated; broader coverage remains follow-up work.

The full eight-case installed-disk matrix (#5), expanded hardware records (#6),
itemized desktop/manual/credential checks and comparative performance testing
remain follow-up coverage. They are **not blockers for this beta** and are not
marked as completed tests. Existing known limitations remain documented; new
reported defects should be triaged for fixes or release-note updates.

## Beta publication checklist

- [x] First-beta scope and completed hardware testing accepted.
- [x] Record the tested hardware and known limitations.
- [x] Finalize `v1.0.0-beta.1` at `ed3db234d8ae34da883186457800f47121a872d2`.
- [x] Complete the selected build's existing CI checks and retain both edition
  ISO files with matching SHA256 files.
- [x] Finalize these beta notes and publish as a GitHub **pre-release**, using
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

Beta hardware testing is accepted. Broader hardware and configuration coverage
will follow through testing and feedback.

Known limitations:

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

The published first beta uses one torrent per intact ISO, seeded by the
existing `it-m5plus` runner, with `.torrent` and SHA256 files attached to GitHub.
Read-only checks on 2026-09-14 confirmed that its Transmission service is active,
peer port 51414 reports open, DHT/peer exchange are enabled, and about 242 GB is
free on the root filesystem. Keep release copies outside the CI checkout so
build cleanup cannot remove seeded files. Both release torrents are now retained
and seeding from that location.

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

The tag workflow retains each verified ISO outside the CI checkout,
creates a torrent and waits for Transmission to report complete, error-free
seeding. Its publication job attaches both torrents, magnet-link text files and
SHA256 files. R2/Archive mirrors have not been configured.

The published notes are in [v1.0.0-beta.1.md](releases/v1.0.0-beta.1.md).

## Seed maintenance

The runner retains release files under
`/srv/storage/sensible-releases/<tag>/<edition>/`, outside its disposable CI
checkout. Keep the ISO, checksum, torrent and magnet file together. Transmission
starts on boot; release torrents have their ratio and idle-seeding limits
disabled individually. Its existing download directory and other torrents keep
their settings.

To inspect a release torrent on `it-m5plus`, use
`transmission-remote --torrent <infohash> --info`. A healthy retained release
must have all bytes verified and be seeding without an error. The daemon's
local peer listener is TCP/UDP 51413; it currently reports external port 51414
and a successful public port test. Preserve the router mapping when moving or
reconfiguring the host.

The public tracker reported a seed for each torrent, but peer-list requests
also timed out during publication checks. DHT and peer exchange are enabled.
The verified piece transfers above establish LAN serving; an independent
internet download was not performed.

Back up the small release metadata along with the retained ISO. A rebuild from
Debian Testing can produce different bytes even at the same source tag;
`scripts/seed-release.sh` refuses to replace an existing tag's ISO with different
bytes. Recovery should restore the original ISO and verify its published SHA256.
Changed images belong to a new release tag.

## Subsequent releases

1. Select a new version/tag and source commit, then finalize its release notes.
   Retain the accepted hardware evidence and update known limitations from feedback.
2. Use the workflow's `v*` tag trigger and `SENSIBLE_RELEASE_READY` publication
   switch. Beta tags must remain GitHub pre-releases.
3. Retain the tag-run build/smoke results and published checksums as the artifact
   record. Do not attribute freshly rebuilt bytes to earlier hardware tests.
4. Verify the retained seed and published metadata. Add direct-download mirrors
   only after their intact ISO checksums match the existing release.
