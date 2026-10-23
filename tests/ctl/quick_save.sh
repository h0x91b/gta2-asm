#!/bin/sh
# tests/ctl/quick_save.sh — the game's files end to end (host/c/vfs.c, host/c/files.c): start
# Downtown with a fresh, isolated overlay (HOME=OUT_DIR/home), quick save from the K menu
# (its first row), quit; then check that game files came from the pak, that the save and the
# CRT logs landed in the overlay, and that data.pak was not touched.
#
#   tests/ctl/quick_save.sh [OUT_DIR]      default: $TMPDIR/gta2ctl-quick-save-<pid>
#
# Needs a built tree (host/build.sh). OUT_DIR gets game.log and home/ (the overlay under
# home/Library/Application Support/gta2-resurrected/). Exit 0 = all checks passed.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-quick-save-$$}
rm -rf "$OUT/home"
mkdir -p "$OUT/home"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
OVL="$OUT/home/Library/Application Support/gta2-resurrected"
export GTA2_CTL="${TMP%/}/gta2ctl-quick-save-$$.sock"
# the loader's default SDL3 path is under $HOME, which this test replaces
export GTA2_SDL3_LIB="${GTA2_SDL3_LIB:-$HOME/.local/opt/sdl3-x86_64/lib/libSDL3.0.dylib}"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }

pak_before=$(stat -f '%m %z' "$ROOT/data.pak")
(cd "$ROOT/host" && HOME="$OUT/home" exec arch -x86_64 ./loader ../data.pak --entry \
    --ctl="$GTA2_CTL" --keys=150:RETURN,250:RETURN) > "$OUT/game.log" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
}
check() {                                   # check DESCRIPTION COMMAND...
    d=$1; shift
    if "$@"; then echo "ok: $d"; else echo "FAIL: $d"; exit 1; fi
}

step --wait-sock=60 ping
step wait in_game == 1 1200
step wait frame '>=' 260                    # past the last --keys RETURN
step wait frames 30
step key K                                  # the K menu opens on its first row, Quick save
step wait frames 10
step key RETURN
step wait frames 10
step key K
step wait frames 30
step quit
wait $GAME || true
trap - EXIT

check "the quick save ran" grep -q '^menu: quick save' "$OUT/game.log"
check "the pak was indexed" grep -q '^pak: .*entries, all Stored' "$OUT/game.log"
check "the registry seed came from the pak" grep -q '\[vfs\] gta2_install.reg -> pak' "$OUT/game.log"
check "game text was read from the pak" grep -q '\[vfs\] CreateFileA(data\\e.gxt) -> pak data/e.gxt' "$OUT/game.log"
check "the save was written to the overlay" \
    grep -q '\[w32\] CreateFileA(player\\plyslot0.svg) -> overlay player/plyslot0.svg' "$OUT/game.log"
check "the save file is in the overlay" test -s "$OVL/player/plyslot0.svg"
check "the CRT's error log is in the overlay" test -f "$OVL/test/error.log"
check "data.pak is untouched" test "$(stat -f '%m %z' "$ROOT/data.pak")" = "$pak_before"
echo "PASS — $OUT (game.log, home/)"
