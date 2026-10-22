#!/bin/sh
# tests/ctl/player_move.sh — on-foot strafe and mouse turning end to end (host/c32/player_move.c,
# docs/re/ped-movement-collision.md §6) with gta2ctl: from Downtown's start (159.5, 139.5),
# facing 0 (+y), strafe left (Q) into the courtyard wall on +x (the wall stops it and the
# walker slides along it), right (E) into the wall on −x (stops dead), forward + left and
# back + left diagonals (heading unchanged: the sprite keeps facing forward), then mouse
# turning with synthetic deltas (`gta2ctl mouse`, in-process: the real cursor never moves).
# A second game with strafe and mouse turning off: Q and the mouse do nothing (= vanilla).
#
#   tests/ctl/player_move.sh [OUT_DIR]      default: $TMPDIR/gta2ctl-player-move-<pid>
#
# Needs a built tree (host/build.sh) and jq. OUT_DIR gets the logs, per-frame telemetry
# (on.jsonl / off.jsonl), the phase markers (in the logs: "ctl: log [frame N] phase ...")
# and screenshots. Mouse turning switches SDL relative mode on while the window has focus.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-player-move-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }

step() {
    printf '$ gta2ctl %s\n' "$*"
    r=$("$CTL" "$@") || { rc=$?; echo "$r"; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
    echo "$r"
}
field() { "$CTL" state | jq -r ".$1"; }
check() {       # check "jq-expr over $a/$b" MESSAGE: $a, $b = the two states
    jq -en --argjson a "$a" --argjson b "$b" "$1" >/dev/null ||
        { echo "FAIL: $2: $(echo "$a" | jq -c '{x,y,heading}') -> $(echo "$b" | jq -c '{x,y,heading}')"; exit 1; }
    echo "ok: $2: $(echo "$a" | jq -c '{x,y,heading}') -> $(echo "$b" | jq -c '{x,y,heading}')"
}
st() { "$CTL" state | jq -c '{frame,x,y,heading}'; }
hold() {        # hold PHASE FRAMES KEY...: keys down for FRAMES, then up; $a/$b around it
    phase=$1 frames=$2; shift 2
    step face 0 >/dev/null
    step wait frames 5 >/dev/null
    a=$(st)
    step log "phase $phase" >/dev/null
    for k in "$@"; do "$CTL" keydown "$k" >/dev/null; done
    step wait frames "$frames" >/dev/null
    b=$(st)
    for k in "$@"; do "$CTL" keyup "$k" >/dev/null; done
    step wait frames 10 >/dev/null
}
game() {        # game NAME CONFIG_TEXT: start Downtown with --ctl, wait for the level
    printf "$2" > "$OUT/$1.yaml"
    export GTA2_CTL="${TMP%/}/gta2ctl-pm-$$-$1.sock"
    (cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
        --window=640x480 --config="$OUT/$1.yaml" --telemetry="$OUT/$1.jsonl" \
        --keys=150:RETURN,250:RETURN) > "$OUT/$1.log" 2>&1 &
    GAME=$!
    trap 'kill $GAME 2>/dev/null || true' EXIT
    step --wait-sock=60 ping >/dev/null
    step wait in_game == 1 1200
    step wait frame '>=' 260
    step wait frames 30
}
quit() {
    step quit
    wait $GAME || true
    trap - EXIT
}

# ---- 1. strafe and mouse turning on --------------------------------------------------
game on 'controls:\n  strafe: true\n  mouse_turn: true\n  mouse_sensitivity: 100\n'
grep '^controls:' "$OUT/on.log"
hold left-wall 150 Q            # +x until the wall at x ~163.8, then the slide along it
check '$b.x > $a.x + 3.5 and $b.x < 164.2 and $b.heading == 0' "strafe left reaches the +x wall"
hold left-held 30 Q             # pressed against the wall: x does not grow
check '($b.x - $a.x) < 0.05' "strafe left stopped by the wall"
step shot "$OUT/1-left-wall.bmp"
hold right-wall 150 E           # −x until the wall at x ~158.1, where it stops dead
check '$b.x < $a.x - 4 and $b.x > 157.9 and $b.heading == 0' "strafe right reaches the −x wall"
hold right-held 30 E
check '$b.x == $a.x and $b.y == $a.y' "strafe right stopped by the wall"
step shot "$OUT/2-right-wall.bmp"
hold fwd-left 40 UP Q           # diagonal: +x and +y, facing unchanged
check '$b.x > $a.x + 0.5 and $b.y > $a.y + 0.5 and $b.heading == 0' "forward + left diagonal"
hold back-left 40 DOWN Q        # back + left: +x and −y
check '$b.x > $a.x + 0.5 and $b.y < $a.y - 0.5 and $b.heading == 0' "back + left diagonal"
hold fwd 30 UP                  # plain walking is untouched
check '$b.y > $a.y + 0.5 and $b.heading == 0' "forward alone"
step shot "$OUT/3-diagonals.bmp"
step face 0 >/dev/null
step wait frames 5 >/dev/null
a=$(st)
step log "phase mouse" >/dev/null
step mouse 100                  # 100% = 2 Ang16 units per pixel: −200 = 50° to the right
step wait frames 5 >/dev/null
b=$(st)
check '$b.heading == 310' "mouse 100 px turns 50° right"
a=$b
step mouse -40                  # +80 = 20° left
step wait frames 5 >/dev/null
b=$(st)
check '$b.heading == 330' "mouse -40 px turns 20° left"
step shot "$OUT/4-mouse.bmp"
quit

# ---- 2. both off: vanilla --------------------------------------------------------------
game off 'controls:\n  strafe: false\n  mouse_turn: false\n'
grep '^controls:' "$OUT/off.log"
hold off-left 60 Q
check '$b.x == $a.x and $b.y == $a.y and $b.heading == $a.heading' "strafe off: Q does nothing"
step face 0 >/dev/null
step wait frames 5 >/dev/null
a=$(st)
step mouse 100
step wait frames 5 >/dev/null
b=$(st)
check '$b.heading == $a.heading' "mouse turning off: the mouse does not turn"
step shot "$OUT/5-off.bmp"
quit
echo "PASS — $OUT"
