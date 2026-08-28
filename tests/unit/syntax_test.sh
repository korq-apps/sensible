#!/usr/bin/env bash
# Syntax sweep: every shell script in the repo parses (bash -n / sh -n).
TEST_NAME="syntax_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

t_section "bash -n over all shell scripts"
sh_files=(
    installer/sensible-install.sh
    installer/lib/common.sh
    installer/lib/disk.sh
    installer/lib/fstab.sh
    installer/lib/hardware.sh
    installer/lib/desktop.sh
    installer/lib/apps.sh
    live/build.sh
    live/auto/config
    live/auto/build
    live/auto/clean
    live/config/hooks/live/0100-sensible-setup.hook.chroot
    live/config/hooks/binary/0100-secure-boot.hook.binary
    live/config/includes.chroot/usr/local/bin/sensible-install
    live/config/includes.chroot/usr/local/bin/lazydeb
    scripts/run-qemu.sh
    tests/run-tests.sh
    tests/lib/harness.sh
)
for f in "${sh_files[@]}"; do
    if bash -n "${REPO_ROOT}/${f}" 2>/dev/null; then
        t_ok
    else
        t_fail "bash -n ${f}" "$(bash -n "${REPO_ROOT}/${f}" 2>&1 | head -3)"
    fi
done

t_section "executable bits"
for f in installer/sensible-install.sh live/build.sh scripts/run-qemu.sh live/auto/config tests/run-tests.sh; do
    if [ -x "${REPO_ROOT}/${f}" ]; then t_ok; else t_fail "${f} is not executable" ""; fi
done

t_summary
