#!/bin/sh
# Pack an installed GTA2 folder into data.pak: a plain zip, every entry Stored (method 0),
# paths relative to the folder root (gta2.ebin, data/audio/fstyle.raw, ...).
#   tools/mkpak.sh [GAME_DIR [OUT]]     default: <repo>/gta2 -> <repo>/data.pak
# GAME_DIR is the original game as installed (gta2.exe, data/, ...). It is not modified:
# the files are staged as copy-on-write clones, and every *.exe is renamed to *.ebin
# inside the pak. The loader's VFS refuses any entry that is not Stored, so never pass
# a -1..-9 level.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$root/gta2}"
out="${2:-$root/data.pak}"
VANILLA_SHA256=dd5381c7297bc13151bed8d129fa04a267114f92707c096772ebdd5a6cdca5a2

[ -d "$src" ] || { echo "mkpak: $src is not a directory" >&2; exit 1; }
src="$(cd "$src" && pwd)"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

stage="$(mktemp -d "${TMPDIR:-/tmp}/mkpak.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -cR "$src/" "$stage/game" 2>/dev/null || cp -R "$src/" "$stage/game"
find "$stage/game" -type f -iname '*.exe' | while read -r f; do
    mv "$f" "${f%.*}.ebin"
done

[ -f "$stage/game/gta2.ebin" ] || { echo "mkpak: no gta2.exe / gta2.ebin in $src" >&2; exit 1; }
sha="$(shasum -a 256 "$stage/game/gta2.ebin" | cut -d' ' -f1)"
[ "$sha" = "$VANILLA_SHA256" ] ||
    echo "mkpak: warning: gta2.exe is not vanilla 11.44 (sha256 $sha); the loader expects 11.44" >&2

rm -f "$out"
cd "$stage/game"
zip -0 -r -X -q "$out" . -x '*.DS_Store'
echo "mkpak: $out ($(unzip -Z1 "$out" | wc -l | tr -d ' ') entries, $(wc -c < "$out" | tr -d ' ') bytes)"
