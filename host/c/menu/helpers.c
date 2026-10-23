/* helpers.c — the K menu's shared game helpers (the player, the current / last car, where
 * spawners put things, the car spawn) and the data the NASM feature modules read.
 * Ped and Car fields: gta2-seuko-mod src/game/gta2.h @25b1985, re/gta2_types_c64.h.
 */
#include <math.h>
#include "dm.h"
#include "../spawn.h"

const char *km_spawn_why;
const char s_dm_noplayer2[] = "No player";
static const char s_dm_incar[] = "Get out of the car first";
static const char s_dm_nospawn[] = "Cannot spawn here";

int32_t dm_model;
gptr dm_last_car NASM(dm_last_car);     /* emergency.c sets them too */
uint32_t dm_last_car_id NASM(dm_last_car_id);

/* CAR_MODEL4 names by id (seuko-mod src/game/gta2.h) */
const char *const dm_car_names[DM_NCARNAMES] = {
    "ALFA", "ALLARD", "AMDB4", "APC", "BANKVAN", "BMW", "BOXCAR", "BOXTRUCK", "BUG", "CAR9",
    "BUICK", "BUS", "COPCAR", "DART", "EDSEL", "CAR15", "FIAT", "FIRETRUCK", "GRAHAM",
    "GT24640", "CAR20", "GTRUCK", "GUNJEEP", "HOTDOG", "HOTDOG_D1", "HOTDOG_D2", "HOTDOG_D3",
    "ICECREAM", "ISETLIMO", "ISETTA", "JEEP", "JEFFREY", "LIMO", "LIMO2", "MEDICAR", "MERC",
    "MESSER", "MIURA", "MONSTER", "MORGAN", "MORRIS", "PICKUP", "RTYPE", "CAR43", "SPIDER",
    "SPRITE", "STINGRAY", "STRATOS", "STRATOSB", "STRIPETB", "STYPE", "STYPECAB", "SWATVAN",
    "T2000GT", "TANK", "TANKER", "TAXI", "TBIRD", "TOWTRUCK", "TRAIN", "TRAINCAB", "TRAINFB",
    "TRANCEAM", "TRUKCAB1", "TRUKCAB2", "TRUKCONT", "TRUKTRNS", "TVVAN", "VAN", "VESPA",
    "VTYPE", "WBTWIN", "WRECK0", "WRECK1", "WRECK2", "WRECK3", "WRECK4", "WRECK5", "WRECK6",
    "WRECK7", "WRECK8", "WRECK9", "XK120", "ZCX5", "EDSELFBI", "HOTDOG_D4", "KRSNABUS",
};

/* models SpawnCar accepts (seuko-mod src/game/utils/lists-utils.cpp) */
const uint8_t dm_spawnable[DM_NSPAWNABLE] = {
    0, 1, 2, 3, 4, 5, 7, 8, 10, 11, 12, 13, 14, 84, 16, 17,
    18, 19, 21, 22, 23, 24, 25, 26, 85, 27, 28, 29, 30, 31, 86, 32,
    33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 45, 46, 47, 48, 49,
    50, 51, 52, 53, 54, 55, 56, 57, 58, 62, 63, 64, 65, 66, 67, 68,
    69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83,
};

/* Game* 0x5EB4FC +0x38 = the current Player, +0x2c4 its Ped */
Player *dm_player(void)
{
    return game_player();
}

Ped *dm_player_ped(void)
{
    Player *pl = dm_player();
    return pl ? GP(Ped, pl->ped) : 0;
}

/* dm_player_ped for NASM (host/debug_menu.asm turns it into eax = Ped*, ecx = Player*) */
struct dm_pair { uint64_t ped, player; };
struct dm_pair dm_player_pair(void)
{
    Player *pl = dm_player();
    struct dm_pair r = { pl ? pl->ped : 0, (uint64_t)(uintptr_t)pl };
    return r;
}

/* dm_track_car (DM_FRAME): remember the car the player is in, for "the last car" */
static void dm_track_car(void)
{
    Ped *ped = dm_player_ped();
    if (!ped || !ped->currentCar)
        return;
    dm_last_car = ped->currentCar;
    dm_last_car_id = GP(Car, ped->currentCar)->id;
}
DM_FRAME(0, dm_track_car);

/* the car the player is in, else the last one while its id still matches (cars live in a
 * fixed array, so a destroyed car's slot is reused with a new id), or 0 */
Car *dm_car(int *in_it)
{
    Ped *ped = dm_player_ped();
    if (ped && ped->currentCar) {
        *in_it = 1;
        return GP(Car, ped->currentCar);
    }
    *in_it = 0;
    Car *car = GP(Car, dm_last_car);
    if (!car)
        return 0;
    if (car->id != dm_last_car_id || !car->body) {
        dm_last_car = 0;
        return 0;
    }
    return car;
}

/* that far in front of the player on foot, facing the same way (Ped +0x168 PedGameObject,
 * +0x80 Sprite: rotation, x, y, z): offset = dist * (sin a, cos a), a = rotation * 2pi / 1440
 * (the front, user-checked in play) */
uint32_t km_spawn_pos(int32_t out[4], int32_t dist)
{
    Ped *ped = dm_player_ped();
    km_spawn_why = s_dm_noplayer2;
    if (!ped)
        return 0;
    km_spawn_why = s_dm_incar;
    if (ped->currentCar)
        return 0;
    km_spawn_why = s_dm_nospawn;
    PedGameObject *go = GP(PedGameObject, ped->gameObject);
    Sprite *spr = go ? GP(Sprite, go->body) : 0;
    if (!spr)
        return 0;
    uint32_t rot = (uint16_t)spr->rotation;
    double a = rot * (2 * M_PI / 1440);
    out[0] = spr->x + (int32_t)lrint(sin(a) * dist);
    out[1] = spr->y + (int32_t)lrint(cos(a) * dist);
    out[2] = spr->z;
    out[3] = (int32_t)rot;
    return go->body;
}

/* SpawnCar @0x426AC0, fastcall(TrafficManager* ecx = [0x5E4CA4], edx = 0; SCR_f x, y, z,
 * int rotation, CAR_MODEL4 model, int scale = [0x5E4D4C]) -> Car*, then the remap on its
 * body (Car +0x50, a Sprite): Sprite_SetRemap @0x4B9B00 thiscall(Sprite*, ushort remap)
 * sets +0x24 and the render state +0x34, Sprite_SetNoRemapState @0x420700
 * fastcall(Sprite*) restores the sprite's colours (Seq 27 seq49-car-sprite-remap.md).
 * Car_ApplyRemap @0x421FD0 is not used: it skips models with num_remaps <= 1.
 * From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 * src/game/functions.h, memory.h, src/modules/modmenu/utils/spawn-car.cpp @25b1985 —
 * SpawnCar 0x426AC0, TrafficManager 0x5E4CA4, CarsScale 0x5E4D4C. */
int km_car_remap_last;                  /* the palette remap km_spawn_car resolved: -1 random, -2 none */
uint32_t km_spawn_car(int model, int remap, int32_t x, int32_t y, int32_t z, int rot)
{
    km_spawn_why = s_dm_nospawn;
    gptr tm = rd32(0x5E4CA4);
    if (!tm)
        return 0;
    CarInfo *ci = dm_car_info(model);
    if (ci && remap > ci->num_remaps)
        remap = ci->num_remaps;
    int r = -2;                         /* none */
    if (remap < 0 || (remap > 0 && !ci))
        r = -1;                         /* random: leave the game's pick */
    else if (remap > 0)
        r = ci->remap[remap - 1];
    km_car_remap_last = r;
    uint32_t a[6] = { (uint32_t)x, (uint32_t)y, (uint32_t)z, (uint32_t)rot, (uint32_t)model,
                      rd32(0x5E4D4C) };
    gptr car = (gptr)call32(0x426AC0, a, 6, 0, tm, 0);
    if (!car)
        return 0;
    dm_last_car = car;
    dm_last_car_id = GP(Car, car)->id;
    km_spawn_why = "Car spawned";
    gptr body = GP(Car, car)->body;
    if (!body || r == -1)
        return car;
    if (r == -2)
        game_fastcall(0x420700, body, 0, 0);
    else
        game_thiscall(0x4B9B00, body, 1, (uint32_t)r);
    return car;
}
