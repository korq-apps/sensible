#!/usr/bin/env bash
# Unit tests for installer/lib/apps.sh — default app set, LazyVim skel,
# Flatpak, baked LazyVim defaults, optional apps and Brave origin.
TEST_NAME="apps_test"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/apps.sh"

TMP_MNT="$(mktemp -d)"
MNT="${TMP_MNT}"
mkdir -p "${MNT}/etc/apt" "${MNT}/home/alice"
mkdir -p "${MNT}/etc/skel/.config/nvim"
echo "vim.cmd.colorscheme habamax" > "${MNT}/etc/skel/.config/nvim/init.lua"

chroot() { mlog "chroot $*"; }
git() {
    mlog "git $*"
    if [ "$1" = "clone" ]; then
        local target="${@: -1}"
        mkdir -p "${target}"
        echo "vim.cmd.colorscheme habamax" > "${target}/init.lua"
    fi
}
curl()   { mlog "curl $*"; touch "$2"; }

t_section "Default apps: canonical package list (Architecture §7)"
mock_setup
install_default_apps "alice"
apt_line="$(mock_last_call 'apt-get install -y --no-install-recommends')"
for pkg in firefox-esr chromium vlc neovim libreoffice-writer libreoffice-calc libreoffice-impress thunderbird keepassxc 7zip unzip zip ripgrep fd-find fzf bat eza zoxide btop fastfetch jq sudo curl git ca-certificates flatpak fonts-noto-core fonts-noto-color-emoji fonts-liberation; do
    if [[ " ${apt_line} " == *" ${pkg} "* ]]; then t_ok; else t_fail "package ${pkg} in apt install call" "line: ${apt_line}"; fi
done
calls="$(cat "${MOCK_LOG}")"
assert_not_contains "Flathub setup stays out of the installer" "${calls}" "flatpak remote-add"
assert_not_contains "LazyVim starter is not cloned during install" "${calls}" "git clone"
assert_file_exists "skel nvim config" "${MNT}/etc/skel/.config/nvim/init.lua"
assert_file_exists "copied to created user" "${MNT}/home/alice/.config/nvim/init.lua"
assert_contains "ownership fixed via chroot" "${calls}" "chown -R alice:alice /home/alice/.config"
assert_not_contains "no Slack" "${calls}" "slack"
assert_not_contains "no Zoom" "${calls}" "zoom"
assert_not_contains "no Steam" "${calls}" "steam"
assert_not_contains "no Snapd" "${calls}" "snapd"
mock_teardown

t_section "Optional apps: brave from official apt origin only"
mock_setup
install_optional_apps 'brave'
calls="$(cat "${MOCK_LOG}")"
assert_contains "keyring downloaded" "${calls}" "curl -fsSLo ${MNT}/usr/share/keyrings/brave-browser-archive-keyring.gpg"
assert_file_contains "sources.list.d entry signed by keyring" \
    "${MNT}/etc/apt/sources.list.d/brave-browser-release.list" \
    "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main"
assert_contains "installs brave-browser" "${calls}" "apt-get install -y brave-browser"
assert_not_contains "no chromium" "${calls}" "chromium"
mock_teardown

t_section "Optional apps: quoted checklist output matches (whiptail format)"
mock_setup
install_optional_apps '"chromium" "audacious"'
calls="$(cat "${MOCK_LOG}")"
assert_contains "chromium installed" "${calls}" "apt-get install -y chromium"
assert_contains "audacious installed" "${calls}" "apt-get install -y audacious"
mock_teardown

t_section "Optional apps: media player per DE tag"
mock_setup
install_optional_apps "amberol"
mock_has_call "apt-get install -y amberol" && t_ok || t_fail "amberol installed" "missing"
assert_not_contains "no elisa" "$(cat "${MOCK_LOG}")" "elisa"
mock_reset
install_optional_apps "elisa"
mock_has_call "apt-get install -y elisa" && t_ok || t_fail "elisa installed" "missing"
assert_not_contains "no amberol" "$(cat "${MOCK_LOG}")" "amberol"
mock_teardown

t_section "Optional apps: empty selection is a no-op"
mock_setup
install_optional_apps ""
assert_not_contains "nothing installed" "$(cat "${MOCK_LOG}")" "apt-get install"
mock_teardown

rm -rf "${TMP_MNT}"
t_summary
