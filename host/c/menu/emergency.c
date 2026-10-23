/* emergency.c — the K menu rows "Call ambulance" / "Call fire truck" on the Player page.
 * The game logic is C32 (host/c32/emergency.c, docs/c32.md): a row only records the request,
 * and the DM_FRAME hands it to the C32 de_frame on the game's side of the frame, with the
 * presented-frame counter (for the log), the Vehicle page's model (the car put on the road
 * when no parked one gets a truck) and the menu's last car; a car it spawns becomes the
 * menu's last car, as with any other spawn.
 */
#include <stdio.h>
#include <stdlib.h>
#include "dm.h"

static void *c32_need(const char *name)
{
    void *p = c32_find(name);
    if (!p) {
        printf("c32: FAIL: the image exports no %s\n", name);
        exit(1);
    }
    return p;
}

extern gptr dm_last_car NASM(dm_last_car);          /* helpers.c */
extern uint32_t dm_last_car_id NASM(dm_last_car_id);

static uint32_t req;                    /* 1 ambulance, 2 fire truck, for de_tick */
static gptr fn_frame, *spawned;         /* C32 exports: de_frame, de_spawned */

/* DM_FRAME: const char *de_frame(req, frame, model, last_car) in C32, every frame (it also
 * watches the queued body and logs the service slots) */
static void de_tick(void)
{
    if (!fn_frame) {
        fn_frame = (gptr)(uintptr_t)c32_need("de_frame");
        spawned = c32_need("de_spawned");
    }
    uint32_t a[4] = { req, r_frames, dm_spawnable[dm_model], dm_last_car };
    req = 0;
    gptr toast = (gptr)call32(fn_frame, a, 4, 0, 0, 0);
    if (*spawned) {
        dm_last_car = *spawned;
        dm_last_car_id = GP(Car, *spawned)->id;
    }
    if (toast)
        dm_toast_set((const char *)(uintptr_t)toast);   /* C32 rodata, mapped 1:1 */
}
DM_FRAME(30, de_tick);

/* RETURN calls (LEFT / RIGHT do nothing); no value text */
static void ambulance_change(const struct dm_item *it, int dir)
{
    (void)it;
    if (!dir)
        req = 1;
}

static void firetruck_change(const struct dm_item *it, int dir)
{
    (void)it;
    if (!dir)
        req = 2;
}

static void ambulance_fmt(char *end) { *end = 0; }
static void firetruck_fmt(char *end) { *end = 0; }

DM_VALUE_FNS(ambulance);
DM_VALUE_FNS(firetruck);
DM_ITEM(dmp_player, 70, DM_VALUE, "Call ambulance", &dmv_ambulance);
DM_ITEM(dmp_player, 80, DM_VALUE, "Call fire truck", &dmv_firetruck);
