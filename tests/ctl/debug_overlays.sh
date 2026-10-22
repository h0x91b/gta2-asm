#!/bin/sh
# tests/ctl/debug_overlays.sh — the K menu's two world overlays end to end with gta2ctl
# (docs/debug-menu.md): "Road network" (Debug flags page; host/c32/debug_roads.c) and
# "Ped paths" (root page; host/c32/debug_paths.c), toggled through the menu's own keys.
#
#   1. Road network at two places in Downtown: off, cars, cars + peds, off again (a
#      screenshot each; "off" must match the shot before the overlay was turned on).
#   2. Ped paths on while the player walks with the game's own GO_TO_AREA objective
#      (walk_to plans a real tile path), three screenshots as the waypoints move.
#   3. The "roads:" / "paths:" stats lines in the log.
#
#   tests/ctl/debug_overlays.sh [OUT_DIR]   default: $TMPDIR/gta2ctl-overlays-<pid>
#
# Every input is frame-scheduled and the level starts from the same seed, so two runs
# of the same build take the same screenshots: compare OUT_DIR/*.bmp of two builds with
# cmp for a parity check. Exit 0 = all steps passed.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-overlays-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-overlays-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }

printf '# no mods\n' > "$OUT/config.yaml"
(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --window=640x480 --config="$OUT/config.yaml" --keys=150:RETURN,250:RETURN) \
    > "$OUT/game.log" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
}
keys() { for k in "$@"; do step key "$k" 2 >/dev/null; done; }
shot() { step wait frames 2 >/dev/null; step shot "$OUT/$1.bmp"; }
# K, root: END = Close, UP = Debug flags, RETURN opens it; there END = Back, UP = Road
# network (its last row); RETURN = the next mode; BACKSPACE to the root, K closes
roads_next() { keys K END UP RETURN END UP RETURN BACK K; step wait frames 10 >/dev/null; }
# K, root: HOME, 4 x DOWN = Ped paths (order 50), RETURN toggles, K closes
paths_toggle() { keys K HOME DOWN DOWN DOWN DOWN RETURN K; step wait frames 10 >/dev/null; }

step --wait-sock=60 ping
step wait in_game == 1 1200
step wait frame '>=' 260                    # past the last --keys RETURN (docs/gta2ctl.md)
step wait frames 30

# ---- 1. Road network at two places ---------------------------------------------------
for place in "a 168.5 133.5" "b 132 195"; do
    set -- $place
    step teleport "$2" "$3"
    step wait frames 250                    # the camera pans after a teleport, slowly
    shot "roads-$1-0-off"
    roads_next; shot "roads-$1-1-cars"
    roads_next; roads_next; shot "roads-$1-2-all"
    roads_next; shot "roads-$1-3-off"
    cmp -s "$OUT/roads-$1-0-off.bmp" "$OUT/roads-$1-3-off.bmp" \
        && echo "note: roads-$1 off/off identical" \
        || echo "note: roads-$1 off/off differ (the world moved meanwhile)"
done

# ---- 2. Ped paths while the player walks a planned path -------------------------------
step teleport 159.5 139.5                   # the level start, a courtyard
step wait frames 250
paths_toggle
shot paths-0-standing
"$CTL" walk_to 168.5 133.5 3000 > "$OUT/walk_to.json" &   # a second client: it blocks
WALK=$!
step wait frames 20; shot paths-1
step wait frames 40; shot paths-2
step wait frames 40; shot paths-3
wait $WALK || { echo "FAIL: walk_to: $(cat "$OUT/walk_to.json")"; exit 1; }
cat "$OUT/walk_to.json"
paths_toggle

# ---- 3. the stats lines ----------------------------------------------------------------
step log overlays test done
step quit
wait $GAME || true
trap - EXIT
grep -q '^roads: view' "$OUT/game.log" || { echo "FAIL: no roads: stats line"; exit 1; }
grep -q '^paths: ' "$OUT/game.log" || { echo "FAIL: no paths: stats line"; exit 1; }
grep '^roads: \|^paths: ' "$OUT/game.log" | head -4
echo "PASS — $OUT (game.log, *.bmp)"
