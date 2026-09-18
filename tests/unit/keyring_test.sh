#!/usr/bin/env bash
# Unit tests for the GNOME autologin login-keyring helper (installer/lib/keyring.sh).
TEST_NAME="keyring_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/keyring.sh"

TMP_DIR="$(mktemp -d /tmp/sensible-keyring-test.XXXXXX)"
mock_setup
trap 'mock_teardown; rm -rf "${TMP_DIR}"' EXIT

# chroot only runs chown here; record it instead of touching the host.
chroot() { mlog "chroot $*"; }

reset_target() {
    MNT="${TMP_DIR}/mnt"
    rm -rf "${MNT}"
    mkdir -p "${MNT}/home/alice"
    mock_reset
}

KR="home/alice/.local/share/keyrings"

t_section "GNOME autologin gets an auto-unlocking, default login keyring"
reset_target
configure_user_login_keyring gnome true alice
assert_rc "helper succeeds for gnome autologin" 0 $?
assert_file_exists "login keyring written" "${MNT}/${KR}/login.keyring"
assert_file_exists "default pointer written" "${MNT}/${KR}/default"
assert_file_contains "keyring is the plaintext (empty-password) format" "${MNT}/${KR}/login.keyring" "[keyring]"
assert_file_contains "keyring will not lock on idle" "${MNT}/${KR}/login.keyring" "lock-on-idle=false"
assert_eq "default names the login keyring" "login" "$(cat "${MNT}/${KR}/default")"
assert_eq "keyrings dir is private (0700)" "700" "$(stat -c '%a' "${MNT}/${KR}")"
assert_eq "login keyring is 0600" "600" "$(stat -c '%a' "${MNT}/${KR}/login.keyring")"
assert_eq "default pointer is 0600" "600" "$(stat -c '%a' "${MNT}/${KR}/default")"
if mock_has_call "chroot ${MNT} chown alice:alice /home/alice/.local/share/keyrings/login.keyring /home/alice/.local/share/keyrings/default"; then
    t_ok
else
    t_fail "keyring files are chowned to the user" "$(mock_last_call chown)"
fi
# No stray content beyond the two managed files.
assert_eq "only the two managed files exist" "2" "$(find "${MNT}/${KR}" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"

t_section "byte format is exact and stable"
assert_eq "empty keyring bytes match the daemon's plaintext format" \
    "$(printf '[keyring]\ndisplay-name=Login\nctime=123\nmtime=0\nlock-on-idle=false\nlock-after=false\n')" \
    "$(sensible_login_keyring_bytes 123)"

t_section "no-op outside the GNOME autologin case"
for combo in "gnome false" "kde true" "kde false"; do
    reset_target
    # shellcheck disable=SC2086
    configure_user_login_keyring $combo alice
    assert_rc "helper is a no-op for '${combo}'" 0 $?
    assert_file_not_exists "no keyring written for '${combo}'" "${MNT}/${KR}/login.keyring"
    assert_file_not_exists "no default written for '${combo}'" "${MNT}/${KR}/default"
done

t_section "a pre-existing keyring is never reinterpreted"
reset_target
mkdir -p "${MNT}/${KR}"
printf 'GnomeKeyring pre-existing encrypted store\n' > "${MNT}/${KR}/login.keyring"
existing_before="$(cat "${MNT}/${KR}/login.keyring")"
configure_user_login_keyring gnome true alice
assert_rc "helper succeeds without touching an existing keyring" 0 $?
assert_eq "existing keyring left byte-for-byte" "$existing_before" "$(cat "${MNT}/${KR}/login.keyring")"
assert_file_not_exists "no default forced onto an existing keyring" "${MNT}/${KR}/default"

t_section "unsafe paths and inputs are refused"
reset_target
ln -s /tmp "${MNT}/home/alice/.local"
configure_user_login_keyring gnome true alice
assert_rc "symlink in the keyring path is refused" 1 $?
reset_target
configure_user_login_keyring gnome true "../root"
assert_rc "invalid username is refused" 1 $?
reset_target
rm -rf "${MNT}/home/alice"
configure_user_login_keyring gnome true alice
assert_rc "missing home directory is refused" 1 $?

t_summary
