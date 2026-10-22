# Ped movement and collision in gta2.exe 11.44

How vanilla GTA2 turns player input into on-foot motion, and how a walking ped collides with
the map, cars, other peds and objects. Written for one practical question: **how can the host
move the player ped sideways (strafe) without walking through walls?** The answer is in §6.

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`); every name is in the Ghidra
DB (`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and therefore in `re/`.
"verified" = the body was read in the decompiler and, for calling conventions and the hook site,
in the disassembly (`ret N`, registers); "hypothesis" = the name carries `unsure_`.
Sources: Seq 37 analysis (five slices: input → motion, ped vs map, ped vs sprites, move API,
heading/mouse), the prior mods listed in §8, and the car pipeline in
[car-physics.md](car-physics.md) (shared collision services).

## 1. Units and the main objects

| quantity | representation |
|---|---|
| position, speed, push | Fix16 = `SCR_f`, Q14 (`0x4000` = 1 map block; 1 "pixel" = 1/64 block = `0x100`) |
| heading | Ang16, int16 `0..1439`, **4 units = 1°**, 0 = facing +y; `x = sin(h)·len`, `y = cos(h)·len` (`Ang16_PolarToXY` 0x41FC20, sin table 0x5D3938, cos table 0x5D6718) |
| tick | 33 ms, everything below runs once per `GameTick` 0x45C1F0 ([car-physics.md](car-physics.md) §2) |

The imported struct names from three old projects overlap. What they really are:

| real thing | names in `re/gta2_types.h` | where it hangs |
|---|---|---|
| **ped body object**, 0xB4, pool of 400 (`PedGameObjectManager` 0x66A3B4) | `PedGameObject` (was `GameObject`; the phantom duplicates (old `Sprite` 0x100, `PedS1` 0x90) were deleted 2026-10-22) | `Ped+0x168` |
| **physics body** (pose + collision box), 0x3C | `Sprite` (was `Position`; `Pos` and `S21_1` merged into it), `PedSprite` / `CarSprite` (truncated views) | `PedGameObject+0x80` (`body`), `Car+0x50`, `CarAI+0x70`, `CarAttachment+0`, `Collide+0`, `S21+0`, `S24_char+8` |
| bounds object (size, corners, AABB) | none (untyped) | `Sprite+0xC` (typed `next_`, wrong) |

`ObjectMotionState` belongs to dynamic map objects, not to peds.

### PedGameObject fields used by the walker (verified)

| off | type | meaning |
|---|---|---|
| +0x08 / +0x0C | PED_STATE / PED_STATE2 | copied from the Ped every tick by `Ped_TickGameObjectAndSeatInCar` |
| +0x10 | int | walk sub-mode (0 idle, 1 moving, 7 stop, 0xF lying/jumping, 0x1B nudged by obstacle, …; meanings partly hypothesis) |
| +0x38 | SCR_f | **speed** along the heading |
| +0x3C | SCR_f | `walkSpeedTarget` = **0.0625 block/tick** (1.9 blocks/s) for every ped; no run speed in this path |
| +0x40 | Ang16 | **heading** — the one the player turns, the one the sprite is drawn with |
| +0x4C / +0x50 | SCR_f | `pushX` / `pushY`, world-axis displacement added to one move, then zeroed |
| +0x58 | bits | bit 0 on a slope block, **bit 3 walking backwards**, bit 5 teleport pending, bit 7 no ped collision |
| +0x69 / +0x6A / +0x74 | byte / byte / Ang16 | walking around an obstacle / step-aside timer / step-aside heading |
| +0x7C / +0x80 | Ped* / Sprite* | owner and body |
| +0x98 / +0x9C | SCR_f | velocity **output** (published after the move; writing it does nothing) |
| +0xA4..+0xAC | SCR_f ×3 | teleport target (`TeleportGameObject` 0x491E00, no collision) |

Full layout of the rest of `PedGameObject` (2026-10-22 pass; V = behaviour + caller checked, H = hypothesis):
`+0x14` Ang16 targetHeading (V), `+0x16` downedFlag (V), `+0x18`/`+0x1C` obstacle / lastObstacle
(Car* or WorldObject*, V), `+0x20` obstacleKind 1 car / 3 object (V), `+0x24` int walkAroundPhase 0..3 (V),
`+0x28`/`+0x2A` walk-around heading / turn step (V), `+0x44` groundType (V, `PedGameObject_GetGroundType`),
`+0x45` slopeType (V), `+0x46` stateTimer (V), `+0x48` getUpTimer (V), `+0x54` jumpTick (V),
`+0x55` detourTimer (V), `+0x5C` objectBumpCooldown (H), `+0x60` detourAxis (H), `+0x68` animFrame,
`+0x6C` anim, `+0x70`/`+0x71` animTick / animTicksPerFrame (V), `+0x72`/`+0x73` detour tile (V),
`+0x84` Car* (V), `+0x88` CarAttachment* list (V), `+0x8C` jumpStartZ, `+0x90` fallSpeed,
`+0x94` fallZVelocity (V), `+0xA0` onTopOfCarLayer (H). Written only by init/deinit, no reader
found: `+4/+5/+6`, `+0x2C`, `+0x30`, `+0x34`, `+0x42`, `+0x64`, `+0xB0` (named `unk_*`).

`Ped.rotation` (+0x12C) and the pose copy inside the Ped are **mirrors** of the PedGameObject and the
body, rewritten every tick by `Ped_TickGameObjectAndSeatInCar`. Writing them moves nothing.

### Player input fields (verified)

| off | meaning |
|---|---|
| Player+0x04 | key mask (fwd 1, back 2, left 4, right 8, attack 0x10, enter 0x20, jump 0x40, …), written by `SetKeyState` 0x4A4930 |
| Player+0x08 | **`turnRate`**, Ang16 per tick, added to PedGameObject+0x40 every tick |
| Player+0x0C | **`moveSpeed`**: a direction flag, +1.0 forward / −1.0 back / 0 (not a speed) |
| Player+0x78..+0x83 | key booleans (fwd, back, left, right, attack, enter, jump, …) unpacked by `Player_MapKeys` |

## 2. One tick of the on-foot player

```
processPlayerKeys 0x45A650 → Player_ProcessInput 0x4A7680 → Player_MapKeys 0x4A4AE0   (key mask → bools)
GameTick 0x45C1F0
 ├ Player_Update 0x4A7E80
 │   └ Player_HandleControls 0x4A76D0   thiscall(Player*, Ped*) ret 4
 │       └ Player_MoveOnFoot 0x4A5C50   thiscall(Player*, Ped*) ret 4
 │            writes only Player.turnRate and Player.moveSpeed (+ jump, special key)
 └ … PedManager_UpdateActivePeds → Ped_Update 0x4454E0
       ├ Ped_UpdateState 0x43ECC0       player: STAYING↔WALK from moveSpeed / turnRate
       └ Ped_TickGameObjectAndSeatInCar 0x43F180   fastcall(Ped*)
           ├ PedGameObject.state1/state2 := Ped.state/state2
           ├ PedGameObject_Tick 0x49C460   thiscall(PedGameObject*, arg) ret 4
           │   ├ last good pose → playerPedX_ / DAT_0066A74C / DAT_0066A754
           │   ├ CollisionGrid_RemoveSprite 0x447C40 (g_CollisionGridObstacles, body)
           │   ├ switch state1: 0 → PedGameObject_StateWalk 0x49A560 (THE mover)
           │   │                7 → PedGameObject_StateStaying 0x49BD10 (turns; runs StateWalk if push ≠ 0)
           │   │                8 fall, 9 PedGameObject_StateWasted, 1/2/3/5 car enter/exit …
           │   ├ PedGameObject_UpdateAnimFrame 0x497DF0 (animation + z placement only)
           │   ├ SetRotation(body, PedGameObject+0x40)
           │   ├ velocity output → +0x98/+0x9C
           │   └ CollisionGrid_InsertSprite 0x447C00 (body at its new pose)
           └ body pose / heading → copies in Ped
```

### Turning (verified)

`Player_MoveOnFoot`: left key `turnRate += turnStep` (20 = 5°) up to +48 (12°/tick), right key the
same downwards, no key → 0; max 24 while the sub-mode is 0xF; attack held without forward → step 3°.
The walker adds `turnRate` to the heading: `Ang16_AddAssign(PedGameObject+0x40, turnRate)` at
0x49A98F–0x49A99B (and in `StateStaying`). The player has a single heading; "desired" headings
(`Ped+0x130`, `+0x12E`) exist only for AI and auto-aim.

### Speed and backward walking (verified)

The player branch of `StateWalk` (0x49A969 onwards) reads `Player.moveSpeed`:
- **> 0**: speed jumps to `walkSpeedTarget` (0.0625) or ramps by 1/256 (`Sprite_RampSpeedToward` 0x433970).
- **< 0**: the same speed, and the heading is **temporarily rotated by 180°** (0x49AA8E: save the
  heading, `bit1 |= 8`, `heading += DAT_0066A5F4` = 720, local flag `[esp+0x11] := 0`). The sprite
  keeps facing forward because the heading is restored at the end (0x49B0A5).
- **== 0**: speed 0, sub-mode 7 → STAYING (0x49AB11).

### Displacement and commit (verified)

```
probe   = pos + Ang16_PolarToXY(heading, 6/64 block) + push          0x49ACB5–0x49ACEB
if PedGameObject_IsInTileCenter 0x497410 (sub-tile 20..44 px both axes): no tile test
else player: PedGameObject_CanMovePlayer 0x495BF0(go, probeTileX, probeTileY)
     npc:    PedGameObject_CanMoveNpc    0x495540(go, probeTileX, probeTileY)
free    → pos += Ang16_PolarToXY(heading, speed) + push; SetPosition   0x49AE96–0x49AEFA
blocked → player: PedGameObject_SlideAlongWallPlayer 0x4995A0 (re-test at octant
          headings, half step); npc: PedGameObject_TurnAwayFromWallNpc 0x4994D0
push := 0                                                              0x49AF09
z follow FUN_00494180; Ped_ResolveSpriteObstacle 0x499F00 (cars/peds/objects, §4)
0x49B0A5: if the heading was changed for this move, restore it
```

## 3. Ped vs the map

Ped steps are a **tile-edge model**, not the car's swept rectangle. `CanMovePlayer` tests each
block edge the ped box (half size 0.1 block around the probe, 8 px front radius `DAT_0066A640`)
would cross:

- `PedGameObject_CanCrossTileEdgePlayer` 0x495980 `thiscall(go, dir)` ret 4, dir 1 N (y−1), 2 S,
  3 E, 4 W → `MapBlocks_IsBlockEdgeCrossingBlocked` 0x4656D0 (wall bit of this face and of the
  neighbour's opposite face, slopes one level up/down) + ground type of the neighbour block, and
  under `DAT_0066A3C7` a tentative `SetPosition` + `Sprite_TestMapCollisionAndRecord`
  0x4BD670, restored afterwards. A blocked direction goes to `DAT_00593228` (1..4) for the slide.
- `PedGameObject_CanCrossTileEdge` 0x495220 is the npc version without the body test.

Block faces (gmp `block_info`, 12 bytes: left, right, top, bottom, lid words, arrows, slope_type):
**bit 0x400 = wall** for peds and cars, 0x800 = bullet wall. Bits 12–15 (flat, flip, rotation) are
never read by collision: fences and transparent walls block exactly when 0x400 is set.
`slope_type & 3` is the ground type (0 air → the ped falls, 1 road, 2 pavement, 3 field),
`>> 2` the slope index into `g_SlopeTable` 0x662DB0 (64 × 12 bytes `{dir, len, step, pad, z0, z1}`,
filled by `MapBlocks_InitSlopeTable` 0x52B3B0): 1–44 gradients, 45–52 diagonals and roofs
(faces ignored for 49–52), 53–61 partial blocks (not walls).

Ped body: w = h = 0.2 block, zsize 0.25 (`Ped_CreateSprite` 0x4360C0). Because w == h ≤ 0.2, the
bounds code ignores the rotation: the ped is an **axis-aligned box**.

Z: `FUN_00494180` snaps z to the level or to the slope surface (`MapBlocks_GetSlopeSurfaceZ`
0x466B70). Ground height queries: `MapBlocks_GetGroundZBelow` 0x469570 (level aware), `FindMaxZ`
0x46A420 (topmost). Walking onto air → `FALL_ON_GROUND`.

### Map collision services (shared with cars and objects)

| address | name | prototype | what | |
|---|---|---|---|---|
| 0x4BD670 | `Sprite_TestMapCollisionAndRecord` | `bool __fastcall(Sprite*)` | body rectangle vs walls at its current pose, writes `g_CollisionResult` | verified |
| 0x46B440 | `MapBlocks_IsBodyBlockedByWalls` | `bool __thiscall(MapBlocks*, xBlk, yBlk, zBlk, Sprite* mover, u16 mask)` ret 0x14 | the wall test; needs the block-bounds globals 0x662BD4/BF8/BAC/BFC (`CollisionBox_LoadBlockBoundsToGlobals` 0x4BA5E0) | verified |
| 0x46A570 | `MapBlocks_ScanBoxFacesForWalls` | thiscall, 7 stack ints | face scan of the box strips | verified structure |
| 0x4656D0 | `MapBlocks_IsBlockEdgeCrossingBlocked` | `thiscall(MapBlocks*, x, y, z, dir, byte* out, char flag)` ret 0x18 | ped edge crossing; nonzero = blocked; writes only `MapBlocks+0x36E` | verified |
| 0x4BA720 | `CollisionBox_HitsMapSolid` | `bool __fastcall(SCR_f box[6])` | map-only test for an arbitrary box, no sprite (faces only, no sub-block refinement) | verified |
| 0x469F90 | `MapBlocks_SweepBodyIsClear` | stdcall, 9 args, ret 0x24 | steps a temporary body from A to B; **call-site argument order unresolved, do not call** | verified |

`g_CollisionResult` 0x5E6874 record (setters 0x4BA250 / 0x4BA280, verified): kind 1 stores a segment
in +4/+8 and its line in +0x18; kind 2 a segment in +0xC/+0x10 and its line in +0x14; kind 3 = a
sprite hit (+0x20 hit sprite, +0x24 mover). Per slice 2's reading of the callers, kind 1 is a wall
along constant y and kind 2 a wall along constant x — [car-physics.md](car-physics.md) labels them
"wall X / wall Y". The ped walker does not read the record, only the booleans.

## 4. Ped vs cars, peds and objects

The collision grid (`CollisionManager_Ctor` 0x4471B0; grids Obstacles/Notify/Aux 0x5E668C/90/94;
256 rows → strips of cells → entry lists) holds cars (kind 2), peds (3) and objects (1/4/5),
bucketed by map block. Pools: 4096 entry nodes (`DAT_005E6684`, pop 0x447350 **without an empty
check** — the community crash at 0x447352), 6000 cell headers (`DAT_005E6688`). Facts from Seq 27,
cross-checked against the constructor sizes.

**Nothing re-buckets a body automatically**: `SetPosition` 0x420600 only stores the pose and marks
the bounds dirty (`Sprite_MarkBoundsDirty` 0x4B99F0). The ped tick removes the body before its
step and inserts it after. A host move outside the tick must do the same, one-to-one: an insert
without a remove leaks nodes until the pool empties.

After the map step, `Ped_ResolveSpriteObstacle` 0x499F00 `thiscall(go, char flag)` →
`Sprite_FindObstacleAndRecord` 0x4BDFE0 → `Collision_FindObstacle` 0x447740
**`thiscall(grid, Sprite* body, int preferredKind)` ret 8** (preferredKind is a kind value, not
a mask) → `Sprite_ShouldCollideWithSprite` 0x4B9A30 (filter) → `Sprite_CollisionCheck` 0x4BCAC0
(z overlap + rectangle corners). Responses (verified flow, names hypothesis):

| obstacle | response |
|---|---|
| car | body back to the last good pose, then "walk around" along a tangent of the car (`+0x69`, `FUN_0049A080`); never knocked down by walking into a car (knock-down is the car's side: `unsure_PedSprite_HandleCarImpact` 0x497570) |
| light object | pushed (`FUN_004867E0`); heavy object → as a car |
| another player | blocked |
| civilian / special / driver, mission ped | the player **walks through**; the other ped steps aside (`+0x6A = 4`, `+0x74`); `STAND_STILL_BLOKE` blocks |

Filter: peds entering/leaving/driving a car, falling, wasted (states 6, 7, 9, 10, 0x11, 0x13,
0x18–0x1B) do not collide; a ped lying on the ground only against kind 4.

Side-effect-free "what blocks a body at pose P": remove the body from the grid, `SetPosition` to P,
`Collision_FindObstacle(g_CollisionGridObstacles, body, kind)`, restore the pose, insert. It writes
only query stamps and bounds-cell globals. Avoid `Collision_CheckAndNotifyAllForSprite` 0x447480
and `Sprite_OnOverlapNotifyImpactEvent` 0x4BAB70 (sounds, object notifications).

### Line of sight

**There is no raycast.** `Ped_FindThreatLineOfSight` 0x43BED0 is a 12-byte stub (`mode = 5; jmp
0x437BE0`) into the shared threat search, a spiral walk over collision-grid cells around the ped
(`FUN_00447540`) with a distance test and a camera visibility check. Bullets are projectile
objects (`FireFromGun` 0x4D0530) moving and colliding per tick, no hitscan.

## 5. Function table

| address | name | prototype | | |
|---|---|---|---|---|
| 0x4A76D0 | `Player_HandleControls` | `void __thiscall(Player*, Ped*)` ret 4 | enter/exit, attack, DriveCar / MoveOnFoot | verified |
| 0x4A5C50 | `Player_MoveOnFoot` | `void __thiscall(Player*, Ped*)` ret 4 | keys → turnRate, moveSpeed | verified |
| 0x43E1E0 | `Ped_CancelEnterCarOnPlayerMove` (was `Ped_MovePlayer`) | `void __fastcall(Ped*)` | cancels a pending ENTER_CAR when a move key is pressed; moves nothing | verified |
| 0x43ECC0 | `Ped_UpdateState` | `uint __fastcall(Ped*)` | player: WALK↔STAYING from moveSpeed / turnRate | verified |
| 0x436140 / 0x4348E0 | `Ped_GetPlayerTurnRate` / `Player_GetTurnRate` | thiscall, out pointer | Player+8 | verified |
| 0x436200 / 0x4348F0 | `Ped_GetPlayerMoveSpeed` / `Player_GetMoveSpeed` | thiscall, out pointer | Player+0xC | verified |
| 0x43F180 | `Ped_TickGameObjectAndSeatInCar` | `void __fastcall(Ped*)` | state → body object, tick, copy pose back | verified |
| 0x49C460 | `PedGameObject_Tick` | `void __thiscall(PedGameObject*, arg)` ret 4 | grid remove, state dispatch, rotation, grid insert | verified |
| 0x49A560 | `PedGameObject_StateWalk` | `void __fastcall(PedGameObject*)` | **the walker**: turn, speed, probe, tile test, commit/slide, sprite obstacles | verified |
| 0x49BD10 | `PedGameObject_StateStaying` | `void __fastcall(PedGameObject*)` | turn on the spot; runs StateWalk when push ≠ 0 | verified |
| 0x49C120 | `PedGameObject_StateWasted` | `void __fastcall(PedGameObject*)` | state 9 | verified |
| 0x495BF0 | `PedGameObject_CanMovePlayer` | `bool __thiscall(PedGameObject*, char tileX, char tileY)` ret 8 | player tile-edge test (1 = free) | verified |
| 0x495540 | `PedGameObject_CanMoveNpc` | same | npc version | verified |
| 0x495980 | `PedGameObject_CanCrossTileEdgePlayer` | `bool __thiscall(PedGameObject*, int dir)` ret 4 | edge + neighbour + tentative body test | verified |
| 0x495220 | `PedGameObject_CanCrossTileEdge` | same | edge + neighbour | verified |
| 0x497410 | `PedGameObject_IsInTileCenter` | `bool(void)`, reads the pose globals | sub-tile 20..44 px → skip tests | verified |
| 0x4995A0 | `PedGameObject_SlideAlongWallPlayer` | `void __fastcall(PedGameObject*)` | octant re-tests, half step | verified |
| 0x4994D0 | `PedGameObject_TurnAwayFromWallNpc` | `void __fastcall(PedGameObject*)` | | verified |
| 0x499F00 | `Ped_ResolveSpriteObstacle` | `void __thiscall(PedGameObject*, char)` | sprite obstacles + response | verified |
| 0x494280 / 0x4948C0 / 0x4993B0 | `Ped_ReactToPedObstacle` / `…ToCarOrObjectObstacle` / `…ToObjectObstacle` | thiscall | responses (§4) | verified flow |
| 0x447740 | `Collision_FindObstacle` | `int __thiscall(grid, Sprite*, int kind)` ret 8 | first obstacle overlapping the body | verified |
| 0x447C00 / 0x447C40 | `CollisionGrid_InsertSprite` / `CollisionGrid_RemoveSprite` | `thiscall(grid, Sprite*)` | bbox insert / remove | verified |
| 0x41FC20 | `Ang16_PolarToXY` | `void __stdcall(short* ang, SCR_f* len, SCR_f* outX, SCR_f* outY)` ret 0x10 | x = sin·len, y = cos·len | verified |
| 0x41FA70 | `Ang16_AddAssign` | `short* __thiscall(short*, short*)` | add and wrap to 0..1439 | verified |
| 0x433970 | `Sprite_RampSpeedToward` | `void __thiscall(PedGameObject*, SCR_f)` ret 4 | speed ± 1/256 toward target | verified |
| 0x4B99F0 | `Sprite_MarkBoundsDirty` | `void __fastcall(Sprite*)` | | verified |
| 0x491E00 / 0x435C80 | `TeleportGameObject` / `Ped_Teleport` | | applied at the next tick, **no collision** | verified |

## 6. How to move the player sideways safely

There is no "move this ped by (dx, dy) with collision" function, and no pure "can it go from A
to B" query: the collision is inline in `PedGameObject_StateWalk`, keyed off the heading. Options:

1. **Heading offset during the move (chosen).** The game already walks backwards this way:
   rotate the heading for the duration of one move, let every test (probe, tile edges, slide,
   sprite obstacles) run along the real direction, restore the heading before the sprite is
   rotated. Strafe is the same trick with ±90° (±360 units), ±45° when combined with forward.
   Cost: one `JMPHOOK` plus an input-side change.
2. **Push accumulator** `PedGameObject+0x4C/+0x50`. No code patch, and it works even for a standing
   ped (`StateStaying` runs the walker when the push is nonzero). But the wall probe still points
   6 px **along the heading**, and `CanMovePlayer` ignores the push when the front box already
   crosses a tile edge, so a wall beside the ped is not always caught, and a wall in front can
   block a pure side step. Good for a prototype, wrong for the feature.
3. **Host-side move + own test** (`MapBlocks_IsBlockEdgeCrossingBlocked`, `Collision_FindObstacle`,
   grid remove/insert by hand). Re-implements the walker without the slide, slope and z rules,
   and risks the grid-pool leak. Rejected.

### The hook (verified in the disassembly)

`PedGameObject_StateWalk` keeps two locals: a byte flag `[esp+0x11]` (≠ 0 = the heading has not
been changed this move) and the saved heading `[esp+0x24]` (frame: `sub esp,0x30` + 4 pushes).
The backward branch saves the heading and clears the flag; at **0x49AC76** the code reads the
flag and, if it is still set, saves the unmodified heading; at **0x49B0A5** it restores the
heading when the flag is clear.

```
0x49AC76  8A 44 24 11     mov al,[esp+0x11]        ; JMPHOOK here: 6 bytes, no relative branch
0x49AC7A  84 C0           test al,al
0x49AC7C  74 09           jz 0x49AC87
0x49AC7E  66 8B 56 40     mov dx,[esi+0x40]        ; ESI = PedGameObject*
0x49AC82  66 89 54 24 24  mov [esp+0x24],dx
0x49AC87  …               probe from the heading (Ang16_PolarToXY at 0x49ACB5)
…
0x49B0A5  8A 44 24 11     mov al,[esp+0x11]
0x49B0AB  75 09           jnz 0x49B0B6
0x49B0AD  66 8B 4C 24 24  mov cx,[esp+0x24]
0x49B0B2  66 89 4E 40     mov [esi+0x40],cx        ; heading restored
```

Stub at 0x49AC76, for the local player's PedGameObject only (`[[esi+0x7C]+0x15C]` = its Player*) and
a nonzero offset: if `[esp+0x11] ≠ 0`, store `[esi+0x40]` into `[esp+0x24]` and clear the flag;
then `[esi+0x40] = wrap1440([esi+0x40] + offset)`. The displaced `mov`/`test` then see the clear
flag, skip the save, and the end of the function restores the facing.

Offsets relative to the facing: pure strafe ±360; forward + strafe ±180; backward + strafe: the
backward branch has already turned the heading by 720, so ∓180. Left is **+360**, right **−360**
(x = sin h, y = cos h; the left arrow makes the heading grow). Measured on Downtown's start
(facing north, heading 720): right moved the ped +x and left −x at 1/16 block per tick with
y and the heading unchanged, and each run stopped at a building wall (left: x pinned at 156.75
blocks for 250 frames). Implementation: `host/player_move.asm`.

**The hook sees every walking ped**, not only the player: the check for the player's
PedGameObject must come before anything is consumed (the first version cleared the offset on an
NPC that walked earlier in the tick, and the player never strafed).

### Input side

`StateWalk` only moves when `Player.moveSpeed ≠ 0`; with 0 it sets speed 0 and STAYING. A pure
strafe must therefore report "forward" (`moveSpeed = +1.0`) after `Player_MoveOnFoot`, so the
state machine stays in WALK and the walk animation plays. Disable strafe when the ped is in a car
(`Ped+0x168 == 0` or `Ped+0x16C ≠ 0`), getting in/out, or `Player+0x2F` (controls disabled).

### Mouse turning

`Player.turnRate` is the per-tick heading delta and the player has no separate target heading, so
writing `turnRate` after `Player_MoveOnFoot` turns the ped smoothly by any amount through the
game's own code (`StateWalk` and `StateStaying` both apply it). Writing PedGameObject+0x40 directly
also works, but `Ped_UpdateState` keys WALK↔STAYING on `turnRate`, so the delta path keeps the
state machine honest.

## 7. Open questions

- Values of a few CRT-initialised constants are inferred, not read live: `DAT_0066A574` (walk
  speed copy), the slide octant angles `DAT_0066A718/758/6C8/654`, the turn clamps 48/24.
- Shooting direction is believed to be the heading (`Ped_UpdateWeaponFiring` runs before the move
  in the same tick, so the temporary offset does not affect it) — the weapon code was not read to
  the end.
- `MapBlocks_SweepBodyIsClear` 0x469F90: argument order at the call sites.
- PedGameObject+0x10 sub-mode values, `DAT_0066A3C6` and `DAT_005E6664` writers.
- `PedGameObject_Tick` has a second caller, 0x4BE870 (probably remote players), not read.

## 8. Prior mods

None of them strafed or touched collision; all three only turned the ped.

| mod | how it turned the ped | limit |
|---|---|---|
| [h0x91b/gta2-mouse](https://github.com/h0x91b/gta2-mouse) `6c5351b` (MIT), `MainWindow.cpp:334-391` | cursor angle → `PedGameObject+0x40 = deg·4` written from a 60 Hz timer | the walker overwrites it every tick (jitter); cursor must stay in the window |
| [h0x91b/gta2-resurection](https://github.com/h0x91b/gta2-resurection) `87e1d98` (MIT), `mod-mouse-rotation.lua:18-111`, `dllmain.cpp:58` | hook `SetKeyState` 0x4A4930, presses virtual left/right while the angle error > 15°, direct write inside the dead zone | turn speed capped by `turnRate`, 15° dead zone |
| [izawartka/gta2-seuko-mod](https://github.com/izawartka/gta2-seuko-mod) `25b1985` (credit + link, not for sale), `src/modules/modmenu/cheats/mouse-control/`, `src/events/keyboard-state-update.cpp` | jump hook at 0x4A4934 (inside `SetKeyState`), virtual left/right from point-at-mouse or a locked relative mouse | turn speed capped by `turnRate` |
