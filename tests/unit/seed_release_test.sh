#!/usr/bin/env bash
TEST_NAME=seed_release_test
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
fixture="$(mktemp -d /tmp/sensible-seed-test.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin" "$fixture/source"
export SEED_TEST_LOG="$fixture/rpc.log"
cat > "$fixture/bin/transmission-create" <<'MOCK'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    if [[ $1 == --outfile ]]; then printf 'torrent fixture\n' > "$2"; exit 0; fi
    shift
done
exit 1
MOCK
cat > "$fixture/bin/transmission-show" <<'MOCK'
#!/usr/bin/env bash
printf 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567\n'
MOCK
cat > "$fixture/bin/transmission-remote" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SEED_TEST_LOG"
[[ ${SEED_TEST_RPC_FAIL:-0} == 0 ]] || exit 1
if [[ $1 == --json ]]; then
    printf '%s\n' '{"result":"success","arguments":{"torrents":[{"totalSize":100,"haveValid":100,"haveUnchecked":0,"leftUntilDone":0,"status":6,"error":0}]}}'
fi
MOCK
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
iso="$fixture/source/sensible-gnome-debian-testing-amd64.iso"
printf 'verified ISO bytes\n' > "$iso"
(cd "$fixture/source" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")
script="$REPO_ROOT/scripts/seed-release.sh"

bash "$script" "$iso" v1.0.0-beta.1 "$fixture/seeds" > "$fixture/output" 2>&1
assert_rc "verified complete seed exports metadata" 0 $?
assert_file_exists "torrent exported for release" "$iso.torrent"
assert_file_exists "magnet exported for release" "$iso.magnet.txt"
stored="$fixture/seeds/v1.0.0-beta.1/gnome/$(basename "$iso")"
cmp "$iso" "$stored"
assert_rc "seeded ISO is byte-identical" 0 $?
assert_file_contains "download directory is scoped to the pending torrent add" "$SEED_TEST_LOG" "--add $stored.torrent --download-dir ${stored%/*}"
assert_file_contains "only release torrent gets ratio override" "$SEED_TEST_LOG" '--torrent 0123456789abcdef0123456789abcdef01234567 --no-seedratio --no-idle-seeding-limit --verify'
bash "$script" "$iso" v1.0.0-beta.1 "$fixture/seeds" > "$fixture/output" 2>&1
assert_rc "same bytes may be seeded again" 0 $?

printf 'different ISO bytes\n' > "$iso"
(cd "$fixture/source" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")
bash "$script" "$iso" v1.0.0-beta.1 "$fixture/seeds" > "$fixture/output" 2>&1
assert_rc "cannot replace a tagged ISO" 1 $?
assert_file_contains "original seeded bytes preserved" "$stored" 'verified ISO bytes'

printf 'invalid checksum\n' > "$iso.sha256"
bash "$script" "$iso" v1.0.0-beta.2 "$fixture/seeds" > "$fixture/output" 2>&1
assert_rc "bad source checksum blocks seeding" 1 $?
assert_file_not_exists "bad input leaves no release directory" "$fixture/seeds/v1.0.0-beta.2"
(cd "$fixture/source" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")
rm "$iso.torrent" "$iso.magnet.txt"
SEED_TEST_RPC_FAIL=1 bash "$script" "$iso" v1.0.0-beta.2 "$fixture/seeds" > "$fixture/output" 2>&1
assert_rc "daemon failure blocks publication metadata" 1 $?
assert_file_not_exists "failed seed exports no torrent" "$iso.torrent"
bash "$script" "$iso" ../../escape "$fixture/seeds" > "$fixture/output" 2>&1
assert_rc "tag cannot escape release storage" 1 $?
t_summary
