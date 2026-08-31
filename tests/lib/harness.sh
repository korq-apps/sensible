#!/usr/bin/env bash
# Minimal bash test harness for Sensible — assertions, mocks, counters.
# No external dependencies; runs unprivileged.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER_DIR="${REPO_ROOT}/installer"

set -uo pipefail

PASS=0
FAIL=0

t_section() {
    printf '\n> %s\n' "$1"
}

t_ok() {
    PASS=$((PASS + 1))
}

t_fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2
}

assert_eq() { # desc expected actual
    if [ "$2" = "$3" ]; then t_ok; else t_fail "$1" "expected [$2], got [$3]"; fi
}

assert_ne() { # desc not-expected actual
    if [ "$2" != "$3" ]; then t_ok; else t_fail "$1" "unexpectedly equal to [$2]"; fi
}

assert_contains() { # desc haystack needle
    if [[ "$2" == *"$3"* ]]; then t_ok; else t_fail "$1" "[$2] does not contain [$3]"; fi
}

assert_not_contains() { # desc haystack needle
    if [[ "$2" != *"$3"* ]]; then t_ok; else t_fail "$1" "[$2] unexpectedly contains [$3]"; fi
}

assert_file_exists() {
    if [ -f "$2" ]; then t_ok; else t_fail "$1" "file missing: $2"; fi
}

assert_file_not_exists() {
    if [ ! -e "$2" ]; then t_ok; else t_fail "$1" "file unexpectedly exists: $2"; fi
}

assert_file_contains() { # desc file needle
    if [ ! -f "$2" ]; then
        t_fail "$1" "file missing: $2"
    elif grep -qF -- "$3" "$2"; then
        t_ok
    else
        t_fail "$1" "[$3] not found in $2"
    fi
}

assert_file_not_contains() { # desc file needle
    if [ ! -f "$2" ]; then
        t_fail "$1" "file missing: $2"
    elif grep -qF -- "$3" "$2"; then
        t_fail "$1" "[$3] unexpectedly found in $2"
    else
        t_ok
    fi
}

assert_rc() { # desc expected_rc actual_rc
    if [ "$2" -eq "$3" ]; then t_ok; else t_fail "$1" "expected rc=$2, got rc=$3"; fi
}

# --- Mock helpers -----------------------------------------------------------
# External tools are overridden with bash functions (functions take precedence
# over PATH). Calls are recorded in $MOCK_LOG, one line per call.

MOCK_DIR=""
MOCK_LOG=""

mock_setup() {
    MOCK_DIR="$(mktemp -d /tmp/sensible-test-mocks.XXXXXX)"
    MOCK_LOG="${MOCK_DIR}/calls.log"
    : > "${MOCK_LOG}"
}

mock_teardown() {
    [ -n "${MOCK_DIR}" ] && rm -rf "${MOCK_DIR}"
    MOCK_DIR=""
    MOCK_LOG=""
}

mock_reset() {
    : > "${MOCK_LOG:?mock_setup not called}"
}

mlog() {
    printf '%s\n' "$*" >> "${MOCK_LOG:?mock_setup not called}"
}

mock_has_call() { # needle -> rc 0 if any logged call contains needle
    [ -f "${MOCK_LOG}" ] && grep -qF -- "$1" "${MOCK_LOG}"
}

mock_last_call() { # needle -> prints last logged call containing needle
    grep -F -- "$1" "${MOCK_LOG}" | tail -n 1
}

mock_count_calls() { # needle -> number of matching calls
    grep -cF -- "$1" "${MOCK_LOG}"
}

# Run a function expected to exit(), in a subshell, and capture its rc.
run_exiting() { # func args...
    ( "$@" ) >/dev/null 2>&1
    echo $?
}

t_summary() {
    printf '\n%s: %d passed, %d failed\n' "${TEST_NAME:-$(basename "$0")}" "${PASS}" "${FAIL}"
    [ "${FAIL}" -eq 0 ]
}
