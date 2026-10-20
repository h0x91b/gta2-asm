#!/usr/bin/env bash
# Exports the Ghidra archive shipped in gta2-resurection (gta2-resurected.exe.gzf, the
# user's 2021 Ghidra DB) with the same ExportGta2Re.java as re/, into re/external/gzf/.
# The .gzf is imported into a throwaway project under TMPDIR; nothing else is touched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
EXT="${EXT:-$REPO/.external}"
GZF="$EXT/gta2-resurection/gta2-resurected.exe.gzf"
OUT="$REPO/re/external/gzf"
WORK="${GHIDRA_WORK:-${TMPDIR:-/tmp}/gta2-gzf-work}"; WORK="${WORK%/}"
if [[ -z "${GHIDRA_HOME:-}" ]]; then
  for d in /opt/homebrew/opt/ghidra/libexec /opt/homebrew/Caskroom/ghidra/*/ghidra_*_PUBLIC; do
    [[ -x "$d/support/analyzeHeadless" ]] && GHIDRA_HOME="$d" && break
  done
fi
[[ -f "$GZF" ]] || { echo "missing $GZF (run fetch.sh)" >&2; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK/proj" "$WORK/out"
cp "$GZF" "$WORK/"
"${GHIDRA_HOME:?set GHIDRA_HOME}/support/analyzeHeadless" "$WORK/proj" gzf -import "$WORK/$(basename "$GZF")" \
  -noanalysis -scriptPath "$REPO/re/tools" -postScript ExportGta2Re.java "$WORK/out" "$WORK" \
  > "$WORK/headless.log" 2>&1 || { tail -40 "$WORK/headless.log" >&2; exit 1; }
mkdir -p "$OUT"
# imports.csv is identical to re/imports.csv, the .inc files duplicate the .h/.csv
for f in functions.csv functions_typed_unnamed.csv globals.csv globals_typed_unnamed.csv \
         comments.csv gta2_types.h stats.txt; do
  cp "$WORK/out/$f" "$OUT/$f"
done
python3 -I "$REPO/re/tools/check_mapping.py" "$REPO/gta2/gta2.ebin" "$WORK/blocks" || \
  echo "note: the gzf is of the patched gta2-resurected.exe, a few differing .text/.rsrc bytes are expected" >&2
echo "gzf exported to $OUT"
