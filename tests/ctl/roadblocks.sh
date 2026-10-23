#!/bin/sh
# tests/ctl/roadblocks.sh — the K menu's persistent police roadblocks end to end
# (host/c32/roadblocks.c, docs/re/gangs-and-peds.md section 7) with gta2ctl: place one on
# foot, one from a car (ahead along the road), drive into it, remove both, then place one
# and quit to the frontend and replay: the new level starts with none.
#
#   tests/ctl/roadblocks.sh [OUT_DIR]     default: $TMPDIR/gta2ctl-roadblocks-<pid>
#
# Needs a built tree (host/build.sh) and jq. The K menu is driven with keys (HOME + DOWN n
# picks a row), so it depends on the row order of the root and Player pages.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-roadblocks-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-roadblocks-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }
LOG="$OUT/game.log"

step() {
    printf '$ gta2ctl %s\n' "$*"
    r=$("$CTL" "$@") || { rc=$?; echo "$r"; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
    echo "$r"
}
field() { "$CTL" state | jq -r ".$1"; }
key() {         # key NAME [N]: N taps, a few frames apart
    i=0
    while [ $i -lt "${2:-1}" ]; do
        "$CTL" key "$1" 2 >/dev/null && "$CTL" wait frames 4 >/dev/null
        i=$((i + 1))
    done
}
player_row() {  # player_row N SHOT: K, root row 7 (Player...), row N of the Player page, RETURN, K
    key K; key HOME; key DOWN 7; key RETURN
    key HOME; key DOWN "$1"; key RETURN
    "$CTL" wait frames 6 >/dev/null
    step shot "$OUT/$2.bmp" >/dev/null
    key BACK; key K                 # back to the root: the menu reopens on the last page
}
count() { grep -c "$1" "$LOG" || true; }
expect_count() {    # expect_count PATTERN N
    n=$(count "$1")
    [ "$n" = "$2" ] || { echo "FAIL: '$1' $n times in the log, expected $2"; exit 1; }
    echo "ok: '$1' x$n: $(grep "$1" "$LOG" | tail -1)"
}

(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --window=640x480 --keys=150:RETURN,250:RETURN) > "$LOG" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step --wait-sock=60 ping >/dev/null
step wait in_game == 1 1200
step wait frame '>=' 260
step wait frames 30

# ---- 1. on foot, facing down the road --------------------------------------------------
step teleport 167 133
step face 0
step wait frames 250                # the camera pans after a teleport
player_row 4 1-place-on-foot
expect_count 'menu: roadblock at tile' 1
step wait frames 30
step shot "$OUT/2-roadblock-on-foot.bmp"

# ---- 2. from a car, ahead along the road, then drive into it ---------------------------
step teleport 169.5 150
step wait frames 200
r=$("$CTL" spawn car 13 --at=169.5,151.5 --rot=180) || { echo "FAIL: spawn: $r"; exit 1; }; echo "$r"
id=$(echo "$r" | jq -r .id)
step enter_car "$id"
step wait in_car == 1 300
step wait frames 30
player_row 4 3-place-from-car
expect_count 'menu: roadblock at tile' 2
y0=$(field y)
step keydown UP
step wait frames 150
step keyup UP
step wait frames 30
y1=$(field y)
echo "drove from y $y0 to y $y1 ($(grep 'menu: roadblock at tile' "$LOG" | tail -1))"
step shot "$OUT/4-drove-into-it.bmp"

# ---- 3. remove both ----------------------------------------------------------------------
player_row 5 5-remove
expect_count 'menu: removed 2 roadblocks' 1
step wait frames 30
step shot "$OUT/6-removed.bmp"
step exit_car

# ---- 4. place one, quit to the frontend, replay: the new level has none ------------------
player_row 4 7-place-before-quit
expect_count 'menu: roadblock at tile' 3
key ESCAPE; key RETURN              # quit confirm, Enter quits
step wait in_game == 0 600
step wait frames 60
step shot "$OUT/8-frontend.bmp"
key DOWN; key RETURN                # "player quit" page: REPLAY PREVIOUS AREA
step wait in_game == 1 1200
step wait frames 60
player_row 5 9-remove-after-replay
expect_count 'menu: removed 0 roadblocks' 1
step quit >/dev/null
wait $GAME || true
trap - EXIT
grep -E 'menu: (roadblock|removed|no road)|c32: roadblock' "$LOG" | sed 's/^/  /'
echo "PASS — $OUT"
