/* debug_roads.c — the "Road network" overlay of the K menu (Debug flags page): the
 * navigation data the game drives and walks by, over the world. The row (LEFT / RIGHT /
 * RETURN cycle off -> cars -> peds -> all), the per-frame hook and the stats line are host
 * C (host/c/menu/overlays.c), which call32s dr_draw once a frame while it is on.
 *
 * cars:
 * - every road tile's green arrows (BlockInfo.arrows, low nibble: 1 left, 2 right, 4 up,
 *   8 down; TrafficSpawner_TrySpawnSide 0x4B34E0 and CarPhysics_ApplySteeringAssist
 *   0x4A17C0 read them, re/comments.csv) as white ticks: what ambient traffic actually
 *   follows, since it never routes (RoadNetwork_FindRoute 0x40E030 serves drive orders);
 * - the RGEN graph, RoadNetwork* 0x5D351C: segments hSegments / vSegments outlined grey;
 *   junctions (ids 1.. until minX == 0, as RoadNetwork_ShowJunctionIds 0x40D120 walks
 *   them) outlined yellow, their id on top once a tile is DR_LABEL_TILE units or more;
 *   each link (u16: junction id bits 0-8, RoadLink_GetJunctionId 0x40CE90; length 9-14,
 *   0x40CEA0; open bit 15, RoadLink_IsOpen 0x40CED0, SWITCH_ROAD clears it) a line from its
 *   junction to the target, shifted a quarter tile to the right of travel, so the two ways
 *   of a road do not overlap, with a bigger dot near the target end: blue open, red closed;
 * - traffic lights: TrafficLights* 0x6721CC. A TrafficJunction holds 4 lamp objects and
 *   4 glow Lights (Light_Init 0x469010, Light_SetColor 0x476B00).
 *   TrafficJunction_ApplyPhase 0x4C3A10 sets the lamp frame and the glow colour together
 *   (0xff00 green, 0xff8000 amber, 0xff0000 red), so each glow is drawn in its own live
 *   rgb (own decompilation, 2026-10-21);
 * - routes: a car with a drive order route (CarAI.routeSlot >= 1, RoadNetwork.routes, 256
 *   junction ids per slot, 0-terminated; routeStep is the current entry, CarAI_FollowRoute
 *   0x430320 / RoadNetwork_StoreRoute 0x40CC10) gets a line from the car through the
 *   junctions still ahead, in a hue from its id. Cars: CarPool* 0x5E4CA0, the in-use list
 *   through Car.next (CarPool_UpdateAll 0x42A2D0).
 *
 * peds: there is no ped graph. Dummies wander by heading, keep to the top block of a column
 * whose ground type is pavement (slopeType & 3 == 2; MapBlocks_FindPavementTopBlock
 * 0x466910, the ambient spawner's test) and cross only from a curb next to road
 * (Ped_StartCrossingRoadIfAtCurb 0x43B7C0); peds with an objective get on-demand tile
 * paths from PedPathfinder 0x66A7E4 (those are "Ped paths"). So this draws the walkable
 * pavement tiles, filled green, with their border to non-pavement outlined.
 *
 * Map access is the game's own layout (MapBlocks_GetBlock 0x42A850): grid =
 * g_MapBlocks 0x662C08 ->grid; column = columns + base[y*256 + x] words (byte height, byte
 * offset, then u32 block ids for z = offset..height-1); blocks[id]. Only tiles inside the
 * player camera's world rect (cameraBoundaries) plus one around are scanned, and only
 * junctions, segments, links and lights overlapping it are projected; a junction's screen
 * point is computed once per frame (jstamp). Map and graph are read live rather than
 * cached: a column walk is a few loads, and live reads stay right after SWITCH_ROAD or
 * CHANGE_BLOCK.
 *
 * Test build: C32FLAGS_EXTRA='-DDR_TEST=F -DDR_TX=X -DDR_TY=Y' moves the player to tile
 * (X, Y) at frame F (Ped_Teleport 0x435C80, Ghidra; seuko-mod TeleportPed).
 */
#include "overlay.h"

#define G_MAPBLOCKS 0x662C08            /* MapBlocks* */
#define G_ROADNET   0x5D351C            /* RoadNetwork* */
#define G_TLIGHTS   0x6721CC            /* TrafficLights* */
#define G_CARPOOL   0x5E4CA0            /* CarPool* */
#define RN_MAXJ     545
#define MAXCARS     400
#define DR_LABEL_TILE 24                /* label junctions once a tile is this many units */

#define DR_ROADS 1                      /* the mode bits */
#define DR_PEDS  2

#define PAVE      0x4020C040u           /* pavement fill */
#define PAVE_EDGE 0xFF40FF60u
#define ARROW     0xD0FFFFFFu
#define SEG       0xA0909090u
#define JUNC      0xFFFFD020u
#define LINK_OPEN 0xFF40A0FFu
#define LINK_SHUT 0xFFFF3030u
#define LAMP_RIM  0xFF000000u

C32_OFFSET(MapBlocks, grid, 0x0);
C32_OFFSET(MapGrid, columns, 0x40008);
C32_OFFSET(MapGrid, blocks, 0x4000C);
C32_OFFSET(BlockInfo, arrows, 0xA);
C32_OFFSET(BlockInfo, slopeType, 0xB);
C32_ASSERT(sizeof(BlockInfo) == 12);
C32_OFFSET(Camera, cameraBoundaries, 0x20);
C32_OFFSET(RoadNetwork, junctions, 0x8);
C32_OFFSET(RoadNetwork, routes, 0x2218);
C32_OFFSET(RoadNetwork, hSegments, 0xA830);
C32_OFFSET(RoadNetwork, vSegments, 0xB938);
C32_OFFSET(RoadNetwork, hSegCount, 0xCC62);
C32_OFFSET(RoadNetwork, vSegCount, 0xCC64);
C32_OFFSET(RoadJunction, minX, 0xC);
C32_OFFSET(RoadSegment, minX, 0x4);
C32_OFFSET(TrafficLights, junctionCount, 0x190);
C32_OFFSET(TrafficLights, phase, 0x192);
C32_OFFSET(TrafficJunction, glowN, 0x10);
C32_OFFSET(Light, x, 0x4);
C32_OFFSET(Light, colour, 0x10);
C32_OFFSET(CarPool, usedHead, 0x4);
C32_OFFSET(Car, next, 0x4C);
C32_OFFSET(Car, body, 0x50);
C32_OFFSET(Car, ai, 0x5C);
C32_OFFSET(Car, id, 0x6C);
C32_OFFSET(CarAI, routeSlot, 0x28);
C32_OFFSET(CarAI, routeStep, 0x56);
C32_OFFSET(Sprite, x, 0x14);

#ifdef DR_TEST
GAME_FN(void, G2_FASTCALL, Ped_Teleport, 0x435C80, (Ped *ped, int edx, SCR_f x, SCR_f y));
#endif

/* what the host's "roads:" line prints, every DR_STATS_FRAMES while on */
struct dr_stats {
    int32_t x0, x1, y0, y1;             /* the view, tiles, inclusive */
    uint32_t tileu;                     /* a tile in 640x480 units */
    uint32_t pave, arrow, junc, link, light, route, phase;
};
struct dr_stats dr_stats;
C32_EXPORT(dr_stats);

static int32_t tilepx, lw;              /* a tile, a line's width: pixels */
static uint32_t stamp;                  /* this frame, for the junction memo */
static uint32_t jstamp[RN_MAXJ];
static struct ov_pt jpt[RN_MAXJ];

static int32_t clamp_tile(int32_t v)
{
    return v < 0 ? 0 : v > 255 ? 255 : v;
}

/* the topmost block of the column that is not air (ground type != 0), *z = the z its top
 * surface is at; 0 if none */
static BlockInfo *top_block(int32_t x, int32_t y, int32_t *z)
{
    MapBlocks *mb = *(MapBlocks **)G_MAPBLOCKS;
    if (!mb || !mb->grid)
        return 0;
    MapGrid *g = mb->grid;
    const uint8_t *col = (const uint8_t *)(g->columns + g->base[y * 256 + x]);
    int32_t height = col[0], offset = col[1];
    for (int32_t h = height - 1; h >= offset; h--) {
        BlockInfo *b = &g->blocks[((const uint32_t *)col)[h - offset + 1]];
        if (b->slopeType & 3) {
            *z = h + 1;
            return b;
        }
    }
    return 0;
}

/* the ground type of the column's top block, 0 if none or off the map */
static int ground(int32_t x, int32_t y)
{
    int32_t z;
    if ((uint32_t)x > 255 || (uint32_t)y > 255)
        return 0;
    BlockInfo *b = top_block(x, y, &z);
    return b ? b->slopeType & 3 : 0;
}

static int rect_visible(int32_t min_x, int32_t min_y, int32_t max_x, int32_t max_y)
{
    return max_x >= dr_stats.x0 && min_x <= dr_stats.x1 && max_y >= dr_stats.y0 &&
           min_y <= dr_stats.y1;
}

/* a 1-line-wide frame inside the pixel rect a..b */
static void frame_box(struct ov_pt a, struct ov_pt b, uint32_t argb)
{
    ov_box(a.x, a.y, a.x + lw, b.y, argb);      /* left */
    ov_box(b.x - lw, a.y, b.x, b.y, argb);      /* right */
    ov_box(a.x, a.y, b.x, a.y + lw, argb);      /* top */
    ov_box(a.x, b.y - lw, b.x, b.y, argb);      /* bottom */
}

/* ---- peds: pavement tiles, filled, with their border to anything else */
static void pavement(void)
{
    for (int32_t y = dr_stats.y0; y <= dr_stats.y1; y++)
        for (int32_t x = dr_stats.x0; x <= dr_stats.x1; x++) {
            int32_t z;
            BlockInfo *b = top_block(x, y, &z);
            if (!b || (b->slopeType & 3) != 2)
                continue;
            dr_stats.pave++;
            struct ov_pt p1 = ov_project(x << 14, y << 14, z << 14);
            struct ov_pt p2 = ov_project((x + 1) << 14, (y + 1) << 14, z << 14);
            ov_box(p1.x, p1.y, p2.x, p2.y, PAVE);
            if (ground(x - 1, y) != 2)
                ov_box(p1.x, p1.y, p1.x + lw, p2.y, PAVE_EDGE);
            if (ground(x + 1, y) != 2)
                ov_box(p2.x - lw, p1.y, p2.x, p2.y, PAVE_EDGE);
            if (ground(x, y - 1) != 2)
                ov_box(p1.x, p1.y, p2.x, p1.y + lw, PAVE_EDGE);
            if (ground(x, y + 1) != 2)
                ov_box(p1.x, p2.y - lw, p2.x, p2.y, PAVE_EDGE);
        }
}

/* ---- cars: the green arrows of every road tile on screen */
static void arrows(void)
{
    /* arrow bits 1 left, 2 right, 4 up, 8 down as (dx, dy) tiles */
    static const int8_t dirs[4][2] = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } };
    for (int32_t y = dr_stats.y0; y <= dr_stats.y1; y++)
        for (int32_t x = dr_stats.x0; x <= dr_stats.x1; x++) {
            int32_t z;
            BlockInfo *b = top_block(x, y, &z);
            if (!b || (b->slopeType & 3) != 1 || !(b->arrows & 0x0F))
                continue;
            dr_stats.arrow++;
            int32_t wx = x << 14 | 0x2000, wy = y << 14 | 0x2000;
            struct ov_pt c = ov_project(wx, wy, z << 14);
            for (int bit = 0; bit < 4; bit++) {
                if (!(b->arrows >> bit & 1))
                    continue;
                /* head 0.3125 tile on, tail half that back; axis-aligned, so one solid
                 * box from tail to head */
                struct ov_pt h = ov_project(wx + dirs[bit][0] * 0x1400,
                                            wy + dirs[bit][1] * 0x1400, z << 14);
                int32_t tx = ((c.x - h.x) >> 1) + c.x, ty = ((c.y - h.y) >> 1) + c.y;
                int32_t x1 = tx < h.x ? tx : h.x, x2 = tx < h.x ? h.x : tx;
                int32_t y1 = ty < h.y ? ty : h.y, y2 = ty < h.y ? h.y : ty;
                ov_box(x1 - lw, y1 - lw, x2 + lw, y2 + lw, ARROW);
                ov_mark(h, 2, ARROW);
            }
        }
}

/* the tiles' rectangle outlined at the height of the road under its centre */
static void outline(const uint8_t *rect, uint32_t argb)  /* minX, minY, maxX, maxY */
{
    int32_t z = 2;
    top_block((rect[0] + rect[2]) >> 1, (rect[1] + rect[3]) >> 1, &z);
    struct ov_pt a = ov_project(rect[0] << 14, rect[1] << 14, z << 14);
    struct ov_pt b = ov_project((rect[2] + 1) << 14, (rect[3] + 1) << 14, z << 14);
    frame_box(a, b, argb);
}

/* ---- cars: h and v segments */
static void segments(RoadNetwork *rn)
{
    for (int v = 0; v < 2; v++) {
        RoadSegment *s = v ? rn->vSegments : rn->hSegments;
        int n = v ? rn->vSegCount : rn->hSegCount;
        if (n > RN_MAXJ)
            n = RN_MAXJ;
        for (; n > 0; n--, s++)
            if (rect_visible(s->minX, s->minY, s->maxX, s->maxY))
                outline(&s->minX, SEG);
    }
}

/* a used junction, 0 if out of range / unused */
static RoadJunction *junc(uint32_t id)
{
    RoadNetwork *rn = *(RoadNetwork **)G_ROADNET;
    if (!id || id >= RN_MAXJ || !rn)
        return 0;
    RoadJunction *j = &rn->junctions[id];
    return j->minX ? j : 0;
}

/* its centre on screen (memo per frame); 0 when the id is no junction */
static int jproj(uint32_t id, struct ov_pt *out)
{
    RoadJunction *j = junc(id);
    if (!j)
        return 0;
    if (jstamp[id] != stamp) {
        jstamp[id] = stamp;
        int32_t z = 2;
        top_block((j->minX + j->maxX) >> 1, (j->minY + j->maxY) >> 1, &z);
        /* (min + max + 1) / 2 tiles */
        jpt[id] = ov_project((j->minX + j->maxX + 1) << 13, (j->minY + j->maxY + 1) << 13,
                             z << 14);
    }
    *out = jpt[id];
    return 1;
}

static int32_t iabs(int32_t v)
{
    return v < 0 ? -v : v;
}

static void link(uint32_t id, RoadJunction *j, uint16_t l)
{
    uint32_t to_id = l & 0x1FF;
    RoadJunction *t = junc(to_id);
    if (!to_id || !t)
        return;
    /* the box over both junctions must meet the view */
    if (!rect_visible(j->minX < t->minX ? j->minX : t->minX,
                      j->minY < t->minY ? j->minY : t->minY,
                      j->maxX > t->maxX ? j->maxX : t->maxX,
                      j->maxY > t->maxY ? j->maxY : t->maxY))
        return;
    dr_stats.link++;
    struct ov_pt a, b;
    jproj(id, &a);
    jproj(to_id, &b);
    /* a quarter tile to the right of travel: screen (dx, dy) -> (-sgn dy, sgn dx) */
    int32_t off = tilepx >> 2;
    int32_t ox = b.y - a.y > 0 ? -off : b.y - a.y < 0 ? off : 0;
    int32_t oy = b.x - a.x > 0 ? off : b.x - a.x < 0 ? -off : 0;
    a.x += ox, b.x += ox, a.y += oy, b.y += oy;
    uint32_t col = l & 0x8000 ? LINK_OPEN : LINK_SHUT;
    ov_line(a, b, col);
    /* the head: 1.5 tiles before the target, or 80% along a short link */
    int32_t dx = b.x - a.x, dy = b.y - a.y;
    int32_t len = iabs(dy) < iabs(dx) ? iabs(dx) : iabs(dy);
    struct ov_pt h;
    if (len <= 2 * tilepx) {
        h.x = dx * 4 / 5 + a.x;
        h.y = dy * 4 / 5 + a.y;
    } else {
        int32_t back = (tilepx * 3) >> 1;
        h.x = b.x - dx * back / len;
        h.y = b.y - dy * back / len;
    }
    ov_mark(h, 2, col);
}

/* ---- cars: junctions, their links, their ids */
static void junctions(void)
{
    for (uint32_t id = 1; id < RN_MAXJ; id++) {
        RoadJunction *j = junc(id);
        if (!j)
            return;                     /* minX == 0: past the last one */
        link(id, j, j->linkN);
        link(id, j, j->linkS);
        link(id, j, j->linkE);
        link(id, j, j->linkW);
        if (!rect_visible(j->minX, j->minY, j->maxX, j->maxY))
            continue;
        dr_stats.junc++;
        outline(&j->minX, JUNC);
        if (dr_stats.tileu >= DR_LABEL_TILE) {  /* ids only when zoomed in to read them */
            struct ov_pt p;
            jproj(id, &p);
            ov_label(p, id, JUNC);
        }
    }
}

/* ---- cars: every traffic light glow, in its own colour */
static void lights(void)
{
    TrafficLights *tl = *(TrafficLights **)G_TLIGHTS;
    if (!tl)
        return;
    int n = tl->junctionCount > 100 ? 100 : tl->junctionCount;
    while (--n >= 0) {
        TrafficJunction *tj = tl->junctions[n];
        if (!tj)
            continue;
        Light *glow[4] = { tj->glowN, tj->glowS, tj->glowW, tj->glowE };
        for (int i = 0; i < 4; i++) {
            Light *li = glow[i];
            if (!li || li->x >> 14 < dr_stats.x0 || li->x >> 14 > dr_stats.x1 ||
                li->y >> 14 < dr_stats.y0 || li->y >> 14 > dr_stats.y1)
                continue;
            dr_stats.light++;
            struct ov_pt p = ov_project(li->x, li->y, li->z);
            ov_mark(p, 6, LAMP_RIM);
            ov_mark(p, 5, (li->colour & 0xFFFFFF) | 0xFF000000u);
        }
    }
}

/* ---- cars: drive-order routes */
static void routes(void)
{
    RoadNetwork *rn = *(RoadNetwork **)G_ROADNET;
    CarPool *pool = *(CarPool **)G_CARPOOL;
    if (!rn || !pool)
        return;
    int left = MAXCARS;
    for (Car *car = pool->usedHead; car && left--; car = car->next) {
        CarAI *ai = car->ai;
        if (!ai || ai->routeSlot < 1 || ai->routeSlot >= 50 || !car->body)
            continue;
        int slot = ai->routeSlot;
        uint32_t step = ai->routeStep;
        dr_stats.route++;
        Sprite *s = car->body;
        struct ov_pt self = ov_project(s->x, s->y, s->z), prev = self, p;
        uint32_t col = ov_hue(car->id);
        for (uint32_t label = 1; step < 256; label++, step++) {
            uint16_t jid = rn->routes[slot * 256 + step];
            if (!jid || !jproj(jid, &p))
                break;
            ov_line(prev, p, col);
            prev = p;
            ov_mark(p, 2, col);
            if (label <= 9)             /* the first few steps numbered */
                ov_label(p, label, col);
        }
        ov_mark(self, 3, col);
    }
}

/* the overlay, one frame, mode = DR_ROADS | DR_PEDS; 0 when there is nothing to draw for */
uint32_t G2_STDCALL dr_draw(uint32_t mode, uint32_t frame)
{
    (void)frame;
    if (!ov_setup())
        return 0;
#ifdef DR_TEST
    /* test only: the player to tile (DR_TX, DR_TY), so a junction with lights can be shot
     * without walking there */
    if (frame == DR_TEST && ov_player()->ped)
        Ped_Teleport(ov_player()->ped, 0, DR_TX << 14 | 0x2000, DR_TY << 14 | 0x2000);
#endif
    stamp++;
    WorldRect *v = &ov_cam->cameraBoundaries;   /* the view in tiles, one around */
    dr_stats = (struct dr_stats){
        .x0 = clamp_tile((v->left >> 14) - 1), .x1 = clamp_tile((v->right >> 14) + 1),
        .y0 = clamp_tile((v->top >> 14) - 1), .y1 = clamp_tile((v->bottom >> 14) + 1),
    };
    /* a tile's width on screen, at the view centre, z 2 */
    int32_t cx = (dr_stats.x0 + dr_stats.x1) << 13, cy = (dr_stats.y0 + dr_stats.y1) << 13;
    struct ov_pt a = ov_project(cx, cy, 0x8000);
    tilepx = ov_project(cx + 0x4000, cy, 0x8000).x - a.x;
    if (tilepx <= 0)
        tilepx = 1;
    if (!ov_scale)
        return 0;
    dr_stats.tileu = ((uint32_t)tilepx << 14) / (uint32_t)ov_scale;
    lw = (int32_t)((uint32_t)ov_scale >> 15);   /* half a unit, at least 1 px */
    if (!lw)
        lw = 1;
    if (mode & DR_PEDS)
        pavement();
    if (mode & DR_ROADS) {
        RoadNetwork *rn = *(RoadNetwork **)G_ROADNET;
        arrows();
        if (rn)
            segments(rn);
        junctions();
        lights();
        routes();
    }
    TrafficLights *tl = *(TrafficLights **)G_TLIGHTS;
    dr_stats.phase = tl ? tl->phase : 0;
    return 1;
}
C32_EXPORT(dr_draw);
