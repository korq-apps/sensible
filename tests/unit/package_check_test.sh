#!/usr/bin/env bash
TEST_NAME="package_check_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

WORK="$(mktemp -d /tmp/sensible-package-gate-test.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
export GATE_TEST_WORK="${WORK}"
apt-get() {
    printf '%s\n' "$*" >> "${GATE_TEST_WORK}/calls"
    cp "${APT_CONFIG}" "${GATE_TEST_WORK}/apt.conf"
    cp "${APT_CONFIG%/*}/etc/sources.list" "${GATE_TEST_WORK}/sources.list"
    printf '%s\n' "${APT_CONFIG%/*}" > "${GATE_TEST_WORK}/index-path"
    [ "${GATE_TEST_MODE}" != update_failure ]
}
apt-cache() {
    printf '%s\n' "$*" >> "${GATE_TEST_WORK}/calls"
    # Simulate a host with all requested packages, but a Testing index missing
    # one package. Accidentally using the host must not yield a false success.
    [ -f "${APT_CONFIG:-/nonexistent}" ] || return 0
    if [ "${GATE_TEST_MODE}" = missing ] && [ "$2" = linux-image-amd64 ]; then return 100; fi
    return 0
}
export -f apt-get apt-cache
run_gate() {
    : > "${WORK}/calls"
    rc=0
    GATE_TEST_MODE="$1" SENSIBLE_PACKAGE_CHECK_NATIVE=1 \
        bash "${REPO_ROOT}/scripts/check-packages.sh" gnome > "${WORK}/output" 2>&1 || rc=$?
}
t_section "native gate uses a disposable Testing-only APT configuration"
run_gate success
assert_rc "Testing packages resolve" 0 "$rc"
assert_file_contains "correct suite and components" "${WORK}/sources.list" 'testing main contrib non-free non-free-firmware'
assert_file_contains "explicit Debian signature keyring" "${WORK}/sources.list" 'signed-by=/usr/share/keyrings/debian-archive-keyring.gpg'
assert_file_contains "installed host packages excluded" "${WORK}/apt.conf" 'Dir::State::status "/dev/null";'
assert_file_contains "host config and hooks excluded" "${WORK}/apt.conf" '/etc";'
assert_file_contains "partial update failures are fatal" "${WORK}/apt.conf" 'APT::Update::Error-Mode "any";'
assert_file_contains "target architecture is explicit" "${WORK}/apt.conf" 'APT::Architecture "amd64";'
assert_eq "refresh happens before lookup" 'update -qq' "$(head -n 1 "${WORK}/calls")"
if [ -e "$(<"${WORK}/index-path")" ]; then t_fail "temporary APT state leaked"; else t_ok; fi

t_section "missing Testing package fails even if the host supplies it"
run_gate missing
assert_rc "missing package rejected" 1 "$rc"
assert_file_contains "diagnostic names missing package" "${WORK}/output" 'linux-image-amd64'

t_section "archive failures do not fall back to host state"
run_gate update_failure
assert_rc "failed update aborts" 1 "$rc"
assert_file_not_contains "no lookup after refresh failure" "${WORK}/calls" 'show '
if [ -e "$(<"${WORK}/index-path")" ]; then t_fail "failed refresh leaked APT state"; else t_ok; fi

t_section "package collection failure cannot validate a partial list"
python3() { return 127; }
export -f python3
run_gate success
unset -f python3
assert_rc "failed package collector aborts" 1 "$rc"
assert_file_contains "collector error explained" "${WORK}/output" 'could not collect the complete package-name set'
assert_file_not_contains "archive not queried with incomplete list" "${WORK}/calls" 'update'
t_summary
