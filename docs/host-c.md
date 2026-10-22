# Host C modules (`host/c/*.c`)

Logic-heavy host code may be written in plain **C99** and linked into the loader next to
the NASM. Hooks, thunks, Win32 shims, the loader and the renderer stay in NASM. C here is
**64-bit host code**, exactly like the NASM it sits next to: it runs on the host stack
between two stretches of 32-bit game code, may use libc, and reaches the game only through
its memory and through `call32`. Code that runs *inside* the 32-bit segment is the other C
flavour, C32 (`host/c32/`, `docs/c32.md`).

Which one: **game logic** — mods, detours into game functions, anything that mostly reads
game structs and calls game functions — is C32. **Host features** — the K menu, config,
SDL, logs, the C32 loader itself — are 64-bit host C (this page). Pilots: Seq 53 (host C)
and Seq 54 (C32), 2026-10-22, the same car-entry mod in both; the mod now lives in C32
(`host/c32/car_bonus.c`), its config key and K menu row here (`host/c/c32_host.c`, see
"Worked example").

## Build

`host/build.sh` compiles every `host/c/*.c` and `host/c/menu/*.c` (the K menu,
`docs/debug-menu.md`) and links the objects into `loader` through
the same `/usr/bin/ld` line as `loader.o` (no list to edit; a new file is picked up by
itself):

```sh
clang -arch x86_64 -std=c99 -O2 -Wall -Wextra -Werror -mmacosx-version-min=26.0 \
      -isysroot "$(xcrun --show-sdk-path)" -c -o c/x.o c/x.c
```

`clang` comes from `xcrun -f clang` (Apple's, not anything else on `PATH`). The objects
(`host/c/*.o`) are git-ignored. `CFLAGS_EXTRA=-g host/build.sh` adds flags. No new
dependencies: the loader already links libSystem, so libc is there. `-no_pie` with
clang's PIC objects is fine (they only use RIP-relative addressing).

Check that a module is in the link: `nm -m host/loader | grep c32_load`.

## Adding a module

1. `host/c/<thing>.c`, `#include "game.h"`.
2. Functions NASM calls: plain C functions; NASM declares them in `host/c_bridge.asm` as
   `extern _name` (Mach-O C symbols carry a leading underscore, like `_printf`).
3. NASM symbols C uses: `global name` in `host/c_bridge.asm`, then in C
   `extern T name NASM(name);` (`NASM()` is an asm label, so the C name binds to the NASM
   label without the underscore).
4. `host/build.sh`.

## ABI glue, both directions

### NASM → C (a hook handler calls C)

A hook handler (`HOOK`/`CALLHOOK`, `w32_hooks.asm`) is already a SysV x86-64 function:
`host_dispatch` calls it with `rdi` = the game's stack arguments and a 16-byte aligned
stack, and `HENTER` keeps the alignment (5 pushes + the return address). So calling C is a
plain `call`: integer arguments in `rdi, rsi, rdx, rcx, r8, r9`, return in `eax`
(`rdx:rax` for 64 bits). The callee may clobber `rax, rcx, rdx, rsi, rdi, r8-r11` and keeps
`rbx, rbp, r12-r15` — which is why the handler below keeps its values in `r12-r14`.

The pattern, as the Seq 53 pilot used it (a `CALLHOOK 0x43F279` on `Car_OnDriverEnter`;
the mod itself has since moved to C32, which hooks without any NASM):

```nasm
; host/c_bridge.asm
extern _c_on_driver_enter

hk_DriverEnter:
    HENTER
    mov r12d, [abs G_ECX]           ; Car* (G_ECX: read before any call32)
    mov r13d, [rbx]                 ; Ped* (stack arg 0)
    mov r14d, [rbx - 4]             ; the game's return address
    mov edi, 0x427A20               ; the original, first
    mov rsi, rbx
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d                   ; thiscall: this in ecx
    xor r9d, r9d
    call call32
    mov edi, r12d                   ; c_on_driver_enter(car, ped, site)
    mov esi, r13d
    lea edx, [r14 - 5]
    call _c_on_driver_enter
    HRET
```

```c
void c_on_driver_enter(gptr car, gptr ped, gptr site);
```

In the tree today `_main` calls `_c32_load` (`host/c/c32_host.c`), `loader.asm` calls
`_cfg_set_path` and `w32_advapi32.asm` `_config_apply` (`host/c/config.c`) the same way.

The other direction, C calling a NASM *function*, needs that function to be SysV-clean:
arguments in `rdi, rsi, …`, callee-saved registers kept, and any libc call inside it aligned
for a caller whose `call` was aligned. `config.c` calls `reg_key_add`, `reg_val_find`,
`reg_val_set` (`w32_advapi32.asm`) and `fail`
(`loader.asm`), all checked for that; each is `global` in `c_bridge.asm` and declared with
`NASM()` in the C file. Check a NASM function's pushes before adding it to such a list.

A C function can also *be* the handler or a table entry directly when its contract is
SysV already. The other way round, C calling a NASM function whose callee-saved discipline
was only ever checked against NASM callers goes through `dm_cb(fn, a, b)`
(`host/debug_menu.asm`): it keeps rbx, rbp, r12-r15 and realigns the stack around the call.
The K menu (`host/c/menu/`) calls every `DM_FRAME` hook and `DM_VALUE` pair that way, since
the NASM feature modules still register some.

### Import shims in C (the game calls a Win32 / DLL export)

An import handler — what a shim table entry points at — needs no NASM glue either:
`host_dispatch` calls `imp_handler[slot](rdi = args, esi = slot)` with a 16-byte aligned
host stack, and far-returns `edx:eax` to the game after `common32` pops the stdcall
argument bytes the table lists. So a shim is a plain C function:

```c
/* args[0] is the first stdcall argument ([esp+4] at the game's call), args[1] the next, ... */
uint64_t ail_set_sample_volume(const uint32_t *args)       /* (HSAMPLE, 0..127) */
{
    struct voice *v = aud_voice(args[0]);
    if (v)
        v->vol = args[1];
    return 0;                                               /* eax; edx = rdx, ignored */
}
```

and the table stays NASM (the `SHIM` macro builds the `{name, handler, pop}` records that
`bind_slot` / `GetProcAddress` search), naming the C symbol with its underscore:

```nasm
; host/w32_mss32.asm (or any w32_<dll>.asm), listed in w32_tables.asm
extern _ail_set_sample_volume
shimtab_mss32:
    dq s_mss32                              ; the DLL name
    SHIM "_AIL_set_sample_volume@8", 8, _ail_set_sample_volume   ; 8 = bytes common32 pops
    dq 0
```

Rules:

- The **pop count is the table's job**, not the handler's: stdcall `@N` names pop N,
  cdecl exports (`wsprintfA`) pop 0. A wrong N corrupts the game's stack after the call.
- Arguments are 32-bit game values: pointers come in as `gptr` (read/write them with
  `rd32`/`wr32`, or cast through `uintptr_t`; the image and every allocation are mapped
  1:1). Out-parameters are written in place (`wr32(args[0], AUD_DRV)`).
- The return value is `rax`; the game sees `eax` (and `edx` for 64-bit results — return
  `(uint64_t)hi << 32 | lo`).
- A handler may call the game back (`call32` / `game_stdcall`): calls nest. If it needs the
  game's `ecx`/`edx` (a thiscall/fastcall import or hook), read `G_ECX`/`G_EDX` before that.
- Memory handed to the game must come from the low arena (`heap_alloc`, w32_core.asm,
  `global` in c_bridge.asm), never `malloc`.

Users: `c32_svc_log` (`shimtab_c32`, c32_blob.asm) and the whole `mss32` shim
(`host/c/audio.c`, table `w32_mss32.asm`; ported from NASM in Seq 57). The NASM shims'
`HENTER`/`ARG(n)` is the same contract (`rbx = rdi = args`).

### C → game (C calls a 32-bit game function)

Through the same `call32` (`loader.asm`) the NASM uses, exported to C:

```c
uint64_t call32(gptr fn, const uint32_t *args, int nargs,
                uint32_t eax, uint32_t ecx, uint32_t edx) NASM(call32);
```

Its register contract (`edi, rsi, edx, ecx, r8d, r9d` → `edx:eax`) already *is* the SysV
signature above, so there is no glue at all — only `global call32`. On top of it
`host/c/game.c` has three variadic front ends, and `game.h` one **typed inline wrapper per
game function**:

```c
uint32_t game_stdcall(gptr fn, int nargs, ...);                 /* cdecl too */
uint32_t game_thiscall(gptr fn, gptr this_, int nargs, ...);    /* this in ecx */
uint32_t game_fastcall(gptr fn, uint32_t ecx, uint32_t edx, int nargs, ...);

/* ChangeMoney(Player*, int) @0x421990, thiscall, ret 4 (source in game.h) */
static inline void ChangeMoney(Player *player, int32_t amount)
{
    game_thiscall(0x421990, (gptr)(uintptr_t)player, 1, (uint32_t)amount);
}
```

Why this split: the variadic front end is the one place that knows how arguments reach
`call32`, and the typed wrapper is the one place that knows a function's address, ABI and
argument types (with the source next to it). Callers then read like C
(`ChangeMoney(player, 333)`) and the compiler checks the argument count, which a bare
`game_thiscall(0x421990, ...)` cannot. One generic `game_call(conv, ...)` was rejected: a
convention enum at every call site is noise, and the typed wrappers make it unnecessary.
A `(fn, args[], n)` array API is `call32` itself, still available.

Rules for game calls from C: arguments are 32-bit values (cast pointers, `gptr`); `call32`
nests, so a C function called from a hook may call the game again; read `G_EAX/G_ECX/G_EDX`
(in NASM) before the first `call32`, it overwrites them.

### C ↔ NASM data

Shared globals are ordinary symbols:

- NASM → C: `global r_frames` (c_bridge.asm), then `extern uint32_t r_frames NASM(r_frames);`
  (game.h); `global new_slot` / `c32_blob` (c32_blob.asm) the same way for `c32_host.c`.
- C → NASM: a C global `int32_t amount;` is `_amount` to NASM
  (`extern _amount`, `mov eax, [rel _amount]`).

## Game structs in C

`re/gta2_types.h` is the i386 view (8-byte pointers in 64-bit C would shift every offset).
For host C, `re/gta2_types_c64.h` (generated by the re/ export, Seq 27) has every struct with
its exact 32-bit layout, packed, every game pointer as `uint32_t` (the pointee type in a
comment), and `GP(T, v)` to turn such a value into a `T *`. `host/build.sh` passes `-I../re`:

```c
#include "gta2_types_c64.h"                     /* via game.h */
Player *player = game_player();                 /* Game 0x5EB4FC ->currentPlayer */
Car *car = GP(Car, car_va);
if (car->driver == player->ped)                 /* uint32_t == uint32_t */
    printf("money %d\n", player->score.money.value);
```

The image and every game allocation are mapped 1:1, so a game VA is a valid host address.
Globals are not in the header: `game.h` keeps them (`G_GAME`) with their source, and raw
`rd32/wr32` accessors (volatile) for anything without a type. The struct pointers are plain
(not volatile): fine for reading a field the game is not changing under us within one call,
which is always the case on the host side (the game is stopped while host code runs).

## Unit tests (`host/test/`)

`host/build.sh --test` builds every `host/test/<name>_test.c` together with
`host/c/<name>.c` into `host/test/<name>` (git-ignored) and runs it, without the game, the
pak or SDL. The test stubs every NASM symbol the module uses under the same `NASM()` name
(`test/config_test.c`: an in-memory registry, a short `key_table`, `fail` that `longjmp`s
back with its message). It cannot cover the NASM itself; parity runs of the loader do that. `test/audio_wav_test.c` feeds `audio_wav.c` synthetic WAVs through a
`vfs_load` stub and checks the IMA ADPCM decoder against hand-worked values.

## Pitfalls

- **Never call C from 32-bit code** or hand a C function pointer to the game. The game can
  only reach the host through an import slot (`new_slot` / a hook); C is reached from there.
- **Stack alignment**: every `call` into C needs `rsp % 16 == 0` at the call. `HENTER`
  handlers have it; elsewhere count your pushes (a misaligned SSE spill crashes with
  `movaps`, often far from the cause).
- **Callee-saved registers**: anything a NASM caller needs after the call goes into
  `rbx, rbp, r12-r15`, not `rcx/rdx/rsi/rdi/r8-r11`.
- **Symbol names**: C `foo` is `_foo` in NASM; a NASM label C uses needs `global` and
  `NASM(label)` in its C declaration, or the link fails with an undefined `_label`.
- **Game pointers are 32-bit** (`gptr`). `sizeof(void *)` is 8 here; use
  `gta2_types_c64.h`, never `gta2_types.h`, in host C. A C pointer from `GP()` must never be
  stored into game memory; store the `uint32_t`.
- **x87 state**: the game sets the x87 control word (24-bit precision like most DirectX
  games). Host C uses SSE for `float`/`double` and is unaffected, but `long double` is x87:
  do not use it.
- **libc only in host code**: `printf` goes to the same stdout as the NASM's; `malloc`
  memory lies above 4 GB and must never be handed to the game (use the game's allocator or
  the shims' arena below 4 GB for that).
- **No headers shared with NASM**: NASM uses `re/gta2_types.inc`, C `re/gta2_types_c64.h`,
  both generated from the same export, so offsets agree.

## Worked example: `host/c/c32_host.c`

The host side of C32, i.e. everything about a C32 mod that is not game logic:

- **Loader** (`c32_load`, called from `_main`): checks the image header, `mmap`s it at its
  link address (hint, verified), binds its host services with `new_slot("c32", name)`,
  `call32`s its initialisers with `.text` temporarily `rwx` (`docs/c32.md`).
- **Host services** (`c32_svc_log`): import handlers, `uint64_t f(const uint32_t *args)`,
  listed in `shimtab_c32` (`host/c32_blob.asm`).
- **Config key** (`c32_cfg_mods`, from `config_apply`'s `mods:` section): parses
  `mods: car_enter_bonus: N` with `strtol` and writes the C32 global the image exports
  (`C32_EXPORT(car_bonus)`), found by name — the image is mapped 1:1, so it is a plain store.
- **K menu row** (`c32_carbonus_change` / `c32_carbonus_fmt`): the Mods page's value row,
  registered from this file with `DM_ITEM(dmp_mods, ...)` (`docs/debug-menu.md`, "A row
  for a C32 module").

Try the mod: put `mods:` / `  car_enter_bonus: 333` in
`~/Library/Application Support/gta2-resurrected/config.yaml` (or `--config=PATH`), run
`host/build.sh --load --entry`, PLAY, walk to a car, RETURN; or K → Mods → Car entry bonus.
