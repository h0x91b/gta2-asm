# host/

Two x86-64 NASM binaries (run under Rosetta 2), one build command:

```sh
host/build.sh                 # builds ./host and ./loader
host/build.sh --run [N]       # SDL3 hello window (main.asm), quit after N frames
host/build.sh --load          # PE loader (loader.asm) on ../gta2/gta2.exe: exit 0 = all checks pass
host/build.sh --load --entry  # ...then run the game from its PE entry point through the Win32
                              # shims; stops (exit 3) at the first unimplemented import
host/build.sh --load --entry --trace   # + one log line per shim call
host/build.sh --load --entry --hold    # + keep the SDL window up 5 s when it stops
host/build.sh --load --entry --frames=300 --shot=/tmp/menu.bmp
                              # run to the main menu, save frame 300 as BMP, exit 0
host/build.sh --load --entry --keys=200:DOWN,240:RETURN --frames=300 --shot=/tmp/m.bmp
                              # + scripted key taps at presented frames (DIK names)
host/build.sh --load --input-selftest  # DirectInput self-test through the game's own
                              # input code, PASS/FAIL per check (exit = failures)
host/build.sh --load --input-test      # same code, ~15 s of real keys in a test window
```

The Win32 shim layer (`w32_*.asm`, included by `loader.asm`) is documented in
[`docs/win32-shims.md`](../docs/win32-shims.md); the SDL3 renderer that replaces
`dmavideo.dll`/`d3ddll.dll` (`w32_renderer.asm`) in
[`docs/renderer-sdl.md`](../docs/renderer-sdl.md).

Both are linked with `-pagezero_size 0x1000 -no_pie -image_base 0x200000000` through
`/usr/bin/ld` (via `xcrun -f ld`), so the low 4 GB is free for the game. `loader` links
**only libSystem**: linked SDL3 frameworks would land in the low 4 GB, so it maps its
low regions first and then `dlopen`s SDL3 (`$GTA2_SDL3_LIB`, default
`~/.local/opt/sdl3-x86_64/lib/libSDL3.0.dylib`).

## `loader` — vanilla gta2.exe mapped, original functions called in 32-bit mode

What it does (`loader.asm`; SDL is dlopen'ed by the shims):

1. Reads `gta2.exe`, validates MZ / PE / i386 / PE32 / ImageBase `0x3F0000` (no
   relocations, so no other base), `mmap`s SizeOfImage at `0x3F0000` (hint + verify).
2. Copies headers and every section to ImageBase+VA. Raw bytes are copied up to
   `min(SizeOfRawData, align_up(VirtualSize, 0x1000))` like the Windows loader; the rest
   of each section's pages (BSS) is zeroed explicitly. ⚠️ Copying only `VirtualSize`
   bytes is wrong for this exe: the 11.44 patch keeps code in `.text`'s raw slack past
   VirtualSize — the entry point jumps to `0x56DCDA`, VirtualSize ends at `0x56DBC0`.
3. Walks the import directory and points **every** IAT slot at its own 10-byte 32-bit
   stub (`push index; jmp common32`) at `0x10004000`. `common32` far-calls
   `host_dispatch`, which runs the slot's Win32 shim (see `docs/win32-shims.md`); slots
   without one print `unimplemented import DLL!Name (called from 0x…)` and exit **3**.
4. `mprotect`s from section characteristics: headers `r--`, `.text r-x`, `.rdata r--`
   (the IAT lives there; it is written before this step), `.data rw-`, `.rsrc r--`.
   Our own low region `0x10000000-0x11000000` (thunks, stubs, TEB, 8 MB 32-bit stack)
   is **RWX** for now; the shims' arena (heap etc.) is `0x20000000-0x60000000`, RW.
5. LDT: flat 32-bit code descriptor (index 16, selector `0x87`) and a TEB data
   descriptor (index 17, `0x8f`, `fs:[0]=-1`, `fs:[4/8]` stack base/limit,
   `fs:[0x18]` self). `call32` sets eax/ecx/edx + stack args, far-returns into
   32-bit code and gets edx:eax back; it does not trust esp after the call, so
   cdecl, stdcall (callee pops) and register-argument functions all work.
6. Runs a table of checks against original functions. Expected values are hard-coded,
   derived from the disassembly by hand (`__alldiv` values computed separately with
   Python integers) — nothing is recorded from a previous run. SIGSEGV/SIGBUS print
   `rip/cs/rsp` and exit **4** (`cs 0x87` = it died in game code).

Exit codes: 0 ok, 1 load/setup failure, 2 a check failed, 3 unimplemented import, 4 crash.

| Function | VA | Source / ABI | What it computes |
|---|---|---|---|
| `IsCarGun` | `0x433820` | game, stdcall `ret 4` | `al = (int)id >= 15` (signed; upper eax garbage, masked) |
| `getUpgradeType` | `0x420760` | game, **argument in al** (Ghidra's stdcall label is wrong) | jump table @`0x420790`: `0xFA→0x12, 0xFB→0x10, 0xFC→0x11`, anything else `0x0F` |
| `__alldiv` | `0x4D6260` | MSVC CRT, stdcall `ret 0x10` | signed 64/64 division, edx:eax, truncating |
| `_strlen` | `0x4D8960` | MSVC CRT, cdecl | strlen on strings copied below 4 GB (aligned + unaligned starts) |

Addresses from `re/functions.csv`; behaviour read from `ndisasm -b32` of the file.
Rejected: `carUpgradeCost` (`0x41F7D0`) — it starts by dereferencing the global at
`0x5E4CA4`, which is zero before game init.

### Real output (2026-10-20, before the Win32 shims; `host/build.sh --load --entry`)

Kept as the record of the loader step. The shim layer since adds a few setup lines and
runs much further — current output in `docs/win32-shims.md`.

```
loader: read ../gta2/gta2.exe (1740800 bytes)
PE32 i386: ImageBase=0x3f0000 SizeOfImage=0x28a000 entry=0x4d84f9 sections=4
  map .text    0x3f1000-0x56dbc0 (VirtualSize end)  copied 0x17d000 raw, zeroed tail 0x000000
  map .rdata   0x56e000-0x57b6cc (VirtualSize end)  copied 0x00e000 raw, zeroed tail 0x000000
  map .data    0x57c000-0x676718 (VirtualSize end)  copied 0x01a000 raw, zeroed tail 0x0e1000
  map .rsrc    0x677000-0x6799b0 (VirtualSize end)  copied 0x003000 raw, zeroed tail 0x000000
low region 0x10000000-0x10200000 (rwx: thunks, stubs, TEB, 32-bit stack); code32 sel 0x87, fs sel 0x8f -> TEB 0x10003000
  DINPUT8.dll      1 imports, IAT 0x56e024
  WINMM.dll        1 imports, IAT 0x56e258
  DPLAYX.dll       2 imports, IAT 0x56e02c
  VERSION.dll      3 imports, IAT 0x56e248
  KERNEL32.dll    84 imports, IAT 0x56e040
  USER32.dll      42 imports, IAT 0x56e19c
  GDI32.dll        1 imports, IAT 0x56e038
  ADVAPI32.dll     8 imports, IAT 0x56e000
  SHELL32.dll      1 imports, IAT 0x56e194
  ole32.dll        3 imports, IAT 0x56e380
  binkw32.dll     18 imports, IAT 0x56e260
  mss32.dll       52 imports, IAT 0x56e2ac
imports: 12 DLLs, 216 IAT slots patched with stubs at 0x10004000
  protect .text    r-x
  protect .rdata   r--
  protect .data    rw-
  protect .rsrc    r--
calling original gta2.exe functions in 32-bit mode:
  [PASS] 0x433820 IsCarGun(14)                   [stdcall] -> 0x0 (expected 0x0)
  [PASS] 0x433820 IsCarGun(15)                   [stdcall] -> 0x1 (expected 0x1)
  [PASS] 0x433820 IsCarGun(-1)  signed compare   [stdcall] -> 0x0 (expected 0x0)
  [PASS] 0x420760 getUpgradeType(al=0xFA)        [reg al] -> 0x12 (expected 0x12)
  [PASS] 0x420760 getUpgradeType(al=0xFB)        [reg al] -> 0x10 (expected 0x10)
  [PASS] 0x420760 getUpgradeType(al=0xFC)        [reg al] -> 0x11 (expected 0x11)
  [PASS] 0x420760 getUpgradeType(al=0xFD)        [reg al] -> 0xf (expected 0xf)
  [PASS] 0x420760 getUpgradeType(eax=0x1205)     [reg al] -> 0xf (expected 0xf)
  [PASS] 0x4d6260 __alldiv(1000000000000, 7)     [CRT] -> 0x2142f30249 (expected 0x2142f30249)
  [PASS] 0x4d6260 __alldiv(-1000000000000, 7)    [CRT] -> 0xffffffdebd0cfdb7 (expected 0xffffffdebd0cfdb7)
  [PASS] 0x4d6260 __alldiv(123456789012345678, 9876543210) -> 0xbebc1f (expected 0xbebc1f)
  [PASS] 0x4d6260 __alldiv(-(2^63-1), -3)        [CRT] -> 0x2aaaaaaaaaaaaaaa (expected 0x2aaaaaaaaaaaaaaa)
  [PASS] 0x4d8960 strlen("")                     [CRT] -> 0x0 (expected 0x0)
  [PASS] 0x4d8960 strlen("GTA2") unaligned       [CRT] -> 0x4 (expected 0x4)
  [PASS] 0x4d8960 strlen(48-char string)         [CRT] -> 0x30 (expected 0x30)
functions: 15/15 checks passed
--entry: jumping to the PE entry point 0x4d84f9
unimplemented import KERNEL32.dll!GetModuleHandleA (called from 0x56dce5)
```
(exit code 3; without `--entry` it ends with `ALL OK`, exit 0.)

The entry point is the 11.44 patch's stub (`jmp 0x56DCDA`), whose first instruction
pair is `push "KERNEL32"; call [GetModuleHandleA]` — exactly where the run stops.

### Not done yet / caveats

- `call32` is single-threaded; it is re-entrant (import handlers call back into 32-bit
  code, e.g. WndProc), nested frames go just below the game's `esp`.
- x87 control word is the macOS default (64-bit precision), not Windows' `0x27F`
  (53-bit); set it before running float-heavy game code.
- The low region is RWX; the image itself is mapped with per-section protections.
