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
# A shared content column keeps the logo, copy, and controls visually related.
# It is clamped on small consoles.
SENSIBLE_LOGO_WIDTH=40
SENSIBLE_CONTENT_WIDTH=72
SENSIBLE_STTY_STATE=""
INSTALL_PROGRESS_STARTED_AT=0
INSTALL_PROGRESS_TOTAL=1

# Gum talks to the controlling terminal directly. Login shells and sudo can
# inherit non-TTY standard descriptors while still having a perfectly usable
# /dev/tty, so probe that device without exposing open errors.
_ui_has_controlling_tty() {
    [ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null
}

# Linux VTs answer cursor-position probes from Gum/Bubble Tea. With ECHOCTL
# enabled, the line discipline visibly echoes those replies as ^[[15;1R.
# Keep normal character echoing, but hide control replies for the installer
# session and restore the original terminal state when it exits.
prepare_terminal() {
    _ui_has_controlling_tty || return 0
    [ -z "$SENSIBLE_STTY_STATE" ] || return 0
    SENSIBLE_STTY_STATE=$(stty -g </dev/tty 2>/dev/null || true)
    stty -echoctl </dev/tty 2>/dev/null || true
}

restore_terminal() {
    [ -n "$SENSIBLE_STTY_STATE" ] || return 0
    stty "$SENSIBLE_STTY_STATE" </dev/tty 2>/dev/null || true
    SENSIBLE_STTY_STATE=""
}

measure_terminal() {
    # sudo/login can leave standard descriptors detached while /dev/tty is
    # still the real interactive console. Measure that console first.
    local tty_size=""
    if _ui_has_controlling_tty; then
        tty_size=$(stty size </dev/tty 2>/dev/null || true)
        TERM_HEIGHT=${tty_size%% *}
        TERM_WIDTH=${tty_size##* }
    elif [ -t 0 ] || [ -t 2 ]; then
        tty_size=$(stty size 2>/dev/null || true)
        TERM_HEIGHT=${tty_size%% *}
        TERM_WIDTH=${tty_size##* }
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

    LAYOUT_WIDTH=$SENSIBLE_CONTENT_WIDTH
    (( LAYOUT_WIDTH < SENSIBLE_LOGO_WIDTH )) && LAYOUT_WIDTH=$SENSIBLE_LOGO_WIDTH
    (( LAYOUT_WIDTH > TERM_WIDTH - 4 )) && LAYOUT_WIDTH=$((TERM_WIDTH - 4))
    (( LAYOUT_WIDTH < 20 )) && LAYOUT_WIDTH=20

    PADDING_LEFT=$(((TERM_WIDTH - LAYOUT_WIDTH) / 2))
    (( PADDING_LEFT < 0 )) && PADDING_LEFT=0
    LOGO_PADDING_LEFT=$((PADDING_LEFT + (LAYOUT_WIDTH - SENSIBLE_LOGO_WIDTH) / 2))
    (( LOGO_PADDING_LEFT < 0 )) && LOGO_PADDING_LEFT=0
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

# Gum color theme (subtle, matches Sensible branding)
export GUM_CONFIRM_PROMPT_FOREGROUND="6"
export GUM_CONFIRM_SELECTED_FOREGROUND="0"
export GUM_CONFIRM_SELECTED_BACKGROUND="2"
export GUM_CONFIRM_UNSELECTED_FOREGROUND="7"
export GUM_CONFIRM_UNSELECTED_BACKGROUND="0"
export GUM_FILTER_INDICATOR_FOREGROUND="2"
export GUM_FILTER_MATCH_FOREGROUND="2"
export GUM_FILTER_PROMPT_FOREGROUND="8"
export GUM_FILTER_PLACEHOLDER_FOREGROUND="8"

# Styling is presentation, never installation control flow. Always render it
# on the console rather than stdout (which may carry a selected value), and do
# not abort the installer if a terminal rejects a cosmetic capability query.
ui_style() {
    gum style "$@" >/dev/tty 2>&1 || true
}

ui_blank() {
    if _ui_has_controlling_tty; then
        printf '\n' >/dev/tty
    else
        printf '\n' >&2
    fi
}

installer_edition_label() {
    case "${DESKTOP_CHOICE:-${SENSIBLE_VARIANT:-gnome}}" in
        kde) printf 'KDE Plasma edition' ;;
        *)   printf 'GNOME edition' ;;
    esac
}

render_logo() {
    local top_padding="${1:-1}" logo=""
    if [ -n "${SENSIBLE_LOGO_PATH:-}" ] && [ -f "$SENSIBLE_LOGO_PATH" ]; then
        logo=$(<"$SENSIBLE_LOGO_PATH")
    elif [ -f /usr/share/sensible/logo.txt ]; then
        logo=$(</usr/share/sensible/logo.txt)
    else
        logo="Sensible"
    fi
    ui_style --foreground 2 --padding "${top_padding} 0 0 $LOGO_PADDING_LEFT" "$logo"
}

centered_style() {
    ui_style --width "$LAYOUT_WIDTH" --align center --padding "0 0 0 $PADDING_LEFT" "$@"
}

clear_logo() {
    measure_terminal
    local edition installer_caption
    edition=$(installer_edition_label)
    installer_caption="Debian Testing  •  ${edition}"
    # Only clear and use gum when we have a real TTY; tests pipe input
    if _ui_use_gum; then
        printf "\033[H\033[2J" >/dev/tty
        render_logo 1
        centered_style --foreground 8 "${installer_caption}" || true
        printf '\n' >/dev/tty
    else
        # Text/whiptail mode: simple header
        if [ -t 2 ]; then
            printf "%sSensible Installer — %s\n" "$PADDING_LEFT_SPACES" "${installer_caption}" >&2
        fi
    fi
}

welcome_screen() {
    _ui_use_gum || return 0

    measure_terminal
    local edition top_padding
    edition=$(installer_edition_label)
    top_padding=$(((TERM_HEIGHT - 18) / 2))
    (( top_padding < 1 )) && top_padding=1

    printf "\033[?25l\033[H\033[2J" >/dev/tty
    render_logo "$top_padding"
    printf '\n' >/dev/tty
    centered_style --bold "Welcome to Sensible" || true
    centered_style --foreground 8 "Debian Testing  •  ${edition}" || true
    printf '\n' >/dev/tty
    printf '\n\n' >/dev/tty
    centered_style --bold --foreground 2 "Press Enter to start" || true

    IFS= read -r _ </dev/tty || true
    printf "\033[?25h\033[H\033[2J" >/dev/tty
}

step() {
    clear_logo
    if _ui_use_gum; then
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" "$1"
        ui_blank
    else
        echo >&2
        printf "%s%s\n" "$PADDING_LEFT_SPACES" "$1" >&2
        echo >&2
    fi
}

say() {
    if _ui_use_gum; then
        ui_style --padding "0 0 0 $PADDING_LEFT" "$@"
    else
        _say_plain "$@"
    fi
}

format_elapsed_time() {
    local elapsed="${1:-0}"
    (( elapsed < 0 )) && elapsed=0
    printf '%dm %02ds\n' "$((elapsed / 60))" "$((elapsed % 60))"
}

install_progress_start() {
    INSTALL_PROGRESS_STARTED_AT=$(date +%s)
    INSTALL_PROGRESS_TOTAL="${1:-1}"
}

install_progress_elapsed() {
    local now
    now=$(date +%s)
    format_elapsed_time "$((now - INSTALL_PROGRESS_STARTED_AT))"
}

install_progress_update() {
    local current="$1" stage="$2"
    [ "${SENSIBLE_DEBUG:-0}" != "1" ] || return 0
    _ui_use_gum || return 0

    local width=34 filled empty percent bar_done bar_left elapsed
    (( INSTALL_PROGRESS_TOTAL > 0 )) || INSTALL_PROGRESS_TOTAL=1
    (( current < 0 )) && current=0
    (( current > INSTALL_PROGRESS_TOTAL )) && current=$INSTALL_PROGRESS_TOTAL
    filled=$((current * width / INSTALL_PROGRESS_TOTAL))
    empty=$((width - filled))
    percent=$((current * 100 / INSTALL_PROGRESS_TOTAL))
    printf -v bar_done '%*s' "$filled" ''
    printf -v bar_left '%*s' "$empty" ''
    bar_done=${bar_done// /#}
    bar_left=${bar_left// /-}
    elapsed=$(install_progress_elapsed)

    clear_logo
    ui_style --padding "0 0 0 $PADDING_LEFT" --bold "Installing Sensible"
    echo >/dev/tty
    ui_style --padding "0 0 0 $PADDING_LEFT" --foreground 2 \
        "[${bar_done}${bar_left}] ${percent}%"
    ui_style --padding "0 0 0 $PADDING_LEFT" "$stage"
    ui_style --padding "0 0 0 $PADDING_LEFT" --foreground 8 "Elapsed: ${elapsed}"
    echo >/dev/tty
    ui_blank
}

# Render Gum-styled messages cleanly when the terminal cannot run Gum. Do not
# expose presentation flags such as "--foreground 8" as installer copy.
_say_plain() {
    local -a words=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --foreground|--background|--border-foreground|--border-background|--align|--width|--height|--margin|--padding)
                shift
                [ "$#" -gt 0 ] && shift
                ;;
            --bold|--faint|--italic|--strikethrough|--underline)
                shift
                ;;
            --)
                shift
                words+=("$@")
                break
                ;;
            *)
                words+=("$1")
                shift
                ;;
        esac
    done
    printf "%s%s\n" "$PADDING_LEFT_SPACES" "${words[*]}" >&2
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

_ui_use_gum() {
    [ "${UI_TOOL:-}" = "gum" ] && _ui_has_controlling_tty
}

ui_msgbox() {
    local title="$1" text="$2"
    # Callers pass \n escapes (they are whiptail's native form). gum and the
    # text fallback print them literally, so expand once for everyone —
    # whiptail handles real newlines identically.
    text=$(printf '%b' "$text")
    if _ui_use_gum; then
        clear_logo
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" "$text"
        ui_blank
        if [ -t 0 ]; then
            ui_style --padding "0 0 0 $PADDING_LEFT" --foreground 8 "Press Return to continue"
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
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" "$text"
        ui_blank
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
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" "$text"
        ui_blank
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
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" "$text"
        ui_blank
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
    text=$(printf '%b' "$text")
    if _ui_use_gum; then
        clear_logo
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" "$text"
        ui_blank
        # Keep the rendered label and returned action separate. Parsing a
        # styled label made the completion menu occasionally return an empty or
        # malformed action and silently fall back to the live shell.
        local options="" keys=()
        local i
        for ((i=0; i<${#items[@]}; i+=2)); do
            keys+=("${items[i]}")
            options+="${items[i]} — ${items[i+1]}"$'\t'"${items[i]}"$'\n'
        done
        local chosen
        chosen=$(printf '%s' "$options" | \
            gum choose --label-delimiter $'\t' --select-if-one --header "" 2>/dev/tty) || return 1
        for ((i=0; i<${#keys[@]}; i++)); do
            if [ "${keys[i]}" = "$chosen" ]; then
                printf '%s\n' "$chosen"
                return 0
            fi
        done
        return 1
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
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" --bold "$title"
        ui_blank
        ui_style --padding "0 0 0 $PADDING_LEFT" "$text"
        ui_blank
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
    ui_blank
    [ -n "$title" ] && { ui_style --padding "0 0 0 $PADDING_LEFT" --bold "$title"; ui_blank; }
    ui_style --padding "0 0 0 $PADDING_LEFT" "$text"
    if [ -n "$hint" ]; then
        ui_style --padding "0 0 0 $PADDING_LEFT" --foreground 8 "$hint"
    fi
    ui_blank
        local rc
    gum confirm --affirmative "$affirmative" --negative "$negative" "Confirm?" 2>/dev/tty
    rc=$?
    return $rc
}
