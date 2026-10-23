#!/bin/sh
# tests/ctl/emergency.sh — the K menu's "Call ambulance" / "Call fire truck" end to end
# (host/c32/emergency.c, docs/re/gangs-and-peds.md section 7) with gta2ctl: next to the
# three-lane road east of the Downtown start, call an ambulance (a ped is queued or killed,
# the MEDICAR comes, the crew gets out), then a fire truck (a car mid-lane is lit, the truck
# comes and hoses). Checks the "emerg:" log lines and takes screenshots on the way.
#
#   tests/ctl/emergency.sh [OUT_DIR]      default: $TMPDIR/gta2ctl-emergency-<pid>
#
# Needs a built tree (host/build.sh) and jq. The K menu is driven with keys (HOME + DOWN n
# picks a row), so it depends on the row order of the root and Player pages.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=${TMPDIR:-/tmp}
OUT=${1:-${TMP%/}/gta2ctl-emergency-$$}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
CTL="$ROOT/tools/gta2ctl/gta2ctl"
export GTA2_CTL="${TMP%/}/gta2ctl-emergency-$$.sock"
[ -x "$CTL" ] && [ -x "$ROOT/host/loader" ] || { echo "build first: host/build.sh" >&2; exit 1; }
LOG="$OUT/game.log"

step() {
    printf '$ gta2ctl %s\n' "$*"
    "$CTL" "$@" || { rc=$?; echo "FAIL (exit $rc): gta2ctl $*"; exit 1; }
}
key() {         # key NAME [N]: N taps, a few frames apart
    i=0
    while [ $i -lt "${2:-1}" ]; do
        "$CTL" key "$1" 2 >/dev/null && "$CTL" wait frames 4 >/dev/null
        i=$((i + 1))
    done
}
player_row() {  # player_row N: K, root row 7 (Player...), row N of the Player page, RETURN, K
    key K; key HOME; key DOWN 7; key RETURN
    key HOME; key DOWN "$1"; key RETURN
    "$CTL" wait frames 6 >/dev/null
    step shot "$OUT/$2.bmp"
    key BACK; key K                 # back to the root: the menu reopens on the last page
}
wait_log() {    # wait_log PATTERN FRAMES: until the game log has PATTERN
    n=0
    while ! grep -q "$1" "$LOG"; do
        n=$((n + 30))
        [ $n -le "$2" ] || { echo "FAIL: no '$1' in the log after $2 frames"; exit 1; }
        "$CTL" wait frames 30 >/dev/null
    done
    echo "ok: log has '$1': $(grep "$1" "$LOG" | head -1)"
}

(cd "$ROOT/host" && exec arch -x86_64 ./loader ../data.pak --entry --ctl="$GTA2_CTL" \
    --window=640x480 --keys=150:RETURN,250:RETURN) > "$LOG" 2>&1 &
GAME=$!
trap 'kill $GAME 2>/dev/null || true' EXIT

step --wait-sock=60 ping
step wait in_game == 1 1200
step wait frame '>=' 260
step wait frames 30
step teleport 167 133               # west of the one-way road at x = 168..170
step wait frames 250                # the camera pans after a teleport

# ---- ambulance -----------------------------------------------------------------------
player_row 6 1-menu-ambulance
wait_log 'emerg: ambulance for ped' 60
wait_log 'ambulance slot0 stage' 900
step shot "$OUT/2-ambulance-dispatched.bmp"
"$CTL" wait frames 600 >/dev/null
step shot "$OUT/3-ambulance-later.bmp"

# ---- fire truck ----------------------------------------------------------------------
player_row 7 4-menu-firetruck
wait_log 'emerg: fire truck for car' 60
wait_log 'fire slot. state 3' 3600
step shot "$OUT/5-firetruck-hosing.bmp"
"$CTL" wait frames 300 >/dev/null
step shot "$OUT/6-firetruck-later.bmp"
step quit
wait $GAME || true
trap - EXIT
grep -E 'emerg:|c32: (hook|emerg)' "$LOG" | sed 's/^/  /'
echo "PASS — $OUT"
