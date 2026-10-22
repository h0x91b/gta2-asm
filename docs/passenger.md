# Passenger mod: Shift+Enter gets in as a passenger

Vanilla GTA2 only lets the player take the driver's seat; the passenger seat is reachable
only from mission scripts. With this mod, **Shift+Enter** (either Shift) on foot gets the
player into the car in front of him as a passenger, through the game's own passenger path.
Plain Enter is unchanged, and Enter in the car gets out as usual.

- Code: `host/c32/passenger.c` (C32, the game logic), `host/c/c32_host.c` (the Shift test, the
  K menu row), `host/c/config.c` (the config key).
- Config: `mods: passenger_enter: true` (default true; `false` = the game behaves as vanilla).
  K menu → Mods → "Passenger: on / off" (the game font has no `+`).
- Log: `c32: passenger: enter car 29 (model 1, driver 0x0, 1 free seats)`, `... seated in car
  29 (model 1, driver 0x0), door 1`, `... leave car 29 ...`.
- Test: `tests/ctl/passenger.sh` (gta2ctl), and `gta2ctl enter_car ID --passenger [--key]`.

## How the game does it (RE)

Vanilla 11.44 VAs; own decompile of `gta-2-recovered` plus Seq 27's RE pass (2026-10-22).

- **No separate objective.** Driver and passenger both use objective `ENTER_CAR` (35); the seat
  is `Ped+0x248 enterCarAsPassenger` (0 / 1), and `Ped+0x24C targetCarDoor` is where the door
  search starts.
- **The script command** is `SET_CHAR_OBJECTIVE (char, ENTER_CAR_AS_PASSENGER, car)` (opcode
  132, `Script_Op_SET_CHAR_OBJECTIVE_2` 0x47A1E0): objective 35, `Ped_SetObjCar` 0x403AA0,
  `Ped_SetEnterCarAsPassenger` 0x4039B0 (1). It does not set the door. `ORDER_CHAR_TO_BACKDOOR`
  (`Ped_OrderEnterCarBackdoor` 0x43E350) is the same with the last door. There is no
  "put the player in as a passenger" opcode; `Ped_PutInCarAsPassenger` 0x433320 seats
  instantly and is only used for spawned crews.
- **The player's Enter key** (`Player_HandleControls` 0x4A76D0, on foot, Enter edge):
  `CarManager_FindEnterableCarInFront` 0x424E70 (radius 3, half a block ahead), then
  `Ped_SetTask(0)`, `Ped_SetObjective(35, or 37 for a train)`, `Ped_SetObjCar`,
  `Ped_SetEnterCarAsPassenger(0)`, `Ped_SetTargetCarDoor(0)` (call at **0x4A7793**). Same
  sequence as the script, with 0 where the script passes 1.
- **Door choice**: `Ped_FindFreeCarDoor` 0x437EC0, every tick of `Ped_Obj2_EnterCar` 0x43D1C0.
  A passenger searches from `targetCarDoor` up to the last door, then down to 0
  (`Car_IsDoorExitClear` 0x425A40: only map/obstacle clearance outside the door). Door 0/1 are
  the front pair, 1 = front passenger door. The door does not pick the seat: a passenger who
  ends up at door 0 is still a passenger.
- **No jack, no bonus**: the carjack block of `Ped_Obj2_EnterCar` runs only for the driver. At
  the end of the animation `Ped_TickGameObjectAndSeatInCar` 0x43F180 calls `Car_OnDriverEnter`
  for a driver (the car-entry bonus seam, `car_bonus.c`) and, for a passenger,
  `Car_ShowCarNameForLocalPlayer` (call at **0x43F280**) + `PedQueue_Push(&car->passengers)`.
  So the bonus is not paid (measured).
- **No capacity check** anywhere on this path (scripts can overfill a car). `CarInfo.passengers`
  (`Car_GetPassengerCapacity` 0x41FBB0, 0 when car flag 4) is the seat count without the driver.
- **In the car**: `Player_HandleControls` returns before `Player_DriveCar` when
  `Ped_IsNotPassenger` 0x4A5040 (`+0x248 != 1`) is false: a passenger cannot steer (measured:
  UP held 60 frames, the car stays put). Attack still reaches `Ped_SetFiring` (untested).
- **Exit**: the same Enter key, no seat check: `Car_CanExitCar` 0x4222A0 (|v| < 0.3, so not
  while an AI driver is moving), objective `LEAVE_CAR` 36, `Ped_SetObjCar` (call at
  **0x4A77E4**). `Ped_Obj2_LeaveCar` 0x443C30 removes a passenger from `car->passengers` and
  does not call `Car_OnDriverLeft`; the passenger gets out through its door (door 1, the other side from the driver; measured).
  It frees the car's `driveOrder` whenever any occupant leaves (vanilla).
- `+0x248` stays 1 on foot after a passenger exit until the next plain Enter (sets 0), script
  `Ped_PutInCar` 0x436070 (sets 0), or another passenger entry: vanilla behaviour after a
  scripted passenger ride, not reset by the mod.

## The mod

Three C32 call hooks (`c32_callhook`), installed at load:

| Site | Original | Hook |
|---|---|---|
| 0x4A7793 | `Ped_SetTargetCarDoor(ped, 0)`, the last call of the Enter branch | if objective is 35 (not a train), the ped is the local player and `c32_passenger_wanted()`: with ≥ 2 doors and a free seat, `Ped_SetEnterCarAsPassenger(ped, 1)` and door 1; else `Ped_SetObjective(0)` (Shift+Enter does nothing) |
| 0x43F280 | `Car_ShowCarNameForLocalPlayer` (passenger seated) | log for the local player |
| 0x4A77E4 | `Ped_SetObjCar` in the exit branch | log when the player is a passenger |

Everything else — walking to the door, the animation, seating, the HUD car name, the camera,
exiting — is the game's. The door-count guard matters: models with 0 doors (6, 55, 61, 65,
66, 72–81 in `wil.sty`) would send the passenger door search past the door table. The
seat check (`Car_GetPassengerCapacity` minus the `car->passengers` list) is the mod's own;
the game has none.

**Why the key is read on the host.** `di_keys[256]` (`w32_dinput.asm`), the DirectInput shim's
keyboard state, lives in host memory above 4 GB, out of reach of 32-bit code. The hook only
needs it on the Enter edge when a car was found, so one host service (`passenger_wanted`, a
32→64 import stub, `c32_host.c`) answers "mod on and LSHIFT or RSHIFT down" — one mode switch
per Enter press, nothing per frame. LSHIFT is not bound to a game control; RSHIFT is
control slot 11 in the default registry (`Control\11` = 0x36 in `gta2_install.reg`), which
sets `keySpecial3` (input bit 0x800) — a key nothing in 11.44 reads (Seq 27, verified; slots 9
Tab and 10 LAlt are horn/siren and camera pan). Holding it for 20 frames on foot and in a car
changed nothing (measured), so both Shifts count. `di_keys` sees a bound key either way. The
switch itself is a host byte (`mods_passenger_enter`), so the
config line is one `T_BOOL` row of `config.c`'s key table and the K menu row toggles the same
byte; no C32 export is needed.

**Off = vanilla.** With the mod off the hooks still run but call the originals with the
original arguments (the same behaviour, not the same bytes).

## Measured (2026-10-22, Downtown, 640×480, `tests/ctl/passenger.sh`)

- Parked car 29 (model 1): Shift+Enter → walks to the door, `"result":"passenger"`,
  `driver: false`, money stays $0 with `car_enter_bonus: 333`; UP held 60 frames: the car does
  not move; Enter → out through door 1 (x 129.5, the driver gets out at 130.5).
- Plain Enter on the same car: driver, +$333 (bonus works as before).
- AI-driven cars stopped in traffic (three runs: car 85 model 63, car 97 model 8, car 106
  model 0): `enter_car ID --passenger` → passenger, no jack; the AI driver drives on with the
  player aboard (car 106: (136.5, 194.7) → (132.7, 204.4)); the camera follows the car.
- `passenger_enter: false`: Shift+Enter → driver's seat (vanilla).
- Not tested: a mission that seats the player as a passenger, cops and wanted level while
  riding, firing from the passenger seat. `THREAD_WAIT_FOR_CHAR_IN_CAR` script threads start
  from `Car_OnDriverEnter` (docs/re/script-engine.md), so a mission waiting for the player to
  get into a car does not see a passenger entry (Seq 27, not run).
