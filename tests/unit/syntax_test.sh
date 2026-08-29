#!/usr/bin/env bash
# Syntax sweep: every shell script in the repo parses (bash -n / sh -n).
TEST_NAME="syntax_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

t_section "syntax sweep (sh -n for #!/bin/sh, bash -n otherwise)"
# Pick the checker from the shebang: a #!/bin/sh script must parse under the
# POSIX shell (dash on Debian) so bashisms are caught, not silently accepted
# by bash -n. Everything else is validated with bash -n.
syntax_checker_for() {
    case "$(head -n 1 "$1")" in
        *bash*) echo "bash -n" ;;
        *sh*)   echo "sh -n" ;;
        *)      echo "bash -n" ;;
    esac
}
sh_files=(
    installer/sensible-install.sh
    installer/lib/common.sh
    installer/lib/disk.sh
    installer/lib/fstab.sh
    installer/lib/hardware.sh
    installer/lib/desktop.sh
    installer/lib/apps.sh
    installer/lib/verify.sh
    live/build.sh
    live/auto/config
    live/auto/build
    live/auto/clean
    live/config/hooks/live/0100-sensible-setup.hook.chroot
    live/config/hooks/live/0100-grub-serial-timeout.hook.binary
    live/config/includes.chroot/usr/local/bin/sensible-install
    live/config/includes.chroot/etc/profile.d/99-sensible-firmware-check.sh
    live/config/includes.chroot/etc/profile.d/99-sensible-autostart.sh
    live/config/includes.chroot/usr/local/bin/lazydeb
    scripts/run-qemu.sh
    scripts/smoke-boot.sh
    scripts/build-native.sh
    tests/run-tests.sh
    tests/lib/harness.sh
    tests/unit/common_test.sh
    tests/unit/disk_test.sh
    tests/unit/fstab_test.sh
    tests/unit/desktop_test.sh
    tests/unit/apps_test.sh
    tests/unit/syntax_test.sh
    tests/unit/verify_test.sh
    tests/integration/installer_flow_test.sh
)
for f in "${sh_files[@]}"; do
    checker="$(syntax_checker_for "${REPO_ROOT}/${f}")"
    if ${checker} "${REPO_ROOT}/${f}" 2>/dev/null; then
        t_ok
    else
        t_fail "${checker} ${f}" "$(${checker} "${REPO_ROOT}/${f}" 2>&1 | head -3)"
    fi
done

t_section "live-build hooks use the executed naming convention"
# live-build only runs config/hooks/*/*.hook.{chroot,binary}; any other name
# is silently skipped — which is how the Secure Boot hook once shipped inert.
for f in "${REPO_ROOT}"/live/config/hooks/*/*; do
    case "$(basename "$f")" in
        *.hook.chroot|*.hook.binary) t_ok ;;
        *) t_fail "hook $(basename "$f") would be silently skipped by live-build" "rename to *.hook.chroot or *.hook.binary" ;;
    esac
done

t_section "executable bits"
for f in installer/sensible-install.sh live/build.sh scripts/run-qemu.sh scripts/smoke-boot.sh live/auto/config tests/run-tests.sh; do
    if [ -x "${REPO_ROOT}/${f}" ]; then t_ok; else t_fail "${f} is not executable" ""; fi
done

t_summary
