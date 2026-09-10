#!/usr/bin/env bash
TEST_NAME="config_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/sensible-install.sh"
set +e

t_section "protected TOML parsing"
PYTHONDONTWRITEBYTECODE=1 python3 "${REPO_ROOT}/tests/lib/check_config.py"
assert_rc "production parser regression tests" 0 $?

t_section "CLI validation happens before root checks or mutations"
check_root() { printf 'UNEXPECTED_ROOT_CHECK\n'; return 1; }
for args in '--unknown' '--config' '--debug --debug' '--help --unknown' '--config --debug'; do
    # Intentional word splitting: this table contains only fixed option tokens.
    output=$(main $args 2>&1)
    assert_rc "reject $args" 1 $?
    assert_not_contains "no privileged action for $args" "$output" UNEXPECTED_ROOT_CHECK
done
output=$(main --help 2>&1)
assert_rc "help succeeds unprivileged" 0 $?
assert_contains "help documents config" "$output" '--config FILE'

t_section "shared semantic validation"
valid_password short; assert_rc "short password rejected" 1 $?
valid_password $'eight123\nroot'; assert_rc "password line injection rejected" 1 $?
valid_password 'valid $pass\word'; assert_rc "literal special characters accepted" 0 $?
valid_optional_identity 'Alice Example'; assert_rc "ordinary optional identity accepted" 0 $?
for identity in $'Alice\n[user]' 'Alice:root' 'a"b' 'a\b' 'a#b' 'a;b'; do
    valid_optional_identity "$identity"; assert_rc "unsafe optional identity rejected" 1 $?
done
valid_locale en_US.UTF-8 /nonexistent/SUPPORTED
assert_rc "locale metadata missing fails closed" 1 $?

t_section "parser failure status is not hidden by process substitution"
python3() { printf 'partial\0'; return 1; }
UNATTENDED_FIELDS=()
load_unattended_config unused >/dev/null 2>&1
assert_rc "partial failing parser rejected" 1 $?
assert_eq "discard partial output" 0 "${#UNATTENDED_FIELDS[@]}"
(
    # A complete record must not mask a nonzero parser exit either. Isolate the
    # semantic validators so the wait status is the only possible rejection.
    python3() { for ((i=0; i<14; i++)); do printf 'field\0'; done; return 1; }
    valid_hostname() { return 0; }
    valid_username() { return 0; }
    valid_optional_identity() { return 0; }
    valid_timezone() { return 0; }
    valid_locale() { return 0; }
    validate_keyboard_layout() { return 0; }
    valid_password() { return 0; }
    load_unattended_config unused >/dev/null 2>&1
    [ "$?" -ne 0 ]
)
assert_rc "nonzero parser status rejects even complete output" 0 $?
unset -f python3

t_section "unattended error UI never invokes a dialog"
SENSIBLE_UNATTENDED=true
UI_TOOL=whiptail
whiptail() { printf 'UNEXPECTED_DIALOG\n'; return 1; }
output=$(ui_msgbox Error 'failure detail' 2>&1)
assert_rc "error diagnostic succeeds without UI" 0 $?
assert_contains "error remains visible" "$output" 'failure detail'
assert_not_contains "no whiptail" "$output" UNEXPECTED_DIALOG
_ui_use_gum; assert_rc "no Gum in config mode" 1 $?
show_failure_screen test 1 /nonexistent; assert_rc "no failure menu" 0 $?

t_section "literal rsync exclusions"
assert_eq "glob characters escaped" '/run/a\[b\]\*\?' "$(input_copy_exclusion '/run/a[b]*?')"

t_section "offline parser dependency fails closed at image build"
assert_file_contains "Python explicitly installed" "${REPO_ROOT}/live/config/package-lists/live.list.chroot" python3
for dependency_rc in 0 1; do
    output=$(bash -c '
        chmod() { :; }
        systemctl() { echo NETWORK_MANAGER_ENABLED; }
        parser_status="$2"
        python3() { return "$parser_status"; }
        source "$1"
    ' _ "${REPO_ROOT}/live/config/hooks/live/0100-sensible-setup.hook.chroot" "$dependency_rc" 2>&1)
    assert_rc "hook handles parser status $dependency_rc" "$dependency_rc" $?
    if [ "$dependency_rc" = 1 ]; then
        assert_contains "missing parser diagnosis" "$output" 'requires Python 3.11+ with tomllib'
        assert_not_contains "missing parser stops hook" "$output" NETWORK_MANAGER_ENABLED
    else
        assert_contains "valid parser proceeds" "$output" NETWORK_MANAGER_ENABLED
    fi
done

t_summary
