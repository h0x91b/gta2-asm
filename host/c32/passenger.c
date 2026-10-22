/* passenger.c — mod: Shift+Enter on foot gets the player into the car in front of him as a
 * passenger (docs/passenger.md).
 *
 * The game already has the whole passenger path; only the key is missing. The player's
 * enter key (Player_HandleControls 0x4A76D0, on foot) finds the car with
 * CarManager_FindEnterableCarInFront and then does exactly what SET_CHAR_OBJECTIVE (char,
 * ENTER_CAR_AS_PASSENGER, car) does in a mission script (Script_Op_SET_CHAR_OBJECTIVE_2
 * 0x47A1E0): objective ENTER_CAR (35), Ped_SetObjCar, Ped_SetEnterCarAsPassenger — with 0
 * where the script passes 1. So the hook flips that one flag when Shift is held, and the
 * game's own objective, door search (Ped_FindFreeCarDoor 0x437EC0), animation, seat
 * (Car.passengers) and exit run unchanged. In the car Player_HandleControls skips
 * Player_DriveCar for a passenger (Ped_IsNotPassenger 0x4A5040 = flag != 1). Own analysis of
 * the Ghidra decompile (gta-2-recovered), names from re/functions.csv.
 *
 * Seams (call hooks, all three only log or change the passenger case):
 *   0x4A7793  Player_HandleControls, enter branch: call Ped_SetTargetCarDoor(ped, 0), the
 *             last call after Ped_SetEnterCarAsPassenger(ped, 0)
 *   0x43F280  Ped_TickGameObjectAndSeatInCar, end of the enter animation, passenger branch (the driver
 *             branch is Car_OnDriverEnter, car_bonus.c): call Car_ShowCarNameForLocalPlayer
 *   0x4A77E4  Player_HandleControls, exit branch (after Car_CanExitCar): call Ped_SetObjCar
 *
 * Toggle: config.yaml `mods: passenger_enter` (default on) and the K menu's Mods page, both
 * host side; the host service c32_passenger_wanted answers "on and a Shift held".
 */
#include "c32.h"

C32_OFFSET(Ped, objectiveTargetCar, 0x150);
C32_OFFSET(Ped, player, 0x15C);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(Ped, id, 0x200);
C32_OFFSET(Ped, enterCarAsPassenger, 0x248);
C32_OFFSET(Ped, targetCarDoor, 0x24C);
C32_OFFSET(Ped, objective, 0x258);
C32_OFFSET(Player, ped, 0x2C4);
C32_OFFSET(PedListNode, next, 0x4);
C32_OFFSET(Car, passengers, 0x4);
C32_OFFSET(Car, driver, 0x54);
C32_OFFSET(Car, id, 0x6C);
C32_OFFSET(Car, carModel, 0x84);

#define OBJ_ENTER_CAR 35                /* PED_OBJECTIVE_ENTER_CAR; trains use 37 */

GAME_FN(void, G2_THISCALL, Ped_SetEnterCarAsPassenger, 0x4039B0, (Ped *self, int on));
GAME_FN(uint32_t, G2_FASTCALL, Player_IsLocal, 0x41DC70, (Player *self));
/* mov al, [ecx+0x84]; ... CarInfo_GetDoorInfo(model)[0]: the number of doors, in al */
GAME_FN(uint32_t, G2_FASTCALL, Car_GetDoorCount, 0x41F880, (Car *self));
/* Car_GetPassengerCapacity: CarInfo.passengers in al, 0 when car flag 4 is set */
GAME_FN(uint32_t, G2_FASTCALL, Car_GetPassengerCapacity, 0x41FBB0, (Car *self));
/* thiscall(Ped*, objective, timer), callee pops 8 (Seq 27; call site 0x4A7828) */
GAME_FN(void, G2_THISCALL, Ped_SetObjective, 0x43BBC0, (Ped *self, int objective, int timer));

typedef void (G2_THISCALL *set_door_fn)(Ped *self, int door);
typedef void (G2_THISCALL *show_name_fn)(Car *self, Ped *ped);
typedef void (G2_THISCALL *set_obj_car_fn)(Ped *self, Car *car);
static set_door_fn Ped_SetTargetCarDoor;                /* 0x403A70 */
static show_name_fn Car_ShowCarNameForLocalPlayer;      /* 0x423590 */
static set_obj_car_fn Ped_SetObjCar;                    /* 0x403AA0 */

static int is_local_player(Ped *ped)
{
    Player *player = ped ? ped->player : 0;
    return player && (Player_IsLocal(player) & 0xFF) && player->ped == ped;
}

/* free passenger seats: CarInfo.passengers (the driver not counted; 0 with car flag 4,
 * Car_GetPassengerCapacity) minus the peds on Car.passengers. The game's own enter path
 * checks neither (Seq 27), so a script can overfill a car; Shift+Enter does not. */
static int free_seats(Car *car)
{
    int n = (int)(Car_GetPassengerCapacity(car) & 0xFF);
    for (PedListNode *p = car->passengers; p; p = p->next)
        n--;
    return n;
}

/* 0x4A7793: the enter key found a car; the game has just set objective ENTER_CAR, the
 * target car and passenger = 0, and now sets door 0 */
static void G2_THISCALL hk_set_door(Ped *ped, int door)
{
    Car *car = ped->objectiveTargetCar;
    if (car && ped->objective == OBJ_ENTER_CAR && is_local_player(ped) && c32_passenger_wanted()) {
        unsigned doors = Car_GetDoorCount(car) & 0xFF;
        int seats = free_seats(car);
        if (doors < 2 || seats <= 0) {
            /* no passenger door (bikes, doorless models: the door search would read past
             * the door table) or no free seat: Shift+Enter does nothing */
            Ped_SetObjective(ped, 0, 9999);
            c32_log("passenger: car %u (model %u) has %u doors, %d free seats: not entering",
                    car->id, (unsigned)car->carModel, doors, seats);
        } else {
            Ped_SetEnterCarAsPassenger(ped, 1);
            /* where the door search (Ped_FindFreeCarDoor) starts: up from here, then back
             * down to 0; door 1 is the front passenger door (Ped_PutInCarAsPassenger and
             * the bus code use it too) */
            door = 1;
            c32_log("passenger: enter car %u (model %u, driver 0x%x, %d free seats)",
                    car->id, (unsigned)car->carModel, (uint32_t)car->driver, seats);
        }
    }
    Ped_SetTargetCarDoor(ped, door);
}

/* 0x43F280: a passenger has just sat down (any ped; log only the player) */
static void G2_THISCALL hk_seated(Car *car, Ped *ped)
{
    Car_ShowCarNameForLocalPlayer(car, ped);
    if (is_local_player(ped))
        c32_log("passenger: seated in car %u (model %u, driver 0x%x), door %u",
                car->id, (unsigned)car->carModel, (uint32_t)car->driver,
                (unsigned)ped->targetCarDoor);
}

/* 0x4A77E4: the player's exit key, the car is slow enough; objective LEAVE_CAR is set */
static void G2_THISCALL hk_exit(Ped *ped, Car *car)
{
    Ped_SetObjCar(ped, car);
    if (ped->enterCarAsPassenger == 1 && car)
        c32_log("passenger: leave car %u (model %u, driver 0x%x)", car->id,
                (unsigned)car->carModel, (uint32_t)car->driver);
}

static void passenger_init(void)
{
    Ped_SetTargetCarDoor = (set_door_fn)c32_callhook(0x4A7793, 0x403A70, (void *)hk_set_door);
    Car_ShowCarNameForLocalPlayer =
        (show_name_fn)c32_callhook(0x43F280, 0x423590, (void *)hk_seated);
    Ped_SetObjCar = (set_obj_car_fn)c32_callhook(0x4A77E4, 0x403AA0, (void *)hk_exit);
}
C32_INIT(passenger_init);
