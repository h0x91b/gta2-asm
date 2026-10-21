# World objects, prefabs, projectiles, explosions, particles and weapons in gta2.exe 11.44

Everything in the game world that is not a car or a ped is a **world object**: map props,
pickups, phones, bullets, rockets, grenades, explosions, blood, conveyor belts, lights. They
share one pool, one spawn funnel and one per-tick loop, and every one of them is described by an
**object prefab** built at startup from two static tables. Explosions and fire are world objects
of type `PARTICLE_SYSTEM` that carry an emitter state; the visible flames and smoke are a
separate 500-node particle pool. Weapons are a third, smaller system that spawns projectile
objects.

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`). Names, prototypes and plate
comments are in the Ghidra DB (`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and
therefore in `re/`. **Verified** means the claim was checked against the decompiler or the
disassembly (a reader and a writer, a caller, a constant); `unsure_` names and "H" mark
hypotheses. Sources: the Seq 27 objects pass (commit 653af51) and the Seq 46 pass (this page:
five sub-agents named the remaining 209 functions in 0x480000-0x49FFFF, the coordinator re-read
the claims below in the decompiler).

Related pages: [ped-movement-collision.md](ped-movement-collision.md) (ped walker, `PedGameObject_*`
movement, collision grids), [car-physics.md](car-physics.md), [math-helpers.md](math-helpers.md)
(`Fix16` is Q14: 1.0 = `0x4000` = one map block).

## 1. Object pool and the per-object structs

| struct | size | pool / global | capacity | notes |
|---|---|---|---|---|
| `WorldObject` | 0x2C | `WorldObjectPool` at `0x665784` (0x29178 B, ctor `WorldObjectPool_Ctor` 0x483F10) | **3825** (0xEF1) | the real world object. +0 next, +4 `Position*` (the body that lives in the collision grid), +8 `ObjectPrefab*`, +0xC kind state, +0x10 `ObjectMotionState*`, +0x14 serial (`DAT_00593210++`), +0x18 `OBJECT_TYPE`, +0x1C "kind state is a ParticleState", +0x20 list state (1 active / 2 static), +0x24 pending type (morph), +0x25 lifecycle (0 alive, 1 dead now, 2 dead when off-screen), +0x26 owner slot **or** extra byte (below) |
| `ObjectAnimState` | 8 | `0x66577C` (ctor `ObjectAnimStatePool_Ctor` 0x483F60) | 1101 | +4 loops left, +6 tick counter, +7 frame (`ObjectAnimState_Init` 0x482AD0) |
| `ObjectMotionState` | 0x3C | `0x665780` (ctor `ObjectMotionStatePool_Ctor` 0x4848C0) | **385** | heading, speed, z-velocity, lifetime, airborne flag. Type owned by the map task (Seq 44); field facts sent there |
| `ParticleState` | 0x30 | `ParticleStatePool40` | 40 | emitter state of explosions and fires (section 5) |
| `ObjectSpawner` | 0x5C | `g_ObjectSpawner` | 1 | counters: +0x10 category-2 objects (hard cap 360), +0x14 category-3 objects (soft cap 88), +0x20 50 bonus-token flags, +0x54 bonus-token counter, +0x58 scratch `Position*` |

The struct named `Object` (0x5C) in `re/gta2_types.h` is a duplicate of `ObjectSpawner`; the 0xB4
`GameObject` is the ped body (ped walker), not a world object.

`WorldObject.+0x26` is dual-use (verified): for objects spawned by a ped it is the
`OwnerSlotTable` index (`WorldObject_SetOwnerSlotAddRef` 0x482790 stores it and increments the
slot's refcount); for conveyor belts it holds the packed push offsets `(dx+7)<<4 | (dy+7)`
(`Object_SetConveyorOffsets` 0x483C00, called by `Script_Decl_CONVEYOR_SET`; unpacked by
`unsure_UnpackNibbleOffsetsMinus7` 0x482770); for projectiles it records the tile face hit.

**Refcount balance (verified, answers the Seq 27 open question).** `OwnerSlotTable_DecRef`
0x4B9940 has three callers: `Object_Destroy` 0x484910 (call at 0x484977) and the two
lifetime-expiry paths in `Object_UpdatePhysics` (0x487B3B) and `Object_UpdatePhysicsAnimated`
(0x487D48). All three are guarded by "prefab kind not in {1, 6, 7, 8, 9, 10, 12}"; projectiles are
kind 3/4, so every projectile's AddRef is released. The AddRef in `ObjectSpawner_CreateObject`
has no such guard, so an object of an excluded kind spawned with an owner would leak a ref (H: no
such spawn found).

## 2. Object prefabs and the two static tables

Each `OBJECT_TYPE` maps to an `ObjectPrefab` (0x74 B) in the prefabs container (`u16 length`,
`ObjectPrefab prefabs[300]` at +4, `ObjectPrefab* byId[300]` at +0x87F4; `ObjectPrefabs_Get`
0x488170 is `byId[id]`, no bounds check). The fields that drive behaviour:

| off | field | meaning |
|---|---|---|
| 0x00-0x0C | `boxX/Y/Z`, `boxRadius` | body extents; `boxRadius` = min(boxX, boxY) (`ObjectPrefab_SetBox` 0x487F60); all-zero → box from the sprite size /64 (`ObjectPrefab_SetDefaultBoxFromSprite` 0x487FA0) |
| 0x10 / 0x14 | `initialSpeed` / `deceleration` | copied into the motion state at spawn |
| 0x24 | `objectType` | the id (`ObjectPrefabs_AddSlot` 0x4881D0) |
| 0x34 | `kind` | 0 static, 1 static + contact notify, 2 animated, 3 physics, 4 physics + anim, 5 particle system, 6-9 pickups (static/physics/animated/both), 0xB light, 0xC logic only |
| 0x38 / 0x3C | `killTransform` / `endTransform` | type to become when killed / when lifetime or animation ends (0 = just die) |
| 0x40 | `gridKind` | 0/1 aux point grid, 2 none, 3 notify grid (bbox), 4 obstacles grid (bbox) |
| 0x44 | `impactMode` | what a hit does (`Object_ApplyPendingTransform` 0x486060 / `ImpactEvent_Dispatch` 0x486410 switch); 7 = die on impact |
| 0x58 | `usesGravity` | 0 → `Object_MoveFlatWithCollision` 0x4874D0, else `Object_MoveBallisticWithCollision` 0x486E90 (verified at both call sites) |
| 0x5C | `category` | 1 uncounted, 2 hard cap 360, 3 soft cap 88 with oldest-first trim (`ObjectSpawner_TrimCategory3` 0x485E40) |
| 0x61 | `onActiveList` | 0 = never ticked again after spawn, else updated every frame |
| 0x64 / 0x65 / 0x6C | ticks per frame / lifetime-or-loops (0xFF infinite) / frame count | |

**Where the values come from (verified).** The prefab tables at `0x665C50` (126 rows × 0x6C) and
`0x6692C0` (24 rows × 0x54) are zero in the file. They are filled by CRT static initialisers:
`ObjectPrefabRow126_Construct` 0x488210 (29 stack arguments, `ret 0x74`) is called once per row
from 0x537D70..0x53BEED with `ecx = 0x665C50 + n*0x6C`, and `ObjectPrefabRow24_Construct` 0x4882F0
(21 arguments) once per row from 0x53BEF0..0x53C888. That is why 0x488210 has 126 xrefs.
`ObjectPrefabs_InitAll` 0x489530 then copies them into prefab slots (`ObjectPrefabs_InitTable126`
0x488D10, `ObjectPrefabs_InitTable24` 0x4884B0), then `ObjectPrefabs_ApplyPatches` 0x488570 and
`ObjectPrefabs_InitPickupClones` 0x488F70 overwrite a few types (probe-bullet clones 0x9A/0x9F/
0xC1/0xC3/0xC7, pickups 200..244 → moving clones 64..108), and `ObjectPrefabs_InitFromStyle`
0x488450 adds one prefab per style `OBJI` record.

The rows were decoded by running the static-init code through a small symbolic x86 interpreter
over `gta2.ebin` (push/mov/lea plus the `Fix16_FromInt/Mul/MulInt/Neg` calls), resolving all 150
argument lists. Spot check: the ROCKET row (call at 0x53B94F) pushes `0x80`, `0x32` (lifetime
50), kind 3, impact mode 7, exactly as decoded. A second, independent check: the transform ids
the table gives the explosives are exactly the "destroy codes" that `DestroyCode_ToExplosionKind`
0x4825E0 maps to explosion kinds (0x27 → 0x12 small, 0x28 → 0x21, 0x29 → 0x13 medium, 0x2A → 0x14
large): molotov dies into 0x27, a grenade's lifetime ends in 0x28, the car bomb in 0x2A.
Caveat: the patch/clone/style passes are not applied in the table below, so a few types end up
with different values in the running game.

Projectile and effect rows (speed in blocks per tick, lifetime in ticks):

| type | kind | speed | decel | lifetime | gravity | grid | impact | becomes |
|---|---|---|---|---|---|---|---|---|
| 0xFE BULLET | physics | 0.2 | 0 | 25 | no | 1 | 7 die | — |
| 0x80 ROCKET | physics | 0.4 | 0 | 50 | no | 1 | 7 die | — |
| 0xC0 SHOT (shotgun pellet) | physics | 0.4 | 0 | 8 | no | 2 | 8 | SPARK |
| 0xB7 MOVING_GRENADE | physics + anim | 0.1 | -0.01 | 12 | **yes** | 4 | 0 | killed → GRENADE (0xB6), lifetime end → 0x28 (explosion 0x21) |
| 0x8A MOLOTOV_MOVING | physics + anim | 0 (thrown) | 0 | ∞ | **yes** | 1 | 7 die | 0x27 (explosion 0x12) |
| 0xC2 FLAMING_BULLET / 0xC6 WATER_BULLET | physics | 1.0 | 0 | 1 | no | 2 | 8 | itself |
| 0x84 CAR_BOMB | animated | 0 | 0 | 120 | no | 0 | 0 | 0x2A (explosion 0x14) |
| 0x71 PARTICLE_SYSTEM | particle system | 0 | 0 | 0 | no | 2 (none) | 0 | — (invisible) |

So a rocket flies 0.4 × 50 = 20 blocks, a bullet 5 blocks, a pellet 3.2 blocks, in a straight
line; the grenade is the only ballistic projectile. Real launch speed is prefab speed plus the
shooter's velocity (`Object_AddVelocityImpulse` 0x4849B0). The full 126-row table is in the
appendix; sprite base frames are the running sum of `frameCount` in table order (ANTENNA 0 …
ROCKET 540 … PARTICLE_SYSTEM 552), which is the `CODE_OBJ` sprite order in the style file.

The 24-row table holds the movable street furniture (BENCH → MOVING_BENCH, BIN → MOVING_BIN,
BIN_LID, …): static, obstacles grid, and a transform into the physics variant when hit.

## 3. Lifecycle: spawn, tick, free

**Spawn (verified).** Every creation funnels into `ObjectSpawner_CreateObject` 0x484E00 —
`SpawnObject` 0x4852E0, `ObjectSpawner_SpawnPhysicsObject`, `_SpawnLightObject`, `_SpawnMovingObject`,
`_SpawnThrown` 0x485500, `Object_NewWithPedRefIdx`, `Object_NewPhysicsObjUnlessBlocked` (script
pickups), `SaveGame_RestorePickups` 0x485640 (inverse of `SaveGame_CollectPickups`), and
`Weapon_SpawnProjectile` 0x4CDA90. It pops a `WorldObject` and a `Position`, then by prefab kind
an anim state, a motion state or a `ParticleState`, applies the prefab to the `Position`
(`ObjectPrefab_ApplyToPosition` 0x4883A0), inserts the body into the grid chosen by `gridKind`
(`Object_InsertIntoGrid` 0x482630) and puts the object on the active list if `onActiveList`.
**None of the three pool pops checks for empty** (object pool at 0x4829A3, motion pool at 0x483FE3).

**Tick (verified).** `GameTick` → `ObjectSpawner_Update` 0x487F50 once per 33 ms tick: trim
category 3, then walk the active list and call `Object_UpdateOne` 0x487E80 → `Object_UpdateByKind`
0x487D70. Physics kinds go through `Object_UpdatePhysics` 0x487A30 / `Object_UpdatePhysicsAnimated`
0x487BC0: conveyor push (`ObjectMotionState_ResolvePushedVelocity` 0x482D90), gravity/friction,
then the mover. The ballistic mover sub-steps the motion and picks
`Object_StepCollisionGrounded` 0x484090 (vz = 0), `…Rising` 0x484260 or `…Falling` 0x4843A0. Map
hits record the impact surface (`Projectile_SetImpactSurfaceFromCollision` 0x483500 →
`DAT_00665794`: floor/wall codes), sprite hits go to `Object_ResolveCollisionByKind` 0x486C60
(wall X/Y, car, ped, object). Hits are then dispatched by `ImpactEvent_Dispatch` 0x486410 on
`impactMode` to `Projectile_OnHitWorld` 0x485C90 / `Projectile_OnHitSprite` 0x486390 /
`Object_TryExplodeOnHit` 0x486360. When the lifetime byte runs out the object morphs into
`endTransform` (`Object_MorphTo` 0x485760).

**Free (verified).** `Object_MarkDead` 0x4827B0 sets lifecycle 1 (`Object_KillNow` = put on
active list + mark dead). The next `ObjectSpawner_Update` calls `Object_Destroy` 0x484910: clears
the type, decrements the category counters, `OwnerSlotTable_DecRef`, `Object_FreeStates` 0x484760
(anim/motion state back to their pools, `ParticleState_Release`, light free), frees the
`Position`, pushes the object back on the free list. `Object_FreeNow` 0x485260 is the immediate
path used by car-attachment code. Lifecycle 2 objects stay until no player camera sees them.

## 4. Projectiles and explosions

A projectile is an ordinary world object with a motion state. What one rocket produces (Seq 27
pass B, code paths verified):

| what it hits | path | explosion kind |
|---|---|---|
| wall / ground | `ImpactEvent_Dispatch` → `Projectile_OnHitWorld` → `Object_CreateExplosion` + `Particle_EmitImpactParticles` (6 sparks) | by surface: 0x12, or the directional wall/floor bursts 0x16..0x19 |
| ped | `Projectile_OnHitSprite` → `PedSprite_OnExplosiveProjectileHit` 0x4932D0 | 0x12 |
| car | `Car_OnDamage` → `Car_AddDamage(32000)` → `Car_Explode` | 0x13 (0x12 if already wrecked) |
| explosive object (`explosiveClass` 0xC/0xD) | `Object_ExplodeOnProjectileHit` 0x485B00 | 0x12 / 0x13 |

**Explosion object.** `Object_CreateExplosion` 0x485540 spawns a `PARTICLE_SYSTEM` (0x71)
object and allocates a `ParticleState` from the 40-slot pool; the state's timer is 100 for the
blast kinds (0x12-0x14, 0x16-0x19, 0x20, 0x21) and 9999 (= until released) for fires. It is
ticked by `ParticleState_Update` 0x491A70, which decrements the timer and dispatches to
`ParticleState_TickExplosion` 0x491240 (0x12-0x14, 0x20, 0x21: the timer is decremented a second
time there, so the blast lasts 50 ticks) or `ParticleState_TickWallBurst` 0x491550 (0x16-0x19).
While the timer is above 0x32, `ParticleState_ApplyBlastDamage` 0x490D60 hits every car within
the radius (`ParticleState_GetMaxRadius` 0x48A390: 0.5 block for 0x12/0x16-0x19, 1.0 for 0x13/0x20,
2.0 for 0x14) with 32000 damage — that is the chain explosion. A medium/large blast also spawns
four sub-fires at timer 0x59/0x4F/0x45/0x3B.

**Known leak (verified code path).** If `ParticleStatePool40` is full, `Object_CreateExplosion`
returns 0 **without freeing the object it already spawned**: it stays on the active list with no
state, forever, holding a `Position` and a grid node. The same pattern is in the kind-5 branch of
`ObjectSpawner_CreateObject`. Under rocket/grenade spam this slowly drains the object pool, the
5031 `Position`s and the 4096 collision-grid nodes — the community crash at 0x447352 is the grid
pop. (Seq 27 note 87b729ac; reproduced in code, not at runtime.)

## 5. Particle system

Two different things are called "particle" (Seq 27 pass C, verified):

- **Emitter states**: `ParticleState` (0x30) in `ParticleStatePool40` (40 slots; when full,
  `ParticleStatePool40_EvictLowestPriority` 0x48A5A0 only marks a victim, so the allocation still
  fails that tick). `ParticleStatePool20` is constructed but never allocated from. A state's kind
  (+0x10) selects the emitter: smoke `ParticleState_EmitSmoke3/4/24`, flame `…EmitFlame5`,
  fireballs `…EmitFireballSmall/Medium/Large` 0x48EB00/0x48ED40/0x48EF90, blast ring.
- **Particles**: the real pool is at `0x669E70` (0x947C B, **500 nodes** × 0x4C, ctor
  `ParticlePool_Ctor` 0x48F1E0, owned by `ParticleManager` 0x491B90), updated by
  `UpdateParticles` 0x491CE0 → `Particle_UpdateOne` 0x490760, a switch over ~20 particle types
  (ember, smoke, trail puff, blood pool, muzzle flash, spark, flame, car-light glow, water/flame
  bullet, …). Every particle takes one `Position` and one collision-grid point node, re-inserted
  every tick. The generic allocator `ParticlePool_Alloc` 0x48C930 checks both the particle pool
  and the `Position` pool; six fire/explosion emitters check only the particle pool, so a dry
  `Position` pool is a second NULL-deref candidate. `g_skipParticles` (registry debug flag) skips
  most emitters.

One-shot emitters called from gameplay: `Particle_EmitMuzzleFlash`, `…EmitBloodPool`,
`…EmitPedImpactBurst`, `…EmitImpactParticles` (6 sparks per wall hit), `…EmitFlamethrowerFlame`
0x48D4E0, `…EmitWaterGunJet` 0x48D8B0, `…EmitObjectTrail` 0x48DFC0 (rocket smoke, from
`Object_EmitRocketTrail` 0x4825C0 when type == 0x80).

## 6. Weapons

Structs (Seq 27 pass D, verified): `WEAPON_STRUCT` 0x30 (+0 ammo in tenths of a shot, 0xFFFF
infinite; +2 reload countdown; +4 probe mode — NPCs first fire an invisible clone projectile to
test the line of fire; +0x1C `WEAPON_INDEX`; +0x24 owner ped), pool `g_WeaponPool` 0x673944 of 255,
`FireFromGun` 0x4D0530 switches on the index. The player holds 28 slots (`Player+0x718`), 0-14 on
foot, 15-27 car weapons.

Values read from the image (ammo tables: 28 bytes at `0x575920` per pickup, 28 bytes at
`0x575904` max; reload: the immediate stored into `+2` after a shot, address given):

| idx | weapon | ammo / pickup | max | reload (ticks) | projectile (real / probe) | fire function |
|---|---|---|---|---|---|---|
| 0 | pistol | 10 | 99 | 20 (0x4CE18A) | player 0x109 PISTOL_BULLET, NPC 0xFE / 0x9A | 0x4CE070 |
| 1 | SMG | 10 | 99 | 2 (0x4CE5EF) | 0xFE / 0x9A | 0x4CE4B0 |
| 2 | rocket launcher | 5 | 99 | 50 (0x4CE86F) | 0x80 / 0x9F | 0x4CE6D0 |
| 3 | electrogun | 20 | 99 | every tick | none: area test 0x4CF380, cars take 300 | 0x4CF9E0 |
| 4 | molotov | 5 | 99 | player 4, NPC 50 (0x4CEE48/4E) | thrown 0x8A / 0x9F | 0x4CE970 |
| 5 | grenade | 5 | 99 | player 4, NPC 50 | thrown 0xB7 / 0x9F; held too long explodes in hand (0x12) | 0x4CE970 |
| 6 | shotgun | 10 | 99 | 40 (0x4CDF3E) | 5 × 0xC0 / 5 × 0xC1 | 0x4CDDA0 |
| 7 | electro baton (H) | 20 | 99 | 20 (0x4CFAEF) | 0x115 TASSER_BULLET / 0x9A | 0x4CFA30 |
| 8 | flamethrower | 20 | 99 | every tick | 0x9A damage object + flame particles / 0xC3 | 0x4CDC20 |
| 9 | silenced SMG | 10 | 99 | 2 | 0xFE / 0x9A (no crime event) | 0x4CE4B0 |
| 10 | dual pistol | 10 | 99 | 10 (0x4CE3E6) | 2 × 0xFE / 0x9A | 0x4CE270 |
| 11-14 | unused | 0 | 99 | — | — | — |
| 15 | vehicle bomb | 1 | **1** | one shot | car bomb | 0x4CD400 |
| 16 | oil slick | 5 | 99 | — | ANIMATING_OIL object | 0x4CD460 |
| 17 | mines | 5 | 99 | — | MINE object | 0x4CD5F0 |
| 18 | vehicle machine gun | 10 | 99 | 2 (0x4D041C) | 2 × 0xFE / 2 × 0x9A | 0x4D0230 |
| 19 | tank cannon | 50 | 99 | 50 (0x4D0005) | 0x80 / 0x9F | 0x4CFEC0 |
| 20 | water cannon | 50 | 99 | every tick | water particles / 0xC7 | 0x4CFD80 |
| 21 | vehicle flamethrower | 20 | 99 | every tick | flame particles / 0xC3 | 0x4CFBE0 |
| 22 | army jeep gun | 50 | 99 | 2 (0x4D01B3) | 0xFE / 0x9A | 0x4D0080 |
| 23 | instant vehicle bomb | 1 | 99 | one shot | car bomb | 0x4CD400 |
| 24-27 | unused | 0 | 99 | — | — | — |

With the fast-reload power-up the reload value is halved (`Weapon_ApplyFastReload`, shift at
0x4CD01B). The probe clones (0x9A, 0x9F, 0xC1, 0xC3, 0xC7) and 0x109/0x115 are registered by
`ObjectPrefabs_InitPickupClones` as copies of 0xFE/0x80/0xC0, so they fly like the real ones.

**Damage to peds (verified, `Ped_OnProjectileHit` 0x441A30).** A bullet, pellet, rocket or
molotov object hitting an NPC deals `25 × k × m`, where k = 2 for the player's pistol bullet 0x109
and m = 2 with the shooter's damage power-up; the player ped takes `10 × k × m` unless body armour
absorbs the hit. Water (0xC6): 5 to NPCs, 2 to the player, and extinguishes fire. Flame (0xC2)
sets the ped on fire without direct damage. Rockets, molotovs and grenades also create an
explosion; blast damage is section 4.

## 7. Ped-body helpers in this range

0x491E00-0x49FFFF is mostly the ped body (`GameObject`, 0xB4, `this+0x7C` Ped, `+0x80` Sprite), not
world-object movement. New names there (Seq 46, details in Ghidra comments):

- `PedGameObject_CanMoveToTile` 0x492420 (35 xrefs, verified): can the body step into tile
  (x, y)? Straight moves test one tile edge (`PedGameObject_IsTileEdgeOpen` 0x492190, directions
  1..4); diagonal moves recurse into both orthogonal neighbours. On a block it writes the blocked
  direction to `DAT_00593228`.
- `PedGameObject_OnTouchWorldObject` 0x4930F0 (verified): what a ped does on contact with an
  object type — conveyor 0x8B pushes it (`pushX/pushY`), conveyor end 0x8D kills it, 0xA1 fires a
  script trigger, phones 0xA4/0xB1/0xB3/0xB5 are answered, door objects 0xA7 go to
  `DoorManager_OnPedTouchDoorObject`, weapon pickups and 0x10A bonus tokens are picked up.
- `PED_STATE` → handler (verified from `PedGameObject_Tick`): 0 `StateWalk` 0x49A560, 1/2
  `unsure_PedGameObject_StateGoToCar` 0x49B0D0, 3 `StateEnterCar` 0x49BAD0, 4 `StateGetOutOfCar`
  0x496800, 5 `unsure_PedGameObject_StateUnknown5Car` 0x49BC20, 7 `StateStaying`, 8
  `StateFallOnGround` 0x496880, 9 `StateWasted`.
- `PedPathfinder_*` 0x49C680-0x49DCE0: incremental 8-neighbour path search over a 34×34 node
  grid (`g_PedPathfinder` 0x66A7E4, 0x2FD4 B, 100 iterations per call).
- `PedGameObject_Ctor` 0x497A60 constructs the 400 × 0xB4 array; `ResetVals` is now
  `PedGameObject_ResetTickCountersAndSpriteIds` 0x493520.

Struct facts for `GameObject` (+0x10 walk sub-state, +0x14 target heading, +0x46 state timer,
+0x58 flag bits) and `Ped` were sent to the Ped owner (Seq 27); `GameObject` was not edited.
StateWalk and the walker documented in ped-movement-collision.md were left as they were.

## 8. Census and open questions

Unnamed functions in 0x480000-0x49FFFF: **209 before** (live DB, 2026-10-21), **0 after**
(119 verified, 80 hypothesis among the 199 with a comment; the rest are trivial getters named by
what they return). `ObjectPrefab` gained its gap fields (`boxRadius`, `objectType`, `spriteFlag`,
`spriteLayer`, `usesGravity`, `unsure_solidityVsCar/Ped`, `unsure_initialZ`,
`unsure_killOnOverlap`).

Open:
- Final per-type prefab values after `ObjectPrefabs_ApplyPatches` / `InitPickupClones` /
  `InitFromStyle` (only the base rows are decoded). A runtime dump from our port would settle it.
- Per-weapon sound id (the weapon's audio emitter is type 7, sample not found).
- `0x8A MOLOTOV_MOVING` speed 0: the throw speed must come from `ObjectSpawner_SpawnThrown`.
- Seq 27 leftovers still open: `OBJECT_TYPE` 0x7F ANIMATING_CONE / 0xA5 DEAD_MINE are misnamed
  (explosion fragment / light object); the duplicate `Object` type and the WEAPON_INDEX names
  (3 ELECTROGUN, 6 SHOTGUN, 7 ELECTRO_BATON, 9 SILENCED_SMG) need a hand edit by the user.
- Movie globals `unk1/unk2/unk3` (Bink buffer, Bink handle, movie state, used by `Movie_*`
  0x481D10-0x481E00) are still unnamed.

## Appendix A. Static prefab table 0x665C50 (base rows, before patches)

`kind`, transform ids and grid as described in section 2; `id40` etc. are raw type ids without an
enum name. Speed and decel in blocks per tick, lifetime in ticks (255 = infinite).

| type | name | kind | killTransform | endTransform | onList | impact | grid | speed | decel | lifetime | gravity | category | frames |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 149 (0x95) | ANTENNA | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 109 (0x6D) | SMALL_ARROW | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 257 (0x101) | BLOOD | STATIC(0) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 111 (0x6F) | BLOOD_SPARK | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 5 |
| 247 (0xF7) | BOMB | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 255 | 0 | 1 | 1 |
| 266 (0x10A) | BONUS_TOKEN | STATIC_NOTIFY(1) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 1 |
| 175 (0xAF) | BRIEFCASE | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 255 | 0 | 1 | 5 |
| 254 (0xFE) | BULLET | PHYSICS(3) | 0 | 0 | 1 | 7 | 1 | 0.2 | 0 | 25 | 0 | 1 | 3 |
| 129 (0x81) | BUS_STOP_MARKER | STATIC(0) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 132 (0x84) | CAR_BOMB | ANIMATED(2) | id42 | id42 | 0 | 0 | 0 | 0 | 0 | 120 | 0 | 1 | 0 |
| 122 (0x7A) | CAR_CROSSING | STATIC(0) | 0 | 0 | 0 | 9 | 4 | 0 | 0 | 0 | 0 | 1 | 0 |
| 130 (0x82) | CAR_SHOP | UNK_A(10) | BUSY_CAR_SHOP | BUSY_CAR_SHOP | 0 | 6 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 131 (0x83) | BUSY_CAR_SHOP | UNK_A(10) | CAR_SHOP | CAR_SHOP | 1 | 3 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 139 (0x8B) | CONVEYOR_BELT | STATIC_NOTIFY(1) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 200 (0xC8) | COLLECT_00_PISTOL | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 201 (0xC9) | COLLECT_01_S_UZI | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 202 (0xCA) | COLLECT_02_ROCKET_LAUNCHER | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 203 (0xCB) | COLLECT_03_ELECTROGUN | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 204 (0xCC) | COLLECT_04_MOLOTOV_COCTAIL | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 205 (0xCD) | COLLECT_05_GRENADE | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 206 (0xCE) | COLLECT_06_SHOTGUN | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 207 (0xCF) | COLLECT_07_ELECTROBATON | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 208 (0xD0) | COLLECT_08_FLAMETHROWER | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 209 (0xD1) | COLLECT_09_SILENCED_S_UZI | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 210 (0xD2) | COLLECT_10_DUAL_PISTOL | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 211 (0xD3) | COLLECT_11_LETTER_L | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 212 (0xD4) | COLLECT_12_LETTER_M | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 213 (0xD5) | COLLECT_13_LETTER_N | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 214 (0xD6) | COLLECT_14_LETTER_O | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 215 (0xD7) | COLLECT_15_VEHICLE_BOMB | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 216 (0xD8) | COLLECT_16_VEHICLE_OIL_SLICK | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 217 (0xD9) | COLLECT_17_VEHICLE_MINE | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 218 (0xDA) | COLLECT_18_VEHICLE_MACHINE_GUN | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 219 (0xDB) | COLLECT_19_TANK_CANNON | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 220 (0xDC) | COLLECT_20_WATER_CANNON | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 221 (0xDD) | COLLECT_21_VEHICLE_FLAMETHROWER | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 222 (0xDE) | COLLECT_22_JEEP_TURRET | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 223 (0xDF) | COLLECT_23_INSTANT_VEHICLE_BOMB | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 224 (0xE0) | COLLECT_24_LETTER_J | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 225 (0xE1) | COLLECT_25_LETTER_K | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 226 (0xE2) | COLLECT_26_LETTER_L | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 227 (0xE3) | COLLECT_27_LETTER_M | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 228 (0xE4) | COLLECT_28_MULTIPLIER_PLUS_1 | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 229 (0xE5) | COLLECT_29_LIFE_PLUS_1 | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 230 (0xE6) | COLLECT_30_HEALTH | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 231 (0xE7) | COLLECT_31_ARMOR | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 232 (0xE8) | COLLECT_32_GET_OUTTA_JAIL_FREE_CARD | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 233 (0xE9) | COLLECT_33_COP_BRIBE | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 234 (0xEA) | COLLECT_34_INVULNERABILITY | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 235 (0xEB) | COLLECT_35_DOUBLE_DAMAGE | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 236 (0xEC) | COLLECT_36_FAST_RELOAD | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 237 (0xED) | COLLECT_37_ELECTROFINGERS | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 238 (0xEE) | COLLECT_38_RESPECT | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 239 (0xEF) | COLLECT_39_INVISIBILITY | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 240 (0xF0) | COLLECT_40_INSTANT_GANG | PICKUP_ANIMATED(8) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 255 | 0 | 1 | 8 |
| 241 (0xF1) | COLLECT_41_LETTER_N | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 242 (0xF2) | COLLECT_42_LETTER_O | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 243 (0xF3) | COLLECT_43_LETTER_P | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 244 (0xF4) | COLLECT_44_LETTER_Q | PICKUP_STATIC(6) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| 134 (0x86) | CRANE_WIRE | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 252 (0xFC) | CRANE_PART_B | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 260 (0x104) | CRANE_PART_C | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 261 (0x105) | CRANE_PART_D | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 262 (0x106) | CRANE_PART_E | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 135 (0x87) | CRANE_BASE | STATIC(0) | 0 | 0 | 0 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 1 |
| 136 (0x88) | CRANE_HEAD_A | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 140 (0x8C) | CRANE_PART_A | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 263 (0x107) | CRANE_HEAD_B | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 137 (0x89) | UNK_137 | STATIC_NOTIFY(1) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 258 (0x102) | CROSSING | STATIC(0) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 142 (0x8E) | CAR_CRUSHER | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 150 (0x96) | id150 | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 143 (0x8F) | UNK_143 | STATIC_NOTIFY(1) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 141 (0x8D) | CONVEYOR_BELT_END | STATIC_NOTIFY(1) | 0 | 0 | 1 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 167 (0xA7) | UNK_167 | STATIC_NOTIFY(1) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 168 (0xA8) | UNK_168 | STATIC_NOTIFY(1) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 169 (0xA9) | UNK_169 | STATIC_NOTIFY(1) | 0 | 0 | 0 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 |
| 197 (0xC5) | FIRE | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 255 | 0 | 1 | 8 |
| 114 (0x72) | FIREJET | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 194 (0xC2) | FLAMING_BULLET | PHYSICS(3) | FLAMING_BULLET | FLAMING_BULLET | 0 | 8 | 2 | 1.0 | 0 | 1 | 0 | 1 | 0 |
| 284 (0x11C) | GENLITE | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 255 | 0 | 1 | 2 |
| 183 (0xB7) | MOVING_GRENADE | PHYSICS_ANIMATED(4) | GRENADE | id40 | 1 | 0 | 4 | 0.1 | -0.01 | 12 | 1 | 1 | 4 |
| 195 (0xC3) | UNK_SHOT_195 | PHYSICS(3) | 0 | 0 | 1 | 7 | 2 | 1.0 | 0 | 1 | 0 | 1 | 0 |
| 199 (0xC7) | UNK_199 | PHYSICS(3) | 0 | 0 | 1 | 7 | 2 | 3.0 | 0 | 1 | 0 | 1 | 0 |
| 285 (0x11D) | INVISIBLE_DEAD | STATIC(0) | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 283 (0x11B) | INVISIBLE_DESTRUCTIBLE | STATIC(0) | INVISIBLE_DEAD | 0 | 0 | 11 | 4 | 0 | 0 | 0 | 0 | 1 | 0 |
| 166 (0xA6) | UNK_166 | STATIC_NOTIFY(1) | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 1 | 0 |
| 280 (0x118) | INVISIBLE_TARGET | STATIC(0) | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 248 (0xF8) | GUNJEEP_TURRET | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 286 (0x11E) | KILL_FRENZY | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 255 | 0 | 1 | 8 |
| 165 (0xA5) | DEAD_MINE | LIGHT(11) | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 171 (0xAB) | UNK_171 | LIGHT(11) | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 172 (0xAC) | UNK_172 | LIGHT(11) | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 173 (0xAD) | UNK_173 | LIGHT(11) | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 287 (0x11F) | GANG_DECAL_LOONIES | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 288 (0x120) | GANG_DECAL_YAKUZA | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 289 (0x121) | GANG_DECAL_ZAIBATSU | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 290 (0x122) | GANG_DECAL_REDNECKS | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 291 (0x123) | GANG_DECAL_SCIENTISTS | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 292 (0x124) | GANG_DECAL_KRISHNA | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 293 (0x125) | GANG_DECAL_RUSSIAN | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 161 (0xA1) | SAVE_POINT | STATIC_NOTIFY(1) | 0 | 0 | 0 | 9 | 3 | 0 | 0 | 0 | 0 | 1 | 0 |
| 138 (0x8A) | MOLOTOV_MOVING | PHYSICS_ANIMATED(4) | id39 | id39 | 1 | 7 | 1 | 0 | 0 | 255 | 1 | 1 | 4 |
| 112 (0x70) | WHITE_DOT | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 205 |
| 163 (0xA3) | PHONE | STATIC(0) | PHONE_RINGING | PHONE_RINGING | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 164 (0xA4) | PHONE_RINGING | ANIMATED(2) | PHONE_CALL | PHONE_CALL | 1 | 6 | 3 | 0 | 0 | 255 | 0 | 1 | 2 |
| 281 (0x119) | POWERGEN | STATIC(0) | POWERGEN_DEAD | 0 | 1 | 11 | 4 | 0 | 0 | 0 | 0 | 1 | 1 |
| 282 (0x11A) | POWERGEN_DEAD | STATIC(0) | 0 | 0 | 0 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 1 |
| 256 (0x100) | RED_FOOTPRINTS | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 253 (0xFD) | BIG_RED_SKID | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 4 |
| 144 (0x90) | HUGE_RED_SKID | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 4 |
| 121 (0x79) | MEDIUM_RED_SKID | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 4 |
| 118 (0x76) | SMALL_RED_SKID | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 4 |
| 295 (0x127) | REMOTE | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 255 | 0 | 1 | 8 |
| 128 (0x80) | ROCKET | PHYSICS(3) | 0 | 0 | 1 | 7 | 1 | 0.4 | 0 | 50 | 0 | 1 | 1 |
| 192 (0xC0) | SHOT | PHYSICS(3) | SPARK | SPARK | 1 | 8 | 2 | 0.4 | 0 | 8 | 0 | 1 | 0 |
| 259 (0x103) | SPARK | ANIMATED(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 5 |
| 148 (0x94) | TANKTOP | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 2 |
| 170 (0xAA) | TRAFFIC_LIGHT_CASING | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| 255 (0xFF) | TRAFFIC_LIGHT | STATIC(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 3 |
| 294 (0x126) | TUNNEL_BLOCKER | STATIC(0) | 0 | 0 | 0 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 |
| 113 (0x71) | PARTICLE_SYSTEM | PARTICLE_SYSTEM(5) | 0 | 0 | 1 | 0 | 2 | 0 | 0 | 0 | 0 | 1 | 0 |
| 278 (0x116) | UNK_278 | UNK_C(12) | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 279 (0x117) | SOUND_INSTANT | UNK_C(12) | 0 | 0 | 1 | 0 | 5 | 0 | 0 | 0 | 0 | 1 | 0 |
| 198 (0xC6) | WATER_BULLET | PHYSICS(3) | WATER_BULLET | WATER_BULLET | 0 | 8 | 2 | 1.0 | 0 | 1 | 0 | 1 | 0 |
| 251 (0xFB) | UNK_251 | PHYSICS(3) | 0 | 0 | 1 | 0 | 5 | 0 | 0 | 1 | 0 | 1 | 0 |

## Appendix B. Static map-object table 0x6692C0

One `transform` serves as both killTransform and endTransform. Columns as in the Ghidra row layout (see the plate comment of `ObjectPrefabRow24_Construct`).

| id | name | kind | transform(kill=end) | act | impact | expl | grid | v0 | decel | loops | f4c(+0x28) | f2c(+0x2c entry) | tpf | f58 | f18 | spr3c | sflag | xspr | f62 | cat | f63 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 22 (0x16) | BENCH | STATIC(0) | MOVING_BENCH | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 1.0 | 10 | 0 | 0 | 0 | 1 | 1 |
| 7 (0x7) | BIN | STATIC(0) | MOVING_BIN | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 1 | 1 | 0 | 1 | 3.0 | 10 | 0 | 0 | 0 | 1 | 1 |
| 1 (0x1) | BIN_LID | STATIC(0) | MOVING_BIN_LID | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 1 | 1 | 0 | 1 | 0.2 | 11 | 0 | 0 | 0 | 1 | 1 |
| 5 (0x5) | BLASTER | STATIC(0) | MOVING_BLASTER | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 1 | 0 | 1 | 1 |
| 2 (0x2) | BOLLARD | STATIC(0) | 0 | 0 | 0 | 0 | 4 | 0 | -0.01 | 0 | 1 | 1 | 0 | 0 | 0 | 10 | 0 | 0 | 0 | 1 | 1 |
| 4 (0x4) | BOXES | STATIC(0) | DEAD_BOXES | 0 | 1 | 0 | 3 | 0 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 1 | 1 |
| 11 (0xB) | BUSH | STATIC(0) | MOVING_BUSH | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 3 (0x3) | CONE | STATIC(0) | MOVING_CONE | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 12 (0xC) | CRATE | STATIC(0) | ANIMATING_CRATE | 0 | 1 | 0 | 3 | 0 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 1 | 1 |
| 13 (0xD) | FOOTY | STATIC(0) | MOVING_FOOTY | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 14 (0xE) | HARDBOX | STATIC(0) | MOVING_HARDBOX | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 18 (0x12) | HYDRANT_LID | STATIC(0) | MOVING_HYDRANT_LID | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 19 (0x13) | HYDRANT | STATIC(0) | 0 | 0 | 0 | 0 | 4 | 0 | -0.01 | 0 | 1 | 1 | 0 | 0 | 0 | 10 | 0 | 0 | 0 | 1 | 1 |
| 20 (0x14) | HYDRANT_UNLID | STATIC(0) | 0 | 0 | 0 | 0 | 4 | 0 | -0.01 | 0 | 1 | 1 | 0 | 0 | 0 | 10 | 0 | 0 | 0 | 1 | 1 |
| 10 (0xA) | MINE | STATIC(0) | 0 | 0 | 7 | 0 | 3 | 0 | -0.01 | 255 | 1 | 1 | 4 | 0 | 0 | 7 | 0 | 0 | 0 | 3 | 0 |
| 15 (0xF) | NEWSDIS | STATIC(0) | MOVING_NEWSDIS | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 8 (0x8) | ANIMATING_OIL | ANIMATED(2) | OIL | 1 | 9 | 0 | 3 | 0 | 0 | 1 | 1 | 1 | 1 | 0 | 0 | 3 | 0 | 0 | 0 | 1 | 1 |
| 9 (0x9) | OIL | STATIC(0) | 0 | 0 | 9 | 0 | 3 | 0 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | 3 | 0 | 0 | 0 | 3 | 0 |
| 16 (0x10) | OILDRUM | STATIC(0) | MOVING_OILDRUM | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 23 (0x17) | PACKAGE | STATIC(0) | MOVING_PACKAGE | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |
| 21 (0x15) | ROADBLOCK | STATIC(0) | MOVING_ROADBLOCK | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 5.0 | 10 | 0 | 0 | 0 | 1 | 1 |
| 6 (0x6) | RUBBISH | STATIC(0) | ANIMATING_RUBBISH | 0 | 1 | 0 | 3 | 0 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 1 | 1 |
| 25 (0x19) | TOWER | STATIC(0) | 0 | 0 | 0 | 12 | 4 | 0 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | 10 | 0 | 0 | 0 | 1 | 1 |
| 17 (0x11) | TYRE | STATIC(0) | MOVING_TYRE | 0 | 2 | 0 | 4 | 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0.1 | 10 | 0 | 0 | 0 | 1 | 1 |

## Appendix C. Functions named in the Seq 46 pass

Status as recorded in the plate comment; evidence abridged. `unsure_` names are hypotheses by construction.

| address | name | status | evidence |
|---|---|---|---|
| 0x480195 | `Script_Op_DoEasyPhoneTemplate_RespectTail` | verified | only caller Script_Op_DO_EASY_PHONE_TEMPLATE; Gang_GetRespect/20 compare, Hud_Brief_EnqueueNoArg, ScriptThread_Next |
| 0x4806BE | `ScriptExecOpCode_CaseStoreCarCharacterIsIn` | verified | 8-byte thunk -> Script_Op_STORE_CAR_CHARACTER_IS_IN, no callers (switch case in ExecOpCode) |
| 0x48073E | `ScriptExecOpCode_CaseLocateCharacter` | verified | thunk -> Script_Op_LOCATE_CHARACTER |
| 0x4807AE | `ScriptExecOpCode_CaseSetGangKillReaction` | verified | thunk -> Script_Op_SET_GANG_KILL_REACTION |
| 0x481C30 | `MissionScript_Dtor` | verified | sole caller MissionScript_ScalarDeletingDtor; frees g_ScriptThreadPool, g_MissionCleanup, this+0x1334c/0x13350 |
| 0x481D10 | `Movie_InitBinkGlobals` | verified | sole caller Init; zeroes unk1/unk2/unk3 (Bink buffer/handle/state) |
| 0x481D30 | `Movie_CloseBink` | verified | BinkBufferClose, BinkGetSummary, BinkClose; callers FrontEnd_Tick, WndProc |
| 0x481DA0 | `Movie_ResetBinkBufferOffset` | verified | BinkBufferSetOffset(buf,0,0); caller WndProc |
| 0x481DC0 | `unsure_Movie_IsStateEqual2` | hypothesis | returns unk3==2; WndProc only |
| 0x481DD0 | `unsure_Movie_IsStateOpen` | hypothesis | unk3 in {1,2}; WndProc only |
| 0x481DF0 | `Renderer_IsKind2` | hypothesis | g_RendererKind==2 (selects Bink 2D-surface path vs BinkBuffer path; likely software/DirectDraw kind — enum not checked) |
| 0x481E00 | `Movie_UpdateFrame` | verified | BinkWait/DoFrame/CopyToBuffer/BufferBlit/NextFrame; returns 1 when last frame hit & closes; caller FrontEnd_Tick |
| 0x482080 | `Ped_ClearUnsureEffectFlag4000000` | hypothesis | clears PED_FLAG_UNSURE_EFFECT_4000000; callers MultiplayerTag_SetItPlayer, Player_ClearPowerupsKeepJailCard, Player_TickPowerups (powerup/"it" visual effect ... |
| 0x482090 | `MultiplayerTag_GetGameType` | verified | wrapper Menu_GetMultiplayerGameType(&ptrToMenu); caller MultiplayerTag_Update |
| 0x4820A0 | `unsure_MultiplayerTag_SetItPlayerAndState6` | hypothesis | this+0xC=param, this+0x10=6; callers MultiplayerTag_SetItPlayer and Hud_OnGameStart (2nd caller means "this" may not be only MultiplayerTag) |
| 0x482400 | `unsure_ObjectType_IsInRange27To2A` | hypothesis | eax in 0x27..0x2a; callers ExplodeBarrel/ExplodeAttachedCar/MorphTo (OBJECT_TYPE 39-42 unnamed in enum) |
| 0x4824C0 | `unsure_WorldObject_GetCollisionExtent400Or800` | hypothesis | 0x400 + (prefab+0x68!=0 ? 0x400:0); caller Sprite_TestMapCollisionAndRecord |
| 0x482560 | `Object_NotifyCollisionGridsIfConveyor` | verified | type 0x8B/0x8D = CONVEYOR_BELT/_END -> Collision_CheckAndNotifyAllForSprite on Obstacles+Notify grids; caller Object_UpdateByKind |
| 0x4825A0 | `Object_RemoveFinishedFromMotionSpriteList` | hypothesis | motion(+0x10) list -> unsure_SpriteList_RemoveFinished(list, position); caller Object_UpdateByKind |
| 0x4825C0 | `Object_EmitRocketTrail` | verified | type 0x80 = OBJECT_TYPE_ROCKET -> Particle_EmitObjectTrail; caller Object_UpdatePhysics |
| 0x4827D0 | `unsure_WorldObject_GetMotionSpeedFix16` | hypothesis | reads Fix16 from motion+0xC/+0x10 vs const DAT_00665894 (zero?), fallback DAT_0066582c; callers all Particle_Update*/EmitFlame (particle drift/speed lookup) |
| 0x4828B0 | `Object_IsNotPhoneDead` | verified | type != 0xAE (OBJECT_TYPE_PHONE_DEAD); caller Hud_ArrowTarget_UpdatePosition |
| 0x4828F0 | `unsure_Vec4_GetComponentByCode` | hypothesis | switch 0xB4/C4->[0], B8/C8->[2], BC/CC->[3], C0/D0->[1]; caller MapBlocks_FindDiagonalCollisionDummy |
| 0x482960 | `unsure_SpawnParams_SetByte18` | hypothesis | this+0x18=byte; caller Weapon_ThrowMolotovOrGrenade |
| 0x482970 | `unsure_GetFieldAddrOffset8` | hypothesis | returns this+8; caller SaveGame_CollectPickups |
| 0x482980 | `Vec3_Set` | verified | stores 3 dwords at +0/+4/+8 |
| 0x482A30 | `unsure_SetField8` | hypothesis | this+8=param; callers object-init, Weapon_SpawnProjectile |
| 0x482A40 | `Position_SetVec3AtOffsetCAndMarkDirty` | verified | Vec3_Set(*(this+0xC)) + Position_MarkBoundsDirty(this) |
| 0x482A70 | `Collision_SetKind4ClearField8` | verified | operates on g_CollisionKind: [0]=4,[8]=0; caller FUN_00486d70 |
| 0x482A80 | `Collision_SetKind5ClearField8` | verified | same, kind 5 |
| 0x482A90 | `WorldObject_SetMotionState` | verified | this+0x10=param (WorldObject+0x10 = motion per objects_A); caller Object_CreateExplosion |
| 0x482AD0 | `ObjectAnimState_Init` | verified | ++DAT_00665764 (alloc counter), clears +4..+7; sole caller ObjectAnimStatePool_Pop |
| 0x482AF0 | `ObjectAnimState_UpdateFreeCounters` | verified | --DAT_00665764, ++DAT_0066576c; sole caller ObjectAnimStatePool_Push |
| 0x482B80 | `unsure_ObjectMotionStatePool_UpdateCountsOnPush` | hypothesis | only caller ObjectMotionStatePool_Push; DAT_00665770--, DAT_00665778++ |
| 0x482BA0 | `ObjectMotionState_GetVelocityVec2` | verified | Vec2_FromPolar(speed@+0xC, angle@+4) |
| 0x482BD0 | `ObjectMotionState_ClearPushOffsets` | verified | writes 0 to +0x38 (packed nibbles, see ResolvePushedVelocity) |
| 0x482BE0 | `unsure_Object_SetSpriteLayerFromPrefab` | hypothesis | Sprite_SetLayer(position, prefab+0x2C) |
| 0x482BF0 | `Object_SetSpriteLayer0x1D` | verified | Sprite_SetLayer(pos, 0x1D) |
| 0x482C00 | `Object_SetOwnerSlot` | verified | writes +0x26; only caller Object_NewWithPedRefIdx |
| 0x482C10 | `unsure_Object_IsAnimStateAtStart` | hypothesis | kindState->+4 short==0 && +7 byte==0; callers AdvanceAnimation, ExplodeAttachedCar |
| 0x482C30 | `Object_GetPositionXY` | verified | Position_GetXY(this+4) |
| 0x482C50 | `Object_GetVelocityVec2` | verified | motion? GetVelocityVec2 : zero vec DAT_006657d4 |
| 0x482C80 | `unsure_Object_GetPrefabMass` | hypothesis | returns prefab+0x18; callers car/ped collision with object |
| 0x482C90 | `unsure_Object_IsSolidObstacle` | hypothesis | prefab.kind (+0x34) in {3,4} or kind 0..2 with impactMode(+0x44)==2 |
| 0x482D30 | `Light_SetPositionRelink` | verified | Light_UnlinkFromGrid; set x/y/z(+4/8/C); Light_LinkToGrid; caller Object_UpdateAttached |
| 0x482D60 | `Light_SetRadiusAndIntensity` | verified | +0x10 radius, SetRadius, SetIntensityByte, +0x18 byte |
| 0x482D90 | `ObjectMotionState_ResolvePushedVelocity` | verified | +0x38 nibbles (unpack-7 *DAT_006657fc) added to velocity vec -> length+angle; clears +0x38; callers Object_UpdatePhysics(+Animated) |
| 0x482E80 | `unsure_Projectile_IsHitSpriteOwnerPed` | hypothesis | hit sprite is ped whose owner slot == projectile +0x26 |
| 0x482ED0 | `Object_IntegrateGravityAndFriction` | verified | motion+0x2A==1 (airborne): vz(+0x1C)+=gravity(DAT_665948), z-vel(+0x10)+=vz; else speed(+0xC)+=decel(+0x18), clamp >=0 |
| 0x482FA0 | `Projectile_PrefabAllowsHitSprite` | verified | switch prefab+0x54 vs Sprite_GetKind (1 ped? 2 car 3 ped/4,5 obj kinds) |
| 0x483030 | `Projectile_ShouldHitSprite` | verified | non-null && AllowsHit && !IsHitSpriteOwnerPed |
| 0x483060 | `Object_TestSpriteHitAndRecord` | verified | unsure_Sprite_FindObstacleAndRecord(pos,2); sets DAT_665790 (hit sprite), DAT_665798 (hit special car 0xA6/0xA9 flag), CollisionHit_SetKindObject |
| 0x483100 | `Position_SnapZToSlopeSurface` | verified | MapBlocks_GetSlopeSurfaceZ, Fix16 floor/frac, SetPosition |
| 0x483460 | `unsure_Object_LandOnSpriteSurface` | hypothesis | after TestSpriteHit: if speed<=DAT_6657ac set layer 0x1D/6, speed, decel=prefab+0x14; caller Object_UpdatePhysicsAnimated-step (FUN_00486e90) |
| 0x483880 | `Object_InheritMotionFromSprite` | verified | by Sprite_GetKind: 2 car speed/angle/layer, 3 ped speed*DAT_665a60, 4/5 object copy motion; caller Object_UpdateAttached |
| 0x483990 | `Object_InitFromPrefab` | verified | ObjectPrefabs_Get, type+0x18, position alloc, SetPosition/Rotation; callers CreateObject, Object_MorphTo |
| 0x483A00 | `Object_SwitchOffLight` | verified | Light_SwitchOff(kindState); callers Car siren/roof light |
| 0x483A10 | `unsure_Object_SwitchOnLightToBase` | hypothesis | wrapper Light_SwitchOnToBase() (no args); callers Car siren |
| 0x483B50 | `Object_NotifyTouchedBySprite` | verified | ped -> FUN_004930f0, car -> unsure_Car_OnTouchObject; caller ImpactEvent_Dispatch |
| 0x483BA0 | `unsure_Object_DriftAndSinkInWater` | hypothesis | motion+0x30=1; every 4th frame FUN_004bab10 (push byte += , clamp to half sprite size) then FUN_004bddd0 -> z=0 + Object_MarkDead |
| 0x483C00 | `Object_SetConveyorOffsets` | verified | byte26 = ((x+7)<<4) |
| 0x483C80 | `unsure_Object_GetExplosionKindBySurfaceCode` | hypothesis | byte+0x26 of hit projectile in {0x2E,0x30} -> 0x16 else 0x17; caller ExplodeOnProjectileHit (type 0xA6) |
| 0x483CC0 | `Collision_GetHitTileSurfaceType` | verified | byte+0x26 in {2D,2F}->tile lid surface, {2E,30}->tile side; StyleData_GetTileSurfaceTypeMerged |
| 0x483D50 | `Pickup_InitDefaultAmmo` | verified | type-0x40 (or -200) <0x1C -> WeaponDefaultAmmo; Pickup_SetAmmo |
| 0x483EA0 | `WorldObjectPool_Dtor` | verified | eh_vector_destructor_iterator counts 0xEF1x0x2C, 0x44Dx8, 0x181x0x3C |
| 0x484020 | `ObjectMotionState_Construct` | verified | per-element ctor from ObjectMotionStatePool_Ctor; sets +0x34=2, zeros +0x28/2A/2C/2E/2F |
| 0x484090 | `Object_StepCollisionGrounded` | verified | called when vz==0 (FUN_00486e90); ground type, slope snap, map/sprite collision |
| 0x484260 | `Object_StepCollisionRising` | verified | vz>0; clamps z to DAT_6658bc, +0x2A=1 |
| 0x4843A0 | `Object_StepCollisionFalling` | verified | vz<0; bounce vz=-vz*DAT_665a24 unless prefab+0x50==1/4 |
| 0x484740 | `unsure_Object_SinkIfOnWaterTile` | hypothesis | FUN_004baa90 = tile flag test below z; then 483ba0 |
| 0x4847D0 | `Object_AllocMotionStateFromVelocity` | verified | ObjectMotionStatePool_Pop; +0x20=serial; length+angle from vec |
| 0x484820 | `WorldObjectPool_ScalarDeletingDtor` | verified | dtor + free; all from ObjectSpawner_Dtor |
| 0x484880 | `Object_EnsureMotionStateAndPutOnActiveList` | verified | pops motion state if none, speed/vz=0, Object_PutOnActiveList; caller Sprite_AttachChildToParent |
| 0x4849B0 | `Object_AddVelocityImpulse` | verified | existing velocity + vec -> length/angle, decel=prefab+0x14; else alloc; callers Weapon_SpawnProjectile, Weapon_ThrowMolotovOrGrenade, car/ped hits |
| 0x484A40 | `Object_AddVelocityImpulseRandomizeState` | verified | prefab+0x4C==3 and motion+0x34==2: random(9) <3 ->1, <6 ->0 |
| 0x484AA0 | `Object_SetPushOffsetsByte` | verified | allocs motion (zero vel) if missing, +0x38=byte |
| 0x484AD0 | `unsure_Object_SetPushOffsetsFromSpriteByte` | hypothesis | byte+0x26 of sprite object -> SetPushOffsetsByte |
| 0x484DD0 | `unsure_Object_OnSpriteOverlap` | hypothesis | type 0x8B -> push from byte; type 0x8D && prefab+0x60 -> Object_KillNow; caller Sprite_OnOverlapNotifyImpactEvent |
| 0x485290 | `ObjectSpawner_SpawnAtXYZAndInsertIntoGrid` | verified | CreateObject + FUN_00482a40(position,xyz) + Object_InsertIntoGrid; callers Door_SpawnObjects, CONVEYOR/DESTRUCTOR_SET |
| 0x4853C0 | `ObjectSpawner_SpawnCarLightObject` | verified | CreateObject + Light_SetRadiusAndIntensity; only caller Car_AttachRoofLightObject |
| 0x485640 | `SaveGame_RestorePickups` | verified | loops 20 slots, SpawnObject + Pickup_SetAmmo, zeros 0x12C bytes; caller MissionScript_LoadSaveGame (inverse of SaveGame_CollectPickups) |
| 0x485ED0 | `unsure_Game_SpawnFourUnk166Objects` | hypothesis | 4×SpawnObject(OBJECT_TYPE_UNK_166) stored in param[0..3], called from startGame |
| 0x486580 | `Object_ResolveCollisionWithObject` | verified | impulse via CarPhysics_ComputeCollisionImpulse between two objects, ImpactEvent_Dispatch for both |
| 0x4867E0 | `Object_ResolveCollisionWithPed` | verified | uses Ped_GetX/Y, ped sprite (param_1+0x7c), HandleCarImpact |
| 0x486950 | `Object_ApplyWallBounceImpulse` | verified | impulse vs wall mass DAT_0066583c, ImpactEvent_Dispatch(this,0) |
| 0x4869E0 | `Object_CollideWithWallX` | hypothesis | ComputeWallContactPointX, X-axis constants DAT_005e687c/6878 |
| 0x486B20 | `Object_CollideWithWallY` | hypothesis | mirror of X with ComputeWallContactPointY |
| 0x486C60 | `Object_ResolveCollisionByKind` | verified | switch g_CollisionKind 1=X wall 2=Y wall 3=sprite (car/ped/object) |
| 0x486D70 | `Object_OnMoveBlocked` | hypothesis | switch on prefab+0x4C solidity; calls ResolveCollisionByKind for 2/3 |
| 0x486E90 | `Object_MoveBallisticWithCollision` | verified | called by UpdatePhysics/Animated when prefab+0x58 != 0; gravity, StepCollisionFalling/Rising/Grounded |
| 0x4874D0 | `Object_MoveFlatWithCollision` | verified | same callers when prefab+0x58 == 0; no vertical stepping; Projectile_SetImpactSurfaceFromCollision |
| 0x487F60 | `ObjectPrefab_SetBox` | verified | writes +0,+4,+8 = args, +0xC = min(x,y) |
| 0x487FA0 | `ObjectPrefab_SetDefaultBoxFromSprite` | verified | w,h of the sprite entry /64 (0x40), z=DAT_00665B9C |
| 0x488060 | `ObjectPrefab_SetRemap` | hypothesis | +0x1C=remap; paletteBase 4→5, 5→6 |
| 0x4880A0 | `ObjectPrefab_OffsetFrameAndSetFrameCount` | verified | +0x1E += a, +0x6C = b |
| 0x4881D0 | `ObjectPrefabs_AddSlot` | verified | slot=base+len*0x74+4, byId[id]=slot, len++, slot+0x24=id (returns slot) |
| 0x488200 | `Position_SetByte2C` | verified | this+0x2C = byte |
| 0x488210 | `ObjectPrefabRow126_Construct` | verified | 126 callers, all in CRT static-init 0x537D70..0x53BEED, ecx = 0x665C50 + n*0x6C; ret 0x74 |
| 0x4882F0 | `ObjectPrefabRow24_Construct` | verified | 24 callers in static-init 0x53BEF0..0x53C888, rows of 0x54 at 0x6692C0; ret 0x54 |
| 0x4883A0 | `ObjectPrefab_ApplyToPosition` | verified | pushes prefab sprite type/frame/layer/remap/box onto a Position |
| 0x488420 | `ObjectPrefabs_AddSpriteEntry` | verified | AddSlot + spriteType, frame(+0x1E), frameCount(+0x6C), paletteBase=2 |
| 0x488E70 | `ObjectPrefabs_ZeroSpriteColor` | hypothesis | zero colour of CODE_OBJ sprite of prefab frame |
| 0x488EF0 | `ObjectPrefab_CreatePosition` | verified | GetNewFreePositionStruct + ApplyToPosition; caller Object_InitFromPrefab |
| 0x488F10 | `ObjectPrefabs_ZeroGangDecalSpriteColors` | verified | ids 0x11F..0x125 = OBJECT_TYPE_GANG_DECAL_* (enum) |
| 0x489560 | `ParkingZone_GetPedExitAngle` | hypothesis | switch direction 1..3 → short from 4 globals |
| 0x4895D0 | `CarPhysics_ClearParkingMotion` | hypothesis | +0x74=DAT zero, Vec2 +0x40 zero |
| 0x4895E0 | `Car_ClearFlag8` | verified | Car_ClearFlags(8) |
| 0x4895F0 | `Door_ClearByte2C` | hypothesis | block->+0x2C=0 after Door_CloseBothFaces |
| 0x489600 | `unsure_Pair_BothNonNull` | hypothesis | p[0]&&p[1]; only caller ParkingZone_Init |
| 0x489620 | `ParkingZone_GetBlockByte4` | hypothesis | byte at [*p+4/5/6]; only caller ParkingZone_ValidateBlocks |
| 0x489650 | `ParkingZone_ResetState` | verified | zero +0xC,+0x10 and 4 Vec2 |
| 0x489680 | `ParkingZone_Update` | verified | called from GameTick; state (+0xC) 1/2/3 machine: car drives in, ped exits (Ped_SetSpriteField40), car removed (Car_RequestRemoveNow) |
| 0x48A250 | `Vec2_DivAssignFix16` | verified | 2× Fix16_DivAssign |
| 0x48A270 | `Vec2_GetMaxAbsComponent` | verified | max( |
| 0x48A350 | `unsure_MapBlocks_IsBlockFlagLow2Set` | hypothesis | block+0xB & 3 |
| 0x48A4C0 | `unsure_ParticleState_GetField8` | hypothesis | returns this+8, compared with 8/9; this type uncertain (callers ApplyBlastDamage, Ped_ReactToPedObstacle) |
| 0x48A590 | `ParticleState_SetOwnerObject` | verified | +0x14 = ownerObject (struct), caller Object_CreateExplosion |
| 0x48A7F0 | `ParticleStatePool40_VectorDtor` | verified | eh_vector_destructor 0x28 / 0x14 elements of 0x30; callers ScalarDeletingDtor |
| 0x48A8E0 | `ParticlePool_Dtor` | verified | zero freeHead/activeHead |
| 0x48A930 | `Particle_GetOwnerSpriteValueC` | hypothesis | this+0x50 sprite → helper |
| 0x48F1C0 | `ParticlePool_ScalarDeletingDtor` | verified | Dtor + free if flag&1 |
| 0x491C20 | `ParticleManager_Dtor` | verified | deletes g_ParticlePool, zeroes object0/1; caller ParticleManager_ScalarDeletingDtor |
| 0x491DE0 | `PedFlames_Clear` | hypothesis | +0xB0=-1, Car_RemoveFlames(+0x88); caller Ped_ExtinguishFire |
| 0x491E40 | `unsure_PedGameObject_IsOnWaterTile` | hypothesis | calls FUN_004baa90 (block under sprite, StyleData tile flag); true → Ped_ExtinguishFire + FUN_004938a0 in 0x49B0D0 |
| 0x491E60 | `unsure_PedGameObject_ResetWalkAroundState` | hypothesis | zeroes +0x18..+0x24, +0x28/2A/2C=Ang16 0, +0x69=0 (the "walking around obstacle" flag from unsure_Ped_ReactToCarOrObjectObstacle); caller PedGroup_UpdateEnte... |
| 0x491EA0 | `PedGameObject_IsOnAnyPlayerScreen` | verified | Game_AnyPlayerCameraSeesSprite(game, go+0x80) == 1; used by unsure_Ped_TickOnScreenCounter (g_OnScreenPedCountThisTick++) |
| 0x491EC0 | `PedGameObject_CheckSpriteCollisions` | verified | DAT_0066a3c9=0; Collision_CheckAndNotifyAllForSprite(g_CollisionGridNotify, go+0x80) |
| 0x491EE0 | `Fix16_ToIntD` | verified | *p >> 14, a 4th copy of Fix16_ToInt (siblings ToIntB/ToIntC) |
| 0x491EF0 | `Fix16_AddOneBlock` | verified | *p += 0x4000 |
| 0x491F00 | `Fix16_SubOneBlock` | verified | *p -= 0x4000 |
| 0x491F10 | `unsure_Dir_GetPerpendicular` | hypothesis | dir 1..4 (N,S,E,W per ped-movement doc) → 3/4, 4/3, 2/1, 1/2 by flag byte; used by FUN_00495470 and unsure_PedGameObject_TurnAwayFromWallNpc |
| 0x491F80 | `unsure_StyleData_IsTileKind5` | hypothesis | this=g_StyleData; *(this + tile*4 + 0x6C) == 5; 0x49B0D0 then does Ped+0x210 += 3 (ground damage?) |
| 0x491FA0 | `unsure_PedGameObject_PickNextStateTimer` | hypothesis | only from StateWalk; if +0x46==0 switch on relToS24_unk33 → +0x10 ∈ {1,3,4,7}, +0x6C ∈ {0,1,2}, +0x46 = random(200/400) |
| 0x4920A0 | `unsure_PedGameObject_StepTurnTowardHeading14` | hypothesis | Ang16 compare of +0x14 vs +0x40, adds DAT_0066A62C or 52C to +0x40; caller FUN_00495700 |
| 0x492130 | `unsure_Ped_ClearField36E` | hypothesis | *(byte*)(p+0x36E)=0, this beyond GameObject size → Ped |
| 0x492140 | `unsure_MapBlocks_IsBlockByte10NonZero` | hypothesis | GetBlock(x,y,z) != 0 && block[+10] != 0 (gmp block_info +10 = arrows byte); in 0x49B0D0 false → ped falls |
| 0x492170 | `CollisionBox_GetZSize` | hypothesis | *out = this[+8]; CarWeapon_FireOil does /2 right after CollisionBox_GetYSize; ReactToCarOrObject compares > 0.5 |
| 0x492180 | `unsure_Position_SetOwnerSprite` | hypothesis | this[+8] = param; only caller FUN_00493850 (new Position, SetCollisionKind(3), setter(pos, sprite)) |
| 0x492190 | `PedGameObject_IsTileEdgeOpen` | verified | thiscall(go, dir): MapBlocks_IsBlockEdgeCrossingBlocked + neighbour GetGroundTypeAt (0 air → false, ≤4 ok), slope retry via bit 0x58&1; callers CanCrossTileE... |
| 0x4923A0 | `unsure_PedGameObject_StartTurnState8` | hypothesis | QuantizeWalkDir(+0x40), += DAT_0066A738, +0x10=8, +0x46=10 (StateWalk only) |
| 0x4923D0 | `unsure_PedGameObject_StartTurnState9` | hypothesis | same with DAT_0066A4A4, state 9 (left/right pair, which is which unknown — angle consts are Ang16 not in static_constants.csv) |
| 0x492400 | `PedGameObject_BeginTurnToHeading` | verified | +0x10=0x19, +0x14=angle, +0x46=0xFF; FUN_00491FA0 treats 0x19/0xFF specially; caller FUN_00495470 (turn away when edge blocked) |
| 0x492420 | `PedGameObject_CanMoveToTile` | verified | thiscall(go, tileX, tileY) → bool. Compares target tile with current (Fix16_ToIntD): straight → IsTileEdgeOpen, diagonal → recursive tests of both axes + cor... |
| 0x4928A0 | `PedGameObject_AddHeading` | verified | Ang16_AddAssign(go+0x40, stack arg) (ret 4); caller FUN_004955F0 (random wobble) |
| 0x492C20 | `Ped_GetHostility` | verified | Ped+0x230 = struct unsure_hostility |
| 0x492C30 | `PedGameObject_CanStepAlongHeading` | verified | pos + PolarToXY(heading, DAT_0066A6A8 if state2==3 else 4FC) → ToIntB → CanMoveToTile; used in 0x49B0D0 after StepHeadingToward |
| 0x492CB0 | `unsure_Ped_SetRefCar` | hypothesis | Ped+0x140 = arg (struct refCar); caller Sprite_UpdatePedAnimFrame |
| 0x492CE0 | `Ped_GetMoveTargetX` | verified | Ped+0x1C4 = moveTarget.x |
| 0x492CF0 | `Ped_GetMoveTargetY` | verified | Ped+0x1C8 |
| 0x492D00 | `unsure_PedGameObject_PickDetourTile` | hypothesis | on DAT_00593228 (blocked dir) compares Ped moveTarget with player pose, tries neighbour tiles via CanMoveToTile, writes goal tile bytes go+0x72/+0x73. 0x4965... |
| 0x492FD0 | `Ped_IsEnterCarObjectiveOrTask` | verified | Ped+0x258 == 0x23 \ |
| 0x493000 | `unsure_Ped_LinkObstaclePedSetFlag4` | hypothesis | this+0x138 = other go; +0x224 \ |
| 0x493040 | `unsure_Ped_LinkObstaclePedClearFlag4` | hypothesis | same, +0x224 &= ~4, then unsure_Ped_SetField250(0x16, arg) |
| 0x493090 | `WorldObject_GetConveyorOffsets` | hypothesis | unpack nibbles-7 of obj byte +0x26 → (dx,dy) chars; used for conveyor belt (type 0x8B) in OnTouchWorldObject and by CarPhysics_ApplyObjectPush |
| 0x4930C0 | `PedGameObject_TryAnswerPhone` | hypothesis | if Ped+0x15C (Player) ≠ 0 → FUN_0047F3B0(g_MissionScript, pedId, obj+0x14); only for types 164/177/179/181 = *_PHONE_RINGING |
| 0x4930F0 | `PedGameObject_OnTouchWorldObject` | verified | thiscall(go, WorldObject*), switch on obj+0x18 OBJECT_TYPE: 139 CONVEYOR_BELT (push +0x4C/+0x50 = DAT_0066A438 × offsets), 141 CONVEYOR_BELT_END → Ped_OnDeat... |
| 0x493390 | `unsure_PedGameObject_KnockDown` | hypothesis | go+0x16=1; ObjectSpawner_SpawnMovingObject(…0x6E…) stored in Ped+0x184, owner slot in Ped+0x267; Ped_SetState FALL_ON_GROUND, Ped_SetState2 0x18/0x19/SMOKING... |
| 0x493520 | `PedGameObject_ResetTickCountersAndSpriteIds` | verified | body: relToS24_unk33=0; relToS24_unk34=0; nextSpriteId=0; unk33 is the 0..20 counter bumped in PedGameObject_Tick; sole caller DummyPedManager_Ctor |
| 0x493540 | `unsure_Struct_FirstDwordEquals` | hypothesis | return param == *(uint*)this; caller unsure_Ped_ReactToCarOrObjectObstacle |
| 0x493550 | `PedGameObject_ResetMoveScratch` | verified | first call in PedGameObject_Tick; sets DAT_00593228/0059322c=1, DAT_0066a3c1..c8=0, copies Fix16 zero (DAT_0066a4d8) into the pose globals playerPedX_/0066a7... |
| 0x493640 | `Sprite_Deinit` | verified | pairs with Sprite_Init; CollisionGrid_RemoveSprite + PositionPool_Free(+0x80), Car_FreeAttachments(+0x88), +0xb0=-1; caller SpritePool_Release |
| 0x493710 | `PedGameObject_EnterJumpMode` | verified | called from Ped_Jump 0x433C40; sets sub-mode +0x10=0xF, anim +0x6c=5, +0x38 = jump speed, +0x8c = Z byte |
| 0x493780 | `unsure_Sprite_GetBackwardPolarOffset` | hypothesis | Vec2_FromPolar(-DAT_0066a504, angle at this+0x80); caller FUN_004867e0 |
| 0x4937D0 | `Fix16_ToSubTilePixelX` | verified | frac(x)*64 -> int16; used by PedGameObject_IsInTileCenter (sub-tile 20..44 px) |
| 0x493810 | `Fix16_ToSubTilePixelY` | verified | identical body, used for y |
| 0x493850 | `Sprite_AllocPosition` | verified | GetNewFreePositionStruct, Position_SetCollisionKind(3), SoundClient_EnsureSource; only caller Sprite_Init |
| 0x4938A0 | `unsure_PedGameObject_StartFallOnGroundBurst` | hypothesis | Ped_SetState(FALL_ON_GROUND), SetState2(0x14), Particle_EmitBurstAt; callers Walk/Staying/GetOutOfCar/FallOnGround... |
| 0x493940 | `unsure_PedGameObject_ComputeCarDoorPos` | hypothesis | CarInfo_GetDoorInfo + relToSpiteOfCar table, switch on door/anim step 0..0xC,99, Ang16_RotateXY; callers GameLogic, Sprite_UpdatePedAnimFrame, Ped_RunTask |
| 0x494180 | `PedGameObject_UpdateGroundZ` | verified | MapBlocks_GetSlopeSurfaceZ -> +0x45 slope byte, bit0 of +0x58, SetPosition(x,y,z) |
| 0x495470 | `unsure_PedGameObject_SteerAroundBlockedEdge` | hypothesis | CanCrossTileEdge on heading class and both neighbours, then FUN_00492400 |
| 0x4955F0 | `unsure_PedGameObject_JitterHeading` | hypothesis | random() > 0x16 -> heading +- random Fix16 -> Ang16, sign fix-up |
| 0x495700 | `unsure_PedGameObject_ApplyWalkSubModeSpeed` | hypothesis | switch(+0x10 sub-mode 1,3,4,7,8,9,0x19,0x24) writes speed +0x38 from DAT_0066a798/574/428/634 |
| 0x4958E0 | `unsure_PedGameObject_UpdateWalkAnimAndMelee` | hypothesis | anim +0x6c from speed (0/1/2); melee branch: nearest ped, Ped_TakeDamage 10/20, mugger GiveMoney(-10) |
| 0x496500 | `unsure_PedGameObject_ProbeSideTilesWhenBlocked` | hypothesis | DAT_00593228 1..4 switch, FUN_00492420 probes (y±1), writes +0x72/+0x73,+0x55=0x28 |
| 0x496800 | `PedGameObject_StateGetOutOfCar` | verified | Tick dispatch state1==4 = GETTING_OUT_FROM_CAR (PED_STATE enum); sets door anim 7, Ped_GetTargetCarDoor |
| 0x496880 | `PedGameObject_StateFallOnGround` | verified | Tick dispatch state1==8 = FALL_ON_GROUND; switch state2 0x11/0x13/0x14/0x16/0x18-0x1a/0x1b (thrown, burning, lying, run-over); Ped_OnDeath, SpawnMovingObject... |
| 0x4973E0 | `unsure_Position_IsCollidableWithTypeEqual` | hypothesis | unsure_Sprite_IsOwnerTypeCollidable && byte+0x26 == arg; caller Sprite_ShouldCollideWithSprite |
| 0x497A60 | `PedGameObject_Ctor` | verified | eh_vector_constructor_iterator 400 x 0xB4 in 0x435550; 0xB4 = sizeof(GameObject) |
| 0x49A080 | `unsure_PedGameObject_WalkAroundObstacle` | hypothesis | doc ped-movement-collision §4 "walk around along a tangent (+0x69, FUN_0049A080)"; uses +0x28 heading, Ped_ResolveSpriteObstacle |
| 0x49B0D0 | `unsure_PedGameObject_StateGoToCar` | hypothesis | Tick dispatch state1 1/2 (UNKNOWN_1 / GOING_TO_CAR); path/heading toward target (Ped_GetTargetRotation, StepHeadingTowardTarget, ChebyshevDist) |
| 0x49BAC0 | `thunk_unsure_PedGameObject_StateGoToCar` | verified | 5-byte thunk to 0x49b0d0 (Tick case 2) |
| 0x49BAD0 | `PedGameObject_StateEnterCar` | verified | Tick state1==3 (ENTERING_INTO_CAR); state2==6 -> +0x10=0x24, Collision_FindObstacle car, Car_IsOnTrailer |
| 0x49BC20 | `unsure_PedGameObject_StateUnknown5Car` | hypothesis | Tick state1==5 (PED_STATE_UNKNOWN_5); state2==6 puts body at unsure_Car_GetDoorWorldPos |
| 0x49C680 | `PedPathfinder_CanCrossEdge` | verified | MapBlocks_IsBlockEdgeCrossingBlocked on node (+0x25/+0x26/+0x27) in dir |
| 0x49C6E0 | `PedPathfinder_ClearNodes` | verified | zeroes 0x8C4 dwords at +0x40 (34x34 nodes x 8 B) |
| 0x49C700 | `PedPathfinder_InitFields` | verified | PedPathfinder_Ctor body: clears nodes, +0x34=1, +0x2fd0=1 |
| 0x49C740 | `PedPathfinder_ReleaseIfOwner` | verified | if arg == *this: +0x2fd0=1, +0x2fd1=0; Ped_Remove |
| 0x49C760 | `PedPathfinder_ClassifyNode` | hypothesis | returns 1 expand / 2 reached / 0 skip from node table +0x40+idx*8 |
| 0x49C820 | `PedPathfinder_PushOpenNode` | hypothesis | appends 8-byte record at open-list ptr (+8), cost = dx²+dy² x (diff dir +1), count +0xC |
| 0x49C9D0 | `PedPathfinder_SelectFallbackGoal` | hypothesis | switch DAT_0066a7d4 (1..4) copies saved best-node bytes into +0x25..27 / DAT_0066a7b4.. |
| 0x49CB40 | `PedPathfinder_IsRequestHead` | verified | **(this+0x3c) == arg; Ped_MoveTowardTarget |
| 0x49CB60 | `PedPathfinder_CanStepToTile` | verified | cardinal + diagonal step test (slope check MapBlocks_IsSlope1to44At + edge crossing) |
| 0x49CF10 | `PedPathfinder_TryExpandNeighbor` | hypothesis | ClassifyNode -> CanStepToTile -> PushOpenNode |
| 0x49CF70 | `PedPathfinder_FindPath` | verified | 8-neighbour search per call (budget +0x2e=100, +0x2fd1 >200 = abort), result: 3-byte (x,y,z) steps into caller buffer, length byte out; caller Ped_MoveToward... |
| 0x49DCE0 | `PedPathfinder_CanStepFromTile` | verified | sets +0x25..27 then CanStepToTile; caller unsure_Car_IsDoorExitClear |
| 0x49E540 | `unsure_StyleData_IsRemappedKind4Tile` | hypothesis | table +0x6c[tile]==4 && StyleData_IsTileRemapped |
| 0x49E570 | `unsure_StyleData_IsPlainKind4Tile` | hypothesis | same but !Remapped |
| 0x49EF40 | `Ped_GetRefCar` | verified | returns this+0x140 = Ped.refCar (gta2_types.h) |
| 0x49EFB0 | `unsure_Trailer_GetFlagByte` | hypothesis | returns first byte of Car+0x64 link; CarPhysics_EnforceTrailerControlLimits |
