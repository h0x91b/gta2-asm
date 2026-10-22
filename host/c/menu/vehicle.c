/* vehicle.c — the K menu's Vehicle page: the car the player is in, else the last one
 * (dm_car): colour (car remap), invincibility, repair, explode. Spawning is Spawn > Car
 * (spawn_car.c). Repair, explode and colour follow gta2-seuko-mod
 * src/modules/modmenu/utils/fix-car-utils.cpp, explode-last-car.cpp @25b1985.
 * Car fields (seuko-mod src/game/gta2.h, re/gta2_types_c64.h): deltasBitstate +0x8 (bits
 * 0-4 broken lights and windscreen), body +0x50 (a Sprite: remap +0x24, paletteKind +0x34),
 * damage +0x74, flags (physicsBitmask) +0x78, carModel +0x84, damageFireStage +0x8c,
 * engineState +0x9c (3 = on), lightsBitstate +0xa4 (1 brake lights, 2 lights). */
#include <stdio.h>
#include <string.h>
#include "dm.h"

#define CAR_INVINCIBLE 0x708            /* NO_COLLISION_DAMAGE | BULLET-, ROCKET-, FLAMEPROOF */

static const char s_nocar[] = "No car";

static void carinfo_change(const struct dm_item *it, int dir)
{
    (void)it;
    (void)dir;
}

static void carinfo_fmt(char *end)
{
    int in_it;
    Car *car = dm_car(&in_it);
    if (!car)
        strcpy(end, s_nocar);
    else
        snprintf(end, 48, "Car: %s (%s)",
                 car->carModel < DM_NCARNAMES ? dm_car_names[car->carModel] : "-",
                 in_it ? "in it" : "last");
}

/* colour: -1 = the model's own (paletteKind SPRITE, colour 0), 0..36 car remaps
 * (seuko-mod src/game/utils/lists-utils.cpp GetAvailableCarRemapsWithPalette) */
static void color_change(const struct dm_item *it, int dir)
{
    (void)it;
    int in_it;
    Car *car = dm_car(&in_it);
    Sprite *body = car ? GP(Sprite, car->body) : 0;
    if (!body)
        return;
    int c = body->paletteKind == 2 ? -1 : body->remap;
    c = dir ? c + dir : -1;
    if (c < -1)
        c = 36;
    if (c > 36)
        c = -1;
    body->paletteKind = 3;              /* PALETTE_BASE_CAR_REMAP */
    if (c < 0) {
        body->paletteKind = 2;          /* PALETTE_BASE_SPRITE */
        c = 0;
    }
    body->remap = (short)c;
}

static void color_fmt(char *end)
{
    int in_it;
    Car *car = dm_car(&in_it);
    Sprite *body = car ? GP(Sprite, car->body) : 0;
    if (!body)
        strcpy(end, "-");
    else if (body->paletteKind == 2)
        strcpy(end, "default");
    else
        snprintf(end, 32, "%d", body->remap);
}

static void invinc_change(const struct dm_item *it, int dir)
{
    (void)it;
    (void)dir;
    int in_it;
    Car *car = dm_car(&in_it);
    if (!car)
        return;
    if ((car->flags & CAR_INVINCIBLE) == CAR_INVINCIBLE)
        car->flags &= (uint16_t)~CAR_INVINCIBLE;
    else
        car->flags |= CAR_INVINCIBLE;
}

static void invinc_fmt(char *end)
{
    int in_it;
    Car *car = dm_car(&in_it);
    strcpy(end, !car ? "-" : (car->flags & CAR_INVINCIBLE) == CAR_INVINCIBLE ? "on" : "off");
}

/* dm_repair_car: windscreen and lights back, engine damage 0, fire out (TurnOnCarLights
 * @0x425590, TurnOnCarBrakeLights @0x4213D0, FixCarBrokenEngine @0x421570, ExtinguishCar
 * @0x4BF070, all fastcall(Car* ecx))
 * From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 * src/game/functions.h, src/modules/modmenu/utils/fix-car-utils.cpp @25b1985 — the four calls. */
static void dm_repair_car(void)
{
    int in_it;
    Car *car = dm_car(&in_it);
    if (!car) {
        dm_toast_set(s_nocar);
        return;
    }
    gptr c = (gptr)(uintptr_t)car;
    car->deltasBitstate &= ~0x1Fu;
    car->damage = 0;
    if (car->engineState == 3)
        car->lightsBitstate |= 2;
    if (car->lightsBitstate & 2)
        game_fastcall(0x425590, c, 0, 0);
    if (car->lightsBitstate & 1)
        game_fastcall(0x4213D0, c, 0, 0);
    game_fastcall(0x421570, c, 0, 0);
    car->damageFireStage = 0;
    game_fastcall(0x4BF070, c, 0, 0);
    dm_toast_set("Car repaired");
}

/* dm_explode_car: ExplodeCar @0x426FA0, fastcall(Car* ecx, edx = 0; EXPLOSION_SIZE), ret 4;
 * damage >= 32001 means it already blew up
 * From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 * src/game/functions.h, src/modules/modmenu/utils/explode-last-car.cpp @25b1985 — ExplodeCar 0x426FA0. */
static void dm_explode_car(void)
{
    int in_it;
    Car *car = dm_car(&in_it);
    if (!car || car->damage >= 32001) {
        dm_toast_set(s_nocar);
        return;
    }
    game_fastcall(0x426FA0, (gptr)(uintptr_t)car, 0, 1, 0x13);  /* EXPLOSION_SIZE_MEDIUM */
    dm_toast_set("Boom");
}

DM_VALUE_FNS(carinfo);
DM_VALUE_FNS(color);
DM_VALUE_FNS(invinc);

DM_PAGE(dmp_vehicle, dmp_root, 110, "Vehicle");
DM_ITEM(dmp_vehicle, 10, DM_VALUE, "", &dmv_carinfo);
DM_ITEM(dmp_vehicle, 20, DM_VALUE, "Colour: ", &dmv_color);
DM_ITEM(dmp_vehicle, 30, DM_VALUE, "Invincible: ", &dmv_invinc);
DM_ITEM(dmp_vehicle, 40, DM_ACTION, "Repair", dm_repair_car);
DM_ITEM(dmp_vehicle, 50, DM_ACTION, "Explode", dm_explode_car);
