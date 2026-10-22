# Gangs, respect and pedestrian population in gta2.exe 11.44

How vanilla GTA2 declares gangs, keeps gang respect, spawns and removes pedestrians, sends
ambulances and fire trucks, and decides who attacks whom, read from the binary. Every address is a
VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`); every name is in the Ghidra DB
(`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and therefore in `re/`.

Tags: **V** = the body was read in the 11.44 decompiler and cross-checked with a caller/callee or
a second source; **H** = hypothesis (names carry `unsure_`). Positions are Q14 fixed point
(`0x4000` = 1 block); "tick" = one `GameTick` (≈30 Hz). Constants that are zero in the file and set
by CRT static initialisers come from [`re/static_constants.csv`](../../re/static_constants.csv).

Sources: own decompiler work (Seq 36), the Seq 27 traffic pass (ambulance/fire-truck leads,
verified here), struct names from gta2-seuko-mod / gta2-resurection / gta2-mouse (see
[CREDITS.md](../../CREDITS.md)), gang data decoded from `data.pak` with
`tools/formats` (`scr --gangs`, `gmp --gangs`).

> **Misleading enum names in the DB.** `Ped_CheckBitState2` / `Ped_SetBitState2` (0x4333a0 /
> 0x403920) compare / write **`Ped.pedClass` (+0x238)**, not a bit field. A decompiled
> `Ped_CheckBitState2(ped, FIRING_FROM_GUN)` is really `pedClass == 2 (PLAYER)`;
> `PED_BIT_STATE2_3_COP_RELATED` = 3 (AMBIENT), `UNK_4_POLICE` = 4 (SPECIAL_AI), `UNK_6` = 6
> (CAR_DRIVER). Reported to Seq 27 (Ped owner) for renaming. This document uses the real meaning.

## 1. Structures

### `GangRespect` (= one gang, 0x144 bytes) (V)

There is no separate gang table: `g_GangRespect` (`0x5EB898`) points to a `GangRespectContainer`
= **10 gang slots × 0x144**. The gta2-mouse duplicates `Gang`/`Gangs` were merged into these
types (2026-10-22).

| off | size | field | meaning / evidence |
|---|---|---|---|
| 0x00 | u8 | `present` | slot used (`GangRespectContainer_AllocGang` 0x45dc20) |
| 0x01 | u8 | `id` | slot index 0..9 |
| 0x02 | char[255] | `gangName` | zone name, e.g. `yakuzagang`; `Gang_SetName` copies up to 0xFF bytes + NUL (`zaibatsugang` already overflows a [10]); identity = first 4 chars |
| 0x101 | u8 | `pedRemap` | ped remap of members (init 1) |
| 0x104 / 0x108 / 0x10C | i32 | `basicWeapon` / `angryWeapon` / `hateWeapon` | WEAPON_INDEX |
| 0x110 | u8 | `highRespectFlag` | `respect > 79` of the **last changed** player (single flag) — gang attacks cops (§4) |
| 0x111 | u8 | `killAffectsRespect` | set by SET_GANG_KILL_REACTION / SET_GANG_CHAR_RESPECT |
| 0x112 | u8[10] | `hostileToGang[otherId]` | init **1** for every pair, no writer found → all gangs hate each other |
| 0x11C | s8[6] | `respect[player]` | −100..+100, one per `Game.players[6]`; init zeroes it as dword@0x11C + word@0x120 (Ghidra still has 0x120 as a separate `undefined2` until a Clear) |
| 0x122 | s8[10] | `killReaction[otherId]` | init 0; SET_GANG_KILL_REACTION |
| 0x12C / 0x130 / 0x134 | Q14 | `arrowTargetX/Y/Z` | HUD arrow target from SET_GANG_INFO |
| 0x138 | u8 | `arrowColour` | gang icon id 1..7: HUD sprite `0x3F+n`, name `ganga%d`, car decal `KILL_FRENZY+n` |
| 0x139 | u8 | `hasRespectMeter` | 1 = HUD meter, loses respect on own-member kill, spawns gang cars |
| 0x13C | i32 | `carModel` | gang car (init 1) |
| 0x140 | u8 | `carRemap` | 0xFF = none |
| 0x141 | u8 | `weaponsLocked` | set when an ambient member spawns with a non-pistol; then always `basicWeapon` |

### Ped pool and `DummyPedManager` (V)

- **Pool**: `PedManager_S25` (gzf `PedsManager` merged into it, 0x203AC bytes, `ptrToPedManager` 0x5E5BBC, built by
  `DummyPedManager_Ctor` 0x4416b0): `+0 freeListHead`, `+4 activeListHead`, `+8 peds[200]` (660 B
  each, linked by `Ped.nextPed`), `+0x203A8 activeCountLastTick`. **200 peds** for everyone
  (ambient, cops, mission, gang drivers, player). `PedManager_AllocPed` 0x403890 pops the free list
  **without an empty check**.
- A **"dummy" is not a separate type**: it is an ordinary pool `Ped` with `pedClass = 3` (AMBIENT),
  `occupation = 3` (DUMMY), `graphicType = 0`. There is no dummy↔full conversion.
- `DummyPedManager` (12 B, `g_DummyPedManager` 0x5E5BC0) is only the spawn controller:

| off | size | field | meaning |
|---|---|---|---|
| 0 | i16 | `targetCount` | ambient cap, **50** (ctor) |
| 2 | u8 | `ambientPeds` | last tick's ambient count (copied from `g_AmbientPedCountThisTick` 0x5E5BEA) |
| 3 | u8 | `activePeds` | |
| 4 | u8 | `missionPeds` | |
| 5 | u8 | `emergencyPeds` | paramedics need `< 30` |
| 6 | u8 | `onScreenPeds` | compared with zone density / 25 |
| 7 | u8 | `makeAllCharsMuggers` | MAKE_ALL_CHARS_MUGGERS op |
| 8 | Sprite* | `spawnProbe` | |

### `MapZoneInfo` (22 bytes, new) (V)

Per-zone traffic/population record, 11 × u16, reached through `GetDensity` 0x465250 (first zone of
type 10/1/15 at the point, else default slot 0 at `MapBlocks+0x334`). Defaults set by `processS11`:

| off | field | default | script op |
|---|---|---|---|
| +0x0 | carDensity | 500 | SET_CARDENSITY |
| +0x2 | goodCarRatio | 300 | |
| +0x4 | badCarRatio | 300 | |
| +0x6 | policeCarRatio | 100 | |
| +0x8 | gangCarRatio | 0 | SET_GANGCAR_RATIO (0x174) |
| +0xA | pedDensity | 500 | SET_PEDDENSITY (0x6b) |
| +0xC | muggerRatio | 50 | SET_MUGGER_RATIO (0x6c) |
| +0xE | carThiefRatio | 40 | SET_CARTHIEF_RATIO (0x6d) |
| +0x10 | elvisRatio | 10 | SET_ELVIS_RATIO (0x6e) |
| +0x12 | gangPedRatio | 200 | SET_GANG_RATIO (0x6f) |
| +0x14 | policePedRatio | 40 | SET_POLICEPED_RATIO (0x70) |

Setters: `MapBlocks_SetZone*` 0x462ce0..0x462e20; MAP_ZONE decl → `MapBlocks_SetZoneInfoAll`
0x465280 (−1 = keep). Ratios are per mille of `random(1000)`.

### Emergency-service structures (V)

- `AmbulanceManager` (0x110, `g_AmbulanceManager` 0x663DE4; seuko `Ambulance` merged into it):
  `+0 enabled`, `+1 pendingCount` (queued corpses, cap 25), `+4 pedQueue` (list head; nodes from the
  global ped-list pool), `+8 table[50]` (zeroed, unused), `+0xD0 slots[2]`.
- `AmbulanceSlot` (0x20; seuko `AmbulanceSub` merged into it): `+0..2 spawnTileX/Y/Z` (u8), `+4 vehicle`
  (EmergencyVehicleSlot*), `+8 driverTargetPed`, `+0xC passengerTargetPed`, `+0x10 pedQueue`,
  `+0x14 queuedCount` (< 10), `+0x18 state` (1 active), `+0x1C idle`, `+0x1D reviveTicks`.
- `EmergencyVehiclePool` (`g_EmergencyVehiclePool` 0x672B90): **10 × `EmergencyVehicleSlot`
  (0x30), shared with police crews**. Fields added here: `+0x18 timer` (300 for paramedics),
  `+0x1A offscreenLimit` (150), `+0x1C spawnWaitTicks` (ambulance gives up at > 500),
  `+0x20 crewType` (1 paramedic → model 0x22 MEDICAR; 3 → 0x0C COPCAR; 5 → 0x34 SWATVAN),
  `+0x24 phase` (0 crew on foot/car lost, 1 in car, 2 finished), `+0x28 stage` (3 spawn car,
  5 leaving, 6 active), `+0x2C stageDone`.
- `FireEngineManager` (0x54, `g_FireEngineManager` 0x5EA9CC): 2 × `FireEngineSlot` (0x28) +
  `+0x50 nextSerial`. Slot: `+0 serial`, `+4 active`, `+8 state` (1..6), `+0xC targetCar`,
  `+0x10/14/18 spawnX/Y/Z` (tile + 0.5), `+0x1C truck`, `+0x20 driver`, `+0x24 timer`.

### `PedSprite`, `S36`, `S32` — not ped structures (V)

- `PedSprite` (gzf 2021, 0x20) is a truncated view of **`Sprite`** (0x3C), the collision/render
  body (`PedGameObject+0x80`), pool `SpritePool` (5031 × 0x3C), used by peds,
  cars and objects: `+8` owner, `+0x22` frame, `+0x24` remap, `+0x30` kind (2 car, 3 ped),
  `+0x34` render state.
- `S32` (gta2-mouse) = existing `WorldObject` (3825 × 0x2C, object.cpp); `S31` (merged) =
  `WorldObjectPool`.
- `S36` = per-object motion state of dynamic objects (pool `S35`, 385 × 0x3C, `DAT_00665780`),
  renamed **`ObjectMotionState`**.
- The ped body (`PedGameObject`) pool is 400 × 0xB4 (`PedGameObjectManager`); `Ped_CreateSprite` 0x4360c0 pops it.

## 2. Gangs: declaration and zones (V)

1. `startGame` 0x45b5f0 → `MapBlocks_RegisterGangZones` 0x465390: every map ZONE of **type 14**
   → `GangRespectContainer_AddFromZone` 0x45dc90: new slot unless `FindByName` already matches.
2. `GangRespectContainer_FindByName` 0x45dbb0 matches **the first 4 characters**,
   case-insensitive (`__strnicmp(..., 4)`): `zaibgang` (ste, bil) and `zaibatsugang` (wil) are the
   same key `zaib`. Max 10 gangs.
3. `SET_GANG_INFO` (op 223, `Script_Decl_SET_GANG_INFO` 0x477bd0; args: u16 name string id, u8
   remap, u8 basic/angry/hate weapon, u8 arrowColour, u8 hasRespectMeter, 3 × i32 Q14 arrow
   target, u16 car model, u8 car remap) fills the slot found by name.
4. `SET_GANG_KILL_REACTION` (op 224): `A.killReaction[B.id] = v`, both `killAffectsRespect = 1`.
5. `ADD_CHAR_TO_GANG` (op 258) writes `Ped+0x17C gang`.
6. `Player_UpdateZones` 0x4a6100 (every tick): `Player+0x34 gangZone =
   MapBlocks_FindGangAtPos` 0x465350 (type-14 zone at the player). `IS_CHAR_IN_GANGZONE` (232)
   compares it (non-player peds: re-lookup and name compare).

Shipped data (`bun tools/formats/cli.ts scr data/<m>.scr --gangs`, `gmp data/<m>.gmp --gangs`):

| map | gang (tag) | remap | basic / angry / hate | icon | meter | car / remap | zones (blocks) |
|---|---|---|---|---|---|---|---|
| wil | yakuzagang (yaku) | 13 | 0 / 0 / 0 | 2 | 1 | 37 / 15 | 4 (12639) |
| wil | zaibatsugang (zaib) | 8 | 0 / 0 / 0 | 3 | 1 | 70 / 2 | 4 (13909) |
| wil | looniegang (loon) | 11 | 0 / 0 / 0 | 1 | 1 | 29 / 16 | 4 (5485) |
| ste | redngang (redn) | 5 | 0 / 1 / 4 | 4 | 1 | 41 / 3 | 3 (11918) |
| ste | sciegang (scie) | 7 | 0 / 1 / 8 | 5 | 1 | 48 / 10 | 2 (12843) |
| ste | zaibgang (zaib) | 8 | 0 / 10 / 1 | 3 | 1 | 70 / 2 | 3 (12640) |
| ste | almagang (alma) | 22 | 28 / 28 / 28 | 3 | 0 | 70 / 2 | 2 (3848) |
| ste | poligang (poli) | 0 | 0 / 0 / 0 | 3 | 0 | 70 / 2 | 1 (110) |
| bil | krisgang (kris) | 9 | 0 / 4 / 8 | 6 | 1 | 86 / 255 | 3 (13208) |
| bil | zaibgang (zaib) | 8 | 0 / 9 / 2 | 3 | 1 | 70 / 2 | 1 (14934) |
| bil | russgang (russ) | 10 | 0 / 6 / 1 | 7 | 1 | 10 / 28 | 4 (18077) |
| bil | islagang (isla) | 6 | 0 / 6 / 1 | 0 | 0 | 18 / 30 | 2 (2000) |

Weapons: 0 pistol, 1 SMG, 2 rocket launcher, 4 molotov, 6 (H shotgun), 8 flamethrower, 9 car SMG,
10 dual pistol, 28 outside the enum. Kill reactions shipped (all value 1) form a ring per city:
wil loonie→zaibatsu, yakuza→loonie, zaibatsu→yakuza; ste redn→zaib, scie→redn, zaib→scie;
bil kris→zaib, zaib→russ, russ→kris. ste and bil also start with `CHANGE_GANG_CHAR_RESPECT −5`
(= −100) for `poligang` / `islagang`.

## 3. Respect (V)

Storage: `GangRespect.respect[player]`, signed byte, clamped **−100..+100** (`Gang_AddRespect`
0x45da40 saturates at +100 including char wrap; `Gang_SubRespect` 0x45da80 at −100; both rewrite
`highRespectFlag = respect > 79`). Scripts and the HUD see **steps = respect / 20** (−5..+5).

Every writer:

| source | function | change |
|---|---|---|
| player kills a gang ped | `Ped_OnKilled` 0x43d880 → `unsure_Ped_NotifyPlayerOfEvent` 0x434ff0 → `Gang_ApplyKillRespect` 0x45de10 | delta **5** (1 if victim `Ped+0x290` ∈ {1,3}); victim gang = `Ped+0x17C`, or `+0x19C gangAffiliation` for gang-skinned civilians; requires `killAffectsRespect` |
| `Gang_ApplyKillRespect(gang, p, d)` | 0x45de10 | own gang `-= hasRespectMeter × d`; every other gang j: `+= gang.killReaction[j] × d`, saturating at +100 (a negative reaction would also end at +100 — overflow check) |
| player wrecks / blows up / jacks a gang-model car | `Car_Explode` 0x426fa0, `Car_OnWrecked` 0x427290, `Ped_Obj2_EnterCar` 0x43d1c0, gang from `GangRespectContainer_FindByCarModel` 0x45dce0 | delta 1 (any car of that model) |
| op 225 SET_CHAR_RESPECT | `Gang_SetRespect` 0x45da20 | absolute `arg × 20` |
| op 262 CHANGE_GANG_CHAR_RESPECT | body at 0x47ab91 | `±arg × 20` (Add / Sub) |
| op 393 ..._AND_UPDATE | `Gang_ChangeRespectWithRivals` 0x45dea0 | this ±, rivals with `killReaction[this.id] != 0` the opposite way |
| RESPECT power-up (type 10) | `GivePowerUp` 0x4a5780 | **+20** in own gang zone |
| debug key | `Player_DebugChangeGangRespect` 0x4a4940 | +20, or −100 if > 99 |
| cheats | `Player_ApplyStartCheats` 0x4a6da0 | max respect → 100; bonus pack → 80 |
| checkpoint / ops 445–446 | `Player_SaveCheckpoint` 0x4a6b20, `Player_LoadCheckpoint` 0x4a6c80, 0x47ebe0 | save/restore all 10 bytes |

Mission pass/fail never writes respect directly; missions use ops 225/262/393.

Thresholds:

- **Hostile to the player: `respect < −19`** (`Gang_IsHostileToPlayer` 0x45dae0, `cmp byte, 0xED`),
  i.e. one step below zero.
- Weapon (`Gang_PickWeaponByRespect` 0x45db70, **player 0 only**, single player, not
  `weaponsLocked`): `== −100` → hate weapon, `< −59` → angry weapon, else basic.
- `CHECK_RESPECT` ops 198/199/231 compare steps with the argument.
- HUD meter (0x4c74f0): frown at `< −19` (blinks at −100), icons at `> 39` and `> 79`.
- Gang attacks cops when `highRespectFlag` (`> 79`) — §6.

## 4. Pedestrian population (V)

Call graph (every tick, no divisor):

```
GameTick 0x45c1f0
└─ DummyPedManager_Update 0x445a20
   ├─ PedManager_UpdateActivePeds 0x445960      each active ped: Ped_Update 0x4454e0 (counts per class,
   │                                            Ped_UpdateState 0x43ecc0 = despawn rules); finished → free list
   ├─ copies the per-tick counters into DummyPedManager
   └─ DummyPedManager_SpawnForAllCameras 0x4415e0   (skipped by debug flag g_skipDummies 0x5ead69)
      └─ for each player camera (Game_CameraIter_Begin/Next 0x45a800/0x45a850: main + aux)
         └─ DummyPedManager_TrySpawnAtCameraEdge 0x440cc0
            └─ DummyPedManager_SpawnAmbientPed 0x4404f0
```

**Cap** (0x4415e0): `cap = targetCount` (50), **halved to 25 when `PoliceManager.copLevel > 3`**;
spawning only while `g_AmbientPedCountThisTick < cap`. Counted as ambient: pedClass 3, plus classes
4/6 whose threat reaction is not REACT_AS_EMERGENCY (muggers, thieves, gang members, Elvis). The
check is per camera, so a tick can overshoot by up to 2 (6 for an Elvis group).

**Attempts**: 1 per tick per camera when the camera target moves (`> 0`), 2 when it is still.

**Where** (0x440cc0): the camera rect (`Camera+0x78/7C/80/84`, xmin/xmax/ymin/ymax) widened by 0.5
block; one of 4 edges (`g_PedSpawnEdgeSide` 0x5E5BCE: moving camera → the edge in the direction of
travel; still camera → round robin), walking along it (`g_PedSpawnEdgeStep`), point jittered by
(random(32)+8)/64 block. Accepted only if, in order:
1. `DummyPedManager.onScreenPeds < zone.pedDensity / 25` (default 500 → **20**; 0 → never);
2. `MapBlocks_FindPavementTopBlock` 0x466910: top block of the column is pavement (ground type 2);
3. the point is in **no** player's camera rect (exact rect, no margin);
4. not a slope 45..52 block (`MapBlocks_IsSlope45to52At` 0x433430);
5. bounds 1.0 < x, y < 254.0.

There is no minimum distance to the player beyond "off screen" and no maximum radius beyond the
camera rect + ~1 block.

**Who** (0x4404f0): `r = random(1000)` against cumulative zone ratios:

| r band (defaults) | type | condition | result |
|---|---|---|---|
| `< mugger` (50) | 1 mugger | `g_MuggerPedCount == 0` | occ 15, class 4, remap 17, AREA / RUN_AWAY |
| `+ carThief` (40) | 2 car thief | `g_CarThiefPedCount == 0` | occ 16, class 6, remap 15, carSpeed 4.0 |
| `+ elvis` (10) | 3 Elvis | `random(50) == 25` and `g_ElvisGroupCount == 0` | `PedManager_SpawnElvisGroup` 0x43d640: leader occ 44 + 5 × occ 22, remap 12 |
| `+ gangPed` (200) | 4 gang | `g_ArmedGangPedCount < 8`, type-14 zone at the tile | see below |
| `+ policePed` (40) | 5 foot cop | `g_FootCopPedCount == 0`, police on, crew not ARMY | `PoliceManager_SetupFootCop`: occ 29 (31 at ARMY), LOS / REACT_AS_EMERGENCY; copLevel 0..1: no primary weapon, 50 hp, walk ×0.8 |
| rest | 0 dummy | | occ 3, class 3, AREA / RUN_AWAY, remap `random(25)` → {18..21, 31..51} (naked cheat 26); if the crew type is ARMY: SMG soldier instead |

Gang band: no gang zone → plain dummy (remap 18..21). Gang zone, gang = `FindByName(zone name)`:
- `g_ArmedGangPedCount < 4` → **armed member**: class 4, occ **19 GANG_MEMBER**, `Ped.gang`,
  remap `gang.pedRemap` (remap 5 → 50 % 6), graphic GANG, weapon `Gang_PickWeaponByRespect`
  (+ alt pistol), threat LINE_OF_SIGHT / REACT_AS_NORMAL, counter++;
- else **gang-skinned civilian**: class 3, occ DUMMY, `Ped.gangAffiliation`, gang remap, unarmed,
  AREA / RUN_AWAY (killing one still costs respect).

Cheats: `g_cheatElvisPeds` forces type 3; `g_noAnnoyingChars` forces type 0 except cops;
`makeAllCharsMuggers` turns 50 % of spawns into occ 40 (class 4, AREA / REACT_AS_NORMAL).
Spawn is cancelled (ped removed) if the collision grid reports an obstacle at the point.

**Despawn** (`Ped_UpdateState` 0x43ecc0; `Ped+0x20E offscreenTicks` +1 per tick, reset while the
ped or its car is in any camera). There is **no distance-based despawn**:

| pedClass | rule |
|---|---|
| 2 PLAYER | never |
| 3 AMBIENT on foot | `offscreenTicks >= g_PedOffscreenTicksLimit` (0x5E5D80, **40** ≈ 1.3 s); state 1 peds at 200 |
| 3 AMBIENT in car | when its car is removed / wasted |
| 4 SPECIAL_AI, 6 CAR_DRIVER on foot | `> 100` ticks, except ELVIS_LEADER (> 500, group), group members and police-like (cops: `PoliceCrew_TryDespawnOffscreen`) |
| car thief in car | hands the car to traffic after 60 offscreen ticks |
| 5 MISSION | never |
| dead peds | `> 200` offscreen ticks, except MEDIC / MISSION |

`Ped_Remove` 0x43e650 sets `lifeState = 2`; `Ped_Update` counts it down to 0 and the slot returns
to the free list 2–3 ticks later.

**Traffic drivers** (ped side): every ordinary traffic car shares **one** sprite-less `Ped`
(`Car_AssignDummyDriver` 0x423510 → `PedManager_CreateDummyTrafficDriver` 0x43dd80, occ 4); gang
cars get a real ped each (`Car_AssignGangDriver` 0x423560 → `Car_CreateGangDriverPed` 0x43dc60:
occ 42 GANG_CAR_DRIVER, gang remap and weapon, LOS / REACT_AS_NORMAL), `Car+0x7C = 3`. Gang cars
come from `TrafficSpawner_TrySpawnSide` 0x4b34e0 when `CarManager_PickTrafficModel` 0x424980 rolls
kind 5 (`gangCarRatio`), the player is in a gang zone whose gang has `hasRespectMeter`; model =
`gang.carModel`, remap `carRemap`, decal object `KILL_FRENZY + arrowColour`.

## 5. Occupation enum (`Ped+0x240`, `OCUPATION` / `PED_OCCUPATION`) (V unless marked)

Script keyword numbers equal the engine values (`Script_Op_SET_CHAR_OCCUPATION` 0x479660 stores the
number). There is **no weapon-per-occupation or remap-per-occupation table**: each spawn site sets
them (§4, §7).

| # | name | set by |
|---|---|---|
| 0 | PLAYER | player |
| 1 | EMPTY | inactive aux ped (`Player_TakeControlOfCar`) |
| 2 | UNKNOWN_2 | recycled group copy (`unsure_PedGroup_SwapMemberWithLeader` 0x404120) |
| 3 | DUMMY | default, ambient, every "job done" |
| 4 | DUMMY_CAR_DRIVER | traffic driver (0x43dd80, 0x43dbd0) |
| 5 | DRIVER | ejected driver back in car |
| 7 | TAXI_PASSENGER | dummy hails a taxi: `random(1000) < 2` in `Ped_UpdateOccupationBehaviour` 0x442de0 |
| 8 | BUS_PASSENGER | public transport |
| 9 | TRAIN_PASSENGER | `PedManager_CreateTrainPassenger` 0x43deb0 |
| 10 | DRIVER2 | ejected driver deciding: `random(40)` 7/16/32 → 12, 19 or gang → 13, else 11 |
| 11 | FLEEING_EX_DRIVER | flee, then DUMMY |
| 12 | DRIVER_RETAKING_CAR | ENTER_CAR own car, pistol |
| 13 | ANGRY_DRIVER | pistol, KILL_CHAR_ON_FOOT the jacker |
| 14 | PSYCHO | script (H) |
| 15 | MUGGER | ambient type 1 |
| 16 | CARTHIEF | ambient type 2 |
| 17 | BANK_ROBBER | debug scene / script |
| 18 | CRIMINAL | script |
| 19 | GANG_MEMBER | ambient type 4 (was `UNKNOWN_OCUPATION13`) |
| 22 | ELVIS | Elvis followers |
| 23 | MEDIC | paramedics (was `UNKNOWN_OCUPATION17`) |
| 24 | POLICE | police car crew |
| 25 | SWAT | SWAT van |
| 26 | FBI | FBI crew (250 hp, remap 8) |
| 27 | ARMY_IN_VEHICLE | army crew (250 hp, remap 4, SMG) |
| 28 | GUARD | none found |
| 29 | POLICE_ON_FOOT | foot cop |
| 31 | ARMY_ON_FOOT | foot soldier |
| 32 | GUARD_AGAINST_PLAYER | script |
| 33 / 34 | CRIMINAL_TYPE1 / 2 | script; the two types ignore each other in the hostility test |
| 35 | SPECIAL_GROUP_MEMBER | recruited group member (`unsure_Ped_JoinGroupAsMember`) |
| 36 | TANK_DRIVER | script (H) |
| 37 | ROAD_BLOCK_GUARD | `PoliceManager_SpawnRoadblockGuard` 0x4a9b40 |
| 38 | FIREMAN | fire truck driver |
| 39 | ROAD_BLOCK_TANK_MAN | `PoliceRoadblock_Create` |
| 40 | UNKNOWN_40 | `makeAllCharsMuggers` spawn |
| 41 | DRONE | script (H) |
| 42 | GANG_CAR_DRIVER | `Car_CreateGangDriverPed` (decompiler used to print `GUARD_AGAINST_PLAYER|DRIVER2`) |
| 43 | STAND_STILL_BLOKE | script |
| 44 | ELVIS_LEADER | Elvis group leader |
| 45..49 | REFUGEES, ANY_* | script bonus checks |
| 50 | DRIVER_ABANDONING_CAR | `unsure_PedManager_CreateDriverFor` 0x43e270 (damaged car) |
| 51 | NO_OCCUPATION | script bonus checks |

6, 20, 21, 30: no setter found. `Ped_IsPoliceLikeOccupation` 0x4331e0 = 23..27 or 37 (includes
MEDIC).

## 6. Hostility and reactions (V)

`Ped_UpdateAI` 0x445330 → `Ped_UpdateThreats` 0x43f340 (skipped for the player and for fleeing
objectives), switch on `Ped.threatReaction` (+0x28C):

- **Target search** (`Ped.threatSearch` +0x288): `Ped_FindThreatArea` 0x43beb0 (mode 1) /
  `Ped_FindThreatLineOfSight` 0x43bed0 (mode 5, cone) scan the collision grid around the observer
  through `unsure_Ped_ThreatGridCandidateFilter` 0x4b9a10 (skips AMBIENT-class candidates and dead
  peds), then fall back to the nearest ped in the per-tick **threat list**
  (`PedThreatList_FindNearest` 0x445c30, Chebyshev < 4.0 blocks, |dz| < 1). The target is any ped
  that passes the predicate below — not only the player.
- **REACT_AS_EMERGENCY (cops, 1) / REACT_AS_NORMAL (gang, 2)**: `Ped_SetTask(KILL_CHAR_ON_FOOT
  = 20)` on the target, `target.attackerPed = self`. In a stopped car: LEAVE_CAR first.
- **RUN_AWAY (civilians, 3)**: nearest threat-list ped with a weapon or in a car within **4.0
  blocks** → `Ped_SetTask(FLEE_CHAR_ON_FOOT_TILL_SAFE = 2)`. The threat list is filled by
  `Ped_RegisterAsThreat` 0x4350a0 from every weapon fire handler and from fast driving
  (`CarPhysics_ScarePedsAndTickSwerve`).
- **Retaliation**: `Ped_ReactToAttacker` 0x437010 (victim not engaged): same gang/group → ignore;
  reaction 1/2 → KILL_CHAR_ON_FOOT if armed, else BEAT_OR_ROB_CHAR (23); reaction 3 → flee.
- **Giving up**: GANG_MEMBER drops the kill task when the target is armed and respect ≥ −19
  (`Ped_UpdateOccupationBehaviour` 0x442de0); target lost after 15 misses or > 6.0 blocks.

**The predicate** `unsure_Ped_ShouldReactToPed(observer, candidate)` 0x4371d0, gang branch
(observer has `Ped.gang`):

| candidate | observer attacks when |
|---|---|
| no gang, cop-like occupation (24–27, 29–31, 37) | `observer.gang.highRespectFlag` (respect > 79) |
| player (or EMPTY), attacking or not | `respect[player] < −19`, **unless `g_PoliceManager->crewLeaderOnScreen != 0`** |
| other non-player attacking (`flags & 0x800`), not a cop | observer armed, or within 1.0 block |
| member of another gang | `observer.gang.hostileToGang[cand.gang.id] != 0` (default 1 = always); class 4/6 observers only while the victim has < 4 attackers (this and last tick) |
| same gang | no (unless the candidate is a player) |

Cop branch (observer occupation 24–27, 29–31, 37, no gang): player candidate → wanted logic
(sets 600 wanted points, `PoliceManager_MarkCriminalSighted`, `AssignCarCrewToCriminal`);
non-player candidate → attacks anyone who is **attacking** (`flags & 0x800`) or has task
KILL_CHAR_ON_FOOT, except medics/cops/EMPTY.

**Police vs gangs today**: cops already shoot gang members who are shooting, and gangs with
respect > 79 already attack cops. What does **not** exist: police *pursuit* of non-players.
`Ped_Update` registers a wanted ped (`PoliceManager_RegisterCriminal` 0x4a9d60, pursuit targets
`[4]`) only if `pedClass == 2` (`cmp` 0x445715, `JNZ` 0x44571c) and `Ped.id != 0` (0x445722,
`JZ` 0x445728); wanted points are only ever given to player-class peds. Crime events
(`CrimeEvent_Report` 0x44a200) feed the radio chatter and the current player's `CrimeStats` only.

## 7. Emergency services (V)

**Ambulance** — trigger is a death: the death handler (named `Ped_AttachToGame` 0x4411b0 in the
DB; it is really the kill handler) sets objective 28 on the corpse (sprite, no group, not mission,
not player); `PedSetObjective` case 28 (0x43bde1) → `AmbulanceManager_EnqueuePed` 0x472f20 (cap
**25**; player-class corpses refused). `AmbulanceManager_Update` 0x4740b0 (skipped by
`g_skipAmbulance` 0x5EAD6B; the queue still fills):

1. `AmbulanceManager_DispatchForQueuedPed` 0x473e00, one corpse per tick: road tile near the
   corpse (`PedPathfinder_FindSpawnTile`); an active slot within **8.0 blocks**
   (`g_AmbulancePickupRange` 0x664164, Chebyshev) with `< 10` queued takes it; else a new
   ambulance (max **2** slots, a slot of the shared 10-slot `EmergencyVehiclePool`): crewType 1,
   stage 3, timer **300** ticks. No road / no slot → objective 50 (body removed).
2. `EmergencyVehicleSlot_Update` 0x4c5ca0 stage 3 after the timer: `CarManager_HasRoomForType`
   (ambulance cap 2) → MEDICAR 0x22 at the tile; no car after `spawnWaitTicks > 500` → give up.
3. `AmbulanceSlot_SpawnParamedicCrew` 0x473170: 2 peds, occ 23 MEDIC, remap 0x10, 100 hp,
   REACT_AS_EMERGENCY / NO_THREATS, group leader + member, driverClass 4, siren, objective
   GO_TO_AREA_IN_CAR, car speed 0.4; requires `emergencyPeds < 30`.
4. `AmbulanceSlot_UpdateParamedics` 0x473410: arrive → LEAVE_CAR → GO_TO_CHAR_ON_FOOT corpse →
   `reviveTicks` to **50** → corpse revived: 100 hp, WALK, FLEE_ON_FOOT_TILL_SAFE, occ DUMMY,
   RUN_AWAY. Then ENTER_CAR, idle → stage 5.
5. `EmergencyVehicleSlot_UpdateLeaving` 0x4c5a00: car and crew removed once every part has been
   off screen > 150 ticks.

**Fire truck** — trigger is a car becoming a **wreck** (not merely burning): `Car_TickWreckTimer`
→ `Car_BecomeWreck` → `Car_RequestFireTruckAndSpawnFlames` 0x41f9f0 →
`FireEngineManager_RequestForCar` 0x451510 → `FireEngineManager_AllocRequest` 0x451300 (road tile,
lane probe ≥ 2 in one of 4 directions, max **2** slots, `g_skipFireEngines` 0x5EAD8B blocks it).
Car fire itself comes from `Car_AddDamage` 0x427180: damage ≥ 16000 small fire, ≥ 25000 big fire,
32000 explosion. `FireEngineSlot_Update` 0x450f10:

| state | action |
|---|---|
| 1 | needs target alive and fire-truck room (cap 2): FIRETRUCK 0x11, driverClass 4, FIREMAN driver (100 hp), GO_TO_AREA_IN_CAR to the target tile, siren; spawn failure 50 times → 6 |
| 2 | drive; `< 3.0 blocks` (`g_FireTruckStopDistance` 0x5EAA58) and stopped > 100 ticks → 3 |
| 3 | PUT_OUT_CAR_FIRE (60) on the target → 4 |
| 4 | hose for 50 ticks (`Ped_Obj1_PutOutCarFire` 0x434640); done → 5 |
| 5 | driverClass 3, siren off: the truck becomes ordinary traffic |
| 6 | abort: `Car_RemoveFlames(target)` → 5 |

Watchdog `FireEngineSlot_UpdateWatchdog` 0x450cd0: stopped 999 ticks, truck damage, target gone,
or no flame object (type 0x71) left → finish/abort.

**Police roadblocks** (Seq 40, own decompilation of the functions below, 2026-10-21) —
`PoliceManager` has only **2** slots, `roadblocks[2]` at +0x664 (`PoliceRoadblock`, 0xA4: active,
lifeTimer +0xC, offscreenTicks +0xE, cars[6] +0x10, barrierObjs[12] +0x28 with their ids +0x58,
guards[6] +0x88, collisionRect +0xA0 from `PoliceRoadblock_Ctor` 0x4ac040).

- Build: `PoliceManager_TryCreateRoadblockAt` 0x4aee70, thiscall(tileX, tileY, dir), ret 0xC.
  Crew from `copLevel` +0x654: 3–4 police, 5 FBI, 6 army (`g_crewSpawnKind` 0x66b798; SWAT is
  never chosen here). z = `FindMaxZ` at the tile. dir 1/2 → `PoliceRoadblock_Create` 0x4adb70
  orientation 3 (scans x: road along y), else 2 (scans y). It reads nothing else of the manager,
  only `roadblocks[0]`, then `[1]`.
- `Create`: walks across the road on ground type (`block +0xB & 3` via 0x420420): road lanes
  count, one pavement/field tile per side is allowed, gives up past 12. Then a collision-box
  check (`CollisionGrid_BoxHitsObstacle`). It does **not** see cars: two calls on
  neighbouring tiles stack up (measured). Then lane by lane: even lanes get a barrier pair
  (`SpawnObject` OBJECT_TYPE_ROADBLOCK) + a guard (`PoliceManager_SpawnRoadblockGuard` 0x4a9b40:
  police or FBI only, occupation ROAD_BLOCK_GUARD 37, SPECIAL_AI, GUARD_SPOT, 200 hp,
  REACT_AS_EMERGENCY, needs `emergencyPeds < 30`). Odd lanes get a car (COPCAR / EDSELFBI / TANK
  with a ROAD_BLOCK_TANK_MAN driver; `CarManager_SpawnCarOnGround`, driverClass 4, category
  ROADBLOCK 7, siren on; `CarManager_HasRoomForType` gates it). Finally active = 1, lifeTimer = 100.
- Removal: only `PoliceRoadblock_Update` 0x4ad6c0, called by `PoliceManager_Update` 0x4aef70 for
  the 2 slots. It counts lifeTimer down. Then, while no car, barrier or guard is on screen
  (guards: `offscreenTicks < 0x50`), offscreenTicks climbs. At **0xC9** with the player farther
  than `DAT_0066b898` it calls `PoliceRoadblock_Remove` 0x4abd70. That function hands cars back
  to traffic (`Car_RequestRemove` + driverClass 3), deletes barriers, removes off-screen guards
  and makes on-screen ones AMBIENT. The cars are never recycled on their own:
  `Car_CanBeRecycled` 0x424030 refuses driverClass 4.
- The K menu's persistent roadblocks (`host/debug_roadblocks.asm`) use 8 slots of our own,
  each with a fake `copLevel` 16 bytes in front. They call `TryCreateRoadblockAt` on
  `slot − 0x664` and never `Update`. Verified in Downtown: two of them stayed through ~1300
  frames out of view at wanted level 0.

### Calling the services on demand (Seq 39, measured 2026-10-21)

Used by the K menu's "Call ambulance" / "Call fire truck" (`host/debug_emergency.asm`).

- **Bodies get dropped.** `PedPathfinder_FindSpawnTile` 0x49d7a0 (thiscall on
  `g_PedPathfinder` 0x66A7E4; `(char kind, u8* x, u8* y, u8* z, char wide)`) returns 0 at
  once while `PedPathfinder+0x38` is set and `wide == 0`; the flag flips every frame
  (1, 0, 1, …). `AmbulanceManager_DispatchForQueuedPed` passes `wide = 0`, so a body
  popped on a busy tick is dropped. Its give-up `PedSetObjective(50)` is ignored for a
  dead ped (`PedSetObjective` only takes objective 28 while WASTED), so the body keeps
  objective 28 and no ambulance ever comes. Queueing it again a frame later works.
  Without `wide` the search stops after 6 rings: the Downtown start square has no road
  in range, so no ambulance can come there at all.
- **Fire-truck targets on a junction never get reached.** A drive order routes to "the
  junction ahead of the goal tile" (`RoadNetwork_FindRoute` 0x40e030), so a target
  inside a `RoadJunction` rectangle makes the truck drive through it and round the block
  again (route J(142,115) J(142,149) J(122,149) J(122,115) for a car at 122,149).
  Driven cars do not work either: the target keeps moving, `Car_HaltAIIfHasAI` does not
  hold traffic, and the slot aborts. `CarManager_SpawnCarOnRoadAt` 0x42a120 snaps to a
  segment end (often a junction), files the car as traffic, and `Car_UpdateOffscreenTicks`
  0x424090 removes it after 0x81 ticks off screen (`Car_CanBeRecycled` 0x424030 keeps
  `CAR_CAT_PARKED` cars until wrecked); it also reads the block's arrows without a null
  check (crash at 0x462f91 on an air tile).
- **Arrival (solved in Seq 43).** Even with a still target mid-lane, the truck (and the
  MEDICAR) drove past the target, and the route list (`CarAI+0x28` routeSlot, `routes[]`)
  changed with the junctions around it. Native 11.44: the route is re-planned every tick,
  and `CarAI_FollowRoute` 0x430320 only steers into the target's lane / arrives when
  `floor(car z - 1) == floor(order z)`, which never holds for ground-level orders, so the
  car arrives only on the exact target tile. Full chain and the K-menu workaround
  (`hk_FollowRoute`): [cars-and-car-ai.md](cars-and-car-ai.md) §5–6.

## 8. Hooks for mods

| goal | patch |
|---|---|
| **Gang wars on/off** | `gang_i + 0x112 + id_j` (default 1 = war). Peace: write 0. Wars only happen between armed members (≤ 4 alive, `CMP g_ArmedGangPedCount,4` in 0x4404f0) near zone borders: raise that cap / the outer `< 8`, or give gang-skinned civilians LOS + REACT_AS_NORMAL |
| **Gangs vs cops** | set `highRespectFlag` (+0x110) to 1 per gang for a permanent war on cops, or patch the branch in 0x4371d0 |
| **Cops vs gangs, shooting** | already native for attacking gangsters (`flags & 0x800`); to make cops attack any gang member add `cand.gang != 0` to the cop branch of 0x4371d0 |
| **Cops vs gangs, pursuit with stars** | NOP the `JNZ` at 0x44571c and `JZ` at 0x445728 in `Ped_Update`, give gang peds wanted points (e.g. after `Ped_UpdateWeaponFiring`), and guard `CrimeEvent_Report` 0x44a200 against `ped->player == NULL` first; `PoliceCrew_Update` 0x4ad600 is not yet checked for player-only assumptions |
| max attackers per victim | `attackersLastTick < 4` / `attackersThisTick < 4` in 0x4371d0 |
| respect cheats | `*(s8*)(*(u32*)0x5EB898 + i*0x144 + 0x11C + player)`; or the immediates in `Gang_IsHostileToPlayer` 0x45dae0 (−19), `Gang_PickWeaponByRespect` 0x45db70 (−59/−100), kill deltas 5/1 in 0x434ff0 and 1 in 0x426fa0 / 0x427290 / 0x43d1c0 |
| ambient crowd size | `DummyPedManager.targetCount` (50), the `>>1` at `copLevel > 3` in 0x4415e0, `zone.pedDensity` (on-screen limit = density / 25) |
| spawn mix | `MapZoneInfo` +0xC..+0x14 (or the SET_*_RATIO ops), the `random(50) == 25` Elvis gate, the `random(25)` dummy remap |
| despawn time | `g_PedOffscreenTicksLimit` 0x5E5D80 (40); immediates 100/200/60 in `Ped_UpdateState` 0x43ecc0 |
| disable systems | debug flags `g_skipDummies` 0x5EAD69, `g_skipAmbulance` 0x5EAD6B, `g_skipFireEngines` 0x5EAD8B |
| call services from a mod | `AmbulanceManager_EnqueuePed(g_AmbulanceManager, ped)` or `PedSetObjective(ped, 28)`; `FireEngineManager_RequestForCar(g_FireEngineManager, car)` |
| roadblocks from a mod | `PoliceManager_TryCreateRoadblockAt(fake manager, x, y, dir)` on your own `PoliceRoadblock` (Ctor first) with `copLevel` at −0x10: as many as you like, never despawned because the game only updates its own 2 (`host/debug_roadblocks.asm`) |
| emergency tuning | revive 50 (`0x32` in 0x473410), ambulance delay 300 and give-up 500, pickup range 0x664164, slot count 2, queue 25 |

## 9. Functions named in this pass

All V unless the name carries `unsure_`. Names kept from earlier passes are listed only when this
pass verified them.

| address | name | role |
|---|---|---|
| 0x403920 | Ped_SetBitState2 (really SetPedClass, reported) | writes `pedClass` |
| 0x403b40 / 0x450cb0 | Ped_SetObjectiveDone / Ped_GetObjectiveStatus | `Ped+0x225` |
| 0x404120 | unsure_PedGroup_SwapMemberWithLeader | dead leader/medic replacement |
| 0x40fea0 | Sprite_GetOwnerSpriteIfPed | body kind 3 → owner |
| 0x41f9f0 | Car_RequestFireTruckAndSpawnFlames | wreck → fire truck |
| 0x433430 | MapBlocks_IsSlope45to52At | spawn test |
| 0x433b30 | Gang_GetKillAffectsRespect | +0x111 |
| 0x433e90 | Camera_HasFollowTarget | |
| 0x4350a0 | Ped_RegisterAsThreat | threat list push |
| 0x436830 / 0x43ad10 | Ped_FreeSelectedWeapon / Ped_SetAltWeapon | |
| 0x436890 | unsure_Ped_TickOnScreenCounter | on-screen count, offscreen reset |
| 0x43beb0 / 0x43bed0 | Ped_FindThreatArea / Ped_FindThreatLineOfSight | target search |
| 0x43dbd0 | PedManager_CreateSpritelessDriver | |
| 0x43dc60 | Car_CreateGangDriverPed | gang driver |
| 0x43dd80 | PedManager_CreateDummyTrafficDriver | shared traffic driver |
| 0x43deb0 | PedManager_CreateTrainPassenger | |
| 0x43e8b0 / 0x43eaf0 / 0x442420 / 0x442a40 | Ped_UpdateMugger / _TrainPassenger / _TaxiPassenger / _EjectedDriver | occupation handlers |
| 0x442050 / 0x4427e0 | unsure_Ped_UpdateCarThief / unsure_Ped_UpdateBusPassenger | |
| 0x442de0 | Ped_UpdateOccupationBehaviour | per-occupation AI switch |
| 0x4404f0 | DummyPedManager_SpawnAmbientPed | kind roll + setup |
| 0x440cc0 | DummyPedManager_TrySpawnAtCameraEdge | spawn point tests |
| 0x4415e0 | DummyPedManager_SpawnForAllCameras | cap + camera loop |
| 0x445960 | PedManager_UpdateActivePeds | update + free |
| 0x445c30 | PedThreatList_FindNearest | |
| 0x445f10 / 0x446100 / 0x446060 | PedQueue_Push / PedQueue_Pop / unsure_PedQueue_PurgeNotWasted | |
| 0x4460d0 | unsure_PedList_FreeAll | |
| 0x41dfc0 / 0x41e620 | unsure_Camera_GetTargetSpeed / unsure_Camera_GetTargetHeading | |
| 0x450bc0 / 0x450c10 / 0x450c30 / 0x450c40 / 0x450ca0 | FireEngineSlot_Abort / _Reset / _Release, FireEngineManager_FindFreeSlot / _ResetSerial | |
| 0x450cc0 | FireEngineSlot_TargetHasFlames | |
| 0x450cd0 | FireEngineSlot_UpdateWatchdog | |
| 0x450f10 | FireEngineSlot_Update | state machine |
| 0x451300 / 0x451510 | FireEngineManager_AllocRequest / FireEngineManager_RequestForCar | |
| 0x45a800 / 0x45a850 | Game_CameraIter_Begin / _Next | |
| 0x45d9e0 | Gang_GetHostileToGang | +0x112 |
| 0x45da20 / 0x45da40 / 0x45da80 / 0x45dac0 | Gang_SetRespect / AddRespect / SubRespect / GetRespect | |
| 0x45dae0 | Gang_IsHostileToPlayer | < −19 |
| 0x45db20 / 0x45db40 | Gang_SetKillReaction / Gang_SetName | |
| 0x45db70 | Gang_PickWeaponByRespect | |
| 0x45dbb0 / 0x45dc20 / 0x45dc70 / 0x45dc90 / 0x45dce0 | GangRespectContainer_FindByName / AllocGang / GetGang / AddFromZone / FindByCarModel | |
| 0x45dd50 | Gang_HasRespectMeter | |
| 0x45de10 / 0x45dea0 | Gang_ApplyKillRespect / Gang_ChangeRespectWithRivals | |
| 0x45df30 | GangRespectContainer_MoveToSlot | declaration order (H on intent) |
| 0x462c60 / 0x462e40 / 0x463020 | MapBlocks_GetFoundZoneInfo / MapBlocks_GetZoneRecord / ZoneRecord_ContainsPoint | |
| 0x462ce0..0x462e20 | MapBlocks_SetZone{CarDensity…PolicePedRatio} | 11 setters |
| 0x464fe0 | MapBlocks_FindZoneAtPos | zone of type T at (x, y) |
| 0x465090 | MapBlocks_FindInfoZoneAt | zone type 10/1/15 |
| 0x465280 | MapBlocks_SetZoneInfoAll | MAP_ZONE |
| 0x465350 / 0x465390 | MapBlocks_FindGangAtPos / MapBlocks_RegisterGangZones | |
| 0x466910 | MapBlocks_FindPavementTopBlock | |
| 0x472f20 / 0x472f60 / 0x472fb0 / 0x472fe0 | AmbulanceManager_EnqueuePed / _FindFreeSlot, AmbulanceSlot_EnqueuePed, AmbulanceManager_Reset | |
| 0x473010 | AmbulanceManager_OnParamedicKilled | |
| 0x473140 / 0x473170 / 0x473410 | AmbulanceSlot_Reset / _SpawnParamedicCrew / _UpdateParamedics | |
| 0x473320 | AmbulanceSlot_UpdateActiveStage | |
| 0x473ce0 / 0x473e00 | AmbulanceSlot_Update / AmbulanceManager_DispatchForQueuedPed | |
| 0x475910 / 0x475950 | Gang_SetArrowTarget / Gang_SetHasRespectMeter | |
| 0x482540 | unsure_Object_IsActiveFlame | object type 0x71 |
| 0x497df0 | PedGameObject_UpdateAnimFrame | frame = graphicType base (0/158/316) + anim, remap re-applied |
| 0x497c20 / 0x4338e0 / 0x433880 / 0x4355c0 | PedGameObject_Init / Sprite_SetOwnerPed / PedGameObject_PlaceBody / PedGameObjectPool_Release | |
| 0x4b9a10 | unsure_Ped_ThreatGridCandidateFilter | |
| 0x4b9b00 / 0x420700 / 0x4206c0 / 0x4bafd0 | Sprite_SetRemap / _SetNoRemapState / _SetFrame / Sprite_ResizeToFrame | |
| 0x4bf430 | StyleData_GetPaletteIndex | ped remap → palette |
| 0x4c5480 / 0x4c54c0 / 0x4c54f0 / 0x4c5a00 | EmergencyVehicleSlot_Reset / _RemoveDriverFromGroup / _IsDriverNotWasted / _UpdateLeaving | |

Globals named: `g_GangRespectIterIdx` 0x592DC8; spawn state `g_PedSpawnEdgeSide` 0x5E5BCE,
`g_PedSpawnEdgeStep` 0x5E5BCF, `g_PedSpawnCameraMoving` 0x5E5BDD, `g_PedSpawnAttemptsPerTick`
0x5E5BDE, `g_PedSpawnCameraHeading` 0x5E5F40; one-per-world counters `g_MuggerPedCount` 0x5E5BD0,
`g_CarThiefPedCount` 0x5E5BD1, `g_ElvisGroupCount` 0x5E5BD2, `g_FootCopPedCount` 0x5E5BD3,
`g_ArmedGangPedCount` 0x5E5BD4, `g_BusPassengerPedCount` 0x5E5BDB (H); per-tick counters
`g_ActivePedCountThisTick` 0x5E5BE8, `g_AmbientPedCountThisTick` 0x5E5BEA,
`g_MissionPedCountThisTick` 0x5E5BEB, `g_EmergencyPedCountThisTick` 0x5E5BEC,
`g_OnScreenPedCountThisTick` 0x5E5BF4; `g_AmbientSpawnCounter` 0x5E5BCC,
`g_PedOffscreenTicksLimit` 0x5E5D80 (+ init copy 0x591E7C = 40); `g_AmbulancePickupRange` 0x664164
(8.0), `g_FireTruckStopDistance` 0x5EAA58 (3.0).

Coverage: about 140 functions found in the subsystem (gangs ~35, population ~38, emergency ~35,
sprites/occupations ~27, hostility ~12, with overlaps); about 115 renamed or re-verified in this
pass, the rest kept their earlier names. Enum `OCUPATION`/`PED_OCCUPATION`: 21 values renamed,
missing ones added.

## 10. Open questions

- Who ever writes `GangRespect.hostileToGang` (+0x112) after init — none found; confirm at runtime
  that rival gangs actually fight in a shipped map.
- Reader of `highRespectFlag` besides the cop branch.
- `Ped+0x290` values 1/3 (reduce the respect kill delta to 1): meaning unknown.
- `PoliceCrew_Update` 0x4ad600 and `FUN_00446b80` (caller of the threat-grid filter) not read.
- Per-edge spawn heading constants (Ang16 copies set by CRT stubs at 0x5052d0..) not resolved.
- Empty ped pool (200) and empty sprite pool (400): `PedManager_AllocPed` has no empty check;
  behaviour untested.
- Paramedic objective branches 0x0 / 0x1C / 0x23 only partly read; fire spread between cars not
  searched.
- Occupations 6, 20, 21, 28, 30: no setter in the exe.
- Duplicate types still in the DB: `PedSprite` and `CarSprite` (truncated views of `Sprite`), `S32`
  (= `WorldObject`). `S31`, `Ambulance`/`AmbulanceSub` and `Gang`/`Gangs` were merged into
  `WorldObjectPool`, `AmbulanceManager`/`AmbulanceSlot` and `GangRespect`/`GangRespectContainer`.

### Names added by Seq 47 (slice 1): ped pools, weapon probe, small getters

| Address | Name | Conf | Evidence |
|---|---|---|---|
| 0x433560 | Box3_ZRangesOverlap | U | Fix16_RangesOverlap on +0x10/+0x14 of two blocks; Ped_Obj2_EnterCar |
| 0x4337F0 | Sprite_SetUnlitFlag | U | `byte+0x2C \|= 4`; 27 callers (particles, Ped_ApplyInvulnerabilitySpriteFlag) |
| 0x433830 | S3Bytes_Clear | V | zeroes a/b/c; caller InitPeds |
| 0x433A70 | unsure_GameObject_InitAnimState | U | +0x68=0, +0x6C=arg; Ped_InitSpawnedState |
| 0x433A90 | PedGameObject_GetGroundType | U | returns +0x44; flee/cross-road tasks |
| 0x433AA0 | PedGameObject_IsWalkingAroundObstacle | U | +0x69 != 0; Ped_Obj2_ApproachAndAttackTarget |
| 0x4340A0 | WorldObject_GetPickupAmmo | U | +0x26; Ped_PickUp, SaveGame_CollectPickups |
| 0x434130 | Object_SetAnimLoopsLeft | U | `*(u16*)(this->+0xC + 4) = v`; Ped_DropWeaponPickup, Weapon_ThrowMolotovOrGrenade |
| 0x434140 | WorldObject_IsPowergenOrInvisibleDead | U | +0x18 ∈ {0x11A,0x11D}; ApproachAndAttackTarget |
| 0x4341B0 | CarDoor_GetPedInDoor | U | returns +8; pairs with CarDoor_SetPedInDoor |
| 0x434A10 | Menu_IncBonusTokenCount | V | ++Menu.bonusTokenCount (+0x574); only in Ped_PickUp BONUS_TOKEN branch |
| 0x434AF0 | ParkingZone_IsCarFlagged | U | this=g_ParkingZone; car==*this && byte+0x3D; Ped_Obj2_EnterCar |
| 0x4350C0 | Ped_UpdateWeaponProbeModeOnHitSprite | V | Weapon_SetProbeMode by Chebyshev dist; Projectile_OnHitSprite |
| 0x435180 | Ped_UpdateWeaponProbeModeOnHitWorld | V | + PlayerScore_TrackAccuracy(1); Projectile_OnHitWorld, Object_ExplodeOnProjectileHit |
| 0x435220 | Ped_OnProjectileMissed | V | PlayerScore_TrackAccuracy(0), probe 0; Object_UpdatePhysics |
| 0x435510 / 0x435550 | PedGameObjectPool_Dtor / _Ctor | V | 400 x 0xB4 PedGameObject (ptrTo_relSprites); DummyPedManager_Ctor/Dtor |
| 0x43ADD0 | PedGameObjectPool_ScalarDeletingDtor | V | calls 0x435510, free if flag&1 |
| 0x435540 / 0x43ADF0 | S30_Dtor / S30_ScalarDeletingDtor | V | ptrToS30_relToChar (InitS30); DummyPedManager_Dtor |
| 0x43AE40 / 0x43DB20 | PedManager_Dtor / PedManager_ScalarDeletingDtor | V | 200 x Ped (0x294) in ptrToPedManager; callers DummyPedManager_Dtor, Game_Dtor |
| 0x3F154C / 0x3F1574 | Replay_CreateEmptyFile / Replay_TruncateReplayFiles | V | fopen "wb" of "test\replay.rep", "test\replay0.rep" |

The ten 0x3F10B0–0x3F1AFA stubs first named `*_Chunk` are 11.44 patch code-cave hooks; they are now `Patch1144_*` and listed in crt-and-network.md section 4.
