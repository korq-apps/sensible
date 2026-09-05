#!/usr/bin/env bash
# Common logging, UI abstractions, and environment checks for Sensible Installer

# Target mount point (overridable for tests; ${MNT} in production)
MNT="${MNT:-/mnt}"
INSTALL_WARNINGS=()
INSTALL_LOG="${INSTALL_LOG:-/var/log/sensible-install.log}"
INSTALL_LOG_ACTIVE="false"
INSTALL_TEE_PID=""
INSTALL_OUTPUT_QUIET="false"

start_install_log() {
    mkdir -p "$(dirname "$INSTALL_LOG")"
    : > "$INSTALL_LOG"
    if chgrp sudo "$INSTALL_LOG"; then
        chmod 640 "$INSTALL_LOG"
    else
        chmod 600 "$INSTALL_LOG"
        log_warn "Could not assign ${INSTALL_LOG} to the sudo group; keeping it root-only."
    fi
    # The normal graphical installer keeps command/package chatter in the log
    # and reserves the console for the progress UI. --debug and non-Gum runs
    # still mirror everything to the terminal. Secrets are never echoed and
    # shell tracing is never enabled.
    exec 8>&1 9>&2
    if [ "${SENSIBLE_DEBUG:-0}" != "1" ] \
        && declare -F _ui_use_gum >/dev/null 2>&1 \
        && _ui_use_gum; then
        exec > >(tee -a "$INSTALL_LOG" >/dev/null) 2>&1
        INSTALL_OUTPUT_QUIET="true"
    else
        exec > >(tee -a "$INSTALL_LOG" >&8) 2>&1
        INSTALL_OUTPUT_QUIET="false"
    fi
    INSTALL_TEE_PID=$!
    INSTALL_LOG_ACTIVE="true"
}

stop_install_log() {
    [ "$INSTALL_LOG_ACTIVE" = "true" ] || return 0
    exec 1>&8 2>&9
    exec 8>&- 9>&-
    INSTALL_LOG_ACTIVE="false"
    INSTALL_OUTPUT_QUIET="false"
    wait "$INSTALL_TEE_PID"
    INSTALL_TEE_PID=""
}

preserve_install_log() {
    [ -f "$INSTALL_LOG" ] || return 0
    [ -d "${MNT}" ] || return 0
    mkdir -p "${MNT}/var/log"
    cp "$INSTALL_LOG" "${MNT}/var/log/sensible-install.log"
    if chroot "${MNT}" chgrp sudo /var/log/sensible-install.log; then
        chmod 640 "${MNT}/var/log/sensible-install.log"
    else
        chmod 600 "${MNT}/var/log/sensible-install.log"
        log_warn "Could not assign the target install log to its sudo group; keeping it root-only."
    fi
}

require_id() {
    # Abort rather than continue with an empty critical identifier; such
    # breakage only surfaces as a boot failure after reboot.
    local label="$1" value="$2"
    if [ -z "$value" ]; then
        log_err "Could not read ${label}; refusing to continue with a broken configuration."
        exit 1
    fi
}

# UI Dialog wrapper (gum > whiptail > dialog > text) — mirrors ui.sh
if command -v gum >/dev/null 2>&1; then
    UI_TOOL="gum"
elif command -v whiptail >/dev/null 2>&1; then
    UI_TOOL="whiptail"
elif command -v dialog >/dev/null 2>&1; then
    UI_TOOL="dialog"
else
    UI_TOOL="text"
fi

log_info() {
    printf '\e[1;34m[INFO]\e[0m %s\n' "$*" >&2
}

log_success() {
    printf '\e[1;32m[OK]\e[0m %s\n' "$*" >&2
}

log_warn() {
    printf '\e[1;33m[WARN]\e[0m %s\n' "$*" >&2
}

log_err() {
    printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2
}

record_warning() {
    INSTALL_WARNINGS+=("$*")
    log_warn "$*"
}

# The desktop is selected when the ISO is built, not by the installer user.
# live-build places it on the kernel command line as sensible.variant=... so
# the running live session can describe and configure the correct edition.
detect_install_variant() {
    local cmdline_file="${1:-/proc/cmdline}"
    local variant="${SENSIBLE_VARIANT:-}"
    local arg

    if [ -r "${cmdline_file}" ]; then
        for arg in $(<"${cmdline_file}"); do
            case "${arg}" in
                sensible.variant=*) variant="${arg#sensible.variant=}" ;;
            esac
        done
    fi

    case "${variant}" in
        gnome|kde) printf '%s\n' "${variant}" ;;
        *)         printf 'gnome\n' ;;
    esac
}

# Legacy geometry kept for tests that source common.sh without ui.sh
if ! declare -F ui_msgbox >/dev/null 2>&1; then
ui_box_geometry() {
    local text="$1" min_height="${2:-12}" extra_rows="${3:-0}"
    local term_h term_w width height rows
    term_h=$(tput lines 2>/dev/null || echo 24)
    term_w=$(tput cols 2>/dev/null || echo 80)
    [ "${term_h:-0}" -lt 10 ] 2>/dev/null && term_h=24
    [ "${term_w:-0}" -lt 40 ] 2>/dev/null && term_w=80
    width=$(printf '%s\n' "$text" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
    width=$(( width + 8 ))
    [ "$width" -lt 60 ] && width=60
    [ "$width" -gt $(( term_w - 4 )) ] && width=$(( term_w - 4 ))
    rows=$(printf '%s\n' "$text" | awk -v w=$(( width - 6 )) '
        { n = length($0); r = (n == 0 ? 1 : int((n + w - 1) / w)); total += r }
        END { print total + 0 }')
    height=$(( rows + extra_rows + 8 ))
    [ "$height" -lt "$min_height" ] && height="$min_height"
    [ "$height" -gt $(( term_h - 2 )) ] && height=$(( term_h - 2 ))
    local list_height=$(( height - rows - 8 ))
    [ "$list_height" -lt 1 ] && list_height=1
    [ "$extra_rows" -eq 0 ] && list_height=0
    printf '%s %s %s\n' "$height" "$width" "$list_height"
}
ui_msgbox() {
    local title="$1" text="$2"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local gh gw; read -r gh gw _ <<<"$(ui_box_geometry "$text")"
        "$UI_TOOL" --title "$title" --msgbox "$text" "$gh" "$gw"
    else
        echo "=== $title ===" >&2; echo "$text" >&2; read -rp "Press Enter to continue..." _
    fi
}
ui_yesno() {
    local title="$1" text="$2" default="${3:-yes}"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local extra_flag="" rc; [ "$default" = "no" ] && extra_flag="--defaultno"
        while true; do local gh gw; read -r gh gw _ <<<"$(ui_box_geometry "$text")"
            # shellcheck disable=SC2086
            $UI_TOOL --title "$title" $extra_flag --yesno "$text" "$gh" "$gw"; rc=$?
            [ "$rc" -eq 255 ] && continue; return $rc; done
    else
        echo "=== $title ===" >&2; echo "$text" >&2
        while true; do read -rp "[y/n] (default: $default): " ans; ans="${ans:-$default}"
            case "$ans" in [Yy]*) return 0;; [Nn]*) return 1;; *) echo "Please answer y or n." >&2;; esac; done; fi
}
ui_inputbox() {
    local title="$1" text="$2" init_val="${3:-}"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res gh gw; read -r gh gw _ <<<"$(ui_box_geometry "$text" 12 2)"
        res=$("$UI_TOOL" --title "$title" --inputbox "$text" "$gh" "$gw" "$init_val" 3>&1 1>&2 2>&3); echo "$res"
    else
        echo "=== $title ===" >&2; echo "$text" >&2; read -rp "Value [$init_val]: " res; echo "${res:-$init_val}"; fi
}
ui_passwordbox() {
    local title="$1" text="$2"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res gh gw; read -r gh gw _ <<<"$(ui_box_geometry "$text" 12 2)"
        res=$("$UI_TOOL" --title "$title" --passwordbox "$text" "$gh" "$gw" 3>&1 1>&2 2>&3); echo "$res"
    else
        echo "=== $title ===" >&2; echo "$text" >&2; read -s -rp "Password: " res; echo "" >&2; echo "$res"; fi
}
ui_menu() {
    local title="$1" text="$2"; shift 2; local items=("$@")
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res gh gw gl; read -r gh gw gl <<<"$(ui_box_geometry "$text" 15 $(( ${#items[@]} / 2 )))"
        res=$("$UI_TOOL" --title "$title" --menu "$text" "$gh" "$gw" "$gl" "${items[@]}" 3>&1 1>&2 2>&3); echo "$res"
    else
        echo "=== $title ===" >&2; echo "$text" >&2; local i=1
        for ((j=0; j<${#items[@]}; j+=2)); do echo "$i) ${items[j]} - ${items[j+1]}" >&2; ((i++)); done
        local idx sel; while true; do read -rp "Selection: " sel
            if [[ "${sel:-}" =~ ^[0-9]+$ ]] && [ "${sel}" -ge 1 ] && [ "${sel}" -le $(( ${#items[@]} / 2 )) ]; then idx=$(((sel - 1) * 2)); echo "${items[idx]}"; return 0; fi
            echo "Please enter a number between 1 and $(( ${#items[@]} / 2 ))." >&2; done; fi
}
ui_checklist() {
    local title="$1" text="$2"; shift 2; local items=("$@")
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res gh gw gl; read -r gh gw gl <<<"$(ui_box_geometry "$text" 16 $(( ${#items[@]} / 3 )))"
        res=$("$UI_TOOL" --title "$title" --checklist "$text" "$gh" "$gw" "$gl" "${items[@]}" 3>&1 1>&2 2>&3); echo "$res"
    else
        echo "=== $title ===" >&2; echo "$text" >&2; echo "Selected items (space separated tags):" >&2; read -rp "> " res; echo "$res"; fi
}
fi

network_ready() {
    # Checking the actual Debian metadata endpoint catches disconnected links,
    # broken DNS, captive portals, and an unavailable mirror before any wipe.
    if curl -fsSL --connect-timeout 10 --max-time 20 \
        -o /dev/null https://deb.debian.org/debian/dists/testing/Release \
        >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

ensure_network() {
    while ! network_ready; do
        if ! ui_yesno "Internet Connection Required" "\
Sensible downloads Debian packages during installation, but it cannot reach
the Debian package server yet.

No disk has been changed. Open the network setup now, then Sensible will test
the connection again. Choose No to leave the installer safely." "yes"; then
            ui_msgbox "Installation Cancelled" "No changes were made. Connect to the Internet, then run sensible-install again."
            return 1
        fi

        if command -v nmtui-connect >/dev/null 2>&1; then
            if ! nmtui-connect; then
                log_info "Network setup was closed without selecting a connection."
            fi
        elif command -v nmtui >/dev/null 2>&1; then
            if ! nmtui; then
                log_info "Network setup was closed without applying a connection."
            fi
        else
            ui_msgbox "Network Setup Unavailable" "NetworkManager's setup screen is unavailable. Configure the network from the shell, then run sensible-install again."
            return 1
        fi
    done
}

check_uefi() {
    if [ ! -d /sys/firmware/efi ]; then
        log_err "UEFI boot is required. /sys/firmware/efi was not found."
        log_err "Sensible only supports amd64 systems booted in UEFI mode."
        # Say how to fix it, not just what is wrong: reaching this point means
        # someone already booted the live medium and got all the way into the
        # installer, so "boot in UEFI mode" alone leaves them stuck.
        ui_msgbox "Error: Non-UEFI System" "\
Sensible requires UEFI boot, but this system booted in legacy BIOS mode,
so the installer cannot continue.

Virtual machine (QEMU/libvirt/virt-manager):
  Set the firmware to UEFI (OVMF) instead of the default BIOS/SeaBIOS.
  virt-manager: Overview -> Firmware -> UEFI x86_64 (a new VM is needed;
  firmware cannot be switched on an existing one).
  qemu directly: pass an OVMF pflash pair, as scripts/run-qemu.sh does.

Physical machine:
  Enable UEFI in firmware setup and disable Legacy/CSM/BIOS compatibility,
  then boot the medium from its UEFI entry.

Sensible installs a UEFI-only system (GRUB EFI on an ESP), which is why
a BIOS-booted session is refused before any disk is touched."
        exit 1
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "Installer must be run as root. Please run with sudo or as root."
        exit 1
    fi
}
