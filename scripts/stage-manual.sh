#!/usr/bin/env bash
# Shared by both ISO build entry points; all manual assets stay offline.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-${REPO_ROOT}/live/config/includes.chroot}"

for asset in index.html applications.html terminal-tools.html manual.css; do
    install -Dm0644 "${REPO_ROOT}/manual/${asset}" "${DEST}/usr/share/sensible/manual/${asset}"
done
install -Dm0644 "${REPO_ROOT}/packaging/manual/sensible-manual-autostart.desktop" \
    "${DEST}/usr/share/sensible/manual/sensible-manual-autostart.desktop"
install -Dm0644 "${REPO_ROOT}/packaging/manual/sensible-manual.desktop" \
    "${DEST}/usr/share/applications/sensible-manual.desktop"
install -Dm0755 "${REPO_ROOT}/packaging/manual/sensible-manual" \
    "${DEST}/usr/local/bin/sensible-manual"
