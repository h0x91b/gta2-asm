# Custom cars in ambient traffic: what a car model is made of, and how traffic picks one

What it takes to put our own car models into normal city traffic (dream 2 of [dreams.md](dreams.md)): every table sized
by the model count, everything a model owns, how traffic chooses a model, and the replace-vs-append decision with the
tooling it needs. Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`), every name is in the Ghidra DB
and in `re/`. Marks: (V) read in code and checked from a second angle, (L) measured live, (U) hypothesis. Sources: Seq
27 phase 2, sub-agents C1 (limits, per-model tables, hard-coded ids), C2 (traffic picker), C3 (model -> assets,
tooling), plus a live probe of `Car_GetPhysicsModel` (§4).

Short answer: replacing a plain civilian model in place is almost a pure art swap (sprite + CARI fields), works with
the vanilla code and spawns exactly as often as the model it replaces. Appending a new id (88..254) is also possible
without code changes, but needs a writer for four files. Either way **ambient traffic drives with the physics row of
model 24**, not the car's own `nyc.gci` row (§4).

## 1. Model ids and their limits

A model id is `CarInfo.model` (byte 0 of a CARI record), `Car.carModel` (+0x84, a dword) and byte 0 of a `nyc.gci`
record (V).

- Shipped: 83 models, ids 0..86 except **9, 15, 20, 43**; identical CARI in wil, ste and bil (V, data). Records are not
  in id order (84, 85, 86 follow 14, 26, 31). 77 car sprites (0..76).
- Ids 24, 25, 26, 85 are physics-only rows (rating 99, wreck 99, never spawned); 72..81 are the wreck models
  (`Car_BecomeWreck` 0x427B60 uses model `72 + CarInfo.wreck`, sprites 65..74).
- Code limit: every per-model table has 256 slots indexed by the id byte (§2), so ids up to 254 work. 255 terminates
  the RECY list; 256 records would wrap the u8 `totalCars` (V).
- **87 (0x57) is reserved**: it means "no model" or "any model" in at least 8 places: `CarManager_PickTrafficModel`
  0x424980 (none and the gang category), `Car_Ctor` 0x4267B0, `CarManager_Ctor` 0x428FA0 (`suppressedModel`),
  `Car_Explode` / `Car_OnWrecked`, `PlayerScore_OnPedKilled`, `Script_Op_START_BONUS_CHECK`,
  `ComboList_FindMatchingEntry` (wildcard), `PoliceRadio_QueueCarDescription` (V). A real model 87 would silently
  vanish from traffic and match every combo.
- Ids >= 128 break only two script ops, `Script_Op_CHECK_CAR_MODEL` 0x47A4E0 and `..._AND_REMAP` 0x47A5A0, which read
  `Car+0x84` with `MOVSX byte` (V, disassembly).
- Free ids: 9, 15, 20, 43 (no CARI record, no `car<N>` text key) and 88..254.

## 2. Tables sized by the model count

| Table | Where | Element | Capacity | Index | Filled by |
|---|---|---|---|---|---|
| `AllCarsInfo.cars` | `StyleData+0x5C` (1028 B block) | `CarInfo*` | 256 + u8 `totalCars` @+0x400 | model id | `StyleData_ParseCarInfoChunk` 0x4C0410 |
| CARI raw records | `StyleData+0x58` | 0xE + remaps + 1 + 2 x doors | chunk | file order | `StyleChunk_CARI` 0x4C0580 |
| RECY | `StyleData+0x64`, size u16 @+0x68 | u8 | chunk (sorted, 255-terminated) | set | `StyleChunk_RECY` 0x4C0010 |
| `CarModelTable.physicsData` | `g_CarModelTable` 0x5E5488 +0, block +0x400 | `CarPhysicsData*` (0x2C B) | 256 slots, block = `totalCars` | model id | `CarModelTable_BuildPhysicsData` 0x432EA0 |
| `CarModelTable.engineData` | +0x404, block +0x804 | `CarEngineData*` (0x48 B) | 256 slots, block = `totalCars` | model id (record byte 0) | `CarEngineData_LoadGci` 0x432D10 |
| traffic lists good / average / bad | 0x5E44A0 / 0x5E4098 / 0x5E48A0 (counts 0x5E408C / 0x5E4090 / 0x5E4498) | u32 model | 256 each (spacing; U) | weight slots | `CarManager_BuildTrafficModelLists` 0x420A10 |
| `PlayerScore.carModelFlags` | `PlayerScore+0x8C` | u8 | 256 | model id | `PlayerScore_RecomputeCarModelFlags` 0x4B75B0 |
| `car<N>` text | `.gxt` key, `GetCarModelName` 0x41F700 | text | any | model id | e/f/g/i/s.gxt (83 keys each) |
| car sprite delta cache | `g_CarSpriteCache` 0x5E85C0 | 0x14 B entry | 48 (32 of 64x64, 16 of 64x128) | (sprite, palette, mask) | [sprites-hd.md](sprites-hd.md) §3 |

Getters `CarModelTable_GetEngineData` 0x4327E0 / `GetPhysicsData` 0x432800 mask the id with 0xFF and do not check for
NULL: an id with a CARI record but no GCI record crashes the first time its row is read (V). There is no per-model
sound table: sound is chosen by `switch` on the id (§3.4).

## 3. Everything one model owns

### 3.1 CARI record (per `.sty`, identical in the three shipped styles)

Checks in `StyleData_ParseCarInfoChunk`: <= 256 records, w/h <= 0x80, num_remaps <= 0x40, sprite flag 0/1, doors <= 5
(`DisplayError` otherwise; V). Fields and consumers (V):

| Field | Consumers |
|---|---|
| model (+0) | key of `cars[]`, `StyleData_GetCarInfo` 0x4BF1F0 (32 call sites) |
| spriteIndex (+1) | file flag "new sprite", rewritten at load to the accumulated sprite id: **sprite id = number of earlier flag-1 records (file order)**; flag 0 = share the previous record's sprite. `CarManager_SpawnCar` 0x426AC0, `Car_BecomeWreck`, `Car_ShrinkFrameBounds` |
| w, h (+2, +3) | logical size in px (/64 = blocks): collision body (`Sprite_SetBoundsSize` in SpawnCar), inertia, sweep steps, steer assist, model box. The sprite's pixel size is larger (room for doors and mirrors) |
| num_remaps (+4), remap[] (+0xE) | `Car_PickRandomRemap` 0x422020 (num_remaps + 1 outcomes, the extra one = base art), `Car_NeedsRemapChange` 0x421F40 (no respray for 0 or 1 remaps) |
| passengers (+5) | `Car_GetPassengerCapacity` 0x41FBB0: a count, no seat positions |
| wreck (+6) | wreck model `72 + wreck`; 99 = never wrecked |
| rating (+7) | traffic tier and weight (§5); 99 = never in traffic |
| wheel offsets (+8, +9) | `CarPhysicsData_Build` 0x432AA0 |
| window offsets (+0xA, +0xB) | `Car_SpawnDamageFireEffect` 0x4226C0 only |
| info_flags (+0xC), info_flags_2 (+0xD) | trailer, roof lights (4), roof decal (64), for-hire lights (32), artic cab (8), collide-over, popup lamps (`Car_UpdatePopupLightsAnim` 0x423C30) |
| doors[] (rx, ry, /64) | `Car_InitDoors` 0x423AA0, door world positions, ped boarding, door sounds. Door i gets delta base `g_CarDoorDeltaBaseIds` 0x591E74 = {7, 24, 11, 28}. **`Car_InitDoors` has no clamp at 4** while CARI allows 5: a 5th door writes into `Car.next` (+0x4C). Practical cap: 4 doors |

### 3.2 Sprite, palettes, deltas (`.sty` SPRX, SPRG, SPRB, PALB, PALX, PPAL, DELX, DELS)

- Sprite: one car-category sprite (car base 0). Texture tables are registered eagerly from StyleData counts right after
  the style load (`TextureCache_RegisterAllTextures` 0x4C30A0), so any StyleData change before that call reaches
  every derived table (V).
- Palettes: the 77 car sprites use only 7 physical base palettes (wil: 30 for most); the 37 car remaps are full
  palettes (physical 167..202 plus 42) that differ from base palette 30 at >= 253 of 255 indices. **New art must be
  quantised to the vanilla car base palette** (physical 30) for the 37 remaps to recolour it the way they recolour
  vanilla cars (V measured; the "art convention" reading is U).
- Deltas are **optional**: `StyleData_GetSpriteDeltaRecord` 0x4BF230 returns 0 for a sprite without records and
  `CarSpriteCache_ApplyDeltaMask` 0x44AEA0 skips it. A car without DELX records drives fine but shows no dents, lamps
  or door animation. Record layout and bit meanings: [sprites-hd.md](sprites-hd.md) §3.
- **Hard size limit**: a car sprite that ever gets a delta mask must be <= 64 wide and <= 128 high. The cache slots are
  64x64 / 64x128 regions of one buffer with no size check: a wider sprite overwrites the neighbour slot (V, from the
  `CarSpriteCache_Ctor` 0x44B000 pointer arithmetic; not tested live). Shipped maximum is 64x128.

### 3.3 Physics (`nyc.gci`)

`CarModelTable_Load` 0x432FC0 runs last in `LoadGMP_and_STY_Files` 0x45B469: `CarEngineData_LoadGci` 0x432D10 parses
the text file (comments `{...}`, tokens `[-][b|w|l|f][h][-]digits`, decimals truncated to Fix16), one 0x48-byte record of
4 byte tokens + 17 Fix16 tokens per model (field list: [car-physics.md](car-physics.md) §5 `CarEngineData`). **The
record count must equal `totalCars`** (errors 0x7DE / 0x7E2 / 0xBC5); records are keyed by their model byte. Then mass x
1.1 and `CarPhysicsData_Build` per id (V). One `nyc.gci` serves all districts.

### 3.4 Sound and name

- Name: `GetCarModelName` 0x41F700 = `Gxt_FindTextW("car%d", model)`; e/f/g/i/s.gxt each hold exactly 83 keys (car9,
  car15, car20, car43 missing). A new id needs a key in every language file, else a blank name.
- Sound: hard-coded `switch`es on the id with defaults (V): engine loop `CarModel_GetEngineLoopSample` 0x410E20 (default
  sample 3), horn `CarModel_GetHornSample` 0x410F00 (0x10) and `GetHornBaseFreq` 0x410FC0 (22050 Hz), siren
  `CarModel_GetSirenSample` 0x410EE0, `CarModel_IsHeavyVehicle` 0x411120, door samples; `SoundMgr_UpdateCarSource`
  0x415DF0 has special paths for 0x36, 0x3C and doors-only for 6, 0x3B, 0x3D. A new id gets the defaults; a different
  engine sound needs a code hook. Engine pitch comes from the physics row's GCI record.

## 4. Traffic cars use the physics row of model 24

`Car_GetPhysicsModel` 0x4220A0 decides, every time physics needs a row, which model's GCI / `CarPhysicsData` a car uses
(callers `CarPhysics_SelectModelData`, `SelectEngineData`, `SelectPhysicsData`, `Car_GetModelInertia`,
`CarPhysics_Update`; V, disassembly; the decompiler hides the branch):

| Driver / state | Row |
|---|---|
| non-player driver, a train (`IsCarATrain` 0x403BA0) | own |
| non-player driver, no drive order or `driveOrder->followRoadActive` (+0x22) set (= all road traffic) | **24** (HOTDOG_D1); **85** for the tank 54 |
| non-player driver, direct drive order: COPCAR, GUNJEEP, JEEP, SWATVAN, EDSELFBI | 25; tank 85; others own |
| player or no driver, scale < `CarsScale` (MINI_CAR) | 26 |
| player or no driver, TRUKCAB1/2 with or without trailer | 0x3F / 0x40 swapped |
| player or no driver, anything else | own |

Live (L, 2026-10-26, a throwaway midhook at the two exits 0x4220EE / 0x42213B, Downtown ~1000 frames): every driven
traffic model (0, 1, 4, 5, 8, 12 cop, 13, 18, 36, 38, 50, 53, 56, 63, 68, 69) took row 24 every time; only the trains
59/60 and model 1 after the player got in used their own row.

Readers of the car's **own** row regardless (V): `Car_GetMaxSpeed`, `Car_GetMass`, `Car_GetAntiStrength` (damage),
`Car_GetValueTimes1000`, `PlayerScore_GetCarValue`. Collision size and sprite always come from the own CARI.

Consequence: a custom model's handling (`nyc.gci`) shows only when the player drives it or it is parked/pushed; in
traffic it drives like every other AI car, with its own collision box. To give AI cars their own handling a code hook
on `Car_GetPhysicsModel` is needed (a one-line C32 detour).

## 5. How traffic picks a model

At level load `CarManager_BuildTrafficModelLists` 0x420A10 (only caller `LoadGMP_and_STY_Files` at 0x45B5D1) walks ids
0..255 and keeps a model if it has a CARI record and, in single player, is in the style's **RECY** list
(`StyleData_IsCarModelAllowed` 0x4BFFE0: `while (list[i] < model) i++; return list[i] == model`, so the list must be
sorted ascending and end with 255; a missing chunk allows everything; multiplayer skips the test). Then by
`CarInfo.rating`: 1..9 bad list, 10..19 average, 20..29 good, `rating % 10` copies (the weight), 99 never. Shipped
ratings are only 1, 11, 21, 99 (weight 1). Ratings 30..98 hit a stale-register bug (the tier comes from DI): never use
them (V).

RECY (V, raw chunks): wil 0,1,2,4,5,8,13,18,27,28,36,38,43,50,53,56,63,67,68,69 (43 has no CARI record); ste
4,8,14,16,23,32,35,36,38,39,40,44,45,49,50,51,57,62,64,67,68,83; bil 0,4,7,13,14,16,18,21,23,31,33,38,40,44,46,50,51,63,
67,68,69,71,82.

Per spawn, `CarManager_PickTrafficModel` 0x424980 (from `TrafficSpawner_TrySpawnSide` 0x4B34E0; V):
- pacing: a spawn credit against `100 - chance%`, chance from the zone density and `g_trafficDensityScale` 0x66C460
  (screen area and a wanted-level factor);
- roll 0..999 from the shuffle table against the current zone's `MapZoneInfo` {density, good, bad, police, gang}
  (`.gmp` ZONE info, editable by `SET_ZONE_*_INFO` script ops; defaults 500/300/300/100/0): good list, bad list,
  police (COPCAR 12, replaced by FBI 84 / army 22 by the highest crew type, army may pick APC 3 / TANK 54 / JEEP 30),
  gang (the zone gang's `carModel` +0x13C and `carRemap`, from the `.scr` gang declaration; wil Yakuza 37, Zaibatsu
  70), else the average list;
- inside a list: round robin (`CarManager` cursors +9/+0xA/+0xB), skipping `suppressedModel` (script
  `SUPPRESS_THIS_CAR_MODEL`); the remap comes from `Car_PickRandomRemap`.

Not from the picker: parked and mission cars (model in the `.scr`: `PARKED_CAR_DATA` 0x477530, `CAR_DATA_SET`
0x477290), roadblocks, emergency vehicles, buses (11, rating 99) and trains (59..61) with hard-coded ids.

Live census (L, C1 and C2, Downtown, 145 and 102 distinct cars): every driven car was in wil's RECY except bus 11, cop
12, traincab 60 and the gang cars 37 / 70. Models 1 and 28 were not seen in C2's sample (a sample, not a proof).

Side effect: a model added to a district's RECY becomes **required** for that district's "steal every car" (30 000) and,
if its wreck is not 99, "destroy every car" (50 000) bonuses (`PlayerScore.carModelFlags`; V).

## 6. Hard-coded model ids (do not replace these unless the role should stay)

| Ids | Role, by id | Where (examples) |
|---|---|---|
| 12 COPCAR, 52 SWATVAN, 84 EDSELFBI | police (`Car_IsPoliceModel` {12, 52, 84}), siren, busted transport | `CarManager_PickTrafficModel`, `EmergencyVehicleSlot_Update`, `PoliceRoadblock_Create` |
| 34 MEDICAR, 17 FIRETRUK | emergency services, lights, water gun | `Car_AttachEmergencyLights` 0x424700, `FireEngineSlot_Update`, `CarManager_SpawnCar` |
| 56 TAXI, 51 STYPECAB | taxi behaviour | `Car_IsTaxiModel` 0x4217F0 |
| 11 BUS | bus routes, lane change, thieves | `PublicTransportManager_*`, `CarAI_TryLaneChange` |
| 59, 60, 61, 6 | trains | `IsCarATrain` 0x403BA0, rail spawn, own physics row |
| 54 TANK, 22 GUNJEEP, 30 JEEP, 3 APC, 4 BANKVAN, 7 BOXTRUCK | turrets, guns, roadblocks, army crews | `CarManager_SpawnCar`, `Car_IsBlastImmune`, `Car_GetPhysicsModel` |
| 63, 64, 65, 66 | articulated cabs and trailers | `Car_GetPhysicsModel` swap, `CarManager_SpawnArticulated` |
| 24, 25, 26, 85 | physics-only rows | §4 |
| 72..81 | wrecks | `Car_BecomeWreck` |
| 67 TVVAN, 19 GT24640 | TV van, race numbers | `CarManager_SpawnCar`, `Car_SetNumberGraphic` |
| 1 | default gang car | `InitGangRespect` |
| 87 | sentinel | §1 |

Plain civilians with no special code and in wil's RECY (candidates for option a): 0 ALFA, 2 AMDB4, 5 BMW, 8 BUG,
13 DART, 18 GRAHAM, 36 MESSER, 50 STYPE, 53 T2000GT, 68 VAN, 69 VESPA (C1 and C3; check the sound class of the
chosen one). Mind shared sprites: replacing VAN's sprite 61 also changes TVVAN 67, DART is fine (sprite 12 is its own).

## 7. Replace in place vs append

| | (a) replace model X | (b) append id N (88..254 or 9/15/20/43) | (c) clone (flag-0 record) |
|---|---|---|---|
| Files | SPRG pixels (+ SPRX w/h), CARI fields, `nyc.gci` row, `car<X>` text | CARI record, SPRX/SPRG sprite, SPRB/PALB counts, PALX entry, optional DELX/DELS, RECY in each style, `nyc.gci` record (count = totalCars), `car<N>` in 5 `.gxt` | CARI record right after X's (shares its sprite and deltas), RECY, GCI, text |
| Code changes | none | none (sound defaults) | none |
| Traffic frequency | X's (RECY + rating unchanged) | set by rating + RECY placement | same as (b) |
| Keeps | everything id-keyed of X: sound class, wreck, scripts that spawn X, steal/destroy bonus slot | nothing; defaults | nothing but X's art |
| Risk | X's special code (pick a plain civilian, §6) | the 9-step writer must keep five chunk indices consistent | sprite sharing only by file order |

Tooling options:
1. **File writers through our VFS (recommended).** `.sty` CARI + sprite + palette + delta appender, a `nyc.gci` writer,
   `gxt --import` (exists). The game's own loaders validate and every derived table (textures, palettes, deltas,
   physics, traffic lists) rebuilds by itself. The TS decoders already parse every chunk involved, so a round-trip test
   is cheap. Needs a mod layer in `host/c/vfs.c` (e.g. `--mod=DIR` before the overlay) so a mod does not overwrite the
   shared overlay (U, design).
2. Runtime injection from C32: after the style load and before `TextureCache_RegisterAllTextures` patch SPRX, SPRB,
   PALB, PALX, the delta index and RECY in `StyleData`; after `CarModelTable_Load` set `cars[N]` (not earlier:
   `CarModelTable_BuildPhysicsData` would write past its `totalCars`-sized block), allocate its GCI and physics rows,
   re-run `CarManager_BuildTrafficModelLists`. Feasible, but re-implements the loader's index maintenance by hand and
   every missed cache is a silent wrong draw (V on the paths read, never run).

Recommendation: start with (a) on a plain civilian (an art swap plus CARI edits, no new tooling beyond a sprite
writer), then (b) with the file writers; C32 only for what files cannot express: the sound switches, own handling for
AI cars (`Car_GetPhysicsModel`), and any id-keyed behaviour wanted for a new id. HD art for the new sprite plugs into
the dream-1 key (sprite id, remap) unchanged.

## 8. Open

- Live: a sprite wider than 64 px with a delta (the slot overflow), a CARI id without a GCI record (crash), rating 30+.
- The `value` byte's consumers, `info_flags` bit 1 (`ped_jump`), whether bonus levels (`bob_*.gxt`) need car keys.
- The traffic list capacity is inferred from array spacing (256), not from an allocation.
