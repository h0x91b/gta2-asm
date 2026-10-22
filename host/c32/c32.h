/* c32.h — what C32 code sees (docs/c32.md).
 *
 * C32 is C99 compiled for i386 and linked into one flat image at C32_BASE (c32.ld). The
 * host maps it there before the game starts; from then on it is ordinary 32-bit code in
 * the game's own code segment: game pointers are real C pointers, re/gta2_types.h structs
 * are used as they are, game functions are called directly and a game call site can jump
 * straight into a C32 function. There is no libc: the game's statically linked MSVC CRT
 * (re/functions.csv) and a few host services (c32_log) take its place.
 */
#ifndef C32_H
#define C32_H

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include "../../re/gta2_types.h"

/* Compile-time check, C99 style: a negative array size stops the build. Use it for every
 * struct field a module relies on, so a re/ export that moves a field fails here. */
#define C32_CAT_(a, b) a##b
#define C32_CAT(a, b) C32_CAT_(a, b)
#define C32_ASSERT(cond) typedef char C32_CAT(c32_assert_, __LINE__)[(cond) ? 1 : -1]
#define C32_OFFSET(type, field, off) C32_ASSERT(offsetof(type, field) == (off))

/* A game function at a fixed VA with its real convention (G2_CDECL / G2_STDCALL /
 * G2_FASTCALL / G2_THISCALL from gta2_types.h). clang turns the constant pointer into a
 * direct `call addr`, the same instruction the game uses:
 *   GAME_FN(void, G2_THISCALL, ChangeMoney, 0x421990, (Player *self, int amount));
 *   ChangeMoney(player, 333);
 * MSVC leaves the upper bits of small return values and arguments as garbage; clang
 * i386 re-extends them itself (measured: movzx after the call and on the argument), but
 * prefer int-sized types plus an explicit mask in prototypes anyway (docs/c32.md). */
#define GAME_FN(ret, cc, name, addr, args) \
    static ret (cc *const name) args = (ret (cc *) args)(addr)

/* ---- the game's CRT (MSVC, cdecl, statically linked; addresses from re/functions.csv) */
GAME_FN(int, G2_CDECL, game_vsprintf, 0x4D7FE6, (char *buf, const char *fmt, va_list ap));
/* memcpy 0x4D9400, memset 0x4E02A0, memmove 0x4D6EB0: c32.ld binds the names clang may
 * emit on its own (struct copies, zeroing) to these. */

/* ---- host services: 32-bit stubs into the 64-bit host (c32_host.c) -------------------- */
void c32_log(const char *fmt, ...);     /* "c32: <text>" on the host's stdout, 511 chars max */
int c32_passenger_wanted(void);         /* mods.passenger_enter on and a Shift down (passenger.c) */

/* ---- hooks ----------------------------------------------------------------------------
 * Only during C32_INIT: the host makes the game's .text rwx while the initialisers run
 * and r-x again afterwards. Each returns 0 and logs when the expected bytes differ. */

/* Entry detour: the function at va now starts with `jmp fn`; returns a trampoline that runs
 * the displaced first n bytes (5..16, whole instructions, no relative branches) and jumps
 * back to va + n. Call the trampoline as the original function, same type as fn. */
void *c32_detour(uint32_t va, const uint8_t *orig, unsigned n, void *fn);

/* Call hook: the `E8 call` at site now calls fn; returns its previous target, to be called
 * as the original. When site was already retargeted (a NASM CALLHOOK in w32_hooks.asm, or
 * another C32 hook), that hook is what comes back, so hooks chain. */
void *c32_callhook(uint32_t site, uint32_t expect_target, void *fn);

/* ---- registration (linker sets, collected by c32.ld) ---------------------------------- */

/* C32_INIT(fn): run void fn(void) once at load, before the game's entry point */
typedef void (*c32_init_fn)(void);
#define C32_INIT(fn) \
    static const c32_init_fn C32_CAT(c32_init_, fn) \
        __attribute__((section(".c32.init"), used)) = fn

/* C32_EXPORT(var): let the host find a global by name (c32_find), e.g. config values */
struct c32_export {
    const char *name;
    void *addr;
};
#define C32_EXPORT(var) \
    static const struct c32_export C32_CAT(c32_export_, var) \
        __attribute__((section(".c32.exports"), used)) = { #var, &var }

#endif
