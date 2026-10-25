/* c32_host.c — the 64-bit side of C32 (docs/c32.md): maps the 32-bit image that
 * the host/c32 sources are linked into, binds its host services, runs its initialisers, and owns
 * the car bonus's config key and K menu row, the passenger mod's switch, and the keyboard,
 * mouse, settings and K menu rows of on-foot strafe and mouse turning, the city-fights
 * switch (64-bit host C
 * serving C32 code).
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
#include "ctl.h"
#include "menu/dm.h"

extern const uint8_t c32_blob[] NASM(c32_blob);
extern const uint8_t c32_blob_end[] NASM(c32_blob_end);
/* loader.asm: a 32-bit import stub `push index; jmp common32` bound by name to a handler
 * in the shim tables (shimtab_c32 for "c32"); returns its VA */
uint32_t new_slot(const char *dll, const char *name, int ordinal) NASM(new_slot);

#define TEXT_START 0x3F1000             /* gta2.exe .text, page-aligned (loader.asm map log) */
#define TEXT_END   0x56E000

#define BONUS_DEFAULT 333
#define BONUS_MAX     1000000

#define DIK_LSHIFT 0x2A
#define DIK_RSHIFT 0x36

/* w32_dinput.asm: the keyboard state, 0x80 = down; the mouse; key names for logs */
extern const uint8_t di_keys[256] NASM(di_keys);
extern uint8_t have_focus NASM(have_focus);     /* SDL keyboard focus */
extern float mouse_dx NASM(mouse_dx);           /* motion accumulator, pixels */
int take_axis(float *acc) NASM(take_axis);      /* whole pixels out, the fraction stays */
void mouse_capture_on(void) NASM(mouse_capture_on);     /* SDL relative mode */
void mouse_capture_off(void) NASM(mouse_capture_off);
const char *dik_str(int dik) NASM(dik_str);
/* mods.passenger_enter (config.c key table, default on; K menu Mods page) */
uint8_t mods_passenger_enter;

static struct c32_header *hdr;          /* = the mapped image */
static uint32_t *bonus;                 /* exported car_bonus (c32/car_bonus.c) */
static uint32_t bonus_amount = BONUS_DEFAULT;

static void c32_fail(const char *why)
{
    printf("c32: FAIL: %s\n", why);
    exit(1);
}

/* the address of an exported C32 global or function (C32_EXPORT), or 0 */
void *c32_find(const char *name)
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

/* passenger_wanted() (c32/passenger.c, on the enter key only): the mod is on and a Shift
 * is held, read from the one keyboard state the DirectInput shim keeps */
uint64_t c32_svc_passenger_wanted(const uint32_t *args)
{
    (void)args;
    return mods_passenger_enter && ((di_keys[DIK_LSHIFT] | di_keys[DIK_RSHIFT]) & 0x80);
}

/* ---- on-foot strafe and mouse turning (c32/player_move.c) ----------------------------- */

#define MOUSE_GAP 3                     /* frames without a call = the motion is stale, dropped */

/* the controls: section of config.yaml (config.c's key table sets the defaults before main:
 * strafe on, Q / E, mouse turning off, 100%) and the K menu root rows below */
uint8_t pm_strafe_on;                   /* controls.strafe */
uint8_t pm_mouse_on;                    /* controls.mouse_turn */
uint8_t pm_key_left;                    /* DIK, controls.strafe_left */
uint8_t pm_key_right;                   /* DIK, controls.strafe_right */
int32_t pm_mouse_sens;                  /* controls.mouse_sensitivity, percent */
static uint8_t pm_captured;             /* relative mouse mode switched on by us */
static uint32_t pm_mouse_frame;         /* r_frames at the last on-foot mouse read */

/* config.c: one line after the config, so a run log says what is active */
void pm_report(void)
{
    printf("controls: strafe %s (%s / %s), mouse turning %s (%d%%)\n",
           pm_strafe_on ? "on" : "off", dik_str(pm_key_left), dik_str(pm_key_right),
           pm_mouse_on ? "on" : "off", pm_mouse_sens);
}

/* foot_input(struct c32_foot_input*, on_foot) (c32/player_move.c, every Player_MoveOnFoot):
 * the strafe keys, and while on foot the mouse: relative mode on while mouse turning is on
 * and the window has focus, given back when it is switched off (only if we took it: full
 * screen takes it too), the whole pixels since the last tick, dropped after a gap (the
 * first tick after a menu or a car) */
uint64_t c32_svc_foot_input(const uint32_t *args)
{
    struct c32_foot_input *in = (struct c32_foot_input *)(uintptr_t)args[0];
    in->mouse_on = pm_mouse_on;
    in->strafe = 0;
    in->mouse_px = 0;
    in->mouse_ok = 0;
    in->mouse_sens = pm_mouse_sens;
    if (!args[1])
        return 0;
    if (pm_strafe_on)
        in->strafe = (di_keys[pm_key_left] != 0) - (di_keys[pm_key_right] != 0);
    if (!pm_mouse_on) {
        if (pm_captured) {
            pm_captured = 0;
            mouse_capture_off();
        }
        return 0;
    }
    if (!have_focus)
        return 0;
    pm_captured = 1;
    mouse_capture_on();
    in->mouse_px = take_axis(&mouse_dx);
    uint32_t gap = r_frames - pm_mouse_frame;
    pm_mouse_frame = r_frames;
    in->mouse_ok = gap <= MOUSE_GAP;
    return 0;
}

/* ctl_on_foot(Player*, Ped*) (c32/player_move.c, after its own writes): gta2ctl steering */
uint64_t c32_svc_ctl_on_foot(const uint32_t *args)
{
    ctl_on_foot(args[0], args[1]);
    return 0;
}

DM_ITEM(dmp_root, 60, DM_FLAG, "Mouse turning: ", &pm_mouse_on);
DM_ITEM(dmp_root, 70, DM_FLAG, "Strafe (Q/E): ", &pm_strafe_on);

/* ---- the car bonus (c32/car_bonus.c): config key and K menu row ----------------------- */

/* config.c, `mods:` section: 0 applied, 1 unknown key, -1 bad value (*msg = why) */
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

/* K menu value row on the Mods page (menu/mods.c): any key toggles on / off */
static void c32_carbonus_change(const struct dm_item *item, int dir)
{
    (void)item;
    (void)dir;
    *bonus = *bonus ? 0 : bonus_amount;
}

static void c32_carbonus_fmt(char *end)
{
    if (*bonus)
        snprintf(end, 32, "$%u", *bonus);
    else
        snprintf(end, 32, "off");
}
/* ---- the passenger mod (c32/passenger.c): K menu row; the config key is in config.c --- */

static void c32_passenger_change(const struct dm_item *item, int dir)
{
    (void)item;
    (void)dir;
    mods_passenger_enter = !mods_passenger_enter;
}

static void c32_passenger_fmt(char *end)
{
    snprintf(end, 32, "%s", mods_passenger_enter ? "on" : "off");
}

/* ---- city fights (c32/city_fights.c): the switch, copied into the image every frame -- */

uint8_t mods_city_fights;               /* config.c key table (default off), K menu row */
static uint8_t *cf_on;                  /* exported city_fights */
static gptr cf_census;                  /* exported cf_frame: the census log line */

/* DM_FRAME: the C32 hooks read their own byte (thousands of predicate calls a tick, no
 * mode switch each); the host byte is the one the config and the menu write */
static void c32_city_fights_sync(void)
{
    if (!cf_on && !(cf_on = c32_find("city_fights")))
        c32_fail("the image exports no city_fights");
    if (*cf_on != mods_city_fights) {
        *cf_on = mods_city_fights;
        printf("c32: city_fights %s\n", mods_city_fights ? "on" : "off");
    }
    if (!mods_city_fights)
        return;
    if (!cf_census && !(cf_census = (gptr)(uintptr_t)c32_find("cf_frame")))
        c32_fail("the image exports no cf_frame");
    call32(cf_census, 0, 0, 0, 0, 0);
}
DM_FRAME(5, c32_city_fights_sync);

/* the Mods page rows (menu/mods.c) */
DM_VALUE_FNS(c32_carbonus);
DM_VALUE_FNS(c32_passenger);
DM_PAGE_EXTERN(dmp_mods);
DM_ITEM(dmp_mods, 10, DM_VALUE, "Car entry bonus: ", &dmv_c32_carbonus);
DM_ITEM(dmp_mods, 20, DM_VALUE, "Passenger: ", &dmv_c32_passenger);
DM_ITEM(dmp_mods, 30, DM_FLAG, "City fights: ", &mods_city_fights);
