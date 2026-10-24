#!/bin/sh
# tests/ctl/map.sh — the radar and the M map (docs/map.md) end to end with gta2ctl: Downtown
# from an empty explored map, the radar on foot facing two ways, the M map before exploring,
# a drive east, the radar while driving, the M map after it, then a restart of the level to
# check that the explored map was saved and comes back.
#
#   tests/ctl/map.sh [OUT_DIR]       default: $TMPDIR/gta2ctl-map-<pid>
#
# The game runs with HOME=OUT_DIR/home, so its overlay (and maps/wil.fog in it) is a fresh
# one and the player's own explored map is never touched. Needs a built tree (host/build.sh).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-map-$$}
mkdir -p "$OUT/home"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-map-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }
SDL=${GTA2_SDL3_LIB:-$HOME/.local/opt/sdl3-x86_64/lib/libSDL3.0.dylib}   # found from HOME otherwise
FOG="$OUT/home/Library/Application Support/gta2-resurrected/maps/wil.fog"
rm -f "$FOG"

start() {
    (cd "$ROOT/host" && HOME="$OUT/home" GTA2_SDL3_LIB="$SDL" exec arch -x86_64 ./loader ../data.pak --entry \
        --ctl="$GTA2_CTL" --keys=150:RETURN,250:RETURN) > "$OUT/game$1.log" 2>&1 &
    GAME=$!
    trap 'kill $GAME 2>/dev/null || true' EXIT
    step --wait-sock=60 ping
    step wait in_game == 1 1200
    step wait frame '>=' 260
    step wait frames 30
}

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
}

start 1
step face 0
step wait frames 20
step shot "$OUT/radar-foot-h0.bmp"
step face 90
step wait frames 20
step shot "$OUT/radar-foot-h90.bmp"
step key M
step wait frames 10
step wait paused == true 30
step shot "$OUT/map-before.bmp"
step key M
step wait paused == false 30
step teleport 132 195                       # next to a parked car (smoke.sh)
step wait frames 5
step enter_car nearest
step wait in_car == 1 30
step wait frames 30
step keydown UP
step wait frames 90
step shot "$OUT/radar-driving.bmp"
step wait frames 150
step keyup UP
step wait frames 30
step key M
step wait frames 10
step shot "$OUT/map-after.bmp"
step key M
step wait frames 10
step quit
wait $GAME || true
trap - EXIT
[ -s "$FOG" ] || { echo "FAIL: no $FOG after the run"; exit 1; }
echo "explored map saved: $(wc -c < "$FOG") bytes"

start 2                                     # the same level again: the fog comes back
grep -q "map: level wil, explored tiles [1-9]" "$OUT/game2.log" ||
    { echo "FAIL: the explored map did not load on restart"; exit 1; }
step key M
step wait frames 10
step shot "$OUT/map-restart.bmp"
step quit
wait $GAME || true
trap - EXIT
grep "^map:" "$OUT/game1.log" "$OUT/game2.log"
echo "PASS — $OUT (game1.log, game2.log, radar-*.bmp, map-*.bmp)"
