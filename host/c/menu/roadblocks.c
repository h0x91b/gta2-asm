/* roadblocks.c — the K menu rows "Place roadblock: <crew>" / "Remove roadblocks: <n>" on the
 * Player page. The roadblocks themselves are C32 (host/c32/roadblocks.c, docs/c32.md): a row
 * only records the request, and the DM_FRAME hands it to the C32 rb_frame on the game's
 * side of the frame, which also keeps the slots in step with the game every frame.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static const char *const kind_names[] = { "police", "FBI", "army" };
#define NKINDS 3

static uint32_t req;                    /* 1 place, 2 remove all, for rb_tick */
static int kind;                        /* index into kind_names */
static gptr fn_frame;                   /* C32 exports: rb_frame, rb_up */
static const uint32_t *up;

/* DM_FRAME: const char *rb_frame(req, kind) in C32, every frame */
static void rb_tick(void)
{
    if (!fn_frame) {
        fn_frame = (gptr)(uintptr_t)c32_need("rb_frame");
        up = c32_need("rb_up");
    }
    uint32_t a[2] = { req, (uint32_t)kind };
    req = 0;
    gptr toast = (gptr)call32(fn_frame, a, 2, 0, 0, 0);
    if (toast)
        dm_toast_set((const char *)(uintptr_t)toast);   /* C32 memory, mapped 1:1 */
}
DM_FRAME(10, rb_tick);

/* RETURN places one, LEFT / RIGHT pick police, FBI or army */
static void rbplace_change(const struct dm_item *it, int dir)
{
    (void)it;
    if (!dir)
        req = 1;
    else
        kind = (kind + dir + NKINDS) % NKINDS;
}

static void rbplace_fmt(char *end) { strcpy(end, kind_names[kind]); }

static void rbclear_change(const struct dm_item *it, int dir)
{
    (void)it;
    if (!dir)
        req = 2;
}

static void rbclear_fmt(char *end) { snprintf(end, 32, "%u", up ? *up : 0); }

DM_VALUE_FNS(rbplace);
DM_VALUE_FNS(rbclear);
DM_ITEM(dmp_player, 50, DM_VALUE, "Place roadblock: ", &dmv_rbplace);
DM_ITEM(dmp_player, 60, DM_VALUE, "Remove roadblocks: ", &dmv_rbclear);
