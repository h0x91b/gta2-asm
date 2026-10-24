#!/bin/sh
# Add the radio / menu music (data/GTAudio/*.wav) from the original GTA2 installer to a pak.
#   tools/add-music.sh [SETUP [IN_PAK [OUT_PAK]]]
#     SETUP    the Rockstar Classics freeware installer GTA2INSTALLER.exe, kept renamed as
#              setup.ebin (default: setup.ebin in the main checkout; it is never run)
#     IN_PAK   default <repo>/data.pak (a vanilla 11.44 pak without data/GTAudio)
#     OUT_PAK  default <repo>/data-music.pak; may equal IN_PAK
#
# The installer is an InstallShield 7 self-extractor: its three cabinets sit at fixed
# offsets (measured by M1sterMo/gta2-browser, web/installer-worker.js), and unshield
# (brew install unshield) unpacks the "App Executables" group from them. Only the 22
# files of data/GTAudio are taken: the game opens data\gtaudio\<id>.wav / <id>A.wav for
# the radio and d.wav / a.wav for the menu (docs/win32-shims.md, "Audio"). Everything
# else in IN_PAK is kept as it is, and the result is packed by tools/mkpak.sh (Stored).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
main="$(git -C "$root" worktree list --porcelain | sed -n '1s/^worktree //p')"
setup="${1:-$main/setup.ebin}"
in_pak="${2:-$root/data.pak}"
out_pak="${3:-$root/data-music.pak}"
SIZE=362331961
SHA1=8c10c0d20f15912a9450b6fbe028f31928b29893

command -v unshield >/dev/null || { echo "add-music: needs unshield (brew install unshield)" >&2; exit 1; }
[ -f "$setup" ] || { echo "add-music: no installer at $setup" >&2; exit 1; }
[ -f "$in_pak" ] || { echo "add-music: no pak at $in_pak" >&2; exit 1; }
[ "$(wc -c < "$setup" | tr -d ' ')" = "$SIZE" ] && [ "$(shasum -a 1 "$setup" | cut -d' ' -f1)" = "$SHA1" ] ||
    { echo "add-music: $setup is not GTA2INSTALLER.exe (size $SIZE, sha1 $SHA1)" >&2; exit 1; }
case "$out_pak" in /*) ;; *) out_pak="$PWD/$out_pak" ;; esac

work="$(mktemp -d "${TMPDIR:-/tmp}/add-music.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# name, offset, size of each cabinet inside the self-extractor
cut() { tail -c +$(($2 + 1)) "$setup" | head -c "$3" > "$work/$1"; }
cut data1.hdr $((0xEE96E)) 71292
cut data1.cab $((0x604AA)) 582812
cut data2.cab $((0x100016)) 359762427
unshield -g 'App Executables' -d "$work/x" x "$work/data1.hdr" > "$work/unshield.log" ||
    { tail -5 "$work/unshield.log" >&2; exit 1; }
music="$(find "$work/x" -type d -ipath '*/data/gtaudio' | head -1)"
[ -n "$music" ] && [ "$(ls "$music" | wc -l | tr -d ' ')" = 22 ] ||
    { echo "add-music: no data/GTAudio (22 files) in the installer" >&2; exit 1; }

mkdir "$work/game"
unzip -q "$in_pak" -d "$work/game"
find "$work/game" -type d -ipath '*/data/gtaudio' -prune -exec rm -rf {} +
mv "$music" "$work/game/data/GTAudio"
rm -rf "$work/x"
"$root/tools/mkpak.sh" "$work/game" "$out_pak"
