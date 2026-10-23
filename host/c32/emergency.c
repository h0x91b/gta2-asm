/* emergency.c — "Call ambulance" and "Call fire truck" on the K menu's Player page (the
 * rows are host C: host/c/menu/emergency.c). Neither spawns a vehicle itself: each hands the
 * game the trigger its own emergency services react to, so the dispatch, the vehicle, the
 * siren, the crew and its AI are all the game's (docs/re/gangs-and-peds.md section 7,
 * verified in Ghidra):
 *
 * - Ambulance. The only trigger is a corpse in g_AmbulanceManager's queue. The nearest
 *   body within DE_RANGE (on foot, with a game object, no group, not player / special AI /
 *   mission class, not queued yet: objective not 28 or 50) gets Ped_SetObjective(28),
 *   whose case 28 is AmbulanceManager_EnqueuePed. With no body, the nearest such live ped
 *   is killed with Ped_OnDeath, as the mission opcode KILL_CHAR does (0x47E130); its own
 *   death path sets objective 28 (0x441306). Nobody is picked without a road tile near
 *   them (road_near_ped), and a body the game drops is queued again (amb_requeue).
 *   AmbulanceManager_DispatchForQueuedPed 0x473E00 then takes a road tile near the body,
 *   waits 300 ticks and the MEDICAR comes; the paramedics revive the ped.
 * - Fire truck. Car_RequestFireTruckAndSpawnFlames 0x41F9F0 (fastcall ecx = car, no stack
 *   args; the wreck path Car_BecomeWreck calls it) asks FireEngineManager for a truck and,
 *   if a slot was granted, attaches a fire object to the car. That flame is what
 *   FireEngineSlot_UpdateWatchdog 0x450CD0 checks while the crew hoses. The target stands
 *   in for the native wreck: a driverless car in the middle of a lane (not on a junction,
 *   lane_tile) within DE_FIRE_RANGE, nearest first, until the game grants a truck for one;
 *   else a car of the Vehicle page's model is put mid-lane on the nearest lane
 *   (spawn_on_road). The game refuses a car without a road tile at least 2 lanes wide near
 *   it (FireEngineManager_AllocRequest 0x451300) or with both truck slots busy.
 *
 * Known limit, found in the Seq 43 bug hunt (2026-10-22): the game's own FollowRoute never
 * steers a service car into the target's lane nor arrives (z gate at 0x430444, see
 * hk_follow_route below), so without the hook the vehicle drives past the target one lane
 * over. hk_follow_route makes the two services arrive after a call; the cause is in the
 * game's code (docs/re/cars-and-car-ai.md section 6).
 *
 * Both honour the game's own switches g_skipAmbulance 0x5EAD6B / g_skipFireEngines
 * 0x5EAD8B. Every build logs an "emerg:" line per call and per slot state change; a
 * C32FLAGS_EXTRA=-DDE_TRACE build also prints the slot states every DE_LOG_EVERY frames for
 * DE_LOG_FRAMES frames after a call (player, slots, the vehicles' routes).
 *
 * Addresses: re/functions.csv, re/globals.csv and own decompiler reading in
 * gta-2-recovered (2026-10-21); conventions checked in the disassembly (ret sizes).
 * Ped_SetObjective 0x43BBC0 thiscall(Ped*; objective, timer), ret 8, also in
 * gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 * src/game/functions.h @25b1985. Struct offsets: re/gta2_types.h.
 */
#include "c32.h"

C32_OFFSET(Game, currentPlayer, 0x38);
C32_OFFSET(Player, ped, 0x2C4);
C32_OFFSET(Ped, nextPed, 0x160);
C32_OFFSET(Ped, group, 0x164);
C32_OFFSET(Ped, gameObject, 0x168);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(Ped, position, 0x1AC);
C32_OFFSET(Ped, health, 0x216);
C32_OFFSET(Ped, lifeState, 0x234);
C32_OFFSET(Ped, pedClass, 0x238);
C32_OFFSET(Ped, objective, 0x258);
C32_OFFSET(Ped, state, 0x278);
C32_OFFSET(PedManager_S25, activeListHead, 0x4);
C32_OFFSET(Car, next, 0x4C);
C32_OFFSET(Car, body, 0x50);
C32_OFFSET(Car, driver, 0x54);
C32_OFFSET(Car, ai, 0x5C);
C32_OFFSET(Car, driveOrder, 0x60);
C32_OFFSET(Car, id, 0x6C);
C32_OFFSET(Car, lifeState, 0x88);
C32_OFFSET(CarPool, usedHead, 0x4);
C32_OFFSET(CarAI, parentCar, 0x0);
C32_OFFSET(CarAI, flags, 0x24);
C32_OFFSET(CarAI, routeSlot, 0x28);
C32_OFFSET(CarAI, routeStep, 0x56);
C32_OFFSET(CarDriveOrder, mode, 0x8);
C32_OFFSET(CarDriveOrder, targetX, 0x14);
C32_OFFSET(CarDriveOrder, targetZ, 0x1C);
C32_OFFSET(CarDriveOrder, isUrgent, 0x20);
C32_OFFSET(CarDriveOrder, followRoadActive, 0x22);
C32_OFFSET(CarDriveOrder, arrived, 0x26);
C32_OFFSET(Sprite, x, 0x14);
C32_OFFSET(Sprite, z, 0x1C);
C32_OFFSET(AmbulanceManager, pendingCount, 0x1);
C32_OFFSET(AmbulanceManager, slots, 0xD0);
C32_OFFSET(AmbulanceSlot, vehicle, 0x4);
C32_OFFSET(AmbulanceSlot, state, 0x18);
C32_OFFSET(EmergencyVehicleSlot, car, 0x0);
C32_OFFSET(EmergencyVehicleSlot, inUse, 0x1E);
C32_OFFSET(EmergencyVehicleSlot, stage, 0x28);
C32_OFFSET(FireEngineSlot, active, 0x4);
C32_OFFSET(FireEngineSlot, state, 0x8);
C32_OFFSET(FireEngineSlot, targetCar, 0xC);
C32_OFFSET(FireEngineSlot, truck, 0x1C);
C32_OFFSET(FireEngineSlot, timer, 0x24);
C32_OFFSET(BlockInfo, arrows, 0xA);
C32_OFFSET(RoadNetwork, junctionCount, 0x4);
C32_OFFSET(RoadNetwork, junctions, 0x8);
C32_OFFSET(RoadNetwork, routes, 0x2218);
C32_OFFSET(RoadJunction, minX, 0xC);
C32_ASSERT(sizeof(AmbulanceSlot) == 0x20 && sizeof(FireEngineSlot) == 0x28);
C32_ASSERT(sizeof(RoadJunction) == 0x10 && sizeof(EmergencyVehicleSlot) == 0x30);

#define DE_RANGE        (10 << 14)      /* bodies / peds, Chebyshev, 10 blocks (SCR_f) */
#define DE_FIRE_RANGE   (16 << 14)      /* cars tried for a fire truck, Chebyshev */
#define DE_ROAD_RINGS   16
#define DE_TRIES        8
#define DE_AMB_RETRIES  30
#define DE_MAXPEDS      400             /* the pool has 200; a broken list cannot hang us */
#define DE_MAXCARS      1000
#define DE_LOG_FRAMES   1800
#define DE_LOG_EVERY    20

#define OBJ_AMBULANCE   28              /* PED_OBJECTIVE_UNKNOWN_28: queue for an ambulance */
#define OBJ_REMOVE      50              /* PED_OBJECTIVE_UNKNOWN_50: body removed, no ambulance */
#define PED_ALIVE       99              /* Ped.lifeState */
#define CLASS_PLAYER    2               /* PED_CLASS_PLAYER */
#define CLASS_SPECIAL   4               /* PED_CLASS_UNSURE_SPECIAL_AI: emergency crews, cops */
#define CLASS_MISSION   5               /* PED_CLASS_UNSURE_MISSION */

#define G_GAME          0x5EB4FC        /* Game* */
#define G_PEDMGR        0x5E5BBC        /* PedManager_S25* */
#define G_CARPOOL       0x5E4CA0        /* CarPool* */
#define G_TRAFFIC       0x5E4CA4        /* TrafficManager*, SpawnCar's ecx */
#define G_CARSCALE      0x5E4D4C
#define G_ROADNET       0x5D351C        /* RoadNetwork* */
#define G_PATHFINDER    0x66A7E4        /* PedPathfinder* */
#define G_MAPBLOCKS     0x662C08        /* MapBlocks* */
#define G_AMBULANCE     0x663DE4        /* AmbulanceManager* */
#define G_FIREENGINE    0x5EA9CC        /* FireEngineManager* */
#define G_SKIP_AMB      0x5EAD6B        /* g_skipAmbulance */
#define G_SKIP_FIRE     0x5EAD8B        /* g_skipFireEngines */
#define G_EMERGPOOL     0x672B90        /* EmergencyVehiclePool*: 10 slots x 0x30 (DE_TRACE) */

#define GLOBAL(type, va) (*(type *volatile *)(va))

GAME_FN(void, G2_THISCALL, Ped_SetObjective, 0x43BBC0, (Ped *self, int objective, int timer));
GAME_FN(void, G2_FASTCALL, Ped_OnDeath, 0x4411B0, (Ped *self));
/* unsure_Map_FindSpawnRoadTile: kind 1 = road, wide 0 = at most 6 rings; al = 1 found */
GAME_FN(uint32_t, G2_THISCALL, PedPathfinder_FindSpawnTile, 0x49D7A0,
        (void *self, int kind, uint8_t *x, uint8_t *y, uint8_t *z, int wide));
GAME_FN(void, G2_FASTCALL, Car_RequestFireTruckAndSpawnFlames, 0x41F9F0, (Car *self));
GAME_FN(BlockInfo *, G2_THISCALL, MapBlocks_GetBlock, 0x4653C0, (void *self, int x, int y, int z));
/* fastcall(TrafficManager* ecx, edx = 0; SCR_f x, y, z, rotation, CAR_MODEL4, scale) -> Car*,
 * ret 0x18 (as host/c/menu/helpers.c km_spawn_car) */
GAME_FN(Car *, G2_FASTCALL, SpawnCar, 0x426AC0,
        (void *tm, int zero, int x, int y, int z, int rot, int model, int scale));

typedef void (G2_FASTCALL *follow_route_fn)(CarAI *self);
static follow_route_fn CarAI_FollowRoute;   /* 0x430320, or a hook chained before ours */

/* the car spawn_on_road put on the road this frame, or 0: the host makes it the K menu's
 * "last car" (host/c/menu/emergency.c) */
Car *de_spawned;
C32_EXPORT(de_spawned);

static uint8_t de_assist;               /* from the first call on, hk_follow_route helps */
static Ped *amb_ped;                    /* the body queued last */
static int amb_retry;
static int prev_state[4] = { 0, 0, -1, -1 };    /* fire slot states, ambulance stages */
static Car *tried[DE_TRIES];
static int ntried;
static uint32_t frame;                  /* the host's presented-frame counter */
#ifdef DE_TRACE
static int log_left;
#endif

static Ped *player_ped(void)
{
    Game *g = GLOBAL(Game, G_GAME);
    Player *pl = g ? g->currentPlayer : 0;
    return pl ? pl->ped : 0;
}

static int iabs(int v) { return v < 0 ? -v : v; }

static int dist(int x1, int y1, int x2, int y2)
{
    int dx = iabs(x1 - x2), dy = iabs(y1 - y2);
    return dx > dy ? dx : dy;
}

static AmbulanceSlot *amb_slot(AmbulanceManager *am, int i) { return &am->slots[i]; }

/* the vehicle of an active AmbulanceSlot or the truck of an active FireEngineSlot */
static int is_service_car(Car *car)
{
    if (!car)
        return 0;
    AmbulanceManager *am = GLOBAL(AmbulanceManager, G_AMBULANCE);
    if (am)
        for (int i = 0; i < 2; i++) {
            AmbulanceSlot *s = amb_slot(am, i);
            if (s->state && s->vehicle && s->vehicle->car == car)
                return 1;
        }
    FireEngineManager *fm = GLOBAL(FireEngineManager, G_FIREENGINE);
    if (fm)
        for (int i = 0; i < 2; i++)
            if (fm->slots[i].active && fm->slots[i].truck == car)
                return 1;
    return 0;
}

/* Call hook at 0x432678, the `call CarAI_FollowRoute` (fastcall ecx = CarAI*) in
 * CarAI_Update. Why (measured, Seq 43 bug hunt, docs/re/cars-and-car-ai.md): FollowRoute
 * only steers into the target's lane and only arrives by "passed the target along the
 * segment" when floor(car z - 1.0) == floor(order z) (0x430437..0x430444), but every drive
 * order the game gives its services carries the SPRITE z of the ground (2.0: FindSpawnRoadTile
 * node z for the ambulance, the wreck's z for the fire truck, script goto_area_in_car
 * z=2.0), while a car on flat ground has z 2.0 too, so floor(z - 1) = 1 != 2 and the
 * services drive past a target one lane over forever. For the car an AmbulanceManager /
 * FireEngineManager slot holds, after a K-menu call, the order's z is set to car z - 1.0 for
 * the length of the call only (CarAI_UpdateDriveOrder 0x42D390 plans with the sprite z, so
 * the order must keep it between calls). */
static void G2_FASTCALL hk_follow_route(CarAI *ai)
{
    CarDriveOrder *order = 0;
    int z = 0;
    Car *car = ai->parentCar;
    if (de_assist && is_service_car(car) && car->driveOrder) {
        order = car->driveOrder;
        z = order->targetZ;
        order->targetZ = car->body->z - 0x4000;
    }
    CarAI_FollowRoute(ai);
    if (order && car->driveOrder == order)
        order->targetZ = z;
}

/* an "emerg:" line whenever a FireEngineSlot state or an ambulance's EmergencyVehicleSlot
 * stage changes (always on: a few lines per call) */
static void log_changes(Car *last_car)
{
    FireEngineManager *fm = GLOBAL(FireEngineManager, G_FIREENGINE);
    if (fm)
        for (int i = 0; i < 2; i++) {
            FireEngineSlot *s = &fm->slots[i];
            int st = s->active ? s->state : 0;
            if (prev_state[i] == st)
                continue;
            int was = prev_state[i];
            prev_state[i] = st;
            int tx = s->truck && s->truck->body ? s->truck->body->x >> 14 : -1;
            c32_log("emerg: f%u fire slot%d state %d (was %d), truck x %d, spawned car life %d",
                    frame, i, st, was, tx, last_car ? (int)last_car->lifeState : -1);
        }
    AmbulanceManager *am = GLOBAL(AmbulanceManager, G_AMBULANCE);
    if (am)
        for (int i = 0; i < 2; i++) {
            AmbulanceSlot *s = amb_slot(am, i);
            int st = s->state && s->vehicle ? s->vehicle->stage : -1;
            if (prev_state[2 + i] == st)
                continue;
            int was = prev_state[2 + i];
            prev_state[2 + i] = st;
            c32_log("emerg: f%u ambulance slot%d stage %d (was %d)", frame, i, st, was);
        }
}

/* For DE_AMB_RETRIES frames after a call, queue the body again when the game has dropped
 * it. AmbulanceManager_DispatchForQueuedPed pops the body and gives up without a road
 * tile, and its unsure_Map_FindSpawnRoadTile refuses outright while PedPathfinder +0x38 is
 * set, which flips every frame (measured: 1, 0, 1, ...). The give-up sets objective 50,
 * which Ped_SetObjective ignores on a dead ped, so the body just lies there with objective
 * 28 and no ambulance (measured, 2026-10-21). Dropped = queue empty and no AmbulanceSlot
 * active; done as soon as one is. */
static void amb_requeue(void)
{
    if (!amb_retry)
        return;
    amb_retry--;
    AmbulanceManager *am = GLOBAL(AmbulanceManager, G_AMBULANCE);
    if (!amb_ped || amb_ped->state != PED_STATE_WASTED || !am || am->slots[0].state ||
        am->slots[1].state) {
        amb_retry = 0;
        return;
    }
    if (am->pendingCount)
        return;                         /* still queued: the game has not looked yet */
    Ped_SetObjective(amb_ped, OBJ_AMBULANCE, 9999);
    c32_log("emerg: f%u body dropped by the game, queued again", frame);
}

/* 1 if the game would find a road tile for an ambulance next to this ped: the search
 * AmbulanceManager_DispatchForQueuedPed makes for the body. Without one the game drops the
 * body (objective 50) and no ambulance comes (measured on the Downtown start square), so
 * nobody is killed for that. */
static int road_near_ped(Ped *ped)
{
    void *pf = GLOBAL(void, G_PATHFINDER);
    if (!pf)
        return 0;
    uint8_t x = (uint8_t)(ped->position.x >> 14), y = (uint8_t)(ped->position.y >> 14);
    uint8_t z = (uint8_t)((ped->position.z + 0x2000) >> 14);
    return (PedPathfinder_FindSpawnTile(pf, 1, &x, &y, &z, 0) & 0xFF) == 1;
}

static const char *call_ambulance(void)
{
    Ped *me = player_ped();
    if (!me)
        return "No player";
    if (*(volatile uint8_t *)G_SKIP_AMB)
        return "Ambulances are off";
    int best_live_d = DE_RANGE + 1, best_body_d = DE_RANGE + 1;
    Ped *best_live = 0, *best_body = 0;
    PedManager_S25 *pm = GLOBAL(PedManager_S25, G_PEDMGR);
    int n = DE_MAXPEDS;
    for (Ped *p = pm ? pm->activeListHead : 0; p && n-- > 0; p = p->nextPed) {
        if (p == me || !p->gameObject || p->currentCar || p->group)
            continue;
        if (p->pedClass == CLASS_PLAYER || p->pedClass == CLASS_SPECIAL ||
            p->pedClass == CLASS_MISSION)
            continue;
        int d = dist(p->position.x, p->position.y, me->position.x, me->position.y);
        if (p->state == PED_STATE_WASTED) {
            if (p->objective != OBJ_AMBULANCE && p->objective != OBJ_REMOVE && d < best_body_d) {
                best_body_d = d;
                best_body = p;
            }
        } else if (p->lifeState == PED_ALIVE && d < best_live_d) {
            best_live_d = d;
            best_live = p;
        }
    }
    const char *toast;
    Ped *p = best_body;
    if (p) {
        if (!road_near_ped(p))
            return "No road near the ped for an ambulance";
        Ped_SetObjective(p, OBJ_AMBULANCE, 9999);
        toast = "Ambulance called";
    } else {
        p = best_live;
        if (!p)
            return "No ped nearby";
        if (!road_near_ped(p))
            return "No road near the ped for an ambulance";
        Ped_OnDeath(p);
        toast = "Ambulance called (ped killed)";
    }
    if (p->objective != OBJ_AMBULANCE)  /* 28 = AmbulanceManager_EnqueuePed took it */
        toast = "No ambulance: queue full";
    amb_ped = p;
    amb_retry = DE_AMB_RETRIES;
    c32_log("emerg: ambulance for ped %08x objective %d state %d at %d,%d", (uint32_t)p,
            p->objective, p->state, p->position.x >> 14, p->position.y >> 14);
#ifdef DE_TRACE
    log_left = DE_LOG_FRAMES;
#endif
    return toast;
}

/* The arrow bits (1 left, 2 right, 4 up, 8 down: TrafficSpawner_TrySpawnSide 0x4B34E0)
 * when the tile is the middle of a one-way lane, else 0. Middle of a lane = the ground
 * block (z - 1) has exactly one arrow (the test unsure_Map_FindSpawnRoadTile makes), and
 * the tile is outside every RoadJunction rectangle grown by one. Why: a drive order routes
 * to "the junction ahead of the goal tile" (RoadNetwork_FindRoute 0x40E030), so a goal
 * inside a junction makes the truck drive through it and on round the block for ever
 * (measured: route J(142,115) J(142,149) J(122,149) J(122,115) for a car at 122,149, in
 * J(122..123,149..151)), and arrival (CarAI_FollowRoute 0x430320) wants the goal between
 * two junctions of the route. */
static int lane_tile(int x, int y, int z)
{
    BlockInfo *b = MapBlocks_GetBlock(GLOBAL(void, G_MAPBLOCKS), x, y, z - 1);
    if (!b)
        return 0;
    int arrows = b->arrows & 0xF;
    if (!arrows || (arrows & (arrows - 1)))
        return 0;                       /* none, or more than one */
    RoadNetwork *rn = GLOBAL(RoadNetwork, G_ROADNET);
    if (!rn)
        return 0;
    for (int i = 0; i < rn->junctionCount; i++) {
        RoadJunction *j = &rn->junctions[i];
        if (x >= j->minX - 1 && x <= j->maxX + 1 && y >= j->minY - 1 && y <= j->maxY + 1)
            return 0;                   /* inside (or next to) a junction */
    }
    return arrows;
}

/* A car of the Vehicle page's model in the middle of the lane nearest the player
 * (lane_tile, ring by ring up to DE_ROAD_RINGS), or 0: SpawnCar at the tile centre, facing
 * along the arrow (rotation 0 = +y, the K menu's spawn convention). A SpawnCar car has no
 * driver and no category, so it stays where it is and is not recycled (measured: a burning
 * one kept 3000 frames). */
static Car *spawn_on_road(Ped *me, int model)
{
    int px = me->position.x >> 14, py = me->position.y >> 14;
    int pz = (me->position.z + 0x2000) >> 14;
    for (int r = 0; r <= DE_ROAD_RINGS; r++)
        for (int dy = -r; dy <= r; dy++)
            for (int dx = -r; dx <= r; dx++) {
                if ((iabs(dx) > iabs(dy) ? iabs(dx) : iabs(dy)) != r)
                    continue;           /* only the ring's border */
                int arrow = lane_tile(px + dx, py + dy, pz);
                if (!arrow)
                    continue;
                int rot = arrow == 2 ? 360 : arrow == 4 ? 720 : arrow == 1 ? 1080 : 0;
                void *tm = GLOBAL(void, G_TRAFFIC);
                if (!tm)
                    return 0;
                Car *car = SpawnCar(tm, 0, ((px + dx) << 14) + 0x2000, ((py + dy) << 14) + 0x2000,
                                    (me->position.z + 0x2000) & ~0x3FFF, rot, model,
                                    *(volatile int *)G_CARSCALE);
                if (!car)
                    return 0;
                de_spawned = car;
                c32_log("emerg: car put mid-lane, ring %d, at %d,%d", r, car->body->x >> 14,
                        car->body->y >> 14);
                return car;
            }
    return 0;
}

/* 1 + index of the active FireEngineSlot whose targetCar is car, or 0 */
static int fire_slot(Car *car)
{
    FireEngineManager *fm = GLOBAL(FireEngineManager, G_FIREENGINE);
    if (!fm)
        return 0;
    if (fm->slots[0].active && fm->slots[0].targetCar == car)
        return 1;
    if (fm->slots[1].active && fm->slots[1].targetCar == car)
        return 2;
    return 0;
}

static int request_fire(Car *car)
{
    Car_RequestFireTruckAndSpawnFlames(car);
    return fire_slot(car);
}

/* the driverless car nearest the player (Chebyshev, sprite position) within DE_FIRE_RANGE,
 * mid-lane, not the player's own car and not tried yet, or 0 */
static Car *nearest_car(Ped *me)
{
    Car *best = 0;
    int best_d = DE_FIRE_RANGE + 1;
    CarPool *cp = GLOBAL(CarPool, G_CARPOOL);
    int n = DE_MAXCARS;
    for (Car *c = cp ? cp->usedHead : 0; c && n-- > 0; c = c->next) {
        /* a driven car keeps going, the truck never catches it (Car_HaltAIIfHasAI does not
         * hold traffic) */
        if (c == me->currentCar || c->driver || !c->body)
            continue;
        int d = dist(c->body->x, c->body->y, me->position.x, me->position.y);
        if (d >= best_d)
            continue;
        if (!lane_tile(c->body->x >> 14, c->body->y >> 14, (c->body->z + 0x2000) >> 14))
            continue;                   /* a car on a junction never gets its truck */
        int seen = 0;
        for (int i = 0; i < ntried; i++)
            seen |= tried[i] == c;
        if (seen)
            continue;
        best_d = d;
        best = c;
    }
    return best;
}

/* the cars within DE_FIRE_RANGE nearest first, at most DE_TRIES of them, until the game
 * grants a truck for one; with none granted, a car put on the nearest lane */
static const char *call_firetruck(int model)
{
    Ped *me = player_ped();
    if (!me)
        return "No player";
    if (*(volatile uint8_t *)G_SKIP_FIRE)
        return "Fire engines are off";
    FireEngineManager *fm = GLOBAL(FireEngineManager, G_FIREENGINE);
    if (!fm || (fm->slots[0].active & fm->slots[1].active))
        return "Fire truck already coming";
    Car *car = 0;
    int slot = 0;
    ntried = 0;
    while (ntried < DE_TRIES && (car = nearest_car(me)) != 0) {
        tried[ntried++] = car;
        slot = request_fire(car);
        c32_log("emerg: try car id %u at %d,%d,%d -> %d", car->id, car->body->x >> 14,
                car->body->y >> 14, car->body->z >> 14, slot);
        if (slot)
            break;
    }
    if (!slot) {
        car = spawn_on_road(me, model);
        if (!car || !(slot = request_fire(car)))
            return "No fire truck: no road or slot";
    }
    c32_log("emerg: fire truck for car %08x id %u slot %d at %d,%d z %x", (uint32_t)car,
            car->id, slot, car->body->x >> 14, car->body->y >> 14, car->body->z);
#ifdef DE_TRACE
    log_left = DE_LOG_FRAMES;
#endif
    return "Fire truck called";
}

#ifdef DE_TRACE
static int fmt(char *buf, const char *f, ...)
{
    va_list ap;
    va_start(ap, f);
    int n = game_vsprintf(buf, f, ap);
    va_end(ap);
    return n;
}

/* the car's CarAI route (routeSlot, routeStep, the junction rectangles of routes[slot]),
 * its drive order and position */
static void dump_route(Car *car)
{
    if (!car || !car->ai)
        return;
    CarAI *ai = car->ai;
    int slot = ai->routeSlot;
    c32_log("emerg   route slot %d step %u:", slot, ai->routeStep);
    CarDriveOrder *o = car->driveOrder;
    if (o) {
        c32_log("emerg   ai flags %08x order mode %d followRoad %u arrived %u urgent %u",
                ai->flags, (int)o->mode, o->followRoadActive, (unsigned)o->arrived, o->isUrgent);
        c32_log("emerg   order target %x,%x,%x car pos %x,%x,%x", o->targetX, o->targetY,
                o->targetZ, car->body->x, car->body->y, car->body->z);
    }
    RoadNetwork *rn = GLOBAL(RoadNetwork, G_ROADNET);
    if (slot <= 0 || !rn)
        return;
    char line[256];
    char *e = line;
    *e = 0;
    for (int i = 0; i < 12; i++) {
        unsigned j = rn->routes[slot * 0x100 + i];
        if (!j)
            break;
        RoadJunction *jn = &rn->junctions[j];
        e += fmt(e, " (%d,%d-%d,%d)", jn->minX, jn->minY, jn->maxX, jn->maxY);
    }
    c32_log("emerg   route:%s", line);
}

/* while log_left runs, every DE_LOG_EVERY frames: the player, the queued body, the two
 * AmbulanceSlots and the two FireEngineSlots */
static void trace(void)
{
    if (!log_left)
        return;
    log_left--;
    if (log_left < DE_LOG_FRAMES - 40 && log_left % DE_LOG_EVERY)
        return;                         /* every frame right after a call */
    Ped *me = player_ped();
    if (!me)
        return;
    if (amb_ped) {
        int used = 0;
        uint8_t *pool = GLOBAL(uint8_t, G_EMERGPOOL);
        for (int i = 0; pool && i < 10; i++)
            used += pool[i * 0x30 + 0x1E];
        uint8_t *pf = GLOBAL(uint8_t, G_PATHFINDER);
        c32_log("emerg   body objective %d state %d z %x, emergency pool in use %d, "
                "pathfinder busy %d", amb_ped->objective, amb_ped->state, amb_ped->position.z,
                used, pf ? pf[0x38] : -1);
    }
    c32_log("emerg f%u: player %d,%d health %d", frame, me->position.x >> 14,
            me->position.y >> 14, me->health);
    AmbulanceManager *am = GLOBAL(AmbulanceManager, G_AMBULANCE);
    for (int i = 0; am && i < 2; i++) {
        AmbulanceSlot *s = amb_slot(am, i);
        Car *c = s->vehicle ? s->vehicle->car : 0;
        c32_log("emerg   amb slot%d state %d stage %d car %d,%d queue %u", i, s->state,
                s->vehicle ? s->vehicle->stage : -1, c && c->body ? c->body->x >> 14 : -1,
                c && c->body ? c->body->y >> 14 : -1, am->pendingCount);
        dump_route(c);
    }
    FireEngineManager *fm = GLOBAL(FireEngineManager, G_FIREENGINE);
    for (int i = 0; fm && i < 2; i++) {
        FireEngineSlot *s = &fm->slots[i];
        Car *c = s->truck;
        uint32_t rt = 0xFFFFFFFF;       /* routeSlot << 24 | drive order target x << 8 | y */
        if (c && c->ai) {
            rt = (uint32_t)c->ai->routeSlot << 24;
            if (c->driveOrder)
                rt |= (c->driveOrder->targetX >> 14 & 0xFF) << 8 | (c->driveOrder->targetY >> 14 & 0xFF);
        }
        c32_log("emerg   fire slot%d active %d state %d truck %d,%d route|target %08x", i,
                s->active, s->state | s->timer << 16, c && c->body ? c->body->x >> 14 : -1,
                c && c->body ? c->body->y >> 14 : -1, rt);
        dump_route(c);
    }
}
#endif

/* Once per gameplay frame, from the host's DM_FRAME (host/c/menu/emergency.c): req 1 =
 * call an ambulance, 2 = a fire truck (from the K menu rows), model = the Vehicle page's
 * car model, last_car = the K menu's "last car" (for the log). Returns the toast, or 0. */
const char *G2_STDCALL de_frame(uint32_t req, uint32_t now, uint32_t model, Car *last_car)
{
    const char *toast = 0;
    frame = now;
    de_spawned = 0;
    if (req) {
        de_assist = 1;
#ifdef DE_TRACE
        /* CRT static-initialiser constants the route code reads (re/static_constants.csv) */
        c32_log("emerg: consts 5e512c=%x 5e50b8=%x 5e520c=%x 5e5398=%x",
                *(volatile uint32_t *)0x5E512C, *(volatile uint32_t *)0x5E50B8,
                *(volatile uint32_t *)0x5E520C, *(volatile uint32_t *)0x5E5398);
#endif
    }
    if (req == 1)
        toast = call_ambulance();
    else if (req == 2)
        toast = call_firetruck((int)model);
#ifdef DE_TRACE
    Ped *me = player_ped();
    if (req == 1 && me)
        c32_log("emerg: f%u call ambulance: %s (player %d,%d)", frame, toast,
                me->position.x >> 14, me->position.y >> 14);
#endif
    amb_requeue();
#ifdef DE_TRACE
    trace();
#endif
    log_changes(de_spawned ? de_spawned : last_car);
    return toast;
}
C32_EXPORT(de_frame);

static void emergency_init(void)
{
    CarAI_FollowRoute = (follow_route_fn)c32_callhook(0x432678, 0x430320, (void *)hk_follow_route);
}
C32_INIT(emergency_init);
