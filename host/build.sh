#!/bin/sh
# Build the host (x86_64 Mach-O, runs under Rosetta 2). Requires nasm, Xcode CLT and
# an x86_64 SDL3 (default ~/.local/opt/sdl3-x86_64, override with SDL3_PREFIX).
#   ./build.sh            build ./host
#   ./build.sh --run      build + run (extra args go to the host, e.g. --run 120)
set -e
cd "$(dirname "$0")"
SDL3_PREFIX="${SDL3_PREFIX:-$HOME/.local/opt/sdl3-x86_64}"
[ -f "$SDL3_PREFIX/lib/libSDL3.dylib" ] || { echo "no x86_64 SDL3 at $SDL3_PREFIX" >&2; exit 1; }

rm -f host main.o
nasm -f macho64 ${NASMFLAGS:-} -o main.o main.asm
# Xcode linker explicitly (anaconda's ld64-530 shadows it on PATH).
# -pagezero_size 0x1000 -no_pie -image_base 0x200000000: keep the low 4 GB free so
# gta2.exe can later be mapped at 0x3F0000 (proven by spike/).
# minos 26.0 = what the local SDL3 build targets (avoids a minos mismatch warning).
# -rpath: libSDL3's install name is @rpath/libSDL3.0.dylib, so no DYLD_* needed.
"$(xcrun -f ld)" -arch x86_64 -platform_version macos 26.0 "$(xcrun --show-sdk-version)" \
  -syslibroot "$(xcrun --show-sdk-path)" -lSystem \
  -L"$SDL3_PREFIX/lib" -lSDL3 -rpath "$SDL3_PREFIX/lib" \
  -pagezero_size 0x1000 -no_pie -image_base 0x200000000 -e _main -o host main.o 2>&1 \
  | grep -v -e 'no platform load command' -e '-no_pie is deprecated' || true
[ -x host ] || exit 1

if [ "$1" = "--run" ]; then shift; exec arch -x86_64 ./host "$@"; fi
