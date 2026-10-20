# re/ — GTA2 reverse-engineering export

Plain-text dump of the Ghidra annotations for vanilla `gta2.exe`, so you can grep
addresses, names and struct layouts without running Ghidra. Everything here except
`tools/` and this README is generated — do not edit it by hand, regenerate instead.

## Address mapping: 1:1 with vanilla gta2.exe

Source: program **`gta2.segments.fixed.exe`** in the Ghidra project
**`~/ghidra/gta-2-recovered.gpr`** (the user's current base), exported with **Ghidra 12.1.4**
(Homebrew formula). The older `~/ghidra/gta2.gpr` project (Ghidra 11.2.1, DB last saved
2019) yields a byte-identical export — same annotations.

Vanilla `gta2.exe` (sha1 `2d7a779780c4f092950c09221753aa4d4af2a31c`) has image base
**0x3F0000** (not the usual 0x400000) and no relocations, so it must be loaded at exactly
that base. The Ghidra program uses the same base and section layout, and its `.text`,
`.rdata`, initialized `.data` and `.rsrc` bytes are identical to the file (0 differing
bytes, checked block by block). Only the PE header differs (the "segments fixed" edit).
**Every address in these files is the absolute VA in vanilla gta2.exe — no offset.**

| section | VA range |
|---|---|
| `.text`  | 0x3F1000–0x56DBBF |
| `.rdata` | 0x56E000–0x57B6CB |
| `.data`  | 0x57C000–0x676717 (raw file data up to 0x595FFF, the rest is bss) |
| `.rsrc`  | 0x677000–0x6799AF |

The old `gta2.gpr` also holds `gta2.segments.fixed2.exe` (same bytes, an extra `.new`
section, no names or types) and `miss2.exe` (the official mission-script compiler, base
0x400000, 577 named functions — not exported here).

## Files

| file | what |
|---|---|
| `functions.csv` | named functions: address, name, calling convention, size, full prototype. `name_source` = `USER_DEFINED` (named by hand) or `ANALYSIS` (Ghidra library/FID match, e.g. CRT `fread`) |
| `functions_typed_unnamed.csv` | `FUN_xxxxxxxx` functions whose signature was set by hand |
| `globals.csv` | hand-named labels with section, data type and size; `in_function` set when it is a code label inside a function |
| `globals_typed_unnamed.csv` | `DAT_`-style globals with a user-defined type applied |
| `imports.csv` | IAT slot address → DLL!function (what a host must patch) |
| `comments.csv` | plate/pre/eol/post/repeatable comments with the containing function |
| `gta2_types.h` | user types as C (structs, unions, enums, typedefs, function types) plus their dependencies. Packed, gaps spelled out, offset on every member |
| `gta2_types.inc` | same structs as NASM `struc` (`Name.field`, `Name_size`), unions as `Name.member equ 0`, enums as `Enum.VALUE equ n` |
| `gta2_addresses.inc` | NASM `equ`s: `fn_<name>` functions, `g_<name>` globals, `lbl_<func>__<name>` code labels (`::` → `__`, other non-identifier chars → `_`) |
| `stats.txt` | counts from the last export |

Examples: `grep -i ped re/functions.csv`, `grep -n 'struct Car ' re/gta2_types.h`,
`%include "re/gta2_addresses.inc"` then `call fn_SomeFunction`.

## Counts (last export)

| | named (exported) | auto-named (skipped) |
|---|---|---|
| functions | **733** (399 by hand + 333 library/analysis + 1 imported) | 3871 `FUN_` (136 of them with a hand-set signature → `functions_typed_unnamed.csv`) |
| labels/globals | **281** (273 by hand + 8 imported) | 58725 `DAT_`/`LAB_`; 11197 analysis labels (strings, switch tables) skipped; 108 `DAT_` with a user type → `globals_typed_unnamed.csv` |
| types | **160**: 105 structs, 5 unions, 32 enums, 12 typedefs, 6 function types | Ghidra-generated PE/DOS/PDB/Demangler types and the Windows type archive (only pulled in as dependencies) |
| imports | 216 | |
| comments | 889 | |

## Gotchas in the source data

- `SpriteEntry.pad` (/_STY) is typed `uint16`, which in Ghidra is a **16-byte** integer,
  so Ghidra sizes `SpriteEntry` at 22 bytes. Probably meant `ushort` (8-byte struct).
  The export reproduces Ghidra faithfully; fix it in Ghidra and regenerate.
- Ghidra built-in names are kept (`undefined4`, `dword`, `uint`…) and typedef'd at the top
  of `gta2_types.h`; `undefinedN` means "size known, type not".
- Enum constants that look like compiler macros (`_MSC_VER`, `_M_IX86`…) or collide with
  another enum's constant are prefixed `EnumName__`.
- Bitfields are emitted as raw storage bytes with the bit layout in a comment.

## Regenerate

```sh
brew install ghidra                              # 12.1.4 used for this export
re/tools/export.sh [~/ghidra/gta-2-recovered.gpr]  # PROGRAM=..., VANILLA=path/to/gta2.exe
```

The script copies the project into `$TMPDIR/gta2-ghidra-work` (Ghidra 12 refuses project
paths with a dot-leading element such as `~/.dev3.0/…`), patches the copy's owner to the
current OS user (headless refuses a project owned by someone else), and opens it with
`analyzeHeadless -readOnly -noanalysis` — the original project is never opened or
modified, and its lock (the GUI may have it open) does not matter. Only saved work is
exported: save in the GUI first. It then dumps every memory block and checks it
byte-for-byte against the sections of `$VANILLA` (default `gta2/gta2.exe`), and compiles a generated `_Static_assert` file (sizeof/offsetof of
every struct member, clang `i686-pc-windows-msvc`) and an `%if`/`%error` file for the NASM
`struc`s, so a layout mismatch fails the export.
