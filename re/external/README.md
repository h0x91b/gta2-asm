# re/external — RE facts harvested from other GTA2 projects

What three external repos know about vanilla `gta2.exe` 11.44 (ImageBase `0x3F0000`),
diffed against our Ghidra export in `re/` (`~/ghidra/gta-2-recovered.gpr`). The aim: list
everything those repos know that our Ghidra DB does **not**, so it can be imported later.
Nothing here has been written to Ghidra; importing is the user's call.

Everything except this README and `tools/` is generated. Regenerate, do not edit.

## Sources

| repo | commit (pinned in `tools/fetch.sh`) | license | what was harvested |
|---|---|---|---|
| [izawartka/gta2-seuko-mod](https://github.com/izawartka/gta2-seuko-mod) | `25b198591f840b909dc5e3a38be880840d94c17d` (2026-09-05) | custom, README "License": free to modify and distribute **with credit to the original authors and a link to the repo**; no selling | `src/game/functions.h` (typed function pointers), `src/game/memory.h` (globals), `src/events/*.cpp` + `modules/` (hook sites, return addresses, fn-pointer slots), `src/game/gta2.h` (153 structs/unions, 55 enums) |
| [h0x91b/gta2-resurection](https://github.com/h0x91b/gta2-resurection) | `87e1d98f14a7a861d6e3518eb2b4885788592a8e` (2021-11-15) | MIT, © 2021 Arseniy Pavlenko | `gta2.h` (34 structs), `dllmain.cpp`, `ui.cpp`, `gta-helper.h`, `*.lua` (ffi casts), `gta2-resurected.ct` (Cheat Engine table), and **`gta2-resurected.exe.gzf`** (a Ghidra archive, see below) |
| [h0x91b/gta2-mouse](https://github.com/h0x91b/gta2-mouse) | `6c5351b67da14f1c08db2e9146b59afdfe583743` (2019-06-14) | MIT, © 2019 Arseniy Pavlenko | `gta2.segments.fixed.exe.h` (98 structs), `MainWindow.cpp` |

Only facts are stored (addresses, names, offsets, sizes, signatures, enum values) plus a
`file:line` reference into the pinned commit. No code from the repos is copied. Credit for
everything tagged `gta2-seuko-mod` goes to its authors (izawartka and contributors), see the link above.

`gta2-resurection.gzf` is its own source column: the `.gzf` is the user's own **2021 Ghidra DB**
of `gta2-resurected.exe` (the patched build; addresses identical to vanilla). `tools/export_gzf.sh`
imports it into a throwaway project under `$TMPDIR` and runs the same `re/tools/ExportGta2Re.java`;
the result is in `gzf/`, in the same format as `re/`. Its bytes differ from vanilla in 9 `.text`
and 14 `.rsrc` bytes (the user's old patches), as expected.

## Files

| file | rows are |
|---|---|
| `summary.md` | **start here**: counts per repo × status, all semantic conflicts, struct size conflicts |
| `import_candidates.csv` | one row per address that ours does not name or names differently: names from every source side by side, how many agree, a suggested name (seuko-mod preferred), signature, byte check |
| `functions.csv` | function addresses: name, calling convention, signature, status vs ours, our name/signature, byte check |
| `globals.csv` | globals and function-pointer slots (`kind=fnptr_slot`) |
| `code_refs.csv` | hook sites, return addresses, asm constants inside functions, with our containing function and the instruction at the site |
| `struct_fields.csv` | every named struct field: offset, size, type, status vs the same struct in `re/gta2_types.h` |
| `struct_diff.md` | per-struct summary (sizes, counts) and every field conflict |
| `enums.csv` | enum constants vs ours |
| `ct_entries.csv` | all 147 Cheat Engine entries incl. pointer chains (`[base]+off -> +off`), heap-only ones marked |
| `gzf_comments_new.csv` | comments in the 2021 DB that our current DB lacks |
| `gzf/` | the 2021 DB export itself |
| `stats.txt` | raw counts of the last run |

## Statuses

- **NEW** — ours has nothing named at that address / no such struct, field or constant.
  `ours: typed but unnamed` in `detail` means ours has a signature/type but no name.
- **SAME** — ours has it under the same name. Names are compared normalised (case, `_`,
  `ptrTo`/`p`/`fn` prefixes, enum-name prefixes dropped), so `pGame` = `ptrToGame`, `do_blood` = `doBlood`.
- **CONFLICT** — same address, different name; or a different calling convention (only when our
  signature is hand-set); or ours has the same name at another address; or the address falls inside
  one of our functions (function boundary disagrees); for structs: different name/size at the same
  offset, or a field overlapping one of ours. Column `severity` splits them:
  - `naming` — the same thing in another naming scheme (`window_width` vs `WindowedWidth`). Ignore.
  - `semantic` — the sources really disagree. These need a human.

## How it was checked

- **Byte check** (`byte_check`): every NEW/CONFLICT function address in `.text` was checked against
  `gta2/gta2.exe` bytes — a real MSVC function start follows `90`/`CC` padding, a `ret`, a `jmp`, or a
  switch jump table. 273 checked, 2 suspect, both in the 2021 DB and both explained:
  `0x004d11a6 injectBack` is the user's code cave in the patched exe (vanilla has `90` padding there)
  and `0x003f113c` is a bogus typed entry. All seuko-mod and resurection/mouse addresses pass, so
  no wrong-version addresses were found.
- **Hook sites**: for seuko's call hooks the byte at the site must be `E8` (call); the culling hooks
  sit on 6-byte `jz near` (`0F 84`) which the mod overwrites on purpose, recorded in `detail`.
  `bytes` shows the decoded call target and our name for it.
- **Struct layouts** are measured by clang (`i686-pc-windows-msvc`, `-fdump-record-layouts`), not
  by hand, and **packed** (`#pragma pack(1)`), which is what Ghidra means by its unaligned structs
  and how resurection compiles them. seuko-mod compiles its header with MSVC default packing; the 10
  structs where that moves fields are marked `ALIGN_SENSITIVE(compiled by seuko-mod: size N)`.
  Placeholder fields (`field_0x..`, `undefined`, `pad`, `unk`, `unused`) are skipped; note that
  seuko's own placeholder names are partly stale (`Car.field_0xb9` sits at `0xb6`).

## Counts (this run; `summary.md` has the full table)

| | seuko-mod | resurection (src + .ct) | mouse | 2021 Ghidra DB (.gzf) |
|---|---|---|---|---|
| functions NEW / SAME / CONFLICT | 62 / 1 / 9 | 3 / 1 / 1 | 1 / 2 / 1 | 130 / 40 / 66 |
| globals + slots NEW / SAME / CONFLICT | 23 / 8 / 20 | 3 / 21 / 10 | 0 / 3 / 0 | 125 / 89 / 37 |
| hook sites / code refs (all NEW) | 98 | 2 | 0 | 0 |
| structs NEW / same size / size conflict | 85 / 56 / 12 | 29 / 2 / 3 | 24 / 63 / 11 | 29 / 9 / 3 |
| named struct fields NEW / SAME / CONFLICT | 680 / 187 / 45 | 82 / 6 / 16 | 128 / 211 / 28 | 82 / 29 / 17 |
| enum constants NEW / SAME / CONFLICT | 1054 / 244 / 38 | 35 / 0 / 0 | 324 / 361 / 8 | 35 / 0 / 0 |

`import_candidates.csv`: 254 addresses (99 functions NEW, 69 function CONFLICT, 34 globals NEW,
52 globals CONFLICT).

## What is worth knowing

1. **seuko-mod is the big win**: 62 new function names with full typed signatures, 85 structs we
   lack (`Player` 2140 B with 44 named fields, `Camera`, `CarPhysics`, `GameObject`, `SVideo`,
   `Cheats` — 92 named debug flags at `0x5ead51`, `GlobalSettings`, `Keyboard`, `TrafficManager`, …)
   and 1054 enum constants.
2. **The renderer seam is partly mapped already.** Function-pointer slots the game fills from
   `d3ddll.dll` / `dmavideo.dll`: `0x005952a8` gbh_InitDLL (renderer base = value − `0xe053f0`),
   `0x005952bc` DrawTile, `0x005952c4` DrawQuad (typed: `void __stdcall(uint32 flags, DWORD sprite,
   GTAVertex*, uint16 flags2)`), `0x005952d0` DrawTriangle, `0x00595044` Vid_FlipBuffers,
   `0x00595064` Vid_ClearScreen (typed); `GTAVertex` (32 B) and `SVideo` (1220 B, 34 fields) are in
   seuko's `gta2.h`. Our DB already names `0x5952b4` gbh_SetWindow and the two Vid_ slots.
3. **The 2021 DB holds about 40 named functions the current DB lost**, e.g. `0x0045c1f0 GameTick`
   (also named by seuko and resurection), `0x004a4930 SetKeyState`, `0x004cb530/550 Hide/ShowMouseCursor`,
   `0x004d2e50 InitVideoDll`, `0x00472e90 PauseGame`, `0x004a5c50 PlayerMovement`, plus 196 comments.
4. **Our `FireFromGun` (0x4d0530) is far too long**: three sources put functions inside it
   (`0x004d0a00` the window procedure, per resurection's `ui.cpp` and the 2021 DB). Fix its boundary in Ghidra.

## Top conflicts that need the user's judgment

Functions (seuko-mod vs ours):

| address | seuko-mod | ours | note |
|---|---|---|---|
| `0x00461de0` | `InitGame` | `MainMenu` | ours came from Ghidra analysis, not by hand; the 2021 DB has `MainMenu` at `0x453e20` and `InitGame` at `0x45c4d0` (where ours also has `initGame`). Likely ours is wrong. |
| `0x00426ac0` | `SpawnCar` (thiscall, TrafficManager*) | `relToCarColliding` (stdcall) | ours is a `relTo` guess; gta2-mouse puts `SpawnCar` at `0x426e10` instead |
| `0x0043df60` | `CreatePed` (stdcall, no args) | `RecycleOldestPedAndGiveHim100Health` (fastcall) | 2021 DB: `CreateNewPedAndSetHealth`. Calling convention also differs. |
| `0x004d0530` | `ShootFromWeapon` (thiscall) | `FireFromGun` (fastcall) | same meaning; convention differs, and see the boundary issue above |
| `0x004ca440` | `DrawUI` | `drawScene` | |
| `0x004cd7f0` | `GetCarWeaponStruct` | `getWeaponPtrFromCarByIndex` | 2021 DB: `GetCarByType` |
| `0x00425590` | `TurnOnCarLights` | `relToEmergencyCarLights` | ours is a `relTo` guess |

Globals (seuko-mod vs ours): `0x005e3cc4` MainCamera vs ours `ptrToGameStats` (typed `GameStats*`);
`0x005e4ca4` TrafficManager vs `ptrToCarManager`; `0x005e4ca0` CarsManager vs `relToCars`;
`0x00662c08` MapBlocks vs `relToCounters` (typed `SCR_STRING_HEADER*`, surely wrong);
`0x0066a3b4` PedGameObjectManager vs `ptrTo_relSprites`; `0x00595014` IsFullScreen vs `start_mode`.

Structs: `Car` is 168 B in ours, 185 (seuko) / 188 (resurection, 2021 DB) elsewhere, with 10 field
conflicts (seuko `+0x50 Sprite* sprite` vs ours `Position* position`, `+0x58 CarPhysics*` vs
`MaybeCarEngine*`, `+0x84 carModel` 4 B vs 1 B); `Ped` +0x164..+0x1ac (`PedGroup* group`,
`GameObject* gameObject`, `SCR_Vector3 position` vs ours `ElvisOrTarget`, `pedSprite`, `x`);
`Sprite` 73 B (seuko) vs 256 B in ours — probably different structs under one name;
`SpriteEntry` 22 B in ours is the known `uint16` typo (`re/README.md`), seuko has 8.

The 2021 DB conflicts (`gta2-resurection.gzf` rows) are mostly the user's own renames between 2021
and now; the current name should usually win unless it is a `relTo` guess.

## Regenerate

```sh
re/external/tools/run.sh            # fetch pinned repos, export the .gzf, harvest + diff
SKIP_GZF=1 re/external/tools/run.sh # without Ghidra: reuse gzf/
python3 -I re/external/tools/harvest.py   # only the diff
```

Needs `git`, `clang` (Apple clang 17 used), Python 3, and Ghidra 12.1.4 for the `.gzf` step.
Clones go to `.external/` (git-ignored). Output is deterministic. After `re/` is regenerated, rerun
`harvest.py` to refresh statuses.
