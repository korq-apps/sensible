# shellcheck shell=bash
# Stable CI marker for the serial autologin shell. The graphical installer is
# intentionally tty1-only, while the headless boot smoke observes ttyS0.

[ -n "${BASH_VERSION:-}" ] || return 0
case "$-" in *i*) ;; *) return 0 ;; esac
[ "$(tty 2>/dev/null)" = "/dev/ttyS0" ] || return 0

printf '\nSENSIBLE_LIVE_SERIAL_READY\n'
