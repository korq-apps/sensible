#!/usr/bin/env bash
TEST_NAME="setup_form_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/ui.sh"
source "${INSTALLER_DIR}/lib/setup-form.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

t_section "validation and live keyboard helpers"
valid_hostname "debian"; assert_rc "simple hostname accepted" 0 $?
valid_hostname "living-room.pc"; assert_rc "dotted hostname accepted" 0 $?
valid_hostname "-bad"; assert_rc "leading hyphen rejected" 1 $?
valid_hostname "bad_name"; assert_rc "underscore rejected" 1 $?
valid_hostname "$(printf 'a%.0s' {1..64})"; assert_rc "Linux-overlong hostname rejected" 1 $?
valid_username "root"; assert_rc "existing system account rejected" 1 $?
valid_username "sddm"; assert_rc "future desktop service account rejected" 1 $?
valid_username "speech-dispatcher"; assert_rc "future accessibility service account rejected" 1 $?
valid_username "pipewire"; assert_rc "future audio service account rejected" 1 $?
valid_username "Bad Name"; assert_rc "invalid username characters rejected" 1 $?
valid_username "sensible_test_user_9274"; assert_rc "available username accepted" 0 $?
valid_timezone "UTC"; assert_rc "UTC accepted" 0 $?
valid_timezone "Europe/Berlin"; assert_rc "IANA timezone accepted" 0 $?
valid_timezone "../../../etc/passwd"; assert_rc "path traversal rejected" 1 $?
valid_timezone "/etc/passwd"; assert_rc "absolute path rejected" 1 $?

symbols="${fixture}/symbols"
mkdir -p "${symbols}"
touch "${symbols}/us" "${symbols}/de"
validate_keyboard_layout "us" "${symbols}"; assert_rc "installed layout accepted" 0 $?
validate_keyboard_layout "us,de" "${symbols}"; assert_rc "installed layout list accepted" 0 $?
validate_keyboard_layout "missing" "${symbols}"; assert_rc "missing layout rejected" 1 $?
validate_keyboard_layout '../bad' "${symbols}"; assert_rc "path-like layout rejected" 1 $?

keyboard_out="${fixture}/keyboard"
SETUPCON_CALLS=0
setupcon() { SETUPCON_CALLS=$((SETUPCON_CALLS + 1)); return 0; }
apply_live_keyboard "de" "${keyboard_out}"
assert_file_contains "applied keyboard file carries selected layout" "${keyboard_out}" 'XKBLAYOUT="de"'
apply_live_keyboard "us" "${symbols}" >/dev/null 2>&1
assert_rc "keyboard file write failure is returned" 1 $?
assert_eq "setupcon not run after keyboard write failure" "1" "${SETUPCON_CALLS}"

printf 'XKBMODEL="pc105"\nXKBLAYOUT="de"\n' > "${keyboard_out}"
assert_eq "reads XKBLAYOUT" "de" "$(detect_keyboard_layout "${keyboard_out}")"
printf 'XKBLAYOUT=us\nXKBLAYOUT="fr"\n' > "${keyboard_out}"
assert_eq "last XKBLAYOUT wins" "fr" "$(detect_keyboard_layout "${keyboard_out}")"
assert_eq "missing file falls back to us" "us" "$(detect_keyboard_layout "${fixture}/missing")"
assert_eq "file without XKBLAYOUT falls back to us" "us" "$(detect_keyboard_layout /dev/null)"

t_section "keyboard choices come from XKB metadata"
cat > "${fixture}/base.lst" <<'EOF'
! model
  pc105           Generic 105-key PC
! layout
  us              English (US)
  de              German
  fr              French
! variant
  intl            us: English (US, intl.)
EOF
SENSIBLE_XKB_LAYOUTS_FILE="${fixture}/base.lst"
keyboard_options="$(list_keyboard_layout_options)"
assert_contains "keyboard list includes code and readable language" "$keyboard_options" "us         English (US)"
assert_contains "keyboard list includes other installed layouts" "$keyboard_options" "de         German"
assert_not_contains "keyboard variants are not mixed into layouts" "$keyboard_options" "intl"

t_section "timezone choices come from tzdata metadata"
printf '# comment\nDE\t+5230+01322\tEurope/Berlin\tGermany (most areas)\nUS\t+404251-0740023\tAmerica/New_York\tEastern\n' \
    > "${fixture}/zone1970.tab"
SENSIBLE_ZONE_TAB_FILE="${fixture}/zone1970.tab"
timezone_options="$(list_timezone_options)"
assert_contains "UTC is always available" "$timezone_options" "UTC"
assert_contains "timezone is searchable by city" "$timezone_options" "Europe/Berlin"
assert_contains "timezone is searchable by country and description" "$timezone_options" "DE — Germany (most areas)"

t_section "locale choices include human metadata"
mkdir -p "${fixture}/locales"
cat > "${fixture}/SUPPORTED" <<'EOF'
de_DE.UTF-8 UTF-8
de_DE ISO-8859-1
en_US.UTF-8 UTF-8
EOF
cat > "${fixture}/locales/de_DE" <<'EOF'
LC_IDENTIFICATION
language   "German"
territory  "Germany"
END LC_IDENTIFICATION
EOF
cat > "${fixture}/locales/en_US" <<'EOF'
LC_IDENTIFICATION
language   "American English"
territory  "United States"
END LC_IDENTIFICATION
EOF
SENSIBLE_SUPPORTED_LOCALES_FILE="${fixture}/SUPPORTED"
SENSIBLE_LOCALE_SOURCE_DIR="${fixture}/locales"
locale_options="$(list_locale_options)"
assert_contains "locale includes stable code" "$locale_options" "en_US.UTF-8"
assert_contains "locale can be found by language" "$locale_options" "American English"
assert_contains "locale can be found by territory" "$locale_options" "Germany"
assert_not_contains "non-UTF-8 locale is omitted" "$locale_options" "ISO-8859-1"

t_section "current value is the first searchable choice"
ordered="$(printf '%s\n' "$keyboard_options" | _options_with_default_first de)"
assert_contains "default layout moves to top" "$(printf '%s\n' "$ordered" | head -n 1)" "de"

t_section "text fallback remains scriptable"
UI_TOOL=text
validate_fixture_choice() { [ "$1" = "de" ]; }
printf 'de\n' | _prompt_searchable "Keyboard" "Search" "us" \
    "list_keyboard_layout_options" "validate_fixture_choice" "Invalid" "Enter layout:" >/dev/null 2>&1
assert_rc "text fallback accepts the same stable value" 0 $?

t_summary
