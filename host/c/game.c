/* game.c — the variadic front ends of call32 (game.h). */
#include <stdarg.h>
#include "game.h"

#define MAX_ARGS 16

static int take_args(uint32_t *args, int nargs, va_list ap)
{
    if (nargs < 0 || nargs > MAX_ARGS)
        nargs = 0;
    for (int i = 0; i < nargs; i++)
        args[i] = va_arg(ap, uint32_t);
    return nargs;
}

uint32_t game_stdcall(gptr fn, int nargs, ...)
{
    uint32_t args[MAX_ARGS];
    va_list ap;
    va_start(ap, nargs);
    nargs = take_args(args, nargs, ap);
    va_end(ap);
    return (uint32_t)call32(fn, args, nargs, 0, 0, 0);
}

uint32_t game_thiscall(gptr fn, gptr this_, int nargs, ...)
{
    uint32_t args[MAX_ARGS];
    va_list ap;
    va_start(ap, nargs);
    nargs = take_args(args, nargs, ap);
    va_end(ap);
    return (uint32_t)call32(fn, args, nargs, 0, this_, 0);
}

uint32_t game_fastcall(gptr fn, uint32_t ecx, uint32_t edx, int nargs, ...)
{
    uint32_t args[MAX_ARGS];
    va_list ap;
    va_start(ap, nargs);
    nargs = take_args(args, nargs, ap);
    va_end(ap);
    return (uint32_t)call32(fn, args, nargs, 0, ecx, edx);
}
