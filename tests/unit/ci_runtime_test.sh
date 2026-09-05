#!/usr/bin/env bash
TEST_NAME="ci_runtime_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

WORK="$(mktemp -d /tmp/sensible-ci-test.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
export MOCK_WORK="${WORK}"
touch "${WORK}/test.iso"

qemu-img() { return 0; }
qemu-system-x86_64() {
    printf '%s\n' "${BASHPID}" > "${MOCK_WORK}/qemu.pid"
    trap 'exit 0' TERM
    case "${MOCK_BOOT}" in
        crash) return 42 ;;
        clean_exit) return 0 ;;
        ready|late_crash)
            printf '\000\033[32mWelcome to \033[0mDebian\nSENSIBLE_LIVE_SERIAL_READY\n'
            ;;
        partial) echo 'Welcome to Debian' ;;
    esac
    if [ "${MOCK_BOOT}" = late_crash ]; then sleep 1; return 42; fi
    while :; do sleep 0.1; done
}
export -f qemu-img qemu-system-x86_64

run_smoke() {
    local mode="$1" timeout="$2" settle="$3" rc=0
    MOCK_BOOT="${mode}" SMOKE_FIRMWARE=bios SMOKE_TIMEOUT="${timeout}" \
        SMOKE_SETTLE="${settle}" bash "${REPO_ROOT}/scripts/smoke-boot.sh" \
        "${WORK}/test.iso" > "${WORK}/smoke.log" 2>&1 || rc=$?
    SMOKE_RC=${rc}
    if [ -f "${WORK}/qemu.pid" ]; then
        if kill -0 "$(<"${WORK}/qemu.pid")" 2>/dev/null; then
            t_fail "smoke test left QEMU running"
        else
            t_ok
        fi
    fi
}

t_section "smoke completes on normalized markers, not the timeout"
start=${SECONDS}
run_smoke ready 15 1
assert_rc "ready guest succeeds" 0 "${SMOKE_RC}"
assert_file_contains "reports readiness" "${WORK}/smoke.log" 'Smoke test PASSED'
if [ "$((SECONDS - start))" -lt 15 ]; then t_ok; else t_fail "waited for full timeout"; fi

t_section "smoke fails on missing markers and premature QEMU exits"
run_smoke partial 2 1
assert_rc "one marker is insufficient" 1 "${SMOKE_RC}"
assert_file_contains "missing marker diagnosed" "${WORK}/smoke.log" 'marker not reached'
run_smoke crash 10 1
assert_rc "QEMU crash fails" 1 "${SMOKE_RC}"
assert_file_contains "crash status retained" "${WORK}/smoke.log" 'QEMU exit code: 42'
run_smoke clean_exit 10 1
assert_rc "premature clean exit fails too" 1 "${SMOKE_RC}"
run_smoke late_crash 10 3
assert_rc "crash during settling fails" 1 "${SMOKE_RC}"
run_smoke ready invalid 1
assert_rc "invalid deadline rejected" 1 "${SMOKE_RC}"

t_section "smoke cancellation stops its guest"
rm -f "${WORK}/qemu.pid"
MOCK_BOOT=partial SMOKE_FIRMWARE=bios SMOKE_TIMEOUT=30 \
    bash "${REPO_ROOT}/scripts/smoke-boot.sh" "${WORK}/test.iso" > "${WORK}/cancel.log" 2>&1 &
smoke_pid=$!
for attempt in {1..100}; do
    [ ! -f "${WORK}/qemu.pid" ] || break
    sleep 0.05
done
kill -TERM "${smoke_pid}"
rc=0
wait "${smoke_pid}" || rc=$?
assert_rc "cancellation remains unsuccessful" 143 "${rc}"
if kill -0 "$(<"${WORK}/qemu.pid")" 2>/dev/null; then
    t_fail "cancellation left guest running"
else t_ok; fi

# Emulate only the named container lifecycle, without a daemon or privileges.
mock_engine() {
    printf '%s\n' "$*" >> "${MOCK_WORK}/engine.log"
    case "$1" in
        run)
            if [ "${MOCK_CONTAINER}" = fail ] || [ "${MOCK_CONTAINER}" = daemon_fail ]; then return 42; fi
            if [ "${MOCK_CONTAINER}" = success ]; then return 0; fi
            printf '%s\n' "${BASHPID}" > "${MOCK_WORK}/container.pid"
            trap 'exit 143' TERM
            while :; do sleep 0.1; done
            ;;
        ps)
            if [ "${MOCK_CONTAINER}" = daemon_fail ]; then return 99; fi
            [ ! -f "${MOCK_WORK}/container.pid" ] || echo test-container
            ;;
        rm) kill -TERM "$(<"${MOCK_WORK}/container.pid")" ;;
    esac
}
export -f mock_engine
t_section "managed containers preserve status and clean up on cancellation"
for mode in success fail daemon_fail; do
    rc=0
    MOCK_CONTAINER="${mode}" bash "${REPO_ROOT}/scripts/run-build-container.sh" \
        mock_engine test-container image > "${WORK}/container.log" 2>&1 || rc=$?
    expected=0
    [ "${mode}" = success ] || expected=42
    assert_rc "container ${mode} exit preserved" "${expected}" "${rc}"
done
MOCK_CONTAINER=wait bash "${REPO_ROOT}/scripts/run-build-container.sh" \
    mock_engine test-container image > "${WORK}/container.log" 2>&1 &
wrapper_pid=$!
for attempt in {1..100}; do
    [ ! -f "${WORK}/container.pid" ] || break
    sleep 0.05
done
kill -TERM "${wrapper_pid}"
rc=0
wait "${wrapper_pid}" || rc=$?
assert_rc "container cancellation status preserved" 143 "${rc}"
assert_file_contains "removes the exact named container" "${WORK}/engine.log" 'rm -f test-container'
if kill -0 "$(<"${WORK}/container.pid")" 2>/dev/null; then
    t_fail "cancellation left container client running"
else t_ok; fi

t_summary
