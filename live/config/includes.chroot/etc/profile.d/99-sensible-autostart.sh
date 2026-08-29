# shellcheck shell=bash
# Auto-start the installer on the live console.
#
# Deliberately narrow, so this never fires anywhere it would surprise someone:
#   - only on /dev/tty1 (the autologin console), never over SSH or on ttyS0,
#   - only for an interactive bash login shell,
#   - only once per boot, guarded by a marker under /run. Without that, an
#     installer that exits immediately would restart on every getty respawn
#     and loop,
#   - not when booted in legacy BIOS mode, where check_uefi would refuse
#     anyway; 99-sensible-firmware-check.sh has already explained why.
#
# A short countdown leaves an escape hatch to the shell for diagnostics or
# manual network setup. The installer itself now checks and guides networking.

[ -n "${BASH_VERSION:-}" ] || return 0
case "$-" in *i*) ;; *) return 0 ;; esac
[ "$(tty 2>/dev/null)" = "/dev/tty1" ] || return 0
[ -d /sys/firmware/efi ] || return 0
[ -x /usr/local/bin/sensible-install ] || return 0

_sensible_marker=/run/sensible-autostart.done
[ -e "${_sensible_marker}" ] && { unset _sensible_marker; return 0; }
: > "${_sensible_marker}" 2>/dev/null || true
unset _sensible_marker

printf '\n  Starting the Sensible installer in 5s '
printf -- '- press any key to stay at the shell...'
if read -r -t 5 -n 1 -s; then
    printf '\n\n  Cancelled. Run "sensible-install" when ready.\n\n'
else
    printf '\n\n'
    sensible-install
    printf '\n  Installer exited. Run "sensible-install" to start it again.\n\n'
fi
