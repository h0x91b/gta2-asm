#!/bin/sh
# tests/ctl/smoke.sh — gta2ctl end to end (docs/gta2ctl.md): start Downtown with --ctl,
# then state, teleport next to a parked car, enter it, get out, walk 5 blocks, spawn a car
# and get into that one, check the car-entry bonus (mods: car_enter_bonus 333), screenshot,
# quit. Every step prints the game's JSON reply; the first failure stops the test.
#
#   tests/ctl/smoke.sh [OUT_DIR]      default: $TMPDIR/gta2ctl-smoke-<pid>
#
# Needs a built tree (host/build.sh). OUT_DIR gets game.log, telemetry.jsonl, config.yaml
# and the screenshots. Exit 0 = all steps passed.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-smoke-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-smoke-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }

printf 'mods:\n  car_enter_bonus: 333\n' > "$OUT/config.yaml"
(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --config="$OUT/config.yaml" --telemetry="$OUT/telemetry.jsonl,every=30" \
    --keys=150:RETURN,250:RETURN) > "$OUT/game.log" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
}

step --wait-sock=60 ping
step wait in_game == 1 1200                 # the menu keys start the level
step wait frames 30
step state
step teleport 132 195                       # Downtown: 2 blocks from a parked car (id 29)
step wait frames 5
step enter_car nearest
step wait in_car == 1 30
step wait money '>=' 333 120                # mods: car_enter_bonus
step exit_car
step goto 132.5 199.5                       # 5 blocks across the plaza, past the car
echo '$ gta2ctl spawn car 13 --at=129,199 --rot=90'
car=$("$CTL" spawn car 13 --at=129,199 --rot=90) || { echo "FAIL: spawn: $car"; exit 1; }
echo "$car"
id=$(echo "$car" | sed 's/.*"id":\([0-9]*\).*/\1/')
step enter_car "$id"
step wait money '>=' 666 120
step wait frames 60                         # the camera zooms out after entering
step shot "$OUT/in-car.bmp"
step exit_car
step wait frames 10
step shot "$OUT/on-foot.bmp"
step log smoke test done
step quit
wait $GAME || true
trap - EXIT
echo "PASS — $OUT (game.log, telemetry.jsonl, in-car.bmp, on-foot.bmp)"
