# gta2-resurrected — agent guide

## Project goal

Write an application in assembly (NASM preferred, not mandatory) that loads the
**original, vanilla `gta2.exe`** (32-bit x86 PE) into memory and reuses as many of
its functions, classes and data as possible — patching where needed — while running
on **macOS** and using **SDL** for windows, input and graphics. The original Windows
renderer (DirectDraw / Direct3D / Glide) gets ported to SDL along the way.

This is not a reimplementation of GTA2. The game's own code does the work; we provide
the process, the memory layout and every OS/library service it expects.

## Execution model

Proven up to gameplay: `spike/` proved the 32-bit LDT segment under
Rosetta, `host/loader` (see `host/README.md`) maps vanilla `gta2.exe` at `0x3F0000`, and
`--entry` runs the game from its PE entry point through NASM Win32 shims (CRT startup,
WinMain, registry, a real SDL3 window, DirectInput) and our SDL_Renderer replacements of
`dmavideo.dll`/`d3ddll.dll` into the frontend loop, which draws the original main menu
and navigates it with real keyboard input (SDL3 events → DirectInput 8), with menu sound
effects from `mss32` reimplemented on SDL3 audio (`docs/win32-shims.md`, "Audio"). PLAY
starts the first level (Downtown, `wil`) and the game loop draws it: tiles, slopes,
sprites, HUD and the original point lighting (`--keys=150:RETURN,250:RETURN`). On foot the
player can also strafe (Q/E) and turn with the mouse, both through the game's own walker and
its collision (`host/c32/player_move.c`, `docs/re/ped-movement-collision.md`). A round radar and an M city map with per-level fog of war are drawn over the frame by host C (`host/c/map.c`, `docs/map.md`). Shim list and policies: `docs/win32-shims.md`; renderer:
`docs/renderer-sdl.md`.

SDL3 is **dlopen'ed, not linked**: linked, dyld puts its frameworks in the low 4 GB and
`mmap(0x3F0000)` fails. Do not "fix" that with a fixed zerofill Mach-O segment either:
CrowdStrike Falcon on the dev machine SIGKILLs and deletes such binaries (exit 137, the
file vanishes).

Loader gotcha: copy each section's raw data up to `align_up(VirtualSize, 0x1000)`,
not just `VirtualSize` — the 11.44 patch keeps code in `.text`'s raw slack (the entry
point jumps to `0x56DCDA`, past VirtualSize end `0x56DBC0`).

- **Host**: an x86-64 Mach-O built from NASM (`-f macho64`) plus C99 host modules
  (`host/c/*.c`, clang, `docs/host-c.md`), running under **Rosetta 2** on Apple Silicon.
- **C32**: i386 C99 (`host/c32/*.c`, clang + `ld.lld`) linked into a flat image at
  `0x0F000000`, mapped by the loader and run inside the game's own 32-bit segment: real
  `gta2_types.h` pointers, direct game calls, hooks that jump straight into C
  (`docs/c32.md`).
- **Image**: the host maps `gta2.exe` sections at the PE's preferred base
  (`0x3F0000`, see below) with `mmap(MAP_FIXED)`, then resolves its import table to
  our own shims.
- **32-bit code**: the game runs in a 32-bit code segment created with
  `i386_set_ldt`, entered with a far call/jump and returning to 64-bit host code
  through thunks — the Wine/CrossOver "32-on-64" approach. Everything the game
  touches (heap, stacks, TLS, structures handed to it) must live below 4 GB.
- **Win32 imports** (`KERNEL32`, `USER32`, `GDI32`, `ADVAPI32`, `WINMM`, `DINPUT8`,
  `DPLAYX`, …) are shimmed by us (`host/w32_*.asm`) and thunked to libc / SDL. Game
  functions that only probe the OS may be hooked to host stubs (`w32_hooks.asm`).
  Third-party DLLs the game ships with (`mss32.dll` audio, `binkw32.dll` video) are shimmed the same way
  or replaced.
- **Renderer**: see "Renderer seam" below — the cheapest port point is the game's
  own renderer-plugin DLL API, not DirectDraw COM.

## Target binary: vanilla `gta2.exe`

Lives as **`gta2.ebin`** inside `data.pak` (see "Game files"): every `.exe` in the game folder
is renamed to `.ebin` (company policy: no `.exe` files in the project). Only the host-side
file is renamed; the game still sees itself as `C:\GTA2\gta2.exe`. Facts measured from
the file:

| Property | Value |
|---|---|
| Version | **11.44** (2013-09-07, the community "Vike the Hube" bug-fix build — `gta2/gta2-changelog.txt`; the gtamp.com installer version) |
| SHA-256 | `dd5381c7297bc13151bed8d129fa04a267114f92707c096772ebdd5a6cdca5a2` |
| MD5 | `47a4cc02632c93349b848716b92b0483` |
| Size | 1 740 800 bytes |
| PE TimeDateStamp | `0x408EC2AC` (2004-04-27 — the header stamp was not bumped by the 11.x patches) |
| Machine / subsystem | i386 / Windows GUI |
| **ImageBase** | **`0x003F0000`** — not the usual `0x400000` |
| SizeOfImage | `0x28A000` (image spans `0x3F0000`–`0x67A000`) |
| Entry point | `0x004D84F9` |
| Relocations | **none** — the image can only run at `0x3F0000` |
| DllCharacteristics | `0` (no ASLR/DEP flags) |

Sections: `.text` `0x3F1000` (size `0x17CBC0`), `.rdata` `0x56E000`, `.data`
`0x57C000` (size `0xFA718`, mostly BSS), `.rsrc` `0x677000`.

Static imports (function count): `KERNEL32` 84, `mss32` 52, `USER32` 42,
`binkw32` 18, `ADVAPI32` 8, `VERSION` 3, `ole32` 3, `DPLAYX` 2, `DINPUT8` 1,
`WINMM` 1, `GDI32` 1, `SHELL32` 1.

Loaded at runtime with `LoadLibraryA`/`GetProcAddress` (found as strings in the
binary): `d3ddll.dll`, `dmavideo.dll`, `DDRAW.DLL`, `DINPUT.DLL`, `DMUSIC.DLL`,
`3dfx.dll`, `softdll.dll`.

`gta2-resurected.exe` (no longer in `gta2/`) is **not** the target. It is the user's old
patched build: the same 11.44 image plus an extra `.h0x91b` section at `0x67A000` and a
handful of patched bytes. Its addresses are identical to vanilla.

### Renderer seam

The game does not talk to DirectDraw/Direct3D itself. It loads two plugin DLLs with
flat C APIs (export lists measured from the shipped DLLs):

- `d3ddll.dll` (renderer, ImageBase `0xE00000`, relocatable), 42 exports:
  `gbh_Init`, `gbh_InitDLL`, `gbh_BeginScene`, `gbh_EndScene`, `gbh_DrawQuad`,
  `gbh_DrawQuadClipped`, `gbh_DrawTile`, `gbh_DrawTilePart`, `gbh_DrawTriangle`,
  `gbh_DrawFlatRect`, `gbh_RegisterTexture`, `gbh_LockTexture`, `gbh_RegisterPalette`,
  `gbh_SetCamera`, `gbh_AddLight`, `gbh_BlitBuffer`, `gbh_BlitImage`, … plus
  `ConvertColourBank`, `DrawLine`, `MakeScreenTable`, `SetShadeTableA`.
- `dmavideo.dll` (video mode / surfaces, ImageBase `0x1000000`, relocatable),
  22 exports: `Vid_Init_SYS`, `Vid_SetMode`, `Vid_FlipBuffers`, `Vid_GetSurface`,
  `Vid_ClearScreen`, `Vid_SetGamma`, `Vid_WindowProc`, `Vid_ShutDown_SYS`, …

Ways to port the renderer, in order of preference:

1. **Reimplement the `gbh_*` + `Vid_*` APIs on SDL** and hand the game our function
   pointers when it calls `GetProcAddress`. That is about 64 well-defined functions
   and no COM. Recommended.
2. Load the original `d3ddll.dll`/`dmavideo.dll` too and shim `ddraw.dll` +
   Direct3D (immediate mode, DX5-era) COM vtables on SDL. Much larger surface.
3. Patch the game's draw call sites directly. Fragile; only for odd cases.

Option 1 is implemented in host C, `host/c/renderer.c` + `renderer_gbh.c` (export
tables in `host/w32_renderer.asm`, `docs/renderer-sdl.md`); the full API is in
`docs/renderer-api.md`.

## Game files (`data.pak`)

- The full game (92 MB) is `data.pak` in the repository root: a zip with zero
  compression (every entry Stored) of the old `gta2/` folder, paths relative to it
  (`gta2.ebin`, `data/audio/fstyle.raw`, …). It is **git-ignored and never committed**:
  the repository is public and the game files are Rockstar's. The canonical copy is in
  the main checkout; `.dev3/config.json` has `"clonePaths": ["data.pak"]`, so every
  task worktree gets its own copy-on-write clone. Never modify or re-pack it without
  the user's word.
- For an experiment that needs loose files, unpack it into your worktree
  (`unzip -q data.pak -d gta2`; `/gta2/` stays git-ignored) and never commit the result.
  `tools/mkpak.sh [dir [out]]` rebuilds a pak from such a folder (`zip -0 -r -X`).
- The canonical pak includes the radio / menu music `data/GTAudio/*.wav` (22 files, 320 MB),
  which the 11.44 install lacks: `tools/add-music.sh` takes it from the freeware installer
  `setup.ebin` (InstallShield 7, unpacked with `unshield`; git-ignored, in the main checkout).
- **`tools/get-game.sh` builds a working pak from downloads alone**: gtamp.com's 11.44 NSIS
  installer (unpacked by `7zz`, never run) is the whole game, byte-identical to the canonical
  pak's files; the archive.org freeware installer (9.6 exe, unused) adds the music. The
  canonical pak's 64 extra entries are the user's old mods, saves and replays, not needed.
  Downloads are cached in git-ignored `downloads/` and verified by size + SHA-256.
- **The loader runs from the pak alone** (`host/c/vfs.c`): it indexes the central
  directory once, maps `gta2.ebin` from it, and serves every game file read (Win32
  file shims, registry seed, mss32 streams, `LoadLibraryA` probes) from it,
  case-insensitively. It refuses a pak with any non-Stored entry. **Writes** go to the
  overlay `~/Library/Application Support/gta2-resurrected/` (the host's cwd); overlay
  files win over the pak, and a pak file opened for writing is copied there first. The
  pak itself is never written. Delete the overlay to get back to vanilla state.
- Contents, for orientation: game data in `data/`, plugin DLLs (`d3ddll.dll`,
  `dmavideo.dll`, `mss32.dll`, `binkw32.dll`, glide DLLs), and dgVoodoo wrappers
  (`DDraw.dll`, `D3DImm.dll`, `dgVoodoo.conf`). The dgVoodoo files are a Windows-only
  DirectX→D3D11 wrapper: not part of vanilla and irrelevant to us. Leftovers from the
  user's older mods sit alongside them (`gta2-resurection.dll`, `lua51.dll`,
  `discord_game_sdk.dll`, `gta2-resurected.exe.*`). `gta2manager.exe` (the settings
  tool) is `gta2manager.ebin`.

## File-format decoders (`tools/formats/`)

TypeScript decoders for `.sty`, `.gmp`, `.sdt`/`.raw`, `nyc.gci`, `.scr`, `.gxt` and frontend `.tga`, run
with Bun (`/opt/homebrew/bin/bun`, no npm deps), reading straight from `data.pak` with the
same rules as `host/c/vfs.c`. Use them to learn what
a loader function in `gta2.exe` is parsing: `bun tools/formats/cli.ts help`, e.g.
`sty data/wil.sty --summary`, `gmp data/wil.gmp --block 40,135,3`, `scr data/bil.scr --mis --out formats-out/bil`
(mission scripts back to `.mis`), `gxt data/e.gxt --export`/`--import` (edit game text, `docs/re/gxt.md`). Tests: `bun test
tools/formats`. They write only to an explicit `--out` (inside the repo only if git-ignored,
e.g. `/formats-out/`). Format traps: `docs/formats/lessons.md`; format → reader function →
struct: `docs/formats/loader-map.md`; DMA's specs + example missions: `docs/formats/specs/`; what is left out
(`docs/reference.md`).

## Reference material

Every source (repos, documents, libraries) with what was taken, where it lives and its
license terms: [CREDITS.md](CREDITS.md). Cite a new one there and next to the code that uses it.

All three repos target **GTA2 11.44**, the same build as our vanilla `gta2.exe`, so
their absolute addresses apply 1:1. How this was checked:
- `gta2-seuko-mod` hard-codes the version check `11.44.0.0` (9.6 tolerated, unsupported).
- `gta2-resurection` and `gta2-mouse` both require 11.44 in their READMEs.
- The `gta2-resurected.exe` in gta2-resurection's installer is byte-identical to
  the old `gta2/gta2-resurected.exe` (SHA-256 `c47702e4…07b4`), which differs from vanilla
  only by an appended section plus a few patched bytes.
- Spot check: five function addresses from seuko-mod/resurection
  (`0x461DE0` InitGame, `0x462060` DeinitGame, `0x45A5A0` EachFrameDraw,
  `0x43AE10` GetPedById, `0x41EBF0` UpdateCarCamera) all land on function starts
  right after `90 90` padding in vanilla `gta2.exe`.

| Repo | What it is | Useful for |
|---|---|---|
| [h0x91b/gta2-resurection](https://github.com/h0x91b/gta2-resurection) | The user's old RE + modding project (DLL injected into the patched exe, Lua/LuaJIT FFI mods, ImGui over D3D11 via dgVoodoo). Last commit 2021-11. | `gta2-resurection/gta2.h` (~5 k lines of Ghidra-exported struct layouts: Ped, Car, Game, Player, …), `gta2-def.lua` (the same as LuaJIT FFI cdefs), function addresses in `gta2-functions.lua` / `dllmain.cpp`. Also ships a **Ghidra archive** `gta2-resurected.exe.gzf` and a Cheat Engine table `gta2-resurected.ct` (live data addresses). |
| [h0x91b/gta2-mouse](https://github.com/h0x91b/gta2-mouse) | The user's earliest mod (2019): mouse aiming DLL + xdelta patch for the exe. | `gta2.segments.fixed.exe.h` (~5.7 k lines of Ghidra-exported types for the "segments fixed" program that is also in the Ghidra project below), small worked examples of hooking the exe. |
| [izawartka/gta2-seuko-mod](https://github.com/izawartka/gta2-seuko-mod) | A friend's modern and much more advanced continuation (C++ mod menu, `dinput8.dll` proxy / ASI). Active; last commit 2026-09. | **Best maintained address map.** `src/game/gta2.h` (~9.6 k lines of structs), `src/game/functions.h` (typed function pointers with addresses), `src/game/memory.h` (global data addresses such as `Game*` at `0x5EB4FC`), `src/events/*.cpp` (call-site addresses of hooks), `src/game-version-check.cpp`. |

### Ghidra project

- **Current project (user's choice): `/Users/arsenyp/ghidra/gta-2-recovered.gpr`**
  (+ `gta-2-recovered.rep/`). **Writable by agents**: rename functions, variables and
  globals, fix prototypes, add comments in it through the Ghidra MCP server, which
  talks to the user's running Ghidra GUI. Agents are expected to edit it more than
  the user does. Never open or modify the `.gpr`/`.rep` files on disk directly (another
  Ghidra, `analyzeHeadless`, `rm`, …) while the GUI holds them. `re/tools/export.sh` is
  fine: it copies the project and opens only the copy — call `save_program` first, and
  regenerate `re/` after a naming pass so the names reach the repo.
- Older project: `/Users/arsenyp/ghidra/gta2.rep` (`gta2.gpr` next to it, ~174 MB).
  Programs inside: `gta2.segments.fixed.exe`, `gta2.segments.fixed2.exe`,
  `miss2.exe` (the mission-script compiler).
- The older projects (`gta2.rep`, `gta-2.rep`, the zip) are **read-only**: do not modify them, and never open them
  in place with a Ghidra that might upgrade or lock them. Work on a copy.
- Also present, superseded by `gta-2-recovered`:
  `/Users/arsenyp/ghidra/gta-2.rep` (+ `gta-2.gpr`, recently locked) and
  `/Users/arsenyp/ghidra/gta2-ghidra-proj.zip` (42 MB, 2020).
- **Grep `re/` instead of opening Ghidra**: named functions, globals, imports, comments
  (CSV), structs as C header + NASM `struc`, and `re/gta2_addresses.inc`. Addresses are
  1:1 vanilla gta2.exe VAs. Regenerate with `re/tools/export.sh`; see `re/README.md`.
- **Ghidra MCP struct edits destroy data silently** (measured 2026-10-21):
  - `modify_struct_field` with `new_type` and no `new_name` **erases the field name**
    (CarEngineData lost all 17). Always pass `new_name` together with `new_type`, and
    `get_struct_layout` after every edit; restore a lost name with `field_name="offset:N"`.
  - `remove_struct_field` on a non-packed struct deletes the bytes and shifts every later
    field (Ped went 660 → 645, no undo); `recreate_struct` fails on referenced types;
    `add_struct_field` only fills undefined bytes. Never call the first two. Retyping a
    field to `undefined1` frees its other bytes without a shift, but the 1-byte stub stays a
    component: a new field may start on it, yet nothing can span two stubs (measured
    2026-10-22 on probe structs). A real Clear (`Structure.clearComponent`) needs
    `run_script_inline`, i.e. Ghidra started with `GHIDRA_MCP_ALLOW_SCRIPTS=1`; else ask the
    user for a Structure Editor Clear of the exact offset ranges, then `add_struct_field`.
- Other MCP traps: several programs are open (the renderer DLLs too), so pass
  `program="gta2.segments.fixed.exe"` on every call; `rename_function` needs
  `strict_mode="off"` (its PascalCase gate rejects `Module_Verb` names); `rename_symbol`
  at an address that already has a label adds a second one — `delete_label` the old name.
- **Ghidra docs — look the API up, do not guess it.** `docs/ghidra/api/ghidra.<package>.pyi`
  is Ghidra 12.1.4's own API reference (signatures + full javadoc text, 16 packages, committed;
  `grep -n 'def clearComponent' docs/ghidra/api/*.pyi`); `docs/ghidra/examples/` has bundled
  scripts. `tools/ghidra-docs.sh` unpacks the full javadoc, in-app help and all bundled scripts
  into git-ignored `ghidra-docs/` (~500 MB, 9 s). How to run scripts through the MCP
  (`run_script_inline`, transactions, `save_program`, the calls we use and what bit us):
  `docs/ghidra-scripting.md`; index: `docs/ghidra/README.md`.
- Many `DAT_` constants are zero on disk and set by CRT static initialisers: read their
  values from `re/static_constants.csv` (`re/tools/static_constants.py`), not the file image.

## Toolchain

Measured on this machine (2026-10-20): arm64, macOS 26.6.2 (25G83), Xcode with the
MacOSX 26.2 SDK, Apple clang 17.0.0.

| Tool | State | Notes |
|---|---|---|
| Rosetta 2 | ✅ installed | `oahd` running, `arch -x86_64` works. Rosetta ships its own `debugserver` (`/Library/Apple/usr/libexec/oah/debugserver`). |
| NASM | ✅ 3.02 (Homebrew, `/opt/homebrew/bin/nasm`) | `-f macho64` output links and runs under Rosetta (smoke-tested). |
| Linker | ✅ Apple `ld` 1230.1 at **`/usr/bin/ld`** (= `xcrun ld`) | ⚠️ **Trap:** `ld` and `otool` on `PATH` resolve to anaconda's ancient ld64-530 (`/opt/homebrew/anaconda3/bin`). Always call `/usr/bin/ld` / `xcrun ld` (or link through `clang -arch x86_64`). |
| clang (x86_64 target) | ✅ Apple clang 17 | `clang -arch x86_64` builds Rosetta binaries; handy for C test harnesses. |
| lldb | ✅ lldb-1703 | Debugging x86_64 processes under Rosetta works through Rosetta's debugserver. 32-bit LDT code segments are untested; expect lldb to mis-disassemble them (it assumes 64-bit mode). Plan to need `disassemble --arch i386 -s <addr>` or a manual memory dump. |
| SDL3 (x86_64) | ✅ 3.4.14 at **`~/.local/opt/sdl3-x86_64`** (`include/`, `lib/libSDL3.dylib`) | Built from source in `~/.local/src/SDL-x86` (tag `release-3.4.14`), `minos 26.0`. Install name is `@rpath/libSDL3.0.dylib`: `host` links it with `-rpath`; `loader` dlopens `lib/libSDL3.0.dylib` (see `host/build.sh`). Do not modify that prefix. Homebrew's `sdl3`/`sdl2-compat` under `/opt/homebrew` are arm64-only and unusable from a Rosetta host; x86_64 Homebrew refuses to install on Apple Silicon. |
| Ghidra | ✅ 12.1.4 (Homebrew formula `ghidra`) | `ghidraRun` on `PATH`; headless at `/opt/homebrew/opt/ghidra/libexec/support/analyzeHeadless`. Uses JDK 21 (`/opt/homebrew/opt/openjdk@21`). |
| ld.lld (i386 linker) | ✅ LLD 23.1.4 (Homebrew formula `lld`, `/opt/homebrew/bin/ld.lld`) | **Required to build** (`brew install lld`): links the C32 image (`host/c32/`, `docs/c32.md`), Apple `ld` cannot link i386. Agents may install it into the arm64 Homebrew; `host/build.sh` stops with a hint without it, `LLD=` overrides the path. |
| cmake / ninja / pkg-config | ✅ (arm64 Homebrew) | They run natively and can still drive an x86_64 build via `CMAKE_OSX_ARCHITECTURES=x86_64`. |

### Required link flags for the host (verified)

The game must sit at `0x3F0000` and allocate only below 4 GB, so the host must keep
the low 4 GB free. `host/build.sh` is the working reference (NASM + SDL3, adds
`-L…/sdl3-x86_64/lib -lSDL3 -rpath …` and `-platform_version macos 26.0 <sdk>`
to match SDL's `minos`); the minimal form is:

```sh
nasm -f macho64 -o host.o host.asm
/usr/bin/ld -arch x86_64 -platform_version macos 11.0 11.0 \
  -e _main -no_pie -pagezero_size 0x1000 -image_base 0x200000000 \
  -L"$(xcrun --show-sdk-path)/usr/lib" -lSystem \
  -o host host.o
```

Smoke-test results (an `mmap(0x3F0000, 0x28A000, RWX, MAP_FIXED|MAP_ANON)` probe,
run under Rosetta):

| Link flags | Result |
|---|---|
| default (4 GB `__PAGEZERO`) | `ENOMEM` (the whole low 4 GB is reserved) |
| `-pagezero_size 0x1000`, PIE (default) | `ENOMEM` |
| `-pagezero_size 0x1000 -no_pie` | OK (host text at `0x1000`) |
| `-pagezero_size 0x1000 -no_pie -image_base 0x200000000` | **OK**, and the host sits above 4 GB. Recommended. |

`ld` warns that `-no_pie` is deprecated. It still works with ld 1230 on macOS 26,
but it is a long-term risk to track. Add `-platform_version` (or a
`LC_BUILD_VERSION`) to silence "no platform load command" warnings.

### Install steps for the user (not done by agents)

Agents may only `brew install` into the existing arm64 Homebrew. Everything below is
system-level and is the user's call. Steps 1 and 2 are **done** (2026-10-20, see the
table above); kept for rebuilding on another machine.

1. **x86_64 SDL** (required). Options, recommended first:
   - **Build SDL3 for x86_64 from source** into a repo-local prefix (no system
     changes):
     ```sh
     git clone --depth 1 --branch release-3.4.x https://github.com/libsdl-org/SDL.git /tmp/SDL
     cmake -S /tmp/SDL -B /tmp/SDL/build-x64 -G Ninja \
       -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_BUILD_TYPE=Release \
       -DCMAKE_INSTALL_PREFIX="$PWD/third_party/sdl-x86_64"
     cmake --build /tmp/SDL/build-x64 && cmake --install /tmp/SDL/build-x64
     ```
     (`third_party/sdl-x86_64` must stay git-ignored. A universal build is also
     possible with `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`.)
   - Or a second, x86_64 Homebrew under `/usr/local`:
     ```sh
     arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
     arch -x86_64 /usr/local/bin/brew install sdl3
     ```
     This is heavier and system-wide, and invites arm64/x86_64 `PATH` mix-ups.
     ⚠️ In practice x86_64 Homebrew **refuses to install on Apple Silicon** — use the
     source build.
2. **Ghidra** (for RE work): `brew install ghidra` (formula; uses the existing JDK 21).
3. Optional: put `/usr/bin` before `/opt/homebrew/anaconda3/bin` on `PATH`, or
   just always call `/usr/bin/ld` explicitly.

### SDL2 vs SDL3

**Use SDL3.** It is the actively developed line, Homebrew's `sdl2` is now
`sdl2-compat` (a shim over SDL3), and SDL3's `SDL_Renderer` / `SDL_GPU` cover what
the `gbh_*` renderer needs (textured quads, palettes converted to textures,
blending). SDL2 is the fallback only if a specific SDL2-only library turns up.
Calling SDL from NASM is ordinary SysV x86-64 C ABI, so the choice does not affect
the assembly side.

## Testing the game: use gta2ctl

Drive a running game from bash instead of guessing `--keys` frame timings: start it with
`--ctl=PATH` (export `GTA2_CTL=PATH`), then `tools/gta2ctl/gta2ctl state | teleport | goto |
enter_car | spawn | wait money >= 333 | shot | quit`, each one JSON reply line, exit 0/1/2 for
ok/error/timeout. Keep `--keys` only for the frontend. Commands, fields and a worked example
(`tests/ctl/smoke.sh`): [docs/gta2ctl.md](docs/gta2ctl.md).

## Rules for agents

- **Run builds, tests and programs in a visible tmux pane next to you** (`dev3 pane run "<cmd>" --label <name>`, read it with `dev3 pane logs <id>`, close it with `dev3 pane close <id>`), so the user watches the logs live. Quick read-only commands (grep, cat, git status) may stay inline.
- Never commit game files, extracted assets, or any binary (`*.exe`, `*.dll`, `*.o`,
  built hosts), and never `data.pak`. Build output must be git-ignored.
- Never modify the main checkout or the old Ghidra projects (`gta-2-recovered` is
  writable via MCP, see "Ghidra project"). An unpacked `gta2/` in your
  worktree is yours to change.
- Addresses are always virtual addresses for ImageBase `0x3F0000` (11.44). Cite
  where an address came from (seuko-mod file, Ghidra, own analysis) when you add
  one to the code.
- **Where code goes.** Game logic (mods, detours into game functions) is **C32**: i386 C99
  in `host/c32/`, run inside the game's segment (`docs/c32.md`). Host features (K menu,
  config, SDL, logs) are **64-bit host C** in `host/c/`, game pointers as `uint32_t`
  (`docs/host-c.md`). Hooks, thunks, Win32 shims and the loader stay NASM; the shim
  handlers themselves may be host C (`host/c/audio.c`, `host/c/renderer*.c`).
- Keep the execution model above in sync with what the spike proves. If it changes,
  update this file in the same change.
