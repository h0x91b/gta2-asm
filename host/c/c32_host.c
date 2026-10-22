/* c32_host.c — the 64-bit side of C32 (docs/c32.md): maps the 32-bit image that
 * the host/c32 sources are linked into, binds its host services, runs its initialisers, and owns
 * the car bonus's config key and K menu row (64-bit host C serving C32 code).
 *
 * The image (c32.bin, raw, linked at its header's base) is embedded in the loader by
 * host/c32_blob.asm. c32_load runs from _main right after protect_image: the initialisers
 * call game code (the CRT's vsprintf for c32_log), which needs .text executable, and they
 * patch it, so .text is rwx only while they run.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "game.h"
#include "../c32/c32_abi.h"

extern const uint8_t c32_blob[] NASM(c32_blob);
extern const uint8_t c32_blob_end[] NASM(c32_blob_end);
/* loader.asm: a 32-bit import stub `push index; jmp common32` bound by name to a handler
 * in the shim tables (shimtab_c32 for "c32"); returns its VA */
uint32_t new_slot(const char *dll, const char *name, int ordinal) NASM(new_slot);

#define TEXT_START 0x3F1000             /* gta2.exe .text, page-aligned (loader.asm map log) */
#define TEXT_END   0x56E000

#define BONUS_DEFAULT 333
#define BONUS_MAX     1000000

static struct c32_header *hdr;          /* = the mapped image */
static uint32_t *bonus;                 /* exported car_bonus (c32/car_bonus.c) */
static uint32_t bonus_amount = BONUS_DEFAULT;

static void c32_fail(const char *why)
{
    printf("c32: FAIL: %s\n", why);
    exit(1);
}

/* the address of an exported C32 global, or 0 */
static void *c32_find(const char *name)
{
    for (uint32_t e = hdr->exports; e < hdr->exports_end; e += 8)
        if (strcmp((const char *)(uintptr_t)rd32(e), name) == 0)
            return (void *)(uintptr_t)rd32(e + 4);
    return 0;
}

void c32_load(void)
{
    const struct c32_header *h = (const struct c32_header *)c32_blob;
    size_t blob = (size_t)(c32_blob_end - c32_blob);
    if (blob < sizeof *h || h->magic != C32_MAGIC || h->version != C32_VERSION)
        c32_fail("c32.bin has no C32 header (rebuild host/c32)");
    if (h->image_end - h->base != blob || h->bss_end < h->image_end)
        c32_fail("c32.bin size does not match its header");
    size_t size = (h->bss_end - h->base + 0xFFF) & ~(size_t)0xFFF;
    /* hint, not MAP_FIXED: a fixed map would silently replace whatever is there */
    void *want = (void *)(uintptr_t)h->base;
    void *p = mmap(want, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p != want) {
        printf("c32: FAIL: 0x%x-0x%zx is taken (mmap gave %p)\n", h->base, h->base + size, p);
        exit(1);
    }
    memcpy(p, c32_blob, blob);
    hdr = p;
    memset((void *)(uintptr_t)hdr->bss_start, 0, hdr->bss_end - hdr->bss_start);
    for (uint32_t i = 0; i < hdr->n_imports; i++) {
        uint32_t imp = hdr->imports + 8 * i;
        wr32(imp + 4, new_slot("c32", (const char *)(uintptr_t)rd32(imp), 0));
    }
    bonus = c32_find("car_bonus");
    if (!bonus)
        c32_fail("the image exports no car_bonus");
    printf("c32: image 0x%x-0x%x (%zu bytes + %u bss), %u services, %u exports\n",
           hdr->base, hdr->bss_end, blob, hdr->bss_end - hdr->bss_start, hdr->n_imports,
           (hdr->exports_end - hdr->exports) / 8);
    if (mprotect((void *)TEXT_START, TEXT_END - TEXT_START, PROT_READ | PROT_WRITE | PROT_EXEC))
        c32_fail("cannot unprotect .text for the C32 initialisers");
    call32(hdr->start, 0, 0, 0, 0, 0);
    if (mprotect((void *)TEXT_START, TEXT_END - TEXT_START, PROT_READ | PROT_EXEC))
        c32_fail("cannot protect .text again");
}

/* ---- host services (shimtab_c32, c32_blob.asm): import handlers, rdi = 32-bit args ---- */

uint64_t c32_svc_log(const uint32_t *args)
{
    printf("c32: %s\n", (const char *)(uintptr_t)args[0]);
    return 0;
}

/* ---- the car bonus (c32/car_bonus.c): config key and K menu row ----------------------- */

/* config.asm, `mods:` section: 0 applied, 1 unknown key, -1 bad value (*msg = why) */
int c32_cfg_mods(const char *key, const char *val, const char **msg)
{
    if (strcmp(key, "car_enter_bonus") != 0)
        return 1;
    char *end;
    long v = strtol(val, &end, 10);
    if (end == val || *end || v < 0 || v > BONUS_MAX) {
        *msg = "mods.car_enter_bonus: expected dollars, 0 (off) .. 1000000";
        return -1;
    }
    if (v)
        bonus_amount = (uint32_t)v;
    *bonus = (uint32_t)v;
    printf("config: mods.car_enter_bonus = %ld%s\n", v, v ? "" : " (off)");
    return 0;
}

/* K menu value row (host/menu/mods.asm, DM_VALUE): any key toggles on / off */
void c32_carbonus_change(void *item, int dir)
{
    (void)item;
    (void)dir;
    *bonus = *bonus ? 0 : bonus_amount;
}

void c32_carbonus_fmt(char *end)
{
    if (*bonus)
        snprintf(end, 32, "$%u", *bonus);
    else
        snprintf(end, 32, "off");
}
