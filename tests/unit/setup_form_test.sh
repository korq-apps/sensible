#!/usr/bin/env bash
TEST_NAME="setup_form_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/ui.sh"
source "${INSTALLER_DIR}/lib/setup-form.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

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
