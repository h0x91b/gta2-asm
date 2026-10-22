/* ctl_game.c — what gta2ctl reads from and does to the game (docs/gta2ctl.md).
 *
 * 64-bit host C, not C32, although it touches game objects every tick: it is the game side
 * of a host feature (the command channel), its state machine lives with the socket in
 * ctl.c, and the only per-tick work is two Player fields written from the existing NASM
 * hook on Player_MoveOnFoot (hk_MoveOnFoot, host/player_move.asm). A C32 half would need a
 * second copy of the command state, shared through exports, for no gain.
 *
 * Game facts (re/gta2_types_c64.h, docs/re/ped-movement-collision.md): positions are SCR_f
 * (Q14, 0x4000 = 1 block); a heading is an Ang16, 1440 per turn, 0 faces +y, x = sin(h),
 * y = cos(h); Player.turnRate (+8) is added to the PedGameObject heading (+0x40) and
 * Player.moveSpeed (+0xC) = +1.0 makes the walker step forward, both every tick.
 * Car pool g_CarPool 0x5E4CA0 (+4 used list, Car.next), ped list PedManager 0x5E5BBC (+4,
 * Ped.nextPed): host/debug_emergency.asm, host/debug_paths.asm. */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "ctl.h"

extern uint8_t have_focus NASM(have_focus);     /* w32_dinput.asm: SDL keyboard focus */

#define G_CAR_POOL  0x5E4CA0
#define G_PED_MGR   0x5E5BBC
#define G_CAR_MGR   0x5E4CA4
#define ANG_TURN    1440
#define MOVE_FWD    0x4000                      /* Player.moveSpeed +1.0 */
#define PED_ALIVE   99                          /* Ped.lifeState */
#define LIST_MAX    5

const struct ctl_field ctl_fields[F_NFIELDS] = {
    [F_FRAME] = { "frame", 'i' },       [F_IN_GAME] = { "in_game", 'b' },
    [F_PAUSED] = { "paused", 'b' },     [F_FOCUS] = { "focus", 'b' },
    [F_X] = { "x", 'f' },               [F_Y] = { "y", 'f' },
    [F_Z] = { "z", 'f' },               [F_HEADING] = { "heading", 'f' },
    [F_HEALTH] = { "health", 'i' },     [F_ARMOUR] = { "armour", 'i' },
    [F_MONEY] = { "money", 'i' },       [F_WANTED] = { "wanted", 'i' },
    [F_WANTED_POINTS] = { "wanted_points", 'i' },
    [F_IN_CAR] = { "in_car", 'b' },     [F_DRIVER] = { "driver", 'b' },
    [F_CAR_ID] = { "car_id", 'i' },     [F_CAR_MODEL] = { "car_model", 'i' },
    [F_SPEED] = { "speed", 'f' },       [F_WEAPON] = { "weapon", 'i' },
    [F_AMMO] = { "ammo", 'i' },         [F_PED_STATE] = { "ped_state", 'i' },
    [F_OBJECTIVE] = { "objective", 'i' }, [F_PED_ID] = { "ped_id", 'i' },     [F_DEAD] = { "dead", 'b' },
};

ctl_steer_t ctl_steer;

int ctl_field_index(const char *name)
{
    for (int i = 0; i < F_NFIELDS; i++)
        if (!strcmp(ctl_fields[i].name, name))
            return i;
    return -1;
}

void jb_printf(jbuf *b, const char *fmt, ...)
{
    va_list ap;
    size_t room = sizeof b->buf - b->len;
    va_start(ap, fmt);
    int n = vsnprintf(b->buf + b->len, room, fmt, ap);
    va_end(ap);
    if (n > 0)
        b->len += (size_t)n < room ? (size_t)n : room - 1;
}

void jb_str(jbuf *b, const char *s)
{
    jb_printf(b, "\"");
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\')
            jb_printf(b, "\\%c", c);
        else if (c < 0x20)
            jb_printf(b, "\\u%04x", c);
        else
            jb_printf(b, "%c", c);
    }
    jb_printf(b, "\"");
}

Ped *ctl_ped(void)
{
    Player *pl = game_player();
    return pl ? GP(Ped, pl->ped) : 0;
}

static Sprite *ped_body(Ped *ped)
{
    PedGameObject *go = ped ? GP(PedGameObject, ped->gameObject) : 0;
    return go ? GP(Sprite, go->body) : 0;
}

/* a ped in a car has no game object and a stale position: the car's (Seq 27) */
static void ped_pos(Ped *ped, int32_t *x, int32_t *y, int32_t *z)
{
    Car *car = GP(Car, ped->currentCar);
    Sprite *s = car ? GP(Sprite, car->body) : ped_body(ped);
    if (s) {
        *x = s->x, *y = s->y, *z = s->z;
    } else {
        *x = ped->position.x, *y = ped->position.y, *z = ped->position.z;
    }
}

int ctl_pos(int32_t *x, int32_t *y, int32_t *z)
{
    Ped *ped = ctl_ped();
    if (!ped)
        return 0;
    ped_pos(ped, x, y, z);
    return 1;
}

int32_t ctl_dist(int32_t ax, int32_t ay, int32_t bx, int32_t by)
{
    return (int32_t)hypot((double)ax - bx, (double)ay - by);
}

static int wanted_level(int points)
{
    static const int stars[] = { 600, 1600, 3000, 5000, 8000, 12000 };   /* dm_cop_values */
    int n = 0;
    while (n < 6 && points >= stars[n])
        n++;
    return n;
}

static double car_speed(Car *car)
{
    CarPhysics *ph = GP(CarPhysics, car->physics);
    return ph ? hypot(ph->linVel.x, ph->linVel.y) / SCR_ONE : 0.0;   /* blocks per tick */
}

static void set(ctl_state *s, int f, double v)
{
    s->v[f] = v;
    s->valid[f] = 1;
}

void ctl_snapshot(ctl_state *s)
{
    memset(s, 0, sizeof *s);
    set(s, F_FRAME, r_frames);
    set(s, F_FOCUS, have_focus != 0);
    Game *g = game();
    Player *pl = game_player();
    Ped *ped = pl ? GP(Ped, pl->ped) : 0;
    set(s, F_IN_GAME, ped != 0);
    if (!ped)
        return;
    set(s, F_PAUSED, g->gameStatus == 2);
    int32_t x, y, z;
    ctl_pos(&x, &y, &z);
    set(s, F_X, scr_to_f(x));
    set(s, F_Y, scr_to_f(y));
    set(s, F_Z, scr_to_f(z));
    Car *car = GP(Car, ped->currentCar);
    Sprite *body = car ? GP(Sprite, car->body) : ped_body(ped);
    set(s, F_HEADING, body ? (uint16_t)body->rotation / 4.0 : ped->rotation / 4.0);
    set(s, F_HEALTH, ped->health);
    set(s, F_ARMOUR, pl->powerups[3]);                  /* POWERUP_TYPE_ARMOR */
    set(s, F_MONEY, pl->score.money.value);
    set(s, F_WANTED_POINTS, ped->wantedPoints);
    set(s, F_WANTED, wanted_level(ped->wantedPoints));
    set(s, F_IN_CAR, car != 0);
    set(s, F_DRIVER, car && car->driver == pl->ped);
    set(s, F_CAR_ID, car ? (double)car->id : -1);
    set(s, F_CAR_MODEL, car ? (double)car->carModel : -1);
    set(s, F_SPEED, car ? car_speed(car) : 0);
    WEAPON_STRUCT *w = GP(WEAPON_STRUCT, car ? ped->carWeapon : ped->selectedWeapon);
    set(s, F_WEAPON, w ? (double)w->id : -1);
    set(s, F_AMMO, w ? w->ammo : 0);
    set(s, F_PED_STATE, ped->state);
    set(s, F_OBJECTIVE, ped->objective);
    set(s, F_PED_ID, ped->id);
    set(s, F_DEAD, pl->isDeadOrBusted != 0);
}

void ctl_fields_json(jbuf *b, const ctl_state *s)
{
    const char *sep = "";
    for (int i = 0; i < F_NFIELDS; i++) {
        if (!s->valid[i])
            continue;
        jb_printf(b, "%s\"%s\":", sep, ctl_fields[i].name);
        sep = ",";
        double v = s->v[i];
        switch (ctl_fields[i].kind) {
        case 'b': jb_printf(b, "%s", v != 0 ? "true" : "false"); break;
        case 'i': jb_printf(b, "%.0f", v); break;
        default:  jb_printf(b, "%.3f", v); break;
        }
    }
}

/* ---- nearest cars and peds ---------------------------------------------------------- */

typedef struct { gptr p; int32_t d; } near_t;

static void near_add(near_t *list, int *n, gptr p, int32_t d)
{
    int i = *n < LIST_MAX ? (*n)++ : LIST_MAX;
    if (i == LIST_MAX && d >= list[LIST_MAX - 1].d)
        return;
    if (i == LIST_MAX)
        i = LIST_MAX - 1;
    while (i > 0 && list[i - 1].d > d) {
        list[i] = list[i - 1];
        i--;
    }
    list[i].p = p;
    list[i].d = d;
}

static int nearest_cars(near_t *list, int32_t x, int32_t y, gptr skip)
{
    int n = 0, guard = 1000;
    gptr pool = rd32(G_CAR_POOL);
    for (gptr c = pool ? rd32(pool + 4) : 0; c && guard--; c = GP(Car, c)->next) {
        Car *car = GP(Car, c);
        Sprite *s = GP(Sprite, car->body);
        if (c == skip || !s)
            continue;
        near_add(list, &n, c, ctl_dist(x, y, s->x, s->y));
    }
    return n;
}

gptr ctl_nearest_car(void)
{
    Ped *ped = ctl_ped();
    int32_t x, y, z;
    near_t list[LIST_MAX];
    if (!ped || !ctl_pos(&x, &y, &z))
        return 0;
    return nearest_cars(list, x, y, ped->currentCar) ? list[0].p : 0;
}

gptr ctl_car_by_id(uint32_t id)
{
    int guard = 1000;
    gptr pool = rd32(G_CAR_POOL);
    for (gptr c = pool ? rd32(pool + 4) : 0; c && guard--; c = GP(Car, c)->next)
        if (GP(Car, c)->id == id && GP(Car, c)->body)
            return c;
    return 0;
}

void ctl_lists_json(jbuf *b)
{
    Ped *me = ctl_ped();
    int32_t x, y, z;
    near_t list[LIST_MAX];
    if (!me || !ctl_pos(&x, &y, &z))
        return;
    int n = nearest_cars(list, x, y, me->currentCar);
    jb_printf(b, ",\"cars\":[");
    for (int i = 0; i < n; i++) {
        Car *car = GP(Car, list[i].p);
        Sprite *s = GP(Sprite, car->body);
        jb_printf(b, "%s{\"id\":%u,\"model\":%u,\"remap\":%d,\"x\":%.3f,\"y\":%.3f,\"z\":%.3f,"
                  "\"dist\":%.3f,\"has_driver\":%s,\"speed\":%.3f}", i ? "," : "",
                  car->id, car->carModel, s->remap, scr_to_f(s->x), scr_to_f(s->y),
                  scr_to_f(s->z), scr_to_f(list[i].d), car->driver ? "true" : "false",
                  car_speed(car));
    }
    n = 0;
    int guard = 400;
    gptr mgr = rd32(G_PED_MGR), mine = (gptr)(uintptr_t)me;
    for (gptr p = mgr ? rd32(mgr + 4) : 0; p && guard--; p = GP(Ped, p)->nextPed) {
        Ped *ped = GP(Ped, p);
        int32_t px, py, pz;
        if (p == mine)
            continue;
        ped_pos(ped, &px, &py, &pz);
        near_add(list, &n, p, ctl_dist(x, y, px, py));
    }
    jb_printf(b, "],\"peds\":[");
    for (int i = 0; i < n; i++) {
        Ped *ped = GP(Ped, list[i].p);
        int32_t px, py, pz;
        ped_pos(ped, &px, &py, &pz);
        jb_printf(b, "%s{\"id\":%d,\"remap\":%u,\"occupation\":%u,\"x\":%.3f,\"y\":%.3f,"
                  "\"z\":%.3f,\"dist\":%.3f,\"in_car\":%s,\"alive\":%s}", i ? "," : "",
                  ped->id, ped->remap, ped->occupation, scr_to_f(px), scr_to_f(py),
                  scr_to_f(pz), scr_to_f(list[i].d),
                  ped->currentCar ? "true" : "false",
                  ped->lifeState == PED_ALIVE ? "true" : "false");
    }
    jb_printf(b, "]");
}

/* ---- actions -------------------------------------------------------------------------- */

int ctl_teleport(int32_t x, int32_t y, int32_t z, int has_z, const char **why)
{
    Ped *ped = ctl_ped();
    *why = "no player";
    if (!ped)
        return 0;
    gptr p = (gptr)(uintptr_t)ped;
    Car *car = GP(Car, ped->currentCar);
    if (car) {
        Sprite *s = GP(Sprite, car->body);
        if (!has_z)
            z = s ? s->z : ped->position.z;
        /* TeleportCar @0x4207F0 fastcall(Car*, edx; SCR_f x, y, z), ret 0xC */
        game_fastcall(0x4207F0, ped->currentCar, 0, 3, (uint32_t)x, (uint32_t)y, (uint32_t)z);
    } else if (has_z) {
        /* TeleportGameObject @0x491E00 fastcall(PedGameObject*, edx; x, y, z), ret 0xC */
        if (!ped->gameObject)
            return 0;
        game_fastcall(0x491E00, ped->gameObject, 0, 3, (uint32_t)x, (uint32_t)y, (uint32_t)z);
    } else {
        /* Ped_Teleport @0x435C80 fastcall(Ped*, edx; SCR_f x, y), ret 8 (seuko-mod
         * TeleportPed; used the same way by host/debug_roads.asm) */
        game_fastcall(0x435C80, p, 0, 2, (uint32_t)x, (uint32_t)y);
    }
    *why = "";
    return 1;
}

/* The enter branch of Player_HandleControls @0x4A76D0 (own decompile), with the car
 * chosen by us instead of Ped_FindEnterableCarInFront: Ped_SetTask(NO_OBJ), then
 * PedSetObjective(ENTER_CAR 35, 9999), Ped_SetObjCar, not as a passenger, door 0. The ped
 * then walks to the door and gets in (or jacks the driver) on its own. As a passenger:
 * the flag 1 and door 1, what SET_CHAR_OBJECTIVE (char, ENTER_CAR_AS_PASSENGER, car) does
 * plus the front passenger door (docs/passenger.md); the game then never jacks. */
int ctl_order_enter(gptr car, int passenger, const char **why)
{
    Ped *ped = ctl_ped();
    *why = "no player";
    if (!ped)
        return 0;
    *why = "already in a car";
    if (ped->currentCar)
        return 0;
    *why = "leaving a car";
    if (ped->objective == 36)
        return 0;
    /* Car_GetDoorCount @0x41F880 fastcall(Car*): CarInfo.num_doors in al. Doorless
     * models would send the passenger door search past the door table (Seq 27). */
    *why = "no passenger door";
    if (passenger && (game_fastcall(0x41F880, car, 0, 0) & 0xFF) < 2)
        return 0;
    gptr p = (gptr)(uintptr_t)ped;
    game_fastcall(0x436920, p, 0, 2, 0u, 9999u);          /* Ped_SetTask */
    game_fastcall(0x43BBC0, p, 0, 2, 35u, 9999u);         /* PedSetObjective ENTER_CAR */
    game_thiscall(0x403AA0, p, 1, car);                   /* Ped_SetObjCar */
    game_thiscall(0x4039B0, p, 1, passenger ? 1u : 0u);   /* Ped_SetEnterCarAsPassenger */
    game_thiscall(0x403A70, p, 1, passenger ? 1u : 0u);   /* Ped_SetTargetCarDoor */
    *why = "";
    return 1;
}

/* Experimental (phase 2): the game's own GO_TO_AREA_ON_FOOT (12) objective toward a point,
 * the way scripts give it: target position (+0x1DC), then PedSetObjective(12, 9999). The ped
 * AI routes there itself (Ped_MoveTowardTarget, docs/re/ped-ai.md). */
/* Experimental: GO_TO_AREA_IN_CAR (14), what the fire engines and ambulances get:
 * Ped_Obj1_GoToAreaInCar @0x438C40 gives the car a GO_TO_POINT drive order (follow roads)
 * and resumes its AI; passed when the drive order arrives (own decompile). */
uint32_t ctl_autopilot_ticks;           /* hk_CarDriverClass: AI ticks given (debug) */
uint32_t ctl_autopilot_ped;             /* player_move.asm: hk_CarDriverClass, hk_DriveCar */
static gptr autopilot_car;
static uint32_t autopilot_class;

/* Undo drive_to: the drive order freed (CarDriveOrderPool_Free @0x446290, thiscall pool
 * [0x5E6340]), the AI halted (Car_HaltAI @0x421540), the player's class and controls back. */
void ctl_autopilot_off(void)
{
    if (!autopilot_car)
        return;
    Car *car = GP(Car, autopilot_car);
    if (car->driveOrder && rd32(0x5E6340)) {
        game_thiscall(0x446290, rd32(0x5E6340), 1, car->driveOrder);
        car->driveOrder = 0;
    }
    if (car->ai) {
        game_fastcall(0x421540, autopilot_car, 0, 0);     /* Car_HaltAI */
        game_fastcall(0x4266F0, autopilot_car, 0, 0);     /* Car_FreeAI, as for a player */
    }
    car->driverClass = autopilot_class;
    if (car->physics)
        GP(CarPhysics, car->physics)->mode = 2;           /* CarPhysics_SetModePlayer */
    ctl_autopilot_ped = 0;
    autopilot_car = 0;
}

/* sms: our own text as a mission brief (the "SMS" with the speaker icon). Hud_Brief_Enqueue
 * @0x4C6690 (stdcall, ECX = g_HudManager [0x672F40] + 0xE4 briefQueue; priority, key, arg -1)
 * with the key "ctlsms" and a private priority 4: higher than the game's, so it shows at once,
 * and ClearAllBriefsWithPriority @0x4C6860 (thiscall, RET 4) drops our previous one.
 * Hud_Brief_PrepareCurrentText asks Gxt_FindTextW_thunk for the key's text, and hk_BriefText
 * (player_move.asm) answers it with ctl_brief_text. Text and key live in the low arena: the game reads them.
 * docs/re/hud-and-menus.md §3.1 */
#define SMS_MAX 120
uint32_t heap_alloc(uint32_t size, uint32_t flags) NASM(heap_alloc);   /* w32_core.asm */
static gptr sms_key, sms_text;

uint32_t ctl_brief_text(gptr key)
{
    if (!sms_key || !key || strcmp((const char *)(uintptr_t)key, "ctlsms"))
        return 0;
    return sms_text;
}

int ctl_sms(const char *text)
{
    gptr hud = rd32(0x672F40);
    if (!hud)
        return 0;
    if (!sms_key) {
        sms_key = heap_alloc(8, 0);
        sms_text = heap_alloc(2 * (SMS_MAX + 1), 0);
        if (!sms_key || !sms_text)
            return sms_key = 0, 0;
        memcpy((char *)(uintptr_t)sms_key, "ctlsms", 7);
    }
    /* u16 font codes, not UTF-16: printable ASCII (Seq 27). '#' toggles the highlight colour and
     * '_' is a blank glyph (gta2ctl's command names): both become '-' */
    uint16_t *w = (uint16_t *)(uintptr_t)sms_text;
    int n = 0;
    for (const unsigned char *t = (const unsigned char *)text; *t && n < SMS_MAX; t++)
        w[n++] = *t == '#' || *t == '_' ? '-' : *t >= 0x20 && *t < 0x7F ? *t : '?';
    w[n] = 0;
    gptr q = hud + 0xE4;
    game_thiscall(0x4C6860, q, 1, 4u);                    /* ClearAllBriefsWithPriority(4) */
    game_thiscall(0x4C6690, q, 3, 4u, sms_key, 0xFFFFFFFFu);   /* Enqueue, private priority 4 */
    return 1;
}

/* drive_to debug: the AI's state, one line to the game log */
void ctl_drive_debug(void)
{
    if (!autopilot_car)
        return;
    Car *car = GP(Car, autopilot_car);
    CarAI *ai = GP(CarAI, car->ai);
    CarDriveOrder *o = GP(CarDriveOrder, car->driveOrder);
    CarPhysics *ph = GP(CarPhysics, car->physics);
    Sprite *s = GP(Sprite, car->body);
    printf("ctl: drv f%u pos %.2f,%.2f rot %d | ai fl %06x slot %d step %u unstick %d offr %d stuck %u still %u rev %u obst %x blk %x"
           " | ord mode %d road %u urg %u arr %u retry %u tgt %.2f,%.2f,%.2f | ph gas %u brk %u st %d spd %d | cls %d aif %02x\n",
           r_frames, s ? s->x / 16384.0 : 0, s ? s->y / 16384.0 : 0, s ? s->rotation : 0,
           ai ? ai->flags : 0, ai ? ai->routeSlot : 0, ai ? ai->routeStep : 0,
           ai ? ai->unsure_unstickState : 0, ai ? ai->offRoadTurn : 0, ai ? ai->stuckTicks : 0,
           ai ? ai->stillTicks : 0, ai ? ai->reverseTicks : 0, ai ? ai->obstacleHit : 0,
           ai ? ai->blockingCar : 0, o ? (int)o->mode : -1, o ? o->followRoadActive : 0,
           o ? o->isUrgent : 0, o ? o->arrived : 0, o ? o->retryCooldown : 0,
           o ? o->targetX / 16384.0 : 0, o ? o->targetY / 16384.0 : 0, o ? o->targetZ / 16384.0 : 0,
           ph ? ph->isForwardGasOn : 0, ph ? ph->isBrakeOn : 0, ph ? ph->steering : 0,
           ai ? ai->targetSpeed : 0, (int)car->driverClass, car->aiFlags);
}

int ctl_order_drive(int32_t x, int32_t y, int32_t z, const char **why)
{
    Ped *ped = ctl_ped();
    *why = "no player";
    if (!ped)
        return 0;
    *why = "not driving a car";
    if (!ped->currentCar || GP(Car, ped->currentCar)->driver != (gptr)(uintptr_t)ped)
        return 0;
    gptr p = (gptr)(uintptr_t)ped;
    Car *car = GP(Car, ped->currentCar);
    /* the AI a player-driven car lost in Car_OnDriverEnter: Car_AllocAI @0x421510
     * (fastcall car), CarAI_SetParentCar @0x42A9D0 (fastcall ai, edx; car) — Seq 27 */
    if (!car->ai)
        game_fastcall(0x421510, ped->currentCar, 0, 0);
    *why = "no free car AI";
    if (!car->ai)
        return 0;
    game_fastcall(0x42A9D0, car->ai, 0, 1, ped->currentCar);
    /* CarAI_DriveStep clears the route flag of a PLAYER-class (2) car: MISSION (5) meanwhile */
    if (car->engineState != 3)                            /* ENGINE_ON: the keys start it, */
        game_fastcall(0x426E00, ped->currentCar, 0, 0);   /* we skip them: Car_EngineOn */
    autopilot_car = ped->currentCar;
    autopilot_class = car->driverClass;
    car->driverClass = 5;
    car->aiFlags &= ~3;           /* stale TurnLeft/TurnRight bits from traffic (Seq 27) */
    /* PLAYER physics mode (2) takes gears from Player_DriveCar, which we skip: AI mode (1),
     * CarPhysics_SetModeAI @0x4212A0 */
    if (car->physics)
        GP(CarPhysics, car->physics)->mode = 1;
    ctl_autopilot_ped = p;
    game_fastcall(0x436920, p, 0, 2, 0u, 9999u);          /* Ped_SetTask NO_OBJ */
    ped->objectiveTargetPosition.x = x;
    ped->objectiveTargetPosition.y = y;
    ped->objectiveTargetPosition.z = z;
    game_fastcall(0x43BBC0, p, 0, 2, 14u, 9999u);         /* PedSetObjective GO_TO_AREA_IN_CAR */
    ped->objectiveTargetPosition.x = x;
    ped->objectiveTargetPosition.y = y;
    ped->objectiveTargetPosition.z = z;
    *why = "";
    return 1;
}

int ctl_order_walk(int32_t x, int32_t y, int32_t z, const char **why)
{
    Ped *ped = ctl_ped();
    *why = "no player";
    if (!ped)
        return 0;
    *why = "on foot only";
    if (ped->currentCar)
        return 0;
    gptr p = (gptr)(uintptr_t)ped;
    game_fastcall(0x436920, p, 0, 2, 0u, 9999u);          /* Ped_SetTask NO_OBJ */
    ped->objectiveTargetPosition.x = x;
    ped->objectiveTargetPosition.y = y;
    ped->objectiveTargetPosition.z = z;
    game_fastcall(0x43BBC0, p, 0, 2, 12u, 9999u);         /* PedSetObjective GO_TO_AREA_ON_FOOT */
    ped->objectiveTargetPosition.x = x;                   /* in case the setter cleared it */
    ped->objectiveTargetPosition.y = y;
    ped->objectiveTargetPosition.z = z;
    *why = "";
    return 1;
}

void ctl_clear_objective(void)
{
    Ped *ped = ctl_ped();
    if (!ped)
        return;
    gptr p = (gptr)(uintptr_t)ped;
    game_fastcall(0x43BBC0, p, 0, 2, 0u, 9999u);
    game_fastcall(0x436920, p, 0, 2, 0u, 9999u);
}

/* What Ped_CancelEnterCarOnPlayerMove @0x43E1E0 does to the objective (Seq 27): back to
 * NO_OBJ, objective and task, while the ped has not reached the door yet. */
void ctl_cancel_objective(void)
{
    Ped *ped = ctl_ped();
    if (!ped || ped->currentCar || ped->objective != 35 || ped->state == 3)
        return;
    gptr p = (gptr)(uintptr_t)ped;
    game_fastcall(0x43BBC0, p, 0, 2, 0u, 9999u);          /* PedSetObjective NO_OBJ */
    game_fastcall(0x436920, p, 0, 2, 0u, 9999u);          /* Ped_SetTask NO_OBJ */
}

/* The exit branch of Player_HandleControls: if Car_CanExitCar @0x4222A0, Ped_SetTask(NO_OBJ),
 * PedSetObjective(LEAVE_CAR 36, 9999), Ped_SetObjCar(current car). */
int ctl_order_exit(const char **why)
{
    Ped *ped = ctl_ped();
    *why = "no player";
    if (!ped)
        return 0;
    *why = "not in a car";
    if (!ped->currentCar)
        return 0;
    *why = "this car cannot be left now";
    if (!(game_fastcall(0x4222A0, ped->currentCar, 0, 0) & 0xFF))
        return 0;
    gptr p = (gptr)(uintptr_t)ped;
    game_fastcall(0x436920, p, 0, 2, 0u, 9999u);
    game_fastcall(0x43BBC0, p, ped->currentCar, 2, 36u, 9999u);
    game_thiscall(0x403AA0, p, 1, ped->currentCar);
    *why = "";
    return 1;
}

/* ---- steering ------------------------------------------------------------------------ */

static int ang_delta(int from, int to)             /* -720 .. 720 */
{
    int d = ((to - from) % ANG_TURN + ANG_TURN) % ANG_TURN;
    return d > ANG_TURN / 2 ? d - ANG_TURN : d;
}

void ctl_on_foot(gptr player, gptr ped)
{
    if (ctl_steer.mode == STEER_NONE || ctl_steer.done)
        return;
    Player *pl = GP(Player, player);
    /* not while wasted / busted (the game drives the corpse then), in a cutscene, or while
     * the game walks the ped to a car door (Seq 27, reply-seq58-gta2ctl-re.md) */
    if (pl->ped != ped || pl->isDeadOrBusted || pl->controlState || pl->controlsDisabled ||
        GP(Ped, ped)->objective == 35 || GP(Ped, ped)->objective == 12)
        return;
    PedGameObject *go = GP(PedGameObject, GP(Ped, ped)->gameObject);
    Sprite *s = go ? GP(Sprite, go->body) : 0;
    if (!s)
        return;
    int heading = (uint16_t)go->spriteRotation;
    if (ctl_steer.mode == STEER_FACE) {
        int d = ang_delta(heading, ctl_steer.heading);
        pl->turnRate = (short)d;
        if (d == 0)
            ctl_steer.done = 1;
        return;
    }
    double dx = (double)ctl_steer.tx - s->x, dy = (double)ctl_steer.ty - s->y;
    if (hypot(dx, dy) <= ctl_steer.radius) {
        pl->turnRate = 0;
        pl->moveSpeed = 0;
        ctl_steer.done = 1;
        return;
    }
    int want = (int)lrint(atan2(dx, dy) * (ANG_TURN / (2 * M_PI)));
    pl->turnRate = (short)ang_delta(heading, (want + ANG_TURN) % ANG_TURN);
    pl->moveSpeed = MOVE_FWD;
}
