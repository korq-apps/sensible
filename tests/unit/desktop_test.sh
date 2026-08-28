#!/usr/bin/env bash
# Unit tests for installer/lib/desktop.sh — DE package sets, Plymouth theme,
# keyd config (spec §11: no generated fallback mapping).
TEST_NAME="desktop_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/desktop.sh"

TMP_MNT="$(mktemp -d)"
MNT="${TMP_MNT}"
CONFIG_DIR="${REPO_ROOT}/configs"

chroot() { mlog "chroot $*"; }

t_section "GNOME: package set, spinner theme, gdm3, keyd config file copied"
mock_setup
install_desktop gnome true "${CONFIG_DIR}"
calls="$(cat "${MOCK_LOG}")"
assert_contains "installs gnome-core" "${calls}" "gnome-core"
assert_contains "installs gdm3" "${calls}" "gdm3"
assert_contains "installs gnome-software-plugin-flatpak" "${calls}" "gnome-software-plugin-flatpak"
assert_contains "installs plymouth" "${calls}" "plymouth plymouth-themes"
assert_contains "spinner theme" "${calls}" "plymouth-set-default-theme -R spinner"
assert_contains "enables gdm3" "${calls}" "systemctl enable gdm3.service"
assert_contains "installs keyd" "${calls}" "keyd"
assert_file_exists "keyd default.conf deployed" "${MNT}/etc/keyd/default.conf"
if diff -q "${CONFIG_DIR}/keyd-default.conf" "${MNT}/etc/keyd/default.conf" >/dev/null; then
    t_ok
else
    t_fail "keyd conf matches configs/keyd-default.conf" "files differ"
fi
assert_file_contains "Super+C maps to Ctrl+Insert (no SIGINT)" "${MNT}/etc/keyd/default.conf" "c = C-insert"
assert_file_not_contains "no Super+A mapping" "${MNT}/etc/keyd/default.conf" "a ="
assert_not_contains "no sddm for GNOME" "${calls}" "sddm"
mock_teardown

t_section "KDE: package set, breeze theme, sddm, keyd skipped"
mock_setup
rm -rf "${MNT}/etc/keyd"   # gnome section deployed a conf into the shared tmp root
install_desktop kde false "${CONFIG_DIR}"
calls="$(cat "${MOCK_LOG}")"
assert_contains "installs kde-plasma-desktop" "${calls}" "kde-plasma-desktop"
assert_contains "installs sddm" "${calls}" "sddm"
assert_contains "installs plasma-discover flatpak backend" "${calls}" "plasma-discover-backend-flatpak"
assert_contains "breeze theme" "${calls}" "plymouth-set-default-theme -R breeze"
assert_contains "enables sddm" "${calls}" "systemctl enable sddm.service"
assert_not_contains "no keyd when disabled" "${calls}" "keyd"
assert_file_not_exists "no keyd config when disabled" "${MNT}/etc/keyd/default.conf"
assert_not_contains "no gdm3 for KDE" "${calls}" "gdm3"
mock_teardown

t_section "KDE with keyd: conf still comes from configs/, not generated"
mock_setup
install_desktop kde true "${CONFIG_DIR}"
assert_file_exists "keyd conf deployed for KDE+keyd" "${MNT}/etc/keyd/default.conf"
mock_teardown

t_section "Missing keyd config hard-fails instead of generating a second mapping"
mock_setup
rm -rf "${MNT}/etc/keyd"   # previous section deployed a conf into the shared tmp root
rc="$(run_exiting install_desktop gnome true /nonexistent/configs)"
assert_rc "aborts with exit 1" 1 "${rc}"
assert_file_not_exists "no generated fallback conf" "${MNT}/etc/keyd/default.conf"
mock_teardown

t_section "configure_login: GNOME idle lock defaults + GDM autologin"
mock_setup
configure_login gnome true alice
assert_file_contains "dconf profile" "${MNT}/etc/dconf/profile/user" "system-db:local"
assert_file_contains "idle lock after 300s" "${MNT}/etc/dconf/db/local.d/00-sensible-lock" "idle-delay=uint32 300"
assert_file_contains "lock enabled" "${MNT}/etc/dconf/db/local.d/00-sensible-lock" "lock-enabled=true"
assert_file_contains "lock immediately on idle" "${MNT}/etc/dconf/db/local.d/00-sensible-lock" "lock-delay=uint32 0"
assert_contains "dconf db compiled" "$(cat "${MOCK_LOG}")" "dconf update"
assert_file_contains "GDM autologin enabled" "${MNT}/etc/gdm3/daemon.conf" "AutomaticLoginEnable=True"
assert_file_contains "GDM autologin user" "${MNT}/etc/gdm3/daemon.conf" "AutomaticLogin=alice"
mock_teardown

t_section "configure_login: SDDM autologin + kscreenlocker defaults"
mock_setup
configure_login kde true bob
assert_file_contains "KDE autolock" "${MNT}/etc/xdg/kscreenlockerrc" "Autolock=true"
assert_file_contains "KDE lock on resume (suspend cover)" "${MNT}/etc/xdg/kscreenlockerrc" "LockOnResume=true"
assert_file_contains "KDE idle timeout" "${MNT}/etc/xdg/kscreenlockerrc" "Timeout=5"
assert_file_contains "SDDM autologin user" "${MNT}/etc/sddm.conf.d/autologin.conf" "User=bob"
mock_teardown

t_section "configure_login: without autologin the lock defaults still apply"
mock_setup
rm -rf "${MNT}/etc/gdm3" "${MNT}/etc/sddm.conf.d"   # drop-ins from earlier sections
configure_login gnome false alice
assert_file_contains "idle lock defaults present" "${MNT}/etc/dconf/db/local.d/00-sensible-lock" "lock-enabled=true"
assert_file_not_exists "no GDM autologin" "${MNT}/etc/gdm3/daemon.conf"
mock_teardown
mock_setup
configure_login kde false alice
assert_file_not_exists "no SDDM autologin" "${MNT}/etc/sddm.conf.d/autologin.conf"
assert_file_contains "KDE lock defaults present" "${MNT}/etc/xdg/kscreenlockerrc" "Autolock=true"
mock_teardown

rm -rf "${TMP_MNT}"
t_summary
