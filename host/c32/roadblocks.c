/* roadblocks.c — "Place roadblock" / "Remove roadblocks" on the K menu's Player page (the
 * rows are host C: host/c/menu/roadblocks.c): a real police roadblock (cars across the road,
 * barriers, cops behind them) built by the game's own code on the nearest road tile ahead of
 * the player, kept until "Remove roadblocks", up to RB_SLOTS at once, at any wanted level.
 *
 * How the game does it (Ghidra, gta2-segments.fixed.exe, decompiled 2026-10-21;
 * docs/re/gangs-and-peds.md section 7):
 * - PoliceManager (pointer at 0x66B7A0) has only roadblocks[2] at +0x664 (PoliceRoadblock,
 *   0xA4). PoliceManager_TryCreateRoadblockAt 0x4AEE70, thiscall(tileX, tileY, dir), ret
 *   0xC: picks the crew kind from copLevel +0x654 (3, 4 police, 5 FBI, 6 army ->
 *   g_crewSpawnKind 0x66B798), z = FindMaxZ at the tile, then PoliceRoadblock_Create
 *   0x4ADB70 on roadblocks[0] (else [1]) with orientation 3 for dir 1/2 (road along y: it
 *   scans x for the road's width) or 2 otherwise (road along x). Create walks the road's
 *   ground type (block +0xB & 3, 1 = road) across up to 12 tiles, checks the box for
 *   obstacles, then alternates barrier pairs + a guard (PoliceManager_SpawnRoadblockGuard
 *   0x4A9B40: police or FBI only) and cars (CarManager_SpawnCarOnGround, category ROADBLOCK,
 *   driverClass 4) lane by lane; active = 1, lifeTimer = 100.
 * - What removes one: PoliceRoadblock_Update 0x4AD6C0, called by PoliceManager_Update
 *   0x4AEF70 for those two slots only, counts lifeTimer down, then once no car, barrier or
 *   guard has been on screen for 0xC9 ticks and the player is far enough, calls
 *   PoliceRoadblock_Remove 0x4ABD70. Nothing else in the police code removes them; the cars
 *   themselves are not recycled (Car_CanBeRecycled 0x424030 refuses driverClass 4).
 * - So ours live in our own slots (one PoliceRoadblock_Ctor 0x4AC040 each) that the game
 *   never updates: no timer, no despawn, no tie to the wanted level. Each slot has a header
 *   in front whose first dword plays PoliceManager.copLevel, so TryCreateRoadblockAt runs on
 *   `slot - 0x664` (it reads nothing else of the manager) and does the crew pick and the z
 *   of the original. Once per gameplay frame rb_frame drops car pointers whose driverClass
 *   is no longer 4 and guards that left the game or are no longer ROAD_BLOCK_GUARD (their
 *   slots get reused), as Update does, so Remove only touches what is still ours. A new
 *   Game* (another level) forgets them.
 *
 * Placement: from the player (or their car) along its rotation, every half block from 1 to
 * 12 blocks ahead, else ring by ring around them out to 16 tiles (the nearest road first),
 * the first tile whose block one level below the player's z is road (MapBlocks_GetBlock
 * 0x4653C0 on g_MapBlocks 0x662C08, ground = block +0xB & 3) and at least RB_GAP tiles from
 * another of ours: Create's obstacle box does not see cars, so without the gap three
 * roadblocks stacked up on neighbouring tiles (measured). The road's direction comes from
 * its green arrows (block +0xA: bits 0-1 left/right, 2-3 up/down, docs/formats/lessons.md);
 * a junction or an unmarked tile falls back to the player's heading. When Create refuses
 * (an obstacle, a road wider than 12) the search goes on.
 */
#include "c32.h"

C32_OFFSET(Game, currentPlayer, 0x38);
C32_OFFSET(Player, ped, 0x2C4);
C32_OFFSET(Ped, rotation, 0x12C);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(Ped, position, 0x1AC);
C32_OFFSET(Ped, occupation, 0x240);
C32_OFFSET(Car, body, 0x50);
C32_OFFSET(Car, driverClass, 0x7C);
C32_OFFSET(Sprite, rotation, 0x0);
C32_OFFSET(Sprite, x, 0x14);
C32_OFFSET(BlockInfo, arrows, 0xA);
C32_OFFSET(BlockInfo, slopeType, 0xB);
C32_OFFSET(PoliceManager, copLevel, 0x654);
C32_OFFSET(PoliceManager, roadblocks, 0x664);
C32_OFFSET(PoliceRoadblock, cars, 0x10);
C32_OFFSET(PoliceRoadblock, guards, 0x88);
C32_OFFSET(PoliceRoadblock, collisionRect, 0xA0);
C32_ASSERT(sizeof(PoliceRoadblock) == 0xA4);

#define RB_SLOTS        8
#define RB_GAP          4               /* tiles kept between two of ours (Create does not see cars) */
#define RB_STEPS        24              /* half blocks ahead */
#define RB_RING         16
#define CLASS_ROADBLOCK 4               /* Car.driverClass of a roadblock car */
#define OCC_RB_GUARD    37              /* ROAD_BLOCK_GUARD (docs/re/gangs-and-peds.md) */

#define G_GAME          0x5EB4FC        /* Game* */
#define G_MAPBLOCKS     0x662C08        /* MapBlocks* */

GAME_FN(void, G2_THISCALL, PoliceRoadblock_Ctor, 0x4AC040, (PoliceRoadblock *self));
GAME_FN(void, G2_THISCALL, PoliceRoadblock_Remove, 0x4ABD70, (PoliceRoadblock *self));
GAME_FN(void, G2_THISCALL, PoliceManager_TryCreateRoadblockAt, 0x4AEE70,
        (PoliceManager *self, int tx, int ty, int dir));
GAME_FN(uint32_t, G2_FASTCALL, Ped_IsAttachedToGame, 0x433B40, (Ped *self));
GAME_FN(BlockInfo *, G2_THISCALL, MapBlocks_GetBlock, 0x4653C0, (void *self, int x, int y, int z));

/* One of ours: the header TryCreateRoadblockAt reads as PoliceManager.copLevel (the
 * manager it is given is `&rb - 0x664`), the tile it was built on, then the roadblock. */
struct slot {
    int32_t cop_level;
    int32_t tx, ty;
    int32_t pad;
    PoliceRoadblock rb;
};
C32_ASSERT(offsetof(struct slot, rb) - offsetof(struct slot, cop_level) ==
           offsetof(PoliceManager, roadblocks) - offsetof(PoliceManager, copLevel));

static struct slot slots[RB_SLOTS];
static int inited;                      /* the Ctors ran (lazily: the game's heap is up) */
static Game *rb_game;                   /* Game* the slots belong to */
static const uint8_t kind_cop[] = { 3, 5, 6 };  /* copLevel: police, FBI, army */

/* active slots, for the host's "Remove roadblocks: N" row */
uint32_t rb_up;
C32_EXPORT(rb_up);

/* the placement in progress */
static struct slot *cur;
static int rb_z, sdx, sdy, cur_dir;

static char toast[48];

static void toast_fmt(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    game_vsprintf(toast, fmt, ap);
    va_end(ap);
}

static void count_up(void)
{
    rb_up = 0;
    for (int i = 0; inited && i < RB_SLOTS; i++)
        rb_up += slots[i].rb.active != 0;
}

static Ped *player_ped(void)
{
    Game *g = *(Game *volatile *)G_GAME;
    Player *pl = g ? g->currentPlayer : 0;
    return pl ? pl->ped : 0;
}

/* the slots, each through PoliceRoadblock_Ctor (allocates its collisionRect) */
static void ensure(void)
{
    if (inited)
        return;
    inited = 1;
    rb_game = *(Game *volatile *)G_GAME;
    for (int i = 0; i < RB_SLOTS; i++)
        PoliceRoadblock_Ctor(&slots[i].rb);
}

/* another level: the old cars, peds and objects are gone, keep only the rects */
static void forget(void)
{
    for (int i = 0; i < RB_SLOTS; i++) {
        uint8_t *p = (uint8_t *)&slots[i].rb;
        for (unsigned j = 0; j < offsetof(PoliceRoadblock, collisionRect); j++)
            p[j] = 0;
    }
}

/* half a block along (sin a, cos a), a = rotation * 2pi / 1440 (the K menu's spawn
 * convention), rounded by the FPU as the game would (fistp, round to nearest) */
static void half_block_ahead(int rot)
{
    double a = rot * (2 * 3.14159265358979323846 / 1440), s, c;
    __asm__("fsincos" : "=t"(c), "=u"(s) : "0"(a));
    s *= 0x2000;
    c *= 0x2000;
    __asm__("fistpl %0" : "=m"(sdx) : "t"(s) : "st");
    __asm__("fistpl %0" : "=m"(sdy) : "t"(c) : "st");
}

/* 1 when a roadblock now stands in cur around tile (tx, ty) (road at level rb_z; the
 * direction from its arrows or the heading) */
static int try_tile(int tx, int ty, int kind)
{
    if ((unsigned)tx > 255 || (unsigned)ty > 255 || (unsigned)rb_z > 7)
        return 0;
    for (int i = 0; i < RB_SLOTS; i++) {
        struct slot *s = &slots[i];
        if (s->rb.active && (unsigned)(s->tx - tx + RB_GAP) <= 2 * RB_GAP &&
            (unsigned)(s->ty - ty + RB_GAP) <= 2 * RB_GAP)
            return 0;                   /* within RB_GAP of one of ours */
    }
    BlockInfo *b = MapBlocks_GetBlock(*(void *volatile *)G_MAPBLOCKS, tx, ty, rb_z);
    if (!b || (b->slopeType & 3) != 1)
        return 0;                       /* no block, or not road */
    int arrows = b->arrows, dir;
    if (!(arrows & 0xC))
        dir = arrows & 3 ? 3 : 0;       /* 3: road along x */
    else
        dir = arrows & 3 ? 0 : 1;       /* 1: road along y */
    if (!dir)                           /* junction or no arrows: the way the player faces */
        dir = (sdy < 0 ? -sdy : sdy) >= (sdx < 0 ? -sdx : sdx) ? 1 : 3;
    cur_dir = dir;
    cur->cop_level = kind_cop[kind];
    PoliceManager_TryCreateRoadblockAt(
        (PoliceManager *)((uint8_t *)&cur->rb - offsetof(PoliceManager, roadblocks)), tx, ty, dir);
    cur->tx = tx;
    cur->ty = ty;
    return cur->rb.active != 0;
}

/* the next free slot, on the first road tile ahead of the player, else on the nearest road
 * tile around them (rings out to RB_RING) */
static const char *place(int kind)
{
    ensure();
    cur = 0;
    for (int i = 0; i < RB_SLOTS && !cur; i++)
        if (!slots[i].rb.active)
            cur = &slots[i];
    if (!cur)
        return "All roadblocks in use";
    Ped *ped = player_ped();
    if (!ped)
        return "No player";
    SCR_Vector3 *pos = &ped->position;
    int rot = (uint16_t)ped->rotation;
    if (ped->currentCar) {
        Sprite *spr = ped->currentCar->body;   /* in a car: its sprite */
        if (!spr)
            return "No player";
        pos = (SCR_Vector3 *)&spr->x;
        rot = (uint16_t)spr->rotation;
    }
    int px = pos->x, py = pos->y;
    rb_z = (pos->z >> 14) - 1;          /* block level under the player */
    half_block_ahead(rot);
    int placed = 0;
    for (int k = 2; k <= RB_STEPS && !placed; k++)  /* straight ahead */
        placed = try_tile((sdx * k + px) >> 14, (sdy * k + py) >> 14, kind);
    for (int r = 1; r <= RB_RING && !placed; r++)
        for (int dy = -r; dy <= r && !placed; dy++)
            for (int dx = -r; dx <= r && !placed; dx++)
                if (dx == r || dx == -r || dy == r || dy == -r)    /* the ring's border */
                    placed = try_tile((px >> 14) + dx, (py >> 14) + dy, kind);
    if (!placed) {
        c32_log("menu: no road for a roadblock near %d,%d level %d rot %d", px, py, rb_z, rot);
        return "No room for a roadblock ahead";
    }
    int cars = 0, cops = 0;
    for (int i = 0; i < 6; i++) {
        cars += cur->rb.cars[i] != 0;
        cops += cur->rb.guards[i] != 0;
    }
    Sprite *first = cur->rb.cars[0] ? cur->rb.cars[0]->body : 0;
    c32_log("menu: roadblock at tile %d,%d dir %d: %d cars, %d cops; first car at %d,%d,%d",
            cur->tx, cur->ty, cur_dir, cars, cops, first ? first->x : 0, first ? first->y : 0,
            first ? first->z : 0);
    count_up();
    toast_fmt("Roadblock placed, %d up", rb_up);
    return toast;
}

/* PoliceRoadblock_Remove on every active slot, as the game ends its own ones */
static const char *clear(void)
{
    int n = 0;
    for (int i = 0; inited && i < RB_SLOTS; i++)
        if (slots[i].rb.active) {
            n++;
            PoliceRoadblock_Remove(&slots[i].rb);
        }
    c32_log("menu: removed %d roadblocks", n);
    count_up();
    toast_fmt("Removed %d roadblocks", n);
    return toast;
}

/* drop what the game took back, as PoliceRoadblock_Update does: cars no longer of the
 * roadblock class, guards that left the game or are no longer ROAD_BLOCK_GUARD */
static void prune(void)
{
    for (int i = 0; i < RB_SLOTS; i++) {
        PoliceRoadblock *rb = &slots[i].rb;
        if (!rb->active)
            continue;
        for (int j = 0; j < 6; j++) {
            if (rb->cars[j] && rb->cars[j]->driverClass != CLASS_ROADBLOCK)
                rb->cars[j] = 0;
            Ped *g = rb->guards[j];
            if (g && (g->occupation != OCC_RB_GUARD || !(Ped_IsAttachedToGame(g) & 0xFF)))
                rb->guards[j] = 0;
        }
    }
}

/* Once per gameplay frame, from the host's DM_FRAME (host/c/menu/roadblocks.c): req 1 =
 * place one (kind 0 police, 1 FBI, 2 army), 2 = remove them all. Returns the toast, or 0. */
const char *G2_STDCALL rb_frame(uint32_t req, uint32_t kind)
{
    const char *t = 0;
    if (inited && *(Game *volatile *)G_GAME != rb_game) {
        rb_game = *(Game *volatile *)G_GAME;
        forget();
        count_up();
    }
    if (req == 1)
        t = place(kind < sizeof kind_cop ? (int)kind : 0);
    else if (req == 2)
        t = clear();
    if (inited)
        prune();
    return t;
}
C32_EXPORT(rb_frame);
