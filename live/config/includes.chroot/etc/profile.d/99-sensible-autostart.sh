# shellcheck shell=bash
# Auto-start the installer on the live console.
#
# Deliberately narrow, so this never fires anywhere it would surprise someone:
#   - only on /dev/tty1 (the autologin console), never over SSH or on ttyS0,
#   - only for an interactive bash login shell,
#   - not when booted in legacy BIOS mode, where check_uefi would refuse
#     anyway; 99-sensible-firmware-check.sh has already explained why.
#
# The installer opens immediately. Diagnostics remain available by leaving or
# cancelling it. A new login starts it again, which is useful recovery
# behaviour for an installer-only live session.

[ -n "${BASH_VERSION:-}" ] || return 0
case "$-" in *i*) ;; *) return 0 ;; esac
[ "$(tty 2>/dev/null)" = "/dev/tty1" ] || return 0
[ -d /sys/firmware/efi ] || return 0
[ -x /usr/local/bin/sensible-install ] || return 0

sensible-install
printf '\n  Installer exited. Run "sensible-install" to start it again.\n\n'
