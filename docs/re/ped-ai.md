# Ped AI in gta2.exe 11.44: objectives, tasks, states, flags

How a GTA2 ped decides what to do each tick: the two AI slots (objective and task), the
`PED_OBJECTIVE` values and their handlers, the `(state, state2)` pair, `PED_FLAGS` and
`PED_CLASS`. Ped movement itself (the walker, collision) is in
[ped-movement-collision.md](ped-movement-collision.md); groups, gangs and ped spawning are in
[gangs-and-peds.md](gangs-and-peds.md).

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`); every name is in the Ghidra
DB (`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and therefore in `re/`.
"verified" = writer and reader seen in code (or a script opcode mapping); names with `UNSURE_` /
`unsure_` are hypotheses. Source: Seq 27 Ped AI pass (six read-only slices, 2026-10-21).

## 1. Two AI slots: objective and task

A ped carries two goals that share one enum, `PED_OBJECTIVE`:

| | objective | task |
|---|---|---|
| field | `Ped+0x258 objective` | `Ped+0x25C task` |
| set by | `Ped_SetObjective` 0x43BBC0 | `Ped_SetTask` 0x436920 |
| timer | `+0x218 objectiveTimer` | `+0x21A taskTimer` |
| result | `+0x225 objectiveStatus` | `+0x226 taskStatus` |
| targets | `+0x148` ped, `+0x150` car, `+0x1A0` object, `+0x1DC` position | `+0x14C`, `+0x154`, `+0x1A4`, `+0x1D0` |
| derived point | `+0x1B8 goalPosition` | `+0x1C4 moveTarget` |
| dispatcher | `Ped_RunObjective` 0x443170, handlers `Ped_Obj1_*` | `Ped_RunTask` 0x444D00, handlers `Ped_Obj2_*` / `Ped_Task_*` |

The objective is the high-level goal (script- or AI-given). The task is the step the objective
handler hands to itself, for example objective `ENTER_CAR` sets task `ENTER_CAR` and waits for
its result. Status values are `PED_GOAL_STATUS`: 0 running, 1 passed, 2 failed. Script ops
`IS_CHAR_OBJECTIVE_PASSED`/`FAILED` read `objectiveStatus` == 1 / 2.

- `Ped_UpdateAI` 0x445330 is the live caller: occupation behaviour, group code, then both
  dispatchers, then the timers. `Ped_RunObjectives` 0x4454D0 (`call 0x443170; jmp 0x444D00`) is
  the same pair on the `Ped_Update` path for peds that are not AI-driven.
- `Ped_RunObjective` runs only while `objective != 0 && objectiveStatus == 0`; `Ped_RunTask` only
  while `task != 0 && taskStatus == 0`. A finished objective sits there until replaced.
- Timers: 9999 means "no timeout". `objectiveTimer` counts down, except for objectives 13, 14, 19
  and 31, where it counts up as an elapsed counter. `taskTimer` counts down unless 9999.
- Before the switch, both dispatchers compute the goal point from the targets (ped position;
  for objectives 18 and 35..38 the target car's door position; else the car body; else the
  object; else the stored position) and the Chebyshev distance to it.

**Script numbering is the enum.** `ScriptThread_SetCharObjective` 0x4751F0 passes the script's
16-bit objective straight to `Ped_SetObjective` (timer 9999) and clears `PED_FLAG_REMOVAL_REQUESTED`.
DMA's objective names (`tools/formats/scr-consts.ts` `OBJECTIVES[]`) index the enum 1:1;
`ENTER_CAR_AS_DRIVER` and `ENTER_CAR_AS_PASSENGER` are both 35, told apart by
`Ped+0x248 enterCarAsPassenger`. The script table stops at 59: 37, 38, 43..54, 60 and 61 are
internal values the script cannot name (it can still set them by number).

## 2. PED_OBJECTIVE values

Slot: O = used as objective, T = used as task. "No setter" = no game code writes it (scripts can).

| val | name | slot | set by (examples) | notes |
|---|---|---|---|---|
| 0 | NO_OBJ | O,T | everywhere | |
| 1-3 | FLEE_ON_FOOT_TILL_SAFE, FLEE_CHAR_ON_FOOT_TILL_SAFE, FLEE_CHAR_ON_FOOT_ALWAYS | O,T | mugger, bus/taxi passengers, threats, burning | |
| 4, 5 | FLEE_CHAR_ANY_MEANS_TILL_SAFE / _ALWAYS | O | script only | **no handler**: the ped just stands |
| 6 | FLEE_CHAR_ALWAYS_ONCE_CAR_STOPPED | O | Elvis handling, taxi passenger | waits for speed 0, leaves car, then 3 |
| 7 | RUN_TO_GROUP_LEADER | T | `PedGroup_ReactToAttacker`, `Ped_UpdateThreats` (member far from leader) | |
| 8 | GROUP_WAIT_FOR_LEADER | O | `PedGroup_UpdateMember` (leader is in a car) | when the leader is on foot and near, task 9 |
| 9 | FOLLOW_GROUP_LEADER | T | `PedGroup_MakeMembersFollowLeader`, `UpdateMemberNearLeader` | |
| 10, 11, 15, 22 | UNSURE_* | | **no setter found** | handlers exist (drive to char, go to ped until gone, follow path route, done when timer zero) |
| 12-14, 16 | GO_TO_AREA_ON_FOOT, GO_TO_AREA_ANY_MEANS, GO_TO_AREA_IN_CAR, GO_TO_CHAR_ON_FOOT | O,T | police, fire engine, ambulance | 13 picks walk vs. car and spawns subtasks 12/14/26 |
| 17 | WALK_TO_NEARBY_TILE | T | `PedGameObject_StateWalk` | one wander step |
| 18 | GO_TO_CAR_DOOR_SPOT | T | `PedGroup_UpdateEnterCar` | |
| 19, 20, 23 | KILL_CHAR_ANY_MEANS, KILL_CHAR_ON_FOOT, BEAT_OR_ROB_CHAR | O,T | threats, groups, police, mugger | |
| 21 | KILL_CHAR_IN_CAR | O | script only (takes a car) | **no handler** |
| 24-27 | GUARD_SPOT, GUARD_AREA, WAIT_ON_FOOT, WAIT_IN_CAR | O,T | roadblock guard (24), char spawn default (26), police (27) | |
| 28 | WAIT_FOR_AMBULANCE | O | `Ped_OnDeath` | the only objective accepted while WASTED; enqueues the corpse with the ambulance manager |
| 29, 30 | WAIT_FOR_TRAIN_AT_STOP, WAIT_FOR_BUS_AT_STOP | T | `Ped_TryStartPublicTransportTask` (map block type 6 / 7) | 30 has no task handler: the bus code takes over |
| 31 | RIDE_IN_CAR_AS_PASSENGER | O | taxi passenger, car thief, bus passenger | timer counts up; taxi leaves after 150 ticks |
| 32 | GO_TO_CHAR_CAR_DOOR | O,T | police crew (foot cop to a criminal in a car) | walks to a free door of the target's car |
| 33 | EJECT_FROM_CAR_AND_FALL | O | objective 54 on timer expiry | leaves the car and falls (state 8 / 0x11) |
| 34 | ABANDON_CAR | O | `PedGroup_Disband`, `PedList_OrderBusPassengersAbandonCar` | waits for speed 0, leaves, flees |
| 35-38 | ENTER_CAR, LEAVE_CAR, ENTER_TRAIN, LEAVE_TRAIN | O,T | script, player controls, transport, police | |
| 39-41, 53 | UNUSED_* | | nowhere | no handler, no compare |
| 42 | PATROL_ON_FOOT | O | script `ADD_PATROL_POINT` | allocates a patrol route |
| 43 | UNSURE_PATROL_IN_CAR | O | `PoliceManager_AdoptTrafficCarAsCrew` | writes CarAI+0x74 target speed 1.0; `CarAI_UpdateDriveOrder` 0x42D390 overwrites it with `driver->carSpeed` every tick while a drive order exists |
| 44-47 | WAIT_AT_CURB_TO_CROSS_{NEG_Y,POS_X,POS_Y,NEG_X} | T | `Ped_StartCrossingRoadIfAtCurb` (dummy peds) | wait for the crossing light, find pavement up to 6 tiles away |
| 48, 49 | CROSS_ROAD, PAUSE_AFTER_CROSSING | T | 44-47 handlers, 48 handler (timer 100) | |
| 50 | FORCE_WASTED | O | `AmbulanceManager_DispatchForQueuedPed` | `Ped_SetObjective` sets (9, 0xF) at once |
| 51 | UNSURE_FAIL_WHEN_TIMER_ZERO | O | no setter | |
| 52 | DRIVE_AND_ATTACK_CHAR | O,T | police crew | `CarDriveOrder`; the 3.0 it writes to CarAI+0x74 is overwritten each tick by `driver->carSpeed` |
| 54 | BUSTED_TAKEN_AWAY_IN_COP_CAR | O | `Player_OnBusted` (timer 60) | spawns a COPCAR, ped rides as passenger, then 33 |
| 55-60 | FOLLOW_CAR_IN_CAR, FOLLOW_CAR_ON_FOOT_WITH_OFFSET, FIRE_AT_OBJECT_FROM_VEHICLE, DESTROY_OBJECT, DESTROY_CAR, PUT_OUT_CAR_FIRE | O | script; 60 from `FireEngineSlot_Update` | |
| 61 | UNSURE_FIRE_TURRET_AT_CHAR | O | `Ped_UpdateTankDriver` (occupation TANK_DRIVER) | handler `Ped_Obj1_FireTurretAtChar` 0x434530 |

The 11.44 patch hooks the objective-61 handler: bytes 0x43454E..0x434559 are
`fxsave [0x676000]; jmp 0x3F1004`, so Ghidra's decompile of that function is incomplete.

The police crew code at 0x4AC0xx..0x4AD5FF (sets 32, 35, 36, 43, 52) has no Ghidra function yet.

## 3. The state pair

`Ped+0x278 state` (`PED_STATE`, 0..10) and `Ped+0x27C state2` (`PED_STATE2`, sub-state) are mirrored
into `PedGameObject+0x8/+0xC` each tick, and `PedGameObject_Tick` 0x49C460 dispatches the body on
`state`. Most writes go through `Ped_SetStatePreset` 0x433580, which picks one of 7 pairs from the
objective/task value (`Ped_SetObjective`, `Ped_SetTask`, `Ped_SetStatesFromObjective` 0x433650):

| preset | (state, state2) | used for |
|---|---|---|
| 1 | (WALK, WALKING) | no objective on foot, 8, 22, 49, 51 |
| 2 | (PURSUE_OR_FLEE, FLEE) | 1-3 |
| 3 | (PURSUE_OR_FLEE, PURSUE) | 7, 9, 11, 12, 16-18, 20, 23, 32, 48, 56, 58, 59 |
| 4 | (STAYING, STAYING_IDLE) | 24-26, 29, 30, 44-47 |
| 5 | (DRIVING_A_CAR, IN_CAR) | 14, 27, 31, 43, 52, 54, 55, 57, 60, 61; no objective while in a car |
| 6 | (ENTERING_CAR, APPROACH_CAR_DOOR) | 35, 37 |
| 7 | (LEAVING_CAR, IN_CAR) | 36, 38 when the ped has no body |

`FALL_ON_GROUND` (8) is the "down" state: its `state2` says why (0x11 thrown out of a car,
0x13 falling, 0x14 drowning, 0x16 knocked down, 0x18/0x19/0x1A flung by a car or blast and
surviving / knocked down / dying, 0x1B electrocuted), and `PedGameObject_StateFallOnGround`
0x496880 runs all of them. While a ped is down, `Ped_SetState`/`Ped_SetState2` do not change the
state: they park the request in `+0x280 savedState` / `+0x284 savedState2`, and
`Ped_RestoreSavedState` 0x433300 applies it when the body stands up. `Ped_Init` stores 11 / 0x1C
there as "nothing saved" sentinels.

`Ped_TickLifecycle` 0x43ECC0 (formerly `Ped_UpdateState`) is not the state machine: it is the
per-class offscreen/despawn tick, plus the player's WALK/STAYING toggle.

The knockdown meter: `Ped_UpdateKnockdownMeter` 0x435CE0 (every tick from `Ped_Update`) drops the
ped to (8, 0x1B ELECTROCUTED) when `+0x210 knockdownMeter >= +0x212 knockdownThreshold`, decays
the meter, and for a ped with `PED_FLAG_ELECTROFINGERS` runs `Weapon_TaserFindTarget`.

## 4. PED_FLAGS (Ped+0x21C)

Bits that were misnamed before this pass, or whose meaning is not obvious from the name:

| bit | name | evidence |
|---|---|---|
| 0x4 | ENGAGED | busy with a threat; `Ped_UpdateAI` skips the group/AI step |
| 0x8 | UNSURE_NO_HALT_ON_RUNOVER | the driver does not stop after running a ped over (fire engines, car thieves) |
| 0x10 | STAY_IN_CAR | script `SET_CHAR_TO_STAY_IN_CAR` (384) |
| 0x20 | ARRESTED | read by `HAS_CHAR_BEEN_ARRESTED`; set by a cop beating a player ped, cleared in `Player_OnBusted` |
| 0x80 | USE_CAR_WEAPON | script 385; turret objectives |
| 0x100 | ZAPPED | held by an electro-gun beam, cleared each tick |
| 0x10000 | PATH_STEP_TAKEN | one pathfinder step per tick for all peds (round-robin budget) |
| 0x80000 | THREAT_SCAN_DONE | one line-of-sight threat scan per tick (round-robin) |
| 0x800000 | SPOTTED_PLAYER | read by `HAS_CHAR_SPOTTED_PLAYER` through `Ped_HasSpottedPlayer`; cleared each tick |
| 0x4000000 | ELECTROFINGERS | power-up 9 |
| 0x20000000 | TAXI_EXIT_REQUESTED | taxi passenger must leave |

Unused bits: 0x2, 0x1000, 0x40000, 0x100000, 0x200000, 0x40000000, 0x80000000. Bit 0x40 is tested
by `Ped_Obj1_GoToAreaAnyMeans` but never set.

## 5. PED_CLASS (Ped+0x238, also Car+0x7C driverClass)

2 PLAYER, 3 AMBIENT, 4 UNSURE_CREW (manager-spawned role peds: cops, medics, firemen, gang members),
5 MISSION, 6 UNSURE_DRIVER_NPC (gang, thief, ejected drivers). 0 and 1 are never used.
`Ped_PutInCar` copies the class into the car. The old enum `PED_BIT_STATE2` was the same set.

## 6. Ped fields resolved in this pass

| offset | name | meaning |
|---|---|---|
| 0x138 | bumpPartnerObject | `PedGameObject` of the ped this one is blocking (mutual link) |
| 0x178 | carWeapon | weapon created by `CarAddWeapon` for a non-player driver; `Ped_Remove` only zeroes it (possible weapon-slot leak) |
| 0x198 | zapTargetPed | electro-gun victim |
| 0x1E8 | guardEngageRange | read by `GUARD_AREA`, never written (always 0) |
| 0x20C | targetLostTicks | > 15 ticks out of sight: give up the task |
| 0x220 | lastHurtSpeechFrame | throttles the hurt cry to once per 6 frames |
| 0x224 | behaviourBits | 0x4 bump partner, 0x10 "waiting near target" latch, 0x20 weapon drop pending |
| 0x228, 0x229 | meleeHitCount, robberyTicks | melee victim counter (write-only), mugger robbing the player |
| 0x22C, 0x230 | attitude (write-only), aggression | 1 passive / emergency, 2 aggressive |
| 0x250 | pendingSpeechEvent | speech/sound event id, consumed by the sound manager |
| 0x254 | groundMaterial | lid tile material under the ped, for footsteps |
| 0x260 | waitTicks | |
| 0x268 | zapHoldTicks | set to 20, never read |

Game+0x20..0x22: `playerIterCursor`, `cameraIterPlayer`, `cameraIterAux` (iterator state of
`Game_FirstActivePlayer`/`NextActivePlayer` and `Game_CameraIter_Begin`/`Next`).

## 7. Open questions

- Objectives 10, 11, 15, 22 and 51 have handlers but no setter in game code: dead, or script-only.
- `PED_CLASS` 4 and 6 names are guesses that fit every writer.
- `PedGameObject+0x10` (movement sub-state: 0xF jump, 0x24 entering a car) and `+0x6C` (body
  animation state, 5 = jump) are not decoded; the old `PED_STATE4` enum was meant for `+0x6C`.
