#!/usr/bin/env bash
# Common logging, UI abstractions, and environment checks for Sensible Installer

# Target mount point (overridable for tests; ${MNT} in production)
MNT="${MNT:-/mnt}"

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

ui_msgbox() {
    local title="$1"
    local text="$2"
    if [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        "$UI_TOOL" --title "$title" --msgbox "$text" 12 70
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

check_uefi() {
    if [ ! -d /sys/firmware/efi ]; then
        log_err "UEFI boot is required. /sys/firmware/efi was not found."
        log_err "Sensible only supports amd64 systems booted in UEFI mode."
        ui_msgbox "Error: Non-UEFI System" "Sensible requires UEFI boot. This system booted in legacy BIOS mode. Please boot in UEFI mode."
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
        | chroot ${MNT} debconf-set-selections 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive chroot ${MNT} dpkg-reconfigure -f noninteractive keyboard-configuration >/dev/null 2>&1 || true
    cat <<EOF > ${MNT}/etc/default/keyboard
# Written by sensible-install
XKBMODEL="pc105"
XKBLAYOUT="${layout}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    log_success "Keyboard layout '${layout}' configured."
}
