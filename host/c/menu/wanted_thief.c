/* wanted_thief.c — the K menu row Spawn > "Wanted thief: <n> stars": a car thief in red
 * (remap 17, the mugger's red) 1.5 blocks in front of the player, whom the police hunt as a
 * player with n stars; the player's own wanted level is untouched. The hunt itself is C32
 * (host/c32/wanted_thief.c, docs/wanted-thief.md): the row spawns the ped through
 * km_spawn_ped, and the DM_FRAME hands him to the C32 wt_frame, which keeps the pursuit
 * going every frame. LEFT / RIGHT pick the stars (1..6), RETURN spawns.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dm.h"
#include "../spawn.h"

#define WT_REMAP  17                    /* bright red (PED_REMAP 17, the ambient mugger) */
#define WT_ROLE   11                    /* car thief: occ 16, class 6 (spawn_ped.c sp_roles) */
#define WT_DIST   0x6000                /* 1.5 blocks in front */

static int stars = 4;
static uint32_t req_ped;                /* a spawned thief for wt_tick, 0 none */
static uint32_t req_car;                /* a car for him to steal (gta2ctl), 0 none */
static gptr fn_frame;                   /* C32 exports: wt_frame */

static void *c32_need(const char *name)
{
    void *p = c32_find(name);
    if (!p) {
        printf("c32: FAIL: the image exports no %s\n", name);
        exit(1);
    }
    return p;
}

uint32_t km_spawn_wanted_thief(int n, int32_t x, int32_t y, int32_t z, int rot)
{
    uint32_t ped = km_spawn_ped(WT_REMAP, WT_ROLE, 0, x, y, z, rot);
    if (!ped)
        return 0;
    if (n >= 1 && n <= 6)
        stars = n;
    req_ped = ped;
    km_spawn_why = "Wanted thief spawned";
    printf("menu: wanted thief %#x id %d, %d stars\n", ped, GP(Ped, ped)->id, stars);
    return ped;
}

void km_wanted_thief_steal(uint32_t car)
{
    req_car = car;
}

/* DM_FRAME: const char *wt_frame(req, ped, stars) in C32, every frame */
static void wt_tick(void)
{
    if (!fn_frame)
        fn_frame = (gptr)(uintptr_t)c32_need("wt_frame");
    uint32_t a[3] = { req_ped ? 1 : req_car ? 2 : 0, req_ped ? req_ped : req_car,
                      (uint32_t)stars };
    if (req_ped)
        req_ped = 0;
    else
        req_car = 0;
    gptr toast = (gptr)call32(fn_frame, a, 3, 0, 0, 0);
    if (toast)
        dm_toast_set((const char *)(uintptr_t)toast);   /* C32 memory, mapped 1:1 */
}
DM_FRAME(15, wt_tick);

static void wt_spawn(void)
{
    int32_t pos[4];
    if (km_spawn_pos(pos, WT_DIST))
        km_spawn_wanted_thief(stars, pos[0], pos[1], pos[2], pos[3]);
    dm_toast_set(km_spawn_why);
}

static void wthief_change(const struct dm_item *it, int dir)
{
    (void)it;
    if (!dir)
        dm_defer(wt_spawn);
    else
        stars = (stars - 1 + dir + 6) % 6 + 1;
}

static void wthief_fmt(char *end) { snprintf(end, 32, "%d star%s", stars, stars > 1 ? "s" : ""); }

DM_VALUE_FNS(wthief);
DM_PAGE_EXTERN(dmp_spawn);
DM_ITEM(dmp_spawn, 40, DM_VALUE, "Wanted thief: ", &dmv_wthief);
