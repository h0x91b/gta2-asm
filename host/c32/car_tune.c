/* car_tune.c — live handling tuning for the car the player is in (K menu → Vehicle →
 * Tuning; the rows are host C: host/c/menu/car_tune.c). Top speed, acceleration, turbo,
 * mass, brakes, steering lock, turn-in, rear grip, handbrake slide, front drive share and
 * damage taken, each with LEFT / RIGHT, plus reset of this model and of every model.
 *
 * Where the handling lives (docs/re/car-physics.md §5, Seq 33 verified): per MODEL, not per
 * car. g_CarModelTable (0x5E5488) holds engineData[256] (+0x404, the NYC.GCI record,
 * CarEngineData, 72 B; mass already x1.1) and physicsData[256] (+0x000, CarPhysicsData,
 * 44 B, derived by CarPhysicsData_Build 0x432AA0: inertia from mass, half / fifth thrust,
 * max turbo thrust, rear drive bias, skid thresholds). CarPhysics_SelectModelData 0x49ECC0
 * points g_CurCarEngineData / g_CurCarPhysicsData at the entries of
 * Car_GetPhysicsModel(car) 0x4220A0 at the top of every physics step, so an edit of the
 * model's records takes effect on the next tick, for every car of that model (traffic
 * included). Per car was rejected: a car has no handling of its own to point anywhere else,
 * so it would take a detour on SelectModelData plus every direct reader of the tables
 * (Car_GetMaxSpeed, Car_GetMass, Car_GetModelInertia, CarPhysics_CmFromCpViaModel, the
 * engine sounds, ...), and there is no free model id to clone the records into.
 *
 * An edit changes the CarEngineData field, then reruns the game's own CarPhysicsData_Build
 * for the model, so the derived values follow (mass → inertia, thrust → half / fifth / turbo
 * thrust, front drive → rear drive). Build stops the game with a fatal error (0x3F6,
 * carinfo.cpp:0x5B) unless gear2_speed <= gear3_speed <= max_speed, so the top speed scales
 * both gear speeds with it (from stock: the gear changes stay at the same fraction of the
 * top speed). front_mass_bias is not offered: it moves the centre of mass (cmOffset) under a
 * moving car, whose cmPos / centerPos pair would no longer match.
 *
 * Stock values: the first edit of a model copies its record. The table is rebuilt from
 * NYC.GCI on every level load (CarModelTable_Load 0x432FC0), which drops every edit; a new
 * engineDataBlock pointer drops the copies too. "Tuned" is a live compare, not a flag.
 */
#include "c32.h"

C32_OFFSET(Game, currentPlayer, 0x38);
C32_OFFSET(Player, ped, 0x2C4);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(CarModelTable, physicsData, 0x0);
C32_OFFSET(CarModelTable, engineData, 0x404);
C32_OFFSET(CarModelTable, engineDataBlock, 0x804);
C32_OFFSET(CarEngineData, turbo, 0x1);
C32_OFFSET(CarEngineData, mass, 0x4);
C32_OFFSET(CarEngineData, front_drive_bias, 0x8);
C32_OFFSET(CarEngineData, brake_friction, 0x10);
C32_OFFSET(CarEngineData, turn_in, 0x14);
C32_OFFSET(CarEngineData, turn_ratio, 0x18);
C32_OFFSET(CarEngineData, rear_end_stability, 0x1C);
C32_OFFSET(CarEngineData, handbrake_slide_value, 0x20);
C32_OFFSET(CarEngineData, thrust, 0x24);
C32_OFFSET(CarEngineData, max_speed, 0x28);
C32_OFFSET(CarEngineData, anti_strength, 0x2C);
C32_OFFSET(CarEngineData, gear2_speed, 0x40);
C32_OFFSET(CarEngineData, gear3_speed, 0x44);
C32_ASSERT(sizeof(CarEngineData) == 0x48);

#define G_GAME          0x5EB4FC        /* Game* */
#define G_CARMODELTABLE 0x5E5488        /* CarModelTable* (re/globals.csv) */
#define FIX(x)          ((int32_t)((x) * 16384))        /* Q14, constants only */

GAME_FN(uint32_t, G2_FASTCALL, Car_GetPhysicsModel, 0x4220A0, (Car *car));
/* thiscall(CarPhysicsData *out, byte model), ret 4: reads engineData[model] itself
 * (disassembly 0x432AA0..0x432C57) */
GAME_FN(void, G2_THISCALL, CarPhysicsData_Build, 0x432AA0, (CarPhysicsData *self, uint32_t model));

enum { K_MUL, K_ADD, K_BOOL };          /* x1.1 per step / a fixed step / on-off byte */

struct field {
    const char *name;
    uint16_t off;                       /* in CarEngineData */
    uint8_t kind;
    int32_t step, min, max;             /* K_ADD: absolute Q14; K_MUL: max 0 = 8x stock */
};

/* the host's rows are these, in this order (CT_NFIELDS in host/c/menu/car_tune.c) */
static const struct field fields[] = {
    { "Top speed",       0x28, K_MUL,  0, 0, 0 },
    { "Acceleration",    0x24, K_MUL,  0, 0, 0 },
    { "Turbo",           0x01, K_BOOL, 0, 0, 1 },
    { "Mass",            0x04, K_MUL,  0, 0, 0 },
    { "Brakes",          0x10, K_MUL,  0, 0, 0 },
    { "Steering lock",   0x18, K_MUL,  0, 0, FIX(1.5) },    /* fix-angle, 1.5 = 86 degrees */
    { "Turn-in",         0x14, K_ADD,  FIX(0.05), 0, FIX(0.9) },  /* rear cx = 1 - turn_in */
    { "Rear grip",       0x1C, K_MUL,  0, 0, 0 },
    { "Handbrake slide", 0x20, K_ADD,  FIX(0.05), 0, FIX(1.0) },
    { "Front drive",     0x08, K_ADD,  FIX(0.1), 0, FIX(1.0) },
    { "Damage taken",    0x2C, K_ADD,  FIX(0.1), 0, FIX(4.0) },  /* 0 = indestructible */
};
#define NFIELDS ((int)(sizeof fields / sizeof fields[0]))

/* what the host shows; refreshed by every ct_frame */
struct ct_view {
    int32_t model;                      /* physics model id, -1 = not in a car */
    int32_t tuned;                      /* this model differs from stock */
    int32_t tuned_models;               /* models that differ from stock */
    int32_t cur[NFIELDS], stock[NFIELDS];
};
struct ct_view ct_view;
C32_EXPORT(ct_view);

static CarEngineData stock[256];
static uint8_t have[256];
static CarEngineData *block;            /* engineDataBlock the copies belong to */
static char toast[64];

static void fmt(char *buf, const char *f, ...)
{
    va_list ap;
    va_start(ap, f);
    game_vsprintf(buf, f, ap);
    va_end(ap);
}

static int32_t rd(const CarEngineData *e, int f)
{
    const uint8_t *p = (const uint8_t *)e + fields[f].off;
    return fields[f].kind == K_BOOL ? *p : *(const int32_t *)p;
}

static void wr(CarEngineData *e, int f, int32_t v)
{
    uint8_t *p = (uint8_t *)e + fields[f].off;
    if (fields[f].kind == K_BOOL)
        *p = (uint8_t)v;
    else
        *(int32_t *)p = v;
}

/* Q14 as "1.234", in integers */
static void q14(char *buf, int32_t v)
{
    char *s = buf;
    if (v < 0) {
        *s++ = '-';
        v = -v;
    }
    int32_t ip = v >> 14, fp = ((v & 0x3FFF) * 1000 + 0x2000) >> 14;
    if (fp == 1000) {
        ip++;
        fp = 0;
    }
    fmt(s, "%d.%03d", ip, fp);
}

static CarModelTable *table(void)
{
    CarModelTable *t = *(CarModelTable *volatile *)G_CARMODELTABLE;
    if (t && t->engineDataBlock != block) {     /* a level load rebuilt it from NYC.GCI */
        block = t->engineDataBlock;
        for (int i = 0; i < 256; i++)
            have[i] = 0;
    }
    return t;
}

static int differs(const CarEngineData *e, int m)
{
    if (!have[m])
        return 0;
    const uint8_t *a = (const uint8_t *)e, *b = (const uint8_t *)&stock[m];
    for (unsigned i = 0; i < sizeof *e; i++)
        if (a[i] != b[i])
            return 1;
    return 0;
}

static void rebuild(CarModelTable *t, int m)
{
    if (t->physicsData[m])
        CarPhysicsData_Build(t->physicsData[m], (uint32_t)m);
}

static int32_t clamp(int32_t v, int32_t lo, int32_t hi)
{
    return v < lo ? lo : v > hi ? hi : v;
}

static void step(CarModelTable *t, int m, int f, int dir)
{
    CarEngineData *e = t->engineData[m];
    const struct field *fd = &fields[f];
    if (!have[m]) {
        stock[m] = *e;
        have[m] = 1;
    }
    int32_t was = rd(e, f), s = rd(&stock[m], f), v = was;
    switch (fd->kind) {
    case K_BOOL:
        v = !v;
        break;
    case K_ADD:
        v = clamp(v + dir * fd->step, fd->min, fd->max);
        break;
    default: {                          /* x1.1 / ÷1.1, between stock/8 and 8x stock; int32 is
                                         * enough (8x the heaviest mass x 11 < 2^31) and the
                                         * image has no 64-bit division helpers */
        int32_t lo = s / 8 > 0 ? s / 8 : 1, hi = fd->max ? fd->max : s * 8;
        if (s <= 0)
            return;                     /* nothing to scale (no such stock record) */
        int32_t n = dir > 0 ? v * 11 / 10 : v * 10 / 11;
        if (n == v)
            n += dir;
        v = clamp(n, lo, hi);
    }
    }
    wr(e, f, v);
    if (fd->off == 0x28) {              /* gears keep their share of the top speed */
        int32_t sm = stock[m].max_speed;
        e->gear2_speed = stock[m].gear2_speed * v / sm;
        e->gear3_speed = stock[m].gear3_speed * v / sm;
        if (e->gear3_speed > v)
            e->gear3_speed = v;
        if (e->gear2_speed > e->gear3_speed)
            e->gear2_speed = e->gear3_speed;
    }
    rebuild(t, m);

    char a[16], b[16];
    if (fd->kind == K_BOOL) {
        fmt(toast, "%s %s", fd->name, v ? "on" : "off");
        c32_log("car_tune: model %d %s %d -> %d", m, fd->name, was, v);
    } else {
        q14(a, was);
        q14(b, v);
        fmt(toast, "%s %s", fd->name, b);
        c32_log("car_tune: model %d %s %s -> %s (%d%% of stock)", m, fd->name, a, b,
                s ? v * 100 / s : 0);
    }
}

static void reset(CarModelTable *t, int m)
{
    if (!have[m] || !t->engineData[m])
        return;
    *t->engineData[m] = stock[m];
    rebuild(t, m);
}

static Car *player_car(void)
{
    Game *g = *(Game *volatile *)G_GAME;
    Player *pl = g ? g->currentPlayer : 0;
    Ped *ped = pl ? pl->ped : 0;
    return ped ? ped->currentCar : 0;
}

/* Called by the host once a frame while the Tuning page is current, on the game's side of
 * the frame. op 0 refresh, 1 step field f by dir (-1 / +1), 2 reset this model, 3 reset
 * every model. Returns a toast or 0. */
const char *G2_STDCALL ct_frame(uint32_t op, uint32_t f, int32_t dir)
{
    const char *ret = 0;
    CarModelTable *t = table();
    Car *car = t ? player_car() : 0;
    int m = car ? (int)(Car_GetPhysicsModel(car) & 0xFF) : -1;
    if (m >= 0 && !t->engineData[m])
        m = -1;

    if (op == 3 && t) {
        int n = 0;
        for (int i = 0; i < 256; i++)
            if (t->engineData[i] && differs(t->engineData[i], i)) {
                reset(t, i);
                n++;
            }
        c32_log("car_tune: reset %d models to stock", n);
        fmt(toast, "Reset %d models", n);
        ret = toast;
    } else if (op && m < 0) {
        ret = "Not in a car";
    } else if (op == 1 && f < (uint32_t)NFIELDS) {
        step(t, m, (int)f, dir < 0 ? -1 : 1);
        ret = toast;
    } else if (op == 2) {
        reset(t, m);
        c32_log("car_tune: model %d reset to stock", m);
        ret = "Stock handling";
    }

    ct_view.model = m;
    ct_view.tuned = 0;
    ct_view.tuned_models = 0;
    for (int i = 0; t && i < 256; i++)
        if (t->engineData[i] && differs(t->engineData[i], i))
            ct_view.tuned_models++;
    if (m >= 0) {
        CarEngineData *e = t->engineData[m];
        ct_view.tuned = differs(e, m);
        for (int i = 0; i < NFIELDS; i++) {
            ct_view.cur[i] = rd(e, i);
            ct_view.stock[i] = rd(have[m] ? &stock[m] : e, i);
        }
    }
    return ret;
}
C32_EXPORT(ct_frame);
