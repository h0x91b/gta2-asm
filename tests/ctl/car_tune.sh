#!/bin/sh
# tests/ctl/car_tune.sh — K menu → Vehicle → Tuning end to end (host/c32/car_tune.c,
# docs/car-tuning.md) with gta2ctl: the same car down the same straight road (Downtown,
# y 228.5, x 184 -> 238, 54 blocks), full throttle, the peak |linVel| of each run:
#   A stock;  B top speed and acceleration +5 steps (x1.61);  C reset this model (= A);
#   D top speed -7 steps (x0.51, a cap well under the stock top speed);  E reset all models.
#
#   tests/ctl/car_tune.sh [MODEL [OUT_DIR]]   default model 13 (Minx), $TMPDIR/gta2ctl-car-tune-<pid>
#
# Needs a built tree (host/build.sh) and jq. The K menu is driven with keys (HOME + DOWN n
# picks a row), so it depends on the row order of the root, Vehicle and Tuning pages.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
MODEL=${1:-13}
OUT=${2:-${TMP%/}/gta2ctl-car-tune-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-car-tune-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }
LOG="$OUT/game.log"
X0=184 Y0=228.5 X1=238

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
# tune ROW KEY N SHOT: K, root row 8 (Vehicle...), row 5 (Tuning...), row ROW, KEY x N, K
tune() {
    key K; key HOME; key DOWN 8; key RETURN
    key HOME; key DOWN 5; key RETURN
    key HOME; key DOWN "$1"; key "$2" "$3"
    "$CTL" wait frames 6 >/dev/null
    step shot "$OUT/$4.bmp" >/dev/null
    key BACK; key BACK; key K       # back to the root: the menu reopens on the last page
}
# run NAME: from (X0, Y0) facing +x, full throttle to X1; prints and returns the peak speed
peak=0
run() {
    step teleport $X0 $Y0 >/dev/null
    step wait frames 30 >/dev/null
    "$CTL" wait speed '<' 0.005 300 >/dev/null || true
    peak=0 n=0
    "$CTL" keydown UP >/dev/null
    while [ $n -lt 400 ]; do
        s=$("$CTL" state)
        v=$(echo "$s" | jq -r .speed)
        x=$(echo "$s" | jq -r .x)
        peak=$(echo "$v $peak" | awk '{print ($1 > $2) ? $1 : $2}')
        [ "$(echo "$x $X1" | awk '{print ($1 >= $2)}')" = 1 ] && break
        [ "$(echo "$s" | jq -r .in_car)" = true ] || { echo "FAIL: out of the car: $s"; step shot "$OUT/run-$1-fail.bmp"; exit 1; }
        "$CTL" wait frames 2 >/dev/null
        n=$((n + 1))
    done
    "$CTL" keyup UP >/dev/null
    "$CTL" log "car_tune run $1: peak $peak at x $x" >/dev/null
    echo "run $1: peak speed $peak blocks/tick (x $x)"
    step shot "$OUT/run-$1.bmp" >/dev/null
    "$CTL" wait speed '<' 0.005 600 >/dev/null || true
}
log_has() {
    grep -q "$1" "$LOG" || { echo "FAIL: no '$1' in the log"; exit 1; }
    echo "ok: $(grep "$1" "$LOG" | tail -1)"
}

(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --window=640x480 --keys=150:RETURN,250:RETURN) > "$LOG" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step --wait-sock=60 ping >/dev/null
step wait in_game == 1 1200
step wait frame '>=' 260
step wait frames 30

step teleport $((X0 - 2)) 226.5
step wait frames 200                # the camera pans after a teleport
r=$("$CTL" spawn car "$MODEL" 0 --at=$X0,$Y0 --rot=90) || { echo "FAIL: spawn: $r"; exit 1; }; echo "$r"
step enter_car "$(echo "$r" | jq -r .id)"
step wait in_car == 1 300
step wait frames 30

run A; a=$peak
tune 1 RIGHT 5 tune-B-top
tune 2 RIGHT 5 tune-B-accel
log_has 'car_tune: model .* Top speed .*(16[01]% of stock)'
log_has 'car_tune: model .* Acceleration .*(16[01]% of stock)'
run B; b=$peak
tune 12 RETURN 1 tune-C-reset
log_has 'car_tune: model .* reset to stock'
run C; c=$peak
tune 1 LEFT 7 tune-D-top
log_has 'car_tune: model .* Top speed .*(5[0-2]% of stock)'
run D; d=$peak
tune 13 RETURN 1 tune-E-reset-all
log_has 'car_tune: reset 1 models to stock'

step quit >/dev/null
wait $GAME || true
trap - EXIT
grep -E 'c32: car_tune|ctl: log' "$LOG" | sed 's/^/  /'
echo "peaks: A stock $a, B +61% top/accel $b, C reset $c, D -49% top $d"
awk -v a="$a" -v b="$b" -v c="$c" -v d="$d" 'BEGIN {
    ok = b > a * 1.15 && c > a * 0.97 && c < a * 1.03 && d < a * 0.75
    exit !ok }' || { echo "FAIL: peaks out of the expected range"; exit 1; }
echo "PASS — $OUT"
