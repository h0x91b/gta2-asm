#!/bin/sh
# tests/ctl/ctl_hooks.sh — gta2ctl's own game hooks (host/ctl_hooks.asm, docs/gta2ctl.md
# "Where the code is"): `sms` shows a brief (BriefText), `drive_to` lets the car AI drive the
# player's car (CarDriverClass, DriveCar): the AI ticks count up (the CarDriverClass hook
# runs every tick) and the car moves without any key held. From parked car 29 the AI only
# pulls out 1.5 blocks and waits (gas 0) within 300 frames: measured the same on master
# b7983ac, so that is drive_to's own behaviour (experimental), not a hook failure.
#
#   tests/ctl/ctl_hooks.sh [OUT_DIR]      default: $TMPDIR/gta2ctl-ctl-hooks-<pid>
#
# Needs a built tree (host/build.sh) and jq. OUT_DIR gets game.log and screenshots.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-ctl-hooks-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-ctl-hooks-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }

step() {
    printf '$ gta2ctl %s\n' "$*"
    r=$("$CTL" "$@") || { rc=$?; echo "$r"; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
    echo "$r"
}

(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --window=640x480 --keys=150:RETURN,250:RETURN) > "$OUT/game.log" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT
step --wait-sock=60 ping >/dev/null
step wait in_game == 1 1200
step wait frame '>=' 260
step wait frames 30

grep 'hook: .*\(CarDriverClass\|DriveCar\|BriefText\)' "$OUT/game.log"
[ "$(grep -c 'hook: .*\(CarDriverClass\|DriveCar\|BriefText\)' "$OUT/game.log")" -ge 4 ] ||
    { echo "FAIL: the gta2ctl hooks are not installed"; exit 1; }

step sms "CTL HOOKS TEST"
step wait frames 15
step shot "$OUT/1-sms.bmp"
grep -q 'ctl: sms' "$OUT/game.log" && grep 'ctl: sms' "$OUT/game.log" | tail -1 || true

step teleport 132 195                   # 2 blocks from a parked car (smoke.sh)
step enter_car nearest
step wait in_car == 1 300
a=$("$CTL" state | jq -c '{x,y}')
# drive_to runs until arrived/stuck/timeout; 300 frames are enough to see the AI drive
"$CTL" drive_to 150 195 300 > "$OUT/drive.json" || true
cat "$OUT/drive.json"
b=$("$CTL" state | jq -c '{x,y,in_car}')
step shot "$OUT/2-drive_to.bmp"
d=$(jq -n --argjson a "$a" --argjson b "$b" '(($b.x-$a.x)*($b.x-$a.x)+($b.y-$a.y)*($b.y-$a.y)) | sqrt')
echo "car moved $d blocks: $a -> $b"
jq -e '.aiticks > 0' "$OUT/drive.json" >/dev/null || { echo "FAIL: no car AI ticks"; exit 1; }
jq -en --argjson d "$d" '$d > 1' >/dev/null || { echo "FAIL: drive_to did not drive the car"; exit 1; }
step quit
wait $GAME || true
trap - EXIT
echo "PASS — $OUT"
