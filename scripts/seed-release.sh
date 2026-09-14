#!/usr/bin/env bash
# Retain one tag's intact ISO outside the CI checkout and seed it in Transmission.
set -euo pipefail

iso="$(realpath "$1")"
tag="$2"
seed_root="${3:-/srv/storage/sensible-releases}"
name="$(basename "$iso")"
[[ "$tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]]
[[ "$name" =~ ^sensible-(gnome|kde)-debian-testing-amd64\.iso$ ]]
variant="${BASH_REMATCH[1]}"
actual="$(cd "$(dirname "$iso")" && sha256sum "$name")"
[[ -s "$iso" && "$(<"$iso.sha256")" == "$actual" ]]

destination="$seed_root/$tag/$variant"
mkdir -p "$destination"
destination="$(realpath "$destination")"
if [[ -e "$destination/$name" ]]; then
    # A tag's published bytes must never change, including on a CI rerun.
    [[ "$(cd "$destination" && sha256sum "$name")" == "$actual" ]] || {
        echo "Refusing to replace different ISO bytes for $tag/$variant" >&2
        exit 1
    }
else
    temporary="$(mktemp "$destination/.iso.XXXXXX")"
    trap 'rm -f "$temporary"' EXIT
    cp --reflink=auto "$iso" "$temporary"
    [[ "$(sha256sum "$temporary" | cut -d ' ' -f1)" == "${actual%% *}" ]]
    chmod 644 "$temporary"
    mv "$temporary" "$destination/$name"
    trap - EXIT
fi
printf '%s\n' "$actual" > "$destination/$name.sha256"
torrent="$destination/$name.torrent"
if [[ ! -s "$torrent" ]]; then
    transmission-create --anonymize --piecesize 2048 \
        --tracker udp://tracker.opentrackr.org:1337/announce \
        --comment "Sensible $tag ($variant): https://github.com/korq-apps/sensible/releases/tag/$tag" \
        --outfile "$torrent" "$destination/$name"
fi
magnet="$(transmission-show --magnet "$torrent")"
hash="$(grep -oE 'btih:[[:xdigit:]]{40}' <<< "$magnet" | cut -d: -f2)"
[[ "$hash" =~ ^[[:xdigit:]]{40}$ ]]
printf '%s\n' "$magnet" > "$destination/$name.magnet.txt"

# Apply limits only to this release torrent; preserve the daemon's global policy.
transmission-remote --download-dir "$destination" --add "$torrent"
transmission-remote --torrent "$hash" --no-seedratio --no-idle-seeding-limit --verify
transmission-remote --torrent "$hash" --start
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    status="$(transmission-remote --json --torrent "$hash" --info)"
    if python3 -c '
import json, sys
data = json.load(sys.stdin)
torrents = data.get("arguments", {}).get("torrents", [])
sys.exit(0 if data.get("result") == "success" and len(torrents) == 1
         and torrents[0].get("totalSize", 0) > 0
         and torrents[0].get("haveValid") == torrents[0].get("totalSize")
         and torrents[0].get("haveUnchecked") == 0
         and torrents[0].get("leftUntilDone") == 0
         and torrents[0].get("status") == 6
         and torrents[0].get("error") == 0 else 1)
' <<< "$status"; then
        cp "$torrent" "$iso.torrent"
        cp "$destination/$name.magnet.txt" "$iso.magnet.txt"
        echo "Seeding verified ISO: $tag/$variant ($hash)"
        exit 0
    fi
    sleep 5
done
echo "Transmission did not reach complete, error-free seeding for $tag/$variant" >&2
exit 1
