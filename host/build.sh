#!/bin/sh
# Build both host binaries (x86_64 Mach-O, run under Rosetta 2). Requires nasm, Xcode
# CLT and an x86_64 SDL3 (default ~/.local/opt/sdl3-x86_64, override with SDL3_PREFIX).
#   ./build.sh                  build ./host (SDL hello window) and ./loader (PE loader)
#   ./build.sh --run [N]        build + run the hello window (quit after N frames)
#   ./build.sh --load [args]    build + run the loader on ../gta2/gta2.ebin
#                               (e.g. --load --entry: also jump to the PE entry point)
set -e
cd "$(dirname "$0")"
SDL3_PREFIX="${SDL3_PREFIX:-$HOME/.local/opt/sdl3-x86_64}"
[ -f "$SDL3_PREFIX/lib/libSDL3.dylib" ] || { echo "no x86_64 SDL3 at $SDL3_PREFIX" >&2; exit 1; }

# Xcode linker explicitly (anaconda's ld64-530 shadows it on PATH).
# -pagezero_size 0x1000 -no_pie -image_base 0x200000000: keep the low 4 GB free so
# gta2.exe can be mapped at 0x3F0000 (proven by spike/).
# minos 26.0 = what the local SDL3 build targets (avoids a minos mismatch warning).
# -rpath: libSDL3's install name is @rpath/libSDL3.0.dylib, so no DYLD_* needed.
link() {
  out=$1; shift
  "$(xcrun -f ld)" -arch x86_64 -platform_version macos 26.0 "$(xcrun --show-sdk-version)" \
    -syslibroot "$(xcrun --show-sdk-path)" -lSystem "$@" \
    -pagezero_size 0x1000 -no_pie -image_base 0x200000000 -e _main -o "$out" 2>&1 \
    | grep -v -e 'no platform load command' -e '-no_pie is deprecated' || true
  [ -x "$out" ] || exit 1
}

rm -f host main.o loader loader.o
nasm -f macho64 ${NASMFLAGS:-} -o main.o main.asm
link host main.o -L"$SDL3_PREFIX/lib" -lSDL3 -rpath "$SDL3_PREFIX/lib"
nasm -f macho64 ${NASMFLAGS:-} -I. -o loader.o loader.asm
link loader loader.o   # libSystem only: SDL3 is dlopen'ed after the low 4 GB is mapped

case "$1" in
  --run)  shift; exec arch -x86_64 ./host "$@" ;;
  --load) shift; exec arch -x86_64 ./loader ../gta2/gta2.ebin "$@" ;;
esac
