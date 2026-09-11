#!/usr/bin/env bash
# Unit tests: hybrid ZRAM + disk swap (#11). Compressed RAM swap is preferred
# through priorities; the RAM-sized swapfile stays the only hibernation target.
TEST_NAME="zram_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/fstab.sh"

TARGET_LIST="${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot"
ZRAM_CONF="${REPO_ROOT}/live/config/includes.chroot/etc/default/zramswap"
INSTALLER="${REPO_ROOT}/installer/sensible-install.sh"
TMP_DIR="$(mktemp -d /tmp/sensible-zram-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

t_section "zram-tools is part of the offline target closure"
assert_file_contains "zram-tools listed" "$TARGET_LIST" "zram-tools"
assert_file_contains "bc dependency listed explicitly" "$TARGET_LIST" "bc"
# Packages between the app marker and the dconf marker must be documented in
# the manual's application chapters; system swap tooling belongs before them.
apps_section="$(awk '/^# Apps — default set/{p=1} /^# dconf-cli/{p=0} p' "$TARGET_LIST")"
assert_not_contains "zram-tools sits outside the manual-checked app section" "$apps_section" "zram-tools"

t_section "Explicit ZRAM configuration is baked into the image"
assert_file_exists "zramswap defaults shipped" "$ZRAM_CONF"
if bash -n "$ZRAM_CONF"; then t_ok; else t_fail "zramswap config is valid shell" "bash -n failed"; fi
settings="$(grep -vE '^\s*(#|$)' "$ZRAM_CONF")"
assert_eq "only ALGO, PERCENT and PRIORITY are set" "ALGO=lz4
PERCENT=50
PRIORITY=100" "$settings"
assert_not_contains "no fixed SIZE overrides the RAM percentage" "$settings" "SIZE="
# shellcheck disable=SC1090
( . "$ZRAM_CONF"; [ "$ALGO" = lz4 ] && [ "$PERCENT" = 50 ] && [ "$PRIORITY" = 100 ] )
assert_rc "config sources with the documented values" 0 $?

t_section "The disk swapfile keeps a lower priority than ZRAM in fstab"
MNT="${TMP_DIR}/mnt"
mkdir -p "$MNT"
blkid() { printf 'UUID-%s\n' "${*: -1}"; }
zram_priority="$(. "$ZRAM_CONF"; printf '%s' "$PRIORITY")"
for fs in btrfs ext4; do
    generate_crypttab_and_fstab /dev/root /dev/boot /dev/efi "" /dev/root "$fs" false >/dev/null 2>&1
    swap_line="$(grep -E '^/(swap/)?swapfile ' "${MNT}/etc/fstab")"
    swap_pri="$(sed -nE 's/.*\bpri=([0-9]+).*/\1/p' <<< "$swap_line")"
    assert_contains "${fs}: swapfile line carries an explicit priority" "$swap_line" "pri="
    if [ -n "$swap_pri" ] && [ "$swap_pri" -lt "$zram_priority" ]; then t_ok
    else t_fail "${fs}: swapfile priority ${swap_pri:-unset} is below ZRAM priority ${zram_priority}" "priority order wrong"; fi
    assert_file_not_contains "${fs}: no resume parameters leak into fstab" "${MNT}/etc/fstab" "resume"
done

t_section "Installer enables the service without making it a hard dependency"
installer_src="$(<"$INSTALLER")"
assert_contains "target enables zramswap.service" "$installer_src" 'systemctl enable zramswap.service'
assert_contains "enable failure degrades to a warning, not an abort" "$installer_src" 'record_warning "ZRAM swap service could not be enabled'
hooks_src="$(cat "${REPO_ROOT}"/live/config/hooks/live/*.hook.chroot)"
assert_not_contains "no image hook masks the service" "$hooks_src" "zramswap"

t_summary
