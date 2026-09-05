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
    installer/lib/manual.sh
    scripts/stage-manual.sh
    packaging/manual/sensible-manual
    tests/unit/manual_test.sh
    installer/lib/verify.sh
    live/build.sh
    live/build-stages.sh
    live/auto/config
    live/auto/build
    live/auto/clean
    live/config/hooks/live/0100-sensible-setup.hook.chroot
    live/config/hooks/live/0020-live-boot-to-console.hook.chroot
    live/config/hooks/live/0100-grub-serial-timeout.hook.binary
    live/config/hooks/live/0200-sb-efi-prefix.hook.binary
    live/config/hooks/live/0300-ufw.hook.chroot
    live/config/hooks/live/0250-desktop-apps.hook.chroot
    tests/unit/desktop_apps_test.sh
    scripts/fetch-pins.sh
    live/config/includes.chroot/usr/local/bin/sensible-install
    live/config/includes.chroot/etc/profile.d/98-sensible-serial-ready.sh
    live/config/includes.chroot/etc/profile.d/99-sensible-firmware-check.sh
    live/config/includes.chroot/etc/profile.d/99-sensible-autostart.sh
    live/config/includes.chroot/usr/local/bin/lazydeb
    scripts/run-qemu.sh
    scripts/smoke-boot.sh
    scripts/build-native.sh
    scripts/check-packages.sh
    scripts/run-build-container.sh
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
    tests/unit/ci_runtime_test.sh
    tests/unit/build_cache_test.sh
    tests/unit/package_check_test.sh
    tests/integration/installer_flow_test.sh
)
for f in "${sh_files[@]}"; do
    checker="$(syntax_checker_for "${REPO_ROOT}/${f}")"
    if ${checker} "${REPO_ROOT}/${f}" 2>/dev/null; then
        t_ok
    else
        t_fail "${checker} ${f}" "$(${checker} "${REPO_ROOT}/${f}" 2>&1 | head -n 3)"
    fi
done

t_section "errors are handled explicitly"
blanket_suppression=$(printf '\174\174 true')
if suppressed_errors=$(git -C "${REPO_ROOT}" grep -nF -- "${blanket_suppression}" -- installer live scripts); then
    t_fail "production scripts contain blanket error suppression" "${suppressed_errors}"
else
    t_ok
fi

for helper in valid_hostname valid_username valid_timezone validate_keyboard_layout \
    detect_keyboard_layout apply_live_keyboard configure_keyboard; do
    helper_count=$(grep -hEc "^${helper}\\(\\)" \
        "${REPO_ROOT}/installer/lib/common.sh" \
        "${REPO_ROOT}/installer/lib/setup-form.sh" | awk '{ total += $1 } END { print total + 0 }')
    assert_eq "${helper} has one source of truth" "1" "${helper_count}"
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
style_fallback_output="$(bash -c '
    set -e
    gum() { return 1; }
    source "$1"
    _ui_has_controlling_tty() { return 1; }
    ui_style --bold "plain fallback"
    printf "continued\n"
' _ "${REPO_ROOT}/installer/lib/ui.sh" 2>&1)"
style_fallback_rc=$?
assert_rc "failed Gum styling remains non-fatal without a controlling TTY" 0 "${style_fallback_rc}"
assert_contains "plain styling falls back to stderr" "${style_fallback_output}" "plain fallback"
assert_contains "installer continues after plain styling fallback" "${style_fallback_output}" "continued"
closed_style_rc="$(run_exiting bash -c '
    set -e
    gum() { return 1; }
    source "$1"
    _ui_has_controlling_tty() { return 1; }
    exec 2>&-
    ui_style --bold "closed output"
' _ "${REPO_ROOT}/installer/lib/ui.sh")"
assert_rc "styling remains non-fatal when stderr is also closed" 0 "${closed_style_rc}"
assert_file_contains "live console uses readable installer typography" "${REPO_ROOT}/live/config/includes.chroot/etc/default/console-setup" 'FONTSIZE="14x28"'
assert_contains "keyboard uses searchable system choices" "${setup_source}" '_prompt_searchable "Keyboard layout"'
assert_contains "enumerated prompts use Gum filter" "${setup_source}" 'gum filter --limit 1 --strict'
assert_contains "guided flow asks for the root filesystem" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'filesystem_form'
assert_not_contains "guided flow does not hard-code Btrfs" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'local FS_CHOICE="btrfs"'
assert_contains "Linux console hides echoed capability replies" "${ui_source}" 'stty -echoctl'
assert_contains "terminal state is restored on installer exit" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'restore_terminal'
assert_not_contains "disk selection does not capture rendered UI as its value" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'chosen=$(disk_form'
assert_not_contains "installer no longer asks users to type a disk path" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'CONFIRM_DISK'
assert_contains "Gum menus return explicit hidden values" "${ui_source}" "gum choose --label-delimiter"
assert_contains "installer renders staged progress" "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'install_progress_update 12'
assert_eq "elapsed time uses minutes and zero-padded seconds" "2m 05s" "$(UI_TOOL=text; source "${REPO_ROOT}/installer/lib/ui.sh"; format_elapsed_time 125)"

t_section "build and boot gates fail closed"
smoke_source="$(<"${REPO_ROOT}/scripts/smoke-boot.sh")"
hook_source="$(<"${REPO_ROOT}/live/config/hooks/live/0200-sb-efi-prefix.hook.binary")"
package_check_source="$(<"${REPO_ROOT}/scripts/check-packages.sh")"
native_build_source="$(<"${REPO_ROOT}/scripts/build-native.sh")"
container_build_source="$(<"${REPO_ROOT}/live/build.sh")"
serial_marker="$(<"${REPO_ROOT}/live/config/includes.chroot/etc/profile.d/98-sensible-serial-ready.sh")"
apps_source="$(<"${REPO_ROOT}/installer/lib/apps.sh")"
assert_contains "non-BIOS smoke refuses missing OVMF" "$smoke_source" '"${SMOKE_FIRMWARE}" != "bios"'
assert_contains "smoke asserts a serial-visible marker" "$smoke_source" "SENSIBLE_LIVE_SERIAL_READY"
assert_contains "serial profile emits the asserted marker" "$serial_marker" "SENSIBLE_LIVE_SERIAL_READY"
assert_contains "Secure Boot hook checks the redirect file, not just its directory" "$hook_source" "::/EFI/debian/grub.cfg"
assert_contains "missing EFI image is a build error" "$hook_source" 'exit 1'
assert_contains "package query status is checked" "$package_check_source" 'CHECK_STATUS'
assert_contains "container build takes the shared lock" "$container_build_source" 'flock -n 9'
assert_contains "native build takes the shared lock" "$native_build_source" 'flock -n 9'
assert_contains "native build stages its selected desktop list" "$native_build_source" 'desktop.list.chroot'
assert_contains "native build records the selected variant" "$native_build_source" 'etc/sensible/variant'
assert_contains "native build runs the package gate" "$native_build_source" 'scripts/check-packages.sh'
assert_contains "native dependencies include the package collector and Debian keyring" "$native_build_source" 'python3 debian-archive-keyring'
assert_contains "native build stages the same pinned defaults" "$native_build_source" 'scripts/fetch-pins.sh'
assert_contains "target enables fwupd's refresh timer" \
    "$(<"${REPO_ROOT}/installer/sensible-install.sh")" 'systemctl enable fwupd-refresh.timer'
workflow_source="$(<"${REPO_ROOT}/.github/workflows/build-iso.yml")"
assert_contains "CI builds the GNOME and KDE variants" "$workflow_source" 'variant: [gnome, kde]'
assert_contains "CI enforces the Secure Boot smoke path" "$workflow_source" 'SMOKE_FIRMWARE: sb'
assert_contains "CI only cancels superseded PR runs" "$workflow_source" "cancel-in-progress: \${{ github.event_name == 'pull_request' }}"
assert_contains "CI keeps both desktop editions" "$workflow_source" 'variant: [gnome, kde]'
assert_contains "CI caches the actual live-build downloads" "$workflow_source" 'live/.cache/live-build'
assert_contains "CI caches verified pinned assets" "$workflow_source" 'live/local/pins'
assert_contains "CI does not recompress ISOs" "$workflow_source" 'compression-level: 0'
assert_not_contains "CI avoids a duplicate package check" "$workflow_source" 'scripts/check-packages.sh'
assert_file_contains "offline closure carries the NVIDIA driver" "${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot" "nvidia-driver"
assert_contains "Debian browser package uses ESR name" "$apps_source" "firefox-esr"
assert_not_contains "unsupported plain Firefox package is absent" "$apps_source" $'\n        firefox\n'

# A container/archive outage must fail the package gate rather than looking
# like an empty (therefore successful) missing-package result.
fake_engine_dir="$(mktemp -d /tmp/sensible-package-check.XXXXXX)"
cat > "${fake_engine_dir}/podman" <<'EOF'
#!/bin/sh
echo "simulated archive failure" >&2
exit 42
EOF
chmod +x "${fake_engine_dir}/podman"
package_gate_output="$(PATH="${fake_engine_dir}:${PATH}" bash "${REPO_ROOT}/scripts/check-packages.sh" gnome 2>&1)"
package_gate_rc=$?
rm -rf "${fake_engine_dir}"
assert_rc "package gate propagates container failure" 1 "${package_gate_rc}"
assert_contains "package gate explains archive-query failure" "${package_gate_output}" "container exit 42"

missing_img_dir="$(mktemp -d /tmp/sensible-sb-hook.XXXXXX)"
(
    cd "${missing_img_dir}"
    sh "${REPO_ROOT}/live/config/hooks/live/0200-sb-efi-prefix.hook.binary"
) >/dev/null 2>&1
missing_img_rc=$?
rm -rf "${missing_img_dir}"
assert_rc "Secure Boot hook fails when efi.img is absent" 1 "${missing_img_rc}"

t_section "Phase 6 extras are baked into the image, not fetched at install time"
pins_source="$(<"${REPO_ROOT}/live/pins.env")"
source "${REPO_ROOT}/live/pins.env"
fetch_pins_source="$(<"${REPO_ROOT}/scripts/fetch-pins.sh")"
stages_source="$(<"${REPO_ROOT}/live/build-stages.sh")"
target_list="$(<"${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot")"
ufw_hook="$(<"${REPO_ROOT}/live/config/hooks/live/0300-ufw.hook.chroot")"
omb_bashrc="$(<"${REPO_ROOT}/configs/omb-bashrc")"
for var in OH_MY_BASH_COMMIT OH_MY_BASH_TARBALL_SHA256 NERD_FONTS_TAG NERD_FONTS_JETBRAINS_MONO_ZIP_SHA256 LAZYVIM_STARTER_COMMIT LAZYVIM_STARTER_TARBALL_SHA256; do
    assert_contains "pins.env pins ${var}" "${pins_source}" "${var}="
done
assert_contains "pins.env pins the oh-my-bash tarball by SHA256" "${pins_source}" "${OH_MY_BASH_TARBALL_SHA256}"
assert_contains "pins.env pins the Nerd Font zip by SHA256" "${pins_source}" "${NERD_FONTS_JETBRAINS_MONO_ZIP_SHA256}"
assert_contains "fetch-pins verifies every download against the pin" "${fetch_pins_source}" "sha256sum -c"
assert_contains "fetch-pins fails closed on a checksum mismatch" "${fetch_pins_source}" "does not match the pinned SHA256"
assert_contains "fetch-pins stages oh-my-bash for all new users" "${fetch_pins_source}" "etc/skel/.bashrc"
assert_contains "fetch-pins stages the system-wide git defaults" "${fetch_pins_source}" "etc/gitconfig"
assert_contains "fetch-pins installs the Nerd Font into the image" "${fetch_pins_source}" "jetbrains-mono-nerd"
assert_contains "fetch-pins stages the pinned LazyVim starter" "${fetch_pins_source}" "etc/skel/.config/nvim"
assert_contains "fetch-pins stages the GNOME keyd mapping" "${fetch_pins_source}" "configs/keyd-default.conf"
assert_contains "build stages the pins before live-build runs" "${stages_source}" "scripts/fetch-pins.sh"
assert_contains "cleanup restores ownership only after releasing device mounts" "${stages_source}" $'if release_dev_nodes; then\n        if ! restore_host_ownership'
assert_contains "cleanup explains why ownership restoration was skipped" "${stages_source}" "skipping ownership restoration while chroot /dev mounts remain active"
for pkg in fprintd libpam-fprintd ufw ipp-usb sane-airscan; do
    assert_file_contains "target closure bakes ${pkg}" \
        "${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot" "${pkg}"
done
assert_file_contains "GNOME variant bakes simple-scan" "${REPO_ROOT}/live/variants/gnome.list" "simple-scan"
assert_file_contains "KDE variant bakes skanlite" "${REPO_ROOT}/live/variants/kde.list" "skanlite"
for pkg in chromium libreoffice-writer libreoffice-calc libreoffice-impress thunderbird keepassxc 7zip unzip zip; do
    assert_file_contains "common closure bakes ${pkg}" \
        "${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot" "${pkg}"
done
for pkg in file-roller amberol; do
    assert_file_contains "GNOME variant bakes ${pkg}" \
        "${REPO_ROOT}/live/variants/gnome.list" "${pkg}"
done
for pkg in okular ark gwenview kate kcalc kde-spectacle elisa; do
    assert_file_contains "KDE variant bakes ${pkg}" \
        "${REPO_ROOT}/live/variants/kde.list" "${pkg}"
done
assert_contains "ufw hook never runs ufw enable in the chroot" "${ufw_hook}" "Never \`ufw enable\` here"
assert_contains "ufw hook enables by config file" "${ufw_hook}" 's/^ENABLED=no/ENABLED=yes/'
assert_contains "ufw hook opens KDE Connect ports on KDE" "${ufw_hook}" '1714:1764'
assert_contains "skel bashrc wires the shared oh-my-bash install" "${omb_bashrc}" 'OSH=/usr/share/oh-my-bash'

t_section "text UI strips Gum presentation flags"
plain_output="$(UI_TOOL=text; source "${REPO_ROOT}/installer/lib/ui.sh"; say --foreground 8 --bold "Readable fallback" 2>&1)"
assert_contains "fallback preserves message text" "${plain_output}" "Readable fallback"
assert_not_contains "fallback hides Gum style options" "${plain_output}" "--foreground"

t_summary
