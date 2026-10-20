# Win32 shims

How `host/loader --entry` runs vanilla `gta2.exe` from its PE entry point, and every
import it implements. Code lives in `host/w32_*.asm`, which `host/loader.asm` pulls in
with `%include` (one NASM unit).

## Current stopping point (2026-10-20)

**Update:** with the renderer plugins implemented (`host/w32_renderer.asm`,
[`renderer-sdl.md`](renderer-sdl.md)) the game no longer stops: it loads both plugins,
initialises the (silent) audio, loads the frontend and **runs the frontend loop,
drawing the main menu**, until the window is closed (or `--frames=N`). The section
below is the record of the stop before that step.

The game runs the MSVC CRT startup and WinMain, creates its window (a real SDL3
window, 960×720), initialises DirectInput, loads its video plugin, resolves its 22
`Vid_*` exports, and stops at the **first renderer call: `dmavideo.dll!Vid_InitDLL`,
called from `0x4D3505`**. That is where the renderer work picks up.

Real console output, `host/build.sh --load --entry` (the PE-loading part and the 15
function checks are omitted, they are unchanged from `host/README.md`):

```
hook: 0x4031c0 GetDXVersion -> host
SDL 3.4.14 loaded from /Users/arsenyp/.local/opt/sdl3-x86_64/lib/libSDL3.0.dylib
registry: gta2_install.reg -> 8 keys, 54 values (in memory only)
...
functions: 15/15 checks passed
--entry: jumping to the PE entry point 0x4d84f9
  [w32] GetProcAddress(KERNEL32, GetProcessHeap) -> 0x1000487a (shim)
  [w32] GetProcAddress(KERNEL32, IsProcessorFeaturePresent) -> 0x10004884 (shim)
  [ods] Perf: Clock speed = 250 MHz
  [w32] GetFileVersionInfoSizeA(GTA2.EXE): no version resources -> 0
  [w32] CreateFileA(data\j.gxt) -> not found
  [w32] RegisterClassA(WinMain) wndproc 0x4d0a00
  [w32] CreateWindowExA(GTA2) 100x100 -> hwnd 0xab0000 (SDL window), wndproc 0x4d0a00
  [w32] ShowWindow(0xab0000): SDL_ShowWindow -> 1
  [w32] DirectInput8Create(version 0x800) -> IDirectInput8A 0x2000de20 (silent: no input yet)
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
a window titled "GTA2", 960×720 client area, black).

`d3ddll.dll` is not loaded yet: the game loads `dmavideo.dll` first and calls
`Vid_InitDLL` before anything else.

### Flags

| flag | effect |
|---|---|
| `--entry` | jump to the PE entry point after the function checks |
| `--trace` | one line per shim call: `DLL!Name(args) = result <- caller` (+ WndProc messages, file opens) |
| `--hold` | when the run stops, keep pumping SDL events for 5 s so the window is visible |
| `--frames=N` | exit (status 0) after N presented frames (`renderer-sdl.md`) |
| `--shot=PATH` | with `--frames`: save the last frame's back buffer as BMP |

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
- **Hooks** (`w32_hooks.asm`): a game function's entry is overwritten with `jmp` to a
  slot named `gta2.exe!Name`, after checking its first 8 original bytes.
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
match the 64-bit-inode struct layouts; the plain names are the legacy ABI.

## Policies (decisions with long-term impact)

- **Paths.** The host `chdir`s into the directory holding `gta2.exe`; the game is told
  it lives in `C:\GTA2` (`GetModuleFileNameA` → `C:\GTA2\gta2.exe`,
  `GetCurrentDirectoryA` → `C:\GTA2`). `C:\GTA2\x` and relative paths map into the game
  directory, any other absolute path is refused (not found). Backslashes become `/` and
  every component is matched case-insensitively against the disk. Writes land in the
  task's own `gta2/` copy (e.g. the CRT's `test\error.log`).
- **Registry.** In memory, seeded from `gta2/gta2_install.reg` at startup. Writes are
  kept for the life of the process only — not persisted (later: write back to a text
  file next to the game).
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
| LoadLibraryA ✓ | system DLL → its fake handle; otherwise a fake module if the file exists in the game dir (`dmavideo.dll`); else NULL, error 126 |
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

### KERNEL32 — files (`w32_files.asm`)

| import | semantics / shortcut |
|---|---|
| CreateFileA ✓ | path policy above; access → `O_RDONLY/O_WRONLY/O_RDWR`, all five dispositions; failure → `INVALID_HANDLE_VALUE`, error 2, logged |
| ReadFile, WriteFile ✓, SetFilePointer, SetEndOfFile, FlushFileBuffers | `read`/`write`/`lseek` (64-bit with the high dword)/`ftruncate`; no overlapped I/O |
| GetStdHandle ✓, GetFileType ✓ | std handles map to fds 0/1/2 (`FILE_TYPE_CHAR`); files are `FILE_TYPE_DISK` |
| GetFileAttributesA | directory / normal, or `INVALID_FILE_ATTRIBUTES` |
| FindFirstFileA ✓, FindNextFileA, FindClose ✓ | `opendir` + `fnmatch(FNM_CASEFOLD)`, `*.*` matches everything, `.`/`..` skipped; size + attributes filled |
| GetCurrentDirectoryA ✓, SetCurrentDirectoryA | always `C:\GTA2`; only the game directory itself can be set |
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
| UpdateWindow ✓, GetWindowRect ✓, GetClientRect ✓, SetWindowPos ✓ | no frame: window rect = client rect at x,y; `SetWindowPos` resizes/moves the SDL window and sends WM_SIZE/WM_MOVE |
| DestroyWindow, SetWindowTextA, Get/SetWindowLongA, CallWindowProcA | WM_DESTROY + `SDL_DestroyWindow`; title; WNDPROC/STYLE/EXSTYLE/USERDATA; call32 |
| PeekMessageA, DispatchMessageA, PostMessageA, SendMessageA, PostQuitMessage, TranslateMessage | posted-message queue fed by SDL events (close → WM_CLOSE, letters/digits/arrows/Esc/Enter/Space → WM_KEYDOWN/UP); filters ignored; no WM_CHAR yet |
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
| VERSION GetFileVersionInfoSizeA ✓, GetFileVersionInfoA ✓, VerQueryValueA | no version resources → 0 (the game asks about `GTA2.EXE` and carries on) |
| SHELL32 ShellExecuteA | logged, error |
| DPLAYX DirectPlayCreate, DirectPlayLobbyCreateW | `E_FAIL` (network play is out of scope) |
| DINPUT8 DirectInput8Create ✓ | **must succeed** (failure is fatal, `0x44BA2B` → error handler `0x450530`): fake IDirectInput8A |
| IDirectInput8A (11 methods) | CreateDevice → fake device (kind = GUID.Data1: keyboard/mouse); EnumDevices enumerates nothing; most others DI_OK |
| IDirectInputDevice8A (32 methods) | Acquire/SetDataFormat/SetCooperativeLevel/… DI_OK; GetDeviceState → all zero (nothing pressed); GetDeviceData → 0 events; GetCapabilities zeroed |
| mss32 (52), binkw32 (18) | default silent stub: 0, correct stdcall pop from the `@N` decoration; first call logged. Not reached yet. |

### Hooks (`w32_hooks.asm`)

| address | function | why |
|---|---|---|
| `0x4031C0` | `GetDXVersion(DWORD* ver, DWORD* platform)` — Microsoft's DirectX SDK sample (Ghidra name `LoadDirectInputFuncs`) | it creates DirectDraw objects and surfaces only to measure the DirectX version, and WinMain refuses anything below `0x601` (`0x4D11DB`, "ERROR: Incorrect version of DirectX"). The hook answers `0x801` / NT. |

## What the game needs next (notes for later work)

- **Renderer**: done for the frontend — shim tables `dmavideo` / `d3ddll` in
  `w32_renderer.asm`, see `renderer-sdl.md`. Gameplay drawing (tiles, lighting) is next.
- **Input**: DirectInput devices return nothing pressed. Filling `GetDeviceState` from
  `SDL_GetKeyboardState` (SDL scancode → DIK_*) is a small step.
- **Audio/video**: every mss32/binkw32 call returns 0. If the game treats a 0 from
  `AIL_startup`-style calls as fatal, those need real "no device" answers.
- **Not done**: SEH dispatch (`RtlUnwind`), WM_TIMER, dialogs, INI files, registry
  persistence, x87 control word (still macOS' default, not Windows' `0x27F`).
