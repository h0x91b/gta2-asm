# Cars, car sound and car AI in gta2.exe 11.44

The car module `0x410000–0x42FFFF` (car sound, camera, doors, lifecycle, pools, CarManager, the
CarAI helpers) and the drive-order / route-finding code it calls (`RoadNetwork_*` 0x40C000–0x40E3FF,
`CarAI_*` 0x430000–0x432800), read from the binary in Seq 43. Every address is a VA in vanilla
`gta2.exe` 11.44 (base `0x3F0000`); every name is in the Ghidra DB (`gta-2-recovered.gpr`, program
`gta2.segments.fixed.exe`) and therefore in `re/`. "V" = the body was read in the 11.44
decompiler/disassembly; "H" = hypothesis, the name carries `unsure_`. Constants are Fix16 Q14
(`raw / 0x4000`, see [math-helpers.md](math-helpers.md)); zero-in-file `DAT_` values come from
[`re/static_constants.csv`](../../re/static_constants.csv).

Related: [car-physics.md](car-physics.md) (CarPhysics, 0x49D000+), [gangs-and-peds.md](gangs-and-peds.md)
§7 (ambulance / fire-engine managers) and "Calling the services on demand",
[ped-ai.md](ped-ai.md) (ped objectives that give drive orders).

Coverage: the live DB had **348** unnamed functions in `0x410000–0x42FFFF` at the start of Seq 43
(census 2026-10-21 23:55 via `find_functions has_custom_name=false`) and **0** at the end (see §9).

## 1. What lives where

| range | subsystem |
|---|---|
| 0x410000–0x414E4F | sound events and the car-sound helpers: `SoundEventQueue_*`, `SoundEvent_InitFrom*Hit`, impact sample pickers, car-model → engine-sound tables (`unsure_CarModel_GetEngine*`), `CarSound_Add*` emitters, voice range / volume, CarPhysics and CarDoor read-only getters used by sound |
| 0x414E50–0x41DDFF | `SoundMgr_*` (g_SoundManager, the game-side mixer above mss32): request queue, 16 voices, 1020 source slots, listener, pan / distance / Doppler, police radio phrase queue; ComboList (bonus checks, unrelated to sound) |
| 0x41DE00–0x41F5FF | Camera: target / smoothed position, shake, pan, view size, visibility tests |
| 0x41F600–0x42179F | CarDoor, model predicates, roof attachments, upgrades / shop, Position helpers, CarManager traffic lists and category counters, CarDeltas |
| 0x4217A0–0x42A4FF | Car lifecycle: model checks, lights / siren deltas, damage, wreck, explosion, recycling, trailers, trains, pools |
| 0x42A500–0x42FFFF | CarAI helpers and drive orders: `CarAI_Ctor/Reinit`, `Fix16_ChebyshevDist`, `CarAI_SetRouteTarget`, junction reservation, lane change, `CarAI_UpdateDriveOrder`, `CarDriveOrder_Drive` |
| 0x430000–0x432800 | CarAI per-tick: `CarAI_FollowRoute`, `CarAI_ApplyRouteTurn`, `CarAI_FollowLane`, `CarAI_UpdateJunctionTurn`, `CarAI_DriveStep`, `CarAI_Update`, `CarAI_PreUpdate` |
| 0x40C600–0x40E3FF | RoadNetwork (RGEN junction graph): segment → junction lookup, A*-like search, route slots |

## 2. Car sound (SoundManager)

`g_SoundManager` 0x5DCBC8 (type `S6`, 0x5540 bytes) sits above our mss32 reimplementation
([win32-shims.md](../win32-shims.md) "Audio"). Per tick `SoundMgr_Update` → `SoundMgr_UpdateFrame`:

1. flip the request double buffer (`+0x98`), reset the sort index;
2. `SoundMgr_UpdateListenerAndSources` 0x417030: listener from the player's ped (or its car), then
   `SoundMgr_UpdateSource` 0x4163A0 for every active slot — a switch on the source kind: 1 sprite
   (ped / car / object → `SoundMgr_UpdateSpriteSource` 0x4162C0), 2 music stream, 3 radio, 6 event
   queue, 7 weapon, 10 vocal, 0xB HUD counter;
3. each branch fills the pending request (`S6+0x30`, a 0x68-byte record) and calls
   `SoundMgr_QueueRequest` 0x4171A0 when audible (`SoundMgr_IsVoiceInRange` 0x4116B0,
   `SoundMgr_ComputeVoiceVolume` 0x4116F0 → `SoundMgr_CalcDistanceVolume` 0x416DA0);
4. repeating requests are re-issued, then the sorted requests are mapped onto the 16 Miles voices
   (`S6+0xDC0`, 0x68 each) by (slot, emitter id).

Sources live in a 1020-entry slot table at `S6+0x147C` (stride 0xC: `+0` used, `+1` age capped at 10,
`+4` source*, `+8` extra*); the active list is at `+0x444C`, count `+0x543C`. A source
(`SoundClient`, 16 bytes, pool of 1000) is `+0 kind, +4 inactive, +8 voice channel, +0xC owner`.

Car sources: `SoundMgr_UpdateCarSource` 0x415DF0 dispatches on the car's info index (0x36, 0x3C
special); the default chain adds engine, heavy-vehicle slide / idle, speed loops, tyre slip, doors,
alarm, horn (`SoundMgr_UpdateCarHorn` 0x415880, `Car_IsHonking`), siren (`SoundMgr_UpdateCarSiren`
0x415A90, `Car_IsSirenActive` 0x414F80 = emergency lights && `SIREN_ON` bit), damaged engine, shop
and bomb ticks. Police radio: a ring of 15 phrase ids (`S6+0x552C`, read `+0x5528`, write `+0x5529`)
filled by crime-report / car-description / location builders and drained by
`PoliceRadio_Update` 0x41C600.

## 3. Camera, doors, CarManager

- **Camera** (0x41DE00–0x41F5FF): `cameraPosTarget` (+0x10) is set by `Camera_SetTarget` from
  `Camera_FollowCar` / `Camera_FollowPed`; `cameraPos` (+0x98) is the smoothed position, `+0xAC` its
  speed. `Camera_Tick` 0x41F2F0: `followState` (+0x3C) 1 = spring smoothing, 2 = snap; shake while
  `+0x30 != 0` (H); then boundaries and `Camera_CommitTarget`. `Camera_IsWorldPointOnScreen`
  0x41E710 tests 0 ≤ x < 640, 0 ≤ y < 480 in game screen units.
- **CarDoor** (16 bytes, `Car+0xC + i*0x10`, 4 doors): state `+4` 0 none, 6 closed
  (`CarDoor_Init`), 1/2 opening / open, 3..5 closing; `CarDoor_RequestOpen` 0x41F680 refreshes the
  hold timer `+0xC = 0x32`.
- **CarManager** category counters and caps (`CarManager_HasRoomForType` 0x420CE0 /
  `_Strict` 0x420C40, all signed `setl`):

  | category | field | cap | strict |
  |---|---|---|---|
  | RECYCLED + PROT_RECYCLED | +0x28 + +0x40 | < 16 | < 15 |
  | AMBULANCE | +0x2C | < 2 | < 1 |
  | FIRE_TRUCK | +0x30 | < 2 | < 1 |
  | UNIT | +0x34 | < 6 | < 5 |
  | ROADBLOCK | +0x38 | < 12 | < 11 |
  | MISSION | +0x3C | < 24 | < 23 |
  | PARKED | +0x44 | < 200 | < 200 |
  | COP_CALLED (10) | +0x48 | < 12 | < 11 |

  `CarManager_Ctor` 0x428FA0 does not write `+0x48` or `+0x68` and the object comes from a
  non-zeroed `operator new(0x6C)` (Seq 27, re-verified here): `copCalledCars` starts as heap
  contents. Runtime effect not measured.

## 4. CarAI per tick

`Car_Update` → `CarAI_PreUpdate` 0x4327A0 (scratch reset, heading = body rotation, travelDir =
heading class, halt handling) → `CarAI_Update` 0x432370:

1. `DAT_5E53D8 / 5E5320 / 5E50EC` ← car body x / y / z (scratch globals every helper reads);
2. if `car->driveOrder && ai->unsure_unstickState == 0`: **`CarAI_UpdateDriveOrder` 0x42D390 every
   tick**, `DAT_5E507E = 1`;
3. unstick handling (`offRoadTurn` +0x50: steer ±, reverse), `stuckTicks > 200` → abandoned;
4. `CarAI_DriveStep` 0x431C10, `CarAI_ReactToNearbyCar`;
5. drive order with `followRoadActive == 0` → `CarDriveOrder_Drive` 0x42D820 (direct driving);
6. `routeSlot > 0 && ai->flags & 0x10 && followRoadActive == 1` → **`CarAI_FollowRoute` 0x430320**;
7. `CarAI_FollowLane` 0x430CC0 (lane keeping, `CarAI_UpdateJunctionTurn` → `CarAI_TryStartTurn` /
   `CarAI_ReserveJunction`; ambient traffic picks turns at random with `CarAI_PickRandomTurn`).

`ai->flags` (+0x24): 0x02 inside the current junction rect, 0x10 on a lane tile whose arrows match
travelDir, 0x40 unstick / reverse, 0x80 turn committed, 0x800 straight / U-turn code valid
(`routeExitCode` +0x38), 0x20000 junction reserved, 0x40000 / 0x80000 steer into the target's lane,
0x100000 halted, 0x200000 copy of a driver flag.

## 5. Drive orders and route finding

A ped objective (`Ped_Obj1_GoToAreaInCar` 0x438C40 for GO_TO_POINT; see [ped-ai.md](ped-ai.md))
gives the car a `CarDriveOrder` (0x40 bytes, pool of 20): `+8 mode` (1 GO_TO_POINT, 2 FOLLOW_TARGET,
3–5 chase variants), `+0xC` maneuver 0..0xF for direct driving, `+0x14/18/1C` target x/y/z,
`+0x20 isUrgent`, `+0x22 followRoadActive`, `+0x26 arrived`, `+0x30 targetPed`,
`+0x34 retryCooldown` (300, or 100 for cops / copLevel ≥ 3).

**`CarAI_UpdateDriveOrder` 0x42D390**, every tick:

- `ai->targetSpeed = driver->carSpeed`; target = order x/y/z (GO_TO_POINT) or the target ped's
  position.
- `Fix16_ChebyshevDist` 0x42A6B0 (`max(|dx|, |dy|)`) to the target `< 5.0` (`DAT_5E50B8`) stops road
  following — **only when mode != GO_TO_POINT**.
- urgent orders never route: when no player camera sees the car, it is teleported onto the target's
  arrow tile (`Car_TryPlaceOnArrowTileAt`), repaired, crew despawned.
- otherwise: `RoadNetwork_FreeRoute`, find a road block with arrows at the target (x, y, z) or
  (x, y, z − 1), else `PedPathfinder_FindSpawnTile`; then `CarAI_SetRouteTarget(x, y, blockZ, 3)`,
  `followRoadActive = 1`. **The route is recomputed from scratch every tick**, so `routeStep`
  (+0x56) stays 0 — it is written only by `CarAI_Ctor`, `CarAI_Reinit` and `SetRouteTarget`.

**`CarAI_SetRouteTarget` 0x42ACF0**: `RoadNetwork_FindRoute(car x, car y, ToInt(car z − 1),
target x, y, z, 3)` → `ai->routeSlot`; on success writes the order's target x/y and **target z =
the original order z (`DAT_5E5218`), not the road block's z**.

**`RoadNetwork_FindRoute` 0x40E030** = `InitSearch` 0x40D690 + `RunSearch` 0x40DFA0 + `StoreRoute`:
a best-first search over the RGEN junction graph (4 links per junction; closed links and
incompatible arrow kinds skipped). Start = the junction of the car's segment
(`RoadNetwork_FindSegmentJunctionAtTile` kind 0, then kind 1 = the one ahead if the car is outside
the first one's rect); goal = the junction ahead of the target tile; if start == goal the start
reverts to the first (behind) junction. The route is stored as u16 junction ids in
`routes[slot*0x100 + i]` (`RoadNetwork+0x2218`), 0-terminated, slots 1..49. A car already on the
target's segment therefore gets the pair [junction behind, junction ahead] with the target inside
its bounding box — the "route growing with the junctions behind it" seen in Seq 39 is this per-tick
re-plan, not a moving goal.

**Arrival.** `driveOrder->arrived` has one writer, `CarAI_FollowRoute` 0x430320 (stores at
0x4304DE, 0x43053C, 0x430626). It arrives when

- (a) `routes[slot][step] == 0`, or the car's tile equals the target tile exactly
  (`ToInt(x) == ToIntB(target x) && ToInt(y) == ToIntB(target y)`, no z, no tolerance); or
- (b) the target is inside `RoadNetwork_IsTileInJunctionPairBounds(routes[0], routes[1])` **and**
  `ToInt(car z − 1.0) == ToIntB(order z)` (0x43041F..0x430444, `JNZ 0x4305B5`) **and** the car has
  passed the target along `RoadJunction_GetLinkDirTo(routes[0], routes[1])` (1: car y ≤ t y,
  2: car y ≥ t y, 3: car x ≤ t x, 4: car x ≥ t x). The same branch, while not yet passed, sets
  `ai->flags` 0x40000 / 0x80000 to steer into the target's lane.

On arrival: `CarPhysics_SteerPlus`, `followRoadActive = 0`, `Car_HaltAIIfHasAI`, `arrived = 1`.

## 6. Why dispatched services drive past their target (Seq 43 bug hunt)

**Verdict: native 11.44 behaviour, not a port bug.** Evidence chain (traces from a `-DDE_TRACE`
build of `host/debug_emergency.asm`, Downtown, 2026-10-22):

1. Both services get a GO_TO_POINT order, `isUrgent = 0` (paramedics: `Ped+0x26C` = 0, written at
   0x47323A). Trace: `ai flags 00012012 order mode 1 followRoad 1 arrived 0 urgent 0` — flag 0x10 is
   set, `CarAI_FollowRoute` runs every tick.
2. The order's z is the **sprite z of the ground**: 2.0 (`0x8000`) on flat road, for the ambulance
   (node z of `PedPathfinder_FindSpawnTile` 0x49D7A0), the fire truck (`ToIntB` of the wreck's z
   in `FireEngineSlot_Update` 0x450F10) and mission scripts alike (`goto_area_in_car` with z 2.0,
   `docs/formats/specs/scripting/example/bil/bil_rm3.mis:147`). A car on flat road also has z 2.0.
   Trace: `order target 2a0000,200000,8000 car pos …,…,8000`.
3. So the z gate of branch (b) compares `ToInt(2.0 − 1.0) = 1` with `ToIntB(2.0) = 2` and never
   passes on flat ground: no lane steering, no "passed the target" arrival. Only the exact-tile test
   (a) remains. The road at x = 168..170 is three lanes one way; the truck and the MEDICAR drive at
   x = 169, the target is at x = 168, and they pass one tile beside it forever.
4. Lowering the order z to 1.0 does not help either: `CarAI_UpdateDriveOrder` plans with that z and
   no longer finds the road block (route slot −1). No single z value satisfies both on flat ground.
5. The proximity stops in the slot code need the car standing still: `Ped_Obj1_GoToAreaInCar`
   counts only while `Car_GetSpeed == 0` (0x421EC0); `AmbulanceSlot_UpdateParamedics` waits for
   Chebyshev < 8.0 and a timer > 0x32, `FireEngineSlot_Update` state 2 for < 3.0 and a timer > 100.
6. Port inputs ruled out: the CRT static constants read on this path are correct at runtime
   (`5E512C = 0x4000`, `5E50B8 = 0x14000`, `5E520C = 0x8000`, `5E5398 = 0x1EB`); the chain uses no
   time, `rand`, FPU or camera (`RoadNetwork_FindRoute`, not the `*Offscreen` variant); the search
   buffers are cleared by `InitSearch`; the deciding values are integer map / sprite data.
7. Control experiment: NOPing only the `JNZ` at 0x430444 made the ambulance steer into lane
   x = 168, stop at (168, 129), free its route, and the paramedics revived the body.

Not done: a side-by-side run of the original game on Windows, and a natively triggered dispatch
without the K menu (the K entries only enqueue the body or light the car; everything after is the
game's own code, so the menu path *is* the native dispatch). Arrival on slopes / bridges
(fractional z) is untested.

**Workaround** (`host/debug_emergency.asm`, `hk_FollowRoute`): a call hook on the
`call CarAI_FollowRoute` in `CarAI_Update` (0x432678) that, after the first K-menu call and only for
the vehicles held by the ambulance / fire-engine slots, sets the order's z to car z − 1.0 for the
duration of the call and restores it afterwards (`CarAI_UpdateDriveOrder` must keep planning with the
sprite z). Every other car runs the vanilla path. With it the MEDICAR stops at the body and the crew
revives it; the fire truck reaches the wreck, hoses (slot states 3 → 4 → 5) and leaves.

## 7. Structures (DB state after Seq 43)

- `CarAI` (0x78): `+0 parentCar`, `+8 turnTimer`, `+9/+A turnTileX/Y`, `+0xC nextFree`, `+0x10 heading`,
  `+0x14/18/1C` speed cur / goal / step, `+0x24 flags` (§4), `+0x28 routeSlot` (s8, −1 none),
  `+0x2A stillTicks`, `+0x2C avoidTimer`, `+0x38 routeExitCode` (new), `+0x3C unsure_unstickState`,
  `+0x44 turnExitDir`, `+0x4C travelDir`, `+0x50 offRoadTurn`, `+0x54 laneFollowCooldown`,
  `+0x56 routeStep` (always 0, §5), `+0x74 targetSpeed`.
- `CarDriveOrder` (0x40): see §5; new in Seq 43: `+0x10 unsure_driveFlag`, `+0x2A/2C/2E
  unsure_counter*`, `+0x34 retryCooldown`.
- `CarManager` (0x6C): §3. `CarDoor`: §3. `S6` / SoundManager layout: §2 (struct not yet edited in
  the DB; the existing `S5` slot type is the 0xC slot record, `SoundClient` is 16 bytes — the 0x30
  layout currently in the DB is the weapon's).

## 8. Open questions

- Who sets `ai->flags & 0x10` (not `CarAI_Update`; probably `CarAI_FollowLane`).
- `CarDriveOrder_Drive` maneuver numbers 1..0xF in detail; `DAT_5E5084` for GO_TO_POINT.
- Sound source kinds 8 / 9, car info indices 0x36 / 0x3C, sample bank ids → cue names.
- Camera `+0x30` (shake amplitude vs `CAMERA_MOVEMENT` bitmask) and the `+0x60/+0x64` split: medium
  confidence, struct left unchanged.
- `copCalledCars` (+0x48) heap garbage: runtime value never dumped.

## 9. Functions named in Seq 43

All 348 functions that were unnamed at the start, by slice (names as exported to `re/functions.csv`; "V" unless the name carries `unsure_`; evidence from the slice reports, empty where the name is a plain field accessor). Slices: sound events (Sonnet agent N1), SoundManager (N2), camera / doors / CarManager (N3), lifecycle / CarAI helpers (N4); route bug hunt (B) and coordinator checks in §5–6.

#### Sound events, car-sound helpers (0x410000–0x414E4F, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x410010 | SoundEvent_InitFromPedHit | V | classifies g_CollisionKind/HitSprite -> event type 8/4/6/7 |
| 0x4100F0 | SoundEvent_InitFromObjectHit | V | same, types 10/3/7/9, +0x18 objType, +0x1c |
| 0x410210 | SoundEventQueue_AddHit | V | appends event at queue+4+cnt*0x28, cnt at +0xc84 |
| 0x4102A0 | SoundEventQueue_AddImpactEventSurfaceBelow | V | event types 0xb/0xc/1, z shifted |
| 0x410370 | SoundEventQueue_AddImpactEvent | V | same without z shift |
| 0x410440 | SoundEventQueue_ReleaseClient | V | from SoundEventQueue_Dtor; returns client to pool via 40fe60 |
| 0x410460 | SoundEventQueue_AddHitDefaultVolume | V | wrapper of 410210 with DAT_005d82d0 |
| 0x410480 | SoundEventQueue_AddHitWithKind | V | sets g_CollisionKind then 410460 |
| 0x410500 | SoundMgr_Init_Thunk | V | initSound(&g_SoundManager) |
| 0x410570 | SoundMgr_Reset_Thunk | V | SoundManager_Reset(g_SoundManager), from Game_Dtor |
| 0x410580 | SoundMgr_AddRadioStation_Thunk | V | caller Script_Decl_RADIO_STATION |
| 0x410590 | SoundMgr_CancelVocalAt | V | clears vocal-table entry (stride 0x1c @5e2014) matching an (x,y) pair |
| 0x4105C0 | Sound_SetSFXVolume | V | clamp 0x7f -> SFXVolume |
| 0x410630 | Sound_GetCDVolume | V | returns CDVol |
| 0x410640 | MssAudio_ReleaseDevice_Thunk | V | _AIL_digital_handle_release_4; WndProc only |
| 0x410650 | SoundMgr_ReacquireDevice_Thunk | V | FUN_00416d60(g_SoundManager) = reacquire; WndProc |
| 0x410660 | unsure_Audio_GetCdDriveLetter | H | byte global read by intro-movie funcs |
| 0x410690 | SoundClientPool_Dtor | V | *p=0 (only a thunk caller) |
| 0x4106A0 | SoundClientPool_InitFreeList | V | 1000 nodes x16, link +0xc |
| 0x4106F0 | SoundClientPool_Ctor | V | wraps 4106a0, no callers (static init) |
| 0x410700 | thunk → SoundClientPool_Dtor_Thunk | V | thunk |
| 0x410710 | SoundClient_FreeVoice | V | relatedToS6 on node+8; called by 40fe60 (pool free) |
| 0x410790 | Sound_NopPreInit | V | empty; from initSound |
| 0x4107A0 | Sound_NopPreShutdown | V | empty; from 4164d0 |
| 0x4107B0 | SoundMgr_PickImpactSample3Tier | V | vol<0xf none; <0x28 ->0x25; <0x5a ->0x26; else 0x27; writes S6+0x44/0x50 |
| 0x410800 | Sound_PlayStreamTrackByCode | V | code 0x40..0x68 (+0x88) -> track -> MssAudio_Stream_OpenTrack |
| 0x410A70 | SoundMgr_PickImpactSample2Tier | V | samples 0x28/0x29 |
| 0x410AC0 | SoundMgr_PickImpactSample3TierNoCutoff | V | as 4107b0 w/o cutoff |
| 0x410B10 | SoundMgr_PickSurfaceImpactSample | V | by event+0x20 -> 0x27/0x26/0x44 |
| 0x410BF0 | Fix16_RoundToInt | V | (x+0x2000)>>14; Fix16 has 14 fractional bits |
| 0x410E20 | CarModel_GetEngineLoopSample | V | model -> 3..8; only caller 414fa0 |
| 0x410EE0 | CarModel_GetSirenSample | V | -> 0xe/0xf |
| 0x410F00 | CarModel_GetHornSample | V | -> 0x10..0x17 |
| 0x410FC0 | CarModel_GetHornBaseFreq | V | returns sample rates (0x5622 = 22050 ...) |
| 0x411120 | CarModel_IsHeavyVehicle | V | set {3,7,0xb,0x11,0x15,0x3a,0x3f,0x40,0x56}; same set as 413eb0 idle |
| 0x4112B0 | SoundMgr_CreateVocalClient | V | ff1 type-10 client into S6+0x5450 |
| 0x4112F0 | SoundMgr_DestroyVocalClient | V | frees S6+0x5450 |
| 0x411330 | SoundMgr_UpdateVocalClient | V | VOCAL id S6+0x5464 -> MssAudio_Stream_OpenTrack, clears it |
| 0x4116B0 | SoundMgr_IsVoiceInRange | V | dist2(+0x28) < arg, lazy sqrt -> +0x58, flag +0x2c |
| 0x4116F0 | SoundMgr_ComputeVoiceVolume | V | 416da0 attenuation -> +0x54, halved if muffled |
| 0x411730 | SoundMgr_GetDistSqToListener | V | (+0x38-+0x1468)^2+(+0x3c-+0x146c)^2 |
| 0x4117B0 | Position_GetXYZ | V | +0x14/+0x18/+0x1c; caller Hud_ArrowTarget_UpdatePosition |
| 0x4117D0 | Ped_TakeTrainStop | H | read-and-clear +0x13c (receiver = driver Ped from Car_GetDriver) |
| 0x4117F0 | Ped_TakeTrainStop2 | H | identical twin of 4117d0 |
| 0x411810 | CarPhysics_IsReverseGasOn | V | CarPhysics+0x94 |
| 0x411820 | CarPhysics_GetThrottle | V | +0x60 (receiver = Car+0x64? no: CarDriveOrder in Car+0x60; here param is CarPhysics from Car+0x58 in 413160) |
| 0x411830 | CarPhysics_GetWheelSpinTimer | V | +0xac |
| 0x411840 | CarPhysics_GetFrontSlip | V | +0x84 |
| 0x411850 | CarPhysics_GetRearSlip | V | +0x88 |
| 0x411860 | CarPhysics_GetGroundMaterial | V | +0x9c |
| 0x411870 | CarDoor_IsOpeningStart | V | state==2 && animationFrame==0 && frameDelay==0 |
| 0x411890 | CarDoor_IsClosingAtFrame1 | V | state==3 && animationFrame==1 |
| 0x4118B0 | Car_GetDriver | V | Car+0x54, 19 callers |
| 0x411950 | Car_TakeDriverReaction | V | Car+0xac read-and-clear |
| 0x411990 | Car_GetHornStateOrZero | V | Car+0xa7, 0 if >0xf8 |
| 0x4119B0 | Car_HasBomb | V | push 0x84 (OBJECT_TYPE_CAR_BOMB); call Car_FindAttachmentByType |
| 0x4119C0 | Car_IsEngineStateSiren | V | engineState==4 = REL_TO_CAR_SIREN; caller is siren sound |
| 0x4119D0 | Car_TakeShopReaction | V | Car+0xb4 |
| 0x4119F0 | Car_IsTurretBeingRotated | V | Car+0xb8 |
| 0x411A00 | Crane_GetBasePosition | V | *(x+0x2c)+4; IS_ITEM_ONSCREEN case 4 + type-8 client |
| 0x411A10 | Crusher_GetHasTarget | V | x+0x2c |
| 0x411A20 | Crusher_GetPosX | V | owner+0x24 of type-9 client |
| 0x411A30 | Crusher_GetPosY | V | owner+0x28 |
| 0x411A40 | SoundClient_GetType | V | *p |
| 0x411A50 | SoundMgr_UpdateMusicClient | V | type-2 client, MusicStream_IsDone -> Close/Open, vol S6+0x25*6/10 |
| 0x411D20 | SoundMgr_UpdateCraneSource | V | type 8 case of 4163a0; owner flags +0x156..+0x159 |
| 0x412010 | SoundMgr_UpdateCrusherSource | V | type 9; owner +0x24/+0x28 pos |
| 0x4121F0 | SoundMgr_CalcImpactVolume | V | event type 2..5 -> normalised volume; default random 5..14 |
| 0x4123C0 | CarSound_AddDriverReaction | H | Car_TakeDriverReaction -> samples 0x101..0x10f, layer 7 |
| 0x412680 | CarSound_AddTrainCabSpeedLoopA | V | speed/maxspeed -> vol, sample 4, layer 0 |
| 0x412830 | CarSound_AddTrainCabSpeedLoopB | V | sample 5, layer 2, vol 0x7f scale |
| 0x4129D0 | SoundMgr_GetChannelCar | V | channel -> client owner -> Sprite_GetCar |
| 0x412A20 | CarSound_AddTrainStopSound | H | Car_GetDriver -> Ped+0x13c -> sample 0x8b/0x8c, layer 3 |
| 0x412BD0 | CarSound_AddTankSpeedLoop | V | engine on, layer 5, sample 0xc |
| 0x412D80 | CarSound_AddTurretRotation | V | Car_IsTurretBeingRotated, layer 4, sample 0xb |
| 0x412EB0 | CarSound_AddBombTick | V | Car_HasBomb, layer 0xf |
| 0x412FE0 | CarSound_AddShopReaction | V | Car_TakeShopReaction -> samples 0x3e..0x43, one-shot |
| 0x413160 | CarSound_AddEngine | V | engine on, layer 0, sample 1 |
| 0x4139A0 | CarSound_AddAlarm | V | Car+0x8e alarmTimer, layer 6 |
| 0x413BD0 | CarSound_AddDamagedEngine | V | engine on and Car.damage(+0x74)>16000, layer 1 |
| 0x413DF0 | CarSound_PickDoorSample | V | model -> 0x1a..0x1f |
| 0x413EB0 | CarSound_AddHeavyVehicleIdle | V | speed==0 & heavy model, sample 7, layer 2 |
| 0x414030 | CarSound_AddHeavyVehicleSlide | V | !IsVelocityAlignedWithHeading & heavy model, layer 0xb |
| 0x414200 | unsure_CarSound_AddSpeedLoopC | H | sample 2, layer 2 |
| 0x4143B0 | CarSound_AddDoors | V | per door: IsOpeningStart->layer 9, IsClosingAtFrame1->layer 0xa |
| 0x414780 | CarSound_AddSiren | V | engineState==4, layer 0xc, sample 1/2 by carInfo parity |
| 0x4148D0 | CarSound_AddTyreSlip | V | front/rear slip, wheelSpinTimer vs CarPhysicsData thresholds, layer 0xd |

#### SoundManager, police radio, ComboList (0x414E50–0x41DDFF, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x414E50 | SoundMgr_UpdateOnScreenCounterSource | V | called from UpdateSource for kind 0xB; sample 0x39, vol by value of FUN_00411A40 (thresholds 0x97/0x12D) |
| 0x414F80 | Car_IsSirenActive | V | IsCarHasEmergencyLights && lightsBitstate SIREN_ON |
| 0x414FA0 | SoundMgr_ResolveRequestParams | V | switch on request category (+0x58): picks sample, freq, radius, loop, bank fields B0/B8/BC |
| 0x4150E0 | SoundMgr_PickEventSample | V | event id (+0x18) + category 1/3/7/9 -> sample id (S6+0x44), pitch (S6+0x50) from random S6+0x1454/58 |
| 0x415520 | SoundMgr_ResolveEventCategory9 | V | id filter then PickEventSample(..,9) |
| 0x4156B0 | thunk → CarSound_AddDoors | V | thunk |
| 0x4156C0 | unsure_CarSound_AddTankCarContactLoop | H | needs Car_IsEngineOn + Car_HasFlag2000; request type 0xE, cat 0xD |
| 0x415880 | SoundMgr_UpdateCarHorn | V | Car_IsHonking; request type 8, cat 5; skips fire truck/tank/siren cases |
| 0x415A90 | SoundMgr_UpdateCarSiren | V | Car_IsSirenActive + engine on; type 7, cat 4, vol 0x46 |
| 0x415BE0 | SoundMgr_ResolveEventCategory1 | V | PickEventSample(..,1) |
| 0x415BF0 | SoundMgr_ResolveEventCategory3 | V | ids 200..244 / 0x40..0x6C -> FUN_00410800, else (..,3) |
| 0x415C30 | SoundMgr_ResolveEventCategory7 | V | same ranges, (..,7) |
| 0x415C70 | SoundMgr_UpdateCarSource_Model3C | V | dispatcher branch for car info idx 0x3C |
| 0x415CC0 | SoundMgr_UpdateCarSource_Model36 | V | branch for idx 0x36 |
| 0x415D20 | SoundMgr_UpdateCarSource_Default | V | engine, siren, horn, 4139A0.. chain |
| 0x415DF0 | SoundMgr_UpdateCarSource | V | stores Car_HasPlayerDriver in source+4; switch Car_GetCarInfoIdx |
| 0x415EF0 | SoundMgr_ResolveEventSample | V | switch on event category: 1,10->Cat1; 2,4,5,0xC->410xxx; 3; 7; 9 |
| 0x415F90 | SoundMgr_UpdateEventQueueSource | V | kind 6: walks SoundEventQueue (events 0x28, count +0xC84), best candidate queued |
| 0x4162C0 | SoundMgr_UpdateSpriteSource | V | kind 1: ped->UpdatePedSource, car->UpdateCarSource, object->UpdateObjectSource |
| 0x4163A0 | SoundMgr_UpdateSource | V | switch kind: 1,6,7,8,9,10,0xB; kind 3 -> SoundManager_UpdateRadio; kind 2 -> 411A50 (music) |
| 0x4164D0 | SoundMgr_Shutdown | V | SoundManager_Reset, ends samples, clears slots, MssAudio_Shutdown |
| 0x4166D0 | SoundMgr_Is3DActive | V | init && [+0x1D] |
| 0x4166E0 | SoundMgr_GetPitchJitter | V | random % bank field B4, sign toggled via DAT_00591DF5 |
| 0x4167C0 | SoundMgr_InsertRequestSorted | V | memmove into sorted index (0xD9C + buf*16) |
| 0x416880 | Fix16_PtrToInt | V | *p >> 14 (also used by NearestSprite_SpiralSearch) |
| 0x416890 | SoundMgr_RecalcRequestRemaining | V | bank size * S6[+8] / freq into request+0x44, -3 when no loop |
| 0x4168E0 | SoundMgr_GetPosRelativeToListener | V | Fix16_Sub with +0x1468/146C/1470 |
| 0x416940 | Fix16_ToFloatStore | V | stdcall(Fix16, float*) |
| 0x416960 | SoundMgr_ScaleVolumeByDistanceFade | V | linear fade in last 1/4 of radius |
| 0x4169A0 | SoundMgr_ResetRequestSortIndex | V | fills sort index with numVoices, count=0 |
| 0x4169E0 | SoundMgr_ResetVoices | V | init 16 voices (0xDC0, 0x68 each) |
| 0x416B20 | SoundMgr_ReseedRandoms | V | 5x random32 into +0x1454 |
| 0x416B50 | Ped_GetZ | V | writes *(Ped+0x1B4) to out; sibling of Ped_GetX/Y; 46 callers |
| 0x416B70 | Camera_GetFollowedPed | V | returns +0x34; nonzero -> ped branch in 417030 |
| 0x416B80 | Car_GetBodyPos | V | reads Car+0x50 -> +0x14/18/1C (Position*) |
| 0x416BB0 | Car_GetBodyRotation | V | reads u16 at *(Car+0x50) |
| 0x416BF0 | SoundMgr_ShutdownIfInitialized | V | wrapper on S6[0] |
| 0x416D60 | SoundMgr_ReacquireAudioDevice | V | AIL_digital_handle_reacquire |
| 0x416DA0 | SoundMgr_CalcDistanceVolume | V | clamp 0..0x7F; called by 4116F0 |
| 0x416E50 | SoundMgr_CalcPan | V | pan 10..0x75 from relative X, table at 0x591DF8 |
| 0x416F20 | SoundMgr_ApplyDopplerToFrequency | V | scales freq by relative speed vs DAT_005E2228 |
| 0x417030 | SoundMgr_UpdateListenerAndSources | V | listener from player ped/car, loop active list calling UpdateSource |
| 0x4171A0 | SoundMgr_QueueRequest | V | 39 xrefs; copies S6+0x30 (0x68 B) into queue; key (0x7F-vol)*[+0x4C] |
| 0x417260 | SoundMgr_RequeueRepeatingRequests | V | replays previous buffer entries with remaining counter (+0x4C of record) |
| 0x417410 | SoundMgr_ApplyRequestsToVoices | V | MssAudio_Sample[3D]_* calls |
| 0x417CE0 | SoundMgr_Apply3DDistanceFade | V | only when 3D; __ftol2 + 416960 |
| 0x417D90 | SoundMgr_VocalSlots_Ctor | V | vector_constructor_iterator(+0x5468,0x1C,5) |
| 0x417EA0 | SoundMgr_UpdateFrame | V | flip buffer, UpdateListener, Requeue, Fade, Apply, age slots |
| 0x417EF0 | SoundMgr_Ctor | V | defaults |
| 0x418050 | SoundMgr_Update | V | pause handling + every-5th-frame flag +0x544C |
| 0x418100 | SoundMgr_PlayPhoneCallChatter | V | ExtraSample_PlayRange with random 0x45../0x57.. or 0x73../0x83.. |
| 0x4181C0 | SoundObj_GetAmbientType | V | byte +0x26 |
| 0x4181D0 | SoundObj_IsAmbientEmitter | V | *(info+8)+0x34 == 0xC |
| 0x4181E0 | SoundMgr_UpdateAmbientObjectSource | V | 8 KB switch types 3..0x33; per-type cooldowns DAT_005E24xx |
| 0x41A3C0 | SoundMgr_UpdateObjectSourceByType | V | switch on FUN_0040FEF0(obj) (5,0x71,0x80,0x8B,0xA4..,0xB9..,0xC5) |
| 0x41B030 | SoundMgr_UpdateObjectSource | V | picks 4181E0 or 41A3C0 |
| 0x41B060 | SoundMgr_TickPedSpeechCooldown | V | DAT_005E2B98 6->0 |
| 0x41B090 | PedGameObject_GetState2 | H | returns +0xC; sole caller UpdatePedSource |
| 0x41B0B0 | Ped_ConsumePendingSpeechEvent | V | read +0x250 then zero |
| 0x41B0D0 | SoundMgr_UpdatePedSpeech | V | event 1..0x1C -> sample ranges 0xD2..0x13x |
| 0x41B7B0 | SoundMgr_UpdatePedSource | V | callees Ped_HasWeapons, Player_GetCurrentCar, Sprite_GetSpeed, 41B0D0 |
| 0x41BF60 | PoliceRadio_ClearQueue | V | fills 15 entries with 0x79, idx 0 |
| 0x41BF90 | PoliceRadio_QueuePhrase | V | ring buffer, id clamp 0x45..0x88 |
| 0x41C000 | PoliceRadio_PumpQueue | V | plays next phrase when ExtraSample finished |
| 0x41C0D0 | PoliceRadio_GetFreeQueueSlots | V |  |
| 0x41C0F0 | SoundMgr_NoOp | V | single ret |
| 0x41C100 | unsure_PoliceRadio_QueueType8FollowUpPhrases | H | queues 0x79,0x5F,0x5B,0x78 when >3 free |
| 0x41C150 | PoliceRadio_FindDistrictAtPos | V | zone type 3 named m## |
| 0x41C200 | PoliceRadio_Reset | V |  |
| 0x41C240 | PoliceRadio_QueueLocationPhrases | V | compass 0x73..0x77 + district 0x79+n |
| 0x41C350 | PoliceRadio_QueueCarDescription | V | colour (sprite id) + model class; caller PoliceRadio_Update |
| 0x41C5A0 | PoliceRadio_QueueCrimeReport | V | caller PoliceRadio_Update |
| 0x41CC70 | Weapon_GetField04 | V | int at +4, must be 0 in UpdateWeaponSource; also used by unsure_Ped_FollowTarget |
| 0x41CC80 | Weapon_ConsumeFiredFlag | V | read +0x2C then zero |
| 0x41CC90 | Weapon_GetWeaponType | V | +0x1C |
| 0x41CCA0 | SoundMgr_UpdateWeaponSource | V | kind 7; sample 0x137..0x13F by weapon type |
| 0x41D010 | WorldObject_Dtor | H | zeroes +0,+4,+8,+0x10; caller WorldObjectPool_Ctor |
| 0x41D030 | WorldObject_ScalarDeletingDtor | H | 0 xrefs |
| 0x41D070 | EmptyBase_Ctor | V | returns this; callers PoliceRoadblock_Ctor, TrafficSpawner_Ctor |
| 0x41D8A0 | ComboEntry_Reset | V | defaults (-1, 0x57, 0x33, ..) |
| 0x41D8F0 | thunk → ComboEntry_Reset | V | thunk |
| 0x41D950 | ComboList_FindFreeEntry | V | first entry with +0x2A == 0, else 10 |
| 0x41D980 | ComboList_PollEntry | V | returns -1 inactive, -2, -3 done, -4; caller ScriptThread_GetBonusResult |
| 0x41D9D0 | ComboEntry_MatchField14 | V | pattern groups for param_7 |
| 0x41DA60 | ComboEntry_MatchOccupation | V | pattern groups 0x2E..0x31 for param_4 |
| 0x41DB10 | ComboEntry_MatchCarModel | V | groups {3,0xC,0x16,0x1E,0x34,0x36,0x54}, wildcards 0x33/0x38 |
| 0x41DD20 | ComboList_FindMatchingEntry | V | scans 10 entries; caller ComboList_Add |

#### Camera, doors, CarManager, Position (0x41DE00–0x42179F, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x41DE40 | ComboList_AddBonusCheck | V | 0x2c-byte slot, 10 slots (10 = full), caller Script_Op_START_BONUS_CHECK |
| 0x41DF70 | Camera_StorePrevPos | V | cameraPos2(0x88) := cameraPos(0x98) |
| 0x41DFB0 | Camera_ResetElevationOffset | V | +0x40 = 0 |
| 0x41E010 | Camera_ResetSmoothing | V | 0x98 := 0x0, velocity(0xac) := 0; Player_Watch*/OnWasted/OnBusted/OnLevelStart/WARP_FROM_CAR_TO_POINT |
| 0x41E350 | Box3_SetXYRanges | V | writes [0..3] = xmin,xmax,ymin,ymax (use in 41f180) |
| 0x41E370 | Box3_SetZRange | V | writes [4],[5] |
| 0x41E390 | Bounds_IsSquareAndSmall | H | a==b && a<=DAT_005e3e10 |
| 0x41E3D0 | Camera_SetTarget | V | target x,y, z=p3+elev(0x40), w |
| 0x41E410 | Camera_CommitTarget | V | cameraPosTarget2 := cameraPosTarget |
| 0x41E480 | Camera_IsTrackingSprite | V | compares with followCar(0x38) / ped(0x34)'s car |
| 0x41E4E0 | Camera_IncreaseElevationOffset | V | +0x40 += step, clamp; Player_ApplyDebugZoomKeys |
| 0x41E510 | Camera_DecreaseElevationOffset | V | +0x40 -= step, clamp at 0 |
| 0x41E540 | Camera_ClampTargetZ | V | +0x18 clamped to [0, DAT_005e3d54] |
| 0x41E580 | Camera_ShiftTargetByCameraDelta | V | target += (cameraPos - cameraPos2) of other camera |
| 0x41E710 | Camera_IsWorldPointOnScreen | V | WorldPointToScreen, 0<=x<640, 0<=y<480 |
| 0x41EAD0 | Camera_SetShake | V | +0x30 = const * arg |
| 0x41EB00 | Camera_ApplyShake | V | +0x30 added to pos xyz, then *= -DAT_005e4008 (damped) |
| 0x41EB70 | Camera_SetViewSize | V | 0x68/0x6c w/h, 0x70/0x74 half, 0x60/0x64=-1, uiScale(0xa8)=w/640 |
| 0x41EEF0 | Camera_UpdatePanOffsetFromKeys | V | 4 key flags -> ramps 0x48/0x4c, counters 0x50-0x5c |
| 0x41F0A0 | Camera_ResetPanVelocity | V | Vec2_SetZero(0x48), zero 0x50-0x5c |
| 0x41F0D0 | Camera_ApplyPanOffset | V | adds 0x48/0x4c * scale |
| 0x41F180 | Camera_IsPositionInView | V | Box3 around camera vs sprite bounds |
| 0x41F2F0 | Camera_Tick | V | followState(0x3c) 1 smooth / 2 snap, shake, UpdateBoundaries, commit |
| 0x41F680 | CarDoor_RequestOpen | V | state 1/2 -> timer(+0xc)=0x32; 3..6 -> state 2, byte1=4 |
| 0x41F6E0 | Car_IsPoliceModel | V | model in {12,52,84} |
| 0x41F880 | Car_GetDoorCount | V | CarInfo_GetDoorInfo(model)[0] |
| 0x41F8A0 | Car_OpenAllDoors | V | loop CarDoor_RequestOpen |
| 0x41F8F0 | Car_CloseAllDoors | V | loop CarDoor_RequestClose |
| 0x41F9B0 | DamageFire_GetEffectTypeForStage | V | 1->0xc,2->0xd,3->0xe; Car_SpawnDamageFireEffect |
| 0x41FA60 | Car_IsInCrusherList | V | wrapper of FUN_0044a3a0 (crusher array, count +0x90, stride 0x30, car at +0x14) |
| 0x41FAB0 | Car_GetTrailerCabOrSelf | V | Car+0x64 ? (*+0x64)+8 : this |
| 0x41FAC0 | Car_GetCornerAngle | V | atan2(h/2,w/2) of CarInfo |
| 0x41FBD0 | Car_AttachGangDecal | V | SpawnObject(KILL_FRENZY+p), attach to sprite(0x50) |
| 0x41FC70 | Car_GetTrailerOrSelfBody | V | ctrl ? ctrl->[0xc]->+0x50 : +0x50 |
| 0x41FC90 | Ang16_RotateXY | V | x'=x cos + y sin, y'=y cos - x sin |
| 0x41FE40 | Fix16_SwapXYIfDir3or4 | V | swap when 2<p<5 |
| 0x41FE70 | RelTable_GetSigned | V | table[i] or -table[-i] |
| 0x41FF20 | CarInfo_GetRearWindowOffsetFix16 | V | relTable[this+0xb] |
| 0x41FF40 | CarInfo_GetFrontWindowOffsetFix16 | V | relTable[this+0xa] |
| 0x41FF60 | CarInfo_GetScaledWidthFix16 | V | relTable[this+2]*DAT_005e4fb4 |
| 0x420220 | StyleData_GetSpriteWidth | V | GetSpriteEntry(id)->w |
| 0x420230 | StyleData_GetSpriteSizeFix16 | V | relTable[w], relTable[h] |
| 0x420270 | Car_GetLookAheadZ | V | physics(0x58) ? CarPhysics_GetLookAheadZ : sprite+0x1c |
| 0x420470 | Box3_SetXYRangesWithZCenter | V | 4 stack args + z -+ DAT_005e4d50 |
| 0x4204D0 | Box3_SetFromCenterSize | V | 6 fields from center/size |
| 0x420590 | Fix16Holder_Load | V | *out = *this; callers 420720/420740/Ped_React... |
| 0x420660 | Position_SetZ | V | +0x1c + Position_MarkBoundsDirty |
| 0x4206E0 | Position_SetField22 | V | short +0x22 |
| 0x4206F0 | Position_SetCollisionKind | V | +0x30 + SetDefaultField28ByKind |
| 0x420710 | Sprite_SetOwner | V | CarManager_SpawnCar: FUN(car2->body, car2) writes body+8 = car |
| 0x420720 | Position_GetFrameWidth | H | Fix16Holder_Load(*(this+4)); Car_IsSpriteZDifferent |
| 0x420740 | Position_GetBodyWidth | H | Fix16Holder_Load(*(this+0xc)); CrusherSlot_Update, Car_IsSpriteZDifferent |
| 0x4207E0 | ListHead_Init | V | *this=0; Car_InitAttachments(&attachments), Crane_Init, WeaponManager_Ctor(&hitCarList), CarManager_Ctor(2 globals) |
| 0x420B50 | Ped_GetOwnerSlot | V | Ped+0x267 |
| 0x420B60 | Ped_GetId | V | Ped+0x200 |
| 0x420C30 | OwnerSlot_IsValid | V | slot<13 |
| 0x420D80 | CarDeltas_Ctor | V | Car_Ctor: FUN(&car->deltasBitstate) |
| 0x420D90 | CarDeltas_Reset | V | Car_Reset, Car_BecomeWreck on &deltasBitstate |
| 0x420DA0 | DynBuffer_ScalarDeletingDtor | V | DynBuffer_FreeAndReset + free; CarManager_FreePools |
| 0x420E00 | Position_ScalarDeletingDtor | V | thunk_FUN_004bbd10 + free; CarManager_FreePools |
| 0x420E40 | CarAIPool_ClearLast | V | *this=0 from CarAIPool_ScalarDeletingDtor |
| 0x420E60 | TrailerControllerPool_ClearHead | V | *this=0 from TrailerControllerPool_ScalarDeletingDtor |
| 0x420EA0 | PedQueue_IsEmpty | V | *p==0; Car_IsTaxiAvailableForHire, AmbulanceSlot_Update, Ped_UpdateTaxiPassenger |
| 0x420FF0 | WorldObject_GetOwnerSlot | V | byte +0x26, passed to OwnerSlotTable_GetPedId; Object type 0x84 (projectile) |
| 0x421020 | WorldObject_GetShopId | V | byte +0x26 of object type 0x82; only Car_OnEnterShop |
| 0x421030 | PositionPool_Free | V | unlink (FUN_004bdc40) + push, +0xc = next |
| 0x421050 | WorldObject_GetParamByte26 | V | byte +0x26; bonusTokenAllowed[], DoorManager_ShouldDoorBlock, surface code |
| 0x421080 | unsure_WorldObject_KindHasOwnerSlot | H | (*(this+8))+0x34 not in {1,6,7,8,9,10,12} |
| 0x4210B0 | WorldObject_IsPrefabGridKind3 | V | (*(this+8))+0x40 == 3; Sprite_ShouldCollideWithSprite |
| 0x4210C0 | CarAI_ClearParentCar | V | *p=0; CarAIPool_Free |
| 0x421150 | CarPhysics_GetLinearVelocity | V | Vec2 at +0x40 |
| 0x421170 | CarPhysics_SetLinearVelocity | V | Car_ZeroVelocity calls it with Car+0x58 |
| 0x421190 | CarPhysics_SetAngularVelocity | V | +0x74 = defaultX in Car_ZeroVelocity right after SetLinearVelocity |
| 0x4211C0 | Fix16Vec2_GetLengthOut | V | wrapper of Fix16Vec2_GetLength |
| 0x4211E0 | CarPhysics_GetVelocityAngle | V | Fix16Vec2_GetAngle(+0x40) |
| 0x421310 | CarDoor_Ctor | V | Car_Ctor eh_vector_constructor_iterator(car->carDoor,16,4,...) |
| 0x421340 | CarDoor_ClearState | V | state=0; Car_InitDoors |
| 0x421360 | CarDoor_IsActive | V | state not in {0,6} |
| 0x421380 | CarDoor_SetPedInDoor | V | +8=x; Ped_Obj2_EnterCar/LeaveCar, Car_InitDoors |
| 0x421430 | Car_ClearRearLightsOnDeltas | V | CarDeltas_ClearBit(5), (0x16); Car_AlarmStop, Car_BrakeLightsOff, Car_UpdateLightsAndSiren |
| 0x4214F0 | Car_IsDrivenByNonPlayer | V | Car+0x54 && !Ped_IsPedClass(PLAYER) |
| 0x421530 | Car_SetRouteBit3 | V | +0xa6 |
| 0x4215C0 | Car_HasPlayerDriver | V | driver->player && occupation != EMPTY |
| 0x421610 | Car_IsTrainModel | V | model == 0x3b (TRAIN) |
| 0x421740 | Car_IsFreeTrailer | V | !trailerController && IsTrailer |
| 0x421760 | Car_IsFreeArticCab | V | !trailerController && IsArticCab |
| 0x421780 | Car_IsMedicar | V | model == 0x22 (MEDICAR) |

#### Car lifecycle, pools, CarAI helpers (0x4217A0–0x42FFFF, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x4217B0 | Car_IsJeep | V | carModel==30 |
| 0x4217C0 | Car_IsApc | V | ==3 |
| 0x4217D0 | Car_IsGt24640 | V | ==19 |
| 0x4217E0 | Car_IsTvVan | V | ==67 |
| 0x421810 | Car_SetRoofDecalDelta | H | CarDeltas_SetBit(0xf), from SpawnCar |
| 0x421870 | Car_GetDriverPlayer | V | driver+0x15c |
| 0x421950 | Car_SetShopReaction | V | Car+0xb4 |
| 0x4219A0 | Player_IsWeaponAmmoFull | V | this+0x718+idx*4 -> Weapon_IsAmmoFull |
| 0x4219F0 | Hud_CarName_Hide | V | *p=0; from Car_OnDriverLeft |
| 0x421C00 | Car_GetMaxSpeed | V | engine.max_speed * Car_GetDamageFactorOnSpeed |
| 0x421C40 | Car_GetHitchWorldPos | V | const (trailer/car) rotated + body pos; caller trailer search |
| 0x421CB0 | Car_GetRearWheelOffsetVec | V | Vec2(0, physData+8) |
| 0x421DF0 | Car_IsOnSurface6 | V | physics+0x98 (surfaceType)==6 |
| 0x421E00 | Car_GetVelocityAngle | V | angle of physics+0x40 else body rotation |
| 0x421E70 | Car_GetVelocity | V | physics+0x40/44; train uses actor |
| 0x421EC0 | Car_GetSpeed | V | length of velocity, 0 w/o physics |
| 0x421EF0 | Car_GetMinHalfExtent | V | relToSpiteOfCar[min(w,h)] |
| 0x421F40 | Car_NeedsRemapChange | V | num_remaps>1 && spriteId!=remap |
| 0x421F80 | Car_NeedsRemapChangeWithTrailer | V |  |
| 0x421FD0 | Car_ApplyRemap | V | Position_SetRemap on car+trailer |
| 0x422260 | Car_UnlinkFromWorld | V | RemoveSprite x2, CarPool_UnlinkUsed, SetDetached |
| 0x4222D0 | Car_ResumeAICruise | V | ai+0x18=DAT_5e4dc4; Car_ResumeAI; 12 callers |
| 0x4224A0 | unsure_Car_IsDoorOffCentre | H |  |
| 0x422500 | Car_GetDoorWorldPos | V |  |
| 0x422980 | Car_SirenRearLightsOffA | V | called by Car_SirenOff; bits 0x12/0x11, obj 0xac/0xad |
| 0x422A40 | Car_SirenRearLightsOffB | V | called by Car_SirenOff; bits 0x12/0x11, obj 0xac/0xad |
| 0x422AA0 | Car_SirenLightsOnA | V | bit 0x10, obj 0xa5 (+0xac swat/fire) |
| 0x422B70 | Car_SirenLightsOffA | V | bit 0x10, obj 0xa5 (+0xac swat/fire) |
| 0x422BD0 | Car_SirenLightsOnB | V | bit 0xf, obj 0xab (+0xad) |
| 0x422CB0 | Car_SirenLightsOffB | V | bit 0xf, obj 0xab (+0xad) |
| 0x422E00 | Car_SetNumberGraphic | V | clear bits 0xb..0x14, set 0xb+idx |
| 0x4230D0 | Car_IsDamagePosBroken | V | idx 0..4 -> bits 2,3,1,0,4 |
| 0x4232E0 | Car_ZeroVelocity | V | linVel=zero, angVel=0 |
| 0x423310 | Car_IsFrameWidthChanged | H |  |
| 0x4233B0 | Car_ShrinkFrameBounds | H |  |
| 0x423480 | Car_GetEffectiveDriver | V | trailer -> cab driver |
| 0x423590 | Car_ShowCarNameForLocalPlayer | V | Hud_CarName_Show |
| 0x423630 | Car_StepTurretToward | V | attach 0x72/0x94/0xf8 |
| 0x4237B0 | Car_InitAIWithRouteTarget | V | AllocAI+SetParentCar+SetRouteTarget(x,y,z,flag); identical copies |
| 0x4237F0 | Car_InitAIWithRouteTargetB | V | AllocAI+SetParentCar+SetRouteTarget(x,y,z,flag); identical copies |
| 0x423850 | Car_UpdateBrakeLightsFromFootBrake | V |  |
| 0x423A70 | Car_AreAllDoorsSettled | V | all 4 doors state 0 or 6 |
| 0x423B50 | Car_UpdateForHireLight | V | engine on && no passenger |
| 0x423C30 | Car_UpdatePopupLightsAnim | V | every 3rd frame shifts bits 0xb..0xe, 0x1c..0x1f |
| 0x424360 | Car_UpdateAttachmentLightByLid | V |  |
| 0x4243C0 | Car_GetSpriteLayerForState | V | 0xe / 0x14 / 0x11,0x16 |
| 0x424E30 | Car_CanPedEnter | V |  |
| 0x424F80 | Car_IsEnterCandidateForSearchPed | H |  |
| 0x424FF0 | Car_TryPlaceOnRoadColumn | V | scans up to 200 tiles for arrow block, teleports car if unseen |
| 0x4253C0 | CarAIPool_ScalarDeletingDtor | V | called from CarManager_FreePools |
| 0x4253E0 | TrailerControllerPool_ScalarDeletingDtor | V | called from CarManager_FreePools |
| 0x425400 | CarPool_Dtor | V | 306 x 0xbc / 306 x 0xb0 |
| 0x425430 | CarPhysicsPool_Dtor | V | 306 x 0xbc / 306 x 0xb0 |
| 0x425450 | PedQueue_Ctor | V | ResetIntPtr |
| 0x4254F0 | CarAIPool_PushFree | V | item+0xc=head; head=item |
| 0x425650 | Car_ClearLightDeltaBits | V |  |
| 0x425780 | Car_HasFlag1000 | V |  |
| 0x425790 | Car_GetModelInertia | V |  |
| 0x4257B0 | Car_CanBeResprayed | V | "nespray" brief otherwise |
| 0x425A40 | Car_IsDoorExitClear | V |  |
| 0x425B60 | Car_IsPavementBesideDoor | V |  |
| 0x425D60 | Car_IsBlastImmune | H |  |
| 0x4268C0 | Car_TryPlaceOnArrowTileAt | V | wrapper; caller CarAI_UpdateDriveOrder |
| 0x426D70 | CarPool_ScalarDeletingDtor | V |  |
| 0x426D90 | CarPhysicsPool_ScalarDeletingDtor | V |  |
| 0x426EE0 | Car_RepairWithTrailer | V |  |
| 0x427B20 | Car_DetachTrailerAndBlockReattach | V |  |
| 0x427CA0 | Car_TryRespray | V |  |
| 0x4295C0 | Car_ArmOrDetonateBomb | V | spawn CAR_BOMB or TriggerExplosion(0x14) |
| 0x429800 | Car_DropTrailerIfAny | V |  |
| 0x429FC0 | Car_UpdateSystemsAndWreckTimer | V |  |
| 0x429FF0 | Car_FollowParentSpritePose | V |  |
| 0x42A500 | CarManager_ResetJunctionReserveCooldown | V | DAT_5e5090=0 (ReserveJunction counter) |
| 0x42A5B0 | Car_StartHonkIfAllowed | V | if Car_IsPoliceModel(0x41F6E0): Car.hornState(+0xa7)=0x2d |
| 0x42A5D0 | CarAI_IsExitDirRightTurn | V | (travelDir,turnExitDir) = (1,3)(2,4)(3,2)(4,1) |
| 0x42A620 | Fix16_AssignFromChar | V | *this = c<<14 |
| 0x42A630 | Fix16_Frac | V | *y & 0x3fff |
| 0x42A660 | HeadingClass_Opposite | V | 1<->2, 3<->4, else 0 |
| 0x42A6B0 | Fix16_ChebyshevDist | V | max(abs(bx-ax),abs(by-ay)); 57 xrefs |
| 0x42A720 | Vec2_ToLocalFrame | V | rotates (p-o) by Ang16 |
| 0x42A830 | MapBlocks_GetColumnEntryPtr | V | this+(y*256+x)*4 |
| 0x42A850 | MapBlocksRef_GetBlock | V | column entry -> block by z |
| 0x42A9B0 | CarAI_RaiseCurSpeed | V | if cur(+0x14)<v then cur=v |
| 0x42A9E0 | CarAI_Ctor | V | zeroes CarAI, routeSlot=-1, flags=(flags&0xFFC12010)\ |
| 0x42AAC0 | CarAI_Reinit | V | same without Ang16 ctor |
| 0x42ABE0 | CarPhysics_SetReverseGasOnly | V | writes +0x91/93/94/95 |
| 0x42FE80 | CarAI_UpdateSpeedRamp | V | cur->goal by step(+0x1c), then ReleaseControls; caller CarAI_FollowRoad (rail) |

### Names added by Seq 47 (slice 1): drive-order pool helpers, taxi list

All "HasAlliedManeuver…" scan the 20-entry `CarDriveOrderPool` for an in-use order whose driver (+4) is allied (`Ped_AreAllied`) with the given ped and whose maneuver (+0xC) is in the set; only caller `CarDriveOrder_Drive` (maneuver meanings still open).

| Address | Name | Conf | Evidence |
|---|---|---|---|
| 0x433120 | TaxiList_PopFront | V | `*head = head->next(+4)`; caller TaxiList_Add |
| 0x433130 | TaxiList_PushFront | V | `node->next = *head; *head = node`; caller TaxiList_Clear |
| 0x4462E0 | CarDriveOrderPool_DtorBody | V | eh vector dtor 20 x 0x40; caller CarDriveOrderPool_Dtor |
| 0x446340 | CarDriveOrderPool_FindAlliedDriverByManeuverTargetingPed | V | targetPed(+0x30)==ped, allied, maneuver==arg → driver |
| 0x4463C0 | CarDriveOrderPool_CountAlliedDriversTargetingPed | V | counts orders with targetPed==arg1, driver allied with arg2 |
| 0x446410 | CarDriveOrderPool_HasAlliedManeuver0D0F | V | maneuver 0xD/0xF |
| 0x446480 | CarDriveOrderPool_HasAlliedManeuver08 | V | maneuver 8 |
| 0x4464E0 | CarDriveOrderPool_HasAlliedManeuver060810 | V | maneuver 6/8/0xA |
| 0x446550 | CarDriveOrderPool_HasAlliedManeuver09 | V | maneuver 9 |
| 0x4465B0 | CarDriveOrderPool_HasAlliedManeuver07090B | V | maneuver 7/9/0xB |
| 0x446620 | CarDriveOrderPool_HasAlliedManeuver06To09Or0D | V | maneuver 6..9 or 0xD |
| 0x446690 | CarDriveOrderPool_HasAlliedManeuver04To05 | V | maneuver 4..5 |
| 0x446AA0 | unsure_CollisionHit_IsObjectPrefabSolidVsCar3 | U | hit kind==3 and obj->+8->+0x4C==3; caller CarPhysics_StepAndResolveCollisions |
