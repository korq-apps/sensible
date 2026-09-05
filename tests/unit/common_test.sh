#!/usr/bin/env bash
# Unit tests for installer/lib/common.sh
TEST_NAME="common_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"

t_section "MNT default and override"
assert_eq "MNT defaults to /mnt" "/mnt" "${MNT}"
assert_eq "MNT honors env override" "/tmp/xyz" "$(MNT=/tmp/xyz bash -c 'source "'"${INSTALLER_DIR}"'/lib/common.sh"; echo "$MNT"')"

t_section "UI tool detection"
fake_bin="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/whiptail" && chmod +x "${fake_bin}/whiptail"
assert_eq "detects whiptail" "whiptail" "$( PATH="${fake_bin}" source "${INSTALLER_DIR}/lib/common.sh" >/dev/null 2>&1; echo "${UI_TOOL}" )"
rm -f "${fake_bin}/whiptail"
printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/dialog" && chmod +x "${fake_bin}/dialog"
assert_eq "detects dialog when whiptail missing" "dialog" "$( PATH="${fake_bin}" source "${INSTALLER_DIR}/lib/common.sh" >/dev/null 2>&1; echo "${UI_TOOL}" )"
rm -f "${fake_bin}/dialog"
assert_eq "falls back to text UI" "text" "$( PATH="${fake_bin}" source "${INSTALLER_DIR}/lib/common.sh" >/dev/null 2>&1; echo "${UI_TOOL}" )"
rm -rf "${fake_bin}"

t_section "Logging goes to stderr with tags"
err="$(log_info "hello-info" 2>&1 >/dev/null)"
assert_contains "log_info tags [INFO]" "${err}" "[INFO]"
assert_contains "log_info includes message" "${err}" "hello-info"
err="$(log_success "done" 2>&1 >/dev/null)"
assert_contains "log_success tags [OK]" "${err}" "[OK]"
assert_contains "log_success includes message" "${err}" "done"
err="$(log_warn "careful" 2>&1 >/dev/null)"
assert_contains "log_warn tags [WARN]" "${err}" "[WARN]"
err="$(log_err "boom" 2>&1 >/dev/null)"
assert_contains "log_err tags [ERROR]" "${err}" "[ERROR]"
out="$(log_info "quiet" 2>/dev/null)"
assert_eq "log functions write nothing to stdout" "" "${out}"

# Text-mode UI (pinned: the ISO always ships whiptail, fallback is for tests/bare envs)
UI_TOOL="text"

t_section "ui_msgbox (text mode)"
out="$(printf '\n' | ui_msgbox T1 body 2>/dev/null)"
assert_eq "msgbox writes nothing to stdout" "" "${out}"

t_section "ui_yesno (text mode)"
printf 'y\n' | ui_yesno T q >/dev/null 2>&1; assert_rc "yes answers 0" 0 $?
printf 'n\n' | ui_yesno T q >/dev/null 2>&1; assert_rc "no answers 1" 1 $?
printf '\n' | ui_yesno T q yes >/dev/null 2>&1; assert_rc "empty uses default yes" 0 $?
printf '\n' | ui_yesno T q no >/dev/null 2>&1; assert_rc "empty uses default no" 1 $?
printf 'bogus\ny\n' | ui_yesno T q no >/dev/null 2>&1; assert_rc "invalid answer re-prompts" 0 $?

t_section "ui_inputbox (text mode): only the value is captured"
res="$(printf 'myhost\n' | ui_inputbox Hostname "enter" "debian" 2>/dev/null)"
assert_eq "value returned on stdout" "myhost" "${res}"
res="$(printf '\n' | ui_inputbox Hostname "enter" "debian" 2>/dev/null)"
assert_eq "empty input falls back to init" "debian" "${res}"
res="$(printf 'x\n' | ui_inputbox T msg 2>/dev/null)"
assert_not_contains "prompt is not captured into value" "${res}" "==="

t_section "ui_passwordbox (text mode): only the secret is captured"
res="$(printf 's3cret\n' | ui_passwordbox T msg 2>/dev/null)"
assert_eq "password returned on stdout" "s3cret" "${res}"
res="$(printf 's3cret\n' | ui_passwordbox T msg 2>/dev/null)"
assert_not_contains "prompt not captured into password" "${res}" "==="

t_section "ui_menu (text mode)"
res="$(printf '2\n' | ui_menu T "choose" btrfs "Btrfs" ext4 "Ext4" 2>/dev/null)"
assert_eq "numeric selection maps to tag" "ext4" "${res}"

t_section "ui_checklist (text mode)"
res="$(printf 'chromium brave\n' | ui_checklist T "pick" 2>/dev/null)"
assert_contains "selection echoed" "${res}" "chromium"

t_section "network pre-flight"
curl() { return 0; }
network_ready; assert_rc "reachable Debian metadata passes" 0 $?
curl() { return 22; }
network_ready; assert_rc "failed Debian metadata request is rejected" 1 $?
network_ready() { return 1; }
printf 'n\n\n' | ensure_network >/dev/null 2>&1
assert_rc "declining network setup exits safely" 1 $?

t_section "warning collection"
INSTALL_WARNINGS=()
record_warning "optional component skipped" >/dev/null 2>&1
assert_eq "warning retained for completion summary" "optional component skipped" "${INSTALL_WARNINGS[0]}"

t_section "build-time desktop variant detection"
variant_cmdline="$(mktemp)"
printf 'boot=live components sensible.variant=kde quiet\n' > "${variant_cmdline}"
assert_eq "kernel command line selects KDE edition" "kde" "$(detect_install_variant "${variant_cmdline}")"
printf 'boot=live components sensible.variant=invalid\n' > "${variant_cmdline}"
assert_eq "invalid edition fails closed to GNOME" "gnome" "$(SENSIBLE_VARIANT=invalid detect_install_variant "${variant_cmdline}")"
printf 'boot=live components\n' > "${variant_cmdline}"
assert_eq "environment fallback supports build and tests" "kde" "$(SENSIBLE_VARIANT=kde detect_install_variant "${variant_cmdline}")"
rm -f "${variant_cmdline}"

t_section "check_root"
assert_rc "root passes" 0 "$(run_exiting bash -c 'source "'"${INSTALLER_DIR}"'/lib/common.sh"; id() { echo 0; }; check_root')"
assert_rc "non-root exits 1" 1 "$(run_exiting bash -c 'source "'"${INSTALLER_DIR}"'/lib/common.sh"; id() { echo 1000; }; check_root')"

t_section "check_uefi"
if [ -d /sys/firmware/efi ]; then
    assert_rc "UEFI host passes" 0 "$(run_exiting check_uefi)"
else
    assert_rc "non-UEFI exits 1" 1 "$(run_exiting check_uefi)"
fi

t_section "ui_box_geometry: dialogs are sized to their content"
# whiptail silently truncates text that does not fit, so the fixed 12-row box
# clipped the long "why no disk qualified" / "how to boot UEFI" messages -
# losing exactly the part that helps. Geometry must grow with the content.
tput() { case "$1" in lines) echo 40 ;; cols) echo 100 ;; esac; }

LONG_MSG="$(printf 'remediation line %s\n' $(seq 1 15))"
read -r GH GW _ <<<"$(ui_box_geometry "${LONG_MSG}")"
assert_eq "15-line message gets more than the old 12 rows" 1 "$([ "${GH}" -gt 12 ] && echo 1 || echo 0)"
assert_eq "and still fits the terminal" 1 "$([ "${GH}" -le 38 ] && echo 1 || echo 0)"

read -r SH SW _ <<<"$(ui_box_geometry "short")"
assert_eq "short message keeps the 12-row minimum" 12 "${SH}"
assert_eq "and a readable minimum width" 60 "${SW}"

# A single 400-char line must be counted as the several rows it wraps into,
# not as one row, or it is clipped just like the multi-line case.
WRAP_MSG="$(printf 'x%.0s' $(seq 1 400))"
read -r WH WW _ <<<"$(ui_box_geometry "${WRAP_MSG}")"
assert_eq "long unbroken line is counted as wrapped rows" 1 "$([ "${WH}" -gt 12 ] && echo 1 || echo 0)"
assert_eq "width never exceeds the terminal" 1 "$([ "${WW}" -le 96 ] && echo 1 || echo 0)"

t_section "ui_box_geometry: reserves rows for entry fields and item lists"
# A long form with an entry field must reserve space for both its copy and its
# control. This protects recovery and configuration forms from being clipped.
CONFIRM_TEXT="$(printf 'choice %s\n' $(seq 1 14))
WARNING: ALL DATA ON /dev/sda WILL BE PERMANENTLY DESTROYED!
Choose whether to continue below:"
read -r IH IW _ <<<"$(ui_box_geometry "${CONFIRM_TEXT}" 12 2)"
CONFIRM_ROWS=$(printf '%s\n' "${CONFIRM_TEXT}" | wc -l)
assert_eq "confirmation box is taller than its text" 1 "$([ "${IH}" -gt "${CONFIRM_ROWS}" ] && echo 1 || echo 0)"
assert_eq "and taller than the old fixed 12 rows" 1 "$([ "${IH}" -gt 12 ] && echo 1 || echo 0)"

# A menu must reserve a row per entry, or long disk lists scroll invisibly.
read -r MH MW ML <<<"$(ui_box_geometry "Choose the disk:" 15 8)"
assert_eq "menu reserves a list row per entry" 8 "${ML}"
assert_eq "menu height covers prose plus its list" 1 "$([ "${MH}" -ge $(( ML + 8 )) ] && echo 1 || echo 0)"

# Non-list callers must get 0 so they never pass a stray argument to whiptail.
read -r _ _ NL <<<"$(ui_box_geometry "plain message")"
assert_eq "non-list dialogs report no list height" 0 "${NL}"

t_section "ui_box_geometry: clamps to a small terminal"
tput() { case "$1" in lines) echo 24 ;; cols) echo 80 ;; esac; }
read -r CH CW _ <<<"$(ui_box_geometry "${LONG_MSG}")"
assert_eq "height clamped to terminal height" 1 "$([ "${CH}" -le 22 ] && echo 1 || echo 0)"
assert_eq "width clamped to terminal width" 1 "$([ "${CW}" -le 76 ] && echo 1 || echo 0)"
unset -f tput

t_summary
