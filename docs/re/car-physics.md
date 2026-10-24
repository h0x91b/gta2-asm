# Car physics in gta2.exe 11.44

How vanilla GTA2 moves, steers, collides and damages a car, read from the binary. Every address
is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`); every name is in the Ghidra DB
(`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and therefore in `re/`.
"verified" = the body was read in the 11.44 decompiler/disassembly; "hypothesis" = the name
carries `unsure_`. Names from CriminalRETeam/gta2_re (GTA2 **10.5**, rev `51d2ce3d`, see
[CREDITS.md](../../CREDITS.md)) were used as candidates only; each one listed here was matched
against the 11.44 body (constants, call shape, field offsets), never by address.

Numbers for constants come from [`re/static_constants.csv`](../../re/static_constants.csv): the
DAT_ globals involved are **zero in the file** and filled by CRT static initialisers, which
[`re/tools/static_constants.py`](../../re/tools/static_constants.py) evaluates (see §8).

Coverage: the CarPhysics module `0x49D000–0x4A4C40` has 147 functions (Player functions excluded),
**137 named**; the 10 left are 2 pathfinder routines, 2 map-face tests, 2 one-byte getters and 4
Player-module helpers that only share the address range. Around it, 316 functions are listed in §7
(286 verified, 30 hypotheses).

## 1. Units

| quantity | representation | unit |
|---|---|---|
| Fix16 (`SCR_f`) | int32, **Q14** (`raw / 0x4000`) | the GTA2 "Fix16" name is historical, it is not Q16 |
| position (`cmPos`, `centerPos`, skid anchors) | Fix16 Vec2 | map blocks (1 block = 0x4000) |
| `linVel` | Fix16 Vec2 | blocks per tick (× 30.3 = blocks/s) |
| `linAccel`, `forceAccum / mass` | Fix16 Vec2 | blocks / tick² |
| `heading` | Ang16, int16 | 0..1439, 1 unit = 0.25° (`Ang16_FormatDegrees` prints `×0.25`) |
| `angVel`, `steerAngle`, "fix-angle" | Fix16 | **71 raw = 1 Ang16 unit**, 0x11C = 1°; a full turn is 6.24, not 2π (`Ang16_ToFix16` ×71, `Fix16_ToAng16` ÷71) |
| `zPos`, `zStep`, `zVelocity` | Fix16 | z levels (blocks), per tick |
| mass, inertia | Fix16 | GCI "mass units" (GCI mass ×1.1), mass·block² |
| damage | short at `Car+0x74` | 0..32000, 32001 = wrecked |

`Fix16_Mul = (int64 a·b) >> 14`, `Fix16_Div = (int64 a << 14) / b` (truncates, no zero check).
The decompiler hides the ECX operand of `Fix16_Mul`-style thiscalls; formulas below were read
from the disassembly where that mattered.

## 2. The clock

* One physics step = **one logic tick = 33 ms** (`nextFrameDeltaTime` 0x45A460:
  `33 − (Game+0x30 ? 22 : 0)` in single player, always 33 in multiplayer). With
  `Game.compensationFPSTime` set the tick is 11 ms (writer not found).
* `drawAndLimitFrames` 0x462A30 (called from `WinMain`'s idle loop) uses `timeGetTime()` only.
  Default registry `max_frame_rate=1`, `min_frame_rate=0` (`RenderSettings_LoadFrameRateLighting` 0x4CB1D0): at most
  one tick per drawn frame and the deadline is re-based to "now" before each tick, so a slow machine
  runs the game slower instead of dropping ticks. `min_frame_rate=1` allows up to 8 catch-up ticks.
* There is no `dt` anywhere: every velocity and acceleration is "per tick" (dt = 1).
* `g_FrameCounter->frame` (0x5E8108) counts ticks; `FrameCounter_Advance` 0x44AA30 runs once per
  `GameTick`, **after** `CarManager_Update`. `CarPhysics.activeUntilFrame` is compared with it.

## 3. Subsystem map (per tick)

```
`WinMain` 0x4D1170 ─ drawAndLimitFrames 0x462A30 ─ Game_RunLogicStep 0x461930 ─ Game_StepByStatus 0x45C3B0
 └ GameTick 0x45C1F0
    ├ Player_Update… → Player_HandleControls 0x4A76D0 → Player_DriveCar 0x4A4C40
    │     → Car_ApplyDriverControls 0x429810 → CarPhysics_SetControls 0x49FB00   (input bytes +0x91..+0x95, +0xAD)
    └ CarManager_Update 0x42A4C0 → CarPool_UpdateAll 0x42A2D0 → Car_Update 0x429E50
        ├ Car_UpdatePhysics 0x427B40 → CarPhysics_Update 0x4A4570      (rigs: TrailerController_UpdatePhysics 0x40FB20)
        │   CarPhysics_SelectModelData 0x49ECC0          g_CurCarEngineData / g_CurCarPhysicsData
        │   switch mode (+0x8C): 1 AI, 2 PLAYER →
        │     CarPhysics_ResetExternalVelocity 0x49F500
        │     CarPhysics_CheckCarAndTrailerCollisions 0x49E270   (broad-phase notify only)
        │     [AI] CarPhysics_ApplySwerveInput 0x49DD30
        │     CarPhysics_EnforceTrailerControlLimits 0x49F280
        │     CarPhysics_UpdateSteerAngle 0x4A16B0
        │     CarPhysics_ComputeForces 0x4A2F20
        │       Car_GetDamageFactorOnSpeed 0x421B90 → 0x66AFC4
        │       CarPhysics_UpdateThrottleRamp 0x49E950 ; CarPhysics_UpdateBrakeRamp 0x49E980
        │       CarPhysics_FrontAxleLateralForce 0x4A1130 ; CarPhysics_RearAxleLateralForce 0x4A1360
        │         CarPhysics_ComputeDriveForce 0x4A0F30 → ComputeThrust 0x49E8E0 / ComputeThrustDamaged 0x49E850
        │         CarPhysics_ApplyAxleForce 0x4A0D40 → ComputePointVelocity 0x49E650, ApplyForceAtPoint 0x4A0850
        │       CarPhysics_ApplySlopeGravity 0x4A20E0
        │       CarPhysics_ForcesToAccel 0x4A0C60 ; CarPhysics_IntegrateVelocity 0x4A0CC0
        │     CarPhysics_DampVelocity 0x49EA70 ; CarPhysics_LimitSpeed 0x4A1B20
        │     CarPhysics_AddExternalVelocity 0x49F4E0
        │     CarPhysics_ApplySteeringAssist 0x4A17C0          (angVel += assist, see §4.4)
        │     CarPhysics_ScarePedsAndTickSwerve 0x49F350
        │     CarPhysics_MoveAndCollide 0x4A4490
        │       CarPhysics_StepAndResolveCollisions 0x4A4310 (up to 2, 4 with peds/objects)
        │         SaveStartPose 0x49DEF0 ; StepIntegrate 0x4A2E30 ; UpdateTrailerFromTowingCar 0x49F1B0
        │         SweepForCollision 0x4A2F90 (ComputeRequiredSweepSteps 0x49F930, TestCollision 0x4A0020)
        │         BinarySearchCollisionTime 0x4A30A0 (3 bisections)
        │         OnCollision 0x4A4270 → DispatchCollision 0x4A4170 → §5
        │         UpdateSurfaceAndEmitLanding 0x4A2980 → UpdateSurface 0x4A26C0
        │       still stuck + gas: CarPhysics_NudgeOutOfCollision 0x4A2D70
        │     CarPhysics_CheckPendingCollision 0x4A2DB0
        │     CarPhysics_DoSkidmarks 0x4A0560 → UpdateSkidmarks 0x4A0290 → SpawnSkidSegment 0x4A0120
        │     CarPhysics_SubExternalVelocity 0x49F4F0 ; CarPhysics_SubExternalAngVel 0x49EA60
        │   mode 0 PUSHED / 3 transient / 4 KINEMATIC: reduced sequences (no input, StepKinematic 0x4A3120 for 4)
        │   CarPhysics_UpdateStationaryTimer 0x4A1BA0 → 1 = caller may free the physics object
        ├ Car_TickWreckTimer 0x429660, Car_TickLastDamageTimer 0x4209F0, Car_CheckDeath 0x427450
        └ (trailers) Car_UpdateTrailerPair 0x426540, (trains) Car_UpdateTrain 0x4298B0
```

## 4. Mechanics

### 4.1 Integration (semi-implicit Euler, dt = 1 tick)
```
linAccel = forceAccum / mass            angAccel = −torqueAccum / inertia     (note the minus)
linVel  += linAccel                     angVel  += angAccel
forceAccum = torqueAccum = 0
|vx|+|vy| < 1/256 → linVel = 0          |angVel| < 1/256 (0x6658DC = 1/(64·4), initialiser operands) → 0
s = step · g_CollisionRemainingFraction (0x66AFC0)
heading += Fix16_ToAng16(angVel·s) ; cmPos += linVel·s ; centerPos = cmPos − R(heading)·cmOffset
zPos += zStep(saved at start)·step ; UpdateGroundZ ; WriteSprite (sprite = centerPos, zPos, heading)
```
Only the movement is sub-stepped (by the collision sweep); forces are evaluated once per tick.
Gravity in the air: `zVelocity −= 1/64` per tick (raw 0x100) down to −0.125 (`CarPhysics_UpdateSurface`).
Damping (`CarPhysics_DampVelocity`): velocity rotated into the car frame, lateral ×0.90 / forward
×0.97 / angVel ×0.88 on the ground; ×0.95 / ×0.985 / ×0.94 in the air (0.985 from 10.5, its
11.44 initialiser is not decoded); both axes are zeroed below 1/128.

### 4.2 Engine, gears, top speed, brakes (slice 2)
* Throttle "revs" `+0x60`: +0.25 per tick with gas (fwd or reverse) up to 5.0, −0.25 without.
* Thrust (`CarPhysicsData`): `half_thrust + revs·fifth_thrust`, ×2 when `turbo && revs ≥ 3.0`;
  the damaged variant multiplies the revs term by `D = damage < 16000 ? 1 : (32001 − damage)/16000`.
* Gear is **not stored**, it is picked every tick from `|linVel|`: above `gear3_speed` →
  `ThrustDamaged·gear3_multiplier`, above `gear2_speed` → `ThrustDamaged·gear2_multiplier`, else
  `Thrust·gear1_multiplier`; reverse `−Thrust·gear1_multiplier`. AI cars: `±ThrustDamaged`, no gears.
  No drive force with the engine off (`Car+0x9C != 3`) or on surface 7/8 (water).
* Top speed (`CarPhysics_LimitSpeed`, after damping, not in the air): `max_speed` while the
  velocity is within ±90° of the heading, otherwise `gear2_speed`; damage does not lower it.
* Foot brake ramp `+0x64` +0.25/tick to 1.0; `0x66AC28 = brakeLevel·brake_friction` feeds the tyre
  model. Inputs (`SetControls`): Down while rolling forward = brake, Up while rolling backward =
  brake, reverse only from exactly zero velocity.
* Player may leave the car when `|linVel| < 0.3` (`Car_CanExitCar` 0x4222A0 →
  `CarPhysics_IsNearlyStopped` 0x49EED0, constant 0x66AFC8 = 0x1333).

### 4.3 Steering and tyres (slice 3)
* `steerAngle = turn_ratio · steering(−1/0/+1)` (×2.5 for a cab with trailer). Player cars only:
  × `max(0.6 − |v|, 0.25)/(0.6·0.8)` → ×1.25 at rest, ×0.52 from |v| = 0.35.
* Per axle (`Front/RearAxleLateralForce` → `ApplyAxleForce`): wheel point `(0, wheel_offset)`,
  point velocity rotated into the wheel frame, `F_lat = −v_lat·cx`, `F_long = −v_long·cy + drive`,
  applied at the wheel (force + torque). **Linear viscous grip, no saturation**; the skid thresholds
  only decide tyre marks.
  * front: angle = steerAngle, `cx = 1 + turn_in` while steering, `cy = 0.1387 + brake·0.8`, drive × `front_drive_bias`.
  * rear: counter-steer `−((0.6 − |v|)/(0.6·3.8))·steerAngle`, `cx = 1 − turn_in` while steering,
    `cy = 0.1387 + brake·0.2`, drive × `rear_drive_bias`; handbrake: `cx ×= handbrake_slide_value`,
    `cy += brake_friction·held/128` (held counter `+0xA8` saturates at 128); then both × `rear_end_stability`.
  * swerve (oil, `swerveState` 1/2, 30 ticks): ±30° on front, ∓30° on rear, gas forced on.
* Mass = GCI mass ×1.1 (`CarEngineData_ConvertMass`), × car scale, +5% with a player driver that has
  an occupation; inertia and CM offset from CARI w/h and `front_mass_bias` (`CarPhysicsData_ComputeInertia`).

### 4.4 Steering assist (road arrows)
Confirmed: `CarPhysics_ApplySteeringAssist` **adds** a correction to `angVel` (via
`g_CarExternalAngVel` 0x66AE0C) before `MoveAndCollide`, and `CarPhysics_SubExternalAngVel`
**subtracts** it after — net angVel is unchanged, only this tick's heading moves. Active only for a
human driver with no steering input, throttle ≥ 2.0 (player), velocity aligned with heading, no
swerve, on a road block (`blk+0xB & 3 == 1`) whose arrows (`blk+0xA`) point along an axis within
25° of the heading (0x33 → 90°/270°, 0xCC → 0°/180°/360°). Correction = `target − heading`,
clamped to `|v|·0.13` (`·0.26` for short sprites, `Car_GetSteerAssistLimit` 0x4234A0).
The same external-velocity trick carries object pushes (`CarPhysics_ApplyConveyorPush` 0x49F460).

### 4.5 Collisions and response (slice 4 + orchestrator)
* Pipeline: broad phase on the collision grid rows (`Collision_FindObstacle` 0x447740,
  `Collision_CheckAndNotifyAllForSprite` 0x447480, grids `g_CollisionGridObstacles/Notify/Aux`
  0x5E668C/90/94) → filter `Sprite_ShouldCollideWithSprite` 0x4B9A30 → narrow phase
  `Sprite_CollisionCheck` 0x4BCAC0 (z overlap + rotated-rect corners both ways) → time of impact
  (stepped sweep, then 3 bisections) → replay pose at the hit → contact point → impulse.
  Result record at `g_CollisionResult` 0x5E6874 (`COLLISION_RESULT_KIND`: 1 wall X, 2 wall Y, 3 sprite,
  4 floor, 5 ceiling — 4 / 5 only from ballistic objects); full layout (`wallMin/MaxX/Y`, `contactX/Y`,
  `hitZ`, `hitSprite`, `moverSprite`) in [ped-movement-collision.md](ped-movement-collision.md)
  "`CollisionResult`".
* Impulse (`CarPhysics_ComputeCollisionImpulse` 0x4A05C0, verified):
  `j = −(1+e)·(v_rel·n̂) / ((n·n)(1/mA + 1/mB) + (rA⊥·n)²/IA + (rB⊥·n)²/IB)`, impulse = `n̂·j`;
  an immovable body passes mass −1 (`g_Fix16MinusOne`) and its terms are dropped.
  Restitution by caller:

  | contact | e | other body |
  |---|---|---|
  | car–wall (`CarPhysics_ApplyWallImpulse` 0x4A32D0) | 0x66AE38 = **0.25** | immovable |
  | car–car (`CarPhysics_CollideWithCar` 0x4A34A0) | 0x66B04C = **0.5** | other car's mass/inertia, equal and opposite `ApplyImpact` |
  | car–ped (`CarPhysics_CollideWithSprite` 0x4A0A30) | 0x66AE88 = 1.0 | ped mass 0.5 (0x66AC44), inertia 1.0; the **car gets no impulse**, the ped reacts by impulse tiers (`PedGameObject_HandleCarImpact` 0x497570) |
  | car–object (`CarPhysics_CollideWithObject` 0x4A3A40) | 0x66AEA4 = 1.0 | object inertia 1.0 |
* `CarPhysics_ApplyImpact` 0x4A31B0 applies it (threshold-gated), wakes the car
  (`KeepActiveFor` 15 ticks for walls, 0x32 for car–car), and stores `g_CollisionImpactMagnitude`
  0x66B034, which drives damage and sound.
* If the car could not move at all and gas is held, `unsure_CarPhysics_NudgeOutOf*` push it off the
  obstacle (mass-scaled kick + heading snap, `CarPhysics_ApplyAngularImpulse` 0x49E330).

### 4.6 Damage, deformation, wreck (slice 5)
* `Car_ApplyImpactDamage` 0x4292F0: `points = int(impulse·200)` (none with `Car` flag 0x8 = invincible);
  taxi + impulse > 2.0 → fares get out.
* `Car_AddDamage` 0x427180: `d = int(points·anti_strength)`, at least 1 unless `anti_strength == 0`
  (indestructible); `damage += d`, clamp 32000. Stages: ≥16000 small fire (`Car+0x8C = 3`), ≥25000
  big fire (4), >31499 lights/engine off, ==32000 `Car_Explode`.
* `Car_Explode` 0x426FA0: damage = 32001, wreck timer 50 ticks → `Car_BecomeWreck` 0x427B60 swaps the
  sprite. `Car_TriggerExplosion` 0x429370: real explosion only if destructible and not wrecked.
* Deformation: after both damage calls, if impulse > **0.3** (0x66AD00) `Car_TryDamageArea` 0x423180
  maps the contact side 0/1/2/3 (from the sprite contact classifier) to area 3/2/0/1 and
  `Car_DamageArea` 0x422F00 sets a delta bit in `Car+8` (bits 0..4: four corners + windscreen),
  permanent until `Car_Repair` 0x425F20.
* Weapon/explosion hits: `Car_OnDamage` 0x4274C0 (bullets 800, type 0x109 1600, type 0xC2 100,
  explosions 32000; ×2 with powerup 7; immunity flags 0x100/0x200/0x400).

### 4.7 Tyre marks and surface (slice 5)
* `CarPhysics_UpdateSkidmarks` 0x4A0290, per wheel, only when on screen for a player and not in
  the air: rear marks when `rearSlip ≥ skid_threshhold2` or (`wheelSpinTimer > 0` and rear drive);
  front with `frontSlip ≥ skid_threshhold1` or (`wheelSpinTimer > 0` and front drive).
  Thresholds = GCI `skid_threshhold·(1 ∓ 0.1)` (0x5E54A0 = 0x666, front lower). Segments join the
  previous wheel anchor (`rrSkid..flSkid` +0x10..+0x2F); object id by segment length
  (≤ 0.0625 / 0.25 / 0.375 / longer) and surface type (water 3, grass 2).
* `CarPhysics_UpdateSurface` 0x4A26C0: `surfaceType` (+0x98: 0 flat, 1..4 slope, 5 no lid, 6 air,
  7 water tile, 8 in water, 9 wet), `groundMaterial` (+0x9C), slope bytes +0xA5..+0xA7, landing
  puffs. Sunk and slower than 0.05 → `Car_OnWrecked`. Oil (objects 8/9) → `CarPhysics_StartSwerve`.
  No grip change by surface was found (grass only changes the mark object).

## 5. Structures

### CarPhysics (0xB0, pool of 306 at `ptrToCarPhysicsPool` 0x66AB7C)
| off | field | type | unit / meaning |
|---|---|---|---|
| 0x00 | cmDeltaX/Y | Fix16 ×2 | cmPos displacement during this tick |
| 0x08 | activeUntilFrame | uint | tick number; `KeepActiveFor(n)` = max(.., frame+n) |
| 0x0C | next | CarPhysics* | pool free list |
| 0x10/18/20/28 | rrSkid, rlSkid, frSkid, flSkid | Vec2 | last tyre-mark anchor per wheel, (0,0) = none |
| 0x30 | cmPos | Vec2 | centre of mass, blocks |
| 0x38 | centerPos | Vec2 | sprite position, blocks |
| 0x40 | linVel | Vec2 | blocks/tick |
| 0x48 | forceAccum | Vec2 | cleared every integration |
| 0x50 | linAccel | Vec2 | blocks/tick² |
| 0x58 | heading | Ang16 | 0..1439 |
| 0x5C | car | Car* | owner |
| 0x60 | throttle | Fix16 | "revs", 0..5.0 |
| 0x64 | brakeLevel | Fix16 | 0..1.0 |
| 0x68 | zVelocity | Fix16 | z/tick in the air |
| 0x6C | zPos | Fix16 | z level |
| 0x70 | zStep | Fix16 | z delta per full tick (UpdateGroundZ) |
| 0x74 | angVel | Fix16 | fix-angle/tick (71 = 1 Ang16 unit) |
| 0x78 | steerAngle | Fix16 | fix-angle |
| 0x7C | torqueAccum | Fix16 | |
| 0x80 | angAccel | Fix16 | = −torque/inertia |
| 0x84/0x88 | frontSlip / rearSlip | Fix16 | \|lateral tyre force\| this tick |
| 0x8C | mode | enum | 0 PUSHED, 1 AI, 2 PLAYER, 3 transient, 4 KINEMATIC |
| 0x90 | framesStationary | byte | ≥ 20 → may be freed |
| 0x91..0x95 | isBrakeOn, isHandbrakeOn, isForwardGasOn, isReverseGasOn, isCoasting | byte | inputs |
| 0x98 | surfaceType | CAR_SURFACE | see 4.7 |
| 0x9C | groundMaterial | CAR_SURFACE2 | |
| 0xA0 / 0xA4 | swerveState / swerveTimer | int / byte | oil spin |
| 0xA5..0xA7 | slopeLength, slopeLeftTiles, tileZ | byte | |
| 0xA8 | handbrakeHeldFrames | byte | 0..128 |
| 0xA9 | cachedModelId | CAR_MODEL | |
| 0xAA | unsure_movedByCollision | bool | set by NudgeOutOf* |
| 0xAB | unsure_someCornersUnsupported | bool | 1 when 1–2 corners have no support (was `unsure_partlyAirborne`) |
| 0xAC | wheelSpinTimer | byte | handbrake / wheel-spin marks |
| 0xAD | steering | char | −1 / 0 / +1 |

### CarEngineData (72 B, one NYC.GCI record; `tools/formats/gci.ts` has the same order)
`model`, `turbo`, `value` (score weight, not physics), `pad`, then 17 Fix16: `mass` (×1.1 after
load), `front_drive_bias`, `front_mass_bias`, `brake_friction` (handbrake drag), `turn_in`,
`turn_ratio` (max wheel angle, fix-angle), `rear_end_stability`, `handbrake_slide_value`, `thrust`,
`max_speed` (blocks/tick), `anti_strength` (damage multiplier, 0 = indestructible),
`skid_threshhold`, `gear1/2/3_multiplier`, `gear2_speed`, `gear3_speed` (blocks/tick; the loader
requires `gear2_speed ≤ gear3_speed ≤ max_speed`). Decimal GCI values are **truncated**
(`0.145` → 0.14496).

### CarPhysicsData (44 B, per model, `CarPhysicsData_Build` 0x432AA0)
| off | field | formula |
|---|---|---|
| 0x00 | inertia | from CARI w/h, mass, front_mass_bias |
| 0x04 / 0x08 | front_wheel_offset / rear_wheel_offset | size table[CARI wheel index], blocks |
| 0x0C | cmOffset | (0, cmY) |
| 0x14 / 0x18 | half_thrust / fifth_thrust | thrust/2, thrust/5 |
| 0x1C | max_thrust_turbo | half + fifth·5·(turbo ? 1.5 : 1) |
| 0x20 | rear_drive_bias | 1 − front_drive_bias |
| 0x24 / 0x28 | skid_threshhold1 / 2 | skid·0.9 (front) / skid·1.1 (rear) |

## 6. Corrections to earlier notes

| note | claim | binary says |
|---|---|---|
| `docs/formats/lessons.md`, `lane-assist.md` | assist adds angular velocity then subtracts it | **confirmed** (§4.4) |
| `docs/formats/findings/vehicle-data.md` | handling clock 33 ms | **confirmed** (§2), plus an 11 ms mode |
| `vehicle-data.md` | exit threshold 4.2 m/s (player calibration) | `|linVel| < 0.3` blocks/tick (0x1333) |
| `vehicle-data.md` | wall restitution 0.1 (provisional) | 0.25 for walls, 0.5 car–car, 1.0 peds/objects |
| `vehicle-data.md` | skid thresholds `1 ∓ Q14(0.1)` | confirmed (0x5E54A0 = 0x666) |
| `car-deltas.md` | deltas when magnitude ≥ 1, side from sin/cos | impulse > 0.3, side from the sprite contact classifier |

Existing DB names changed in this pass (was → now, reason in the plate comment):
`CarPhysics_DampAngularVelocity` → `CarPhysics_DampVelocity` (also damps linear velocity);
`relToCarWidth` → `Car_GetSteerAssistLimit`; `GoForward` → `Fix16_SubAssign`;
`relToPlayerPosZ` → `Fix16_IsEqual`; `TogglesEmergencyLightsAndBrakes` → `CarDeltas_SetBit`;
`unsure_Car_AttachDeltaSprites` → `Car_AttachEmergencyLights`; `unsure_Car_ExplodeIfGrounded` →
`Car_TriggerExplosion`; `unsure_CarPhysics_ComputeSweepFraction` → `CarPhysics_ComputeRequiredSweepSteps`;
`unsure_Fix16Vec2_Ctor` → `Fix16Vec2_MulAssign` (now `Vec2_MulAssignFix16`); `unsure_` dropped from `Collision_FindObstacle`,
`Gci_ParseText`, `CarPhysics_ComputeRelativePointVelocity`, `CarPhysics_ComputeCollisionImpulse`;
global `g_CollisionContactRelCm` → `g_CollisionNormal`; field `unsure_partlyAirborne` →
`unsure_someCornersUnsupported`. `CarPhysics_CollideWithSprite` is kept but handles **peds** only.

## 7. Function table

Generated from the DB (name, plate comment) and the slice reports. Role is one line; the plate
comment in Ghidra has the evidence.

#### 1. Tick, clock and per-car entry (15)

| address | name | role | confidence |
|---|---|---|---|
| `0x40FB20` | `TrailerController_UpdatePhysics` | CarPhysics_Update of the cab for a rig | verified |
| `0x41CFE0` | `FrameCounter_GetFrame` | reads `*ECX` (g_FrameCounter->frame) | verified |
| `0x427B40` | `Car_UpdatePhysics` | CarPhysics_Update; if it returns 1 and no driver -> free physics | verified |
| `0x429E50` | `Car_Update` | per-car update, calls Car_UpdatePhysics | verified |
| `0x42A2D0` | `CarPool_UpdateAll` | iterate cars, Car_Update, destroy | verified |
| `0x42A4C0` | `CarManager_Update` | car manager tick | verified |
| `0x44AA30` | `FrameCounter_Advance` | `frame++; frameRandom=Crt_Rand()` on g_FrameCounter | verified |
| `0x45A460` | `nextFrameDeltaTime` | tick length: 33 ms (11 ms if compensationFPSTime) | verified |
| `0x45C1F0` | `GameTick` | all per-tick managers; CarManager_Update inside; FrameCounter_Advance near the end | verified |
| `0x45C3B0` | `Game_StepByStatus` | processPlayerKeys, gameStatus switch -> GameTick | verified |
| `0x461930` | `Game_RunLogicStep` | one logic tick | verified |
| `0x462A30` | `drawAndLimitFrames` | the 33 ms fixed-step scheduler + draw | verified |
| `0x4A4570` | `CarPhysics_Update` | per-car tick state machine (section 2) | verified |
| `0x4CB1D0` | `RenderSettings_LoadFrameRateLighting` (was `loadRenderSettings1`) | reads registry max_frame_rate (default 1) / min_frame_rate (default 0) used by the scheduler | verified |
| `0x4D1170` | `WinMain` | main loop; idle -> drawAndLimitFrames (`0x4D11B8` is the false split `WinMain_AfterNoppedMutexCheck_Frag`) | verified |

#### 2. Integration, pose, Z and trailers (69)

| address | name | role | confidence |
|---|---|---|---|
| `0x40F900` | `TrailerController_UpdateAlignment` | hitch constraint between cab (+8) and trailer (+0xC) | verified |
| `0x414F70` | `Car_HasFlag2000` | `Car_HasFlags(car,0x2000)`. Flag 0x2000 (Car+0x78) = "touching another car this tick": set **only** by `CarPhysics_CollideWithCar` (0x4A36C2, 0x4A37A6 via `Car_AddFlag2000` 0x49EFC0), cleared by `CarPhysics_CheckPendingCollision` (U1, 2026-10-24) | verified |
| `0x420F80` | `CarPhysicsPool_Ctor` | CarPhysicsPool ctor: 306 (0x132) CarPhysics objects of 0xB0 bytes constructed in place (arr306), chained into a free list through… | verified |
| `0x420FD0` | `CarPhysicsPool_Alloc` | pop the head of the free list (firstFree = head->next), CarPhysics_Init(head), return it. NO empty-check (306 slots; the caller… | verified |
| `0x421130` | `CarPhysics_IsKeptActive` | `frame < activeUntilFrame` | verified |
| `0x425D90` | `Car_CreatePhysics` | if car has no physics: Car_AllocPhysicsIfNeeded -> CarPhysics_AttachCar -> CarPhysics_InitFromSprite(sprite); if it exists and car is a… | verified |
| `0x425DD0` | `Car_EnsurePhysics` | physics on demand: trailer rig -> TrailerController_CreatePhysics(trailerController) (creates physics for both), else Car_CreatePhysics. 12 callers (driver… | verified |
| `0x426120` | `Car_FreePhysics` | return car->physics to the pool (CarAIPool_PushFree(ptrToCarPhysicsPool, physics)) and set car->physics=NULL. Called from Car_Destroy,… | verified |
| `0x4262E0` | `Car_UpdateArticulatedCabTrailerSearch` |  | verified |
| `0x49DD10` | `CarPhysics_UpdateTrailerAlignment` | -> TrailerController_UpdateAlignment | verified |
| `0x49DE40` | `CarPhysics_RestoreStartPose` | inverse of SaveStartPose: restores car+trailer fields +30,+34,+6c,+58,+38,+3c,+70,+68 from DAT_0066acd0.. block. | verified |
| `0x49DEF0` | `CarPhysics_SaveStartPose` | copies car (+0x30/34 vel? pos, +0x6c z, +0x58 rot, +0x38/3c, +0x70, +0x68) and trailer fields into scratch globals DAT_0066acd0..… | verified |
| `0x49DF90` | `CarPhysics_RestoreTargetPose` | restores car+trailer fields from the DAT_0066abb8.. block saved by SaveTargetPose. | verified |
| `0x49E040` | `CarPhysics_SaveTargetPose` | saves same field set as SaveStartPose into second scratch block DAT_0066abb8.. ("target pose" = full-step end state). Restore = 0x49DF90. | verified |
| `0x49EA60` | `CarPhysics_SubExternalAngVel` | angVel -= g_CarExternalAngVel | verified |
| `0x49ECC0` | `CarPhysics_SelectModelData` | sets g_CurCarPhysicsData / g_CurCarEngineData for the car's physics model | verified |
| `0x49ED00` | `CarPhysics_CpFromCm` | centerPos = cm - R(heading)*cmOffset | verified |
| `0x49ED60` | `CarPhysics_CmFromCpViaModel` | same as CmFromCp but model data looked up via the car | verified |
| `0x49EDC0` | `CarPhysics_CmFromCp` | cm = centerPos + R(heading)*cmOffset | verified |
| `0x49EE10` | `CarPhysics_InitFromSprite` | pose from sprite xyz/rot, steerAngle=0, CmFromCpViaModel | verified |
| `0x49EE80` | `CarPhysics_WriteSprite` | sprite pos = (centerPos.x, centerPos.y, zPos), rotation = heading | verified |
| `0x49EEB0` | `CarPhysics_WriteSpriteAndTrailer` | + trailer partner | verified |
| `0x49EF50` | `CarPhysics_KeepActiveFor` | activeUntilFrame = max(.., frame+n) | verified |
| `0x49EF80` | `CarPhysics_IsStandingStill` | `linVel==0 && angVel==0` | verified |
| `0x49F170` | `CarPhysics_IsNotMoving` | stationary check, rig aware | verified |
| `0x49F1B0` | `CarPhysics_UpdateTrailerFromTowingCar` | trailer linVel/angVel/zStep from its pose delta | verified |
| `0x49F280` | `CarPhysics_EnforceTrailerControlLimits` | cab with trailer: reverse gas -> foot brake; no forward gas -> turn dir 0 | verified |
| `0x49F350` | `CarPhysics_ScarePedsAndTickSwerve` | ped scare + swerve timer countdown | verified |
| `0x49F4E0` | `CarPhysics_AddExternalVelocity` | linVel += g_CarExternalLinVel | verified |
| `0x49F4F0` | `CarPhysics_SubExternalVelocity` | linVel -= g_CarExternalLinVel | verified |
| `0x49F500` | `CarPhysics_ResetExternalVelocity` | g_CarExternalLinVel = 0 | verified |
| `0x49F510` | `CarPhysics_GetLookAheadZ` | zStep(+0x70) > 0 ? min(zPos + 1.0, DAT_0066AD1C = 7.984) : zPos. Only caller 0x420270. Purpose unconfirmed. | verified |
| `0x49F570` | `CarPhysics_GetCombinedCm` | centre of mass of the rig (mass weighted) | verified |
| `0x49F660` | `CarPhysics_GetMass` | Car_GetMass, or cab+trailer when towing | verified |
| `0x49F6C0` | `CarPhysics_GetInertia` | physicsData.inertia, or cab+trailer sum | verified |
| `0x49F760` | `CarPhysics_SetVelocityTowardTarget` | kinematic placement: linVel = (target + R(heading)*cmOffset) - cmPos, angVel = targetAngle - Ang16_ToFix16(heading) unwrapped by turn… | verified |
| `0x49F930` | `CarPhysics_ComputeRequiredSweepSteps` | returns the NUMBER OF SWEEP STEPS (distance in car half-width units, caller takes `Fix16_ToIntC`), not a 0..1 fraction | verified |
| `0x49FAC0` | `CarPhysics_ClearForces` | zero +0x48,+0x50,+0x7C,+0x80 | verified |
| `0x49FBE0` | `CarPhysics_ComputeSlopeCorrection` | z gained along a slope this step (two outputs) | verified |
| `0x49FDC0` | `CarPhysics_UpdateZOnRailway` | train Z (railway height + slope correction) | verified |
| `0x49FF70` | `CarPhysics_UpdateZOnRailway` |  | verified |
| `0x4A0560` | `CarPhysics_DoSkidmarks` | skidmarks for car + trailer | verified |
| `0x4A0850` | `CarPhysics_ApplyForceAtPoint` | force at point, +0x48 linear, +0x7c torque | verified |
| `0x4A0930` | `CarPhysics_ApplyMassKick` | +0x48 += f(mass) | verified |
| `0x4A0C60` | `CarPhysics_ForcesToAccel` | a = F/m ; angAccel = -T/I | verified |
| `0x4A0CC0` | `CarPhysics_IntegrateVelocity` | v += a, w += alpha, ClearForces, dead zones | verified |
| `0x4A1BA0` | `CarPhysics_UpdateStationaryTimer` | framesStationary++ ; true when >= 20 | verified |
| `0x4A1BE0` | `CarPhysics_Reset` | reset dynamic state (mode=1 AI, cachedModelId=0xFF, ...) | verified |
| `0x4A1CF0` | `CarPhysics_Init` | initialise a pool slot: cmPos=0, heading(+0x58)=DAT_0066AC08 (0), centerPos=0, next(+0xC)=NULL, Reset, cmDelta(+0)=0. Called by… | verified |
| `0x4A1D30` | `CarPhysics_AttachCar` | physics->car(+0x5C)=car; mode := PLAYER(2) if Car_HasPlayerDriver else AI(1). Called by Car_CreatePhysics. gta2_re 10.5: SetCar_5638C0. | verified |
| `0x4A1D60` | `CarPhysics_Ctor` | CarPhysics constructor for the pool vector-ctor: constructs the 4 skid Vec2 members (+0x10..+0x2F, 8 bytes each, Nop_ReturnThis),… | verified |
| `0x4A20E0` | `CarPhysics_ApplySlopeGravity` | slope gravity force | verified |
| `0x4A2240` | `CarPhysics_UpdateGroundZ` | per-step Z following (air / water / ground / slope); prototype fixed `(CarPhysics*, int step)` | verified |
| `0x4A2640` | `CarPhysics_UpdateZWithTrailer` | UpdateGroundZ for cab + trailer, both get the higher z/zStep | verified |
| `0x4A2980` | `CarPhysics_UpdateSurfaceAndEmitLanding` | surface update + landing particles | verified |
| `0x4A2A30` | `CarPhysics_NudgeOutOfWallY` | Y twin of NudgeOutOfWallX (uses contact rel-cm x). | verified |
| `0x4A2B40` | `CarPhysics_NudgeOutOfWallX` | wall-X stuck fix: from heading (+0x58, half-turn flip if +0x94), compares contact rel-cm y (g_CollisionNormal+4) sign with heading… | verified |
| `0x4A2C70` | `CarPhysics_NudgeOutOfSprite` | stuck-vs-sprite nudge: kick strength chosen by hit sprite (obj type 0xA6 weak DAT_0066aea8, player driver DAT_0066af80, AI… | verified |
| `0x4A2D70` | `CarPhysics_NudgeOutOfCollision` | called by MoveAndCollide after a hit when engine accelerates: switch g_CollisionResult.kind 1 -> NudgeOutOfWallX, 2 -> WallY, 3 ->… | verified |
| `0x4A2DB0` | `CarPhysics_CheckPendingCollision` | if Car flag 0x2000: overlap check vs sprites (mask 2), else clear flag | verified |
| `0x4A2E00` | `CarPhysics_ApplyImpulseAndIntegrate` | ApplyForceAtPoint(mode 0)+ForcesToAccel+IntegrateVelocity | verified |
| `0x4A2E30` | `CarPhysics_StepIntegrate` | move by `step` of remaining movement; prototype fixed to `(CarPhysics*, int step)` | verified |
| `0x4A2F20` | `CarPhysics_ComputeForces` | throttle/brake ramps, axle forces, slope gravity, ForcesToAccel, IntegrateVelocity | verified |
| `0x4A2F90` | `CarPhysics_SweepForCollision` | stepped sweep for first colliding step | verified |
| `0x4A30A0` | `CarPhysics_BinarySearchCollisionTime` | 3 bisections refining hit time | verified |
| `0x4A3120` | `CarPhysics_StepKinematic` | mode 4: remaining=1.0, SaveStartPose, StepIntegrate(1.0), no collisions | verified |
| `0x4A31B0` | `CarPhysics_ApplyImpact` | threshold-gated apply of impulse, alarm, keep-active, handbrake release | verified |
| `0x4A4310` | `CarPhysics_StepAndResolveCollisions` | sweep + resolve loop | verified |
| `0x4A4490` | `CarPhysics_MoveAndCollide` | movement loop with collision retries | verified |

#### 3. Engine, gears, brakes and driver input (41)

| address | name | role | confidence |
|---|---|---|---|
| `0x40F840` | `CarPhysics_IsVelocityAlignedWithHeading` | linVel within ±90° of heading | verified |
| `0x4118C0` | `Car_IsEngineOn` | Car.engineState(+0x9C)==3 (ENGINE_ON). gta2_re 10.5: field_9C_engine_status == on_3. | verified |
| `0x4211A0` | `CarPhysics_GetSpeed` | speed accessor = Fix16Vec2_GetLength(CarPhysics+0x40 linVel). show_instruments prints it as 'speed:%3.3f(gear)'. | verified |
| `0x421200` | `CarPhysics_ClearSteering` | steering(+0xAD)=0 (signed char: +1 left, -1 right). | verified |
| `0x421210` | `CarPhysics_SetGasForward` | force forward gas: +0x93=1, brake +0x91=0, reverse +0x94=0, coast +0x95=0. gta2_re 10.5: ForceForwardAcceleration_453F70 (matched). | verified |
| `0x421250` | `CarPhysics_SetHandbrake` | +0x92=1 | verified |
| `0x421260` | `CarPhysics_ReleaseHandbrake` | isHandbrakeOn(+0x92)=0. | verified |
| `0x421270` | `CarPhysics_IsHandbrakeOn` | returns isHandbrakeOn(+0x92). | verified |
| `0x4212A0` | `CarPhysics_SetModeAI` | CarPhysics.mode(+0x8C)=1 (AI). Modes: 1 AI, 2 player, 3/other see CarPhysics_Update switch (slice 1). | verified |
| `0x4212B0` | `CarPhysics_SetModePlayer` | CarPhysics.mode(+0x8C)=2 (player). Player mode enables gears (ComputeDriveForce) and speed-sensitive steering (UpdateSteerAngle). | verified |
| `0x4213D0` | `TurnOnCarBrakeLights` | lights bits, not physics | verified |
| `0x421B90` | `Car_GetDamageFactorOnSpeed` | damage (Car+0x74) -> 1.0 … 0 power scale | verified |
| `0x4221A0` | `Car_FullStop` | Car(+0x58 physics): footbrake on (+0x91=1), gas/reverse/coast off. Used by AI/scripts to stop a car. Compare Car_BrakeHard (also sets… | verified |
| `0x4221B0` | `Car_BrakeHard` | CarPhysics_SetHandbrake + footbrake on, gas/reverse/coast off. | verified |
| `0x4222A0` | `Car_CanExitCar` | may the player leave this car now? false if Car_HasSpriteZoom(car); true if car has no CarPhysics (+0x58); else /physics.linVel/ <… | verified |
| `0x426030` | `Car_UpdateEngineState` | Car engineState machine tick. ENGINE_OFF: if physics exists and IsEngineAccelerates -> state 'REL_TO_CAR_SIREN' (=starting; enum name… | verified |
| `0x426E00` | `Car_EngineOn` | engineState=ENGINE_ON(3) + EngineStartedLightsOn. | verified |
| `0x429810` | `Car_ApplyDriverControls` | Car-level input, roof turret/horn/trailer, then SetControls | verified |
| `0x42AB90` | `CarPhysics_SteerPlus` | steering(+0xAD)=+1 (left; gta2_re car_turn_direction clockwise_m1 is right = -1). | verified |
| `0x42ABA0` | `CarPhysics_SteerMinus` | steering(+0xAD)=-1 (0xFF, right). | verified |
| `0x42ABB0` | `CarPhysics_ClearSteeringAndAngle` | steering(+0xAD)=0 and steerAngle(+0x78)=DAT_005e5194 (zero angle). | verified |
| `0x42ABC0` | `CarPhysics_SetCoast` | force neutral/coast: +0x95=1, +0x91=+0x94=+0x93=0. gta2_re 10.5: ForceNeutralInput_453F50 (matched). | verified |
| `0x42AC00` | `CarPhysics_ReleaseControls` | clear driver inputs: +0x91,+0x93,+0x94,+0x95 = 0 (handbrake and steering untouched). gta2_re 10.5: ClearDriverInputs_453F90 (matched). | verified |
| `0x49DD80` | `CarPhysics_IsInAir` | surfaceType==6 (cab+trailer) | verified |
| `0x49DDC0` | `CarPhysics_IsFootBrakeOn` | footbrake byte +0x91 of this car, or of the towing cab's physics when it is a trailer (car+0x64 controller, +8 cab). Caller 0x423850.… | verified |
| `0x49DDF0` | `IsEngineAccelerates` | fwd or reverse gas on (cab's if trailer) | verified |
| `0x49E820` | `CarPhysics_IsTurboRevving` | `Eng.turbo && revs >= 3.0` | verified |
| `0x49E850` | `CarPhysics_ComputeThrustDamaged` | thrust1 + revs*damageFactor*thrust2 (x2 turbo) | verified |
| `0x49E8E0` | `CarPhysics_ComputeThrust` | same without damage factor | verified |
| `0x49E950` | `CarPhysics_UpdateThrottleRamp` | revs (+0x60) ramp ±0.25/tick, clamp 0..5 | verified |
| `0x49E980` | `CarPhysics_UpdateBrakeRamp` | brakeLevel (+0x64) ramp, DAT_0066ac28 = level*brake_friction | verified |
| `0x49EA70` | `CarPhysics_DampVelocity` | drag step: zero tiny linVel, damp lin x/y in car frame + angVel | verified |
| `0x49EED0` | `CarPhysics_IsNearlyStopped` | returns /linVel (+0x40)/ < DAT_0066AFC8 (= 0x1333 = 0.3 Q14, copied from 0x66AD00 at 0x544CA0). Only reached by tail-jump from… | verified |
| `0x49F010` | `show_instruments` | debug overlay (g_doShowInstruments): 'speed:%3.3f(%d)' = /linVel/ and gear (3 if speed>gear3_speed, 2 if >gear2_speed, else 1);… | verified |
| `0x49FB00` | `CarPhysics_SetControls` | input -> control bytes (see §3) | verified |
| `0x4A0D40` | `CarPhysics_ApplyAxleForce` | applies axle force, sets wheelSpinTimer | verified |
| `0x4A0F30` | `CarPhysics_ComputeDriveForce` | longitudinal drive force per axle, gears | verified |
| `0x4A1B20` | `CarPhysics_LimitSpeed` | top-speed cap (max_speed fwd / gear2_speed backward) | verified |
| `0x4A1DA0` | `show_physics` | debug overlay (g_doShowPhysics). Format strings name fields: CM=(+0x30,+0x34) CP=(+0x38,+0x3C,+0x6C); linvel=(+0x40,+0x44)… | verified |
| `0x4A4C40` | `Player_DriveCar` | Player input bytes -> Car_ApplyDriverControls | verified |
| `0x4A76D0` | `Player_HandleControls` |  | verified |

#### 4. Steering, assist, tyre forces, mass, NYC.GCI (45)

| address | name | role | confidence |
|---|---|---|---|
| `0x41D1F0` | `Gci_FormatError` | "%s at line %d" | verified |
| `0x41D230` | `Gci_PushData` | append bytes to output (err −12 on overflow) | verified |
| `0x41D280` | `Gci_HexStrToLong` | string→int | verified |
| `0x41D3F0` | `Gci_NextToken` | tokenizer, `{}` comments | verified |
| `0x41D580` | `Gci_StrToFix16` | decimal→Fix16, truncating | verified |
| `0x41D620` | `Gci_ParseToken` | type prefix b/w/l/f, h, '-' | verified |
| `0x41D800` | `Gci_ParseText` | binmake text→binary loop | verified |
| `0x41E460` | `Car_IsTruckCabWithTrailer` | `trailerController && trailerController->cab == car` | verified |
| `0x41F730` | `Car_GetAntiStrength` | engine.anti_strength | verified |
| `0x41F770` | `Car_GetValueTimes1000` | (engine.value[+trailer])×1000, no callers | verified |
| `0x421910` | `Car_ScaleByCarScale` | `car.scale != CarsScale ? v*car.scale : v` | verified |
| `0x421CF0` | `Car_GetMass` | engine.mass × car.scale (×(1+0.05) player w/ occupation) | verified |
| `0x421D90` | `Car_GetPhysicsSpeed` | ` | verified |
| `0x4220A0` | `Car_GetPhysicsModel` | model id used to index GCI/physics tables (remaps) | verified |
| `0x4234A0` | `Car_GetSteerAssistLimit` | speed × K (K=0.13, ×2 if CARI h ≤ 0x40) — **old name wrong**: returns speed-scaled value, not width | verified |
| `0x4327E0` | `CarModelTable_GetEngineData` |  | verified |
| `0x432800` | `CarModelTable_GetPhysicsData` |  | verified |
| `0x432850` | `StyleData_GetTotalCars` | `allCarsInfo->totalCars` (+0x400) | verified |
| `0x432880` | `CarPhysicsData_ComputeInertia` | inertia + CM offset from w,h,mass,front bias | verified |
| `0x432AA0` | `CarPhysicsData_Build` | derive CarPhysicsData from CARI + GCI (§2) | verified |
| `0x432C60` | `CarEngineData_ConvertMass` | `mass *= 1.1` | verified |
| `0x432CD0` | `CarModelTable_ValidateEngineData` | calls ConvertMass on every record | verified |
| `0x432D10` | `CarEngineData_LoadGci` | read NYC.GCI → CarEngineData[n] | verified |
| `0x432EA0` | `CarModelTable_BuildPhysicsData` | allocate CarPhysicsData[n], Build for each existing model | verified |
| `0x432F70` | `CarPhysicsData_ArrayDeletingDtor` | scalar-deleting dtor of the 0x2C array | verified |
| `0x432FC0` | `CarModelTable_Load` | path → LoadGci → Validate → BuildPhysicsData | verified |
| `0x49DD20` | `CarPhysics_SetSwerveState` | `swerveState(+0xA0)=*p` (0 none, 1 left, 2 right) | verified |
| `0x49DD30` | `CarPhysics_ApplySwerveInput` | with a driver: state1→steering −1, state2→+1, gas on | verified |
| `0x49E5A0` | `CarPhysics_ComputeRelativePointVelocity` | velocity of a world point attached to the body | verified |
| `0x49E650` | `CarPhysics_ComputePointVelocity` | velocity of a body-local point incl. rotation | verified |
| `0x49E710` | `CarPhysicsData_ComputeMaxThrust` | half + fifth*5*(turbo?1.5:1) | verified |
| `0x49EA00` | `CarPhysics_GetMinGasPedal` | 2.0 for player (car+0x7C==2) else 0 | verified |
| `0x49EC80` | `CarPhysics_SelectEngineData` | `g_CurCarEngineData` only | verified |
| `0x49ECA0` | `CarPhysics_SelectPhysicsData` | `g_CurCarPhysicsData` only | verified |
| `0x49EE50` | `CarPhysics_SnapVelocityToSpriteDirection` | linVel = polar( | verified |
| `0x49EF00` | `CarPhysics_ClearModelData` | both globals = NULL | verified |
| `0x49F2D0` | `CarPhysics_StartSwerve` | start swerve (not trains): random side, timer=30 | verified |
| `0x49F720` | `CarPhysics_GetTrailerAwareTurnRatio` | GCI turn_ratio, ×2.5 for a truck cab with trailer | verified |
| `0x4A0D10` | `CarPhysics_ComputeRelativePointVelocityForModel` | CarPhysics_SelectPhysicsData(this) then CarPhysics_ComputeRelativePointVelocity(out, point). Entry point for non-physics callers… | verified |
| `0x4A1130` | `CarPhysics_FrontAxleLateralForce` | front tyre force; returns | verified |
| `0x4A1360` | `CarPhysics_RearAxleLateralForce` | rear tyre force; returns | verified |
| `0x4A16B0` | `CarPhysics_UpdateSteerAngle` | front steer angle `+0x78` from GCI turn_ratio × steering input; player cars speed-scaled | verified |
| `0x4A17A0` | `CarPhysics_IsGasPedalPressedEnough` | throttle(+0x60) >= GetMinGasPedal | verified |
| `0x4A17C0` | `CarPhysics_ApplySteeringAssist` | road-arrow lane assist: temporarily adds to angVel | verified |
| `0x4B7500` | `PlayerScore_GetCarValue` | engine.value ×1/×2/×5 | verified |

#### 5. Collisions and impulse response (36)

| address | name | role | confidence |
|---|---|---|---|
| `0x426580` | `Car_ApplyExplosionKnockback` (was `unsure_Car_ApplyExplosionKnockback`) | ApplyImpact from explosion | hypothesis |
| `0x446740` | `Collision_GetRowStripList` | row (0..255) -> first strip node in visible range | verified |
| `0x446F30` | `Collision_CheckRowAndNotify` | row step: CollisionCheck + OnOverlapNotify | verified |
| `0x4470B0` | `Collision_FindObstacleInRow` | row scan for it | verified |
| `0x4471B0` | `CollisionManager_Ctor` | builds 5 grids: 0x8004, 0x11944, 3 x 0x400 (g_CollisionGridObstacles/Notify/Aux) | verified |
| `0x447480` | `Collision_CheckAndNotifyAllForSprite` | broad phase over rows DAT_00662bac..bfc | verified |
| `0x447740` | `Collision_FindObstacle` | returns first obstacle sprite overlapping arg, 16 callers | verified |
| `0x482CC0` | `CarPhysics_CollideWithObjectAtPoint` | sets contact pos, calls CollideWithObject | verified |
| `0x497570` | `PedGameObject_HandleCarImpact` (was `unsure_PedSprite_HandleCarImpact`) | ped reaction to being hit (Seq 27 domain) | hypothesis |
| `0x49E270` | `CarPhysics_CheckCarAndTrailerCollisions` | grid query for car and trailer sprites on g_CollisionGridNotify | verified |
| `0x49E330` | `CarPhysics_ApplyAngularImpulse` | torqueAccum(+0x7C) -= arg * g_CurCarPhysicsData->inertia (CarPhysicsData+0). Callers: the three unsure_CarPhysics_NudgeOutOf* (collision… | verified |
| `0x49E360` | `Vec2_DivInt` (was `unsure_Fix16Vec2_DivScalar`) | Vec2 / scalar | hypothesis |
| `0x49EF10` | `CollisionResult_SetMoverSprite` | record +0x24 = sprite (g_CollisionResult struct, +0x24 = g_CollisionResult.moverSprite). Caller CarPhysics_TestCollision. | verified |
| `0x49EF20` | `CollisionResult_IsHitPed` | kind(+0) == 3 (sprite hit) && Sprite_GetOwnerSpriteIfPed(hit sprite +0x20) != 0. Caller CarPhysics_StepAndResolveCollisions (ped hits… | verified |
| `0x49EFC0` | `Car_AddFlag2000` |  | verified |
| `0x49EFD0` | `Car_ClearFlag2000` |  | verified |
| `0x49EFE0` | `Car_CanCrushCars` | IsCollideOver(car) (CARI flag) && (IsTank // !Car_IsDrivenByNonPlayer). Caller CarPhysics_CollideWithCar: vehicles that drive over / flatten other… | hypothesis |
| `0x4A0020` | `CarPhysics_TestCollision` | map + sprite test for car and trailer sprite, records mover | verified |
| `0x4A0080` | `CarPhysics_DebugAssertCollisionKind` | dead debug assert (physics.cpp 0x7a0/0x7a9), 0 callers | verified |
| `0x4A05C0` | `CarPhysics_ComputeCollisionImpulse` | the impulse maths, 7 callers; mass -1 = immovable | verified |
| `0x4A0900` | `CarPhysics_ApplyAccelerationAsForce` | forceAccum(+0x48) += accel * g_CurCarEngineData->mass (+4): turns an acceleration into a force (Seq 48; not a table kick). Only caller 0x4A0960. | verified |
| `0x4A0960` | `CarPhysics_ApplyAccelerationWithTrailerRedirect` | wrapper of 0x4A0900 with trailer redirect (Car_IsOnTrailer => apply to linked CarPhysics). Callers: UpdateSurface, NudgeAndWake. | verified |
| `0x4A09B0` | `CarPhysics_NudgeAndWake` | post-contact kick + KeepActiveFor + release handbrake (not for trains) | verified |
| `0x4A0A30` | `CarPhysics_CollideWithSprite` | car-ped: impulse, sets ped fields, calls ped handler | verified |
| `0x4A3140` | `CarPhysics_ApplyImpulseWithTrailerRedirect` | redirect to linked trailer/cab physics | verified |
| `0x4A32D0` | `CarPhysics_ApplyWallImpulse` | wall response: impulse vs infinite mass, ApplyImpact(0xF), damage | verified |
| `0x4A34A0` | `CarPhysics_CollideWithCar` | car-car response, equal-and-opposite ApplyImpact (0x32 ticks), damage, train explode | verified |
| `0x4A3A40` | `CarPhysics_CollideWithObject` | car vs map object (lamp posts etc.), reaction on object | verified |
| `0x4A3DF0` | `CarPhysics_CollideWithWallX` | car vs map wall on X (reads `wallMinX` / `wallMaxX` 0x5E6878 / 0x5E687C, `contactX/Y`; snaps the contact to the nearer face end) | verified |
| `0x4A3FB0` | `CarPhysics_CollideWithWallY` | Y twin (same body, +0x3c, 0x5E6880..8C = `wallMinY` / `wallMaxY` / `contactX` / `contactY`, ContactPointY) | verified |
| `0x4A4170` | `CarPhysics_DispatchCollision` | switch on g_CollisionResult.kind 1/2/3 -> wall X / wall Y / sprite; then sound event | verified |
| `0x4A4270` | `CarPhysics_OnCollision` | replays pose at hit fraction, dispatches | verified |
| `0x4B9A30` | `Sprite_ShouldCollideWithSprite` | collision filter by entry type 1..5 | verified |
| `0x4BCAC0` | `Sprite_CollisionCheck` | narrow phase: z overlap + rect corners both ways | verified |
| `0x4BCB40` | `Sprite_UpdateBoundsIfDirty` | if sprite bounds (+0xc obj) not yet current (flag +0x48==0) recompute corners via SpriteBounds_RecomputeCorners. 17 callers, called before every… | verified |
| `0x4BD8A0` | `Sprite_ComputeCollisionContactPoint` | contact point of two sprites (1 corner or midpoint of 2) | verified |

#### 6. Damage, deformation, wreck, skids, surface (53)

| address | name | role | confidence |
|---|---|---|---|
| `0x414F60` | `Car_HasFlag100` | Car_HasFlags(Car+0x78, 0x100). In Car_OnDamage gates default (bullet) damage and 0x109 -> likely bullet-proof. Pair Car_HasFlag200… | verified |
| `0x41F940` | `Car_IsOnScreenForAnyPlayer` | gates skids | verified |
| `0x420950` | `Car_AttachRoofLightObject` | spawn object type + attach to car sprite | verified |
| `0x4209F0` | `Car_TickLastDamageTimer` | --lastAttackerTimer(+0x94); at 0 clear attacker ped (+0x70) and kill code (+0x90) | verified |
| `0x420DC0` | `CarDeltas_SetBit` | `*this \ | verified |
| `0x420DE0` | `CarDeltas_ClearBit` | `&= ~(1<<n)` | verified |
| `0x420E20` | `CarDeltas_IsBitSet` | test bit | verified |
| `0x421100` | `CarPhysics_IsSunkAndSlow` | surfaceType==8 and \ | verified |
| `0x421570` | `FixCarBrokenEngine` | engine states 2/TURN_OFF -> OFF | verified |
| `0x421590` | `Car_BreakEngine` | engineState(+0x9c)=5 unless 6 | verified |
| `0x4217F0` | `Car_IsTaxiModel` | model 0x38 TAXI or 0x33 STYPECAB | verified |
| `0x4226C0` | `Car_SpawnDamageFireEffect` | stage fire at 16000 (arg 1) and 25000 (arg 2) | verified |
| `0x422F00` | `Car_DamageArea` | set the delta damage bit(s) in Car+8 (areas 0..4) | verified |
| `0x423180` | `Car_TryDamageArea` | impact side 0..3 -> Car_DamageArea(3,2,0,1); no-op if wrecked/flag 8 | verified |
| `0x423230` | `Car_EmitExplosion` | spawn explosion particle-system object attached to the car | verified |
| `0x423830` | `Car_StartWreckTimer` | wreckTimer(+0xa9)=50, Car_BreakEngine | verified |
| `0x424700` | `Car_AttachEmergencyLights` | attaches siren/roof-light objects 0xa5,0xab-0xad (colour 0xff2010) for MEDICAR(0x22), COPCAR(0xc), SWATVAN(0x34), firetruck, FBI car.… | verified |
| `0x425760` | `Car_HasFlag200` | Car_HasFlags(0x200). See Car_HasFlag100 (gating in Car_OnDamage for types 10/0x80/0x8a). | verified |
| `0x425770` | `Car_HasFlag400` | Car_HasFlags(0x400). See Car_HasFlag100 (gating in Car_OnDamage for type 0xc2). | verified |
| `0x425CA0` | `Car_RecordRamAttackers` | car-vs-car blame: set lastAttackerPedId, kill code 1, timer 50 | verified |
| `0x425F20` | `Car_Repair` | damage=0, fire state=0, clear delta bits 0..4, lights back on, remove flames, fix engine | verified |
| `0x426FA0` | `Car_Explode` | explosion: wreck timer, explosion object, eject, knockback, damage = 32001, attachments explode | verified |
| `0x427180` | `Car_AddDamage` | anti_strength scale, accumulate into Car+0x74, clamp 32000, stage thresholds 16000/25000/31499/32000 | verified |
| `0x427290` | `Car_OnWrecked` | final death: eject occupants, break engine, free attachments, score/respect/wanted, request removal | verified |
| `0x427450` | `Car_CheckDeath` | drowned car -> Car_OnWrecked + splash | verified |
| `0x4274C0` | `Car_OnDamage` | hit by projectile/explosion/flame object: damage per object type | verified |
| `0x427B60` | `Car_BecomeWreck` | switch sprite to CarInfo[wreck+0x48], reset deltas/lights/horn | verified |
| `0x4292F0` | `Car_ApplyImpactDamage` | impulse (Q14) x 200 -> Car_AddDamage; skipped if Car flag 0x8; taxi + impulse > 2.0 -> passengers flee | verified |
| `0x429370` | `Car_TriggerExplosion` | anti_strength != 0 && !wrecked -> Car_Explode else Car_EmitExplosion only | verified |
| `0x4293D0` | `Car_OnTouchObject` | car touches object: 8/9 oil spin, shop, crane, crusher... | verified |
| `0x429660` | `Car_TickWreckTimer` | --wreckTimer; at 0 Car_BecomeWreck | verified |
| `0x436220` | `Ped_GetDamageMultiplier` | 2 with powerup 7 else 1 | verified |
| `0x445E90` | `Passengers_ForceTaxiPassengersToExit` | flag 0x20000000 on taxi passengers | verified |
| `0x44AB20` | `unsure_ObjectType_IsProbeBulletClone` | object types 0x9a,0x9f,0xc1,0xc3,199 | hypothesis |
| `0x44AB80` | `ObjectType_GetKillWeaponCode` | object type -> kill code 9..0x15 stored at Car+0x90 | verified |
| `0x466AF0` | `MapBlocks_GetSkidTileKind` | 7 water / 0 lid / 5 none | verified |
| `0x48DB00` | `Particle_EmitImpactParticles` | 6 random sparks at x,y,z | verified |
| `0x49E100` | `CarPhysics_GetSkidObjectType` | (surface type, length) -> object id | verified |
| `0x49EA30` | `Sprite_GetBoundingBoxCorner` | corner idx -> world xy | verified |
| `0x49EBE0` | `MapBlocks_GetCarSurfaceTypeAt` | tile -> CAR_SURFACE (7/9/5/slope) | verified |
| `0x49F460` | `CarPhysics_ApplyConveyorPush` | direction bytes of a touched object (WorldObject_GetConveyorOffsets) * DAT_0066AC10 added to g_CarExternalLinVel (x) and 0x66B008 (y), KeepActiveFor(15).… | verified |
| `0x49FF80` | `CarPhysics_EmitImpactParticles` | landing puffs at corners | verified |
| `0x4A0120` | `CarPhysics_SpawnSkidSegment` | anchor to new point -> skid object | verified |
| `0x4A0290` | `CarPhysics_UpdateSkidmarks` | skid emission rule (section 5) | verified |
| `0x4A26C0` | `CarPhysics_UpdateSurface` | ground contact, surfaceType/groundMaterial | verified |
| `0x4BD350` | `Sprite_CheckCornerZCollisions` | corner mask + count | verified |
| `0x4BD490` | `Sprite_IsAnyCornerOnSlopeNearZ` | any body corner on a slope block (MapBlocks_IsSlope1to44At) at z or z-1; caller CarPhysics_UpdateSurface | verified |
| `0x4BDD40` | `Sprite_GetCornersOverWaterMask` | corner mask over water | verified |
| `0x4BE920` | `CarAttachment_ExplodeOrKill` |  | verified |
| `0x4BE950` | `CarAttachment_WreckLinkedCar` |  | verified |
| `0x4BEA20` | `CarAttachments_ExplodeAll` | Car_Explode: for each attachment -> CarAttachment_ExplodeOrKill (0x4be920: turret/gun objects explode with code 0x13 via… | verified |
| `0x4BEA40` | `CarAttachments_WreckAll` | Car_OnWrecked: for each attachment -> CarAttachment_WreckLinkedCar (0x4be950) which calls Car_OnWrecked on the linked car if not being… | verified |
| `0x4BEB70` | `unsure_CarAttachments_SetFlameStateTo2` | attachments state=2 at stage 4 | hypothesis |

#### 7. Math helpers (Fix16 Q14, Ang16, Vec2) (57)

| address | name | role | confidence |
|---|---|---|---|
| `0x401AD0` | `Fix16_FromRaw` (was `WriteToFirstArg`) | raw store `*this = v` (used to build raw Q14 constants, RET 8) | verified |
| `0x401AE0` | `Fix16_FromInt16` | `*this = (int16)v << 14` | verified |
| `0x401AF0` | `Fix16_FromInt` (was `bitShiftLeft14`) | `*this = v << 14` (kept, comment added) | verified |
| `0x401B20` | `Fix16_Add` | out = a + b | verified |
| `0x401B40` | `Fix16_Sub` | out = a - b | verified |
| `0x401B60` | `Fix16_Mul` | out = (int64 a*b) >> 14 (floor) | verified |
| `0x401B90` | `Fix16_Div` | out = (int64 a << 14) / b, no zero check | verified |
| `0x401BF0` | `Fix16_DivInt` | out = a / b raw integer division (Fix16 / small int) | verified |
| `0x401C10` | `Ang16_Wrap` | wrap into 0..1439 (while <0 add 1440; while >1439 sub 1440) | verified |
| `0x401C60` | `Ang16_Assign` | assign + wrap | verified |
| `0x401C80` | `Ang16_Neg` | out = wrap(-a) | verified |
| `0x401D20` | `Vec2_Set` | this = (x, y) | verified |
| `0x403780` | `Fix16_Neg` | out = -a | verified |
| `0x4037E0` | `Fix16_IsLess` | returns *this < *p (signed). | verified |
| `0x403800` | `Fix16_IsGreater` | returns *this > *p (signed). Operand order: (this, p) => this > p. | verified |
| `0x403820` | `Fix16_IsNotEqual` | returns *this != *p. | verified |
| `0x403840` | `Fix16_Abs` | out = abs(a) | verified |
| `0x40CE50` | `Fix16_IsLessEqual` | returns *this <= *p. | verified |
| `0x40CE70` | `Fix16_IsGreaterEqual` | returns *this >= *p. | verified |
| `0x40E530` | `Fix16_AddAssign` | this += p | verified |
| `0x40E550` | `Fix16_SubAssign` | `*this -= *arg`. Old name misleading (it is a plain subtract-assign) | verified |
| `0x40E570` | `Fix16_IsEqual` | `*this == *p`. Old name misleading | verified |
| `0x40E590` | `Ang16_SetZero` | angle = 0 | verified |
| `0x40E5A0` | `Ang16_Add` | out = wrap(a+b) | verified |
| `0x40E5D0` | `Ang16_Sub` | out = wrap(a-b) | verified |
| `0x40E670` | `Ang16_IsGreater` | returns *this > *p for Ang16 (int16, no wrap). | verified |
| `0x40F500` | `Ang16_Sin` | *out = sin-table[(int16)angle] as Fix16 (Q14), table at DAT_005D3938 (4 bytes/entry, index = Ang16 0..1439). | verified |
| `0x40F520` | `Ang16_Cos` | *out = cos-table[(int16)angle] as Fix16 (Q14), table at DAT_005D6718. | verified |
| `0x40F540` | `Fix16_ToAng16` | Fix16 / 71 -> Ang16 | verified |
| `0x40F580` | `Ang16_ToFix16` | Ang16 * 71 -> Fix16 | verified |
| `0x40F5C0` | `Vec2_Add` | Vec2 add, thiscall: *out = *this + *b. | verified |
| `0x40F600` | `Vec2_Sub` | Vec2 sub, thiscall: *out = *this - *b (component-wise) via Fix16_Sub + Vec2_Set. | verified |
| `0x40F680` | `Vec2_AddAssign` | Vec2 += (Fix16_AddAssign x,y). gta2_re 10.5 Fix16_Point::operator+=. | verified |
| `0x40F6B0` | `Vec2_RotateByAng16` | in place: x' = x cos + y sin ; y' = y cos - x sin | verified |
| `0x40F760` | `Vec2_NegAssign` | in place negate | verified |
| `0x40F790` | `Fix16Vec2_GetAngle` | atan2 | verified |
| `0x41E0D0` | `Fix16_MulAssign` | `*this = *this * *a >> 14` | verified |
| `0x41E0F0` | `Ang16_IsLess` | returns *this < *p for Ang16 (int16). | verified |
| `0x41E130` | `Fix16_Max` | out = max(a,b) | verified |
| `0x41E1A0` | `Vec2_MulFix16` | out = v * s (thiscall this=v; decompiler hides ECX) | verified |
| `0x41E1E0` | `Vec2_SetZero` | this = (0,0) | verified |
| `0x41E260` | `Fix16Vec2_GetLength` | vector length | verified |
| `0x4202E0` | `Vec2_DivFix16` | out = v / s | verified |
| `0x420360` | `Fix16Vec2_IsZero` | both comps == 0 | verified |
| `0x420390` | `Vec2_Normalize` |  | verified |
| `0x482730` | `Fix16_ApplyDeadZone` | \ | verified |
| `0x4828C0` | `Vec2_SubAssign` | Vec2 -= (Fix16_SubAssign on x and y). | verified |
| `0x48A1A0` | `Fix16_DivAssign` | this = (this<<14)/p | verified |
| `0x49E0E0` | `Fix16_Square` | out = Fix16_Mul(x, x) (decompiler hides the ECX operand; both operands are the same stack arg). Used by… | verified |
| `0x49E240` | `Ang16_FormatDegrees` | swprintf("%3.2f", ang16 * 0.25) into a static buffer: Ang16 -> degrees text for show_physics. Confirms 1 Ang16 unit = 0.25 degree. | verified |
| `0x49E2C0` | `Fix16_Max3` (was `Fix16_Median3`) | median of three, used by ComputeRequiredSweepSteps | verified |
| `0x49E3A0` | `Vec2_MulAssignFix16` (was `Fix16Vec2_MulAssign`) | vec2 *= scalar (calls Fix16_MulAssign on x,y) | verified |
| `0x49E3C0` | `Vec2_ApplyDeadZone` | \ | verified |
| `0x49E420` | `Vec2_Perpendicular` | out = (-v.y, v.x) (rotate +90). Used by CarPhysics_ComputeCollisionImpulse for the 2D cross product. | verified |
| `0x49E450` | `Vec2_HasZeroComponent` | `x==0 \ | verified |
| `0x49E480` | `Fix16Vec2_ClampTowardsZero` | per-axis min( | verified |
| `0x49E500` | `Vec2_Dot` | out = a.x*b.x + a.y*b.y (Fix16_Mul twice + Fix16_Add). Used by CarPhysics_ComputeCollisionImpulse. | verified |

## 8. Static-initialiser constants

`re/tools/static_constants.py gta2.ebin > re/static_constants.csv` disassembles `.text` with
`xcrun llvm-objdump` and evaluates every CRT initialiser thunk built only from
`push imm; mov ecx,&G; call Fix16_FromRaw/Fix16_FromInt`, `G = [S]` copies and
`Fix16_Add/Sub/Mul/Div` of two globals: 13 625 globals, values for 13 539. Thunks with any other
instruction are skipped (e.g. the 0.985 air damping, the 0.13 assist factor and the 1/256
angular dead zone at 0x6658DC, which was read from its initialiser by hand), and a global that
is rewritten at run time is not detected — check for writers before calling one a constant.

## 9. Open questions

* Who sets `Game+0x30` (11 ms ticks)?
* Ang16 convention: `Fix16Vec2_GetAngle` is atan2(y, x) while wheel points (0, off) rotate as if
  heading 0 were +Y; this decides which compass directions the assist's 90°/270° are. Needs a runtime sample.
* Object types behind damage/oil codes (8/9, 10, 0x80, 0x8A, 0xC2, 0x109).
* `CarPhysics+0xAB`, `0xAA` semantics; `MapBlocks_IsPointOnGroundSurface`, `Car_IsDrivenByNonPlayer` (model substitution condition).
* Velocity clamp after an impulse: none found as a separate step (gta2_re's
  `ProcessCollisionAndClampVelocity` corresponds to `MoveAndCollide`, which only zeroes the velocity
  when the car could not move at all).
* Grip on grass/ice: no surface term found in the tyre model.

### Names added by Seq 47 (slice 5, 0x4B9C20–0x4BE570: sprite bounds, draw, FixRect helpers)

Mostly the `Sprite` (0x3C body) module (bounds object, corner math, draw). "high" = verified in the decompiler plus callers; "unsure_" = best guess.

| Address | Name | Notes |
|---|---|---|
| `0x4B9C20` | `Fix16_Sign` | sret Fix16 = ±1/0 |
| `0x4B9C70` | `Fix16_RoundToWhole` | `(raw+0x80)&~0xFF` |
| `0x4B9E10` | `Fix16_IsInRangeInclusive` | lo, hi, val |
| `0x4B9E60` | `Fix16_MinMaxOf4` | out min/max of 4 |
| `0x4BA330` / `0x4BA340` | `CarDeltas_AndLightMask` / `CarDeltas_ClearLightMask` | `deltasBitstate` &= / &= ~ `DAT_005E85BC` (Sprite_Draw, lighting on) |
| `0x4BA350` / `0x4BA360` / `0x4BA370` | `CarDeltas_SelectLightMaskDefault` / `…RoofDecal` / `…FBI` | `DAT_005E85BC` = `DAT_00591E90` / `98` / `94`; meaning of the mask is a hypothesis |
| `0x4BA390` | `Car_IsTrailerAttachedToCab` | `car+0x64`→`+8 == arg` |
| `0x4BA3C0` | `Camera_ProjectPointToScreen` | Fix16 world xyz → screen xy |
| `0x4BA4D0` | `QuadVertex_ProjectWorldPoint` | regs EAX/ESI; sets xyz, rhw, sx, sy |
| `0x4BA620` | `Box3_UnionWith` | 0 callers; last max uses the wrong field (original bug) |
| `0x4BA6C0` | `FixRect_ContainsAnySpriteCorner` | |
| `0x4BA7E0` | `FixRect_ExpandToIncludePoint` | |
| `0x4BAA20` | `FixRect_SetFromPoints4` | 0 callers |
| `0x4BAA70` | `Sprite_GetPed` | |
| `0x4BAA90` | `Sprite_IsOverWaterTile` | |
| `0x4BAB10` | `Sprite_AddSpriteShrinkClamped` | byte `+0x38` |
| `0x4BABB0` | `Sprite_IsObjectOfModel` | |
| `0x4BABE0` | `Sprite_GetPaletteIndex` | |
| `0x4BAC10` | `Sprite_ShouldDrawShadow` | |
| `0x4BAC60` | `Sprite_GetDrawQuadFlags` | |
| `0x4BACF0` | `Sprite_DrawDebugIds` | `g_doShowIds` / `g_doShowObjectIds` |
| `0x4BB020` | `Sprite_ContainsAnyWorldRectPoint` | |
| `0x4BB4D0` | `Sprite_FindCornersInsideRect` | ParkingZone_Update |
| `0x4BB860` / `0x4BB910` | `Sprite_FindEdgeCrossingWallAlongX` / `…AlongY` | |
| `0x4BB9C0` | `Sprite_IsSegmentTouchingBox` | |
| `0x4BBBE0` | `Sprite_IsTouchingGroundSurfaceOverBodyZ` | |
| `0x4BBC80` | `Sprite_GetMinChebyshevDistToSprite` | |
| `0x4BBD10` / `0x4BBD30` | `Sprite_ReleaseSoundClient` / `thunk_…` | `Sprite+0x10` back to pool `DAT_005D85A0` |
| `0x4BBD40` | `SpriteBounds_RecomputeCorners` | 4 corners + AABB, sets `+0x48` |
| `0x4BC580` | `Sprite_LoadBlockBoundsToGlobals` | |
| `0x4BC590` | `SpriteBounds_DrawDebugBox` | `g_doShowCollisionBox` |
| `0x4BC8F0` | `SpriteBounds_Reset` | |
| `0x4BC950` / `0x4BDCB0` | `SpriteBoundsPool_Dtor` / `…ScalarDeletingDtor` | 0x13A7 × 0x4C pool (SpriteBoundsPool) |
| `0x4BC970` / `0x4BDC90` | `SpritePool_Dtor` / `…ScalarDeletingDtor` | 0x13A7 × 0x3C |
| `0x4BC9F0` / `0x4BCA10` | `SpriteBoundsPool_Alloc` / `…Free` | free list through `+0x2C` |
| `0x4BCA70` | `SpriteNode_Init` | |
| `0x4BCA80` | `Sprite_IsControlledByRemotePlayer` | network: has Player and not `Player_IsLocal` |
| `0x4BCB90` | `Sprite_SetBoundsSize` | 18 callers |
| `0x4BCBD0` | `Sprite_EnsureSpriteBounds` | |
| `0x4BCCA0` / `0x4BCCC0` | `Sprite_FreeBoundsC` / `Sprite_FreeBoundsObjects` | |
| `0x4BD250` / `0x4BD290` | `Sprite_IsBoxOverGroundEdge` / `Sprite_ClassifySlopeOverlap` | |
| `0x4BD2E0` | `Sprite_GetCachedZLayer` | byte `+0x39`, used by LayerDrawQueues_Enqueue |
| `0x4BD610` | `Sprite_TestWallBlockedAndRecordZ` | Taser |
| `0x4BDAD0` | `Sprite_ClearObstaclesForSpawn` | Script_Decl_PLAYER_PED / CAR_DATA_SET / CHAR_DATA_SET |
| `0x4BDC40` | `Sprite_DtorBody` | |
| `0x4BDDD0` | `Sprite_ShrinkFrameBoundsAndScaleBody` | |
| `0x4BDF20` | `Sprite_CollisionCheckAgainstShortenedOther` | |
| `0x4BE050` | `Sprite_GetBoundsBox` | 0 callers |
| `0x4BE060` | `Sprite_Draw` | only caller LayerDrawQueue_DrawInOrder |
| `0x4BE570` | `Sprite_SyncZLayerPairToMax` | |
