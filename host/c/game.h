/* game.h — what host C code sees of the game and of the NASM host (docs/host-c.md).
 *
 * C here is 64-bit host code, exactly like the NASM around it: it runs on the host stack
 * between two 32-bit stretches of game code, may use libc, and reaches the game only
 * through its memory and through call32. The image is mapped 1:1 (VA 0x5EB4FC is host
 * address 0x5EB4FC), so a game pointer is a plain 32-bit number: gptr, never a C pointer
 * type, because every game struct's pointer fields are 4 bytes wide.
 */
#ifndef GAME_H
#define GAME_H

#include <stdint.h>

typedef uint32_t gptr;                  /* a game VA (below 4 GB) */

/* A NASM label as a C symbol. Mach-O C names carry a leading underscore and NASM
 * labels do not, so `extern T x NASM(x);` binds x to the label `x` (it must be `global`
 * in host/c_bridge.asm). The other way round, NASM writes `extern _c_name`. */
#define NASM(name) __asm__(#name)

/* ---- game memory ------------------------------------------------------------------ */

static inline uint8_t  rd8(gptr a)  { return *(volatile uint8_t *)(uintptr_t)a; }
static inline uint16_t rd16(gptr a) { return *(volatile uint16_t *)(uintptr_t)a; }
static inline uint32_t rd32(gptr a) { return *(volatile uint32_t *)(uintptr_t)a; }
static inline void wr8(gptr a, uint8_t v)   { *(volatile uint8_t *)(uintptr_t)a = v; }
static inline void wr16(gptr a, uint16_t v) { *(volatile uint16_t *)(uintptr_t)a = v; }
static inline void wr32(gptr a, uint32_t v) { *(volatile uint32_t *)(uintptr_t)a = v; }

/* ---- calling game code -------------------------------------------------------------- */

/* call32 (loader.asm): run fn in 32-bit mode with args[0..nargs-1] on its stack
 * (args[0] at [esp+4]) and eax/ecx/edx preset; returns edx:eax. It does not trust esp
 * afterwards, so cdecl, stdcall and register conventions all work. Nested calls are
 * fine (a handler may call back into the game). */
uint64_t call32(gptr fn, const uint32_t *args, int nargs,
                uint32_t eax, uint32_t ecx, uint32_t edx) NASM(call32);

/* Convenience front ends (game.c): the arguments are uint32_t each, args[0] first.
 * MSVC conventions: stdcall/cdecl all on the stack, thiscall `this` in ecx,
 * fastcall the first two in ecx/edx. */
uint32_t game_stdcall(gptr fn, int nargs, ...);
uint32_t game_thiscall(gptr fn, gptr this_, int nargs, ...);
uint32_t game_fastcall(gptr fn, uint32_t ecx, uint32_t edx, int nargs, ...);

/* ---- NASM host data ------------------------------------------------------------------ */

extern uint32_t r_frames NASM(r_frames);    /* presented frames (renderer.c) */

/* C32 (c32_host.c): the address of a C32_EXPORT'ed global or function, or 0 */
void *c32_find(const char *name);

/* ---- game structs: re/gta2_types_c64.h, generated from the Ghidra project (Seq 27):
 * exact 32-bit layouts, every game pointer a uint32_t, GP(T, v) turns one into a T*.
 * Game globals not in the header: */

#include "gta2_types_c64.h"

#define G_GAME              0x5EB4FC    /* Game* (gta2-seuko-mod src/game/memory.h @25b1985) */

static inline Game *game(void)       { return GP(Game, rd32(G_GAME)); }

static inline Player *game_player(void)
{
    Game *g = game();
    return g ? GP(Player, g->currentPlayer) : 0;
}

/* ---- typed game functions: one wrapper per function, address and ABI in one place ---- */

/* ChangeMoney(Player*, int) @0x421990, thiscall, ret 4: `add ecx, 0x2D4; jmp
 * PlayerScore_AddMoney` — adds to the animated money (clamped to its max), and in
 * multiplayer to the player's points. GiveMoney 0x41DC40 is the same times the
 * player's score multiplier (Player +0x6BC). Own disassembly; names from re/functions.csv. */
static inline void ChangeMoney(Player *player, int32_t amount)
{
    game_thiscall(0x421990, (gptr)(uintptr_t)player, 1, (uint32_t)amount);
}

#endif
