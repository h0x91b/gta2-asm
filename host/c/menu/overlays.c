/* overlays.c — the host side of the two world overlays: the K menu rows, the per-frame
 * hooks and the stats lines of "Ped paths" (root page) and "Road network" (Debug flags
 * page). The drawing is C32 (host/c32/debug_paths.c, debug_roads.c, overlay.c): it reads
 * a few hundred game structs and makes thousands of WorldPointToScreen / DrawFlatRect2D
 * calls a frame, each a plain call there and a mode switch from here. So each hook below
 * does one call32 into the image and prints what it counted.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dm.h"

#define STATS_FRAMES 300                /* a stats line this often while an overlay is on */

/* the C32 side's counters (C32_EXPORT dp_stats, dr_stats), same layout */
struct dp_stats {
    uint32_t listed, alive, on_path, target_only;
};
struct dr_stats {
    int32_t x0, x1, y0, y1;
    uint32_t tileu;
    uint32_t pave, arrow, junc, link, light, route, phase;
};

static uint8_t paths_on;                /* "Ped paths" (DM_FLAG byte) */
static uint8_t roads_mode;              /* "Road network": 0 off, 1 cars, 2 peds, 3 both */
static const char *const roads_names[] = { "off", "cars", "peds", "cars + peds" };

static void *c32_need(const char *name)
{
    void *p = c32_find(name);
    if (!p) {
        printf("c32: FAIL: the image exports no %s\n", name);
        exit(1);
    }
    return p;
}

/* ---- Ped paths ---- */

static void paths_frame(void)
{
    static uint32_t draw, stats_frame;
    static const struct dp_stats *st;
    if (!paths_on)
        return;
    if (!draw) {
        draw = (uint32_t)(uintptr_t)c32_need("dp_draw");
        st = c32_need("dp_stats");
    }
    uint32_t arg = r_frames;
    if (!(uint32_t)call32(draw, &arg, 1, 0, 0, 0) || r_frames - stats_frame < STATS_FRAMES)
        return;
    stats_frame = r_frames;
    printf("paths: %d peds listed, %d alive on foot, %d on a path, %d moveTarget only "
           "(zoom %d%%)\n", st->listed, st->alive, st->on_path, st->target_only, cam_zoom_pct);
}

/* ---- Road network ---- */

static void roads_change(const struct dm_item *item, int dir)
{
    (void)item;
    roads_mode = (uint8_t)((roads_mode + (dir ? dir : 1)) & 3);    /* RETURN: the next */
}

static void roads_fmt(char *end)
{
    strcpy(end, roads_names[roads_mode]);
}

static void roads_frame(void)
{
    static uint32_t draw, stats_frame;
    static const struct dr_stats *st;
    if (!roads_mode)
        return;
    if (!draw) {
        draw = (uint32_t)(uintptr_t)c32_need("dr_draw");
        st = c32_need("dr_stats");
    }
    uint32_t args[2] = { roads_mode, r_frames };
    if (!(uint32_t)call32(draw, args, 2, 0, 0, 0) || r_frames - stats_frame < STATS_FRAMES)
        return;
    stats_frame = r_frames;
    printf("roads: view x %d..%d y %d..%d, tile %d units; %d pavement, %d arrow tiles, "
           "%d junctions, %d links, %d lights, %d routes, light phase %d\n",
           st->x0, st->x1, st->y0, st->y1, st->tileu, st->pave, st->arrow, st->junc,
           st->link, st->light, st->route, st->phase);
}

DM_VALUE_FNS(roads);
DM_ITEM(dmp_root, 50, DM_FLAG, "Ped paths: ", &paths_on);
DM_ITEM(dmp_flags, 100, DM_VALUE, "Road network: ", &dmv_roads);
DM_FRAME(40, paths_frame);
DM_FRAME(50, roads_frame);
