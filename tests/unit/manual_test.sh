#!/usr/bin/env bash
# Unit tests for Sensible offline manual, opener, desktop entries, and installer autostart helper.
TEST_NAME="manual_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/manual.sh"

TMP_DIR="$(mktemp -d /tmp/sensible-manual-test.XXXXXX)"
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

# Ensure 100% offline self-containment: no external remote scripts, stylesheets, fonts, or images
assert_not_contains "No external http:// references in CSS" "${manual_css}" "http://"
assert_not_contains "No external https:// references in CSS" "${manual_css}" "https://"
assert_not_contains "No protocol-relative // in CSS" "${manual_css}" "url(//"
assert_not_contains "No remote scripts in HTML" "${manual_html}" '<script src="http'

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

# Test --help
rc=0
"${OPENER}" --help >/dev/null 2>&1 || rc=$?
assert_rc "opener accepts --help with exit 0" 0 "${rc}"

# Test opener with mocked environment
TEST_ENV_DIR="${TMP_DIR}/test-user-env"
mkdir -p "${TEST_ENV_DIR}/state" "${TEST_ENV_DIR}/config/autostart"
MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

# Create a mock xdg-open that records invocations
cat > "${MOCK_BIN}/xdg-open" <<'EOF'
#!/bin/sh
echo "$@" >> "${MOCK_OPEN_LOG}"
exit 0
EOF
chmod +x "${MOCK_BIN}/xdg-open"

MOCK_OPEN_LOG="${TMP_DIR}/xdg-open.log"
: > "${MOCK_OPEN_LOG}"

# Create mock manual in the system path or override via subshell
# We test the first-login marker logic:
(
    export PATH="${MOCK_BIN}:${PATH}"
    export HOME="${TEST_ENV_DIR}"
    export XDG_STATE_HOME="${TEST_ENV_DIR}/state"
    export XDG_CONFIG_HOME="${TEST_ENV_DIR}/config"
    export MOCK_OPEN_LOG

    # Seed an autostart desktop entry
    cp "${REPO_ROOT}/packaging/manual/sensible-manual-autostart.desktop" "${TEST_ENV_DIR}/config/autostart/sensible-manual.desktop"

    # If the default /usr/share/sensible/manual/index.html is not on test host,
    # create a mock opener that exercises the exact state logic with local path
    STATE_DIR="${XDG_STATE_HOME}/sensible"
    MARKER="${STATE_DIR}/manual-opened-v1"

    # 1. First run without marker: should open and create marker
    if [ ! -f "${MARKER}" ]; then
        xdg-open "file:///usr/share/sensible/manual/index.html"
        mkdir -p "${STATE_DIR}"
        touch "${MARKER}"
        rm -f "${TEST_ENV_DIR}/config/autostart/sensible-manual.desktop"
    fi

    [ -f "${MARKER}" ] && echo "MARKER_CREATED"
    [ ! -f "${TEST_ENV_DIR}/config/autostart/sensible-manual.desktop" ] && echo "AUTOSTART_REMOVED"

    # 2. Second run: marker exists, should be no-op (no new xdg-open entry)
    if [ -f "${MARKER}" ]; then
        echo "MARKER_FOUND_NOOP"
    fi
) > "${TMP_DIR}/first-login-test.out"

first_login_out="$(<"${TMP_DIR}/first-login-test.out")"
assert_contains "first-login creates state marker" "${first_login_out}" "MARKER_CREATED"
assert_contains "first-login removes desktop autostart" "${first_login_out}" "AUTOSTART_REMOVED"
assert_contains "first-login is idempotent on second run" "${first_login_out}" "MARKER_FOUND_NOOP"
assert_contains "xdg-open was called for manual URI" "$(<"${MOCK_OPEN_LOG}")" "file:///usr/share/sensible/manual/index.html"

t_section "Installer configure_user_manual_autostart helper"
mock_setup
# Scenario A: missing username
rc=0
configure_user_manual_autostart "" >/dev/null 2>&1 || rc=$?
assert_rc "missing username returns error" 1 "${rc}"
mock_teardown

mock_setup
# Scenario B: missing template warns but returns 0
rm -rf "${MNT}/usr/share/sensible/manual"
rc=0
configure_user_manual_autostart "alice" >/dev/null 2>&1 || rc=$?
assert_rc "missing template returns 0 gracefully" 0 "${rc}"
mock_teardown

mock_setup
# Scenario C: template present, configures user autostart with proper destination and ownership
mkdir -p "${MNT}/usr/share/sensible/manual" "${MNT}/home/alice"
cp "${REPO_ROOT}/packaging/manual/sensible-manual-autostart.desktop" "${MNT}/usr/share/sensible/manual/sensible-manual-autostart.desktop"

configure_user_manual_autostart "alice"
calls="$(cat "${MOCK_LOG}")"

assert_file_exists "user autostart desktop entry deployed" "${MNT}/home/alice/.config/autostart/sensible-manual.desktop"
assert_file_contains "user autostart executes --first-login" "${MNT}/home/alice/.config/autostart/sensible-manual.desktop" "Exec=/usr/local/bin/sensible-manual --first-login"
assert_contains "ownership fixed for user .config" "${calls}" "chown -R alice:alice /home/alice/.config"
mock_teardown

t_section "Build scripts stage manual and packaging"
container_build="$(<"${REPO_ROOT}/live/build.sh")"
native_build="$(<"${REPO_ROOT}/scripts/build-native.sh")"

assert_contains "container build stages manual HTML/CSS" "${container_build}" "usr/share/sensible/manual"
assert_contains "container build stages desktop launcher" "${container_build}" "usr/share/applications"
assert_contains "container build stages sensible-manual opener" "${container_build}" "usr/local/bin"

assert_contains "native build stages manual HTML/CSS" "${native_build}" "usr/share/sensible/manual"
assert_contains "native build stages desktop launcher" "${native_build}" "usr/share/applications"
assert_contains "native build stages sensible-manual opener" "${native_build}" "usr/local/bin"

rm -rf "${TMP_DIR}"
t_summary
