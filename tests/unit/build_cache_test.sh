#!/usr/bin/env bash
TEST_NAME="build_cache_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

WORK="$(mktemp -d /tmp/sensible-cache-test.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

# Exercise the real stage driver in a disposable directory, replacing only
# privileged/external commands. Filesystem cleanup and cache handling are real.
lb() {
    case "$1" in
        clean)
            [ ! -e chroot ] && [ ! -e .build ] && [ ! -e cache/bootstrap ] || return 90
            ;;
        bootstrap)
            [ -f cache/packages.chroot/cached.deb ] || return 91
            [ ! -e cache/packages.chroot/not-a-package.txt ] || return 92
            mkdir -p chroot/dev
            ;;
        chroot)
            [ "${MOCK_BUILD_FAIL:-0}" != 1 ] || return 42
            printf 'new download' > cache/packages.chroot/new.deb
            ;;
    esac
}
mountpoint() { return 1; }
mount() { return 0; }
stat() { echo 0; }
bash() {
    if [ "$1" = /workspace/scripts/fetch-pins.sh ]; then return 0; fi
    command bash "$@"
}
export -f lb mountpoint mount stat bash

seed() {
    mkdir -p "$1"/.cache/live-build/packages.chroot "$1"/cache/bootstrap "$1"/chroot "$1"/.build
    printf 'old download' > "$1"/.cache/live-build/packages.chroot/cached.deb
    printf 'ignored' > "$1"/.cache/live-build/packages.chroot/not-a-package.txt
    touch "$1"/chroot/stale "$1"/.build/stale "$1"/cache/bootstrap/stale
}
t_section "clean builds reuse downloads but never filesystem snapshots"
seed "${WORK}/success"
rc=0
(cd "${WORK}/success" && command bash "${REPO_ROOT}/live/build-stages.sh") > "${WORK}/build.log" 2>&1 || rc=$?
assert_rc "cached clean build succeeds" 0 "${rc}"
assert_file_exists "old download retained" "${WORK}/success/.cache/live-build/packages.chroot/cached.deb"
assert_file_exists "new download saved" "${WORK}/success/.cache/live-build/packages.chroot/new.deb"
assert_file_not_exists "unrelated files not restored" "${WORK}/success/.cache/live-build/packages.chroot/not-a-package.txt"
assert_file_not_exists "stale root not reused" "${WORK}/success/chroot/stale"
assert_file_not_exists "bootstrap snapshot not reused" "${WORK}/success/cache/bootstrap/stale"

t_section "failed builds leave the previous download snapshot intact"
seed "${WORK}/failed"
rc=0
(cd "${WORK}/failed" && MOCK_BUILD_FAIL=1 command bash "${REPO_ROOT}/live/build-stages.sh") > "${WORK}/failed.log" 2>&1 || rc=$?
assert_rc "mandatory stage failure preserved" 42 "${rc}"
assert_file_exists "previous cache survives" "${WORK}/failed/.cache/live-build/packages.chroot/cached.deb"
assert_file_not_exists "no partial snapshot published" "${WORK}/failed/.cache/live-build/packages.chroot/new.deb"
t_summary
