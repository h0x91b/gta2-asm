/* rt.c — the C32 runtime: image header, host services, hooks (docs/c32.md). */
#include "c32.h"
#include "c32_abi.h"

/* c32.ld */
extern char c32_base[], c32_image_end[], c32_bss_start[], c32_bss_end[];
extern const c32_init_fn c32_inits[], c32_inits_end[];
extern const struct c32_export c32_exports[], c32_exports_end[];

static void G2_STDCALL c32_start(void);

/* host services, bound by c32_host.c; the order is the index used below */
enum { SVC_LOG, SVC_PASSENGER_WANTED };
static struct c32_import imports[] = {
    [SVC_LOG] = { (uint32_t)"log", 0 },
    [SVC_PASSENGER_WANTED] = { (uint32_t)"passenger_wanted", 0 },
};

__attribute__((section(".c32.head"), used))
static const struct c32_header header = {
    .magic = C32_MAGIC,
    .version = C32_VERSION,
    .base = (uint32_t)c32_base,
    .image_end = (uint32_t)c32_image_end,
    .bss_start = (uint32_t)c32_bss_start,
    .bss_end = (uint32_t)c32_bss_end,
    .start = (uint32_t)c32_start,
    .imports = (uint32_t)imports,
    .n_imports = sizeof imports / sizeof imports[0],
    .exports = (uint32_t)c32_exports,
    .exports_end = (uint32_t)c32_exports_end,
};

/* The first 32-bit code that runs: the host call32s it once after mapping the image. */
static void G2_STDCALL c32_start(void)
{
    for (const c32_init_fn *f = c32_inits; f < c32_inits_end; f++)
        (*f)();
}

void c32_log(const char *fmt, ...)
{
    char buf[512];
    va_list ap;                         /* char* on both sides: MSVC's va_list is clang's */
    va_start(ap, fmt);
    game_vsprintf(buf, fmt, ap);        /* the game's own CRT; no length limit, keep it short */
    va_end(ap);
    ((void (G2_STDCALL *)(const char *))imports[SVC_LOG].slot)(buf);
}

int c32_passenger_wanted(void)
{
    return (int)((uint32_t (G2_STDCALL *)(void))imports[SVC_PASSENGER_WANTED].slot)();
}

/* ---- hooks ------------------------------------------------------------------------- */

#define TRAMP_SIZE 32
#define MAX_TRAMPS 32
#define DETOUR_MAX 16

/* Code written at init and run later: in its own page-aligned section (c32.ld), so no
 * variable shares its page. Rosetta treats a write into a page it has translated code from
 * as self-modifying code; a store to a neighbouring variable every frame made a trampoline
 * jump into garbage (measured 2026-10-23, docs/c32.md "Pitfalls"). */
__attribute__((section(".c32.tramp")))
static uint8_t tramps[MAX_TRAMPS][TRAMP_SIZE];
static unsigned n_tramps;

static int bytes_equal(const uint8_t *a, const uint8_t *b, unsigned n)
{
    for (unsigned i = 0; i < n; i++)
        if (a[i] != b[i])
            return 0;
    return 1;
}

/* op rel32 (E8 call / E9 jmp) at `at`, to `target` */
static void put_rel32(uint8_t *at, uint8_t op, uint32_t target)
{
    uint32_t rel = target - ((uint32_t)at + 5);
    at[0] = op;
    at[1] = (uint8_t)rel;
    at[2] = (uint8_t)(rel >> 8);
    at[3] = (uint8_t)(rel >> 16);
    at[4] = (uint8_t)(rel >> 24);
}

static uint32_t rel32_target(const uint8_t *at)
{
    uint32_t rel = at[1] | (uint32_t)at[2] << 8 | (uint32_t)at[3] << 16 | (uint32_t)at[4] << 24;
    return (uint32_t)at + 5 + rel;
}

void *c32_detour(uint32_t va, const uint8_t *orig, unsigned n, void *fn)
{
    uint8_t *code = (uint8_t *)va;
    if (n < 5 || n > DETOUR_MAX || n_tramps == MAX_TRAMPS) {
        c32_log("detour 0x%x: bad length %u or out of trampolines", va, n);
        return 0;
    }
    if (!bytes_equal(code, orig, n)) {
        c32_log("detour 0x%x: original bytes differ (not vanilla 11.44, or hooked already)", va);
        return 0;
    }
    uint8_t *t = tramps[n_tramps++];
    for (unsigned i = 0; i < n; i++)
        t[i] = code[i];
    put_rel32(t + n, 0xE9, va + n);     /* ...then back into the function */
    put_rel32(code, 0xE9, (uint32_t)fn);
    for (unsigned i = 5; i < n; i++)
        code[i] = 0x90;
    c32_log("hook 0x%x -> 0x%x (detour, %u bytes to 0x%x)", va, (uint32_t)fn, n, (uint32_t)t);
    return t;
}

void *c32_callhook(uint32_t site, uint32_t expect_target, void *fn)
{
    uint8_t *code = (uint8_t *)site;
    if (code[0] != 0xE8) {
        c32_log("callhook 0x%x: not an E8 call", site);
        return 0;
    }
    uint32_t prev = rel32_target(code);
    put_rel32(code, 0xE8, (uint32_t)fn);
    c32_log("hook 0x%x -> 0x%x (call, original 0x%x%s)", site, (uint32_t)fn, prev,
            prev == expect_target ? "" : ", chained over an earlier hook");
    return (void *)prev;
}
