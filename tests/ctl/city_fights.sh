#!/bin/sh
# tests/ctl/city_fights.sh — the city-fights mod (docs/city-fights.md) end to end. Starts
# Downtown with `mods: city_fights: on|off`, walks to the pavement east of the start
# (168.5, 133.5; a walk, not a teleport, so the camera follows and nobody despawns off screen),
# then two scenes, each followed through `gta2ctl ped ID` (health, state, task, target):
#
#   1. a calm Zaibatsu gang member (remap 8) and a cop 4 blocks north of him, facing each other.
#      on:  the cop takes KILL_CHAR_ON_FOOT (task 20) on the gang member, they shoot it out.
#      off: vanilla: neither attacks (a cop only goes for a non-player who is attacking).
#   2. a Loonie (remap 11) and a Zaibatsu member 4 blocks apart: rival gangs fight in both
#      modes (native, GangRespect.hostileToGang); reported, not asserted.
#
#   tests/ctl/city_fights.sh on|off [OUT_DIR]      default OUT_DIR: $TMPDIR/city-fights-<mode>-<pid>
#
# Exit 0 = the mode behaved as expected. OUT_DIR: game.log, config.yaml, screenshots.
set -eu
MODE=${1:-on}
case $MODE in on|off) ;; *) echo "usage: $0 on|off [OUT_DIR]" >&2; exit 2 ;; esac
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${2:-${TMP%/}/city-fights-$MODE-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-cityfights-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }

printf 'mods:\n  city_fights: %s\n' "$MODE" > "$OUT/config.yaml"
(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --config="$OUT/config.yaml" --keys=150:RETURN,250:RETURN) > "$OUT/game.log" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
}
spawn() {       # spawn ped ... -> its id
    r=$("$CTL" spawn ped "$@") || { echo "FAIL: spawn ped $*: $r" >&2; exit 1; }
    echo "$r" | sed 's/.*"id":\([0-9]*\).*/\1/'
}
field() {       # field JSON NAME -> the number
    echo "$1" | sed "s/.*\"$2\":\(-*[0-9]*\).*/\1/"
}
# watch A B LABEL: 20 polls 30 frames apart; prints "health/state/task->target" of both,
# screenshots the first poll where either is hurt or attacking the other; sets ENGAGED (one
# attacked the other) and HURT (one lost health)
watch() {
    ENGAGED=0 HURT=0 shot=0
    for t in $(seq 1 20); do
        "$CTL" wait frames 30 > /dev/null
        a=$("$CTL" ped "$1") || a='"health":-1,"state":-1,"task":-1,"target":-1'
        b=$("$CTL" ped "$2") || b='"health":-1,"state":-1,"task":-1,"target":-1'
        line="$3 t=$t: $1 $(field "$a" health)hp st$(field "$a" state) task$(field "$a" task)->$(field "$a" target)"
        line="$line | $2 $(field "$b" health)hp st$(field "$b" state) task$(field "$b" task)->$(field "$b" target)"
        echo "$line"
        [ "$(field "$a" task)" = 20 ] && [ "$(field "$a" target)" = "$2" ] && ENGAGED=1
        [ "$(field "$b" task)" = 20 ] && [ "$(field "$b" target)" = "$1" ] && ENGAGED=1
        h1=$(field "$a" health) h2=$(field "$b" health)
        { [ "$h1" -ge 0 ] && [ "$h1" -lt 100 ]; } || { [ "$h2" -ge 0 ] && [ "$h2" -lt 100 ]; } && HURT=1
        if [ $shot = 0 ] && [ $((ENGAGED + HURT)) -gt 0 ]; then
            "$CTL" shot "$OUT/$3.bmp" > /dev/null && shot=1
        fi
    done
    [ $shot = 1 ] || "$CTL" shot "$OUT/$3.bmp" > /dev/null
}

step --wait-sock=60 ping
step wait in_game == 1 1200
step wait frame '>=' 260                    # every --keys RETURN is through
step goto 168.5 133.5                       # out of the start courtyard to the pavement

gang=$(spawn 8 gang --at=167.3,135.5 --rot=180)
cop=$(spawn 0 cop --at=167.3,131.5 --rot=0)
echo "scene 1: cop $cop vs calm Zaibatsu $gang"
watch "$cop" "$gang" cop-vs-gang
cop_engaged=$ENGAGED cop_hurt=$HURT

z=$(spawn 8 gang --at=167.3,142.5 --rot=180)
l=$(spawn 11 gang --at=167.3,138.5 --rot=0)
echo "scene 2: Loonie $l vs Zaibatsu $z"
watch "$l" "$z" gang-vs-gang
gang_engaged=$ENGAGED gang_hurt=$HURT

step quit
wait $GAME || true
trap - EXIT
echo "--- city_fights lines in game.log:"
grep 'city_fights' "$OUT/game.log" | head -20 || true
echo "scene 1 cop vs gang: engaged=$cop_engaged hurt=$cop_hurt; scene 2 gang vs gang: engaged=$gang_engaged hurt=$gang_hurt"
if [ "$MODE" = on ]; then
    [ "$cop_engaged" = 1 ] && [ "$cop_hurt" = 1 ] || { echo "FAIL: on, but the cop and the gang member did not fight"; exit 1; }
else
    [ "$cop_engaged" = 0 ] && [ "$cop_hurt" = 0 ] || { echo "FAIL: off, but the cop and the calm gang member fought (not vanilla)"; exit 1; }
    ! grep -q 'city_fights:' "$OUT/game.log" || { echo "FAIL: off, but the mod logged a decision"; exit 1; }
fi
echo "PASS ($MODE) — $OUT"
