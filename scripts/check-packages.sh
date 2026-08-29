#!/usr/bin/env bash
# Resolve every package name the project asks for against Debian Testing, and
# fail if any of them is missing.
#
# This exists because vdpau-driver-all was removed from Testing and the
# installer only found out at install time, on the user's machine, after the
# disk had been wiped -- apt exited 100 and took the whole hardware stage with
# it. Testing renames and drops packages continuously, so the only safe place
# to learn a name is gone is here, on our machine, before an ISO ships.
#
# Checks both sources of names:
#   - the live image's package lists (what goes into the ISO)
#   - the package names the installer passes to apt-get (until the offline
#     rework removes that path entirely)
#
# Usage:  scripts/check-packages.sh [variant]
#   variant   gnome (default) or kde
#
# Exit 0 = every name resolves; 1 = at least one does not.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VARIANT="${1:-${SENSIBLE_VARIANT:-gnome}}"

case "${VARIANT}" in
    gnome|kde) ;;
    *) echo "Error: unknown variant '${VARIANT}' (expected gnome or kde)." >&2; exit 1 ;;
esac

# Names that are deliberately not in Debian. Each needs a reason, so this
# cannot quietly become a dumping ground for typos.
#   brave-browser  installed from Brave's own origin, never from Debian
declare -A KNOWN_ABSENT=(
    [brave-browser]="installed from Brave's own apt origin, not packaged by Debian"
)

collect_names() {
    # Live image lists: plain package names, one per line, # comments.
    local list
    for list in "${REPO_ROOT}"/live/config/package-lists/*.list.chroot \
                "${REPO_ROOT}/live/variants/${VARIANT}.list"; do
        [ -f "${list}" ] || continue
        sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' "${list}"
    done

    # Installer: names inside pkgs=( ... ) arrays and on apt-get install lines.
    python3 - "${REPO_ROOT}" <<'PY'
import re, sys, glob, os
root = sys.argv[1]
names = set()
files = glob.glob(os.path.join(root, 'installer/lib/*.sh'))
files.append(os.path.join(root, 'installer/sensible-install.sh'))
for f in files:
    try:
        s = open(f).read()
    except OSError:
        continue
    for m in re.finditer(r'pkgs\+?=\(\s*(.*?)\)', s, re.S):
        # Strip comments first: these arrays carry explanatory comments, and
        # their prose is otherwise indistinguishable from package names.
        body = re.sub(r'#[^\n]*', '', m.group(1))
        for tok in body.split():
            tok = tok.strip('"\'')
            if re.fullmatch(r'[a-z0-9][a-z0-9.+-]{1,}', tok):
                names.add(tok)
    for m in re.finditer(r'apt-get install -y(?: --no-install-recommends)? ([a-z0-9 .+-]+)', s):
        for tok in m.group(1).split():
            if re.fullmatch(r'[a-z0-9][a-z0-9.+-]{1,}', tok):
                names.add(tok)
print('\n'.join(sorted(names)))
PY
}

NAMES="$(collect_names | sort -u | grep -v '^$')"
COUNT="$(printf '%s\n' "${NAMES}" | grep -c .)"
echo "==> Checking ${COUNT} package names for variant '${VARIANT}' against Debian Testing"

# Drop the documented exceptions before querying.
TO_CHECK=""
for name in ${NAMES}; do
    if [ -n "${KNOWN_ABSENT[${name}]:-}" ]; then
        echo "    skipping ${name} (${KNOWN_ABSENT[${name}]})"
        continue
    fi
    TO_CHECK+="${name}"$'\n'
done

if command -v podman >/dev/null 2>&1; then
    ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
    ENGINE="docker"
else
    echo "Error: neither podman nor docker found; cannot query the archive." >&2
    exit 1
fi

LIST_FILE="$(mktemp)"
trap 'rm -f "${LIST_FILE}"' EXIT
printf '%s' "${TO_CHECK}" > "${LIST_FILE}"

# apt-cache show is enough: it answers "does this name exist in the archive",
# which is exactly the failure being prevented, without solving dependencies.
MISSING="$(${ENGINE} run --rm -v "${LIST_FILE}:/names.txt:ro" debian:testing-slim bash -c '
    sed -i "s/^Components:.*/Components: main contrib non-free non-free-firmware/" \
        /etc/apt/sources.list.d/debian.sources 2>/dev/null
    apt-get update -qq >/dev/null 2>&1
    while read -r p; do
        [ -z "$p" ] && continue
        apt-cache show "$p" >/dev/null 2>&1 || echo "$p"
    done < /names.txt
' 2>/dev/null)"

if [ -n "${MISSING}" ]; then
    echo
    echo "The following packages do not exist in Debian Testing:" >&2
    printf '  %s\n' ${MISSING} >&2
    echo >&2
    echo "Fix the name, drop it, or -- if it is deliberately not a Debian package --" >&2
    echo "add it to KNOWN_ABSENT in $(basename "${BASH_SOURCE[0]}") with a reason." >&2
    exit 1
fi

echo "==> All package names resolve."
