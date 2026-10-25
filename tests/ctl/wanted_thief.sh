#!/bin/sh
# tests/ctl/wanted_thief.sh — the K menu's Spawn > "Wanted thief" end to end
# (docs/wanted-thief.md). Starts Downtown (city fights off: the hunt does not need them),
# walks to the pavement east of the start (168.5, 133.5), spawns the thief there through
# `gta2ctl spawn thief 4`, then polls `gta2ctl hunt` and `state` 40 times, 30 frames apart:
# the pursuit slot's state and crews, the cops with the thief as their target, his health,
# and the player's own stars. Screenshots: the first poll with 2+ cops after him, and the
# one with the most.
#
#   tests/ctl/wanted_thief.sh [OUT_DIR]       default OUT_DIR: $TMPDIR/wanted-thief-<pid>
#   STARS=1..6 POLLS=N (env): the thief's stars (default 4) and the number of polls (40)
#   STEAL=1 (env): a car (model 13) is spawned on the road next to him and he is ordered to
#   steal it (`gta2ctl hunt steal`); the run then also needs a roadblock ahead of that car
#   AWAY=X,Y (env): right after the spawn the player is teleported there, so the chase runs
#   off screen (reported, the asserts stay the same)
#
# Exit 0 = police crews were dispatched for him, at least 2 cops targeted him at once, and
# the player's wanted level stayed 0 throughout. OUT_DIR: game.log, polls.txt, screenshots.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/wanted-thief-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-wthief-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }

printf 'mods:\n  city_fights: off\n' > "$OUT/config.yaml"
(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --config="$OUT/config.yaml" --keys=150:RETURN,250:RETURN) > "$OUT/game.log" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
}
field() {       # field JSON NAME -> the number after the last "NAME":, else -1
    v=$(echo "$1" | sed -n "s/.*\"$2\":\(-*[0-9][0-9]*\).*/\1/p")
    echo "${v:--1}"
}

step --wait-sock=60 ping
step wait in_game == 1 1200
step wait frame '>=' 260                    # every --keys RETURN is through
step goto 168.5 133.5                       # out of the start courtyard to the pavement

if [ "${STEAL:-0}" = 1 ]; then
    c=$("$CTL" spawn car 13 --at=169.5,131.5 --rot=180) || { echo "FAIL: spawn car: $c"; exit 1; }
    car=$(field "$c" id)
    r=$("$CTL" spawn thief "${STARS:-4}" --at=168.4,131.5) || { echo "FAIL: spawn thief: $r"; exit 1; }
    step hunt steal "$car"
else
    r=$("$CTL" spawn thief "${STARS:-4}") || { echo "FAIL: spawn thief: $r"; exit 1; }
fi
thief=$(field "$r" id)
echo "thief: ped $thief"
[ -n "${AWAY:-}" ] && step teleport $(echo "$AWAY" | tr , ' ')

MAXH=0 MAXCREWS=0 SWAT=0 WANTED=0 FIRST=0 HURT=0 GONE=0 RB=0 INCAR=0
: > "$OUT/polls.txt"
for t in $(seq 1 "${POLLS:-40}"); do
    "$CTL" wait frames 30 > /dev/null
    s=$("$CTL" state)
    w=$(field "$s" wanted_points)       # the player's own (peds[] carry "wanted" too)
    [ "$w" -gt "$WANTED" ] && WANTED=$w
    h=$("$CTL" hunt "$thief") || { echo "t=$t: thief gone: $h" | tee -a "$OUT/polls.txt"; GONE=1; break; }
    hunt=$(echo "$h" | sed 's/.*"hunt":{\([^}]*\)}.*/\1/')
    target=$(echo "$h" | sed 's/.*"target":{\([^}]*\)}.*/\1/')
    hunters=$(echo "$h" | sed 's/.*"hunters":\[\(.*\)\].*/\1/')
    n=$(echo "$hunters" | grep -o '"id":' | wc -l | tr -d ' ')
    cops=$(echo "$hunters" | grep -o '"id":[0-9]*,"remap":[0-9]*,"occupation":[0-9]*' |
           sed 's/"id":\([0-9]*\),"remap":[0-9]*,"occupation":\([0-9]*\)/\1(occ \2)/' | tr '\n' ' ')
    crews=$(field "{$hunt}" crews) swat=$(field "{$hunt}" swat_crews) st=$(field "{$hunt}" state)
    hp=$(field "{$target}" health)
    tx=$(echo "$target" | sed 's/.*"x":\([-0-9.]*\),"y":\([-0-9.]*\).*/\1,\2/')
    near=$(echo "$hunters" | sed -n 's/^{[^}]*"dist":\([0-9.]*\).*/\1/p')
    line="t=$t: pursuit state $st crews $crews swat $swat | thief ${hp}hp at $tx in_car $(echo "$target" | sed 's/.*"in_car":\([a-z]*\).*/\1/') stars $(field "{$target}" wanted) | $n cops after him (nearest ${near:--}): $cops| player wanted points $w"
    echo "$line" | tee -a "$OUT/polls.txt"
    [ "$crews" -gt "$MAXCREWS" ] && MAXCREWS=$crews
    [ "$swat" -gt 0 ] && SWAT=1
    rb=$(field "{$hunt}" roadblocks)
    [ "$rb" -gt "$RB" ] && RB=$rb
    case $target in *'"in_car":true'*) INCAR=1 ;; esac
    [ "$hp" -ge 0 ] && [ "$hp" -lt 100 ] && HURT=1
    if [ "$n" -ge 2 ] && [ $FIRST = 0 ]; then
        "$CTL" shot "$OUT/first-hunters.bmp" > /dev/null && FIRST=1
    fi
    if [ "$n" -gt "$MAXH" ]; then
        MAXH=$n
        "$CTL" shot "$OUT/most-hunters.bmp" > /dev/null || true
    fi
    [ "$(field "{$target}" health)" = 0 ] && break
done

step quit
wait $GAME || true
trap - EXIT
echo "--- wanted_thief lines in game.log:"
grep 'wanted_thief' "$OUT/game.log" | head -30 || true
echo "max cops after him at once: $MAXH, max crews: $MAXCREWS, swat: $SWAT, thief hurt: $HURT, in a car: $INCAR, roadblocks: $RB, player's max wanted points: $WANTED"
[ "$WANTED" = 0 ] || { echo "FAIL: the player got wanted points"; exit 1; }
[ "$MAXCREWS" -ge 1 ] || { echo "FAIL: no police crew was dispatched for the thief"; exit 1; }
[ "$MAXH" -ge 2 ] || { echo "FAIL: never 2 cops after the thief at once"; exit 1; }
if [ "${STEAL:-0}" = 1 ]; then
    [ "$INCAR" = 1 ] || { echo "FAIL: STEAL=1, but he never sat in a car"; exit 1; }
    [ "$RB" -ge 1 ] || { echo "FAIL: STEAL=1, but no roadblock went up ahead of him"; exit 1; }
fi
echo "PASS — $OUT"
