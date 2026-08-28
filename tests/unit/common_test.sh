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

t_section "detect_keyboard_layout"
kb="$(mktemp)"
printf 'XKBMODEL="pc105"\nXKBLAYOUT="de"\n' > "${kb}"
assert_eq "reads XKBLAYOUT" "de" "$(detect_keyboard_layout "${kb}")"
printf 'XKBLAYOUT=us\nXKBLAYOUT="fr"\n' > "${kb}"
assert_eq "last XKBLAYOUT wins" "fr" "$(detect_keyboard_layout "${kb}")"
assert_eq "missing file falls back to us" "us" "$(detect_keyboard_layout "${kb}/does-not-exist")"
assert_eq "file without XKBLAYOUT falls back to us" "us" "$(detect_keyboard_layout /dev/null)"
rm -f "${kb}"

t_section "check_root"
assert_rc "root passes" 0 "$(run_exiting bash -c 'source "'"${INSTALLER_DIR}"'/lib/common.sh"; id() { echo 0; }; check_root')"
assert_rc "non-root exits 1" 1 "$(run_exiting bash -c 'source "'"${INSTALLER_DIR}"'/lib/common.sh"; id() { echo 1000; }; check_root')"

t_section "check_uefi"
if [ -d /sys/firmware/efi ]; then
    assert_rc "UEFI host passes" 0 "$(run_exiting check_uefi)"
else
    assert_rc "non-UEFI exits 1" 1 "$(run_exiting check_uefi)"
fi

t_summary
