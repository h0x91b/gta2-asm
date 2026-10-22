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

extern uint32_t r_frames NASM(r_frames);    /* presented frames (w32_renderer.asm) */

/* ---- game structs: only the fields we use, as offsets (gptr + OFF) ---------------------
 * Sources: re/gta2_types.h (Ghidra project gta-2-recovered) and gta2-seuko-mod by
 * izawartka (https://github.com/izawartka/gta2-seuko-mod) src/game/gta2.h, memory.h
 * @25b1985; the uses below were checked in the disassembly (docs/host-c.md). */

#define G_GAME              0x5EB4FC    /* Game* (seuko memory.h) */
#define GAME_PLAYER         0x38        /* Game: current Player* (debug_menu.asm dm_player_ped) */
#define PLAYER_PED          0x2C4       /* Player: Ped* */
#define PLAYER_SCORE        0x2D4       /* Player: PlayerScore (animated money: value +0) */
#define PED_PLAYER          0x15C       /* Ped: Player* or 0 */
#define PED_CAR             0x16C       /* Ped: currentCar */
#define PED_AS_PASSENGER    0x248       /* Ped: enterCarAsPassenger */
#define CAR_DRIVER          0x54        /* Car: Ped* */
#define CAR_ID              0x6C        /* Car: id */
#define CAR_MODEL           0x84        /* Car: model */

static inline gptr game_player(void)
{
    gptr game = rd32(G_GAME);
    return game ? rd32(game + GAME_PLAYER) : 0;
}

static inline int32_t player_money(gptr player)
{
    return (int32_t)rd32(player + PLAYER_SCORE);
}

/* ---- typed game functions: one wrapper per function, address and ABI in one place ---- */

/* ChangeMoney(Player*, int) @0x421990, thiscall, ret 4: `add ecx, 0x2D4; jmp
 * PlayerScore_AddMoney` — adds to the animated money (clamped to its max), and in
 * multiplayer to the player's points. GiveMoney 0x41DC40 is the same times the
 * player's score multiplier (Player +0x6BC). Own disassembly; names from re/functions.csv. */
static inline void ChangeMoney(gptr player, int32_t amount)
{
    game_thiscall(0x421990, player, 1, (uint32_t)amount);
}

#endif
