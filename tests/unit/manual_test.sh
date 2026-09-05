#!/usr/bin/env bash
# Unit tests for Sensible offline manual, opener, desktop entries, and installer autostart helper.
TEST_NAME="manual_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/manual.sh"

TMP_DIR="$(mktemp -d /tmp/sensible-manual-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT
TMP_MNT="${TMP_DIR}/mnt"
mkdir -p "${TMP_MNT}"
MNT="${TMP_MNT}"

chroot() { mlog "chroot $*"; }

t_section "Manual source and offline integrity"
assert_file_exists "manual/index.html exists" "${REPO_ROOT}/manual/index.html"
assert_file_exists "manual/manual.css exists" "${REPO_ROOT}/manual/manual.css"

manual_html="$(<"${REPO_ROOT}/manual/index.html")"
manual_css="$(<"${REPO_ROOT}/manual/manual.css")"

assert_contains "HTML has document language" "${manual_html}" '<html lang="en">'
assert_contains "HTML has viewport meta tag" "${manual_html}" '<meta name="viewport"'
assert_contains "HTML has skip link" "${manual_html}" 'class="skip-link"'
assert_contains "HTML contains main element with id" "${manual_html}" '<main id="main"'
assert_contains "HTML contains navigation landmark" "${manual_html}" '<nav'
assert_contains "HTML contains footer" "${manual_html}" '<footer'

# Required assets are self-contained; optional outbound support links are allowed.
assert_not_contains "No external http:// assets in CSS" "${manual_css}" "url(http://"
assert_not_contains "No external https:// assets in CSS" "${manual_css}" "url(https://"
assert_not_contains "No protocol-relative assets in CSS" "${manual_css}" "url(//"
assert_not_contains "No remote scripts in HTML" "${manual_html}" '<script src="http'
assert_not_contains "No remote stylesheets in HTML" "${manual_html}" '<link rel="stylesheet" href="http'

# Check that internal anchor links resolve to ids
while IFS= read -r anchor; do
    target_id="${anchor#\#}"
    if [ -n "${target_id}" ]; then
        if grep -q "id=[\"']${target_id}[\"']" "${REPO_ROOT}/manual/index.html"; then
            t_ok
        else
            t_fail "Internal link #${target_id} has matching id target in manual/index.html" "id not found"
        fi
    fi
done < <(grep -o 'href="#[a-zA-Z0-9_-]*"' "${REPO_ROOT}/manual/index.html" | sed -E 's/href="([^"]+)"/\1/')

# CSS Accessibility checks
assert_contains "CSS includes focus-visible styling" "${manual_css}" ":focus-visible"
assert_contains "CSS includes dark mode media query" "${manual_css}" "prefers-color-scheme: dark"

t_section "Desktop launcher and autostart packaging files"
assert_file_exists "permanent launcher desktop file exists" "${REPO_ROOT}/packaging/manual/sensible-manual.desktop"
assert_file_exists "autostart template desktop file exists" "${REPO_ROOT}/packaging/manual/sensible-manual-autostart.desktop"
assert_file_exists "manual opener script exists" "${REPO_ROOT}/packaging/manual/sensible-manual"

if [ -x "${REPO_ROOT}/packaging/manual/sensible-manual" ]; then
    t_ok
else
    t_fail "sensible-manual opener is executable" "missing +x"
fi

launcher_content="$(<"${REPO_ROOT}/packaging/manual/sensible-manual.desktop")"
autostart_content="$(<"${REPO_ROOT}/packaging/manual/sensible-manual-autostart.desktop")"

assert_contains "Launcher has Application type" "${launcher_content}" "Type=Application"
assert_contains "Launcher executes sensible-manual" "${launcher_content}" "Exec=/usr/local/bin/sensible-manual"
assert_contains "Launcher does not run in terminal" "${launcher_content}" "Terminal=false"
assert_contains "Launcher has documentation category" "${launcher_content}" "Categories=Documentation"

assert_contains "Autostart template has Application type" "${autostart_content}" "Type=Application"
assert_contains "Autostart template uses --first-login" "${autostart_content}" "Exec=/usr/local/bin/sensible-manual --first-login"
assert_contains "Autostart template does not run in terminal" "${autostart_content}" "Terminal=false"

t_section "Opener CLI handling and first-login idempotency"
OPENER="${REPO_ROOT}/packaging/manual/sensible-manual"

# Test unknown argument rejection
rc=0
"${OPENER}" --unknown-flag >/dev/null 2>&1 || rc=$?
assert_rc "opener rejects unknown flag with non-zero" 1 "${rc}"
rc=0
"${OPENER}" --first-login extra >/dev/null 2>&1 || rc=$?
assert_rc "opener rejects extra arguments" 1 "${rc}"

# Test --help
rc=0
"${OPENER}" --help >/dev/null 2>&1 || rc=$?
assert_rc "opener accepts --help with exit 0" 0 "${rc}"

# Test the real opener with a temporary manual path and mocked gio.
TEST_ENV_DIR="${TMP_DIR}/test-user-env"
TEST_MANUAL="${TMP_DIR}/manual/index.html"
PATCHED_OPENER="${TMP_DIR}/sensible-manual"
mkdir -p "${TEST_ENV_DIR}/state" "${TEST_ENV_DIR}/config/autostart" "$(dirname "${TEST_MANUAL}")"
printf '<!doctype html>\n' > "${TEST_MANUAL}"
sed "s#^MANUAL_PATH=.*#MANUAL_PATH=\"${TEST_MANUAL}\"#" "${OPENER}" > "${PATCHED_OPENER}"
chmod +x "${PATCHED_OPENER}"

MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gio" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOCK_OPEN_LOG}"
if [ "${MOCK_GIO_RC:-0}" -ne 0 ]; then
    exit "${MOCK_GIO_RC}"
fi
EOF
chmod +x "${MOCK_BIN}/gio"

MOCK_OPEN_LOG="${TMP_DIR}/gio.log"
: > "${MOCK_OPEN_LOG}"
export PATH="${MOCK_BIN}:${PATH}"
export XDG_STATE_HOME="${TEST_ENV_DIR}/state"
export XDG_CONFIG_HOME="${TEST_ENV_DIR}/config"
export MOCK_OPEN_LOG

cp "${REPO_ROOT}/packaging/manual/sensible-manual-autostart.desktop" "${TEST_ENV_DIR}/config/autostart/sensible-manual.desktop"

# A failed launch must not create the marker or remove autostart.
export MOCK_GIO_RC=1
rc=0
"${PATCHED_OPENER}" --first-login >/dev/null 2>&1 || rc=$?
assert_rc "failed first-login launch returns non-zero" 1 "${rc}"
assert_file_not_exists "failed first-login does not create marker" "${TEST_ENV_DIR}/state/sensible/manual-opened-v1"
assert_file_exists "failed first-login keeps autostart" "${TEST_ENV_DIR}/config/autostart/sensible-manual.desktop"

# A successful launch must create the marker and remove the per-user entry.
MOCK_GIO_RC=0
"${PATCHED_OPENER}" --first-login >/dev/null 2>&1
assert_file_exists "real first-login creates state marker" "${TEST_ENV_DIR}/state/sensible/manual-opened-v1"
assert_file_not_exists "real first-login removes autostart" "${TEST_ENV_DIR}/config/autostart/sensible-manual.desktop"
assert_contains "real opener passes local manual URI" "$(<"${MOCK_OPEN_LOG}")" "open file://${TEST_MANUAL}"
assert_not_contains "opener has no direct browser fallback" "$(<"${OPENER}")" "firefox"
assert_not_contains "opener has no sensible-browser fallback" "$(<"${OPENER}")" "sensible-browser"

open_count="$(wc -l < "${MOCK_OPEN_LOG}")"
"${PATCHED_OPENER}" --first-login >/dev/null 2>&1
assert_eq "real first-login is idempotent" "${open_count}" "$(wc -l < "${MOCK_OPEN_LOG}")"

# The permanent launcher remains independent of the first-login marker.
"${PATCHED_OPENER}" >/dev/null 2>&1
assert_eq "permanent launcher opens despite marker" "$((open_count + 1))" "$(wc -l < "${MOCK_OPEN_LOG}")"

t_section "Opener missing payload and handler fallback"
mv "$TEST_MANUAL" "${TEST_MANUAL}.saved"
rc=0
"${PATCHED_OPENER}" >/dev/null 2>&1 || rc=$?
assert_rc "missing manual fails clearly" 1 "$rc"
mv "${TEST_MANUAL}.saved" "$TEST_MANUAL"

BASH_BIN="$(command -v bash)"
FALLBACK_BIN="${TMP_DIR}/fallback-bin"
mkdir "$FALLBACK_BIN"
rc=0
PATH="$FALLBACK_BIN" "$BASH_BIN" "$PATCHED_OPENER" >/dev/null 2>&1 || rc=$?
assert_rc "no URI handler fails clearly" 1 "$rc"
cat > "${FALLBACK_BIN}/xdg-open" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOCK_OPEN_LOG}"
EOF
chmod +x "${FALLBACK_BIN}/xdg-open"
rc=0
PATH="$FALLBACK_BIN" "$BASH_BIN" "$PATCHED_OPENER" >/dev/null 2>&1 || rc=$?
assert_rc "xdg-open works when gio is absent" 0 "$rc"
assert_eq "fallback receives local file URI" "file://${TEST_MANUAL}" "$(tail -n 1 "$MOCK_OPEN_LOG")"


t_section "Installer configure_user_manual_autostart helper"
mock_setup
# Scenario A: missing username
rc=0
configure_user_manual_autostart "" >/dev/null 2>&1 || rc=$?
assert_rc "missing username returns error" 1 "${rc}"
mock_teardown

mock_setup
# Scenario B: missing template fails clearly
rm -rf "${MNT}/usr/share/sensible/manual"
rc=0
configure_user_manual_autostart "alice" >/dev/null 2>&1 || rc=$?
assert_rc "missing template returns non-zero" 1 "${rc}"
mock_teardown

mock_setup
# Scenario C: template present, configures user autostart with proper destination and ownership
bash "${REPO_ROOT}/scripts/stage-manual.sh" "$MNT"
mkdir -p "${MNT}/home/alice"

configure_user_manual_autostart "alice"
calls="$(cat "${MOCK_LOG}")"

assert_file_exists "user autostart desktop entry deployed" "${MNT}/home/alice/.config/autostart/sensible-manual.desktop"
assert_file_contains "user autostart executes --first-login" "${MNT}/home/alice/.config/autostart/sensible-manual.desktop" "Exec=/usr/local/bin/sensible-manual --first-login"
assert_contains "new config parent is user-owned" "${calls}" "chown alice:alice /home/alice/.config"
assert_contains "new autostart parent is user-owned" "${calls}" "chown alice:alice /home/alice/.config/autostart"
assert_contains "manual autostart is user-owned" "${calls}" "chown alice:alice /home/alice/.config/autostart/sensible-manual.desktop"
assert_not_contains "no recursive ownership changes" "${calls}" "chown -R"
mock_teardown

mock_setup
configure_user_manual_autostart "alice"
calls="$(<"${MOCK_LOG}")"
assert_eq "existing parents are not chowned again" 1 "$(wc -l < "${MOCK_LOG}")"
assert_contains "only generated file chowned on repeat" "$calls" 'chown alice:alice /home/alice/.config/autostart/sensible-manual.desktop'
mock_teardown

rc=0
configure_user_manual_autostart '../outside' >/dev/null 2>&1 || rc=$?
assert_rc "unsafe username rejected" 1 "$rc"
rc=0
configure_user_manual_autostart 'bob' >/dev/null 2>&1 || rc=$?
assert_rc "missing user home rejected" 1 "$rc"
mv "${MNT}/home/alice/.config/autostart" "${MNT}/home/alice/saved-autostart"
ln -s ../saved-autostart "${MNT}/home/alice/.config/autostart"
rc=0
configure_user_manual_autostart alice >/dev/null 2>&1 || rc=$?
assert_rc "symlink parent rejected" 1 "$rc"

t_section "Build scripts stage manual and packaging"
container_build="$(<"${REPO_ROOT}/live/build.sh")"
native_build="$(<"${REPO_ROOT}/scripts/build-native.sh")"

assert_contains "container build uses shared staging" "${container_build}" 'bash "${REPO_ROOT}/scripts/stage-manual.sh"'
assert_contains "native build uses shared staging" "${native_build}" 'bash "${REPO_ROOT}/scripts/stage-manual.sh"'
rc=0
require_manual_payload "$MNT" || rc=$?
assert_rc "shared staging produces complete payload" 0 "$rc"
assert_eq "staged opener is executable" 755 "$(stat -c %a "${MNT}/usr/local/bin/sensible-manual")"
assert_eq "staged HTML is readable" 644 "$(stat -c %a "${MNT}/usr/share/sensible/manual/index.html")"
assert_file_not_exists "staging cannot autostart in live session" "${MNT}/etc/xdg/autostart/sensible-manual.desktop"
chmod -x "${MNT}/usr/local/bin/sensible-manual"
rc=0
require_manual_payload "$MNT" >/dev/null 2>&1 || rc=$?
assert_rc "non-executable opener rejected" 1 "$rc"

rm -rf "${TMP_DIR}"
t_summary
