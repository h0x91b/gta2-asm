# HD sprites: how gta2.exe draws a sprite, and where an HD texture can be swapped in

What the host renderer has to know to replace a sprite's texture with a higher-resolution one, peds and cars first
(dream 1 of [dreams.md](dreams.md)). Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`), every
name is in the Ghidra DB and therefore in `re/`. Marks: (V) read in code and checked from a second angle, (L) measured
live, (U) hypothesis. Sources: Seq 27 phase 1, sub-agents H1 (texture path), H2 (palettes, remaps, deltas), H3 (ped
frames, car sprite ids, logical size), and the live probe `gta2ctl sprites` (`host/c32/sprite_probe.c`,
`host/c/sprite_probe.c`, [gta2ctl.md](../gta2ctl.md)).

Short answer: hook `Sprite_Draw` 0x4BE060 from C32 (done, as a probe), take the key (sprite type, sprite id, palette
kind, remap, shrink, car delta mask) and let the host's `gbh_DrawQuad` replace the texture it is handed by the HD
texture for that key, keeping the game's quad geometry and the logical sprite size. §7 has the design.

## 1. The draw path

Everything world-side that is a sprite (peds, cars, objects, particles) is a `Sprite` (0x3C bytes, `SpritePool` of
5031) drawn by **`Sprite_Draw` 0x4BE060**, thiscall, plain `ret`, single caller `LayerDrawQueue_DrawInOrder` 0x4C4D20
(V). HUD and frontend sprites go through `DrawSprite2D` 0x4CBA50 / `DrawGTAText` 0x4CC100 instead (not covered here).

`Sprite_Draw`, in order (V, disassembly read in full):
1. `Sprite_EnsureSpriteBounds` 0x4BCBD0 (lazy draw box, §5).
2. Texture:
   - `Sprite+0x38 shrink == 0`: `TextureCache_GetSpriteTexture(g_TextureCache, spriteType, spriteId, paletteKind, remap)`
     0x4C2AC0, a static per-level handle (§2).
   - `shrink != 0` (burning, sinking, crushed): a cropped copy (`shrink` px off every side) is written into the style's
     last sprite entry (`StyleData_GetLastSpriteIndex` 0x4B9F20) and drawn through the single scratch texture
     (`TextureCache_SetScratchTexture` 0x4C2CE0).
   - Cars with a delta bit set: the texture is replaced by a car-sprite-cache slot (§3).
3. Corners: `Sprite.frameBounds` (+4) corners through `QuadVertex_ProjectWorldPoint` 0x4BA4D0 into the global vertex
   array 0x66FE18 (4 x 0x20 bytes, D3DTLVERTEX); the corners' world xyz sit at +0x80. UVs from `QuadVertex_InitUvCorners`
   0x4B9BC0 in **source texels**: (0.3, 0.3) .. (w - 0.3, h - 0.3), w/h = the sprite entry size.
4. Up to three `gbh_DrawQuad` calls (sites 0x4BE43B, 0x4BE458, 0x4BE50B):
   - shadow, when `Sprite_ShouldDrawShadow` 0x4BAC10: flags 0x2180, diffuse 0xA0000000, offset by 5 * uiScale, **the
     body's texture** (V; L: shadow and body hash equal for every key);
   - body: flags `Sprite_GetDrawQuadFlags` 0x4BAC60 = 0x80 / 0x2180 / 0x2280 by light mode, `| lighting`;
   - cars only, with `g_lightingEnabled` 0x595011: the lamp overlay, flags 0x80, a second cache slot holding only the
     lamp deltas (§3).

So a ped is 2 quads and a car 2 or 3, all inside one `Sprite_Draw` call: a tag set at its entry is valid for exactly
those quads (L: 32 736 tagged quads in 1076 frames, nothing else drawn inside it).

## 2. Textures and palettes

`TextureCache_RegisterAllTextures` 0x4C30A0 (from `InitFrontend` 0x456BDD and `LoadGMP_and_STY_Files` 0x45B4DC) registers
everything once per style load and `TextureCache_FreeAll` 0x4C2D60 frees it (V): palettes (one `gbh_RegisterPalette` per
physical palette), 1024 tiles, then one `gbh_RegisterTexture` per sprite in table 0 (own palette) and per (sprite,
remap) in tables 1..6. Pixels are pointers into the style's sprite pages (8-bit indices, pitch 256), never copied.
Static handles are therefore stable for a whole level and never re-registered per frame (V).

`TextureCache` (0x15D8, `g_TextureCache` pointer at 0x671978): `tileTextures[1024]` @0, `carSpriteTextures[48]` @0x1004,
`userSlots[96]` @0x10C4, `scratchTexture` @0x1544, `textureTables[7]` @0x1548 (0x14 each: handles @0, count @4,
palettesPerSprite @6, spriteType @8, paletteType @0xC).

| `Sprite.paletteKind` (+0x34) | Table | Handle index | wil size |
|---|---|---|---|
| 2 own palette (no remap) | 0 | global sprite index (`StyleData_GetSpriteIndex` 0x4BF2A0) | 2089 |
| 3 car remap | 1 | spriteId x palettesPerSprite + remap (spriteId category-relative) | 77 x 37 |
| 4 ped remap | 2 | same | 474 x 53 |
| 5 code object | 3 | same | 552 x 6 |
| 6 map object | 4 | same | 90 x 1 |
| 8 font | 5 | same | 723 x 9 |
| 7 user | 6 | same | 173 x 15 |

- Who sets the kind: `Sprite_SetRemap` 0x4B9B00 (kind from spriteType: car 3, ped 4, code object / particle 5, map
  object 6, user 7, font 8) and `Sprite_SetNoRemapState` 0x420700 (kind 2) (V).
- Palette ids handed to the renderer are **physical** (`StyleData_GetPhysicalPalette` 0x4BF530, PALX). Virtual ->
  physical differs between wil / ste / bil, so a host reverse map must be built from StyleData at run time (V, PALX
  decode). A few remaps share a physical palette with another remap or a sprite base palette (wil: car remap 33, ped
  remaps 8, 19 = 44): same colours, so a key on the physical palette loses nothing.
- **There is no lighting palette**: `SetShadeTableA` is a stub; lighting is the flag bits plus per-vertex `gbh_AddLight`
  in the renderer. An HD texture is plain unlit RGBA (V).
- **A remap is a full palette, not a tint**: car sprite 0, remap 29 vs base: 215 of 216 used indices differ, 49..76 % of
  the pixels; ped remaps change 15..211 of 255 indices (V, data). A shader hue shift cannot reproduce them.

Who picks the remap (V): traffic cars `Car_PickRandomRemap` 0x422020 (`CarInfo.remap[]`, one extra outcome = base art);
`Car_ApplyRemap` 0x421FD0 (respray, scripts, gang `carRemap`); FBI car forced remap 2 in `CarManager_SpawnCar` 0x426AC0;
wrecks no remap; peds `Ped.remap` (+0x244, 0..52, 0xFF none) re-applied every tick in `PedGameObject_UpdateAnimFrame`
0x497DF0, forced off for corpse frames.

## 3. Car deltas and the car sprite cache

Deltas exist **only for car sprites** (V, DELX of all three styles: 67 sprites, ids 0..64, 75, 76; 868 records). A delta
is an indexed pixel patch (index 0 erases to transparent). The car's set is the 32-bit mask `Car.deltasBitstate` (+8):

| Bits | Meaning | Writer |
|---|---|---|
| 0..4 | damage areas + windscreen | `Car_DamageArea` 0x422F00, `Car_Repair` clears |
| 5, 6 (22, 23 mirrored) | rear / front lamps on | `TurnOnCarBrakeLights` 0x4213D0, `TurnOnCarLights` 0x425590 |
| 7..10 (24..27 mirrored) | door 0 / 1 frames 0..3, one bit at a time | `CarDoor_UpdateOpening` 0x421A00 / `UpdateClosing` 0x421A80 |
| 11..14 (28..31) | doors 2/3, or popup lamps (`Car_UpdatePopupLightsAnim` 0x423C30), or digits (GT24640 only) | |
| 15 | roof decal or roof lights | `Car_SetRoofDecalDelta` 0x421810 |
| 16..18 | emergency lights | `Car_UpdateSirenFlash` 0x423B80 |
| 19..21 | unused so far (U) | |

Pixels are rewritten before upload in the **car sprite cache** (`g_CarSpriteCache` 0x5E85C0, V):
- 48 entries x 0x14 {pixelBuf, spriteId (global, 0xFFFF free) @4, deltaMask @8, LRU stamp @0xC, textureSlot (= index)
  @0x10, palette (virtual) @0x12}; slots 0..31 are 64 rows, 32..47 128 rows; each owns one of the 48 pre-registered
  `carSpriteTextures`.
- `CarSpriteCache_GetOrCreateCarSpriteSlot` 0x44B0C0: mask 0 -> 0xFFFF (the static table texture is used); hit on
  (sprite, palette, exact mask) or on a strict-subset entry (only the missing bits applied); miss -> LRU victim, rows
  copied from the base sprite, `CarSpriteCache_ApplyDeltaMask` 0x44AEA0 (bits >= 22 = record n - 17, flipped), then
  `TextureCache_SetSpriteSlotPalette` 0x4C2C80 (Lock, size, AssignPalette, Unlock).
- With lighting on, `Sprite_Draw` clears the lamp bits (`g_CarDeltaLightMask` 0x5E85BC, default
  `g_CarDeltaLightMaskDefault` 0x591E90 = 0x00C78060) for the body slot and draws them alone, rows cleared, as the
  overlay quad; the mask is restored afterwards. `CarSpriteCache_InvalidateAll` 0x44AFE0 runs on a lighting toggle.
- So a slot handle **does not identify the sprite**: the same 48 handles carry changing content (V). The cache entry
  does, and it is current before the quad of the same `Sprite_Draw`.

Combinations in practice: damage (5 cumulative bits), at most one bit per door, lamps, siren, popup. Measured (L,
Downtown): 102 car keys over 12 sprites, e.g. the taxi (sprite 50) with masks 0x808040, 0xC08060, 0x10808040 ...; the
game itself never holds more than 48 live combinations.

## 4. Sprite ids

Category bases (SPRB, identical in wil/ste/bil, V): car 0 (77), ped 77 (474), code object 551 (552), map object 1103
(90), user 1193 (173), font 1366 (723). `Sprite.spriteId` is relative to its category; particles (type 8) share the
code-object base.

### 4.1 Peds

Only `PedGameObject_UpdateAnimFrame` 0x497DF0 writes a living ped's frame (V). Frame = **block + offset**: block 0
(`Ped.graphicType` DUMMY), 158 (GANG and any other value), 316 (EMERG); the offset depends on the anim state
(`PedGameObject.anim` +0x6C, `animFrame` +0x68, `walkSubMode` +0x10, armed = +37 in walk/run). Every frame has its own
pixel size (12..32 x 10..32), no fixed cell.

| Offset | Anim | Note | Mark |
|---|---|---|---|
| 0..7 / 37..44 | 0 walk | unarmed / armed | V, L (unarmed) |
| 8..15 / 45..52 | 1 run | unarmed / armed | V, L (unarmed) |
| 16..23 | 5 jump | also scales the draw box | V, L |
| 24..27, 32..35 | 6 enter car | frames 0..3, then 4..7 | V, L |
| 36..33, 28..31 | 7 exit car | frames 0..3, then 4..7 | V, L |
| 53..56 | 2 stand | | V, L |
| 57..64 | 2 stand, walkSubMode 0x23 | | V |
| 65..80 | 0xF, 0x10 (0xA, 0xD = 72, 0xE = 80) | fall / lie (U names) | V |
| 81..97 | 0xB / 0xC | burning | V |
| 115..130 | 4 | unarmed attack, standing / moving | V |
| 135..140, 143..148 | 1 / 0 with walkSubMode 0 | | V |
| 139 | 3, or 2 while firing | firing pose | V |
| 151..157 | 0x11, 0x15, 0x13, 0x14 | corpse / blood (U names) | V |
| 98..114, 131..134, 141..142, 149..150 | - | no reference found: probably unused (U) | U |

Live (L, `gta2ctl sprites peds`, 1076 frames, dummies and gang members): no ped id outside its block; the offsets
above marked L match. The sprite id **lags the anim state by one tick** while an anim plays (the frame is set from the
previous tick's state), so an HD lookup must key on the sprite id, never on the anim state. Not seen live yet: the
EMERG block, armed offsets, burning, corpses.

### 4.2 Cars

Model -> sprite = `CarInfo.spriteIndex` (accumulated at load, `StyleChunk_CARI` 0x4C0580), constant for the car's life
except the wreck swap: `Car_BecomeWreck` 0x427B60 sets the sprite of model `72 + CarInfo.wreck` (sprites 65..74), no
remap, deltas reset, drawn at the collision-body size (V). Identical in wil/ste/bil (V, data). Several models share a
sprite: HOTDOG + D1..D4 (20), TVVAN/VAN (61), EDSEL/EDSELFBI (13).

`CarInfo w x h` = collision body in px; `sprite px` = SPRX entry (the draw box when new; wider than the body to leave
room for open doors).

| model | name | sprite | CarInfo w x h | sprite px w x h | num remaps | wreck |
|---|---|---|---|---|---|---|
| 0 | ALFA | 0 | 32x64 | 62x64 | 20 | 2 |
| 1 | ALLARD | 1 | 30x64 | 44x64 | 12 | 3 |
| 2 | AMDB4 | 2 | 30x64 | 62x64 | 10 | 3 |
| 3 | APC | 3 | 48x85 | 50x98 | 0 | 8 |
| 4 | BANKVAN | 4 | 40x79 | 60x104 | 1 | 8 |
| 5 | BMW | 5 | 32x64 | 62x64 | 9 | 2 |
| 6 | BOXCAR | 6 | 42x128 | 42x128 | 0 | 0 |
| 7 | BOXTRUCK | 7 | 34x107 | 52x128 | 6 | 7 |
| 8 | BUG | 8 | 30x52 | 50x52 | 19 | 2 |
| 10 | BUICK | 9 | 34x64 | 64x64 | 14 | 3 |
| 11 | BUS | 10 | 40x127 | 52x128 | 4 | 0 |
| 12 | COPCAR | 11 | 32x63 | 58x64 | 1 | 2 |
| 13 | DART | 12 | 30x58 | 58x58 | 14 | 3 |
| 14 | EDSEL | 13 | 30x62 | 54x62 | 9 | 2 |
| 84 | EDSELFBI | 13 | 30x62 | 54x62 | 1 | 2 |
| 16 | FIAT | 14 | 32x56 | 62x56 | 14 | 6 |
| 17 | FIRETRUCK | 15 | 40x123 | 58x124 | 0 | 7 |
| 18 | GRAHAM | 16 | 34x63 | 54x64 | 20 | 2 |
| 19 | GT24640 | 17 | 30x63 | 54x64 | 9 | 3 |
| 21 | GTRUCK | 18 | 36x86 | 52x86 | 6 | 7 |
| 22 | GUNJEEP | 19 | 26x47 | 42x48 | 0 | 2 |
| 23 | HOTDOG | 20 | 44x86 | 58x88 | 0 | 8 |
| 24 | HOTDOG_D1 | 20 | 44x86 | 58x88 | 0 | 99 |
| 25 | HOTDOG_D2 | 20 | 44x86 | 58x88 | 0 | 99 |
| 26 | HOTDOG_D3 | 20 | 30x58 | 58x88 | 0 | 99 |
| 85 | HOTDOG_D4 | 20 | 46x81 | 58x88 | 0 | - |
| 27 | ICECREAM | 21 | 44x86 | 58x88 | 0 | 8 |
| 28 | ISETLIMO | 22 | 26x78 | 48x78 | 1 | 4 |
| 29 | ISETTA | 23 | 26x44 | 50x46 | 17 | 6 |
| 30 | JEEP | 24 | 26x47 | 42x48 | 0 | 3 |
| 31 | JEFFREY | 25 | 26x61 | 46x62 | 11 | 5 |
| 86 | KRSNABUS | 26 | 38x100 | 44x100 | 0 | 0 |
| 32 | LIMO | 27 | 32x111 | 60x112 | 5 | 4 |
| 33 | LIMO2 | 28 | 32x109 | 56x110 | 5 | 4 |
| 34 | MEDICAR | 29 | 32x95 | 62x114 | 0 | 4 |
| 35 | MERC | 30 | 32x64 | 38x64 | 13 | 2 |
| 36 | MESSER | 31 | 24x53 | 38x56 | 17 | 6 |
| 37 | MIURA | 32 | 32x62 | 62x64 | 11 | 3 |
| 38 | MONSTER | 33 | 38x57 | 58x58 | 7 | 2 |
| 39 | MORGAN | 34 | 32x58 | 48x60 | 18 | 3 |
| 40 | MORRIS | 35 | 30x58 | 56x58 | 15 | 2 |
| 41 | PICKUP | 36 | 34x64 | 58x64 | 13 | 3 |
| 42 | RTYPE | 37 | 28x64 | 60x64 | 13 | 2 |
| 44 | SPIDER | 38 | 32x62 | 54x62 | 14 | 2 |
| 45 | SPRITE | 39 | 28x56 | 60x56 | 14 | 3 |
| 46 | STINGRAY | 40 | 30x62 | 52x62 | 13 | 2 |
| 47 | STRATOS | 41 | 32x63 | 60x64 | 14 | 3 |
| 48 | STRATOSB | 42 | 32x63 | 60x64 | 14 | 3 |
| 49 | STRIPETB | 43 | 32x64 | 64x64 | 16 | 2 |
| 50 | STYPE | 44 | 36x64 | 56x64 | 18 | 2 |
| 51 | STYPECAB | 45 | 36x64 | 56x64 | 0 | 3 |
| 52 | SWATVAN | 46 | 40x83 | 64x98 | 1 | 8 |
| 53 | T2000GT | 47 | 30x62 | 50x64 | 13 | 3 |
| 54 | TANK | 48 | 46x81 | 46x82 | 0 | 9 |
| 55 | TANKER | 49 | 40x128 | 40x128 | 0 | 0 |
| 56 | TAXI | 50 | 34x64 | 60x64 | 0 | 2 |
| 57 | TBIRD | 51 | 30x64 | 60x64 | 19 | 3 |
| 58 | TOWTRUCK | 52 | 40x79 | 58x80 | 0 | 8 |
| 59 | TRAIN | 53 | 42x128 | 48x128 | 0 | 0 |
| 60 | TRAINCAB | 54 | 42x128 | 42x128 | 0 | 0 |
| 61 | TRAINFB | 55 | 42x128 | 44x128 | 0 | 0 |
| 62 | TRANCEAM | 56 | 28x64 | 54x64 | 10 | 3 |
| 63 | TRUKCAB1 | 57 | 40x63 | 64x64 | 15 | 1 |
| 64 | TRUKCAB2 | 58 | 42x64 | 64x64 | 15 | 1 |
| 65 | TRUKCONT | 59 | 42x128 | 42x128 | 8 | 0 |
| 66 | TRUKTRNS | 60 | 42x128 | 40x128 | 6 | 0 |
| 67 | TVVAN | 61 | 42x72 | 58x74 | 6 | 8 |
| 68 | VAN | 61 | 42x72 | 58x74 | 6 | 8 |
| 69 | VESPA | 62 | 32x56 | 54x56 | 16 | 6 |
| 70 | VTYPE | 63 | 34x64 | 58x64 | 12 | 2 |
| 71 | WBTWIN | 64 | 32x64 | 56x64 | 11 | 3 |
| 72 | WRECK0 | 65 | 40x128 | 40x128 | 0 | - |
| 73 | WRECK1 | 66 | 40x64 | 40x64 | 0 | - |
| 74 | WRECK2 | 67 | 34x62 | 34x62 | 0 | - |
| 75 | WRECK3 | 68 | 32x63 | 32x62 | 0 | - |
| 76 | WRECK4 | 69 | 32x107 | 32x110 | 0 | - |
| 77 | WRECK5 | 70 | 25x61 | 26x62 | 0 | - |
| 78 | WRECK6 | 71 | 24x44 | 24x46 | 0 | - |
| 79 | WRECK7 | 72 | 36x106 | 36x112 | 0 | - |
| 80 | WRECK8 | 73 | 40x72 | 40x74 | 0 | - |
| 81 | WRECK9 | 74 | 56x81 | 46x82 | 0 | - |
| 82 | XK120 | 75 | 32x64 | 52x64 | 18 | 3 |
| 83 | ZCX5 | 76 | 32x63 | 50x64 | 11 | 2 |

## 5. What the sprite size feeds (keep it)

Two boxes per sprite (V):

| Box | Field | Filled from | Used for |
|---|---|---|---|
| collision body | `Sprite+0xC` | `Sprite_SetBoundsSize` 0x4BCB90: cars `CarInfo.w/h`, peds constants, objects their prefab | collision grid, walls, bumps; never the sprite entry |
| draw box | `Sprite+4` frameBounds | `Sprite_EnsureSpriteBounds` / `Sprite_ResizeToFrame` 0x4BAFD0 = sprite w,h / 64 | the quad; also z-layer (`Sprite_ClassifySlopeOverlap` 0x4BD290), skid placement, trailer search |

Other readers of the sprite entry w/h: `Car_IsFrameWidthChanged` 0x423310 (crusher capture), `Car_ShrinkFrameBounds`
0x4233B0, `ObjectPrefab_SetDefaultBoxFromSprite` 0x487FA0 (world objects' collision box), `Sprite_AddSpriteShrinkClamped`,
HUD and text layout (V).

**Rule: never change the sprite entries (SPRX w/h, SPRG pixels) the game loads.** An HD sprite is "same logical w x h,
k times the pixels", swapped only in the renderer. The quad on screen is not w/64 in general (jump scaling, MINI_CAR
scale, shrink, the stretched wreck), so the host keeps the game's corners and only changes the texel density: UVs arrive
in source texels, normalise them by the logical w/h (`GbhTexture.width/height` is that size for every handle).

## 6. Live check: the probe

`gta2ctl sprites on` installs nothing new: the C32 detour on `Sprite_Draw` (`host/c32/sprite_probe.c`, entry bytes
`sub esp, 0xA4`) is always there and publishes `struct c32_sprite_tag` (`c32_abi.h`) while the original runs; with the
probe on, the host's `draw_prim` pairs each textured quad with that tag and hashes the texture's 8-bit pixels plus the
physical palette id (`host/c/sprite_probe.c`). Off, the cost is one byte test per sprite.

Run 2026-10-25 (Downtown, 1076 frames on foot and in a car, three spawned cars; L):
- 15 702 `Sprite_Draw` calls, 32 736 tagged quads, 214 644 untagged (tiles, HUD).
- 430 distinct keys (cars 109, peds 289, code objects 32), **0 conflicts**: every key always came with the same pixels and
  palette, including car slot textures whose handle content changes. This is the property the HD design rests on.
- Shadow quads hashed equal to their body quad for every key; lamp overlays (second non-shadow quad) are their own key.
- A car whose mask has no lamp bit draws no overlay (sprite 1 with mask 0).

Not exercised yet (U): `shrink > 0`, wrecks, the EMERG ped block, armed peds, light mode 2.

## 7. Recommended hook design

Options for telling the renderer which sprite a quad is:
1. **C32 tag on `Sprite_Draw` (recommended).** What the probe does: the detour writes the key into a C32 export, the
   host reads it in `gbh_DrawQuad`. It covers static textures, car slots and the scratch texture alike (the shrink value
   comes with the key, so the HD texture can be cropped by `shrink * k`), costs one 20-byte write per sprite and no mode
   switch (C32 runs in the game's segment; the host only reads memory). (Cost not measured, U.)
2. **Host-only reverse map (H1's option A).** In `gbh_RegisterTexture` record handle -> (w, h, pixels, palette); after a
   style load walk `TextureCache.textureTables` to map handle -> (table, spriteId, remap) and the 48
   `carSpriteTextures` -> slot; at draw time a slot handle reads `g_CarSpriteCache` entry `slot`. No game hook at all, and
   it also covers HUD/frontend sprites drawn outside `Sprite_Draw`. But it depends on six heap layouts, cannot name a
   scratch (shrunk) texture, and does not know the owner.
3. Replacing `TextureCache_GetSpriteTexture` and the slot path with our own handles per (sprite, remap, mask): means
   re-implementing the delta pipeline. Not recommended.

Recommended: 1 for world sprites (peds, cars, objects), with 2's register-time map added later for HUD/font sprites if
those get HD art. Concretely:
- **Key**: (spriteType, spriteId, paletteKind, remap) + for cars the delta mask and the pass (body / lamp overlay, the
  overlay's mask = original mask AND `g_CarDeltaLightMask`) + shrink. Peds: (frame 0..473, remap 0..52 or none).
- **Lookup**: HD texture for (type, id) in the base palette. Recolour for remaps: store the HD art as palette indices (or
  an index map next to the RGBA) and apply the remap's 256-colour palette, since remaps are full palettes (§2).
  Per-(sprite, remap) RGBA overrides are affordable for cars (656 (sprite, remap) pairs in wil), not for peds (474 x 53).
- **Cars with deltas**: compose base HD + one HD overlay per delta record in ascending bit order like
  `CarSpriteCache_ApplyDeltaMask` (bits 22..31 = record n - 17 mirrored), erase = alpha 0 inside the record region;
  cache composites by (sprite, palette, mask), invalidate on `CarSpriteCache_InvalidateAll` and on style reload.
- **Geometry**: unchanged; UV scaled by hd/logical; index 0 = transparent, because the shadow quad reuses the texture.
- **Fallback**: no HD art for a key -> the game's texture, untouched.

## 8. Open

- Live coverage of shrink/wreck, EMERG peds, armed peds (the probe can do it; needs a scripted run with weapons).
- `CarSpriteCache_GetOrCreateCarSpriteSlot` 0x44B0C0 prototype (looks like thiscall, ECX = &deltaMask, 4 stack
  out-params; U).
- Bits 19..21 and the per-model meaning of bits 11..18 for models not read.
- HUD / frontend / font sprites (`DrawSprite2D`, `DrawGTAText`): not part of this phase.
