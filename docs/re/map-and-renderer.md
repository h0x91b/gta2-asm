# Map, city renderer and tile-bound world objects in gta2.exe 11.44

How vanilla GTA2 holds the `.gmp` city in memory, how one frame of the city is drawn (which
blocks, in which order, with which camera, shading and `gbh_*` calls), and how the world
objects tied to tiles work: doors, cranes, lights, animated tiles. Written for two uses: our SDL
renderer (`host/c/renderer*.c`, [renderer-api.md](../renderer-api.md)) and mods (§9).

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`). Every name is in the Ghidra
DB (`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and therefore in `re/`.
"verified" (V) = the body was read in the decompiler and checked from a second angle (a caller,
a field use, a constant or a second function); "hypothesis" (H) = the name carries `unsure_`.
Facts the Seq 44 lead re-checked itself in the decompiler or disassembly are marked
**(re-checked)**. Sources: Seq 44 analysis in five slices (renderer 0x46B-0x472, map data
0x462-0x46A, collision grid + cranes 0x445-0x449, crusher/draw queues/BlockInfo/doors
0x44A-0x451, frame loop/world glue/lights 0x45A-0x461 + script 0x474-0x47F), plus
[ped-movement-collision.md](ped-movement-collision.md) (Seq 37: collision grid, slopes),
[script-engine.md](script-engine.md), [hud-and-menus.md](hud-and-menus.md) (frame loop, settings),
[math-helpers.md](math-helpers.md) (Fix16 = 14 fractional bits), [formats/loader-map.md](../formats/loader-map.md)
and the 10.5 names of gta2_re ([CREDITS.md](../../CREDITS.md)).

## 0. Coverage

Census of functions with an auto name (`has_custom_name=false`) in 0x440000-0x47FFFF, live DB:

| Slice | before | after | what is left |
|---|---|---|---|
| 0x440000-0x444FFF (ped AI, Seq 27 domain) | 5 | 0 | |
| 0x445000-0x449FFF (collision grid, cranes, ped lists) | 112 | 16 | 11 CarDriveOrder helpers 0x4462E0-0x446690 (Seq 43), 0x446AA0, frontend array ctor/dtor 0x449CE0/0x449D10, crime-queue vector dtor 0x449EF0, stub 0x449F50 |
| 0x44A000-0x451FFF (crusher, draw queues, input, BlockInfo, doors) | 82 | 3 | `thunk` 0x44A020, two unidentified dtors 0x44DBF0, 0x4504D0 |
| 0x45A000-0x461FFF (frame loop, world managers, lights) | 121 | 16 | function fragments / EH funclets, foreign car/ped/object helpers |
| 0x462000-0x46AFFF (map data) | 82 | 8 | game-loop / network sync 0x4620A0-0x462850 (not map) |
| 0x46B000-0x472FFF (city renderer) | 45 | 10 | 0x4725B0-0x472FD0: car, ped-anim, segment intersection, random helpers |
| 0x474000-0x47FFFF (mission script, unowned) | 122 | 82 | script opcode handlers, named only where trivial or map-related (§8) |
| **total** | **569** | **135** | |

Renamed existing names (was → now): `isNight` (0x595011) → `g_lightingEnabled` (its only writer is
`RenderSettings_LoadFrameRateLighting` 0x4CB235/0x4CB248, registry `screen\lighting`; there is no
day/night clock in the exe) **(re-checked: xrefs)**; `relS12` → `MapRenderer_SetShadingLevel`;
`memsetBuf` → `LightGrid_Alloc`; type `SNightArray` → `Light`; the lead's Step-0 `unsure_` names
in 0x46BB60-0x46BDF0 were verified and refined (§3.1).

Types created or fixed (Seq 44 owns them): `MapRenderer`, `MapBlocks`, new `MapGrid`, `BlockInfo`,
`MapChangeEntry`, `CollisionGrid`, `GridStrip`, `GridEntry`, `DoorFace`, `Crane` (was one
`byte[348]`), `Light`, `ObjectMotionState` (facts from Seq 46). Camera+0x60 (`projScale`, §3.2)
went to Seq 27, who owns Camera.

## 1. Frame: logic tick and draw

`drawAndLimitFrames` runs `Game_RunLogicStep` 0x461930 once per 33 ms tick and `draw()` 0x461960
per rendered frame ([hud-and-menus.md](hud-and-menus.md) §1).

**Logic, `GameTick` 0x45C1F0 (re-checked):** Player_Update ×N → SoundEventQueue_Reset →
CollisionManager visit reset → `if (g_lightingEnabled) LightManager_Update` (flashing lights) →
CraneManager_Update → CrusherManager_Update → GeneratorManager → DummyPedManager →
PublicTransportManager → ParkingZone → CarManager_Update → TrafficLights → ObjectSpawner →
**MissionScript_ExecuteScriptThreads** (this is where opcodes edit blocks, doors, lights, ambient) →
emergency services → UpdateParticles → **TileAnimManager_Update** → DrawGUI (HUD logic) →
FrameCounter_Advance → **DoorManager_Update** → FireEngineManager → FloatingScore. Doors run after
the frame counter increments and after scripts.

**Draw, `eachFrame` 0x45A5A0 (re-checked):**

```
g_ViewCamera = &game->localPlayer->viewCamera
MapRenderer_ClearField2F00(g_MapRenderer)          // per-frame reset
SpriteManager_ResetDrawCounter; LayerDrawQueues_ClearAll
CollisionGrid_EnqueueVisibleSprites(g_CollisionGridAux)        // sprites → 7 layer queues (§6)
CollisionGrid_EnqueueVisibleSprites(g_CollisionGridNotify)
CollisionGrid_EnqueueVisibleSprites(g_CollisionGridObstacles)
BeginFrame2D; gbh_BeginScene
MapRenderer_DrawFrame(g_MapRenderer)               // city + interleaved sprites (§3)
FloatingScoreManager_Draw; DrawUI (HUD); do_mike
gbh_EndScene; EndFrame2D                           // then Vid_FlipBuffers
```

## 2. The map in memory (`.gmp` → `MapBlocks`)

### 2.1 Load

`InitGame` → `LoadGMP_and_STY_Files` 0x45B469 → `LoadMAP_GMPFile(g_MapBlocks, path)` 0x464990:
6-byte header (unchecked), then chunk loop → `MapBlocks_ReadChunk` 0x464890 (strncmp of the tag):
`DMAP_section` 0x4646A0 (grid, columns, blocks, each malloc'd with spare capacity),
`ZONE_section` 0x464640 (+ `MapBlocks_IndexZones` 0x4644E0), `MapChunk_MOBJ` 0x464590,
`MapChunk_LGHT` 0x4645F0, `ANIM_section` 0x464670 (+ `MapBlocks_StartTileAnims` 0x464550),
`MapChunk_RGEN` 0x464880 (road network, Seq 43); then `MapBlocks_AllocZoneInfoSlots` 0x464330.
Error 0x84 without DMAP. Later `startGame` 0x45B5F0 calls `MapBlocks_SpawnMapObjects` 0x46A4D0,
`MapBlocks_CreateLights` 0x4692B0, `MapBlocks_RegisterGangZones` 0x465390. All V.
Formats match [tools/formats/map.ts](../../tools/formats/map.ts) and the DMA spec.

### 2.2 Structs (applied in Ghidra)

`g_MapBlocks` (0x662C08) → **`MapBlocks`** (0x370):

| off | field | meaning |
|---|---|---|
| 0x000 | `MapGrid *grid` | |
| 0x004 | `MapChangeEntry edits[100]` | runtime edit list (§2.5) |
| 0x324 | `editCount` | **no bound check** (§2.5) |
| 0x328 | `zoneData` | raw ZONE chunk |
| 0x32C | `zoneIndex` | `{u16 count; u16 pad; u8 *rec[count]}` |
| 0x330 / 0x334 | `zoneInfoSlot` / `zoneInfo` | one slot byte per zone; `MapZoneInfo` (0x16) records, record 0 = default |
| 0x338 / 0x344 | `mapObjects` / `mapObjectCount` | MOBJ, 6-byte records |
| 0x33C / 0x348 | `lights` / `lightCount` | LGHT, 16-byte records |
| 0x340 | `tileAnims` | ANIM chunk |
| 0x34C / 0x350 / 0x354 | `blockCountLoaded` / `blockCapacity` (= loaded + 200) / `blockCountLive` | |
| 0x358 / 0x35C / 0x360 | `columnWordsLoaded` / `columnWordCapacity` (= loaded + 0x400) / `columnWordsLive` | |
| 0x364..0x36C | `zoneIter`, `zoneIterType`, `zoneIterX/Y`, `zoneIterUsePoint` | FindFirst/NextZoneOfType iterator |
| 0x36E | `slopeStepBlockedFlag` | set by IsBlockEdgeCrossingBlocked, read-and-cleared by `MapBlocks_TakeSlopeStepBlockedFlag` 0x462E80 |

**`MapGrid`** (0x40010): `u32 base[256*256]` (index **y·256+x**, `MapBlocks_GetColumnEntryPtr`
0x42A830), `+0x40000 columnWordCount`, `+0x40004 blockCount`, `+0x40008 u32 *columns`,
`+0x4000C BlockInfo *blocks`. Column at `columns + base*4`: `u8 height; u8 offset; u16 pad;
u32 blockIndex[height-offset]`. z outside `[offset, height)` is air.

**`BlockInfo`** (12 B): `u16 left, right, top, bottom, lid` (+0..+8), `u8 arrows` (+0xA),
`u8 slopeType` (+0xB). Side face word: bits 0-9 tile, 10 wall (0x400), 11 bullet wall, 12 flat
(0x1000), 13 flip, 14-15 rotation. Lid: bits 10-11 = lighting level. `arrows`: low nibble green,
high nibble red. `slopeType`: bits 0-1 ground (0 air, 1 road, 2 pavement, 3 field), bits 2-7 slope
index: 1-44 ramps (`g_SlopeTable` 0x662DB0), 45-48 diagonals, 49-52 diagonal slopes, 53-61 partial
blocks, 63 "slope above". In code `(slopeType & 0xFC) < 0xB4` ⇔ real ramp.

### 2.3 Block lookup (re-checked)

`MapBlocks_GetBlock` 0x4653C0 (`__thiscall`, ECX = `g_MapBlocks`, ints x, y, z → `BlockInfo*` or
NULL): column from `grid.base[y*256+x]`, return `blocks + blockIndex[z-offset]*12` when
`offset ≤ z < height`. Variants: `MapBlocks_GetBlockClamped` 0x465490 (x, y clamped to 0..255; the
renderer's lookup), `MapBlocks_GetBlockForCollision` 0x465410 (53-61 → NULL, 49-52 → the solid
`g_DummyWallBlockInfo` 0x662B94), `MapBlocks_FindGroundBlockAtOrBelow` 0x466A00, `FindMaxZ`
0x46A420, `MapBlocks_FindPavementTopBlock` 0x466910. Ground height: `MapBlocks_GetSlopeSurfaceZ`
0x466B70 (`z0 + gradient(len)·frac`), `MapBlocks_GetGroundZBelow` 0x469570,
`…BelowOrZero` 0x469850. Many callers also write the scratch `g_pLastBlockInfo` 0x662B90.

### 2.4 Zones, map objects

Zone record `{u8 type, x, y, w, h, nameLen; char name[]}`; lookups scan the index linearly in file
order, and the file is sorted smallest area first, so the first hit is the smallest zone
(`MapBlocks_FindFirstZoneAtPoint` 0x465130, `FindFirst/NextZoneOfType` 0x464E70/0x4651C0,
`FindZoneByName` 0x464C70, `PickNextZoneOfType` 0x464DA0 round robin for restarts,
`FindBestZoneOfTypeNearPoint` 0x469110). Only types 1, 10, 15 get a density slot; `GetDensity`
0x465250 returns the `MapZoneInfo` for a point; defaults are the 11 immediates in 0x464330
(car 500, good 300, bad 300, police 100, gang 0, ped 500, mugger 50, car thief 40, elvis 10, gang
ped 200, police ped 40). MOBJ records (`s16 x, y` in 1.8.7 fixed point → `Fix16_FromMapFixed87`
0x462ED0, `u8 angle` → `Ang16_FromMapAng8` 0x462EF0, `u8 type`) are spawned with z = `FindMaxZ`.

### 2.5 The map is edited at runtime, copy-on-write (re-checked)

Scripts (`CHANGE_BLOCK`, `ADD_NEW_BLOCK`, `REMOVE_BLOCK`, `LOWER_LEVEL`) and doors change the map
while the game runs. `MapBlocks_ChangeBlockField` 0x463F60 (x, y, z, field, value): clones the
column to the end of the column array (`MapBlocks_CloneColumnToEnd` 0x463A90), repoints
`grid.base[y*256+x]`, records the cell (`MapChangeList_Record` 0x463990), clones the block
(`MapBlocks_CloneBlockInfo` 0x463A40), then writes field 1-5 = left/right/top/bottom/lid,
6 = slopeType, 7 = arrows. Siblings: `MapBlocks_AddBlockAt` 0x464060, `RemoveBlockAt` 0x464110,
`LowerColumnAt/InRect` 0x464160/0x464210. Loaded data is never modified in place, so savegames
store only the three runtime regions (`MapBlocks_GetEditBuffersForSave` 0x4642A0,
`RestoreEditsFromSave` 0x464250).

**Limits nobody checks at run time:** the edit list holds 100 *distinct* cells (repeated edits of
a cell update its entry); `MapChangeList_Record` appends without a bound, so the 101st cell
overwrites `editCount` and then `zoneData` **(re-checked)**. Spare capacity of 200 blocks and
0x400 column words is checked only at load (hypothesis for the run-time part: no check was found
in the clone functions).

### 2.6 Animated tiles

ANIM record `{u16 base, u8 rate, u8 repeat, u8 len, u8 pad, u16 tiles[len]}` →
`TileAnimPool_AddFromMap` (pool of 50 × 0x18). `GameTick` → `TileAnimManager_Update` →
`TileAnim_Step` per entry; `TileAnim_ApplyFrame` writes `StyleData.tileRemap[base] = tiles[cur]`
(`style+0x40`, `u16[1024]`). **Map blocks are never touched**: every face using tile `base` is
drawn with the remapped graphic, because the renderer resolves every face through
`StyleData_GetTileRemap` 0x4BF6B0 (§3.3). Doors use the same mechanism (§7.1). V by the mapdata
slice; the renderer side is re-checked.

## 3. Drawing the city: `MapRenderer_DrawFrame` 0x472110 (re-checked)

### 3.1 Call graph

```
MapRenderer_DrawFrame(this = g_MapRenderer)
├─ if g_lightingEnabled: gbh_SetAmbient((float)ambientCurrent); MapRenderer_StepAmbient 0x46C1A0
└─ for L = 0..6:                                   // map z levels
   ├─ if L > 0: LayerDrawQueues_FlushLayer(L)      // sprites of the level below (§6)
   ├─ if !g_skipTiles:
   │  ├─ view rect + per-layer projection constants (§3.2)
   │  ├─ if L == 0 && g_lightingEnabled:
   │  │     gbh_ResetLights; gbh_SetCamera(xmin, ymin, xmax, ymax);
   │  │     LightGrid_SubmitLightsToRenderer 0x461400 → gbh_AddLight per light (§5)
   │  ├─ reset currentDrawLayerSize (0x45B040)
   │  ├─ fill renderDistanceArr: MapRenderer_AddUniqueBlockXY 0x46BB90 ×4 per step
   │  └─ DrawMapLayer 0x4720E0: for cell in renderDistanceArr, last to first:
   │        DrawTileBlock 0x471F20(x, y)
   │        ├─ block = MapBlocks_GetBlockClamped(x, y, L); NULL → skip
   │        ├─ copy 5 face words; g_showHiddenFaces → invisible walls/lids as tile 0x260
   │        └─ by slopeType & 0xFC:
   │             0xB4..0xC0 (45-48) MapRenderer_DrawDiagonalBlock   0x46EDD0
   │             0xC4..0xD0 (49-52) MapRenderer_DrawCornerRoofBlock 0x46EE40
   │             0xD4..0xF4 (53-61) MapRenderer_DrawPartialBlock    0x471C30
   │             1..0xB3   (1-44)   MapRenderer_DrawRampBlock       0x471CE0 (skipped by g_skipSlopes)
   │             else               MapRenderer_DrawCubeBlock       0x471D60
   └─ after the loop: LayerDrawQueues_FlushLayer(7)
```

Face drawers (each ends in `gbh_DrawTile`, V): `MapRenderer_DrawLeftFace` 0x46C2C0, `RightFace`
0x46C7F0, `TopFace` 0x46CE30, `BottomFace` 0x46D9A0, `LidFace` 0x46DFE0;
`MapRenderer_DrawPartial{Left,Right,Top,Bottom}Face` 0x470060/0x470250/0x470440/0x470620,
`DrawPartialLidFace` 0x470800; `MapRenderer_DrawDiagonalFace45..48` 0x46D360/0x46D4F0/0x46D680/0x46D810
(slope mapping V, compass direction not checked on screen); `MapRenderer_DrawSideTriangle`
0x46C210 (`gbh_DrawTriangle`, corner roofs only). The map renderer never calls `gbh_DrawQuad`.

Cube block order: Left → Right → Top → Bottom → Lid, each only if its word ≠ 0 (flat faces drawn
as partial pairs). Each wall is back-face culled by comparing two projected x (left/right) or y
(top/bottom) **(re-checked in DrawLeftFace: `if (v1.x < v0.x) return`)**.

### 3.2 Which blocks, and the camera

For layer L the eye is a pinhole at height `8 + cam.z` above z = 0 looking straight down:

- depth of plane L: `A = (8 − L) + cam.z` (Fix16); visible width `w = A / cam.zoom`, height
  `h = w · 0.75` (`g_Fix16_Pt75`); `xmin/xmax = int(cam.x ∓ w/2)`, `ymin/ymax = int(cam.y ∓ h/2)`.
  Lower layers are farther away, so their rectangle is wider.
- projection of a point at height z: `rhw = 1/(cam.z + 8 − z)`,
  `sx = screenPxCenterX + (x − cam.x) · Camera.projScale(+0x60) · rhw`, same for y
  (`MapRenderer_ProjectVertexAtZ` 0x46BC70). The two planes of a layer are cached per layer:
  bottom z = L (`g_MapRenderScaleBottom` 0x6633CC, `g_MapRenderRhwBottom` 0x66364C,
  `MapRenderer_ProjectVertexAtLayerBottom` 0x46BDF0) and top z = L + 1 (`g_MapRenderScaleTop`
  0x663504, `g_MapRenderRhwTop` 0x6635FC, `…AtLayerTop` 0x46BD40). **(re-checked: DrawFrame)**
- `GbhVertex.z` = rhw (1/depth). Vertices go to `g_MapRenderVerts` 0x6632A0 (stride 0x20); the world
  position of vertex k is kept at vertex k+4 for the point lights
  (`MapRenderer_StoreVertexWorldPos` 0x46BBF0).

**Order of cells (painter's algorithm):** the nested loop adds cells symmetrically from the
outermost rows inwards, four at a time, dropping duplicates; `DrawMapLayer` walks the array
backwards, so the centre rows are drawn first and the outermost rows last. Layers go bottom to
top, and each layer's sprites are flushed right after its tiles (§6).
`renderDistanceArr` holds **1500 cells (≈ 45 × 33) with no bounds check**.

### 3.3 One face → `gbh_DrawTile`

```
tile = StyleData_GetTileRemap(g_StyleData, face & 0x3FF)     // animated-tile remap; 0 = skip
flags = lighting(0x8000|0) | table[face >> 13]               // rotation/flip, per face type
        (| 0x4005 custom-UV for ramps/partials) (| 0x80 if face & 0x1000)
tex = TextureCache_GetTileTexture(g_TextureCache, &tile)     // 0x46BB50: g_TextureCache[tile]
gbh_DrawTile(flags, tex, g_MapRenderVerts, brightness = MapRenderer.shade*)
MapRenderer.tilesCount++
```

**(re-checked in DrawLeftFace.)** Flag bits seen (to `gbh_DrawTile`/`gbh_DrawTriangle`):
0x8000 lighting (the `lighting` global 0x67358C), 0x80 flat face = alpha-blend page (face bit 12;
sites include 0x46C79D in DrawLeftFace and 0x46C27A `SHR ESI,5; AND ESI,0x80` in DrawSideTriangle),
0x4000 custom UV (ramps, partials, triangles supply UVs 0..63.9999 themselves), 0x20/0x40/0x60
rotation, 0x08/0x10 flip. Low 3 bits of the table values look like a face-orientation code
(0 lid, 1 top, 2 bottom, 3 left, 4 right, 5 diagonal) — H, our host ignores them. Diagonal faces
do not test bit 12. Never set by map faces: 0x2000, 0x10000, 0x20000.
Rotation/flip tables (8 × u32, index `face >> 13`): left 0x5930D4, right 0x5930F4, top 0x593114,
bottom 0x593134, lid 0x593154, sloped lid 0x593174, diagonals 0x593194/0x5931B4, diagonal lids 0x5931D4.

Seq 27 found that d3ddll caches one texture per tile in the format of its first draw, and that
tiles used both flat and opaque with index-0 pixels exist (wil 74, ste 93, bil 144). Opaque
draws show index 0 as black in the original; the host matches that since Seq 65 (blend NONE for
opaque draws, `docs/renderer-sdl.md` "Index 0"). On screen it changed only diagonal faces, which
never get 0x80.

### 3.4 Shading: baked direction + ambient + point lights

- **Direction shade (per face type):** `MapRenderer_SetShadingLevel` 0x46B620 (ctor: level 15;
  script `SET_SHADING_LEVEL` 0x47E170) fills `MapRenderer.shade*` (+0xC..+0x1B):
  `t = 2·level/3, base = (−4·level − 1) & 0xFF, hi = (51 − level)·5`; left = base + 2t,
  right = hi − 3t, bottom = base, top = hi − t, the rest for diagonals/ramps/roof triangles
  **(re-checked)**. At level 15: left 215, right 150, bottom 195, top 170 (computed, not measured).
  Lids use 0xFF unless lid bits 10-11 ≠ 0 (`MapRenderer_GetLidBrightness` 0x46B5E0 → shadeLeft/
  Bottom/Top). This byte is the 4th argument of `gbh_DrawTile`.
- **Ambient:** `MapRenderer.ambientCurrent/Target/Step` (+0/+4/+8, Fix16).
  `MapRenderer_SetAmbientTarget` 0x46C140 (script `SET_AMBIENT_LEVEL` 0x47AE70: level, frames)
  sets a linear fade, `StepAmbient` advances it once per drawn frame; passed as float to
  `gbh_SetAmbient`. The ctor's default (`eq_1638`) was not decoded.
- **Point lights:** §5. Applied inside the renderer plugin (d3ddll `ApplyPointLightsToVertices`,
  our `apply_lights` in `host/c/renderer_gbh.c`) only for faces with flag 0x8000.
- With `lighting` off none of SetAmbient/ResetLights/SetCamera/AddLight is called.

### 3.5 MapRenderer (0x2F04, applied)

`+0 ambientCurrent, +4 ambientTarget, +8 ambientStep` (Fix16; +8 was the wrong `ptrToS12`),
`+0xC shadeLeft, +0xD shadeRight, +0xE shadeBottom, +0xF shadeTop, +0x10..+0x13 shadeDiag45..48,
+0x14..+0x17 unsure_shadeRamp0..3, +0x18..+0x1B shadeCornerTri0..3`,
`+0x1C RenderDistanceArrayItem renderDistanceArr[1500]` ({int x, int y}),
`+0x2EFC currentDrawLayerSize`, `+0x2F00 tilesCount` (faces drawn; looks like a debug stat).
Renderer scratch globals (0x663298-0x663738) are named `g_MapRender*` / `g_Fix16_*`; see `re/globals.csv`.

## 4. Collision grid = sprite draw list

The three collision grids (`g_CollisionGridAux/Notify/Obstacles`) are also what decides which
sprites get drawn **(re-checked)**: `CollisionGrid_EnqueueVisibleSprites` 0x447390 takes the
camera's non-negative bounds ± margin (`DAT_005E672C`/`5E6944`), clamps them to 0..255 and calls
`CollisionGrid_EnqueueSpritesInCellRect` 0x446D60, which pushes every entry whose sprite kind
(`+0x30`) > 1 into `g_LayerDrawQueues`. A sprite that spans several cells is enqueued once per
cell; whether the queue drops duplicates is open.

Layout (types applied): `CollisionGrid { GridStrip *rows[256]; }`, `GridStrip` (12 B)
`{u8 col; pad[3]; GridEntry *entries; GridStrip *next}` sorted by column, `GridEntry` (8 B)
`{Sprite *sprite; GridEntry *next}`. Fixed pools: 4096 entries (`g_CollisionEntryPool` 0x5E6684,
alloc 0x447350/free 0x447360) and 6000 strips (`g_CollisionStripPool` 0x5E6688, 0x447370/0x447380).
**`CollisionEntryPool_Alloc` pops without an empty check** (`mov eax,[ecx]; mov edx,[eax+4]` —
the known crash at 0x447352 **(re-checked: disassembly)**); its callers
`CollisionGrid_AddEntryAtCell` 0x4479D0 and `CollisionGrid_InsertSpriteIntoRow` 0x447A60 use
the result at once. A bbox sprite takes one node per covered cell; objects and particles use the
point variant (`CollisionGrid_InsertSpriteAtPoint` 0x447BA0). Map blocks are not in the grid: walls
and slopes come from `MapBlocks_ScanBoxFacesForWalls` 0x46A570 ([ped-movement-collision.md](ped-movement-collision.md)).

## 5. Lights

- **LightManager** (`g_LightManager`, 0x1D4CC): `+0 freeHead, +4 activeHead, +8 Light[3000]`.
  **`Light`** (0x28, applied): `+0 packedIntensityRadius` (byte 0 intensity, byte 1 radius·32;
  free marker 0x2A2A2A2A), `+4/+8/+0xC x, y, z` (Fix16), `+0x10 colour` (0xRRGGBB),
  `+0x14 flashOnTicks, +0x15 flashOffTicks, +0x16 flashRandomJitter, +0x17 flashCounter,
  +0x18 baseIntensity`, `+0x1C nextInList` (free/active), `+0x20/+0x24 gridNext/gridPrev`.
- **Spatial hash** `buf16384` 0x6622B4: 64 × 64 cells of 4 × 4 blocks, index `(y>>2)*64 + (x>>2)`
  (`LightGrid_Alloc` 0x4612A0).
- **Creation:** LGHT record `{u32 argb; s16 x, y, z, radius (1.8.7); u8 intensity, shape, on, off}`
  → `Light_Init` 0x469010 (`LightManager_AllocLight` 0x464C40, radius byte via
  `LightIntensityRadius_SetRadius`, link into the hash) and, if `on ≠ 0`, `Light_SetFlashing`
  0x469070 (push to the active list, `LightManager_PushActive` 0x464C60). Also from
  ObjectSpawner, `Script_Decl_LIGHT_SET` 0x47F710 and traffic lights.
- **Per tick:** `LightManager_Update` 0x45BF50 steps only the active (flashing) list via
  `Light_TickFlash`; that function always returns 0, so the free branch in Update is dead (H: vestige).
- **Per frame, layer 0 only (re-checked):** `LightGrid_SubmitLightsToRenderer` 0x461400 widens the
  visible block rect by 2 cells (8 blocks), clamps to 0..63 and calls `gbh_AddLight(&{packed,
  float x, float y, float z, colour})` (20 bytes, = seuko-mod `SLight`) for every light in those
  cells. Our host keeps at most `MAX_LIGHTS` = 1024 per frame (`host/c/renderer_gbh.c`); the pool is 3000.

## 6. Layer draw queues: how sprites interleave with map layers

7 queues (`LayerDrawQueues_Ctor` 0x44B8F0, cleared each frame). `LayerDrawQueues_Enqueue` 0x44B990
culls sprites below `DAT_005E8C10`, computes the layer (cached at sprite+0x39: `(z − DAT_0066FFAC)>>14`
plus a correction in 0x4BD2E0) and inserts into a binary tree sorted by z, then type
(`LayerDrawQueue_InsertSorted` 0x4C4BF0). `LayerDrawQueues_FlushLayer` 0x44B8B0 →
`LayerDrawQueue_DrawInOrder` → 0x4BE060 per sprite = `gbh_DrawQuad`.
Order in a frame (from DrawFrame, re-checked): tiles of layer 0, sprites queued for layer 0
(flushed at the start of iteration 1), tiles of layer 1, …, tiles of layer 6, then flush 7.
H: the exact meaning of the queue index vs. the sprite's z-level was not checked live.

## 7. World objects tied to tiles

### 7.1 Doors (re-checked: DoorFace_Open/Close)

A door is two map faces, not a sprite. `DECLARE_DOOR_INFO` → `g_DoorInfoTable` 0x5E9340 (5 × 10 B:
tile range, two tile-remap slots, speed). `DOOR_DATA_*` (Script_Decl 0x477D20/0x477EE0) →
`DoorManager_RegisterSingleDoor` / `…NoCheck` (opcode 375 DOOR_DATA_SINGLE_1, one `Door_AddFace`; gta2_re 10.5
calls them RegisterDoubleDoor, swapped — Seq 48) or `DoorManager_RegisterRotatedDoubleDoor` / `…NoCheck`
(opcode 378, two faces: tile + side neighbour) → Door slot (0x38 B, 22 slots, `g_DoorManager`) with one or two `DoorFace` (16 B, pool
`g_pDoorFacePool` 0x5E9374: `state` 1 closed / 2 open, block `x, y, z`, `doorInfoIdx`, `side`
1-4); `Door_SpawnObjects` spawns object 0xA9 (visible door) and 0xA7 (trigger).

- `DoorFace_Open` 0x44C560: state = 2; `MapBlocks_ChangeBlockField` on the face with the remap slot
  tile | 0x1000 (| 0x2000 for the B face), and on the opposite side of the same block
  (`HeadingClass_Opposite` 0x462B90); `TileAnimManager_StartAnim(first → last)`.
- `DoorFace_Close` 0x44C610: state = 1; face word = tile | 0x1C00 (wall + bullet wall + flat); the
  animation reversed.
- Collision follows the face word's wall bits, so there is no separate door collision for ground
  units; object 0xA7 decides who may pass (`DoorManager_ShouldDoorBlock`).
- Triggers: car touches 0xA7 → `DoorManager_OnCarTouchDoorObject` → `Door_OnCarTouch` (if
  automatic `+0x29`, `Door_CarMayOpen`, enabled); ped touch → `Door_OnPedTouch`; script
  `DOOR_CONTROL` 177/178 open/close, 179/180 automatic/manual. Auto-close: `Door_UpdateAutoClose`
  counts `+0x1E` down from `+0x1C` (animation length + 0x28). `Door_GetState` 0x476A90 returns
  `+0x20` (mode 1-6; meanings H).

### 7.2 Cranes

Up to 10 (`g_CraneManager`, count at +0xD98), `Crane` 0x15C (applied). Script `CRANE_DATA`
(0x477660) → `CraneManager_AddCrane` 0x449810 → `Crane_Init` 0x449130, then `Crane_SetTarget1/2`
0x4495F0/0x4496E0. A crane has no own drawing: it is 14 ordinary objects (base 135, 4 wires 134,
parts, hook 136, **trigger 137** at base z − 1). The only tie to the map is height: `FindMaxZ` for
the base (cannot sit under a lid) and for each target's drop height. Per tick `CraneManager_Update`
0x449C40 → `Crane_Update` 0x449BA0.

Pick-up chain (V): car touches object 137 → `Car_OnTouchObject` 0x4293D0 case 0x89 →
`CraneManager_OnCarTouchedTrigger` 0x4497E0 → `Crane_OnCarTouched` 0x448A80 (empty, liftable:
`Car_CanBeLiftedByCrane` 0x447F00, not in the cooldown list) → candidate snapshot; if the
car moves the candidate is dropped (`Crane_UpdateCandidatesAndTargets` 0x449880). States
`Crane.state` (+0x150) 0 idle … 4 carrying to target (names H). `kind` (+0x144): 0 basic, 1 FIRST,
2 both, 3 SECOND. `phase` (+0x155) links to the crusher: the SECOND target receives dead
(engine state 7) cars. Transporter trucks (model 66) can be loaded and unloaded.

### 7.3 Crusher, animated tiles

Crushers (3 slots): `CrusherManager_Update` → `CrusherSlot_Update`, a 4-state machine. Animated
tiles: §2.6.

## 8. Script opcodes that touch the map

| handler | calls |
|---|---|
| `Script_Op_CHANGE_BLOCK` 0x47C660 (185-187) | `MapBlocks_ChangeBlockField` |
| `Script_Op_REMOVE_BLOCK` 0x47C5E0 (183) | `MapBlocks_RemoveBlockAt` |
| `Script_Op_LOWER_LEVEL` 0x47C620 (184) | `MapBlocks_LowerColumnsInRect` |
| `Script_Op_ADD_NEW_BLOCK` 0x47C6A0 (182) | `BlockInfo_Clear` + `MapBlocks_AddBlockAt` |
| `Script_Op_DOOR_CONTROL` 0x47C4D0 (177-180) | `DoorFace_Open/Close` via 0x476A60/0x476A30, automatic/manual |
| `Script_Op_CHANGE_INTENSITY/COLOUR/RADIUS` 0x47CA20/0x47CA60/0x47CAA0 | `Light_SetIntensity` 0x476AE0 / `Light_SetColor` 0x476B00 / `LightIntensityRadius_SetRadius` |
| `Script_Op_SET_AMBIENT_LEVEL` 0x47AE70 (226) | `MapRenderer_SetAmbientTarget` |
| `Script_Op_SET_SHADING_LEVEL` 0x47E170 (373) | `MapRenderer_SetShadingLevel` |
| `Script_Decl_LIGHT_SET` 0x47F710 | `Light_Init` + `Light_SetFlashing` |

## 9. Hooks for mods

| Want | Where | Notes |
|---|---|---|
| Hide face types / whole map | `g_skipLeft` 0x5EAD67, `g_skipRight` 0x5EAD59, `g_skipTop` 0x5EAD8C, `g_skipBottom` 0x5EAD5F, `g_skipLid` 0x5EAD9C, `g_skipSlopes` 0x5EAD78, `g_skipTiles` 0x5EAD90; `g_showHiddenFaces` 0x5EAD5A | debug bytes read from the registry by `Debug_LoadFlagsFromRegistry`, so our registry seed can set them with no code patch |
| Draw distance / zoom out | view rect in DrawFrame 0x472110 and `renderDistanceArr[1500]` | more than 1500 cells overflows `MapRenderer` with no check: clamp w, h in DrawFrame, or enlarge the 0x2F04 allocation in Game_Ctor **and** every `+0x2EFC/+0x2F00` site |
| Layer count | `while (L < 7)` in DrawFrame | the map is 8 high; more needs the queue count too |
| Retexture a tile everywhere | `StyleData.tileRemap[tile]` (`StyleData_SetTileRemap`) | no map edit, no capacity used; how water, neon and doors animate |
| Override map face textures | `TextureCache_GetTileTexture` 0x46BB50 / `StyleData_GetTileRemap` 0x4BF6B0 | every face drawer goes through both |
| Edit one cell at run time | `MapBlocks_ChangeBlockField` 0x463F60 (thiscall ECX = `g_MapBlocks`) | saved with the game; ≤ 100 distinct cells, 200 spare blocks, 0x400 spare column words (raise the last two via the `+200`/`+0x400` immediates in `DMAP_section` 0x4646A0) |
| Custom / procedural blocks | hook `MapBlocks_GetBlock` 0x4653C0, `GetBlockClamped` 0x465490 (renderer), `GetBlockForCollision` 0x465410 (collision) | keep writing `g_pLastBlockInfo` |
| Per-cell draw override | `DrawTileBlock` 0x471F20, before the slope dispatch | e.g. replace a lid |
| No back-face culling | the `if (v1.x < v0.x) return` compares in the four wall drawers | shows inside faces |
| Flat / different "sun" shading | `MapRenderer_SetShadingLevel` 0x46B620, or overwrite `shade*` after it | |
| Full bright / no lights | write 1.0 (0x4000) to `ambientCurrent` each frame; or `lighting` 0x67358C = 0 and `g_lightingEnabled` 0x595011 = 0 | the latter removes ambient and all point lights |
| More / fewer / brighter lights | `LightGrid_SubmitLightsToRenderer` 0x461400 (range ±2 cells, clamp 0x3F), `Light_Init` 0x469010 (every level light), `Light_TickFlash` | |
| Animated tile speed | `TileAnim_InitFromMapData` 0x4C32A0 (rate byte), or live pool entries `+4` delay | the tick runs per game tick |
| Traffic / ped density defaults | the 11 immediates in `MapBlocks_AllocZoneInfoSlots` 0x464330; `MapBlocks_SetZoneInfoAll` 0x465280 | |
| Sprite draw cull / order | `LayerDrawQueues_Enqueue` 0x44B990 (z cull `DAT_005E8C10`), `LayerDrawQueue_InsertSorted` 0x4C4BF0, layer function 0x4BD2E0 | |
| Collision pool crash | enlarge: loop count 0xFFF in `CollisionEntryPool_Ctor` 0x4468C0 + `operator_new(0x8004)` in `CollisionManager_Ctor` 0x4471B0 (strip pool 5999 / 0x11944) | a NULL guard needs a code cave in both callers |
| Doors always open | call `DoorFace_Open` 0x44C560 on both faces of every slot and `ret` `DoorFace_Close` 0x44C610 | not tested |
| Doors never open for cars | return 0 from `Door_CarMayOpen` 0x44CA70 | |
| Crane lifts anything | `Car_CanBeLiftedByCrane` 0x447F00; `Crane_SetDisabled` 0x447F60 | |

## 10. Open questions

- Compass direction of `MapRenderer_DrawDiagonalFace45..48`; runtime values of `Camera.projScale`
  and `CameraPos.zoom` (a live read of `g_ViewCamera` would settle both).
- Whether d3ddll reads the low 3 bits of the `gbh_DrawTile` flags; the tail of `DrawRampBlock` and
  `unsure_shadeRamp0..3` are only partly read.
- Default ambient (`eq_1638`, 0x5EB854) value.
- Whether `LayerDrawQueues` drops a sprite enqueued from several grid cells.
- Door modes 1-6 and the Door layout around +0x30/+0x34 (needs a live dump).
- Ground type 3 + green arrows = railway: every `unsure_Rail_*` helper is a hypothesis from code.
- `Crane +0x140` script event id and `+0x78` home crane (callee 0x476900 still unnamed).
- `MapBlocks.edits[99]` split in Ghidra: a Structure Editor Clear of 0x320-0x323 would allow
  `MapChangeEntry edits[100]`.
