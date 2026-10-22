#!/bin/sh
# tests/ctl/passenger.sh — the passenger mod end to end (docs/passenger.md) with gta2ctl:
# Shift+Enter into a parked car (seated as a passenger, no car-entry bonus, the arrow keys
# do not drive it), Enter to get out, plain Enter still takes the driver's seat (bonus
# paid), then a ride with an AI driver, then the same Shift+Enter with the mod off
# (= vanilla: the driver's seat).
#
#   tests/ctl/passenger.sh [OUT_DIR]      default: $TMPDIR/gta2ctl-passenger-<pid>
#
# Needs a built tree (host/build.sh) and jq. OUT_DIR gets the logs and screenshots.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-passenger-$$}
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
expect() {      # expect FIELD VALUE
    v=$(field "$1")
    [ "$v" = "$2" ] || { echo "FAIL: $1 = $v, expected $2"; exit 1; }
    echo "ok: $1 = $v"
}
game() {        # game NAME CONFIG_TEXT: start Downtown with --ctl, wait for the level
    printf "$2" > "$OUT/$1.yaml"
    export GTA2_CTL="${TMP%/}/gta2ctl-passenger-$$-$1.sock"
    (cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
        --window=640x480 --config="$OUT/$1.yaml" --keys=150:RETURN,250:RETURN) \
        > "$OUT/$1.log" 2>&1 &
    GAME=$!
    trap 'kill $GAME 2>/dev/null || true' EXIT
    step --wait-sock=60 ping >/dev/null
    step wait in_game == 1 1200
    step wait frame '>=' 260         # every --keys RETURN is through (a level started early,
    step wait frames 30              # e.g. by a real key press, would get them as Enter = car)
}
quit() {
    step quit
    wait $GAME || true
    trap - EXIT
}

# ---- 1. mod on: parked car, ride, exit, plain Enter ----------------------------------
game on 'mods:\n  car_enter_bonus: 333\n'
step teleport 132 195                   # 2 blocks from a parked car (smoke.sh)
step wait frames 250                    # the camera pans after a teleport, slowly
r=$(step enter_car nearest --key --passenger); echo "$r"
[ "$(echo "$r" | tail -1 | jq -r .result)" = passenger ] || { echo "FAIL: not a passenger"; exit 1; }
step wait frames 20
expect in_car true
expect driver false
expect money 0                          # car_enter_bonus pays drivers only
x0=$(field x); y0=$(field y)
step shot "$OUT/2-seated-passenger.bmp"
step keydown UP                         # a passenger must not drive
step wait frames 60
step keyup UP
x1=$(field x); y1=$(field y)
[ "$x0 $y0" = "$x1 $y1" ] || { echo "FAIL: the car moved: $x0,$y0 -> $x1,$y1"; exit 1; }
echo "ok: UP held 60 frames, car still at $x1,$y1"
step exit_car --key
step wait frames 20
expect in_car false
step shot "$OUT/3-got-out.bmp"
# again, with a screenshot on the way to the door (the camera does not follow a teleported
# ped on foot, so the first entry above has none)
"$CTL" enter_car nearest --key --passenger > "$OUT/enter.json" &
ENTER=$!
step wait ped_state == 3 300            # ENTERING_CAR: at the door
step shot "$OUT/1-walk-to-door.bmp"
wait $ENTER || { cat "$OUT/enter.json"; echo "FAIL: enter_car --passenger"; exit 1; }
cat "$OUT/enter.json"
[ "$(jq -r .result "$OUT/enter.json")" = passenger ] || { echo "FAIL: not a passenger"; exit 1; }
step exit_car --key
step wait frames 20
step enter_car nearest --key            # plain Enter: the driver's seat, as in vanilla
step wait frames 20
expect driver true
expect money 333
step shot "$OUT/4-plain-enter-driver.bmp"
step exit_car --key

# ---- 2. a car with an AI driver: wait for one that stops near the player --------------
ok=
for i in $(seq 1 40); do
    car=$("$CTL" state | jq -c '[.cars[] | select(.has_driver and .speed < 0.02)][0] // empty')
    if [ -n "$car" ]; then
        id=$(echo "$car" | jq -r .id)
        echo "stopped driven car: $car"
        # next to it (the ped walks the rest; the game waits for the car to stop at a door)
        "$CTL" teleport "$(echo "$car" | jq -r '.x + 1.2')" "$(echo "$car" | jq -r .y)" >/dev/null
        "$CTL" wait frames 3 >/dev/null
        if r=$("$CTL" enter_car "$id" 600 --passenger); then
            echo "$r"
            [ "$(echo "$r" | jq -r .result)" = passenger ] && { ok=1; break; }
            "$CTL" exit_car --key >/dev/null || true
        else
            echo "$r"
        fi
    fi
    "$CTL" wait frames 30 >/dev/null
done
step wait frames 120                    # camera
if [ -n "$ok" ]; then
    expect driver false
    step wait speed '>' 0.02 900        # the AI driver drives on with the player aboard
    step wait frames 60
    step shot "$OUT/5-riding-with-ai-driver.bmp"
    step state
else
    echo "SKIP: no driven car stopped near the player (traffic-dependent)"
fi
quit

# ---- 3. mod off: Shift+Enter is plain Enter ------------------------------------------
game off 'mods:\n  passenger_enter: false\n'
step teleport 132 195
step wait frames 250
step enter_car nearest --key --passenger
step wait frames 20
expect driver true
step shot "$OUT/6-mod-off-driver.bmp"
quit
grep -h 'passenger:' "$OUT/on.log" "$OUT/off.log" || true
echo "PASS — $OUT"
