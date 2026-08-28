# shellcheck shell=sh
# Warn at login when the live medium was booted in legacy BIOS mode.
#
# Sensible installs a UEFI-only system, so check_uefi refuses a BIOS-booted
# session. Without this notice that refusal only appears after someone has
# booted, read the MOTD and launched the installer -- announce it up front
# instead, while switching firmware is still cheap.
if [ ! -d /sys/firmware/efi ]; then
    printf '\033[1;33m'
    printf '  WARNING: this session booted in legacy BIOS mode.\n'
    printf '\033[0m'
    printf '  Sensible installs a UEFI-only system, so the installer will\n'
    printf '  refuse to run until the machine is booted via UEFI.\n\n'
    printf '  VM: set firmware to UEFI (OVMF), not the default BIOS/SeaBIOS.\n'
    printf '  Hardware: enable UEFI and disable Legacy/CSM, then boot the\n'
    printf '  medium from its UEFI entry.\n\n'
fi
