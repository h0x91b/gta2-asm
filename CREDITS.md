# Credits and sources

This project runs DMA Design's original `gta2.exe` and stands on years of other people's
reverse engineering. Every address, hook site, technique, file and document that came from
somewhere else is listed here with a link, so anyone can go back to the source and dig
further. In the code, the comment next to a ported address names the source file it came
from (e.g. `; From gta2-seuko-mod by izawartka (…), src/events/camera-pos-apply.cpp @25b1985`).

License terms below are quoted as each source states them; this is not legal advice.

## The game

### Grand Theft Auto 2 — DMA Design / Rockstar Games

- **What we use:** the vanilla `gta2.exe` and its data files, which the host loads and runs
  unmodified (`AGENTS.md`, "Target binary"). Nothing of the game is in this repository: it is
  read at run time from the user's own copy (`data.pak`, git-ignored).
- **Terms:** the game and its files are © Rockstar Games. Bring your own copy.

### GTA2 11.44 — community bug-fix build by Vike the Hube, distributed by gtamp.com

- **Where:** the installer at [gtamp.com/gta2](https://gtamp.com/gta2/); the change log is
  `gta2-changelog.txt` in the game folder ("Bugfixed version of GTA2 by Vike the Hube", 11.44
  dated 2013-09-07).
- **What we use:** this exact build is our target (`gta2.exe` SHA-256 `dd5381c7…a5a2`); every
  address in the repository is a virtual address of it.

### DMA Design's format and scripting documents (via gtamp.com)

- **Where:** [gta2formats.zip](https://gtamp.com/GTA2/gta2formats.zip) (GTA2 Map Format, Style
  Format, …), [gta2script.7z](https://gtamp.com/GTA2/gta2script.7z) (scripting manual, example
  missions, `miss2.exe`), [gta2manual.pdf](https://gtamp.com/GTA2/gta2manual.pdf),
  [gta2maps.pdf](https://gtamp.com/GTA2/gta2maps.pdf), [gtamp.com/text/](https://gtamp.com/text/).
- **What we use:** the specs and example missions are committed in `docs/formats/specs/`
  (URLs, sizes, SHA-256 in `docs/formats/specs/sources.json`); the binaries and PDFs are listed,
  not committed, in `docs/reference.md`. They back `tools/formats/`, `docs/formats/lessons.md`,
  `docs/formats/loader-map.md` and the notes in `docs/formats/findings/`.
- **Terms:** DMA Design's documents as published on gtamp.com; their own disclaimer is
  `docs/formats/specs/scripting/README!.txt`.

## Reverse-engineering projects

### gta2-seuko-mod — izawartka (with research support by h0x91b)

- **URL:** https://github.com/izawartka/gta2-seuko-mod — surveyed and pinned at
  `25b198591f840b909dc5e3a38be880840d94c17d` (2026-09-05).
- **Authors:** izawartka (the mod), h0x91b (research support), per its
  [README Credits](https://github.com/izawartka/gta2-seuko-mod/blob/25b198591f840b909dc5e3a38be880840d94c17d/README.md#L110-L113).
- **What we took:**
  - **Addresses and types** from `src/game/functions.h`, `src/game/memory.h`, `src/game/gta2.h`
    (Ped, Car, Player, Camera, enums such as `PED_REMAP`, `CAR_MODEL4`), harvested into
    `re/external/` and partly imported into our Ghidra database (`re/external/README.md`).
  - **Hook sites** from `src/events/*.cpp`, used in `host/w32_hooks.asm` and
    `host/debug_menu.asm`: camera zoom `CameraPosApply` 0x41F3E9 (`camera-pos-apply.cpp`), shadow
    offset 0x4BE394 (`scale-shadow.cpp`), the render-queue safety valve at `DrawMapLayer` call
    0x472535 (`draw-map-layer.cpp`, its "low zoom crashes" and custom render queue), `DrawUI`
    call 0x45A61F (`draw-ui.cpp`).
  - **Hook kinds:** our `CALLHOOK` and `JMPHOOK` follow its `FunctionCallHook` / `JumpHook`
    (`src/hook-types/`).
  - **Debug-menu features** in `host/debug_menu.asm`: quick save `SaveGame` 0x47EF40
    (`save-game.cpp`), all weapons via `AddWeapon` 0x43E4B0 (`get-all-weapons.cpp`), money
    (`player-stats-menu.cpp`), wanted level and its lock (`cop-value-utils.cpp`,
    `player-appearance.cpp`), skins and car names (`lists-utils.cpp`, `gta2.h`), car spawn
    (`SpawnCar` 0x426AC0, `spawn-car.cpp`), car repair / explode (`fix-car-utils.cpp`,
    `explode-last-car.cpp`), and the menu drawn with `DrawGTAText` 0x4CC100
    (`src/modules/ui/components/text.cpp`).
  - **Native debug flags** (`host/config.asm`, `config.example.yaml`): the idea, the flag list
    (`categorized-native-cheats-data.cpp`, `Cheats` at 0x5EAD51), and which flags are risky.
  - **Game lifecycle:** `InitGame` 0x461DE0 / `DeinitGame` 0x462060 and `ptrToGame` 0x5EB4FC
    (`host/w32_renderer.asm`); its DeinitGame call-site map (six sites) was surveyed for the
    quit-to-menu work.
  - **Mouse control** (`src/modules/modmenu/cheats/mouse-control/`,
    `src/events/keyboard-state-update.cpp`, hook 0x4A4934 inside `SetKeyState`): reviewed as
    prior art for `host/player_move.asm` (Seq 37); it turns the ped with virtual left/right
    keys, which our mouse turning bypasses. No code or address taken.
  - `WorldPointToScreen`, `PedSetObjective`, `PedManager` (`host/debug_paths.asm`),
    `InitMouseExclusive`, `GameWindow` (`host/w32_dinput.asm`).
- **License as stated** ([README#L123-L125](https://github.com/izawartka/gta2-seuko-mod/blob/25b198591f840b909dc5e3a38be880840d94c17d/README.md#L123-L125)):
  "You can modify and distribute this mod freely as long as you credit the original authors and
  provide a link to this repository. You are NOT allowed to sell this mod or any modified
  versions of it." No LICENSE file. Our code reimplements from the facts and credits the source
  file at each feature.

### gta2-resurection — h0x91b (Arseniy Pavlenko)

- **URL:** https://github.com/h0x91b/gta2-resurection — pinned at
  `87e1d98f14a7a861d6e3518eb2b4885788592a8e` (2021-11-15).
- **What it is:** the user's earlier RE and modding project for the same 11.44 build (a DLL in
  a patched exe, Lua/LuaJIT mods, ImGui over D3D11).
- **What we took:** struct layouts from `gta2-resurection/gta2.h` and `gta2-def.lua`, addresses
  from `gta2-functions.lua`, `dllmain.cpp`, `ui.cpp`, `gta-helper.h`; the Cheat Engine table
  `gta2-resurected.ct` (live data addresses, e.g. the debug-flag bytes and window size); and the
  **Ghidra archive `gta2-resurected.exe.gzf`**, the 2021 Ghidra database, exported to
  `re/external/gzf/` (names such as `GameTick`, `InitVideoDll`, `WndProc`, `SetZ`,
  `do_show_junc_id`, the debug-flag names used in `host/debug_menu.asm`). Harvest:
  `re/external/`.
  Its mouse rotation (`mod-mouse-rotation.lua`, the `SetKeyState` 0x4A4930 hook in
  `dllmain.cpp` @87e1d98, virtual left/right keys) is credited as prior art in
  `host/player_move.asm`; no code taken.
- **License:** MIT, © 2021 Arseniy Pavlenko.

### gta2-mouse — h0x91b (Arseniy Pavlenko)

- **URL:** https://github.com/h0x91b/gta2-mouse — pinned at
  `6c5351b67da14f1c08db2e9146b59afdfe583743` (2019-06-14).
- **What it is:** the user's first GTA2 mod: mouse aiming as an injected DLL plus an xdelta
  patch for the exe.
- **What we took:** Ghidra-exported types `gta2.segments.fixed.exe.h` (the same program as in
  the user's Ghidra project, see `re/README.md`), addresses from `MainWindow.cpp`
  (`ptrToGame`, `ptrToPedManager`, `GetSaveSlotByIndex`, …), harvested into `re/external/`.
  Its mouse aiming (`MainWindow.cpp` @6c5351b: cursor angle written to the ped's heading
  GameObject+0x40) is the prior art for `host/player_move.asm`, which turns through
  `Player.turnRate` instead because the game's walker overwrites a written heading every tick.
- **License:** MIT, © 2019 Arseniy Pavlenko.

### gta2_re — CriminalRETeam

- **URL:** https://github.com/CriminalRETeam/gta2_re — cited at revision
  `51d2ce3d4b8d32b6d48ff5c938cc98521061691b`.
- **What it is:** a decompilation/re-implementation of GTA2 **10.5** (PC), per its description.
- **What we took:** function names and constants cited by `docs/formats/findings/`
  (`vehicle-data.md`, `sound-banks.md`, `collision-economy.md`, `ped-animation.md`, …) and
  `docs/formats/GTA2_REFERENCE_RU.md`. Its `_XXXXXX` name suffixes are 10.5 addresses, **not**
  11.44 VAs (checked in `docs/formats/loader-map.md`): use them as search keys only. For the
  mission-script engine (`docs/re/script-engine.md`, at revision
  `825f5498b1ae20ac39d39f9a206df2b4d1a6a34f`) we took the `SCRCMD` opcode enum, the
  `ExecOpCode`/`PreExecOpCode` switch grouping, `SCR_*` argument struct names, and the names of
  handler callees, each matched against the 11.44 binary before it was applied in Ghidra.
- **License:** none stated on GitHub.

### Epic GTA2 Script Decompiler — T.M. (2011), and Valps' fork

- **URLs:** https://gitlab.com/classic-gta/gta2-scr-decompiler (T.M.'s original, cited at
  revision `df4063f08784d0840e6cc97ae6e528d59c3d44d9`) and
  https://github.com/Valps/gta2-tm-scr-decompiler (Valps' fork, revision
  `1ec46d69a35252a77e9108f1ccec718a4d665be8`).
- **What it is:** a C++ `.scr` → `.mis` decompiler for GTA2 mission scripts.
- **What we took:** facts only, transcribed into our own TypeScript (`tools/formats/scr-mis-ops.ts`,
  `scr-consts.ts`): the argument layout of each opcode, the DMA constant-name lists
  (`scr_strings.h`: cars, objects, weapons, objectives, …) and the generated-variable prefixes.
  No source code was copied; the control-flow rebuild is our own (`docs/re/script-engine.md`,
  "Decompiler"). Every layout was then checked against DMA's bil sources, and a local build of the
  fork served as a second oracle.
- **License:** T.M.'s custom licence: non-commercial use, altered versions must be marked and
  their source published, credit required (this entry). Valps' fork: GPL-3.0.

### OpenGTA2 — ikkentim

- **URL:** https://github.com/ikkentim/opengta2 — an open-source GTA2 re-implementation (C#,
  MonoGame).
- **What we took:** cross-checks for the ped animation and sound-bank notes
  (`docs/formats/findings/ped-animation.md`, `sound-banks.md`: `Ped.cs`, `SoundEntry.cs`).
- **License:** MIT.

### WidescreenFixesPack — ThirteenAG

- **URL:** https://github.com/ThirteenAG/WidescreenFixesPack
- **Mentioned only:** gta2-seuko-mod defers widescreen to it; nothing taken yet. Worth a survey
  if 16:9 support comes up.
- **License:** MIT.

### Other community references

Cited in the user-supplied notes `docs/formats/GTA2_REFERENCE_RU.md` and `GTA2_ECONOMY_RU.md`
(mechanics, missions, economy), not used by code:
[gtamp.com](https://gtamp.com/gta2/) tutorials and tools,
[Project Cerbera GTA2 tutorials](https://projectcerbera.com/gta/2/tutorials/),
[GTA Wiki (wikigta.org)](https://en.wikigta.org/), [Grand Theft Wiki](https://www.grandtheftwiki.com/),
[StrategyWiki](https://strategywiki.org/wiki/Grand_Theft_Auto_2),
[GameFAQs](https://gamefaqs.gamespot.com/pc/197478-grand-theft-auto-2/faqs/37001),
[GTA2 RE hub (Valps)](https://valps.github.io/gta2-re-hub/),
[Valps/Project_Open_Downtown](https://github.com/Valps/Project_Open_Downtown),
[Valps/Project_Open_Residential](https://github.com/Valps/Project_Open_Residential),
[JulianOzelRose/GTA2-SaveEdit](https://github.com/JulianOzelRose/GTA2-SaveEdit). Each link is in
the note next to the fact it backs.

## Techniques

- **32-bit code under a 64-bit host via an LDT segment** (`i386_set_ldt` + far calls/thunks):
  the approach Wine / CrossOver use to run 32-bit Windows code on 64-bit macOS ("32-on-64").
  Our implementation is our own (`spike/`, `host/loader.asm`).
- **`GetDXVersion` 0x4031C0** in the game is Microsoft's DirectX SDK sample; `diutil.cpp` /
  `frontend2.cpp` are the game's own source names, from its strings (`docs/win32-shims.md`).

## Libraries and tools

| What | Where | Used for | License |
|---|---|---|---|
| SDL3 | https://www.libsdl.org/ · https://github.com/libsdl-org/SDL (3.4.14) | window, input, audio, rendering; dlopen'ed by the host | zlib |
| NASM | https://www.nasm.us/ | assembler for the whole host | BSD-2-Clause |
| Ghidra | https://ghidra-sre.org/ · https://github.com/NationalSecurityAgency/ghidra (12.1.4) | the RE database behind `re/` | Apache-2.0 |
| GhidraMCP — bethington | https://github.com/bethington/ghidra-mcp (v7.0.0-rc.3) | agents query/annotate the live Ghidra (`tools/ghidra-mcp/`, `docs/ghidra-mcp.md`) | Apache-2.0 |
| Bun | https://bun.sh | runs `tools/formats/` | MIT |
| Rosetta 2, Xcode / Apple clang + ld | Apple | x86-64 host on Apple Silicon, linking | Apple terms |

## Missing something?

If an address, idea or file here came from somewhere not listed, that is a bug: open an issue
or add the entry, with a link.
