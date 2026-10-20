# Win32 shims

How `host/loader --entry` runs vanilla `gta2.exe` from its PE entry point, and every
import it implements. Code lives in `host/w32_*.asm`, which `host/loader.asm` pulls in
with `%include` (one NASM unit).

## Current stopping point (2026-10-20)

**Update:** with the renderer plugins implemented (`host/w32_renderer.asm`,
[`renderer-sdl.md`](renderer-sdl.md)) the game no longer stops: it loads both plugins,
initialises the audio (real since `w32_audio.asm`, see "Audio"), loads the frontend and **runs the frontend loop,
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
| `--trace-input` | log every key change, Acquire, `GetDeviceState` view change and delivered `GetDeviceData` record (implied by `--trace`) |
| `--keys=F:KEY,...` | scripted taps: KEY (a DIK name, e.g. `DOWN`, `RETURN`, `ESCAPE`) goes down at presented frame F, up 4 frames later; pushed into SDL's queue, so it takes the real key path |
| `--input-test` | no game run: drive the game's own input code (see "Input") for ~15 s against real keys pressed in a test window |
| `--input-selftest` | the same with a scripted SDL event sequence; prints PASS/FAIL per check, exit = number of failures |

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

- **Paths.** Game files come from `data.pak` (a Stored zip, indexed once by
  `w32_vfs.asm`) plus a writable overlay, `~/Library/Application Support/gta2-resurrected/`,
  which is the host's cwd. The game is told it lives in `C:\GTA2`
  (`GetModuleFileNameA` → `C:\GTA2\gta2.exe`, `GetCurrentDirectoryA` → `C:\GTA2`).
  `C:\GTA2\x` and relative paths map to the game root, any other absolute path is
  refused (not found). Backslashes become `/`, `.` components drop, and lookup is
  case-insensitive: the overlay first, then the pak. Writes always land in the overlay
  (e.g. the CRT's `test\error.log`); a pak-only file opened for writing with
  `OPEN_EXISTING`/`OPEN_ALWAYS` is copied there first. The pak is read-only.
- **Registry.** In memory, seeded from `gta2_install.reg` (overlay or pak) at startup. Writes are
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

### KERNEL32 — files (`w32_files.asm`)

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
| UpdateWindow ✓, GetWindowRect ✓, GetClientRect ✓, SetWindowPos ✓ | no frame: window rect = client rect at x,y; `SetWindowPos` resizes/moves the SDL window and sends WM_SIZE/WM_MOVE |
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
| mss32 (52) | 36 real (`w32_audio.asm`, see "Audio"); the 16 `AIL_*3D*` exports keep the silent default |
| binkw32 (18) | default silent stub: 0, correct stdcall pop from the `@N` decoration; first call logged |

### Hooks (`w32_hooks.asm`)

| address | function | why |
|---|---|---|
| `0x4031C0` | `GetDXVersion(DWORD* ver, DWORD* platform)` — Microsoft's DirectX SDK sample (Ghidra name `LoadDirectInputFuncs`) | it creates DirectDraw objects and surfaces only to measure the DirectX version, and WinMain refuses anything below `0x601` (`0x4D11DB`, "ERROR: Incorrect version of DirectX"). The hook answers `0x801` / NT. |

## Input (`w32_dinput.asm`, `pump_sdl` in `w32_user32.asm`)

### Which path the game reads (measured in Ghidra + llvm-objdump on vanilla 11.44)

- **Frontend menu: DirectInput `GetDeviceState`, polled.** `InitFrontend` → `dInput8`
  `@0x453D80` (frontend2.cpp) creates its own keyboard (`GUID_SysKeyboard`,
  `c_dfDIKeyboard` @`0x577EB4`, 256 bytes, coop `6` = NONEXCLUSIVE|FOREGROUND) into
  `FrontEnd+4` and acquires it. Each frame `0x452050` calls `0x452000`:
  `GetDeviceState(256, FrontEnd+8)`, re-Acquire on `DIERR_INPUTLOST`/`NOTACQUIRED`, then
  edge-detects 7 keys into `FrontEnd+0xC9B8..0xC9BE`: LEFT `CB`, RIGHT `CD`, UP `C8`,
  DOWN `D0`, RETURN `1C`, ESCAPE `01`, DELETE `D3`. Only while `FrontEnd+0x10D` is set:
  `InitFrontend` sets it, WndProc's `WM_ACTIVATE` (via `0x4D09D0` → `0x453A30`) writes the
  active flag into it.
- **In-game: DirectInput `GetDeviceData`, buffered.** `directInputUtils` `@0x44BB30`
  (diutil.cpp; stdcall, 2 args, `ret 8` — Ghidra's `void` is wrong) creates the keyboard
  `0x5E8F4C` with `DIPROP_BUFFERSIZE = 10000` and acquires it; `0x44C0F0` reads one
  20-byte `DIDEVICEOBJECTDATA` per call until the buffer is empty (`0x44BA60` first asks
  for the count with `rgdod = NULL`, `INFINITE`, `DIGDD_PEEK`).
- **Window messages: no keys.** WndProc `0x4D0A00` never handles `WM_KEYDOWN`/`WM_CHAR`;
  it handles `WM_SYSKEYDOWN` (Alt+Enter → mode switch, F10/Alt swallowed),
  `WM_ACTIVATE` (focus gate above, exclusive mouse), `WM_SETFOCUS`/`WM_KILLFOCUS` (audio,
  video restore/close), `WM_DESTROY` → `PostQuitMessage`. Window close: SDL quit/close →
  `WM_CLOSE` → DefWindowProc → DestroyWindow → `WM_DESTROY` → `WM_QUIT`.
- **Mouse: never read.** `InitMouseExclusive` `@0x4CAD30` (from `fullScreenProbably`)
  creates `GUID_SysMouse` (`c_dfDIMouse` @`0x5782C4`) into `0x6735A8` with coop `5`
  (EXCLUSIVE|FOREGROUND) and acquires it: only to hide/capture the cursor in full
  screen. No `GetDeviceState`/`GetDeviceData` on it anywhere (all 8 references are in
  `0x4CAD30..0x4CADCA`). No `WM_MOUSEMOVE` handling either.

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
through the IAT into `0x5E8FA4`, `dInput8` `@0x453D80` on a zeroed FrontEnd, the in-game
`directInputUtils` `@0x44BB30`, `InitMouseExclusive` `@0x4CAD30`; then per frame the
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

## Audio (`w32_audio.asm`)

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
  **This install has no `data\gtaudio` folder at all** (neither the task copy nor the
  main checkout), so the menu has no music until those files are added.
- **Voices**: `data\audio\vocals\*.wav`, IMA ADPCM (format 0x11, 4-bit, stereo,
  block align 1024), played as streams.
- Volumes: SFX samples come out at vol 10 (registry `SFXVol` = 11), master 127.

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
- **Streams** are loaded whole on `AIL_open_stream` (PCM WAV, or IMA ADPCM decoded up
  front to s16) — the files are small. Missing/unsupported file → 0, logged once per
  name.
- **Focus**: `AIL_digital_handle_release/reacquire` pause/resume the device.
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

Listen live: `host/build.sh --load --entry` and move through the menu.

### Gaps

- Music: no `data\gtaudio` files in this install (see above).
- 3D samples / EAX / A3D (in-game positional sound) — not offered.
- Bink video audio (`binkw32` is still silent; no movies are shipped either).
- Resampling is nearest-sample; every rate the frontend uses is 22050 Hz = the mix
  rate, so it is exact there.

## What the game needs next (notes for later work)

- **Renderer**: done for the frontend — shim tables `dmavideo` / `d3ddll` in
  `w32_renderer.asm`, see `renderer-sdl.md`. Gameplay drawing (tiles, lighting) is next.
- **Input**: done (keyboard + mouse, see "Input"). Joysticks (EnumDevices
  `DI8DEVCLASS_GAMECTRL`) are not offered; WM_CHAR is not generated.
- **Audio**: frontend done (see "Audio"); music needs the `data\gtaudio` files.
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

- `WinMain2` calls `GetGameVersion(&major, &minor)` (`0x4D0920`, call at `0x4D11C7`).
- It runs `GetFileVersionInfoSizeA("GTA2.EXE")` → `GetFileVersionInfoA` →
  `VerQueryValueA(block, "\\")` and takes `major = HIWORD(dwProductVersionMS)`
  (`VS_FIXEDFILEINFO + 0x12`), `minor = LOWORD(dwProductVersionMS)` (`+ 0x10`).
  `dwFileVersion*` is not read; the shim fills it with the same value anyway.
- The menu formats them with `"v%d.%d"` (`0x5738F4`, also `"Coop v%d.%d"` at
  `0x573A98`); the frontend font is upper-case only, hence "V". Minor is printed
  without padding: `5` renders "V23.5", not "V23.05".
- The vanilla exe's own resource carries ProductVersion `11.44` (`0x000B002C`);
  without the shims the game shows "V0.0".
