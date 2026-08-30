#!/usr/bin/env bash
# Sensible UI - gum-based TUI with whiptail/text fallback
# Inspired by omarchy-iso configurator: centered logo, measured terminal,
# gum style/choose/confirm/input primitives.

# Logging helpers (kept here so ui.sh is self-contained for setup-form)
# shellcheck disable=SC2145,SC2128
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()    { printf '\e[1;34m[INFO]\e[0m %s\n' "$*" >&2; }
    log_success() { printf '\e[1;32m[OK]\e[0m %s\n' "$*" >&2; }
    log_warn()    { printf '\e[1;33m[WARN]\e[0m %s\n' "$*" >&2; }
    log_err()     { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; }
fi

# Tool detection: gum > whiptail > dialog > text
if command -v gum >/dev/null 2>&1; then
    UI_TOOL="gum"
elif command -v whiptail >/dev/null 2>&1; then
    UI_TOOL="whiptail"
elif command -v dialog >/dev/null 2>&1; then
    UI_TOOL="dialog"
else
    UI_TOOL="text"
fi

# Omarchy form status codes (shared with setup-form.sh)
OMARCHY_FORM_OK=0
OMARCHY_FORM_BACK=1
OMARCHY_FORM_SIGNAL=130
OMARCHY_FORM_ABORT=2

# Terminal measurement - gum draws on /dev/tty
SENSIBLE_LOGO_TEXT="Sensible"
# Width of the logo/splash for centering (approx, overridden if logo file exists)
SENSIBLE_LOGO_WIDTH=40

measure_terminal() {
    # Use tput/stty without forcing /dev/tty (which blocks when no TTY)
    if [ -t 0 ] || [ -t 2 ]; then
        TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}')
        TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}')
    else
        TERM_WIDTH=""
        TERM_HEIGHT=""
    fi
    (( TERM_WIDTH > 0 )) || TERM_WIDTH=${COLUMNS:-80}
    (( TERM_HEIGHT > 0 )) || TERM_HEIGHT=${LINES:-24}

    # Try to get real logo width if file exists
    if [ -f "${SENSIBLE_LOGO_PATH:-}" ]; then
        SENSIBLE_LOGO_WIDTH=$(awk '{ if (length > max) max = length } END { print max+0 }' "$SENSIBLE_LOGO_PATH" 2>/dev/null)
        [ "$SENSIBLE_LOGO_WIDTH" -lt 20 ] && SENSIBLE_LOGO_WIDTH=40
    elif [ -f /usr/share/sensible/logo.txt ]; then
        SENSIBLE_LOGO_WIDTH=$(awk '{ if (length > max) max = length } END { print max+0 }' /usr/share/sensible/logo.txt 2>/dev/null)
        [ "$SENSIBLE_LOGO_WIDTH" -lt 20 ] && SENSIBLE_LOGO_WIDTH=40
    fi

    PADDING_LEFT=$(((TERM_WIDTH - SENSIBLE_LOGO_WIDTH) / 2))
    (( PADDING_LEFT < 0 )) && PADDING_LEFT=0
    PADDING_LEFT_SPACES=$(printf "%*s" "$PADDING_LEFT" "")

    PADDING="0 0 0 $PADDING_LEFT"
    export GUM_CHOOSE_PADDING="$PADDING"
    export GUM_FILTER_PADDING="$PADDING"
    export GUM_INPUT_PADDING="$PADDING"
    export GUM_SPIN_PADDING="$PADDING"
    export GUM_TABLE_PADDING="$PADDING"
    export GUM_CONFIRM_PADDING="$PADDING"
}
measure_terminal

# Wait for terminal to settle (framebuffer/KMS late in VMs)
wait_for_stable_terminal() {
    local width last="" stable=0 waited=0
    while (( waited < 5000 )); do
        if [ -t 0 ] || [ -t 2 ]; then
            width=$(stty size 2>/dev/null | awk '{print $2}')
        else
            width=$TERM_WIDTH
        fi
        [[ $width =~ ^[0-9]+$ ]] || width=0
        if [[ $width == "$last" ]] && (( width >= SENSIBLE_LOGO_WIDTH )); then
            (( ++stable >= 3 )) && break
        else
            stable=0
        fi
        last=$width
        sleep 0.2
        (( waited += 200 ))
    done
}

# Gum color theme (subtle, matches Sensible branding)
export GUM_CONFIRM_PROMPT_FOREGROUND="6"
export GUM_CONFIRM_SELECTED_FOREGROUND="0"
export GUM_CONFIRM_SELECTED_BACKGROUND="2"
export GUM_CONFIRM_UNSELECTED_FOREGROUND="7"
export GUM_CONFIRM_UNSELECTED_BACKGROUND="0"

clear_logo() {
    measure_terminal
    # Only clear and use gum when we have a real TTY; tests pipe input
    if _ui_use_gum; then
        printf "\033[H\033[2J"
        if [ -n "${SENSIBLE_LOGO_PATH:-}" ] && [ -f "$SENSIBLE_LOGO_PATH" ]; then
            gum style --foreground 2 --padding "1 0 0 $PADDING_LEFT" "$(<"$SENSIBLE_LOGO_PATH")" 2>/dev/tty || true
        elif [ -f /usr/share/sensible/logo.txt ]; then
            gum style --foreground 2 --padding "1 0 0 $PADDING_LEFT" "$(</usr/share/sensible/logo.txt)" 2>/dev/tty || true
        else
            gum style --foreground 2 --padding "1 0 0 $PADDING_LEFT" --bold "Sensible" --foreground 7 "  (aka Lazydeb)" 2>/dev/tty || true
        fi
    else
        # Text/whiptail mode: simple header
        if [ -t 2 ]; then
            printf "%sSensible (aka Lazydeb) — Debian Testing\n" "$PADDING_LEFT_SPACES" >&2
        fi
    fi
}

# Vertically centered greeter (static, no animation - animation optional)
greeter() {
    measure_terminal
    local rows logo_h content_h top cols
    cols=$TERM_WIDTH
    rows=$(stty size 2>/dev/null </dev/tty | awk '{print $1}')
    [[ $rows =~ ^[0-9]+$ ]] || rows=${LINES:-24}

    if [ -f "${SENSIBLE_LOGO_PATH:-}" ]; then
        logo_h=$(wc -l <"$SENSIBLE_LOGO_PATH")
    elif [ -f /usr/share/sensible/logo.txt ]; then
        logo_h=$(wc -l </usr/share/sensible/logo.txt)
    else
        logo_h=2
    fi

    content_h=$((logo_h + 4))
    top=$(((rows - content_h) / 2))
    (( top < 0 )) && top=0

    printf '\033[?25l\033[H\033[2J'
    clear_logo
    echo
    local tagline="A clean Debian Testing desktop — installer wipes one disk, nothing else"
    local tpad=$(((cols - ${#tagline}) / 2)); (( tpad < 0 )) && tpad=0
    printf "%*s%s\n" "$tpad" "" "$tagline"
    echo
    local hint="Press Return to start"
    local hpad=$(((cols - ${#hint}) / 2)); (( hpad < 0 )) && hpad=0
    printf "\033[2m%*s%s\033[0m\n" "$hpad" "" "$hint"

    # Wait for Return (or any key) - non-blocking in tests
    if [ -t 0 ]; then
        IFS= read -r _ </dev/tty || true
    fi
    printf '\033[0m\033[H\033[2J\033[?25h'
}

step() {
    clear_logo
    echo >&2
    if _ui_use_gum; then
        gum style --padding "0 0 0 $PADDING_LEFT" "$1" 2>/dev/tty || printf "%s%s\n" "$PADDING_LEFT_SPACES" "$1" >&2
    else
        printf "%s%s\n" "$PADDING_LEFT_SPACES" "$1" >&2
    fi
    echo >&2
}

say() {
    if _ui_use_gum; then
        gum style --padding "0 0 0 $PADDING_LEFT" "$@" 2>/dev/tty || printf "%s%s\n" "$PADDING_LEFT_SPACES" "$*" >&2
    else
        printf "%s%s\n" "$PADDING_LEFT_SPACES" "$*" >&2
    fi
}

notice() {
    clear_logo
    echo >&2
    if _ui_use_gum; then
        gum spin --spinner "pulse" --title "$1" -- sleep "${2:-2}" 2>/dev/tty || { say "$1"; sleep "${2:-2}"; }
    else
        say "$1"
        sleep "${2:-2}"
    fi
    echo >&2
}

# ── Legacy whiptail-compatible wrappers (now gum-first) ──

# Detect if running under test (no TTY) - fall back to text
_ui_use_gum() {
    [ "${UI_TOOL:-}" = "gum" ] && [ -t 0 ] 2>/dev/null && [ -t 2 ] 2>/dev/null
}

ui_msgbox() {
    local title="$1" text="$2"
    # Callers pass \n escapes (they are whiptail's native form). gum and the
    # text fallback print them literally, so expand once for everyone —
    # whiptail handles real newlines identically.
    text=$(printf '%b' "$text")
    if _ui_use_gum; then
        clear_logo
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" "$text"
        echo
        if [ -t 0 ]; then
            gum style --padding "0 0 0 $PADDING_LEFT" --foreground 8 "Press Return to continue"
            read -r _ </dev/tty || true
        fi
    elif [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local gh gw
        # fallback geometry for whiptail
        gh=20; gw=70
        "$UI_TOOL" --title "$title" --msgbox "$text" "$gh" "$gw"
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        if [ -t 0 ]; then
            read -rp "Press Enter to continue..." _
        fi
    fi
}

ui_yesno() {
    local title="$1" text="$2" default="${3:-yes}"
    if _ui_use_gum; then
        clear_logo
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" "$text"
        echo
        local rc
        if [ "$default" = "no" ]; then
            gum confirm --affirmative "Yes" --negative "No" --default=false "Confirm?" 2>/dev/tty
            rc=$?
        else
            gum confirm --affirmative "Yes" --negative "No" "Confirm?" 2>/dev/tty
            rc=$?
        fi
        # Gum: 0=yes, 1=no, 130=ctrl-c, 255=esc
        [ "$rc" -eq 255 ] && return 1
        return $rc
    elif [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local extra_flag="" rc
        [ "$default" = "no" ] && extra_flag="--defaultno"
        while true; do
            # shellcheck disable=SC2086
            $UI_TOOL --title "$title" $extra_flag --yesno "$text" 20 70
            rc=$?
            [ "$rc" -eq 255 ] && continue
            return $rc
        done
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        while true; do
            read -rp "[y/n] (default: $default): " ans
            ans="${ans:-$default}"
            case "$ans" in [Yy]*) return 0;; [Nn]*) return 1;; *) echo "Please answer y or n." >&2;; esac
        done
    fi
}

ui_inputbox() {
    local title="$1" text="$2" init_val="${3:-}"
    if _ui_use_gum; then
        clear_logo
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" "$text"
        echo
        local res
        res=$(gum input --placeholder "$init_val" --value "$init_val" --width 50 2>/dev/tty) || res="$init_val"
        echo "$res"
    elif [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
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
    local title="$1" text="$2"
    if _ui_use_gum; then
        clear_logo
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" "$text"
        echo
        local res
        res=$(gum input --password --placeholder "Enter password" 2>/dev/tty) || res=""
        echo "$res"
    elif [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
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
    local title="$1" text="$2"
    shift 2
    local items=("$@")
    if _ui_use_gum; then
        clear_logo
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" "$text"
        echo
        # Gum choose expects one item per line; our items are "key" "desc" pairs
        local display=() keys=()
        local i
        for ((i=0; i<${#items[@]}; i+=2)); do
            display+=("${items[i]} — ${items[i+1]}")
            keys+=("${items[i]}")
        done
        local chosen
        chosen=$(printf '%s\n' "${display[@]}" | gum choose --header "" 2>/dev/tty) || return 1
        # Map back to key
        for ((i=0; i<${#display[@]}; i++)); do
            if [ "${display[i]}" = "$chosen" ]; then
                echo "${keys[i]}"
                return 0
            fi
        done
        # Fallback: extract first word
        echo "$chosen" | awk '{print $1}'
    elif [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
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
    local title="$1" text="$2"
    shift 2
    local items=("$@")
    if _ui_use_gum; then
        clear_logo
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        echo
        gum style --padding "0 0 0 $PADDING_LEFT" "$text"
        echo
        local display=() keys=()
        local i
        for ((i=0; i<${#items[@]}; i+=3)); do
            display+=("${items[i]} — ${items[i+1]}")
            keys+=("${items[i]}")
        done
        local chosen
        chosen=$(printf '%s\n' "${display[@]}" | gum choose --no-limit --header "" 2>/dev/tty) || echo ""
        # Map selected display lines back to keys
        local result=""
        while IFS= read -r line; do
            for ((i=0; i<${#display[@]}; i++)); do
                if [ "${display[i]}" = "$line" ]; then
                    result+="${keys[i]} "
                fi
            done
        done <<< "$chosen"
        echo "$result" | sed 's/ *$//'
    elif [ "$UI_TOOL" = "whiptail" ] || [ "$UI_TOOL" = "dialog" ]; then
        local res
        res=$("$UI_TOOL" --title "$title" --checklist "$text" 16 70 5 "${items[@]}" 3>&1 1>&2 2>&3)
        echo "$res"
    else
        echo "=== $title ===" >&2
        echo "$text" >&2
        echo "Selected items (space separated tags):" >&2
        read -rp "> " res
        echo "$res"
    fi
}

# Gum-aware confirm with hidden Ctrl-C toggle helper
# Usage: gum_confirm_with_toggle "title" "text" "affirmative" "negative" "hint"
# Returns: 0=yes, 1=no, 130=toggle
gum_confirm_with_toggle() {
    local title="$1" text="$2" affirmative="$3" negative="$4" hint="$5"
    clear_logo
    echo
    [ -n "$title" ] && gum style --padding "0 0 0 $PADDING_LEFT" --bold "$title" && echo
    gum style --padding "0 0 0 $PADDING_LEFT" "$text"
    if [ -n "$hint" ]; then
        gum style --padding "0 0 0 $PADDING_LEFT" --foreground 8 "$hint"
    fi
    echo
    local rc
    gum confirm --affirmative "$affirmative" --negative "$negative" "Confirm?" 2>/dev/tty
    rc=$?
    return $rc
}
