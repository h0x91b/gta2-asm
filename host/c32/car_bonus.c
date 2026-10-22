/* car_bonus.c — mod: money every time the local player gets into a car as the driver.
 *
 * Seam: Car_OnDriverEnter(Car* this, Ped*) @0x427A20, thiscall, ret 4 — the only function
 * that makes a ped a car's driver. Callers: 0x43F279 Ped_UpdatePosition (end of the
 * enter-car animation, driver branch: an empty car and a jacked one alike) and 0x4A63A3
 * Player_TakeControlOfCar (remote control, the player's aux ped). Seq 27's RE (Ghidra
 * gta-2-recovered) and own disassembly; names from re/functions.csv. Detoured at its entry.
 *
 * Off by default: config.yaml `mods: car_enter_bonus: N` (0 = off) or the K menu's Mods
 * page. Paid through ChangeMoney (a raw add; the HUD counter rolls up as usual).
 */
#include "c32.h"

/* the fields used below, at the offsets checked in the disassembly */
C32_OFFSET(Game, currentPlayer, 0x38);
C32_OFFSET(Player, ped, 0x2C4);
C32_OFFSET(Player, score, 0x2D4);
C32_OFFSET(PlayerScore, money, 0x0);
C32_OFFSET(AnimatedValue, value, 0x0);
C32_OFFSET(Ped, player, 0x15C);
C32_OFFSET(Car, driver, 0x54);
C32_OFFSET(Car, id, 0x6C);
C32_OFFSET(Car, carModel, 0x84);

/* Three conventions, three examples (addresses: re/functions.csv; bodies: disassembly).
 * ChangeMoney: `add ecx, 0x2D4; jmp PlayerScore_AddMoney`. Player_IsLocal: `mov al, [ecx];
 * ret` — only al is set, hence uint32_t and the mask at the call. The cdecl example is
 * the CRT's vsprintf in c32.h. */
GAME_FN(void, G2_THISCALL, ChangeMoney, 0x421990, (Player *self, int amount));
GAME_FN(uint32_t, G2_FASTCALL, Player_IsLocal, 0x41DC70, (Player *self));

typedef void (G2_THISCALL *driver_enter_fn)(Car *self, Ped *ped);
static driver_enter_fn Car_OnDriverEnter;  /* the original, through the detour's trampoline */

uint32_t car_bonus;                 /* dollars per entry, 0 = off; set by the host */
C32_EXPORT(car_bonus);

/* Replaces Car_OnDriverEnter: same type, so the game jumps straight in, no mode switch. */
static void G2_THISCALL hk_driver_enter(Car *car, Ped *ped)
{
    Ped *before = car->driver;
    Car_OnDriverEnter(car, ped);
    if (!car_bonus || !ped)
        return;
    Player *player = ped->player;
    if (!player || !(Player_IsLocal(player) & 0xFF))
        return;                         /* an AI ped, or another network player */
    if (player->ped != ped)
        return;                         /* the aux ped: remote-control takeover */
    if (car->driver != ped || before == ped)
        return;                         /* not the driver after all, or already was */
    int money = player->score.money.value;
    ChangeMoney(player, (int)car_bonus);
    c32_log("car_enter_bonus +$%u: car %u (model %u), previous driver 0x%x, "
            "money %d -> %d", car_bonus, car->id, (unsigned)car->carModel,
            (uint32_t)before, money, player->score.money.value);
}

static void car_bonus_init(void)
{
    static const uint8_t orig[] = { 0x53, 0x8B, 0x5C, 0x24, 0x08 }; /* push ebx; mov ebx,[esp+8] */
    Car_OnDriverEnter = (driver_enter_fn)c32_detour(0x427A20, orig, sizeof orig,
                                                    (void *)hk_driver_enter);
}
C32_INIT(car_bonus_init);
