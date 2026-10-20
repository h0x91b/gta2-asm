#!/usr/bin/env bash
# Regenerates re/*.csv, re/*.inc and re/gta2_types.h from the user's Ghidra project.
#
# The original project is never opened: it is copied into $GHIDRA_WORK (default
# $TMPDIR/gta2-ghidra-work)
# and the copy is opened read-only, so Ghidra cannot save or upgrade anything.
#
#   re/tools/export.sh [path/to/project.gpr]
#
# Env: GHIDRA_HOME (dir containing support/analyzeHeadless), PROGRAM (default below),
#      VANILLA (path to vanilla gta2.exe for the mapping check), GHIDRA_WORK.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GPR="${1:-$HOME/ghidra/gta-2-recovered.gpr}"
VANILLA="${VANILLA:-$REPO/gta2/gta2.exe}"
PROGRAM="${PROGRAM:-gta2.segments.fixed.exe}"
OUT="$REPO/re"
# Ghidra 12 rejects project paths with a dot-leading element (e.g. ~/.dev3.0/...),
# so the working copy lives under TMPDIR, not in the repo.
WORK="${GHIDRA_WORK:-${TMPDIR:-/tmp}/gta2-ghidra-work}"
WORK="${WORK%/}"

if [[ -z "${GHIDRA_HOME:-}" ]]; then
  for d in /opt/homebrew/opt/ghidra/libexec /opt/homebrew/Caskroom/ghidra/*/ghidra_*_PUBLIC; do
    [[ -x "$d/support/analyzeHeadless" ]] && GHIDRA_HOME="$d" && break
  done
fi
HEADLESS="${GHIDRA_HOME:?set GHIDRA_HOME}/support/analyzeHeadless"

SRC_DIR="$(dirname "$GPR")"
NAME="$(basename "$GPR" .gpr)"
[[ -d "$SRC_DIR/$NAME.rep" ]] || { echo "no $SRC_DIR/$NAME.rep" >&2; exit 1; }

rm -rf "$WORK"
[[ -f "$VANILLA" ]] || { echo "vanilla exe not found: $VANILLA (set VANILLA=)" >&2; exit 1; }
mkdir -p "$WORK"
cp -Rp "$GPR" "$SRC_DIR/$NAME.rep" "$WORK/"
rm -f "$WORK/$NAME.lock" "$WORK/$NAME.lock~"
# The project was created by another OS user; headless refuses to open a project
# it does not own. Only the copy is touched.
sed -i.bak "s/NAME=\"OWNER\" TYPE=\"string\" VALUE=\"[^\"]*\"/NAME=\"OWNER\" TYPE=\"string\" VALUE=\"$(whoami)\"/" \
  "$WORK/$NAME.rep/project.prp"

"$HEADLESS" "$WORK" "$NAME" -process "$PROGRAM" -noanalysis -readOnly \
  -scriptPath "$REPO/re/tools" -postScript ExportGta2Re.java "$OUT" "$WORK" \
  > "$WORK/headless.log" 2>&1 || { tail -40 "$WORK/headless.log" >&2; exit 1; }

grep -q "ERROR" "$WORK/headless.log" && { grep "ERROR" "$WORK/headless.log" >&2; exit 1; }
cat "$OUT/stats.txt"

# Address mapping: Ghidra's bytes must equal the vanilla exe's sections.
python3 -I "$REPO/re/tools/check_mapping.py" "$VANILLA" "$WORK/blocks"

# Layout self-check: every struct size and member offset must match Ghidra's.
if command -v clang >/dev/null; then
  clang -target i686-pc-windows-msvc -fsyntax-only -Wno-pragma-pack -I "$OUT" "$WORK/gta2_types_check.c"
  echo "gta2_types.h: layout check OK"
fi
if command -v nasm >/dev/null; then
  nasm -f bin -I "$OUT/" -o /dev/null "$WORK/gta2_types_check.asm"
  echo "gta2_*.inc: nasm OK"
fi
