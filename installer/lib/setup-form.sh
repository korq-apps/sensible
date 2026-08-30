#!/usr/bin/env bash
# Sensible setup-form - shared validation and prompt helpers
# Used by both the installer and any first-boot path so wording/rules cannot drift.
# Inspired by omarchy-iso setup-form.sh / configurator patterns.

# Status codes (must match ui.sh)
SETUP_FORM_OK=0
SETUP_FORM_BACK=1
SETUP_FORM_SIGNAL=130
SETUP_FORM_ABORT=2

# ── Validation (shared) ──

valid_hostname() {
    local hostname="$1"
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
    case "$username" in
        sddm|gdm|avahi|colord|geoclue|rtkit|saned|fwupd-refresh|nm-openvpn|speech-dispatcher|usbmux|polkitd|pulse|pipewire|_flatpak)
            return 1 ;;
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

valid_locale() {
    local locale="$1"
    [ -r /usr/share/i18n/SUPPORTED ] || return 0  # accept if no SUPPORTED file (tests)
    awk -v loc="${locale}" '$1 == loc && $2 == "UTF-8" { found = 1 } END { exit !found }' /usr/share/i18n/SUPPORTED
}

# ── Live keyboard helpers ──

detect_keyboard_layout() {
    local kb_file="${1:-/etc/default/keyboard}"
    local layout=""
    if [ -r "$kb_file" ]; then
        layout=$(grep -E '^XKBLAYOUT=' "$kb_file" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"')
    fi
    echo "${layout:-us}"
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

configure_keyboard() {
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

# ── Prompt helpers (each returns 0 ok / 1 back / 130 signal) ──

# Detect gum vs fallback for prompts
_setup_use_gum() {
    [ "${UI_TOOL:-}" = "gum" ] && [ -t 0 ] 2>/dev/null && [ -t 2 ] 2>/dev/null
}

# Generic input with validation loop
# Usage: _prompt_input "title" "text" "default" "validation_fn" "error_msg" -> sets REPLY
_prompt_input_loop() {
    local title="$1" text="$2" default="$3" valid_fn="$4" err_msg="$5"
    local val rc
    while true; do
        if _setup_use_gum; then
            clear_logo
            echo
            gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
            echo
            gum style --padding "0 0 0 $PADDING_LEFT" "$text"
            echo
            val=$(gum input --placeholder "$default" --value "$default" --width 50 2>/dev/tty) rc=$?
            # gum: 0=ok, 130=ctrl-c, 1=esc/abort (mapped to BACK)
            if [ $rc -eq 130 ]; then return $SETUP_FORM_SIGNAL; fi
            if [ $rc -ne 0 ]; then return $SETUP_FORM_BACK; fi
        else
            val=$(ui_inputbox "$title" "$text" "$default")
            rc=$?
            [ $rc -ne 0 ] && return $SETUP_FORM_BACK
        fi
        val="${val:-$default}"
        if [ -n "$valid_fn" ] && ! "$valid_fn" "$val"; then
            if _setup_use_gum; then
                clear_logo; echo; gum style --padding "0 0 0 $PADDING_LEFT" --foreground 1 "$err_msg"
                sleep 1.5
            else
                ui_msgbox "Invalid Input" "$err_msg"
            fi
            continue
        fi
        REPLY="$val"
        return $SETUP_FORM_OK
    done
}

sensible_prompt_keyboard() {
    local current
    current=$(detect_keyboard_layout)
    while true; do
        _prompt_input_loop "Keyboard layout" "Enter keyboard layout (e.g. us, gb, de, fr). Applied before passwords:" "$current" "validate_keyboard_layout" "Layout not found. Use codes like us, gb, de, fr, es." || return $?
        local layout="$REPLY"
        if ! apply_live_keyboard "$layout" "${LIVE_KEYBOARD_FILE:-/etc/default/keyboard}"; then
            if _setup_use_gum; then
                clear_logo; echo; gum style --padding "0 0 0 $PADDING_LEFT" --foreground 1 "Could not apply '$layout'."
                sleep 1.5
            else
                ui_msgbox "Keyboard Setup Failed" "Could not apply '$layout'. Choose another."
            fi
            continue
        fi
        keyboard="$layout"
        return $SETUP_FORM_OK
    done
}

sensible_prompt_username() {
    while true; do
        _prompt_input_loop "Username" "Enter username (lowercase, starts with letter, max 32):" "" "" "" || return $?
        local val="$REPLY"
        if ! valid_username "$val"; then
            if _setup_use_gum; then
                clear_logo; echo; gum style --padding "0 0 0 $PADDING_LEFT" --foreground 1 "Invalid username. Use a-z, 0-9, -, _, starting with letter/_."
                sleep 1.5
            else
                ui_msgbox "Invalid Username" "Use up to 32 lowercase letters, numbers, hyphens, or underscores, starting with a letter or underscore."
            fi
            continue
        fi
        username="$val"
        return $SETUP_FORM_OK
    done
}

sensible_prompt_password() {
    # Unified password: used for both LUKS (if enabled) and user account
    # Mandatory double-entry, min 8 chars
    local pw1 pw2 rc
    while true; do
        if _setup_use_gum; then
            clear_logo; echo
            gum style --padding "0 0 0 $PADDING_LEFT" --bold "Password"
            echo
            gum style --padding "0 0 0 $PADDING_LEFT" "Enter password for ${username:-user} (min 8 chars). Also used for disk encryption if enabled."
            echo
            pw1=$(gum input --password --placeholder "Enter password" 2>/dev/tty) rc=$?
            if [ $rc -eq 130 ]; then return $SETUP_FORM_SIGNAL; fi
            if [ $rc -ne 0 ]; then return $SETUP_FORM_BACK; fi
        else
            pw1=$(ui_passwordbox "User Password" "Enter password for ${username:-user} and encryption (min 8 chars):") || return $SETUP_FORM_BACK
        fi
        if [ -z "$pw1" ]; then
            if _setup_use_gum; then clear_logo; echo; gum style --padding "0 0 0 $PADDING_LEFT" --foreground 1 "Password cannot be empty."; sleep 1.2
            else ui_msgbox "Invalid Password" "Password cannot be empty."; fi
            continue
        fi
        if [ ${#pw1} -lt 8 ]; then
            if _setup_use_gum; then clear_logo; echo; gum style --padding "0 0 0 $PADDING_LEFT" --foreground 1 "Password must be at least 8 characters."; sleep 1.2
            else ui_msgbox "Invalid Password" "Password must be at least 8 characters."; fi
            continue
        fi
        if _setup_use_gum; then
            pw2=$(gum input --password --placeholder "Confirm password" 2>/dev/tty) rc=$?
            if [ $rc -eq 130 ]; then return $SETUP_FORM_SIGNAL; fi
            if [ $rc -ne 0 ]; then return $SETUP_FORM_BACK; fi
        else
            pw2=$(ui_passwordbox "Confirm Password" "Re-enter password:") || return $SETUP_FORM_BACK
        fi
        if [ "$pw1" != "$pw2" ]; then
            if _setup_use_gum; then clear_logo; echo; gum style --padding "0 0 0 $PADDING_LEFT" --foreground 1 "Passwords did not match."; sleep 1.2
            else ui_msgbox "Mismatch" "Passwords did not match."; fi
            continue
        fi
        password="$pw1"
        # Also set legacy vars for installer compatibility
        USERPASS="$pw1"
        LUKS_PASSPHRASE="$pw1"
        return $SETUP_FORM_OK
    done
}

sensible_prompt_hostname() {
    _prompt_input_loop "Computer name" "Choose a name for this computer (letters, numbers, hyphens):" "debian" "valid_hostname" "Invalid hostname. Use letters, numbers, hyphens, dots." || return $?
    hostname="$REPLY"
    return $SETUP_FORM_OK
}

sensible_prompt_timezone() {
    local current
    current=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    [ -z "$current" ] && current="UTC"
    while true; do
        _prompt_input_loop "Timezone" "Enter timezone (e.g. UTC, Europe/Berlin, America/New_York):" "$current" "valid_timezone" "Timezone not found. Use IANA name like Europe/Berlin." || return $?
        timezone="$REPLY"
        return $SETUP_FORM_OK
    done
}

sensible_prompt_locale() {
    while true; do
        _prompt_input_loop "Locale" "Enter system locale:" "en_US.UTF-8" "valid_locale" "Locale not found in /usr/share/i18n/SUPPORTED. Try en_US.UTF-8." || return $?
        locale_val="$REPLY"
        # Also set LOCALE var for compatibility
        LOCALE="$locale_val"
        return $SETUP_FORM_OK
    done
}

sensible_prompt_identity() {
    # Optional full name / email for git + GECOS (can be skipped)
    local name_input email_input
    if _setup_use_gum; then
        clear_logo; echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "Identity (optional)"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" --foreground 8 "Full name and email for git. Leave empty to skip."
        echo
        name_input=$(gum input --placeholder "Full name (optional)" --width 50 2>/dev/tty) || return $SETUP_FORM_BACK
        # Allow empty - not validated
        email_input=$(gum input --placeholder "Email (optional)" --width 50 2>/dev/tty) || return $SETUP_FORM_BACK
    else
        name_input=$(ui_inputbox "Full name (optional)" "Enter full name for git/GECOS (leave empty to skip):" "") || return $SETUP_FORM_BACK
        email_input=$(ui_inputbox "Email (optional)" "Enter email for git (leave empty to skip):" "") || return $SETUP_FORM_BACK
    fi
    full_name="$name_input"
    email_address="$email_input"
    return $SETUP_FORM_OK
}
