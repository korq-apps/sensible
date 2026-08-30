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
    live/build-stages.sh
    live/auto/config
    live/auto/build
    live/auto/clean
    live/config/hooks/live/0100-sensible-setup.hook.chroot
    live/config/hooks/live/0020-live-boot-to-console.hook.chroot
    live/config/hooks/live/0100-grub-serial-timeout.hook.binary
    live/config/includes.chroot/usr/local/bin/sensible-install
    live/config/includes.chroot/etc/profile.d/99-sensible-firmware-check.sh
    live/config/includes.chroot/etc/profile.d/99-sensible-autostart.sh
    live/config/includes.chroot/usr/local/bin/lazydeb
    scripts/run-qemu.sh
    scripts/smoke-boot.sh
    scripts/build-native.sh
    scripts/check-packages.sh
    tests/run-tests.sh
    tests/lib/harness.sh
    tests/unit/common_test.sh
    tests/unit/setup_form_test.sh
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

t_section "live console launches straight into the branded installer"
autostart="$(<"${REPO_ROOT}/live/config/includes.chroot/etc/profile.d/99-sensible-autostart.sh")"
assert_contains "autostart launches sensible-install" "${autostart}" $'\nsensible-install\n'
assert_not_contains "no five-second launch countdown" "${autostart}" "Starting the Sensible installer in 5s"
assert_not_contains "no keypress escape before installer" "${autostart}" "read -r -t 5"
assert_not_contains "autostart does not write a root-owned run marker" "${autostart}" "/run/sensible-autostart.done"
if [ ! -s "${REPO_ROOT}/live/config/includes.chroot/etc/issue" ]; then t_ok; else t_fail "live issue banner is empty" "getty would print it before the installer"; fi
if [ ! -s "${REPO_ROOT}/live/config/includes.chroot/etc/motd" ]; then t_ok; else t_fail "live motd is empty" "PAM would duplicate the pre-installer banner"; fi
auto_config="$(<"${REPO_ROOT}/live/auto/config")"
assert_contains "ISO persists its desktop edition on the kernel command line" "${auto_config}" 'sensible.variant=${SENSIBLE_VARIANT}'
assert_file_exists "graphical text banner is included in the live image" "${REPO_ROOT}/live/config/includes.chroot/usr/share/sensible/logo.txt"
ui_source="$(<"${REPO_ROOT}/installer/lib/ui.sh")"
setup_source="$(<"${REPO_ROOT}/installer/lib/setup-form.sh")"
assert_not_contains "UI TTY check does not redirect the fd it is testing" "${ui_source}" '[ -t 2 ] 2>/dev/null'
assert_not_contains "form TTY check does not redirect the fd it is testing" "${setup_source}" '[ -t 2 ] 2>/dev/null'
assert_contains "UI detects the controlling terminal" "${ui_source}" '( : </dev/tty )'
assert_contains "forms share the UI terminal detector" "${setup_source}" $'_setup_use_gum() {\n    _ui_use_gum'
assert_contains "welcome offers an explicit start action" "${ui_source}" "Press Enter to start"
assert_contains "installer opens the welcome before keyboard setup" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" $'    welcome_screen\n\n    # ── 1. Keyboard'
assert_contains "terminal size is measured from its controlling TTY" "${ui_source}" 'stty size </dev/tty'
assert_file_contains "live console uses readable installer typography" "${REPO_ROOT}/live/config/includes.chroot/etc/default/console-setup" 'FONTSIZE="14x28"'
assert_contains "keyboard uses searchable system choices" "${setup_source}" '_prompt_searchable "Keyboard layout"'
assert_contains "enumerated prompts use Gum filter" "${setup_source}" 'gum filter --limit 1 --strict'
assert_contains "Linux console hides echoed capability replies" "${ui_source}" 'stty -echoctl'
assert_contains "terminal state is restored on installer exit" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'restore_terminal'
assert_not_contains "disk selection does not capture rendered UI as its value" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'chosen=$(disk_form'
assert_not_contains "installer no longer asks users to type a disk path" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'CONFIRM_DISK'
assert_contains "Gum menus return explicit hidden values" "${ui_source}" "gum choose --label-delimiter"
assert_contains "installer renders staged progress" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'install_progress_update 12'
assert_eq "elapsed time uses minutes and zero-padded seconds" "2m 05s" "$(UI_TOOL=text; source "${REPO_ROOT}/installer/lib/ui.sh"; format_elapsed_time 125)"

t_section "text UI strips Gum presentation flags"
plain_output="$(UI_TOOL=text; source "${REPO_ROOT}/installer/lib/ui.sh"; say --foreground 8 --bold "Readable fallback" 2>&1)"
assert_contains "fallback preserves message text" "${plain_output}" "Readable fallback"
assert_not_contains "fallback hides Gum style options" "${plain_output}" "--foreground"

t_summary
