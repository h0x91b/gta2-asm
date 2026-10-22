#!/bin/sh
# Ghidra's own documentation, taken from the Homebrew install (docs/ghidra/README.md).
#
#   tools/ghidra-docs.sh            unpack the FULL set into ./ghidra-docs/ (git-ignored, ~520 MB):
#                                   javadoc HTML, all Python type stubs, the in-app help pages,
#                                   every bundled ghidra_scripts/ example, the class slides
#   tools/ghidra-docs.sh --curated  regenerate the committed subset in docs/ghidra/ (~3.5 MB)
#
# GHIDRA_HOME overrides the install (default: Homebrew formula `ghidra`).
set -eu

G="${GHIDRA_HOME:-/opt/homebrew/opt/ghidra/libexec}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$G/docs/GhidraAPI_javadoc.zip" ] || { echo "no Ghidra docs under $G (set GHIDRA_HOME)" >&2; exit 1; }
VER="$(sed -n 's/^application.version=//p' "$G/Ghidra/application.properties")"
STUBS="$G/docs/ghidra_stubs/typestubs/ghidra-stubs"

# Java packages agents script against; each becomes docs/ghidra/api/ghidra.<pkg>.pyi.
PACKAGES="
program.flatapi
app.script
program.model.data
program.model.listing
program.model.symbol
program.model.address
program.model.mem
program.model.pcode
program.model.lang
program.database.data
app.decompiler
app.cmd.function
app.services
app.util.cparser.C
util.task
framework.model
"

# Bundled example scripts worth reading, relative to $G/Ghidra/Features.
EXAMPLES="
Base/ghidra_scripts/AddCommentToProgramScript.java
Base/ghidra_scripts/IterateFunctionsScript.java
Base/ghidra_scripts/PrintStructureScript.java
Base/ghidra_scripts/RenameStructMembers.java
Base/ghidra_scripts/RenameVariable.java
Base/ghidra_scripts/BatchRename.java
Base/ghidra_scripts/FixupCompositeDataTypesScript.java
Base/ghidra_scripts/FindDataTypeConflictCauseScript.java
Decompiler/ghidra_scripts/CreateStructure.java
Decompiler/ghidra_scripts/ApplyClassFunctionSignatureUpdatesScript.java
Decompiler/ghidra_scripts/ShowConstantUse.java
"

if [ "${1:-}" = "--curated" ]; then
	D="$ROOT/docs/ghidra"
	rm -rf "$D/api" "$D/examples" "$D/CheatSheet.html" "$D/analyzeHeadlessREADME.md" "$D/WhatsNew.md"
	mkdir -p "$D/api" "$D/examples"
	for p in $PACKAGES; do
		cp "$STUBS/$(echo "$p" | tr . /)/__init__.pyi" "$D/api/ghidra.$p.pyi"
	done
	for e in $EXAMPLES; do
		cp "$G/Ghidra/Features/$e" "$D/examples/"
	done
	cp "$G/docs/CheatSheet.html" "$G/docs/WhatsNew.md" "$G/support/analyzeHeadlessREADME.md" "$D/"
	echo "$VER" > "$D/VERSION"
	du -sh "$D"
	exit 0
fi

OUT="$ROOT/ghidra-docs"
rm -rf "$OUT"
mkdir -p "$OUT/help" "$OUT/scripts"
echo "Ghidra $VER docs from $G" > "$OUT/VERSION"
unzip -q "$G/docs/GhidraAPI_javadoc.zip" -d "$OUT/javadoc"
cp -R "$G/docs/ghidra_stubs/typestubs" "$OUT/typestubs"
cp -R "$G/docs/GhidraClass" "$OUT/GhidraClass"
cp "$G/docs/"*.html "$G/docs/"*.md "$G/support/analyzeHeadlessREADME.md" "$OUT/"
# In-app help: help/topics/** inside each module's jar.
find "$G/Ghidra" -name '*.jar' | while read -r j; do
	if unzip -l "$j" 'help/topics/*' >/dev/null 2>&1; then
		unzip -qo "$j" 'help/topics/*' -d "$OUT/help/$(basename "$j" .jar)"
	fi
done
# Every bundled script, grouped by module.
find "$G/Ghidra" -type d -name ghidra_scripts | while read -r s; do
	m="$(echo "${s#"$G/Ghidra/"}" | cut -d/ -f2)"
	mkdir -p "$OUT/scripts/$m"
	cp -R "$s/." "$OUT/scripts/$m/"
done
du -sh "$OUT"
