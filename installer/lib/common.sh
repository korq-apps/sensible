#!/usr/bin/env bash
# Common logging, UI abstractions, and environment checks for Sensible Installer

# Target mount point (overridable for tests; ${MNT} in production)
MNT="${MNT:-/mnt}"
INSTALL_WARNINGS=()
INSTALL_LOG="${INSTALL_LOG:-/var/log/sensible-install.log}"
INSTALL_LOG_ACTIVE="false"
INSTALL_TEE_PID=""

start_install_log() {
    mkdir -p "$(dirname "$INSTALL_LOG")"
    : > "$INSTALL_LOG"
    chmod 600 "$INSTALL_LOG"
    # Keep the terminal useful while retaining command/package output. Secrets
    # are entered without echo and shell tracing is never enabled.
    exec 8>&1 9>&2
    exec > >(tee -a "$INSTALL_LOG" >&8) 2>&1
    INSTALL_TEE_PID=$!
    INSTALL_LOG_ACTIVE="true"
}

stop_install_log() {
    [ "$INSTALL_LOG_ACTIVE" = "true" ] || return 0
    exec 1>&8 2>&9
    exec 8>&- 9>&-
    INSTALL_LOG_ACTIVE="false"
    wait "$INSTALL_TEE_PID"
    INSTALL_TEE_PID=""
}

preserve_install_log() {
    [ -f "$INSTALL_LOG" ] || return 0
    [ -d "${MNT}" ] || return 0
    mkdir -p "${MNT}/var/log"
    cp "$INSTALL_LOG" "${MNT}/var/log/sensible-install.log"
    chmod 600 "${MNT}/var/log/sensible-install.log"
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

# UI Dialog wrapper (detect whiptail or dialog)
if command -v whiptail >/dev/null 2>&1; then
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

# Size a dialog to its content instead of a fixed 12x70 box.
#
# whiptail silently truncates text that does not fit, so a fixed height turns a
# long, genuinely useful message (why no disk qualified, how to switch the VM to
# UEFI) into a clipped one -- the reader loses exactly the part that helps.
# Accounts for wrapping, since whiptail re-wraps lines wider than the box, and
# clamps to the terminal so the dialog never exceeds the screen.
#
# Echoes "HEIGHT WIDTH".
ui_box_geometry() {
    local text="$1" min_height="${2:-12}"
    local term_h term_w width height rows
    term_h=$(tput lines 2>/dev/null || echo 24)
    term_w=$(tput cols 2>/dev/null || echo 80)
    [ "${term_h:-0}" -lt 10 ] 2>/dev/null && term_h=24
    [ "${term_w:-0}" -lt 40 ] 2>/dev/null && term_w=80

    width=$(printf '%s\n' "$text" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
    width=$(( width + 8 ))
    [ "$width" -lt 60 ] && width=60
    [ "$width" -gt $(( term_w - 4 )) ] && width=$(( term_w - 4 ))

    # Wrapped row count: a line wider than the text area occupies several rows.
    rows=$(printf '%s\n' "$text" | awk -v w=$(( width - 6 )) '
        { n = length($0); r = (n == 0 ? 1 : int((n + w - 1) / w)); total += r }
        END { print total + 0 }')
    height=$(( rows + 8 ))
    [ "$height" -lt "$min_height" ] && height="$min_height"
    [ "$height" -gt $(( term_h - 2 )) ] && height=$(( term_h - 2 ))

    printf '%s %s\n' "$height" "$width"
}

ui_msgbox() {
    local title="$1"
    local text="$2"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local geom
        geom=$(ui_box_geometry "$text")
        # shellcheck disable=SC2086
        "$UI_TOOL" --title "$title" --msgbox "$text" ${geom}
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        read -rp "Press Enter to continue..."
    fi
}

ui_yesno() {
    local title="$1"
    local text="$2"
    local default="${3:-yes}"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local extra_flag=""
        local rc
        [ "$default" = "no" ] && extra_flag="--defaultno"
        while true; do
            # shellcheck disable=SC2086
            "$UI_TOOL" --title "$title" $extra_flag --yesno "$text" 12 70
            rc=$?
            # ESC (255) must not silently flip a dangerous choice (e.g. LUKS off)
            [ "$rc" -eq 255 ] && continue
            return $rc
        done
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        while true; do
            read -rp "[y/n] (default: $default): " ans
            ans="${ans:-$default}"
            case "$ans" in
                [Yy]* ) return 0 ;;
                [Nn]* ) return 1 ;;
                * ) echo "Please answer y or n." >&2 ;;
            esac
        done
    fi
}

ui_inputbox() {
    local title="$1"
    local text="$2"
    local init_val="${3:-}"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res
        res=$("$UI_TOOL" --title "$title" --inputbox "$text" 12 70 "$init_val" 3>&1 1>&2 2>&3)
        echo "$res"
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        read -rp "Value [$init_val]: " res
        echo "${res:-$init_val}"
    fi
}

ui_passwordbox() {
    local title="$1"
    local text="$2"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res
        res=$("$UI_TOOL" --title "$title" --passwordbox "$text" 12 70 3>&1 1>&2 2>&3)
        echo "$res"
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        read -s -rp "Password: " res
        echo "" >&2
        echo "$res"
    fi
}

ui_menu() {
    local title="$1"
    local text="$2"
    shift 2
    local items=("$@")
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res
        res=$("$UI_TOOL" --title "$title" --menu "$text" 15 70 6 "${items[@]}" 3>&1 1>&2 2>&3)
        echo "$res"
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        local i=1
        for ((j=0; j<${#items[@]}; j+=2)); do
            echo "$i) ${items[j]} - ${items[j+1]}" >&2
            ((i++))
        done
        # Re-prompt until the selection is a number within range; an empty or
        # non-numeric answer must never map to an unintended item.
        local idx sel
        while true; do
            read -rp "Selection: " sel
            if [[ "${sel:-}" =~ ^[0-9]+$ ]] && [ "${sel}" -ge 1 ] && [ "${sel}" -le $(( ${#items[@]} / 2 )) ]; then
                idx=$(((sel - 1) * 2))
                echo "${items[idx]}"
                return 0
            fi
            echo "Please enter a number between 1 and $(( ${#items[@]} / 2 ))." >&2
        done
    fi
}

ui_checklist() {
    local title="$1"
    local text="$2"
    shift 2
    local items=("$@")
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res
        res=$("$UI_TOOL" --title "$title" --checklist "$text" 16 70 6 "${items[@]}" 3>&1 1>&2 2>&3)
        echo "$res"
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        # simple fallback
        echo "Selected items (space separated tags):" >&2
        read -rp "> " res
        echo "$res"
    fi
}

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
            nmtui-connect || true
        elif command -v nmtui >/dev/null 2>&1; then
            nmtui || true
        else
            ui_msgbox "Network Setup Unavailable" "NetworkManager's setup screen is unavailable. Configure the network from the shell, then run sensible-install again."
            return 1
        fi
    done
}

valid_hostname() {
    local hostname="$1"
    # Linux's static hostname is limited to 64 bytes including the terminator.
    [ ${#hostname} -ge 1 ] && [ ${#hostname} -le 63 ] || return 1
    [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1

    local label
    IFS='.' read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        [ ${#label} -ge 1 ] && [ ${#label} -le 63 ] || return 1
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

valid_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
    [ ${#username} -le 32 ] || return 1
    ! getent passwd "$username" >/dev/null 2>&1 || return 1
    # These accounts are created by packages installed later, but do not all
    # exist in the small live image used for preflight validation.
    case "$username" in
        sddm|gdm|avahi|colord|geoclue|rtkit|saned|fwupd-refresh|nm-openvpn|speech-dispatcher|usbmux|polkitd|pulse|pipewire|_flatpak)
            return 1
            ;;
    esac
    return 0
}

valid_timezone() {
    local timezone="$1" zoneinfo="${2:-/usr/share/zoneinfo}" part resolved
    [[ "$timezone" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]] || return 1
    IFS='/' read -r -a timezone_parts <<< "$timezone"
    for part in "${timezone_parts[@]}"; do
        [ "$part" != "." ] && [ "$part" != ".." ] || return 1
    done
    resolved=$(realpath -e "${zoneinfo}/${timezone}" 2>/dev/null) || return 1
    [[ "$resolved" = "${zoneinfo}/"* ]] && [ -f "$resolved" ]
}

validate_keyboard_layout() {
    local layout="$1"
    local symbols_dir="${2:-/usr/share/X11/xkb/symbols}"
    [[ "$layout" =~ ^[a-z0-9_-]+(,[a-z0-9_-]+)*$ ]] || return 1

    local item
    IFS=',' read -r -a layouts <<< "$layout"
    for item in "${layouts[@]}"; do
        [ -f "${symbols_dir}/${item}" ] || return 1
    done
}

apply_live_keyboard() {
    local layout="$1"
    local keyboard_file="${2:-/etc/default/keyboard}"
    if ! cat <<EOF > "$keyboard_file"
# Written by sensible-install
XKBMODEL="pc105"
XKBLAYOUT="${layout}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    then
        return 1
    fi
    setupcon --force --keyboard-only >/dev/null 2>&1 || return 1
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

detect_keyboard_layout() {
    # Live session console layout (spec §3: "live console layout")
    local kb_file="${1:-/etc/default/keyboard}"
    local layout=""
    if [ -r "$kb_file" ]; then
        layout=$(grep -E '^XKBLAYOUT=' "$kb_file" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"')
    fi
    echo "${layout:-us}"
}

configure_keyboard() {
    # Write the keyboard layout through keyboard-configuration (spec §3)
    local layout="$1"
    log_info "Configuring keyboard layout '${layout}' via keyboard-configuration..."
    printf 'keyboard-configuration keyboard-configuration/layoutcode select %s\n' "$layout" \
        | chroot "${MNT}" debconf-set-selections
    DEBIAN_FRONTEND=noninteractive chroot "${MNT}" dpkg-reconfigure -f noninteractive keyboard-configuration >/dev/null
    cat <<EOF > "${MNT}/etc/default/keyboard"
# Written by sensible-install
XKBMODEL="pc105"
XKBLAYOUT="${layout}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    log_success "Keyboard layout '${layout}' configured."
}
