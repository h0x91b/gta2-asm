# Win32 shims

How `host/loader --entry` runs vanilla `gta2.exe` from its PE entry point, and every
import it implements. Code lives in `host/w32_*.asm`, which `host/loader.asm` pulls in
with `%include` (one NASM unit).

## Current stopping point (2026-10-20)

**Update:** with the renderer plugins implemented (`host/c/renderer.c`, `renderer_gbh.c`,
[`renderer-sdl.md`](renderer-sdl.md)) the game no longer stops: it loads both plugins,
initialises the audio (real since the mss32 shim, `host/c/audio.c`, see "Audio"), loads the frontend and **runs the frontend loop,
drawing the main menu**, until the window is closed (or `--frames=N`). The section
below is the record of the stop before that step.

The game runs the MSVC CRT startup and WinMain, creates its window (a real SDL3
window, 1280×960), initialises DirectInput, loads its video plugin, resolves its 22
`Vid_*` exports, and stops at the **first renderer call: `dmavideo.dll!Vid_InitDLL`,
called from `0x4D3505`**. That is where the renderer work picks up.

Real console output, `host/build.sh --load --entry` (the PE-loading part and the 15
function checks are omitted, they are unchanged from `host/README.md`):

```
hook: 0x4031c0 GetDXVersion (entry)
SDL 3.4.14 loaded from /Users/arsenyp/.local/opt/sdl3-x86_64/lib/libSDL3.0.dylib
registry: gta2_install.reg -> 8 keys, 54 values (in memory only)
...
functions: 15/15 checks passed
--entry: jumping to the PE entry point 0x4d84f9
  [w32] GetProcAddress(KERNEL32, GetProcessHeap) -> 0x1000487a (shim)
  [w32] GetProcAddress(KERNEL32, IsProcessorFeaturePresent) -> 0x10004884 (shim)
  [ods] Perf: Clock speed = 250 MHz
  [w32] GetFileVersionInfoSizeA(GTA2.EXE): fake VS_FIXEDFILEINFO, version 23.31
  [w32] CreateFileA(data\j.gxt) -> not found
  [w32] RegisterClassA(WinMain) wndproc 0x4d0a00
  [w32] CreateWindowExA(GTA2) 100x100 -> hwnd 0xab0000 (SDL window), wndproc 0x4d0a00
  [w32] ShowWindow(0xab0000): SDL_ShowWindow -> 1
  [w32] DirectInput8Create(version 0x800) -> IDirectInput8A 0x2000de20 
  [w32] LoadLibraryA(dmavideo.dll) -> 0x7f0d0000
  [w32] GetProcAddress(dmavideo.dll, Vid_GetVersion) -> 0x100048fc (UNIMPLEMENTED)
  [w32] GetProcAddress(dmavideo.dll, Vid_Init_SYS) -> 0x10004906 (UNIMPLEMENTED)
  ... (Vid_CheckMode, Vid_FindMode, Vid_FindFirstMode, Vid_FindNextMode, Vid_CloseScreen,
       Vid_SetMode, Vid_FlipBuffers, Vid_ReleaseSurface, Vid_GrabSurface, Vid_ShutDown_SYS,
       Vid_EnableWrites, Vid_DisableWrites, Vid_GetSurface, Vid_FreeSurface,
       Vid_ClearScreen, Vid_InitDLL, Vid_FindDevice, Vid_SetDevice, Vid_WindowProc)
  [w32] GetProcAddress(dmavideo.dll, Vid_SetGamma) -> 0x100049ce (UNIMPLEMENTED)
unimplemented import dmavideo.dll!Vid_InitDLL (called from 0x4d3505)
```

Exit code 3. With `--trace` every shim call is logged with its arguments, result and
caller (about 1 000 lines to this point, most of them CRT `HeapSize` calls). With
`--hold` the process keeps the SDL window up for 5 s when it stops (screenshot check:
a window titled "GTA2", 1280×960 client area, black).

`d3ddll.dll` is not loaded yet: the game loads `dmavideo.dll` first and calls
`Vid_InitDLL` before anything else.

### Flags

| flag | effect |
|---|---|
| `--entry` | jump to the PE entry point after the function checks |
| `--trace` | one line per shim call: `DLL!Name(args) = result <- caller` (+ WndProc messages, file opens) |
| `--hold` | when the run stops, keep pumping SDL events for 5 s so the window is visible |
| `--frames=N` | exit (status 0) after N presented frames (`renderer-sdl.md`) |
| `--shot=PATH` | with `--frames`: save the last frame's back buffer as BMP (the presented part: 640×480 in the frontend, the window size in gameplay) |
| `--window=WxH` | override the registry's `screen\window_width/height` for this run (320×240 … 4096×4096; default 1280×960, the install seeds 960×720): the window size and the gameplay resolution (`renderer-sdl.md`, "Resolution") |
| `--config=PATH` | read settings from PATH instead of the overlay's `config.yaml` (see "Registry", config.yaml) |
| `--trace-input` | log every key change, Acquire, `GetDeviceState` view change and delivered `GetDeviceData` record (implied by `--trace`) |
| `--keys=F:KEY[:N],...` | scripted taps: KEY (a DIK name, e.g. `DOWN`, `RETURN`, `ESCAPE`) goes down at presented frame F, up 4 frames later (N frames with `:N`, to hold it); pushed into SDL's queue, so it takes the real key path |
| `--input-test` | no game run: drive the game's own input code (see "Input") for ~15 s against real keys pressed in a test window |
| `--input-selftest` | the same with a scripted SDL event sequence; prints PASS/FAIL per check, exit = number of failures |
| `--bg-audio` | keep the game audible while the window is not focused (default: muted, see "Audio") |

## Mechanism

- **Dispatch.** Each IAT slot points at its own 10-byte 32-bit stub `push slot; jmp
  common32`. `common32` far-calls `dispatch64` → `host_dispatch`, which switches to the
  host stack, saves the game's `esi/edi/ebx/ebp`, calls `imp_handler[slot](rdi = args,
  esi = slot)` and far-returns `edx:eax`. `common32` then pops `imp_pop[slot]` argument
  bytes (stdcall; 0 for cdecl such as `wsprintfA`).
- **Binding.** Slots are bound by (DLL, name) against the shim tables listed in
  `w32_tables.asm`. Unknown names keep `host_unimpl` (print + exit 3). Decorated
  `mss32`/`binkw32` names (`_AIL_startup@0`) default to a silent stub: return 0, pop N
  bytes, log the first call.
- **GetProcAddress** creates new slots the same way, so dynamically resolved functions
  (`GetProcessHeap`, all plugin exports) are shims or traps exactly like static imports.
- **Callbacks.** `call32` is re-entrant: a handler can call back into 32-bit code
  (WndProc, `CallWindowProcA`); nested 32-bit frames go just below the game's `esp`.
- **Hooks** (`w32_hooks.asm`): four kinds in one table, each checked against its
  original bytes first, each stub a slot named `gta2.exe!Name` (so `--trace` shows it):
  `HOOK` (function entry → `jmp` stub), `CALLHOOK` (an `E8 call` retargeted to the stub),
  `JMPHOOK` (mid-function: whole instructions moved to a 32-bit trampoline at
  `0x10010000+` that does `pushad; pushfd` and calls the stub with the register block, then
  runs them — or resumes where the handler says) and `PATCH` (plain bytes).
  `host_dispatch` keeps the game's eax/ecx/edx in `G_EAX/G_ECX/G_EDX`, so thiscall and
  fastcall targets work and a `CALLHOOK` handler can call the original through `call32`.
- **COM** (`w32_dinput.asm`): an interface is a shim table in vtable order
  (`"IDirectInput8A::CreateDevice"`); `com_new` builds the vtable from slots once and
  allocates objects `{vtbl, refcount, kind}` in low memory.
- **Low memory.** Everything the game sees lives below 4 GB: image `0x3F0000`, low
  region `0x10000000–0x11000000` (thunks, stubs, TEB, 8 MB stack), arena
  `0x20000000–0x60000000` (heap, `VirtualAlloc`, strings, COM objects). Host `.data`,
  `malloc` and SDL memory are never handed to the game.

### Two traps found on the way

1. **SDL3 must not be linked.** Linking `-lSDL3` makes dyld place frameworks in the low
   4 GB and `mmap(0x3F0000)` fails. The loader links only libSystem, maps all low
   regions, then `dlopen`s SDL3 (`$GTA2_SDL3_LIB`, default
   `~/.local/opt/sdl3-x86_64/lib/libSDL3.0.dylib`) and calls it through pointers.
2. **CrowdStrike Falcon kills odd binaries.** Reserving the low range with a zerofill
   Mach-O segment (`-segaddr`, Wine's trick) works in principle, but Falcon on the dev
   machine SIGKILLs (exit 137) and **deletes** such binaries on first run — a 16 MB
   zerofill segment triggered it every time in a minimal test. Symptom: "the binary
   vanished after running". Hence the dlopen route.

Also: on x86_64 macOS, `stat`/`opendir`/`readdir` must be the `$INODE64` symbols to
match the 64-bit-inode struct layouts; the plain names are the legacy ABI. Host C gets
them from the SDK headers by itself (`nm -u host/c/vfs.o`); NASM would need
`extern _stat$INODE64` by hand.

## Policies (decisions with long-term impact)

- **Paths.** Game files come from `data.pak` (a Stored zip, indexed once by
  `host/c/vfs.c`) plus a writable overlay, `~/Library/Application Support/gta2-resurrected/`,
  which is the host's cwd. The game is told it lives in `C:\GTA2`
  (`GetModuleFileNameA` → `C:\GTA2\gta2.exe`, `GetCurrentDirectoryA` → `C:\GTA2`).
  `C:\GTA2\x` and relative paths map to the game root, any other absolute path is
  refused (not found). Backslashes become `/`, `.` components drop, and lookup is
  case-insensitive: the overlay first, then the pak. Writes always land in the overlay
  (e.g. the CRT's `test\error.log`); a pak-only file opened for writing with
  `OPEN_EXISTING`/`OPEN_ALWAYS` is copied there first. The pak is read-only.
- **Registry.** In memory, seeded from `gta2_install.reg` (overlay or pak) at startup. Writes are
  kept for the life of the process only — not persisted (later: write back to a text
  file next to the game). The only override after seeding is `reg_window_override`, which replaces
  `screen\window_width/height` for the run with 1280×960, or with `--window=WxH`.
  Windowed play (`start_mode` 0) sizes the window to those values and lays gameplay out
  for them, and the renderer's back buffer follows (`renderer-sdl.md`, "Resolution"), so
  gameplay is rendered natively at that size. (Until 2026-10-21 they were forced to
  640×480 by `reg_force_screen` and the window was shown 1.5× bigger; both are gone.)
- **config.yaml** (`host/c/config.c`, 64-bit host C; every key is one line of its `keys[]`
  table: section, name, type, storage, default, range). After seeding, `config_apply` reads
  `config.yaml` from the overlay dir (optional; `--config=PATH` names another file, which
  then must exist). A YAML subset: `section:` headers, indented `key: value`, `#` comments,
  spaces only; a syntax error or a bad value stops the loader with the line number (and
  `section.key:` for a value), unknown sections and keys only warn. Section `debug:`:
  the game's own developer flags, which `Debug_LoadFlagsFromRegistry` (`0x451930`) reads once from `HKCU\SOFTWARE\DMA Design Ltd\GTA2\Debug`
  (a flag is on when its value exists, so `false` deletes the value; `show_player_names` is
  value-based). Every flag with comments: `config.example.yaml`. Section `mods:` goes to
  `c32_cfg_mods` (`host/c/c32_host.c`, C32 mods). Section `camera:`,
  key `zoom: auto | 25..400` (percent of the game's zoom, see "Hooks", `0x41F3E9`);
  without it the camera runs at 70% (the table's default), `zoom: 100` is vanilla. Section
  `controls:` (storage in `host/c/c32_host.c`, used by `host/c32/player_move.c`): `strafe` (default on), `strafe_left` / `strafe_right`
  (key names as in `--keys`, default Q / E), `mouse_turn` (default off),
  `mouse_sensitivity` (percent, 10..1000, 100 = 0.5° per mouse point); the first two also
  toggle at run time from the debug menu (K); see "Hooks",
  `0x4A7901` and `0x49AC76`.
- **Threads.** None exist; sync objects are tokens. `CreateThread` is not imported.
- **OS identity.** Windows XP SP3 (5.1.2600, NT), code page 1252 (implemented as
  Latin-1), US-English locale, 1 CPU, DirectX 8.1.

## Shim log

"Exercised" = called in the run above. The rest are implemented from the API contract
and not yet exercised by the game.

### KERNEL32 — process, modules, memory (`w32_kernel32.asm`)

| import | semantics / shortcut |
|---|---|
| GetVersion, GetVersionExA ✓ | Windows XP SP3, NT platform, OSVERSIONINFOEX filled when asked |
| GetStartupInfoA ✓ | zeroed, `cb = 68` |
| GetCommandLineA ✓ | `"C:\GTA2\gta2.exe"` (no arguments yet) |
| GetEnvironmentStrings(A/W) ✓, FreeEnvironmentStrings(A/W) ✓ | fixed small block (PATH, SystemRoot, TEMP, windir); free is a no-op |
| GetModuleHandleA ✓ | NULL / `gta2.exe` → `0x3F0000`; system DLLs → fake handles `0x7F000000 + k·0x10000` |
| GetModuleFileNameA ✓ | `C:\GTA2\gta2.exe` |
| LoadLibraryA ✓ | system DLL → its fake handle; otherwise a fake module if the file exists in the overlay or pak (`dmavideo.dll`); else NULL, error 126 |
| GetProcAddress ✓ | new slot bound by name (cached per DLL+name); unknown names become traps, logged `UNIMPLEMENTED`; ordinals supported |
| FreeLibrary | TRUE |
| GetProcessHeap ✓, HeapCreate ✓, HeapDestroy | one heap for everything, token `0x00DE0000` |
| HeapAlloc ✓, HeapFree ✓, HeapReAlloc ✓, HeapSize ✓ | power-of-two size classes with free lists in the low arena; `HEAP_ZERO_MEMORY`, `HEAP_REALLOC_IN_PLACE_ONLY`; bad frees are logged |
| VirtualAlloc | NULL address → fresh 64 KB-aligned arena memory; an address inside the arena (commit) → itself; anything else NULL + log |
| VirtualFree, VirtualProtect, VirtualQuery | no-op / old = `PAGE_READWRITE` / one committed RW page |
| LocalFree | heap free |
| IsProcessorFeaturePresent ✓ (via GetProcAddress) | CX8, MMX, SSE, RDTSC, SSE2 → TRUE |
| GetSystemInfo | 4 KB pages, 64 KB granularity, 1 CPU, Pentium |
| GetCurrentProcess / ProcessId ✓ / ThreadId ✓ | `-1` / `getpid()` / `getpid()+4` |
| GetLastError ✓ | shims set it where callers check it |
| SetUnhandledExceptionFilter ✓, UnhandledExceptionFilter | stores the filter; the latter only logs (there is no SEH dispatch yet) |
| ExitProcess, TerminateProcess | log + `exit(code)` |
| OutputDebugStringA ✓ | printed as `[ods]` |
| IsBadReadPtr / WritePtr / CodePtr | always "good" |
| GetTickCount ✓, QueryPerformanceCounter ✓, QueryPerformanceFrequency | monotonic clock: ms / ns ticks / 1e9 |
| GetSystemTimeAsFileTime ✓, FileTimeToLocalFileTime, FileTimeToSystemTime, GetTimeZoneInformation ✓ | real UTC time; local time = UTC |
| Sleep ✓ | `usleep` |
| CreateEventA ✓, CreateMutexA, OpenMutexA, ReleaseMutex, CloseHandle ✓ | handle tokens; `OpenMutexA` says no other instance; `CloseHandle` closes files |
| lstrlenA, FormatMessageA | strlen / produces no text (0) |
| SetHandleCount ✓, SetConsoleCtrlHandler, SetEnvironmentVariableA, SetStdHandle | return arg / TRUE |

### KERNEL32 — files (`host/c/files.c`, table `w32_files.asm`)

64-bit host C import handlers (docs/host-c.md, "Import shims in C") on top of the pak VFS
`host/c/vfs.c` (index, `win_path`, overlay, copy-out, `vfs_load`; unit test
`host/test/vfs_test.c`). Ported from NASM in Seq 64 with identical log lines. End to end:
`tests/ctl/quick_save.sh` (a fresh overlay under its own `HOME`, a K menu quick save:
files served from the pak, the save and the CRT logs in the overlay, data.pak untouched).

| import | semantics / shortcut |
|---|---|
| CreateFileA ✓ | path policy above. Overlay: access → `O_RDONLY/O_WRONLY/O_RDWR`, all five dispositions, missing parent dirs created. Pak, read-only access: an `HT_PAK` handle (entry + position), logged as `[vfs]`. Failure → `INVALID_HANDLE_VALUE`, error 2, logged |
| ReadFile, WriteFile ✓, SetFilePointer, SetEndOfFile, FlushFileBuffers | `read`/`write`/`lseek` (64-bit with the high dword)/`ftruncate`; pak handles: `pread` clipped to the entry, own position, no writes; no overlapped I/O |
| GetStdHandle ✓, GetFileType ✓ | std handles map to fds 0/1/2 (`FILE_TYPE_CHAR`); files are `FILE_TYPE_DISK` |
| GetFileAttributesA | directory / normal (overlay, else pak entry or pak directory), or `INVALID_FILE_ATTRIBUTES` |
| FindFirstFileA ✓, FindNextFileA, FindClose ✓ | overlay `opendir`, then pak entries directly in that dir the overlay lacks; `fnmatch(FNM_CASEFOLD)`, `*.*` matches everything, `.`/`..` skipped; size + attributes filled |
| GetCurrentDirectoryA ✓, SetCurrentDirectoryA | always `C:\GTA2`; only the game root itself can be set |
| GetFullPathNameA | relative → `C:\GTA2\name` |
| GetDriveTypeA | `DRIVE_FIXED` |
| GetPrivateProfileStringA | no INI support: copies the default, logs the request |

### KERNEL32 — code pages, locale (`w32_locale.asm`)

| import | semantics / shortcut |
|---|---|
| GetACP ✓ / GetOEMCP | 1252 / 437 |
| GetCPInfo ✓ | single byte, default char `?`, no lead bytes |
| MultiByteToWideChar ✓, WideCharToMultiByte ✓ | Latin-1 ↔ UTF-16, `?` for > 0xFF; size queries and `ERROR_INSUFFICIENT_BUFFER` |
| GetStringTypeW ✓, GetStringTypeA | `CT_CTYPE1` from a Latin-1 table (other info types zero) |
| LCMapStringW ✓, LCMapStringA | copy / `LCMAP_LOWERCASE` / `LCMAP_UPPERCASE` (no sort keys) |
| CompareStringA / W | ordinal, optional `NORM_IGNORECASE` |
| GetLocaleInfoA | a table of US-English answers; unknown types logged → 0 |

### ADVAPI32 (`w32_advapi32.asm`)

| import | semantics / shortcut |
|---|---|
| RegOpenKeyExA ✓, RegCreateKeyExA ✓, RegCloseKey ✓ | keys are full paths (`HKEY_CURRENT_USER\...`), case-insensitive; HKEY = `0x00C00000 + 4·index` |
| RegQueryValueExA ✓, RegSetValueExA ✓, RegDeleteValueA | REG_SZ / DWORD / BINARY / `hex(N)` from the .reg file; size queries and `ERROR_MORE_DATA` |
| GetUserNameA | `Player` |
| IsTextUnicode | FALSE |

### USER32 / GDI32 (`w32_user32.asm`)

| import | semantics / shortcut |
|---|---|
| RegisterClassA ✓ | name + WndProc |
| CreateWindowExA ✓ | `SDL_CreateWindow` (hidden until `ShowWindow`), sends WM_NCCREATE, WM_CREATE (CREATESTRUCTA in low memory), WM_SIZE, WM_MOVE |
| ShowWindow ✓ | `SDL_ShowWindow`/`HideWindow`; first show sends WM_SHOWWINDOW, WM_ACTIVATEAPP, WM_NCACTIVATE, WM_ACTIVATE, WM_SETFOCUS |
| UpdateWindow ✓, GetWindowRect ✓, GetClientRect ✓, SetWindowPos ✓ | no frame: window rect = client rect at x,y; `SetWindowPos` resizes/moves the SDL window and sends WM_SIZE/WM_MOVE. The SDL window is exactly the size the game asked for (1280×960 by default, or `--window`) |
| DestroyWindow, SetWindowTextA, Get/SetWindowLongA, CallWindowProcA | WM_DESTROY + `SDL_DestroyWindow`; title; WNDPROC/STYLE/EXSTYLE/USERDATA; call32 |
| PeekMessageA, DispatchMessageA, PostMessageA, SendMessageA, PostQuitMessage, TranslateMessage | posted-message queue fed by SDL events (see "Input": close → WM_CLOSE, keys → WM_(SYS)KEYDOWN/UP, focus → WM_ACTIVATE); filters ignored; no WM_CHAR (TranslateMessage is a no-op: the game never reads characters from messages) |
| DefWindowProcA ✓ | WM_NCCREATE/WM_NCACTIVATE → TRUE, WM_CLOSE → DestroyWindow, else 0 |
| GetSystemMetrics ✓ | SM_CXSCREEN/SM_CYSCREEN from SDL's desktop mode; others logged → 0 |
| LoadIconA ✓, LoadCursorA ✓, GetDC, ReleaseDC, SetForegroundWindow, FindWindowExA | tokens / TRUE / NULL |
| ShowCursor | display counter → `SDL_ShowCursor`/`SDL_HideCursor` |
| MessageBoxA | printed as `[MessageBox] caption: text`, returns IDOK |
| wsprintfA ✓ | cdecl; `%[-#0 +][width][.prec][h/l]{d i u x X c s}`, NULL `%s` → `(null)`, each spec through host `snprintf` |
| GetKeyboardLayoutNameA | `00000409` |
| SetTimer, KillTimer | accepted and logged; no WM_TIMER delivery yet |
| DialogBoxParamA | dialogs unsupported: logged, −1 |
| GDI32 GetDeviceCaps | BITSPIXEL 32, PLANES 1, HORZRES/VERTRES = screen, VREFRESH 60 |

Not implemented (trap if called): `RtlUnwind`, `GetWindowTextA` and the dialog-item
family (`GetDlgItem`, `SendDlgItemMessageA`, `Set/GetDlgItemTextA`, `EnableWindow`,
`EndDialog`, `GetParent`, `GetDlgCtrlID`).

### Small DLLs (`w32_misc.asm`, `w32_dinput.asm`)

| import | semantics / shortcut |
|---|---|
| WINMM timeGetTime | = GetTickCount |
| ole32 CoInitialize ✓ / CoUninitialize / CoCreateInstance | S_OK / – / no COM servers: `REGDB_E_CLASSNOTREG`, CLSID logged |
| VERSION GetFileVersionInfoSizeA ✓, GetFileVersionInfoA ✓, VerQueryValueA ✓ | a fake version block that is just a `VS_FIXEDFILEINFO` carrying **our port's version** (see "Game version" below); only the root `\\` query answers |
| SHELL32 ShellExecuteA | `gta2manager.exe` (OPTIONS) → logged `suppressed`, returns 42 (success) and posts `WM_ACTIVATE(WA_ACTIVE)`, see "OPTIONS" below; anything else logged, `SE_ERR_FNF` |
| DPLAYX DirectPlayCreate, DirectPlayLobbyCreateW | `E_FAIL` (network play is out of scope) |
| DINPUT8 DirectInput8Create ✓ | **must succeed** (failure is fatal, `0x44BA2B` → error handler `0x450530`) |
| IDirectInput8A (11 methods) | CreateDevice ✓ → device (kind = GUID.Data1: keyboard/mouse); EnumDevices enumerates nothing (no joysticks); most others DI_OK |
| IDirectInputDevice8A (32 methods) | real keyboard + mouse fed by SDL3, see "Input" |
| mss32 (52) | 36 real (`host/c/audio.c`, table `w32_mss32.asm`, see "Audio"); the 16 `AIL_*3D*` exports keep the silent default |
| binkw32 (18) | default silent stub: 0, correct stdcall pop from the `@N` decoration; first call logged |

### Hooks (`w32_hooks.asm`)

| address | function | why |
|---|---|---|
| `0x4031C0` | `GetDXVersion(DWORD* ver, DWORD* platform)` — Microsoft's DirectX SDK sample (Ghidra name `LoadDirectInputFuncs`) | it creates DirectDraw objects and surfaces only to measure the DirectX version, and WinMain refuses anything below `0x601` (`0x4D11DB`, "ERROR: Incorrect version of DirectX"). The hook answers `0x801` / NT. |
| `0x41F3E9` | `CameraPosApply` (JMPHOOK, 7 bytes) — inside the camera update, `cameraPosTarget` (camera+0x10) is copied into `cameraPosTarget2` (camera+0), which `cameraPos` then follows; `esi` = Camera* | multiplies the target zoom (+0x1c) by `camera.zoom` from config.yaml (default 70%) and skips the original copy. The view scale is `cameraPos.zoom`, not `uiScale`: forcing `uiScale` = 1.0 at 1280×960 only halved the HUD (measured). (seuko-mod `camera-pos-apply.cpp`) |
| `0x4BE394` | `call Fix16_MulInt` (CALLHOOK) — thiscall `0x401BD0`, out = main camera `uiScale` × shadow offset | scales the shadow offset by the same zoom, so shadows stay under their sprites (seuko-mod `scale-shadow.cpp`). |
| `0x472535` | `call DrawMapLayer` (CALLHOOK) — fastcall `0x4720E0(S12*)`, per map layer, after its blocks are queued: inline queue at S12+0x1c, count +0x2efc, 1500 entries, no bounds check | safety valve: above 1200 entries the zoom-out is reduced 5 points per layer (Downtown street level: 99 at 100%, 357 at 50%, 1271 at 25%). (seuko-mod `draw-map-layer.cpp`) |
| `0x45A61F` | `call DrawUI` (CALLHOOK) — fastcall `0x4CA440`, the HUD, once per gameplay frame | before it run the modules' `DM_FRAME` hooks (the Ped paths and Road network overlays, `host/c/menu/overlays.c` calling C32 `debug_paths.c` / `debug_roads.c`, our persistent police roadblocks (`host/c/menu/roadblocks.c` calling C32 `roadblocks.c`) with `PoliceManager_TryCreateRoadblockAt` `0x4AEE70` on our own slots, see `docs/re/gangs-and-peds.md` §7, the emergency calls of C32 `emergency.c`) and the menu's deferred actions; right after it our debug menu (`host/c/menu/`, glue in `debug_menu.asm`, `docs/debug-menu.md`) with the game's `DrawGTAText` (`0x4CC100`), `DrawFlatRect2D` (`0x474110`) and `DrawSprite2D` (`0x4CBA50`); its key handling sits in front of `input_key`. (seuko-mod `draw-ui.cpp`) |
| `0x4CA4F9` | `call Hud_PauseOverlay_Draw` (CALLHOOK) — stdcall `0x4C9FA0`, the game's pause screen, called by DrawUI while paused | skipped while the K menu holds the pause (`host/c/menu/core.c` `dm_pause_sync`, `docs/debug-menu.md` "Pause"); else the original |
| `0x4A7901` | `call Player_MoveOnFoot` (CALLHOOK) — thiscall `0x4A5C50(Player*, Ped*)`, ret 4, in Player_HandleControls when the player is on foot: keys → `Player.turnRate` (+8) and `Player.moveSpeed` (+0xC) | after the original: strafe keys held (`di_keys`, config `controls:`) → a heading offset for this tick's move (±360 Ang16, ±180 with forward or back) and, without forward/back, `moveSpeed = +1.0` so the walker moves; mouse turning → `turnRate` = the game's own value + the tick's mouse delta (the game's value is put back before the next call, so its key ramp is unchanged). Own analysis, `docs/re/ped-movement-collision.md` §6. |
| `0x49AC76` | inside `PedGameObject_StateWalk` (JMPHOOK, 6 bytes `mov al,[esp+0x11]; test al,al`), `esi` = the walking ped's PedGameObject; every walking ped passes | for the player's PedGameObject with a strafe offset: saves the heading into the walker's local `[esp+0x24]`, clears the flag `[esp+0x11]` and turns the heading by the offset. Probe, tile-edge tests, wall slide and sprite obstacles then run along the strafe direction, and the walker restores the facing at `0x49B0A5` — the game's own backward-walk mechanism (`0x49AA8E`). Measured (Downtown start, facing north): E moves +x, Q −x with the heading unchanged, both stop at the walls. |

## Input (`w32_dinput.asm`, `pump_sdl` in `w32_user32.asm`)

### Which path the game reads (measured in Ghidra + llvm-objdump on vanilla 11.44)

- **Frontend menu: DirectInput `GetDeviceState`, polled.** `InitFrontend` → `FrontEnd_CreateKeyboardDevice`
  `@0x453D80` (was `dInput8`; frontend2.cpp) creates its own keyboard (`GUID_SysKeyboard`,
  `c_dfDIKeyboard` @`0x577EB4`, 256 bytes, coop `6` = NONEXCLUSIVE|FOREGROUND) into
  `FrontEnd+4` (`keyboardDevice`) and acquires it. Each frame `0x452050` calls `0x452000`:
  `GetDeviceState(256, FrontEnd+8)`, re-Acquire on `DIERR_INPUTLOST`/`NOTACQUIRED`, then
  edge-detects 7 keys into `FrontEnd+0xC9B8..0xC9BE`: LEFT `CB`, RIGHT `CD`, UP `C8`,
  DOWN `D0`, RETURN `1C`, ESCAPE `01`, DELETE `D3`. Only while `FrontEnd+0x10D` is set:
  `InitFrontend` sets it, WndProc's `WM_ACTIVATE` (via `0x4D09D0` → `0x453A30`) writes the
  active flag into it.
- **In-game: DirectInput `GetDeviceData`, buffered.** `DInput_CreateKeyboardDevice` `@0x44BB30`
  (diutil.cpp; stdcall, 2 args, `ret 8` — Ghidra's `void` is wrong) creates the keyboard
  `0x5E8F4C` with `DIPROP_BUFFERSIZE = 10000` and acquires it; `0x44C0F0` reads one
  20-byte `DIDEVICEOBJECTDATA` per call until the buffer is empty (`0x44BA60` first asks
  for the count with `rgdod = NULL`, `INFINITE`, `DIGDD_PEEK`).
- **Window messages: no keys.** WndProc `0x4D0A00` never handles `WM_KEYDOWN`/`WM_CHAR`;
  it handles `WM_SYSKEYDOWN` (Alt+Enter → mode switch, F10/Alt swallowed),
  `WM_ACTIVATE` (focus gate above, exclusive mouse), `WM_SETFOCUS`/`WM_KILLFOCUS` (audio,
  video restore/close), `WM_DESTROY` → `PostQuitMessage`. Window close: SDL quit/close →
  `WM_CLOSE` → DefWindowProc → DestroyWindow → `WM_DESTROY` → `WM_QUIT`.
- **Mouse: never read.** `InitMouseExclusive` `@0x4CAD30` (from `SetFullscreenMode`)
  creates `GUID_SysMouse` (`c_dfDIMouse` @`0x5782C4`) into `0x6735A8` with coop `5`
  (EXCLUSIVE|FOREGROUND) and acquires it: only to hide/capture the cursor in full
  screen. No `GetDeviceState`/`GetDeviceData` on it anywhere (all 8 references are in
  `0x4CAD30..0x4CADCA`). No `WM_MOUSEMOVE` handling either. The host reads the SDL
  motion itself for `controls.mouse_turn` (`c32_host.c` service `foot_input`, for
  `c32/player_move.c`), and turns relative mode
  on while the player walks with it enabled.

### What the shim does

- **Mapping.** `key_table`: SDL scancode → (DIK, VK, name) for the whole keyboard —
  letters, digits, punctuation, F1–F15, arrows, the Ins/Del/Home/End/PgUp/PgDn block,
  keypad, Ctrl/Shift/Alt/Win left and right (macOS Cmd = Win, Option = Alt).
- **State.** SDL key events (not `SDL_GetKeyboardState`, so pushed events count too)
  update one `di_keys[256]` (`0x80` = down) and append a record `{DIK, 0x80/0, tick,
  sequence}` to a 1024-entry ring. SDL auto-repeat does not reach DirectInput.
- **GetDeviceState** (keyboard): `di_keys`, plus every key pressed since this device's
  previous read (ring records past its own cursor), so a tap that begins and ends
  between two polls is still seen once. *Deviation:* Windows would drop such a tap.
  Keys already down when the device was acquired read as **up** until released
  (`DV_STALE`). *Deviation:* Windows reports them held. `InitFrontend` (`0x456A60`)
  zeroes the menu's previous-key bytes (`FrontEnd+0xC9BF..0xC9C5`) and the menu poll
  (`0x452050`) treats down-now-and-not-before as a press, so the RETURN that confirms
  quitting a game (the in-game reader acts on key-down) was still held at the frontend's
  first poll and chose "RESUME SAVED STATUS" on the "PLAYER QUIT!" screen: the level
  started again. On Windows the slow frontend load hides it; ours takes milliseconds.
  Mouse: `DIMOUSESTATE`/`DIMOUSESTATE2` with motion and wheel (`×120`) accumulated since
  the last read (fraction kept), buttons in DI order (left, right, middle, X1, X2).
- **GetDeviceData** (keyboard): per-device read cursor into the ring, set on Acquire;
  `DIGDD_PEEK`, `rgdod = NULL` (count/flush), `DI_BUFFEROVERFLOW` when more than
  `min(buffer size, 1024)` records are pending, `DIERR_NOTBUFFERED` without a buffer
  size. Mouse: no buffered data.
- **Acquire/Unacquire.** Acquire needs a data format; a FOREGROUND device needs focus
  (`DIERR_OTHERAPPHASPRIO` otherwise); twice → `DI_NOEFFECT`. Unacquired devices answer
  `DIERR_NOTACQUIRED`. An EXCLUSIVE mouse turns on SDL relative mode (cursor hidden and
  captured), Unacquire/Release/focus loss turn it off. Set/GetProperty know
  `DIPROP_BUFFERSIZE`; GetCapabilities reports an attached keyboard/mouse.
- **Focus.** `SDL_EVENT_WINDOW_FOCUS_LOST`: every held key is released (key-up records
  go into the ring), mouse buttons cleared, capture off, `WM_ACTIVATEAPP(0)` +
  `WM_ACTIVATE(WA_INACTIVE)` posted; gained: `WM_ACTIVATEAPP(1)` + `WM_ACTIVATE(WA_ACTIVE)`.
  *Deviation:* Windows would return `DIERR_INPUTLOST` and drop the buffer; the in-game
  reader is change-based and would keep a key held. `WM_SETFOCUS`/`WM_KILLFOCUS` are not
  sent on SDL focus changes (they reopen/close the video mode). The host assumes focus
  at start until SDL says otherwise.
- **Messages.** Every mapped key also posts `WM_KEYDOWN`/`WM_KEYUP` with VK and a real
  lParam (scan code = DIK & 0x7F, extended bit = DIK & 0x80, repeat bit 30 for SDL
  repeats, bits 30–31 on release); with Alt held (or F10) `WM_SYSKEYDOWN`/`UP` + bit 29,
  so Alt+Enter reaches the game's mode switch.

### Evidence

`--input-selftest` (no renderer needed) drives the game's own code: DirectInput8Create
through the IAT into `g_DirectInput8` `0x5E8FA4`, `FrontEnd_CreateKeyboardDevice` `@0x453D80` on a zeroed FrontEnd, the in-game
`DInput_CreateKeyboardDevice` `@0x44BB30`, `InitMouseExclusive` `@0x4CAD30`; then per frame the
frontend poll `0x452050`, `GetDeviceData` on `0x5E8F4C` one record at a time, the mouse
state. It pushes 10 key taps (one shorter than a frame, one auto-repeat, three held
across a focus loss) plus mouse motion/buttons and checks 14 counters — 14/14 PASS,
repeatable (pushed events are marked in `SDL_Event.reserved`; real devices are ignored
in this mode):

```
  [input] SDL key down -> DIK_DOWN (0xd0), record #0
  [input] GetDeviceState(keyboard 0x2001f250) <- 0x452016: held DIK_DOWN
  [menu] frame 10: frontend sees DOWN pressed (0x452050 edge flag)
  [input] GetDeviceData(keyboard 0x2001f370) #0 down DIK_DOWN (0xd0) <- 0x1000001d
  ...
  [input] focus lost
  [input] SDL key up   -> DIK_A (0x1e), record #13
  ...
  [PASS] in-game GetDeviceData records: 20 (expected 20)
  [PASS] WM_KEYDOWN/WM_SYSKEYDOWN posted: 11 (expected 11)
input selftest: 0 failures
```

End to end with the renderer (`--entry --keys=... --frames=N --shot=...`, 2026-10-20):
frame 300 without keys shows PLAY selected; `200:DOWN` → OPTIONS, `200:DOWN,240:DOWN` →
QUIT, `200:RETURN` → the PLAY submenu (player MUCHCASH, START PLAY IN AREA),
`200:RETURN,280:ESCAPE` → back to the main menu. RETURN on OPTIONS: see "OPTIONS" below — the game stays in the menu
(`150:DOWN,200:RETURN,300:UP` ends on PLAY). A real key (System Events `key code 125`) was
seen once in `--input-test` (SDL → `DIK_DOWN` → the in-game buffer); automating real
keys needs the test window frontmost, which `osascript` cannot hold reliably.

### OPTIONS (`gta2manager.exe`)

Vanilla keeps its settings in a separate program. RETURN on OPTIONS calls
`0x4D0820` (named `WinMain` in Ghidra; own analysis), which does
`ShowWindow(main, SW_SHOWMINNOACTIVE)`, then — if `OpenMutexA("GBH_BOB_MUTEX")` finds no
running manager (ours never does) — `PostMessageA(main, WM_ACTIVATE, WA_INACTIVE)` and
`ShellExecuteA(0, 0, "gta2manager.exe", 0, cwd, SW_SHOWNORMAL)`; a result `<= 32` is
`DisplayError` "Failed to launch 'GTA2 Manager' correctly" and the game exits.

The shim answers `gta2manager.exe` (basename, case-insensitive) with 42 and logs
`[w32] ShellExecuteA(gta2manager.exe) suppressed`; nothing is launched. On its own that
leaves the menu dead: the self-posted `WA_INACTIVE` mutes the frontend's keys until the
window is activated again (measured: `150:DOWN,200:RETURN,300:UP` stayed on OPTIONS).
So the shim also posts `WM_ACTIVATE(WA_ACTIVE)` right behind it — the user returning
from a manager that closed at once. `ShowWindow(7)` is harmless here: our `ShowWindow`
never minimizes. Our own options screen replaces this later.

## Audio (`host/c/audio.c`)

64-bit host C since Seq 57 (2026-10-22; NASM `w32_audio.asm` before, same behaviour and
log lines): `host/c/audio.c` (exports, mixer, device, focus mute, `--audio-dump`),
`host/c/audio_wav.c` (WAV / IMA ADPCM), `host/c/audio.h`. The 36 `AIL_*` handlers are C
import handlers listed in `host/w32_mss32.asm` (docs/host-c.md, "Import shims in C").

### How the game uses mss32 (own analysis of vanilla 11.44, code `0x4B5F70`..`0x4B73E0`)

- Sound manager object at `0x66C950`. Startup: `AIL_startup`, `AIL_set_preference`,
  `AIL_waveOutOpen(&drv, 0, -1, fmt)` with **22050 Hz, 16-bit, stereo**. Until now that
  call "succeeded" with a 0 driver and the game quietly shut its audio down again.
- `AIL_enumerate_3D_providers` → 0 (none), so it stays on the **2D sample API**:
  1 8-bit sample (`+0x98`) + 16 16-bit mono samples (`+0x58`) via
  `AIL_allocate_sample_handle`.
- **SFX banks**: `data\audio\<style>.RAW` (raw PCM) + `.SDT` (0x140 entries × 24 bytes:
  offset, size, rate, …). The game reads them itself into `AIL_mem_alloc_lock` memory
  and points samples into it (`AIL_set_sample_address`). The frontend bank is
  `fstyle.raw/.sdt` (568 120 bytes, 18 entries, 22050 Hz s16 mono). A stereo menu effect
  is two entries played at once as two samples, pan 0 and pan 127.
- **Music**: `AIL_open_stream(drv, "data\gtaudio\<n>[A].wav")`, `loop_count 0`
  (forever), `set_stream_volume` from the `CDVol` setting (measured `0x4C`). The
  frontend asks for `data\gtaudio\d.wav` and retries every frame while it is missing.
  The 11.44 install has no `data\gtaudio` folder; `tools/add-music.sh` adds the 22 files
  from the freeware installer to the pak. Stations `<n>.wav` are IMA ADPCM stereo, the
  `<n>a.wav` variants IMA ADPCM mono, `d.wav` / `a.wav` PCM s16 stereo, all 22050 Hz, up
  to 24 min (`1.wav`, 32 MB). There is no `m.wav`, and not every station has an `a`
  variant (1-4 and 12 have none, `101a.wav` has no plain one): those opens return 0, as on
  Windows.
- **Voices**: `data\audio\vocals\*.wav`, IMA ADPCM (format 0x11, 4-bit, stereo,
  block align 1024), played as streams.
- Volumes: SFX samples come out at vol 10 (registry `SFXVol` = 11), master 127.

**Call contract of the `MssAudio` wrapper** (`g_MssAudioDevice` 0x66C950, Seq 27 U1 pass
2026-10-24, read in code, not traced at runtime). Every wrapper indexes a handle array and
tail-jumps to the AIL import with the remaining arguments unchanged, so this is what the host
reimplementation sees. The game-side mixer above it is in
[cars-and-car-ai.md](re/cars-and-car-ai.md) §2.

- **2D voice `v`** (`samples2D[v]`, MssAudio+0x58): `MssAudio_Sample_SetAddress(v, bankBase +
  entry.offset, entry.size)` 0x4B60C0, `_SetPlaybackRate(v, rate)` 0x4B6150 (SDT rate ± jitter, Doppler
  applied), `_SetVolume(v, vol)` 0x4B6110, `_SetPan(v, pan)` 0x4B6130 (slewed ±10 per frame),
  `_SetLoopCount(v, n)` 0x4B6190, `_SetLoopBlock(v, loopStart, loopEnd)` 0x4B6170 (SDT loop points,
  `MssBankEntry.loopStart` +0x10 / `loopEnd` +0x14, −1 = none), `_Start`, `_End`, `_IsPlaying`
  (AIL_sample_status).
- **3D voice** (`samples3D[v]`, +0x26C4, only with a DirectSound3D provider): the same set plus
  `MssAudio_Sample3D_SetPosition(v, x, 0.0, -y)` 0x4B62D0 — world x → X, world y → −Z, height is
  always 0 — and `Sample3D_SetDistances`. The game opens 3D only when a provider is enumerated.
- **Extra sample** (`extraSample` +0x98, one 8-bit HSAMPLE): police-radio phrases
  (`MssAudio_ExtraSample_PlayEntry(entry)` 0x4B69B0: SDT rate, pan 0x40, loop 1, volume
  `sfxVolume*0x6E>>7`) and phone chatter (`_ExtraSample_PlayRange(first, last)` 0x4B6A80: rate 0x4682
  = 18050, one sample spanning several consecutive bank entries).
- **Streams** (`streams[2]` +0x9C; 0 = music / radio, 1 = vocals): `MssAudio_Stream_OpenTrack(stream,
  id, plain)` 0x4B70C0. Stream 0 opens `data\gtaudio\<id>.wav` when `plain` (radio band 1), else
  `<id>A.wav` (band 0), looping forever; stream 1 opens `data\audio\vocals\<name>`, played once. Also
  `_Stream_SetVolume(stream, vol & 0xFF)` 0x4B6890 (**the volume is masked to a byte** before
  AIL_set_stream_volume; the radio sets it to 0 on every station switch and the static-noise update
  raises it again), `_SetPlaybackRate` 0x4B68C0, `_SetPositionMs` 0x4B6910 / `_GetPositionMs`
  (save / restore a station's position), `_GetLengthMs`, `_Close`.
- **Frontend music** is the same stream 0 through `MssAudio_MusicStream_Open(track)` 0x4B6700:
  track 0 `d.wav`, 1 `m.wav`, 2 `a.wav` (names at 0x575214); `SoundManager.musicLoopTrackD` picks
  d vs m.
- Startup: `MssAudio_Startup2D` 0x4B7250 (AIL_startup, waveOutOpen 22050 Hz, 16 2D samples, master
  0x7F); `Mss_Init2DSamples(arg)` 0x4B6F70 (callers pass 1, meaning not decoded); 3D:
  `MssAudio_Open3DProvider(idx)` 0x4B6550 sets `selected3DProviderIdx` +0x26B4 and `eaxSupported`
  +0x26B8 (provider answers "EAX environment selection" != −1); `Mss_Init3DSamples` 0x4B72B0 returns
  the voice count (provider max, capped 16, < 8 = fail).
- Prototypes (all `__thiscall (MssAudio*, …)`): `Sample_SetVolume/Pan/PlaybackRate/LoopCount` and
  `Sample3D_SetVolume/PlaybackRate/LoopCount` 0x4B62B0 / 0x4B6320 / 0x4B6360 take `(int voice, int
  value)`; `Sample(3D)_SetLoopBlock` 0x4B6170 / 0x4B6340 `(int voice, int loopStart, int loopEnd)`;
  `Stream_SetVolume/SetPlaybackRate/SetPositionMs` `(int stream, int value)`; `MusicStream_IsDone`
  0x4B66A0 returns bool; `Eax_SetEffectParams` 0x4B6460 `(float, float, undefined4)` (RET 0xC,
  semantics not decoded).

### Design

- **Everything runs on the game thread.** `audio_pump` (called from `pump_sdl` every
  frame and from `AIL_delay`) mixes 256-frame chunks into int64 accumulators, clips to
  s16 and puts them into one `SDL_AudioStream` (`SDL_OpenAudioDeviceStream`, 22050 Hz
  stereo s16), keeping ~2048 frames (~93 ms) queued. SDL's device thread only drains
  that stream, so no game or shim state is touched off-thread. No callback.
- **Voices**: 64 records; `HSAMPLE`/`HSTREAM` = `0xA10000 + 16 * index`, `HDIGDRIVER`
  = `0xA0D000` (tokens, never dereferenced by the game). Per voice: 8/16-bit, mono/
  stereo, signed/unsigned 8-bit, rate (16.16 step, nearest-sample resampling), volume
  and pan 0..127 (linear, pan 64 = both sides full), loop count and loop block.
- **Streams**: `AIL_open_stream` reads the whole file. PCM plays from that buffer; IMA
  ADPCM is decoded one block (~1017 frames) at a time as the mixer reaches it, into a
  block buffer behind the file. Decoding a whole station up front took 42-196 ms of the
  game thread per open (measured, `1.wav` = 121 MB of s16), at every car entry and radio
  band change; block decode opens in 1-7 ms and gives byte-identical PCM (checked on all
  22 music files and 20 vocals). Missing/unsupported file → 0, logged once per name.
- **Focus (the game's own)**: `AIL_digital_handle_release/reacquire` pause/resume the
  device. The game calls them only from WndProc `0x4D0A00` on `WM_KILLFOCUS`
  (`0x4D0B2B` → `0x410640` → `0x416620` → `0x4B6670`) and `WM_SETFOCUS` (`0x4D0A39` →
  `0x410650` → `0x416D60` → `0x4B6680`); jump table `0x4D0E10`, own analysis. Those two
  messages also close/reopen the video mode, so the host never sends them (see
  "Input"); `WM_ACTIVATE(APP)` does not touch audio, and nothing pauses the game, which
  keeps running in the background.
- **Mute while unfocused (host)**: the device stream's gain is 0
  (`SDL_SetAudioStreamGain`) whenever the main window lacks `SDL_WINDOW_INPUT_FOCUS` or
  is hidden/minimised, 1 otherwise. `focus_poll` reads the window flags at the start of
  every SDL pump (before the mixer runs), and `FOCUS_GAINED`/`FOCUS_LOST` apply a change
  within the same pump. Polling is what covers a window that **never** gets focus — the
  game started from a terminal or a dev3 pane while the user works in another app sends
  no focus event at all, and an event-only mute left it audible. Logged once at the
  start (`[aud] window initially unfocused: output muted …` / `… initially focused:
  output unmuted`) and on every change (`[aud] window now unfocused: …` / `[aud] window
  now focused: output unmuted`). The mixer keeps running on the device clock, so samples and streams
  advance and end exactly as if audible: no game state changes, nothing restarts,
  nothing is lost, and on return you hear what is playing *now*. A pause
  (`SDL_PauseAudioStreamDevice`) was rejected: it stalls the device-clock mixer while the
  game runs on, so sounds would end late and stream positions drift. The gain is
  applied when SDL pulls data, so the ~93 ms already queued goes silent at once.
  `--audio-dump` records the mix before the gain (unaffected). `--bg-audio` disables
  the mute. Independent of the game's own release/reacquire above.
- **No audio device**: the mixer advances on the wall clock instead, so
  `--audio-dump` works headless.

### Exports implemented (36)

`startup`, `shutdown`, `set_preference`, `waveOutOpen`, `waveOutClose`,
`mem_alloc_lock`, `mem_free_lock`, `set_digital_master_volume`,
`digital_handle_release`, `digital_handle_reacquire`, `delay`,
`enumerate_3D_providers` (none); samples: `allocate/release_sample_handle`,
`init_sample`, `set_sample_type`, `set_sample_address`, `set_sample_playback_rate`,
`set_sample_volume`, `set_sample_pan`, `set_sample_loop_count`,
`set_sample_loop_block`, `start_sample`, `end_sample`, `sample_status`; streams:
`open/close/start_stream`, `stream_status`, `set_stream_loop_count`,
`(set_)stream_volume`, `(set_)stream_playback_rate`, `(set_)stream_ms_position`.
The 16 `*3D*` exports stay on the silent default (never reached: no provider).

### Proof: `--audio-dump=PATH.wav`

Writes the mixed output (22050 Hz stereo s16) and at exit prints its duration, the
number of sample starts / streams and peak + rms per second. Measured:

- `--keys=300:DOWN,360:DOWN,420:UP`: every key tap starts one stereo pair from
  `fstyle.raw` at the tap's frame (`start_sample ... len 47872 ... pan 0` / `pan 127`;
  UP plays a different entry, len 47958).
- Stream path checked with a temporary `data\gtaudio\d.wav` (a copy of
  `vocals\gta.wav`, IMA ADPCM, removed again): the dump matches macOS `afconvert`'s
  decode of the same file with correlation 0.9999997, gain 0.596 (= stream volume
  76/127). It looped every 3.3 s, as the game asks for (`loop_count 0`).
- Radio, with the music pak: entering a parked Downtown car opens a station
  (`data\gtaudio\6.WAV` / `2.WAV`, random per car), leaving it switches to `12.WAV` faded
  out. Dump rms in the car ~3500-4100 against ~600 (engine only) with the vanilla pak.

Listen live: `host/build.sh --load --entry` and move through the menu.

### Gaps

- 3D samples / EAX / A3D (in-game positional sound) — not offered.
- Bink video audio (`binkw32` is still silent; no movies are shipped either).
- Resampling is nearest-sample; every rate the frontend uses is 22050 Hz = the mix
  rate, so it is exact there.

## What the game needs next (notes for later work)

- **Renderer**: done (frontend and gameplay) — shim tables `dmavideo` / `d3ddll` in
  `host/w32_renderer.asm`, handlers in `host/c/renderer*.c`, see `renderer-sdl.md`.
- **Input**: done (keyboard + mouse, see "Input"). Joysticks (EnumDevices
  `DI8DEVCLASS_GAMECTRL`) are not offered; WM_CHAR is not generated.
- **Audio**: frontend, menu music and car radio done (see "Audio").
  In-game: 3D samples (no provider offered, so the game should stay on 2D — unverified
  in gameplay), Bink video audio.
- **Not done**: SEH dispatch (`RtlUnwind`), WM_TIMER, dialogs, INI files, registry
  persistence, x87 control word (still macOS' default, not Windows' `0x27F`).

## Game version (`GTA2_VERSION_MAJOR` / `GTA2_VERSION_MINOR`)

The main menu's bottom line ("GTA2 V23.31") is our port's version, set by two
constants at the top of the VERSION shims in `host/w32_misc.asm`:

```nasm
GTA2_VERSION_MAJOR equ 23
GTA2_VERSION_MINOR equ 31
```

Bump them there and nowhere else. How the game uses them (Ghidra, read-only):

- `WinMain` calls `GetGameVersion(&major, &minor)` (`0x4D0920`, call at `0x4D11C7`).
- It runs `GetFileVersionInfoSizeA("GTA2.EXE")` → `GetFileVersionInfoA` →
  `VerQueryValueA(block, "\\")` and takes `major = HIWORD(dwProductVersionMS)`
  (`VS_FIXEDFILEINFO + 0x12`), `minor = LOWORD(dwProductVersionMS)` (`+ 0x10`).
  `dwFileVersion*` is not read; the shim fills it with the same value anyway.
- The menu formats them with `"v%d.%d"` (`0x5738F4`, also `"Coop v%d.%d"` at
  `0x573A98`); the frontend font is upper-case only, hence "V". Minor is printed
  without padding: `5` renders "V23.5", not "V23.05".
- The vanilla exe's own resource carries ProductVersion `11.44` (`0x000B002C`);
  without the shims the game shows "V0.0".
