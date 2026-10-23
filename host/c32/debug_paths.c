/* debug_paths.c — the "Ped paths" overlay of the K menu (root page; the row, the per-frame
 * hook and the stats line are host C, host/c/menu/overlays.c, which call32s dp_draw once a
 * frame while the toggle is on).
 *
 * For each live ped on foot: a dotted line from the ped through the next DP_WAYPOINTS
 * waypoints of its path, each with a square and its number (1 = the next one), all in the
 * ped's own colour (ov_hue of its id). A ped with no path left but a moveTarget gets a
 * cyan line to that instead, and one with neither a grey tick one block along its
 * rotation (the convention km_spawn_pos uses; checked against the player walking north).
 * Measured in Downtown (2026-10-21): the wandering dummies have neither — no pathCursor,
 * moveTarget -1.0, objective 0 — so they only get the tick; paths are planned for peds
 * with an objective (go to, chase, enter a car: the 16 callers of Ped_MoveTowardTarget;
 * gta2ctl walk_to gives the player one).
 *
 * Test build: C32FLAGS_EXTRA=-DDP_TEST=F sends every ped after the player on foot at frame
 * F (Ped_SetObjective), so paths show up without a mission.
 *
 * Ped fields (re/gta2_types.h, Ghidra; relayed from the Ped naming pass): path[100] =
 * S3Bytes map cells (x, y, z block coordinates), ended by a (0,0,0) triple; pathCursor =
 * the current one (Ped_MoveTowardTarget 0x4380D0 steps it by 3). Peds: PedManager*
 * 0x5E5BBC, the in-use list from activeListHead through nextPed (PedManager_UpdateAll
 * 0x445960). A cell becomes a world point as cell * 1.0 (0x40CE30 there), +0.5 for the
 * centre. Ped_SetObjective and PedManager from gta2-seuko-mod by izawartka
 * (https://github.com/izawartka/gta2-seuko-mod), src/game/functions.h, memory.h @25b1985.
 */
#include "overlay.h"

#define G_PEDMGR     0x5E5BBC           /* g_PedManager: PedManager* */
#define PED_ALIVE    99
#define SCR_NONE     (-0x4000)          /* -1.0: no moveTarget */
#define MAXPEDS      400                /* the pool has 200; a broken list cannot hang us */
#define DP_WAYPOINTS 10

#define GREEN 0xFF20FF20u
#define CYAN  0xFF20E0FFu
#define GREY  0xC0C0C0C0u

C32_OFFSET(PedManager, activeListHead, 0x4);
C32_OFFSET(Ped, path, 0x0);
C32_OFFSET(Ped, rotation, 0x12C);       /* short, 1440 = a full turn */
C32_OFFSET(Ped, objectiveTargetPed, 0x148);
C32_OFFSET(Ped, nextPed, 0x160);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(Ped, pathCursor, 0x18C);
C32_OFFSET(Ped, position, 0x1AC);
C32_OFFSET(Ped, moveTarget, 0x1C4);
C32_OFFSET(Ped, id, 0x200);
C32_OFFSET(Ped, lifeState, 0x234);
C32_OFFSET(Player, ped, 0x2C4);

/* what the host's "paths:" line prints, every DP_STATS_FRAMES while on */
struct dp_stats {
    uint32_t listed, alive, on_path, target_only;
};
struct dp_stats dp_stats;
C32_EXPORT(dp_stats);

#ifdef DP_TEST
GAME_FN(void, G2_THISCALL, Ped_SetObjective, 0x43BBC0, (Ped *self, int objective, int timer));
#endif

/* x87 at the game's precision, exactly as the NASM overlay did it: (sin, cos) * 1 block of
 * a Sprite/Ped rotation (1440 units per turn) */
static void heading(int32_t rot, int32_t *dx, int32_t *dy)
{
    static const uint64_t rot2rad = 0x3F71DF46A2529D39ull;     /* 2*pi / 1440 */
    static const int32_t len = 0x4000;
    int32_t c, s;
    __asm__ volatile("fildl %2\n\tfmull %3\n\tfsincos\n\t"     /* st0 = cos, st1 = sin */
                     "fimull %4\n\tfistpl %0\n\tfimull %4\n\tfistpl %1"
                     : "=m"(c), "=m"(s)
                     : "m"(rot), "m"(rot2rad), "m"(len));
    *dx = s;
    *dy = c;
}

static void draw_ped(Ped *ped)
{
    struct ov_pt at = ov_project(ped->position.x, ped->position.y, ped->position.z);
    struct ov_pt prev = at, pts[DP_WAYPOINTS];
    uint32_t col = ov_hue((uint32_t)ped->id);
    int k;
    for (k = 0; k < DP_WAYPOINTS; k++) {
        const uint8_t *cell = (const uint8_t *)ped->pathCursor + 3 * k;
        /* unsigned: also catches a null / foreign cursor */
        if ((uint32_t)cell - (uint32_t)ped > sizeof ped->path - 3)
            break;
        if (!(cell[0] | cell[1] | cell[2]))
            break;                      /* (0,0,0): the end of the path */
        pts[k] = ov_project(cell[0] << 14 | 0x2000, cell[1] << 14 | 0x2000, cell[2] << 14);
        ov_line(prev, pts[k], col);
        prev = pts[k];
    }
    if (k) {                            /* markers and labels over the whole line */
        dp_stats.on_path++;
        for (int i = 0; i < k; i++) {
            ov_mark(pts[i], i ? 2 : 3, col);    /* the next waypoint: a bigger square */
            ov_label(pts[i], (uint32_t)i + 1, col);
        }
        ov_mark(at, 2, col);
        return;
    }
    SCR_Vector3 mt = ped->moveTarget;   /* no path: the moveTarget, if any */
    if (mt.x != SCR_NONE && (mt.x != ped->position.x || mt.y != ped->position.y)) {
        dp_stats.target_only++;
        struct ov_pt t = ov_project(mt.x, mt.y, mt.z);
        ov_line(at, t, CYAN);
        ov_mark(t, 2, CYAN);
    } else {                            /* neither (a wandering ped): where it faces */
        int32_t dx, dy;
        heading(ped->rotation, &dx, &dy);
        struct ov_pt h = ov_project(ped->position.x + dx, ped->position.y + dy,
                                    ped->position.z);
        ov_line(at, h, GREY);
        ov_mark(h, 1, GREY);
    }
    ov_mark(at, 2, GREEN);
}

/* the overlay, one frame; 0 when there is nothing to draw for (no player camera) */
uint32_t G2_STDCALL dp_draw(uint32_t frame)
{
    (void)frame;
    if (!ov_setup())
        return 0;
    dp_stats = (struct dp_stats){ 0 };
    PedManager *mgr = *(PedManager **)G_PEDMGR;
    if (!mgr)
        return 1;
#ifdef DP_TEST
    Ped *player = ov_player()->ped;
#endif
    int left = MAXPEDS;
    for (Ped *ped = mgr->activeListHead; ped && left--; ped = ped->nextPed) {
        dp_stats.listed++;
        if (ped->lifeState != PED_ALIVE || ped->currentCar)
            continue;
        dp_stats.alive++;
#ifdef DP_TEST
        /* test only: at frame DP_TEST every ped is sent after the player on foot (then
         * objectiveTargetPed, which Ped_SetObjective clears), so the game plans real paths */
        if (frame == DP_TEST && ped != player) {
            Ped_SetObjective(ped, 16, 9999);        /* PED_OBJECTIVE_GO_TO_CHAR_ON_FOOT */
            ped->objectiveTargetPed = player;
        }
#endif
        draw_ped(ped);
    }
    return 1;
}
C32_EXPORT(dp_draw);
