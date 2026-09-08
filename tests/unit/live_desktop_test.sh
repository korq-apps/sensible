#!/usr/bin/env bash
# Unit tests: sensible-live-desktop, the one-shot that prepares the "Try
# Sensible" live desktop chosen from the boot menu.
TEST_NAME="live_desktop_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPT="${REPO_ROOT}/live/config/includes.chroot/usr/local/bin/sensible-live-desktop"
LAUNCHER_SRC="${REPO_ROOT}/live/config/includes.chroot/usr/share/applications/sensible-install.desktop"
TMP="$(mktemp -d /tmp/sensible-live-desktop-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

make_root() { # name variant [live-user]
    local root="${TMP}/$1"
    rm -rf "$root"
    mkdir -p "$root/etc/sensible" "$root/home/${3:-user}" "$root/usr/share/applications"
    printf '%s\n' "$2" > "$root/etc/sensible/variant"
    cp "$LAUNCHER_SRC" "$root/usr/share/applications/sensible-install.desktop"
    printf '%s' "$root"
}

cmdline() { # name args...
    local file="${TMP}/cmdline-$1"
    shift
    printf '%s\n' "$*" > "$file"
    printf '%s' "$file"
}

# The script runs as a separate bash process; root-only tools are doubled by
# exported functions that record their arguments.
mock_setup
export MOCK_LOG
runuser() {
    mlog "runuser $*"
    case "$*" in
        *"gsettings get org.gnome.shell favorite-apps"*) printf '%s\n' "${MOCK_FAVORITES:-[]}" ;;
    esac
    return 0
}
chown() { mlog "chown $*"; return 0; }
export -f mlog runuser chown
export MOCK_FAVORITES="['org.gnome.Nautilus.desktop', 'firefox-esr.desktop']"

run_prep() { # root cmdline-file
    mock_reset
    OUTPUT="$(SENSIBLE_LIVE_ROOT="$1" SENSIBLE_LIVE_CMDLINE="$2" bash "$SCRIPT" 2>&1)"
    RC=$?
}

INSTALL_CMDLINE="$(cmdline install boot=live components sensible.variant=gnome console=tty0)"
DESKTOP_CMDLINE="$(cmdline desktop boot=live components sensible.variant=gnome sensible.session=desktop systemd.unit=graphical.target)"

t_section "default console boot leaves everything alone"
ROOT="$(make_root console gnome)"
run_prep "$ROOT" "$INSTALL_CMDLINE"
assert_rc "exits cleanly" 0 "$RC"
assert_eq "no output" "" "$OUTPUT"
assert_eq "no privileged calls" "" "$(cat "$MOCK_LOG")"
assert_file_not_exists "no live files written" "${ROOT}/home/user/.config/kscreenlockerrc"

t_section "GNOME live desktop: lock off, installer pinned first in the dash"
ROOT="$(make_root gnome gnome)"
run_prep "$ROOT" "$DESKTOP_CMDLINE"
assert_rc "exits cleanly" 0 "$RC"
assert_contains "screen lock disabled for the throwaway account" "$(cat "$MOCK_LOG")" \
    "runuser -u user -- env HOME=/home/user dbus-run-session -- gsettings set org.gnome.desktop.screensaver lock-enabled false"
assert_contains "installer prepended to existing favourites" "$(cat "$MOCK_LOG")" \
    "gsettings set org.gnome.shell favorite-apps ['sensible-install.desktop', 'org.gnome.Nautilus.desktop', 'firefox-esr.desktop']"
MOCK_FAVORITES="[]" run_prep "$ROOT" "$DESKTOP_CMDLINE"
assert_contains "empty favourites become the installer alone" "$(cat "$MOCK_LOG")" \
    "gsettings set org.gnome.shell favorite-apps ['sensible-install.desktop']"
MOCK_FAVORITES="['sensible-install.desktop', 'org.gnome.Nautilus.desktop']" run_prep "$ROOT" "$DESKTOP_CMDLINE"
assert_not_contains "already pinned installer is not duplicated" "$(cat "$MOCK_LOG")" "gsettings set org.gnome.shell favorite-apps"
assert_not_contains "GNOME path writes no KDE files" "$(cat "$MOCK_LOG")" "chown"

t_section "KDE live desktop: lock off, desktop icon, SDDM session completed"
ROOT="$(make_root kde kde)"
printf '[Autologin]\nUser=user\nSession=\n' > "${ROOT}/etc/sddm.conf"
run_prep "$ROOT" "$DESKTOP_CMDLINE"
assert_rc "exits cleanly" 0 "$RC"
assert_file_contains "kscreenlocker autolock off" "${ROOT}/home/user/.config/kscreenlockerrc" "Autolock=false"
assert_file_contains "kscreenlocker lock-on-resume off" "${ROOT}/home/user/.config/kscreenlockerrc" "LockOnResume=false"
assert_file_exists "installer icon on the Plasma desktop" "${ROOT}/home/user/Desktop/sensible-install.desktop"
if [ -x "${ROOT}/home/user/Desktop/sensible-install.desktop" ]; then t_ok; else t_fail "desktop icon is executable" "Plasma refuses non-executable launchers"; fi
assert_contains "live files handed to the live user" "$(cat "$MOCK_LOG")" "chown -R user:user ${ROOT}/home/user/.config ${ROOT}/home/user/Desktop"
assert_file_contains "empty SDDM session filled with the Wayland session" "${ROOT}/etc/sddm.conf" "Session=plasma"
assert_not_contains "KDE path touches no GSettings" "$(cat "$MOCK_LOG")" "gsettings"
printf '[Autologin]\nUser=user\nSession=plasma.desktop\n' > "${ROOT}/etc/sddm.conf"
run_prep "$ROOT" "$DESKTOP_CMDLINE"
assert_file_contains "an SDDM session live-config chose is kept" "${ROOT}/etc/sddm.conf" "Session=plasma.desktop"

t_section "live username from the kernel command line is honoured"
ROOT="$(make_root named kde demo)"
NAMED_CMDLINE="$(cmdline named boot=live components live-config.username=demo sensible.session=desktop)"
run_prep "$ROOT" "$NAMED_CMDLINE"
assert_rc "exits cleanly" 0 "$RC"
assert_file_exists "files land in the named user's home" "${ROOT}/home/demo/.config/kscreenlockerrc"
assert_contains "ownership follows the named user" "$(cat "$MOCK_LOG")" "chown -R demo:demo"

t_section "degraded live roots never block the display manager"
ROOT="$(make_root nohome gnome)"
rm -rf "${ROOT}/home/user"
run_prep "$ROOT" "$DESKTOP_CMDLINE"
assert_rc "missing home exits cleanly" 0 "$RC"
assert_contains "missing home explained" "$OUTPUT" "live user 'user' has no home"
ROOT="$(make_root odd other)"
run_prep "$ROOT" "$DESKTOP_CMDLINE"
assert_rc "unknown variant exits cleanly" 0 "$RC"
assert_contains "unknown variant explained" "$OUTPUT" "unknown desktop variant 'other'"
assert_eq "unknown variant makes no privileged calls" "" "$(cat "$MOCK_LOG")"
run_prep "$ROOT" "${TMP}/does-not-exist"
assert_rc "unreadable command line exits cleanly" 0 "$RC"

mock_teardown
t_summary
