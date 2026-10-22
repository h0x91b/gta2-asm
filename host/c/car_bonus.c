/* car_bonus.c — demo mod: money every time the player gets into a car as the driver.
 *
 * Seam: Car_OnDriverEnter(Car* this, Ped*) @0x427A20 (thiscall, ret 4), the game's own
 * "a ped is now this car's driver" step (it shows the car's name, hands over the
 * player's car weapons, records the last player driver). Its two callers are call-hooked
 * in w32_hooks.asm; host/mods.asm runs the original and then calls
 * c_on_driver_enter here:
 *   0x43F279 Ped_UpdatePosition, the end of every enter-car animation, taken when
 *            Ped.enterCarAsPassenger (+0x248) is 0 — an empty car and a jacked one alike
 *   0x4A63A3 Player_TakeControlOfCar
 * Own disassembly of gta2.exe 11.44; function names from re/functions.csv.
 *
 * Off by default: config.yaml `mods: car_enter_bonus: N` (0 = off) or the K menu's Mods
 * page. The money goes through the game's ChangeMoney, so the HUD counter rolls up and
 * the score updates the usual way.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "game.h"

#define BONUS_DEFAULT   333
#define BONUS_MAX       1000000
#define DEBOUNCE_FRAMES 30              /* the same car again within half a second = one entry */

int32_t car_bonus_amount = BONUS_DEFAULT;   /* the configured amount */
uint8_t car_bonus_on;                       /* 0 = vanilla */

static gptr last_car;
static uint32_t last_frame;

void c_on_driver_enter(gptr car, gptr ped, gptr site)
{
    if (!car_bonus_on || !car || !ped)
        return;
    gptr player = game_player();
    if (!player || rd32(ped + PED_PLAYER) != player || rd32(player + PLAYER_PED) != ped)
        return;                             /* not the local player's ped */
    if (rd32(car + CAR_DRIVER) != ped) {    /* not the driver seat after all */
        printf("mods: car_enter_bonus: 0x%x enters car %u but driver is 0x%x, skipped\n",
               ped, rd32(car + CAR_ID), rd32(car + CAR_DRIVER));
        return;
    }
    if (car == last_car && r_frames - last_frame < DEBOUNCE_FRAMES)
        return;
    last_car = car;
    last_frame = r_frames;

    int32_t before = player_money(player);
    ChangeMoney(player, car_bonus_amount);
    printf("mods: car_enter_bonus +$%d: car %u (model %u) via 0x%x, money %d -> %d, frame %u\n",
           car_bonus_amount, rd32(car + CAR_ID), rd32(car + CAR_MODEL), site, before,
           player_money(player), r_frames);
}

/* config.asm, `mods:` section: 0 applied, 1 unknown key, -1 bad value (*msg = why) */
int c_cfg_mods(const char *key, const char *val, const char **msg)
{
    if (strcmp(key, "car_enter_bonus") != 0)
        return 1;
    char *end;
    long v = strtol(val, &end, 10);
    if (end == val || *end || v < 0 || v > BONUS_MAX) {
        *msg = "mods.car_enter_bonus: expected dollars, 0 (off) .. 1000000";
        return -1;
    }
    car_bonus_on = v != 0;
    if (v)
        car_bonus_amount = (int32_t)v;
    printf("config: mods.car_enter_bonus = %ld%s\n", v, v ? "" : " (off)");
    return 0;
}

/* K menu value row (host/menu/mods.asm, DM_VALUE): any key toggles on / off */
void c_carbonus_change(void *item, int dir)
{
    (void)item;
    (void)dir;
    car_bonus_on ^= 1;
}

/* writes the row's value after its label; the menu leaves 32 bytes there */
void c_carbonus_fmt(char *end)
{
    if (car_bonus_on)
        snprintf(end, 32, "$%d", car_bonus_amount);
    else
        snprintf(end, 32, "off");
}
