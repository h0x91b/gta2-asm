# Host C modules (`host/c/*.c`)

Logic-heavy host code may be written in plain **C99** and linked into the loader next to
the NASM. Hooks, thunks, Win32 shims, the loader and the renderer stay in NASM. C here is
**64-bit host code**, exactly like the NASM it sits next to: it runs on the host stack
between two stretches of 32-bit game code, may use libc, and reaches the game only through
its memory and through `call32`. Nothing C-compiled ever runs inside the 32-bit segment.

Pilot (Seq 53, 2026-10-22): `host/c/car_bonus.c`, a mod that pays the player money every
time they get into a car as the driver (see "Worked example" below).

## Build

`host/build.sh` compiles every `host/c/*.c` and links the objects into `loader` through
the same `/usr/bin/ld` line as `loader.o` (no list to edit; a new file is picked up by
itself, like `host/menu/*.asm`):

```sh
clang -arch x86_64 -std=c99 -O2 -Wall -Wextra -Werror -mmacosx-version-min=26.0 \
      -isysroot "$(xcrun --show-sdk-path)" -c -o c/x.o c/x.c
```

`clang` comes from `xcrun -f clang` (Apple's, not anything else on `PATH`). The objects
(`host/c/*.o`) are git-ignored. `CFLAGS_EXTRA=-g host/build.sh` adds flags. No new
dependencies: the loader already links libSystem, so libc is there. `-no_pie` with
clang's PIC objects is fine (they only use RIP-relative addressing).

Check that a module is in the link: `nm -m host/loader | grep c_on_driver_enter`.

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

```nasm
; host/c_bridge.asm
extern _c_on_driver_enter

; host/mods.asm — CALLHOOK 0x43F279 on Car_OnDriverEnter(Car* this, Ped*)
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
/* host/c/car_bonus.c */
void c_on_driver_enter(gptr car, gptr ped, gptr site);
```

A C function can also *be* the handler or a table entry directly when its contract is
SysV already: the K menu's `DM_VALUE` pair `{change(esi = dir), fmt(rdi = text end)}` is
called with an aligned stack, so `host/menu/mods.asm` points it straight at C:

```nasm
dmv_carbonus: dq _c_carbonus_change, _c_carbonus_fmt
```
```c
void c_carbonus_change(void *item, int dir);   /* esi = dir is the 2nd SysV argument */
void c_carbonus_fmt(char *end);                /* rdi */
```

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
  (game.h). Used by car_bonus.c for its debounce.
- C → NASM: a C global `int32_t car_bonus_amount;` is `_car_bonus_amount` to NASM
  (`extern _car_bonus_amount`, `mov eax, [rel _car_bonus_amount]`).

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

## Worked example: `+$333` on every car entry

- Seam: `Car_OnDriverEnter(Car* this, Ped*)` `0x427A20`, thiscall, ret 4 — the game's own
  "this ped is now the driver" step (it shows the car's name, hands over the player's car
  weapons via `Player_OnEnterCarWeapons` `0x4A5570`, stores `Car.lastPlayerDriverId`).
  Call-hooked at `0x43F279` in `Ped_UpdatePosition` (`0x43F180`), the end of every
  enter-car animation, taken when `Ped.enterCarAsPassenger` (+0x248) is 0 — the same path
  for an empty car and a jacked one. Its only other caller, `0x4A63A3` in
  `Player_TakeControlOfCar` (`0x4A6350`), is remote control of a car, not an entry, so it is
  not hooked. Own disassembly, confirmed by Seq 27 in Ghidra; names from `re/functions.csv`.
  Not covered: a script that puts the player straight into a car may set the driver without
  `Car_OnDriverEnter` (Seq 27, unchecked).
- Checks (C): the ped is the current player's (`Game->currentPlayer` → `Player->ped`, and
  `Ped->player` → the same Player), the car's `driver` (+0x54) is that ped, and the same
  car again within 30 frames is ignored (one entry = one bonus).
- Money: `ChangeMoney` `0x421990` (exact amount; `GiveMoney` `0x41DC40` would multiply it by
  the player's score multiplier), so the HUD counter rolls up as for any reward.
- Switch: `mods: car_enter_bonus: N` in config.yaml (0 = off, the default), and the K menu's
  Mods page (`host/menu/mods.asm`, any key toggles). Log line:
  `mods: car_enter_bonus +$333: car 59 (model 3) via 0x43f279, money 0 -> 333, frame 652`.

Try it: put `mods:` / `  car_enter_bonus: 333` in
`~/Library/Application Support/gta2-resurrected/config.yaml` (or `--config=PATH`), run
`host/build.sh --load --entry`, PLAY, walk to a car, RETURN.
