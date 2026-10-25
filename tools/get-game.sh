#!/bin/sh
# Download GTA2 and build data.pak from it: vanilla 11.44 + the radio / menu music.
#   tools/get-game.sh [--no-music] [--force] [OUT]     default OUT: <repo>/data.pak
#     --no-music  skip the 345 MB freeware installer; the game runs without radio music
#     --force     replace an existing OUT
#
# Two downloads, kept in $GTA2_DOWNLOADS (default <repo>/downloads/, git-ignored) and
# verified by size and SHA-256 before use; a file already there is used without network,
# so a second run works offline:
#   gta2-installer.ebin   gtamp.com's GTA2 installer (NSIS 3, 17 MB). Its files are the
#                         11.44 game (gta2.exe SHA-256 dd5381c7...a5a2) plus gta2_install.reg,
#                         byte-identical to the canonical pak's.
#   GTA2INSTALLER.ebin    Rockstar's 2004 freeware installer from the Internet Archive
#                         (InstallShield 7, 345 MB). Its gta2.exe is 9.6, so only its 22
#                         data/GTAudio music files are taken (tools/add-music.sh). A copy kept
#                         as setup.ebin in the repo root or the main checkout is used too.
# Both are saved as .ebin (no .exe files in the project) and never run: 7zz unpacks the
# NSIS one, unshield the InstallShield cabinets.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
main="$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
cache="${GTA2_DOWNLOADS:-$root/downloads}"
music=1 force=0 out=
for a in "$@"; do
    case "$a" in
    --no-music) music=0 ;;
    --force) force=1 ;;
    -*) sed -n '2,5s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
    *) out="$a" ;;
    esac
done
out="${out:-$root/data.pak}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
[ "$force" = 1 ] || [ ! -e "$out" ] || { echo "get-game: $out exists (--force replaces it)" >&2; exit 1; }

GTAMP_URL=https://gtamp.com/GTA2/gta2-installer.exe
GTAMP_SIZE=17620859
GTAMP_SHA256=1b9e82005a66a6eb920e4875135ad8f4a056664769a269c3b597c1a8e37fecda
FREE_URL=https://archive.org/download/gta2_rockstar-classics/GTA2INSTALLER.exe
FREE_SIZE=362331961
FREE_SHA256=0cd380498dfbe62448d56aaddd3e36593cfda324aa8a3972b06a02d015b083a0
VANILLA_SHA256=dd5381c7297bc13151bed8d129fa04a267114f92707c096772ebdd5a6cdca5a2

missing=
command -v 7zz >/dev/null || missing="$missing sevenzip"
[ "$music" = 0 ] || command -v unshield >/dev/null || missing="$missing unshield"
[ -z "$missing" ] || { echo "get-game: needs brew install$missing" >&2; exit 1; }

# valid FILE SIZE SHA256: the file is there with that size and hash
valid() {
    [ -f "$1" ] && [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] &&
        [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$3" ]
}

# fetch NAME URL SIZE SHA256 [OTHER_COPY...]: print the path of a verified copy,
# downloading it into $cache/NAME when no copy is valid
fetch() {
    name="$1" url="$2" size="$3" sha="$4"
    shift 4
    for f in "$cache/$name" "$@"; do
        valid "$f" "$size" "$sha" && { echo "$f"; return; }
        [ ! -f "$f" ] || echo "get-game: ignoring $f (not size $size, sha256 $sha)" >&2
    done
    mkdir -p "$cache"
    echo "get-game: downloading $url ($size bytes)" >&2
    curl -fL --retry 3 --progress-bar -C - -o "$cache/$name.part" "$url" >&2 ||
        { echo "get-game: download failed; rerun to resume" >&2; return 1; }
    valid "$cache/$name.part" "$size" "$sha" || {
        rm -f "$cache/$name.part"
        echo "get-game: $url is not the expected file (size $size, sha256 $sha)" >&2
        return 1
    }
    mv "$cache/$name.part" "$cache/$name"
    echo "$cache/$name"
}

gtamp="$(fetch gta2-installer.ebin "$GTAMP_URL" "$GTAMP_SIZE" "$GTAMP_SHA256")"
if [ "$music" = 1 ]; then
    free="$(fetch GTA2INSTALLER.ebin "$FREE_URL" "$FREE_SIZE" "$FREE_SHA256" \
        "$root/setup.ebin" ${main:+"$main/setup.ebin"})"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/get-game.XXXXXX")"
trap 'rm -rf "$work"' EXIT
7zz x -y -o"$work/game" -x'!$*' "$gtamp" > "$work/7zz.log" ||
    { tail -5 "$work/7zz.log" >&2; exit 1; }
[ "$(shasum -a 256 "$work/game/gta2.exe" | cut -d' ' -f1)" = "$VANILLA_SHA256" ] ||
    { echo "get-game: the installer's gta2.exe is not vanilla 11.44" >&2; exit 1; }
"$root/tools/mkpak.sh" "$work/game" "$work/data.pak"
rm -rf "$work/game"
[ "$music" = 0 ] || "$root/tools/add-music.sh" "$free" "$work/data.pak" "$work/data.pak"
mv -f "$work/data.pak" "$out"
echo "get-game: $out ready"
