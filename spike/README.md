# Spike: 32-bit x86 code from an x86-64 host under Rosetta 2

**Verdict: WORKS, with caveats.** An x86-64 NASM Mach-O, run with `arch -x86_64` on an
arm64 Mac (macOS 26.6.2, build 25G83), installs 32-bit descriptors with `i386_set_ldt`,
far-transfers into 32-bit code, gets results back, takes callbacks from 32-bit code into
64-bit host functions, loads FS with a TEB selector, runs x87, and recovers from a SIGSEGV
raised inside 32-bit code. No entitlement, no codesign, no special flag.

## Build / run

```sh
brew install nasm                 # nasm 3.02 used here; Xcode (CLT) for ld + SDK
spike/build.sh                    # build + run the core spike
spike/build.sh /path/to/gta2.exe  # also map gta2.exe's sections at 0x3F0000
spike/build.sh --build-only
```

## What it does (`spike.asm`)

| Step | How |
|---|---|
| Low memory | Linked `-pagezero_size 0x1000 -no_pie -image_base 0x200000000`, then `mmap(0x3F0000, 0x510000, RWX)` with a hint (no `MAP_FIXED`) and the result is checked. |
| 32-bit code | Flat 4 GB DPL3 code descriptor at LDT index 16 → selector `0x87`. Data/stack use the existing `ss=ds=0x23`, no data descriptor needed. |
| 64 → 32 | `call32`: save host rsp in low memory, switch to a low stack, push `sel32:tramp32`, `o64 retf`. `tramp32` does `call ecx` (cdecl), then `jmp far [FAR_RET]` to a 64-bit thunk below 4 GB that restores rsp. |
| Proof of mode | Bytes `40 40` are `inc eax; inc eax` only in 32-bit mode (REX prefixes in 64-bit): returns 2. `mov ax, cs` from 32-bit code reads `0x87`. |
| 32 → 64 callback | 32-bit `call far [FAR_CB]` → 64-bit `cb64` thunk reads cdecl args off the 32-bit stack, aligns, calls a normal SysV host function (`printf` inside), `retf` (32-bit operand) back. |
| FS / TEB | Second LDT entry (index 17, base `0x703000`, limit 4 KB) → `mov fs, 0x8f`; `fs:[0x18]` returns the TEB self pointer, and FS survives a full 64-bit round trip. |
| Signals | `mov eax, [0x10]` in 32-bit code → SIGSEGV; the 64-bit handler sees `cs=0x87`, 32-bit `rip`/`rsp`, rewrites the context to the 64-bit thunk with `cs=0x2b`, execution resumes, later 32-bit calls still work. |
| gta2.exe bonus | PE sections `pread` to their VAs at ImageBase 0x3F0000; the entry dword read from 32-bit code matches the file (`e9 dc 57 09` = `jmp rel32`). Imports not resolved, nothing from the game executed. |

## Real output

```
host: cs=0x2b ss=0x23 ds=0x0, _main at 0x20000078b
mmap(0x3F0000, 0x510000, RWX) -> 0x3f0000
i386_set_ldt(17, &desc, 1) -> 17 (errno 0)
i386_set_ldt(16, &desc, 1) -> 16 (errno 0)
selectors: code32 = 0x87, fs/TEB = 0x8f
mode32 (40 40 = inc eax x2 only in 32-bit mode) -> 2  [2 = 32-bit, 0 = 64-bit]
cs as seen from 32-bit code = 0x87
add32 -> 42
  [host_cb] called from 32-bit code: x=6 y=7 (host rsp=0x8effc0)
cb32(6,7) = host_cb(6,7)+1 -> 43
fpu32(2,3) = x87 sqrt(2*3)*1000 -> 2449
fs:[0x18] after mov fs -> 0x703000, on a later call32 -> 0x703000 (TEB = 0x703000)
perf: 1M 64->32->64 round trips: 42857875 ns total, 42 ns each
perf: 1M round trips with a 32->64->32 callback inside: 80 ns each
perf: 300M-iter loop: 32-bit -> 0xfc152e6e in ~222 ms, 64-bit -> 0xfc152e6e in ~212 ms
  [signal 11] addr=0x10 rip=0x700089 cs=0x87 rsp=0x8efff4
fault32 recovered, call32 returned 0xdead
add32 -> 1337
PE: ImageBase=0x3f0000 SizeOfImage=0x28a000 sections=4
  .text -> 0x3f1000 raw 0x17d000 (pread 1560576)
  .rdata -> 0x56e000 raw 0xe000 (pread 57344)
  .data -> 0x57c000 raw 0x1a000 (pread 106496)
  .rsrc -> 0x677000 raw 0x3000 (pread 12288)
gta2.exe entry 0x4d84f9, first dword read from 32-bit code = 0x0957dce9
ALL OK
```

## What breaks / caveats (all observed unless marked)

- **`i386_set_ldt(LDT_AUTO_ALLOC, …)` kills the process**: Rosetta prints
  `rosetta error: i386_set_ldt(kLdtAutoAlloc) not supported` and aborts (SIGABRT, exit 134).
  It is not an errno, it cannot be caught. Manage LDT indices yourself, the way Wine does.
- **`num_sels > 1` also aborts**: `rosetta error: i386_set_ldt with multiple sels not supported`.
  One descriptor per call.
- **Valid indices**: 0–2 → `-1, errno 22 (EINVAL)`; 3…8191 work (swept 3, 5–8, 15, 255,
  256, 1000, 4095, 8190).
- **gta2.exe ImageBase is `0x3F0000`, not `0x400000`**, SizeOfImage `0x28A000`
  (ends at `0x67A000`), and it has **no relocation table**: it can only be loaded at
  exactly `0x3F0000`.
- **The default PIE host lands in low memory.** With `-pagezero_size 0x1000` alone the
  image slid to `0x46c000`, right on top of the target range, and `mmap`'s hint was quietly
  ignored (it returned another address instead of failing). Fix used: `-no_pie
  -image_base 0x200000000`, and always compare the `mmap` result with the hint. Never use
  `MAP_FIXED` blind here: it would silently replace whatever Rosetta/dyld put there.
- **The 64-bit side of every transition must live below 4 GB** (32-bit far pointers are
  16:32), so the return/callback thunks are copied into the low mapping. Stacks used by
  32-bit code must be below 4 GB too.
- **`call32` here is not re-entrant and single-threaded** (one saved rsp slot). The real
  loader needs a per-thread context stack, a per-thread 32-bit stack and TEB (FS).
  *Not tested*: threads, nested 64→32→64→32, SSE inside 32-bit code, `lldb` stepping
  through 32-bit code.
- **Performance**: ~40 ns per 64→32→64 round trip, ~80 ns with a 32→64→32 callback
  inside it. Compute-bound 32-bit code runs at the same speed as the same loop in 64-bit
  (222 vs 212 ms for 300M iterations): Rosetta translates compat-mode code just like
  64-bit code. For Win32 import shims (hundreds to thousands of calls per frame) the
  transition cost is negligible.
- **No entitlement or flag** was needed: an unsigned, linker-signed binary, RWX `mmap`
  without `MAP_JIT`.
- **Rosetta phase-out (the real long-term risk)**: at WWDC 2025 Apple announced that macOS
  26 Tahoe is the last release for Intel Macs and that Rosetta 2 stays generally available
  through macOS 27; after that only a reduced subset aimed at older unmaintained games is
  promised. Whether that subset keeps 32-bit compat-mode support (which CrossOver/Wine's
  wine32on64 relies on) is not announced. Practically: this model works today and on
  macOS 27 (not tested here: this machine is on 26.6.2); from macOS 28 (expected ~autumn 2027,
  about a year from now) it may stop working. Treat the whole
  execution layer as replaceable and keep the Win32 shim layer independent of it.

## If/when Rosetta goes away — fallbacks

1. **Embedded x86 emulator (Unicorn/QEMU-TCG, or box86/box64-style DBT)** running the
   32-bit code in an arm64-native host; the shim layer stays the same, only `call32` and
   the callback thunk change. Slower but independent of Apple.
2. **Static recompilation** of gta2.exe (lifting `.text` to C/LLVM IR): best performance and
   longevity, but large up-front effort (indirect jumps, self-modifying/computed code).
3. **Wine-based** (CrossOver/Wine + SDL): least code, but it is exactly the same Rosetta
   dependency today and no NASM host.

Recommendation: proceed with the Rosetta + LDT model now (it works and is fast), keep
`call32`/callback thunks behind one small interface so option 1 can replace them later.
