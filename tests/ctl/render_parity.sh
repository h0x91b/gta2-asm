#!/bin/sh
# tests/ctl/render_parity.sh — renderer parity screenshots (docs/renderer-sdl.md, "Parity"):
# one scripted run through the frontend, the first seconds of Downtown, the K menu, a
# spawned car, the road overlay, a second district and the in-game quit prompt, with a
# BMP at fixed presented frames. Every input is frame-scheduled and the level starts
# from the same seed, so two runs of the same build should give identical files; two
# builds are compared with cmp (tests/ctl/render_parity.sh OUT_A; LOADER=... OUT_B;
# cmp OUT_A/*.bmp OUT_B/*.bmp). Also records the run's CPU time (time.txt) and the wall
# time of each 120-frame stats line (flips.txt: frame, seconds since start).
#
#   [LOADER=PATH] [WINDOW=WxH] tests/ctl/render_parity.sh [OUT_DIR]
#
# LOADER: the loader binary to run (default host/loader), e.g. a copy built from master.
# WINDOW: --window for the run (default: the game's 1280x960).
# Exit 0 = every step replied ok.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-parity-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
LOADER=${LOADER:-$ROOT/host/loader}
export GTA2_CTL="${TMP%/}/gta2ctl-parity-$$.sock"
[ -x "$CTL" ] && [ -x "$LOADER" ] || { echo "build first: host/build.sh" >&2; exit 1; }

printf '# no mods\n' > "$OUT/config.yaml"
win=
[ -n "${WINDOW:-}" ] && win="--window=$WINDOW"
# each stdout line stamped with the seconds since start (for flips.txt)
(cd "$ROOT/host" && exec /usr/bin/time -l -o "$OUT/time.txt" arch -x86_64 "$LOADER" \
    ../data.pak --entry --ctl="$GTA2_CTL" $win --config="$OUT/config.yaml" \
    --keys=150:RETURN,250:RETURN) 2>&1 \
    | perl -MTime::HiRes=time -ne 'BEGIN { $| = 1; $t0 = time } printf "%.3f %s", time - $t0, $_' \
    > "$OUT/game.log" &
GAME=$!
trap 'pkill -f "ctl=$GTA2_CTL" 2>/dev/null || true' EXIT

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*" >&2; exit 1; }
}
keys() { for k in "$@"; do step key "$k" 2 >/dev/null; done; }
at() { step wait frame '>=' "$1" 3000 >/dev/null; }          # an exact frame (if not passed)
shot() { step shot "$OUT/$1.bmp" | sed 's/.*"frame":\([0-9]*\).*/  frame \1/'; }

step --wait-sock=60 ping
# ---- frontend: the main menu, then PLAY's screen (RETURN at 150), the level at 250 ----
at 60;  shot f060-menu
at 120; shot f120-menu
at 200; shot f200-play
step wait in_game == 1 1200
at 270; shot f270-level
at 300; shot f300-level
at 360; shot f360-level
at 420; shot f420-level
# ---- the K menu: root, then the Debug flags page ---------------------------------------
keys K;                at 440; shot f440-kmenu
keys END UP RETURN;    at 460; shot f460-kmenu-flags
keys BACK K;           at 480; shot f480-kclosed
# ---- another district (tall buildings), a spawned car, driving it -----------------------
step teleport 132 195 >/dev/null
at 740; shot f740-plaza
car=$("$CTL" spawn car 13 --at=129,199 --rot=90) || { echo "FAIL: spawn: $car"; exit 1; }
id=$(echo "$car" | sed 's/.*"id":\([0-9]*\).*/\1/')
at 760; shot f760-car
step enter_car "$id" >/dev/null
at 860; shot f860-in-car
step exit_car >/dev/null
at 900; shot f900-on-foot
# ---- the road overlay (K, Debug flags, Road network: cars), then off again ---------------
keys K END UP RETURN END UP RETURN BACK K
at 960; shot f960-roads
keys K END UP RETURN END UP RETURN RETURN RETURN BACK K
at 1020; shot f1020-roads-off
# ---- the in-game quit prompt ------------------------------------------------------------
keys ESCAPE
at 1040; shot f1040-quit-prompt
keys ESCAPE
at 1060; shot f1060-back
step quit >/dev/null
wait $GAME || true
trap - EXIT
grep ' \[vid\] flip ' "$OUT/game.log" | awk '{ print $4, $1 }' | tr -d : > "$OUT/flips.txt"
echo "PASS — $OUT ($(ls "$OUT"/*.bmp | wc -l | tr -d ' ') shots, game.log, time.txt, flips.txt)"
