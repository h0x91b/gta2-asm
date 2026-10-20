#!/bin/sh
# Pack the loose game folder into data.pak: a plain zip, every entry Stored (method 0),
# paths relative to the folder root (gta2.ebin, data/audio/fstyle.raw, ...).
#   tools/mkpak.sh [GAME_DIR [OUT]]     default: <repo>/gta2 -> <repo>/data.pak
# The loader's VFS refuses any entry that is not Stored, so never pass a -1..-9 level.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$root/gta2}"
out="${2:-$root/data.pak}"
[ -f "$src/gta2.ebin" ] || { echo "mkpak: no gta2.ebin in $src" >&2; exit 1; }
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
rm -f "$out"
cd "$src"
zip -0 -r -X -q "$out" . -x '*.DS_Store'
echo "mkpak: $out ($(unzip -Z1 "$out" | wc -l | tr -d ' ') entries, $(wc -c < "$out" | tr -d ' ') bytes)"
