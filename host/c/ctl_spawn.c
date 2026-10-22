/* ctl_spawn.c — gta2ctl's stand-in for spawn.h until Seq 55's C port of the K menu lands
 * (then this file goes and theirs implements the same declarations). Same recipes as the
 * K menu's NASM pages (host/menu/spawn_car.asm, spawn_ped.asm, spawn_object.asm, and
 * dm_spawn_pos / dm_spawn_car in debug_menu.asm), addresses and sources cited there:
 * SpawnCar, TrafficManager and CarsScale from gta2-seuko-mod by izawartka
 * (https://github.com/izawartka/gta2-seuko-mod) src/game/functions.h, memory.h @25b1985;
 * the CREATE_CHAR / CREATE_OBJ recipes from Seq 27 (seq51_answer.md). Role auto is simpler
 * than the K menu's: the ped keeps what Ped_Spawn gave it. */
#include <math.h>
#include "game.h"
#include "spawn.h"

const char *km_spawn_why = "";

#define G_TRAFFIC       0x5E4CA4        /* TrafficManager* (= g_CarManager) */
#define G_CARS_SCALE    0x5E4D4C
#define G_PED_POOL      0x5E5BBC        /* PedManager_S25*: +0 freeListHead */
#define G_GANGS         0x5EB898        /* GangRespect[10], 0x144 each: +0 present, +0x101 remap */
#define G_OBJ_SPAWNER   0x665788
#define G_STYLE_DATA    0x670684        /* StyleData*: +0x5C AllCarsInfo (CarInfo*[]) */

/* model ids SpawnCar accepts (seuko-mod src/game/utils/lists-utils.cpp, = dm_spawnable) */
static const uint8_t spawnable[] = {
    0, 1, 2, 3, 4, 5, 7, 8, 10, 11, 12, 13, 14, 84, 16, 17,
    18, 19, 21, 22, 23, 24, 25, 26, 85, 27, 28, 29, 30, 31, 86, 32,
    33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 45, 46, 47, 48, 49,
    50, 51, 52, 53, 54, 55, 56, 57, 58, 62, 63, 64, 65, 66, 67, 68,
    69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83,
};

/* sp_roles (host/menu/spawn_ped.asm): occupation, body, class, threat search, reaction,
 * weapon (-1 none, -2 the gang's pick) */
static const int roles[][6] = {
    { 0, 0, 0, 0, 0, -1 },      /* 0 auto */
    { 3, 0, 3, 2, 3, -1 },      /* 1 civilian */
    { 19, 1, 4, 1, 2, -2 },     /* 2 gang member */
    { 29, 2, 3, 1, 1, 0 },      /* 3 cop */
    { 25, 2, 4, 1, 1, 1 },      /* 4 SWAT */
    { 26, 1, 4, 1, 1, 1 },      /* 5 FBI */
    { 31, 2, 3, 1, 1, 1 },      /* 6 army */
    { 23, 0, 4, 0, 1, -1 },     /* 7 medic */
    { 38, 0, 4, 0, 1, -1 },     /* 8 fireman */
    { 22, 1, 4, 2, 3, -1 },     /* 9 Elvis */
    { 15, 0, 4, 2, 3, -1 },     /* 10 mugger */
    { 16, 0, 6, 2, 3, -1 },     /* 11 car thief */
    { 14, 1, 4, 1, 2, 0 },      /* 12 psycho */
    { 18, 1, 4, 1, 2, 0 },      /* 13 criminal */
    { 43, 0, 5, 2, 3, -1 },     /* 14 stand still */
};
#define NROLES ((int)(sizeof roles / sizeof roles[0]))

uint32_t km_spawn_pos(int32_t out[4], int32_t dist)
{
    Player *pl = game_player();
    Ped *ped = pl ? GP(Ped, pl->ped) : 0;
    km_spawn_why = "No player";
    if (!ped)
        return 0;
    km_spawn_why = "In a car";
    if (ped->currentCar)
        return 0;
    km_spawn_why = "Cannot spawn here";
    PedGameObject *go = GP(PedGameObject, ped->gameObject);
    Sprite *body = go ? GP(Sprite, go->body) : 0;
    if (!body)
        return 0;
    double a = (uint16_t)body->rotation * (2.0 * M_PI / 1440.0);
    out[0] = body->x + (int32_t)lrint(sin(a) * dist);
    out[1] = body->y + (int32_t)lrint(cos(a) * dist);
    out[2] = body->z;
    out[3] = (uint16_t)body->rotation;
    km_spawn_why = "";
    return go->body;
}

uint32_t km_spawn_car(int model, int remap, int32_t x, int32_t y, int32_t z, int rot)
{
    unsigned i;
    for (i = 0; i < sizeof spawnable; i++)
        if (spawnable[i] == model)
            break;
    km_spawn_why = "Model not spawnable";
    if (i == sizeof spawnable)
        return 0;
    km_spawn_why = "Cannot spawn here";
    gptr traffic = rd32(G_TRAFFIC);
    if (!traffic)
        return 0;
    gptr car = game_fastcall(0x426AC0, traffic, 0, 6, (uint32_t)x, (uint32_t)y, (uint32_t)z,
                             (uint32_t)rot, (uint32_t)model, rd32(G_CARS_SCALE));
    if (!car)
        return 0;
    gptr body = GP(Car, car)->body;
    if (body && remap == 0) {
        game_fastcall(0x420700, body, 0, 0);                  /* Sprite_SetNoRemapState */
    } else if (body && remap > 0) {
        gptr style = rd32(G_STYLE_DATA), cars = style ? rd32(style + 0x5C) : 0;
        gptr info = cars ? rd32(cars + 4u * (uint32_t)model) : 0;   /* AllCarsInfo[model] */
        if (info && remap <= rd8(info + 4))                    /* CarInfo +4 num_remaps */
            game_thiscall(0x4B9B00, body, 1, rd8(info + 0xE + remap - 1));   /* Sprite_SetRemap */
    }
    km_spawn_why = "Car spawned";
    return car;
}

static gptr gang_for(int remap)
{
    gptr g = rd32(G_GANGS), any = 0;
    if (!g)
        return 0;
    for (int i = 0; i < 10; i++, g += 0x144) {
        if (!rd8(g))
            continue;
        if (!any)
            any = g;
        if (rd8(g + 0x101) == remap)
            return g;
    }
    return any;
}

uint32_t km_spawn_ped(int remap, int role, int behave, int32_t x, int32_t y, int32_t z, int rot)
{
    km_spawn_why = "Bad role";
    if (role < 0 || role >= NROLES || remap < 0 || remap > 52)
        return 0;
    km_spawn_why = "No free ped";                 /* Ped_Spawn pops the pool with no empty check */
    gptr pool = rd32(G_PED_POOL);
    if (!pool || !rd32(pool))
        return 0;
    gptr p = game_stdcall(0x43DB40, 5, (uint32_t)x, (uint32_t)y, (uint32_t)z, (uint32_t)remap,
                          (uint32_t)rot);        /* Ped_Spawn */
    km_spawn_why = "No free ped sprite";
    if (!p)
        return 0;
    Ped *ped = GP(Ped, p);
    if (role) {
        const int *r = roles[role];
        game_thiscall(0x403920, p, 1, (uint32_t)r[2]);        /* Ped_SetPedClass */
        game_thiscall(0x403970, p, 1, (uint32_t)r[0]);        /* Ped_SetOccupation */
        ped->graphicType = (uint32_t)r[1];
        ped->threatSearch = (uint32_t)r[3];
        ped->threatReaction = (uint32_t)r[4];
        int weapon = r[5];
        if (role == 2) {
            gptr g = gang_for(remap);
            if (g) {
                ped->gang = g;
                weapon = (int)game_fastcall(0x45DB70, g, 0, 0);   /* Gang_PickWeaponByRespect */
            } else {
                weapon = -1;
            }
        }
        if (weapon >= 0)
            game_fastcall(0x43D830, p, 0, 1, (uint32_t)weapon);  /* Ped_SetWeapon */
    }
    km_spawn_why = "Ped spawned";
    Player *pl = game_player();
    gptr me = pl ? pl->ped : 0;
    if (me && behave == 1) {
        game_thiscall(0x43BBC0, p, 2, 20u, 9999u);    /* PedSetObjective KILL_CHAR_ON_FOOT */
        game_thiscall(0x403AC0, p, 1, me);            /* Ped_SetObjTargetPed */
        km_spawn_why = "Ped spawned, hostile";
    } else if (me && behave == 2) {
        if (!GP(Ped, me)->group)
            game_fastcall(0x440350, me, 0, 1, 0u);    /* PedGroupCreate */
        gptr grp = GP(Ped, me)->group;
        if (!grp)
            km_spawn_why = "Ped spawned, no group for you";
        else if (rd8(grp + 0x34) >= 7)
            km_spawn_why = "Ped spawned, your group is full";
        else {
            game_fastcall(0x404C90, grp, 0, 1, p);    /* PedGroupAddPed */
            km_spawn_why = "Ped spawned, follows you";
        }
    }
    return p;
}

uint32_t km_spawn_object(int type, int remap, int32_t x, int32_t y, int32_t z, int rot)
{
    km_spawn_why = "Cannot spawn here";
    gptr spawner = rd32(G_OBJ_SPAWNER);
    if (!spawner || type < 0 || type > 255)
        return 0;
    gptr fn = (type >= 200 && type <= 244) ? 0x485480    /* Object_NewPhysicsObjUnlessBlocked */
                                           : 0x4852E0;   /* SpawnObject */
    gptr obj = game_thiscall(fn, spawner, 5, (uint32_t)type, (uint32_t)x, (uint32_t)y,
                             (uint32_t)z, (uint32_t)rot);
    km_spawn_why = "Blocked";
    if (!obj)
        return 0;
    gptr sprite = rd32(obj + 4);
    if (remap >= 0 && sprite)
        game_thiscall(0x4B9B00, sprite, 1, (uint32_t)remap);  /* Sprite_SetRemap */
    km_spawn_why = "Object spawned";
    return obj;
}
