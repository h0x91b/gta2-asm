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

Decided, not yet proven end to end (a separate spike task is proving the 32-bit
segment under Rosetta — do not implement the loader from this document alone).

- **Host**: an x86-64 Mach-O built from NASM (`-f macho64`), running under
  **Rosetta 2** on Apple Silicon.
- **Image**: the host maps `gta2.exe` sections at the PE's preferred base
  (`0x3F0000`, see below) with `mmap(MAP_FIXED)`, then resolves its import table to
  our own shims.
- **32-bit code**: the game runs in a 32-bit code segment created with
  `i386_set_ldt`, entered with a far call/jump and returning to 64-bit host code
  through thunks — the Wine/CrossOver "32-on-64" approach. Everything the game
  touches (heap, stacks, TLS, structures handed to it) must live below 4 GB.
- **Win32 imports** (`KERNEL32`, `USER32`, `GDI32`, `ADVAPI32`, `WINMM`, `DINPUT8`,
  `DPLAYX`, …) are shimmed by us and thunked to libc / SDL. Third-party DLLs the
  game ships with (`mss32.dll` audio, `binkw32.dll` video) are shimmed the same way
  or replaced.
- **Renderer**: see "Renderer seam" below — the cheapest port point is the game's
  own renderer-plugin DLL API, not DirectDraw COM.

## Target binary: vanilla `gta2.exe`

Lives in `gta2/gta2.exe` (see "Game files"). Facts measured from the file:

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

`gta2/gta2-resurected.exe` is **not** the target. It is the user's old patched build:
the same 11.44 image plus an extra `.h0x91b` section at `0x67A000` and a handful of
patched bytes. Its addresses are identical to vanilla.

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

The `gbh_*` signatures are not documented here yet. Recover them from the Ghidra
project or from the reference repos before implementing.

## Game files (`gta2/`)

- The full game (92 MB) sits at `gta2/` in the repository root. It is git-ignored
  (`/gta2/` in `.gitignore`). **Never commit anything from it, and never commit any
  binary.**
- The canonical copy is in the main checkout:
  `/Users/arsenyp/src-shared-2/gta2-resurrected/gta2`. It is **read-only**: never
  modify, rename or delete anything in the main checkout.
- `.dev3/config.json` has `"clonePaths": ["gta2"]`, so every new dev3 task
  worktree gets its **own** copy at `<worktree>/gta2`. dev3 copies it with
  copy-on-write APFS clones, so the copy costs no disk space until a file changes.
  Inside a task worktree you may modify your copy freely, e.g. to patch the exe for
  an experiment. Verified 2026-10-20: a fresh task worktree started on this config
  got the full `gta2/` (92 MB, `gta2.exe` SHA-256 matching). The config only takes
  effect for tasks whose base branch contains `.dev3/config.json`.
- Contents, for orientation: game data in `data/`, plugin DLLs (`d3ddll.dll`,
  `dmavideo.dll`, `mss32.dll`, `binkw32.dll`, glide DLLs), and dgVoodoo wrappers
  (`DDraw.dll`, `D3DImm.dll`, `dgVoodoo.conf`). The dgVoodoo files are a Windows-only
  DirectX→D3D11 wrapper: not part of vanilla and irrelevant to us. Leftovers from the
  user's older mods sit alongside them (`gta2-resurection.dll`, `lua51.dll`,
  `discord_game_sdk.dll`, `gta2-resurected.exe*`).

## Reference material

All three repos target **GTA2 11.44**, the same build as our vanilla `gta2.exe`, so
their absolute addresses apply 1:1. How this was checked:
- `gta2-seuko-mod` hard-codes the version check `11.44.0.0` (9.6 tolerated, unsupported).
- `gta2-resurection` and `gta2-mouse` both require 11.44 in their READMEs.
- The `gta2-resurected.exe` in gta2-resurection's installer is byte-identical to
  `gta2/gta2-resurected.exe` (SHA-256 `c47702e4…07b4`), which differs from vanilla
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
  (+ `gta-2-recovered.rep/`). Same read-only rules as below; work on a copy.
- Older project: `/Users/arsenyp/ghidra/gta2.rep` (`gta2.gpr` next to it, ~174 MB).
  Programs inside: `gta2.segments.fixed.exe`, `gta2.segments.fixed2.exe`,
  `miss2.exe` (the mission-script compiler).
- **READ-ONLY.** It is Ghidra's binary project database: reading it needs Ghidra
  (GUI or `analyzeHeadless`). Do not modify it, and never open it in place with a
  Ghidra that might upgrade or lock it. Work on a copy.
- Also present, superseded by `gta-2-recovered`:
  `/Users/arsenyp/ghidra/gta-2.rep` (+ `gta-2.gpr`, recently locked) and
  `/Users/arsenyp/ghidra/gta2-ghidra-proj.zip` (42 MB, 2020).
- **Grep `re/` instead of opening Ghidra**: named functions, globals, imports, comments
  (CSV), structs as C header + NASM `struc`, and `re/gta2_addresses.inc`. Addresses are
  1:1 vanilla gta2.exe VAs. Regenerate with `re/tools/export.sh`; see `re/README.md`.

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
| SDL3 (x86_64) | ✅ 3.4.14 at **`~/.local/opt/sdl3-x86_64`** (`include/`, `lib/libSDL3.dylib`) | Built from source in `~/.local/src/SDL-x86` (tag `release-3.4.14`), `minos 26.0`. Install name is `@rpath/libSDL3.0.dylib`: link with `-rpath`, see `host/build.sh`. Do not modify that prefix. Homebrew's `sdl3`/`sdl2-compat` under `/opt/homebrew` are arm64-only and unusable from a Rosetta host; x86_64 Homebrew refuses to install on Apple Silicon. |
| Ghidra | ✅ 12.1.4 (Homebrew formula `ghidra`) | `ghidraRun` on `PATH`; headless at `/opt/homebrew/opt/ghidra/libexec/support/analyzeHeadless`. Uses JDK 21 (`/opt/homebrew/opt/openjdk@21`). |
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

## Rules for agents

- Never commit game files, extracted assets, or any binary (`*.exe`, `*.dll`, `*.o`,
  built hosts). Build output must be git-ignored.
- Never modify the main checkout or the Ghidra projects. Your worktree's `gta2/`
  copy is yours to change.
- Addresses are always virtual addresses for ImageBase `0x3F0000` (11.44). Cite
  where an address came from (seuko-mod file, Ghidra, own analysis) when you add
  one to the code.
- Keep the execution model above in sync with what the spike proves. If it changes,
  update this file in the same change.
