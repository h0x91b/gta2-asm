# Ghidra's own documentation (12.1.4)

The Ghidra API reference, so agents writing scripts (`docs/ghidra-scripting.md`) look calls up
instead of guessing. Everything here is copied unchanged from the Homebrew install
(`/opt/homebrew/opt/ghidra/libexec`, formula `ghidra`, version in `VERSION`) by
`tools/ghidra-docs.sh --curated`. Do not edit it by hand: rerun the script after a Ghidra upgrade.

## Committed subset (this directory, ~3.3 MB)

| Path | What it is | Source in the install |
|---|---|---|
| `api/ghidra.<package>.pyi` | API reference for 16 packages: every class, method signature and the **full javadoc text** as docstrings. Python stub syntax (`jpype.JInt` = Java `int`), but class and method names are the Java ones. One file per package, so `grep -n 'def clearComponent' docs/ghidra/api/*.pyi` finds a method. | `docs/ghidra_stubs/typestubs/ghidra-stubs/<package>/__init__.pyi` |
| `examples/*.java` | 11 bundled scripts that do what we do: iterate functions, print/rename struct members, build a struct, rename variables, apply class signatures, use the decompiler | `Ghidra/Features/{Base,Decompiler}/ghidra_scripts/` |
| `CheatSheet.html` | GUI key bindings | `docs/` |
| `analyzeHeadlessREADME.md` | `analyzeHeadless` options (we use it via `re/tools/export.sh`) | `support/` |
| `WhatsNew.md` | 12.1 release notes | `docs/` |

Packages in `api/`: `program.flatapi` (FlatProgramAPI: `toAddr`, `getFunctionAt`, `start`/`end`,
...), `app.script` (GhidraScript), `program.model.data` (DataTypeManager, Structure, ArrayDataType,
...), `program.model.listing` (Program, Listing, Function, CommentType, ...),
`program.model.symbol` (SymbolTable, SourceType, ...), `program.model.address`,
`program.model.mem`, `program.model.pcode`, `program.model.lang`, `program.database.data`,
`app.decompiler`, `app.cmd.function`, `app.services`, `app.util.cparser.C`, `util.task`,
`framework.model` (DomainObject: `startTransaction`/`endTransaction`).

The javadoc HTML for those same packages is ~37 MB, too much for a public repo; the stubs carry
the same text in a tenth of the size.

## Full set, on demand (git-ignored)

```sh
tools/ghidra-docs.sh      # ~9 s, ~500 MB into ./ghidra-docs/
```

| Path | What it is |
|---|---|
| `ghidra-docs/javadoc/api/` | the complete javadoc (20 k files), e.g. `ghidra/program/model/data/Structure.html` |
| `ghidra-docs/typestubs/` | stubs for every package (`ghidra-stubs/`, `db-stubs/`, `generic-stubs/`, ...) |
| `ghidra-docs/help/<module>/help/topics/` | the in-app Help pages (F1), e.g. `Base/help/topics/GhidraScriptMgrPlugin/ScriptDevelopment.htm`, `Base/help/topics/FunctionPlugin/Variables.htm` (custom storage, `this` auto-parameter) |
| `ghidra-docs/scripts/<module>/` | every bundled `ghidra_scripts/` example (~330 files) |
| `ghidra-docs/GhidraClass/` | the Beginner/Intermediate/Advanced course slides |
| `ghidra-docs/*.html`, `*.md` | GettingStarted, ChangeHistory, CheatSheet, coding standards |

Not copied anywhere: `docs/ghidra_stubs/*.whl` and the `pypredef` duplicates of the stubs.

## Licence

Ghidra, its javadoc, type stubs, help and bundled scripts are Apache-2.0 (the install's
`LICENSE`; the stubs' `PKG-INFO` says `License: Apache-2.0`; every copied example carries the
Apache header). The full javadoc also bundles jQuery/jQuery UI (MIT) and DejaVu fonts, listed in
`ghidra-docs/javadoc/api/legal/`; none of those are committed. See `CREDITS.md`.
