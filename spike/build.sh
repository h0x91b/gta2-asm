#!/bin/sh
# Build and run the Rosetta/LDT spike. Requires: nasm (brew install nasm), Xcode CLT.
#   ./build.sh                    build + run core spike
#   ./build.sh path/to/gta2.exe   also map gta2.exe sections at 0x3F0000 (read-only use)
#   ./build.sh --build-only
set -e
cd "$(dirname "$0")"
nasm -f macho64 ${NASMFLAGS:-} -o spike.o spike.asm
# Xcode linker explicitly (a conda/other ld may shadow it in PATH).
# -pagezero_size 0x1000: free the low 4 GB; -no_pie + high image_base: keep the
# host image out of 0x3F0000.. (PIE slides it into low memory otherwise).
"$(xcrun -f ld)" -arch x86_64 -platform_version macos 11.0 11.0 \
  -syslibroot "$(xcrun --show-sdk-path)" -lSystem \
  -pagezero_size 0x1000 -no_pie -image_base 0x200000000 -e _main -o spike spike.o 2>&1 \
  | grep -v 'no platform load command' || true
[ "$1" = "--build-only" ] || exec arch -x86_64 ./spike "$@"
