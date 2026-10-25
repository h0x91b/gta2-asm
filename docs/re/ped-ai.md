# Ped AI in gta2.exe 11.44: objectives, tasks, states, flags

How a GTA2 ped decides what to do each tick: the two AI slots (objective and task), the
`PED_OBJECTIVE` values and their handlers, the `(state, state2)` pair, `PED_FLAGS` and
`PED_CLASS`, and the on-foot pathfinder that serves the "go to" objectives (§8). Ped movement
itself (the walker, collision) is in [ped-movement-collision.md](ped-movement-collision.md); groups,
gangs and ped spawning are in [gangs-and-peds.md](gangs-and-peds.md).

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
the meter, and for a ped with `PED_FLAG_ELECTROFINGERS` runs `Ped_ElectroFingersZap` 0x4CEF40
(call at 0x435D6E).

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
| 0x4000 | PATH_REQUEST_PENDING | ped is in the pathfinder request queue (§8) |
| 0x10000 | PATH_STEP_TAKEN | one pathfinder step per tick for all peds (round-robin budget) |
| 0x20000 | PATH_FAILED | the search gave `path[0]` = (0,0): the ped steers straight (PURSUE) (§8) |
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

- Pathfinder questions: §8 "Still unknown".

- Objectives 10, 11, 15, 22 and 51 have handlers but no setter in game code: dead, or script-only.
- `PED_CLASS` 4 and 6 names are guesses that fit every writer.
- `PedGameObject+0x10` (movement sub-state: 0xF jump, 0x24 entering a car) and `+0x6C` (body
  animation state, 5 = jump) are not decoded; the old `PED_STATE4` enum was meant for `+0x6C`.

**Ped prototypes for hooks (pass 5, V unless marked).** 259 of 308 `Ped_*` prototypes had `undefined*` returns or
`param_N`; they are now `__thiscall` with `this` in ECX and custom-storage returns (EAX/AX/AL).

- **The 16 handlers take no EDX parameter.** `Ped_Obj1_{EnterTrain, PatrolOnFoot, DestroyObject, EnterCar,
  LeaveCar, LeaveTrain, EjectFromCarAndFall, BustedTakenAwayInCopCar}` and `Ped_Update{Mugger, TrainPassenger,
  Threats, CarThief, TaxiPassenger, BusPassenger, EjectedDriver, OccupationBehaviour}` were typed
  `fastcall(Ped*, uint param_2 @EDX)`; all are `void __thiscall (Ped* this)`, RET 0, and the first EDX mention in
  each body is a write. A hook that expects an EDX argument is wrong.
- **Wrong old returns.** `Ped_ShouldReactToPed` 0x4371D0 returned `Ped*` but is `bool (Ped* other)` (low byte only);
  `Ped_AreAllied` 0x4462F0 is `bool __stdcall (Ped* a, Ped* b)`, both on the stack, no `this`; `Ped_CreateSprite`
  0x4360C0 is `bool (Fix16 x, y, z)`; `Ped_GetZ` 0x416B50 is `Fix16* (Ped*, Fix16* out)` and returns `out`
  (RET 4); the rotation / move-target / aim / speed getters are `Ang16*` / `Fix16* out` and return `out`;
  `Ped_UpdateAimRotation` 0x43E3A0 is `Ang16* (Ang16* out)` (`Weapon_FireSmg` 0x4CE4DE does `MOV CX,[EAX]` on
  the result); `Ped_JitterAimRotation` 0x43ABA0 is `void (WEAPON_STRUCT* weapon)` (EDX unused);
  `Ped_InitAsGroupMemberCloneOf` 0x4402C0 is `void (Ped* this, Ped* leader, WEAPON_INDEX weapon)`, RET 8;
  `Ped_IsGroupmateOrCopOfGroup` 0x434BA0 is `bool (Ped*, PedGroup* group)`; the first parameter of 0x403940 is
  `byte groupSlot` (RET 4, one parameter).
- **Renames (wrong `this` type or wrong meaning).** `Ped_GetPosX` 0x436160 → `Ped_GetSpeed(Fix16* out)`: it calls
  `Sprite_GetSpeed(gameObject)` / `Car_GetFrameDisplacementLength(currentCar)` / ZERO (22 callers); X is
  `Ped_GetX` 0x403A00, and `Ped_GetSpriteSpeed` 0x433C20 is the same without the car fallback.
  `Ped_ResolveSpriteObstacle` 0x499F00, `Ped_ReactToPedObstacle` 0x494280, `…ToObjectObstacle` 0x4993B0,
  `…ToCarOrObjectObstacle` 0x4948C0 → `PedGameObject_*` (`this` is the PedGameObject: `path[]` at go+0x10/0x18/0x20/0x69,
  ped at +0x7C, body at +0x80). `Ped_ElvisHandling` 0x403FB0 → `PedGroup_ElvisHandling(PedGroup* this, Ped* killer)`,
  `RET 4`: callers `Ped_Remove` 0x43E7B8 / 0x43E7CF and `Ped_OnDeath` 0x4412AF set `ECX = [ped+0x164]` (Ped.group) and
  push `[ped+0x1A8]` (killer); the body reads `+0x2C` = PedGroup.leader. The old signature had a bogus 3rd
  parameter.
- **Name hazards.** Two functions were called `Ped_GetId` (0x420B60 and 0x4C4F20, byte-identical
  `MOV EAX,[ECX+0x200]; RET`); the `re/` export and the NASM `.inc` would collide, so 0x4C4F20 is now
  `Ped_GetIdTwin` (V, Ghidra; 5 references vs 18 to 0x420B60). `Ped_IsPlayerWithOccupation` 0x433380 takes no
  occupation: it returns `pedClass == PLAYER && occupation != 1` (name misleading, kept). `Ped_TakeTrainStop`
  0x4117D0 and `…2` 0x4117F0 are byte-identical read-and-clear of Ped+0x13C. `Ped_SetGameObjectField3C` 0x403A50
  only typed (writes `walkSpeedTarget`), not renamed.
- **Still untyped** (`unsure_argN`): `Ped_OnProjectileMissed`, `AddPatrolPoint` (3 bytes, probably an `S3Bytes`
  x,y,z), `TakeDamage` (3rd, short), `OnProjectileHit`, `ElectroFingersZap` (6 params), `RecruitNearbyIntoGroup` 2nd,
  `Obj2_ApproachAndAttackTarget` (1 stack param), `MoveTowardTarget` 3rd, `FindThreatArea/Target/LineOfSight` 2nd,
  `CreateSpriteInAreaSpiral` / `ResetForRespawn` `byte* unsure_area` (rect at +1..+4). `Ped_ThreatSearchCandidateFilter`
  0x4B9A10 `this` is `void* candidate` (reads +8 as a Sprite*; a spiral-search callback, not a Ped).
  `Ped_UpdateThreats`, `CopyFrom`, `MoveTowardTarget`, `Init` show `path[]` hits in the decompiler: that is the real
  `Ped.path`, not a wrong `this`.

## 8. Ped pathfinding (`PedPathfinder`, Seq H3)

Source: Seq H3 (2026-10-23), decompile and asm of every `PedPathfinder_*` function,
`Ped_MoveTowardTarget` 0x4380D0, `Ped_Update` 0x4455ED / 0x445817, `Ped_Remove` 0x43E650,
`Game_Ctor` 0x45CD91 and the `FindSpawnTile` call sites. Nothing was measured at runtime.

**One pathfinder for the whole game.** `Game_Ctor` allocates `operator_new(0x2FD4)` at 0x45CD91,
calls `PedPathfinder_Ctor` 0x45C130 and stores it in `g_PedPathfinder` 0x66A7E4; `Game_Dtor` frees
it (`PedPathfinder_ScalarDeletingDtor` 0x45BE20). There is exactly one search state, and peds take
turns on it.

**Request queue.** `Ped_MoveTowardTarget` 0x4380D0 runs for every on-foot "go to" objective (23
callers: GoToArea, GoToChar, FollowLeader, EnterCar, Guard, …). Each call:

1. sets `DAT_005e5b90` = 1 ("this ped asked for movement this tick"; suggested name
   `g_PedMoveRequestedThisTick`) and state FOLLOW_ROUTE;
2. if `PED_FLAG_PATH_REQUEST_PENDING` (0x4000) is clear, appends the ped to the FIFO
   `requestQueueHead` (+0x3C, `PedList_AddUniqueAtTail`) and sets the flag;
3. if the ped is the queue head (`PedPathfinder_IsRequestHead` 0x49CB40), calls
   `PedPathfinder_FindPath(g, ped->id, ped->path, pos x/y/z, goal x/y/z,
   Ang16_ToHeadingClass(angle to goal), &ped->pathLength)` (call at 0x4384F2). It returns false
   while the search is still running, so the ped keeps waiting. On true the ped is dequeued
   (`PedList_Remove`), the flag is cleared, and `pathCursor` moves to the path entry matching the
   ped's current tile (or `path[0]`). The ped then follows `path[]` step by step (`moveTarget` =
   tile + 0.5). If `path[0]` is (0,0) the ped gets `PED_FLAG_PATH_FAILED` and falls back to PURSUE
   (straight-line steering);
4. non-head peds keep following their old `pathCursor`, or steer straight (PURSUE) if they have none.

`Ped_Update` clears `DAT_005e5b90` at 0x4455ED. At 0x445817, if the ped did not call
MoveTowardTarget this tick and still has the pending flag, it is removed from the queue
(`PedList_RemoveDuplicate`, 0x445834) and the flag is cleared. `Ped_Remove` does the same and also
calls `PedPathfinder_ReleaseIfOwner(ped->id)`.

**The search (`PedPathfinder_FindPath` 0x49CF70)** is an incremental **greedy best-first search**,
not A* and not BFS:

- **Window**: a 33×33 grid centred on the start (grid (16,16) = start, world = start ±16). Storage is
  `nodes[33][34]` (8 B each, stride 34). Grid coordinates are u8 (`nbrGridX/Y`, 0..0x20 valid).
  8 neighbours: dir 1 −y, 2 +x, 3 +y, 4 −x, 5 +x−y, 6 +x+y, 7 −x+y, 8 −x−y. The start is marked
  with dir 0x42.
- **Two z levels per cell**: a cell visited at one z can be visited once more at another z
  (`hasSecondLevel`, slot 2 = `parentDir2` / `z2`); a third level is dropped. This covers bridges
  and stairs.
- **Priority** (`PedPathfinder_PushOpenNode` 0x49C820) = `dx² + dy²` to the goal, ×2 when the
  neighbour's z ≠ goal z. The step count g is stored (`stepCount`) but never added: pure greedy.
- **Open list**: `openList[400]` at +0x2350, unsorted. Each pop is a linear scan for the minimum and
  a swap-remove with the last entry. Pushes have **no bound check**.
- **Walkability** (`PedPathfinder_CanStepToTile` 0x49CB60): a cardinal step →
  `PedPathfinder_CanCrossEdge(dir)` 0x49C680 → `!MapBlocks_IsBlockEdgeCrossingBlocked(cur, dir,
  &g_PedPathStepDz, 1)`; the out-byte is the z change, which goes into the neighbour's z (stairs,
  slopes). A diagonal step is refused if the current tile or either orthogonal tile is a slope
  (`MapBlocks_IsSlope1to44At`), and all four edge crossings must be open (no corner cutting).
  `CanCrossEdge` also refuses any tile with x or y outside 2..0xFD (map-border guard).
- **Budget**: at most 100 pops per call (`iterBudget` +0x2E), then it returns false ("call me next
  tick"). Each call increments `callCount` (+0x2FD1); past 200 calls the search aborts with
  `ready = 1`, returns true and writes **no path**.
- **Termination**: (a) goal reached, exact (x, y, z) equality with the popped node; (b) the goal is
  outside the window and startZ == goalZ: `PedPathfinder_ClassifyNode` 0x49C760 returns 2 when a
  neighbour leaves the window on the side picked by `fallbackDir` (1 −y, 2 +y, 3 +x, 4 −x); the path
  goes to that border and the ped asks again from there; (c) the open list runs dry:
  `PedPathfinder_SelectFallbackGoal` 0x49C9D0 uses the last node pushed on that window edge
  (`g_PedPathEdgeBest*`), else `ReleaseIfOwner` and return true with **no output**.
- **Output**: backtracks `parentDir` from the end node to the start, using `openList` as the stack,
  copies up to **100** (x, y, z) steps into `ped->path` from the start side, then a (0,0,0)
  terminator at `path[count]`, and writes the count to `*outLength`. Then `ready = 1`,
  `searchInProgress = 0`, `callCount = 0`.
- **Throughput**: only the queue head searches, at ≤ 100 pops per tick, so the whole city is served
  one path request at a time.

**`PedPathfinder_FindSpawnTile` 0x49D7A0** (now returns `bool`) is not path finding. It reuses the
grid and open list with `floodMode = 1`: priority = `floodRing` (the pop counter, so roughly BFS),
4 neighbours, the same walkability test. It accepts the first popped tile whose ground type (z − 1)
== `kind` (kind 1 also needs road-arrow bits), refuses when `searchInProgress && !wide`, and without
`wide` gives up after **7 popped tiles** (not "rings"). `PedPathfinder_CanStepFromTile` 0x49DCE0 is
the same step test for `Car_IsDoorExitClear`.

### `PedPathfinder` (0x2FD4, 38 fields)

| Off | Type | Name | Evidence |
|---|---|---|---|
| 0x00 | int | `requesterPedId` | FindPath stores arg 1 (= `Ped.id`, 0x4384EA); ReleaseIfOwner compares it |
| 0x04 | byte | `floodMode` | 0 in FindPath, 1 in FindSpawnTile; PushOpenNode picks the priority from it |
| 0x08 | `PedPathOpenEntry*` | `openCursor` | PushOpenNode / pop scan |
| 0x0C | word | `openCount` | ++ in PushOpenNode, −− on pop; no 400 cap |
| 0x0E–0x10 | byte ×3 | `startX/Y/Z` | FindPath args 4–6; z snapped by `MapBlocks_GetGroundZBelow` |
| 0x11–0x13 | byte ×3 | `goalX/Y/Z` | FindPath args 7–9 |
| 0x14 | byte | `openNodesLeft` (was `unsure_budgetPending`) | write-only: 1 after a pop that left the open list non-empty (0x49D4D2), 0 before path output (0x49D4F5) |
| 0x16 | short | `floodRing` | FindSpawnTile pop counter = priority |
| 0x18 | byte | `searching` | loop condition |
| 0x19 | byte | `searchDone` (was `unsure_goalReached`) | write-only: 1 on **every** search end — goal popped (0x49D588), window-edge exit (0x49CF63), open list exhausted / fallback (0x49D4A9) |
| 0x1A | byte | `targetReached` (was `unsure_goalReached2`) | write-only: 1 only when the target was reached — goal popped (0x49D58C) or edge exit toward the goal (0x49CF67), not on the fallback |
| 0x1B | byte | `stepDir` | 1..8 / 0x42 |
| 0x1C | word | `nodeIndex` | gridX + gridY·34 |
| 0x1E | short | `curStepCount` | from node +6 |
| 0x20–0x22 | byte ×3 | `nbrX/Y/Z` | neighbour world tile |
| 0x23 / 0x24 | byte | `nbrGridX/Y` | window coordinates |
| 0x25–0x27 | byte ×3 | `curX/Y/Z` | from-tile for CanStepToTile / CanCrossEdge |
| 0x28 / 0x29 | byte | `spawnWindowOriginX/Y` (was `unsure_windowOriginX/Y`) | write-only: FindSpawnTile writes x−16, y−16 (0x49D7FD / 0x49D806) |
| 0x2E | short | `iterBudget` | = 100 per call |
| 0x34 / 0x36 / 0x3A | short | `unusedInit34/36/3a` (was `unsure_init34/36/3a`) | write-only, vestigial: InitFields only (1, 0, 0 at 0x49C717 / 0x49C71B / 0x49C71F) |
| 0x38 | byte | `searchInProgress` | set in the pop loop, cleared on success / abort; FindSpawnTile gate |
| 0x3C | `PedListNode*` | `requestQueueHead` | `PedQueue_Ctor`, `PedList_AddUniqueAtTail` / `Remove` |
| 0x40 | `PedPathNode[33][34]` | `nodes` | ClearNodes 0x8C4 dwords; index `x + y*0x22`; start node = index 0x230 |
| 0x2350 | `PedPathOpenEntry[400]` | `openList` | `openCursor = this+0x2350`; also the reconstruction stack |
| 0x2FD0 | byte | `ready` | 1 = idle |
| 0x2FD1 | byte | `callCount` | > 200 → abort |

Sub-types: `PedPathNode` (8 B: `hasSecondLevel, parentDir, z, parentDir2, z2, pad5, short
stepCount`), `PedPathOpenEntry` (8 B: `gridX, gridY, x, y, z, pad5, short priority`),
`PedPathEdgeBest` (5 B: `gridX, gridY, x, y, z`). Globals, used only by `PedPathfinder_*`:
`g_PedPathCurNode` 0x66A7B4, `g_PedPathEdgeBestPosX` 0x66A7BC, `g_PedPathEdgeBestNegY` 0x66A7C4,
`g_PedPathEdgeBestNegX` 0x66A7CC, `g_PedPathFallbackDir` 0x66A7D4, `g_PedPathEdgeBestPosY`
0x66A7D8, `g_PedPathStepDz` 0x66A7E0.

Prototypes (all set in Ghidra): `PedPathfinder_FindPath` is `bool __thiscall (PedPathfinder*, int
requesterPedId, S3Bytes* outPath, byte startX, startY, startZ, goalX, goalY, goalZ, int fallbackDir,
byte* outLength)`; `CanCrossEdge(this, int dir)`, `CanStepToTile(this, byte toX, toY)`,
`CanStepFromTile(this, fromX, fromY, fromZ, toX, toY)`, `IsRequestHead(this, Ped*)`,
`ReleaseIfOwner(this, int pedId)` are `__thiscall`; `ClearNodes`, `InitFields`, `ClassifyNode`,
`PushOpenNode`, `SelectFallbackGoal`, `TryExpandNeighbor` are `__fastcall(this)`.

### Why peds get stuck: pathfinder bugs (Seq H3)

| # | VA | What | Trigger | Severity | Confidence |
|---|---|---|---|---|---|
| 1 | 0x445817 / 0x49CF70 | **A ped can inherit an orphaned search.** `Ped_Update` drops a ped from the queue when it did not call MoveTowardTarget this tick, but never calls `ReleaseIfOwner`. If that ped was the head mid-search (`ready == 0`), FindPath for the next head skips init, keeps searching the **old ped's start → goal**, and writes that path into the new ped's `path[]`; the new ped walks toward a tile near the old ped (cursor = `path[0]`) | the head ped changes objective or reaches its goal while its search spans more than one tick | high (wrong-direction walking) | static V; not observed at runtime |
| 2 | 0x49C7E6–0x49C803 | **Window-edge exit is u8-asymmetric.** Dirs 2 (+y) and 3 (+x) fire on both opposite borders (−1 wraps to 0xFF > 0x20); dirs 1 (−y) and 4 (−x) only in window corners | goal > 16 tiles away, same z | medium: 2/3 can lead away from the goal; 1/4 never exit early → full flood up to 200 ticks → fallback | V (asm) |
| 3 | 0x49CA6D | **SelectFallbackGoal case 2 copy-paste bug**: the grid cell comes from `g_PedPathEdgeBestPosX` instead of `PosY`, so reconstruction starts at the east-edge cell with the south-edge node's world coordinates → garbage path or a `default:` dir → fail | open list exhausted, fallbackDir == 2 | medium | V (asm) |
| 4 | 0x49C740 / 0x49D4C0 / 0x49D71F | **Failure exits leave `searchInProgress = 1`.** `ReleaseIfOwner` does not clear +0x38, so `FindSpawnTile(wide = 0)` keeps failing (ambulance, fire truck, police, CarAI) until a later search completes or aborts. Matches the "bodies get dropped" note in [gangs-and-peds.md](gangs-and-peds.md) | any failed FindPath (unreachable goal, no edge record) | medium | static V |
| 5 | 0x49D4C0, 0x49D71F, > 200 abort | **"Done" with no output**: FindPath returns true but writes neither `path[]` nor `*outLength`; the caller searches the stale `path[]` of the previous request and may follow it, or finds (0,0) → PATH_FAILED → straight-line PURSUE (walking into walls) | unreachable goal, budget abort | medium | static V; the stale-path effect is a hypothesis |
| 6 | 0x49D7A0 | **`FindSpawnTile(wide = 1)` clobbers a running FindPath**: clears nodes, open list and sets floodMode = 1 while `ready == 0`; FindPath resumes on the wreck. wide = 1 callers: `Ped_Obj1_GoToAreaAnyMeans` 0x43C83C / 0x43C9D5, `Ped_Obj1_BustedTakenAwayInCopCar` 0x43D01D, `Sprite_ClearObstaclesForSpawn` 0x4BDB95 (0x43CD2A passes EBP, unknown) | spawn search during a multi-tick ped search | medium | static V |
| 7 | 0x49D6xx (output loop) | **Off-by-one into Ped**: with count == 100 the terminator goes to `path[100]` = Ped+0x12C..0x12E (`rotation`, low byte of `aimRotation`) | path ≥ 100 steps | low–medium (effect unknown) | write V |
| 8 | 0x49C820 / 0x49D645 | **No bounds on `openList[400]`**: the push and the reconstruction stack can run past +0x2FD0 into `ready` / `callCount` and the heap | very large frontier, or a path > 400 nodes in a 33×33 window | low | static |
| 9 | design | **Greedy, not A***: paths are not shortest, U-shaped obstacles cause long detours; every ped waits its turn in one global FIFO at ≤ 100 pops per tick, so crowds steer straight (PURSUE) for seconds → "peds walking into walls" | many on-foot objectives at once | design | V |

### Still unknown

- How often bug 1 happens in play: needs a runtime trace (watch `requesterPedId` change while
  `ready == 0`, e.g. a gta2ctl / K-menu probe on `g_PedPathfinder`).
- Heading-class axes: the pathfinder treats `fallbackDir` as 1 −y, 2 +y, 3 +x, 4 −x. Seq H1 proved
  `Ang16_ToHeadingClass` 0x472C00 = 1 N (−y), 2 S (+y), 3 E (+x), 4 W (−x)
  ([cars-and-car-ai.md](cars-and-car-ai.md) §4), which agrees, so the edge choice is on the right
  axis. (H3 itself did not resolve the Ang16 threshold constants.)
- ~~What +0x14, +0x19, +0x1A, +0x28/0x29, +0x34/0x36/0x3A are for~~: **write-only**, verified by an
  instruction scan of every `PedPathfinder_*` function and every function that references
  `g_PedPathfinder` (any base register except ESP/EBP; U3, 2026-10-24); named after what the writes
  mean (table above). The untyped gaps 0x5–7, 0x15, 0x2A–0x2D, 0x30–0x33, 0x39 have no access at all.
- The `PushOpenNode` early return when `hasSecondLevel` is set and z matches slot 2 (clears the flag,
  pushes nothing): intent unclear.
- Whether `FindSpawnTile`'s `wide = EBP` at 0x43CD2A is 0 or 1.
