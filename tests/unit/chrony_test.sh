#!/usr/bin/env bash
# Unit tests: chrony is the only time daemon in the offline closure.
TEST_NAME="chrony_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

TARGET_LIST="${REPO_ROOT}/live/config/package-lists/sensible-target.list.chroot"
INSTALLER="${REPO_ROOT}/installer/sensible-install.sh"
HOOK="${REPO_ROOT}/live/config/hooks/live/0100-sensible-setup.hook.chroot"
UFW_HOOK="${REPO_ROOT}/live/config/hooks/live/0300-ufw.hook.chroot"

t_section "chrony is the only time daemon in the offline closure"
package_records="$(grep -vE '^\s*(#|$)' "$TARGET_LIST")"
grep -qx 'chrony' <<< "$package_records"; assert_rc "chrony is an uncommented package record" 0 $?
apps_section="$(awk '/^# Apps — default set/{p=1} /^# dconf-cli/{p=0} p' "$TARGET_LIST")"
assert_not_contains "chrony sits outside the manual-checked app section" "$apps_section" "chrony"
for extra in systemd-timesyncd ntpsec openntpd ntp; do
    if grep -qx "$extra" <<< "$package_records"; then
        t_fail "${extra} is not a closure package" "found in ${TARGET_LIST}"
    else
        t_ok
    fi
done
other_lists="$(grep -hE '^\s*(systemd-timesyncd|ntpsec|openntpd|ntp)\s*$' \
    "${REPO_ROOT}"/live/config/package-lists/*.list.chroot \
    "${REPO_ROOT}"/live/variants/*.list || true)"
assert_eq "no other package list names a second time daemon" "" "$other_lists"

t_section "image hook enables chrony and rejects a second time daemon"
hook_src="$(<"$HOOK")"
assert_contains "live image enables chrony.service" "$hook_src" 'systemctl enable chrony.service'
assert_not_contains "hook does not start chrony in the chroot" "$hook_src" 'systemctl start chrony'
assert_file_not_exists "Debian chrony.conf is not replaced" \
    "${REPO_ROOT}/live/config/includes.chroot/etc/chrony/chrony.conf"

t_section "hook package-status branches execute correctly under mocks"
# Run the real hook with dpkg-query mocked: chrony state plus installed
# competing daemons come from the environment, systemctl records its verbs.
run_setup_hook() { # chrony_state (empty = absent) conflicts (space-listed)
    CHRONY_STATE="$1" HOOK_CONFLICTS="$2" bash -c '
        chmod() { :; }
        python3() { return 0; }
        systemctl() { printf "%s:%s\n" "$1" "$2"; }
        dpkg-query() {
            local pkg="${*: -1}" conflict
            if [ "$pkg" = chrony ]; then
                [ -n "$CHRONY_STATE" ] || return 1
                printf "%s\n" "$CHRONY_STATE"
                return 0
            fi
            for conflict in $HOOK_CONFLICTS; do
                [ "$pkg" = "$conflict" ] || continue
                printf "install ok installed\n"
                return 0
            done
            return 1
        }
        source "$1"
    ' _ "$HOOK" 2>&1
}

output="$(run_setup_hook 'install ok installed' '')"; rc=$?
assert_rc "healthy image: hook succeeds" 0 "$rc"
assert_contains "healthy image: chrony.service enabled" "$output" 'enable:chrony.service'
assert_contains "healthy image: NetworkManager still enabled" "$output" 'enable:NetworkManager.service'
assert_contains "healthy image: live desktop unit still enabled" "$output" 'enable:sensible-live-desktop.service'
assert_not_contains "healthy image: no service is started in the chroot" "$output" 'start:'

output="$(run_setup_hook '' '')"; rc=$?
assert_rc "missing chrony: hook fails" 1 "$rc"
assert_contains "missing chrony: diagnosis names the package" "$output" 'chrony is missing from the image.'
assert_not_contains "missing chrony: service not enabled" "$output" 'enable:chrony.service'

output="$(run_setup_hook 'install ok half-installed' '')"; rc=$?
assert_rc "half-installed chrony: hook fails" 1 "$rc"
assert_contains "half-installed chrony: same diagnosis" "$output" 'chrony is missing from the image.'
assert_not_contains "half-installed chrony: service not enabled" "$output" 'enable:chrony.service'

for extra in systemd-timesyncd ntpsec openntpd ntp; do
    output="$(run_setup_hook 'install ok installed' "$extra")"; rc=$?
    assert_rc "${extra} installed: hook fails" 1 "$rc"
    assert_contains "${extra} installed: diagnosis names the daemon" "$output" \
        "${extra} is installed; chrony is the only time daemon."
    assert_not_contains "${extra} installed: chrony not enabled" "$output" 'enable:chrony.service'
done

t_section "installer enables chrony without aborting an offline install"
installer_src="$(<"$INSTALLER")"
assert_contains "target enables chrony.service" "$installer_src" 'systemctl enable chrony.service'
assert_contains "enable failure degrades to a warning, not an abort" "$installer_src" \
    'record_warning "Time synchronization could not be enabled; the clock stays at the hardware time until chrony is enabled."'

t_section "firewall does not open inbound NTP"
assert_file_not_contains "ufw hook does not mention port 123" "$UFW_HOOK" "123"
hooks_src=""
for hook in "${REPO_ROOT}"/live/config/hooks/live/*.hook.chroot; do
    [ -f "$hook" ] || continue
    hooks_src+="$(<"$hook")"$'\n'
done
assert_not_contains "no hook allows inbound NTP" "$hooks_src" "ufw allow 123"

t_summary
