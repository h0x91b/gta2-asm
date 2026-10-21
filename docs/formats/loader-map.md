# GTA2 loader map — file format → reader function → in-memory struct

For each data file the game reads, and each chunk of the chunked formats: which function in
vanilla `gta2.exe` 11.44 reads it, where the bytes land, and how sure we are. Use it the other
way round too: when you meet one of these functions or globals in Ghidra, the on-disk layout in
[lessons.md](lessons.md) and `tools/formats/` tells you what the struct fields mean.

## Conventions

- Addresses are VAs in vanilla `gta2.exe` (ImageBase `0x3F0000`), 1:1 with the Ghidra program
  `gta2.segments.fixed.exe` and with `re/`.
- **Name** is the current name in the live Ghidra project `gta-2-recovered` (read on
  2026-10-21). Several of them (`delta_index`, `UNK_SPEC`, `car_recycling_info`,
  `CarEngineData_LoadGci`, `startGame`, …) are newer than the `re/` export and are not in
  `re/functions.csv` yet. `FUN_xxxxxxxx` means unnamed. Names that are wrong are flagged and
  get a proposal in [the last section](#proposed-names-for-seq-27).
- **V** = verified: I read the code (Ghidra disassembly/decompile, or `llvm-objdump` on
  `gta2.ebin` unpacked from `data.pak`) and saw it read that chunk/field into that place. The
  evidence column says what was seen. Where a size or count is involved it was also checked
  against the shipped files in `data.pak`.
- **H** = hypothesis: inferred from names, from the on-disk spec, or from a reference repo,
  not from following the code to the end.
- `this+0xNN` is a field of the object the reader is called on (`__thiscall`, ECX).
- Read-only research: nothing was renamed or commented in Ghidra and nothing under `re/`
  changed. The reference repos were not needed for any row here (everything came from the
  binary); gta2_re was not consulted.

How to re-verify a row: `mcp__ghidra__disassemble_function` / `force_decompile` on the VA, or
offline `xcrun llvm-objdump -d --x86-asm-syntax=intel --start-address=… gta2.ebin`. (The
11.44 patch code past `.text` VirtualSize, `0x56DBC0`, is invisible to objdump unless you
bump the section's VirtualSize in a scratch copy.)

## Shared plumbing

### The File module (`File.cpp`, one global FILE)

All chunked loaders (`.sty`, `.gmp`, `.gxt`, `.scr`) go through one tiny module that keeps a
single open `FILE*`. Error code + source line go to `DisplayError` (`0x450530`) with the file
name string `"File.cpp"` (`0x56E3D8`).

| VA | Ghidra name | What it does | Status |
|---|---|---|---|
| `0x403160` | `fopen` (misnamed) | `File_Open(path)`: closes a previous file, `copyScriptNameToBuffer(path)` (`0x44DBB0`, remembers the name for error messages), CRT `fopen(path, "rb")` (`0x4D68DE`, mode string `0x56E3EC`), stores `FILE*` in `0x5D25F0`, sets `0x5D25F4 = 1` | V |
| `0x402EB0` | `fclose` | `File_Close()`: `fclose(g_File)`, clears `0x5D25F4` | V |
| `0x402FB0` | `fread` (misnamed) | `File_Read(void *dst, uint *size)`: reads exactly `*size` bytes or errors (code `0xF`) | V |
| `0x403000` | `readChunkHeader` | `File_TryRead(void *dst, uint *size)`: same, but returns `false` at EOF instead of failing — used for chunk headers, which is how every chunk loop ends | V |
| `0x402F60` | `FUN_00402f60` | `File_Skip(uint *size)`: `fseek(g_File, *size, SEEK_CUR)`. The default branch of every chunk dispatcher: unknown chunks are skipped by size | V |
| `0x403040` | `File_ReadAll` | `File_ReadRest(dst, uint *max)`: reads from the current position to EOF, errors `0x3FE` if that is more than `*max`, returns the byte count | V |
| `0x402980` | `fread` | low-level read loop under the above | V (called) |
| `0x460EE0` | `FUN_00460ee0` | `Header_CheckMagic(expected)`: `strncmp(this, expected, 4)`, error `0x5D` | V |
| `0x460EC0` | `FUN_00460ec0` | `Header_CheckVersion(u16)`: compares `this+4`, error `0x5E` | V |

Allocation helpers used by the readers: `0x4059B0` (`malloc`, error on NULL) and `0x4059F0`
(named `malloc` too, really `malloc_aligned64k(size, void **raw)`: allocates `size+0x10000`,
stores the raw pointer for `free`, returns it rounded up to a 64 KB boundary — the big style
pages are 64 KB aligned). `0x4D5DCA`/`0x4D6CCC` are `operator new`, `0x4D630A` `operator delete`.

Chunk tags are **not** compared as 32-bit immediates in this build: every dispatcher calls
`_strncmp(tag, "XXXX", 4)` (`0x4D7AB0`) against `.rdata` strings, so the tag strings show up in a
string search (`"PALB"` … at `0x575460`–`0x5754D8`, GMP tags at `0x573C54`–`0x573C7C`, `"TKEY"`
`0x57554C`, `"TDAT"` `0x575544`). `"GBMP"` is absent because the map header is never checked
(see below).

### Who builds the paths, and the open path down to our shims

The current level's file names live in the `Menu` object at `0x5EC070` (`ptrToMenu`, size
1400): four 256-byte slots.

| Slot | Getter | Setter | Holds | Status |
|---|---|---|---|---|
| `+0x000` | `0x45E4E0` `getGmpPath` | `0x45E410` | `data\wil.gmp` | V |
| `+0x100` | `0x45E4F0` `GetStyFilePath` | `0x45E430` | `data\wil.sty` | V |
| `+0x200` | `0x45E500` `GetStyPath2` (misnamed: it is the **.scr** path) | `0x45E450` | `data\wil.scr` | V |
| `+0x300` | `0x45E510` | `0x45E470` | save-game name, empty for a new game | V |

Writers of those slots (xrefs to the setters, all V):

- **`.seq` (single player).** `FUN_00455340`, called from `InitFrontend` (`0x456A60`):
  `FindFirstFile("data\*.seq")` (error `0x98` if none, `0x99` if more than one), `fopen(…, "rt")`,
  reads `label = value` lines with `FUN_00452530(label_index, buf, FILE*)` (labels built inline
  from `.rdata` `0x573394`…: `MainOrBonus`, `GMPFile`, `STYFile`, `SCRFile`, `Description`),
  accepts `MAIN`/`BONUS` blocks (at most 3 MAIN, 3 BONUS per MAIN) and stores each entry with
  `FUN_004527A0` into the FrontEnd's level table. `FUN_004556A0` later copies the chosen
  entry into the Menu slots (it calls all four setters). V for the parse loop and limits; the
  layout of the FrontEnd level table is **H**.
- **Debug registry override.** `FUN_0045E8D0`: `regGet("mapname" / "stylename" /
  "scriptname" / "savename")`, prefixed with `data\`; defaults `data\jointmap.gmp`,
  `data\style.sty`, `data\q.scr`. V.
- **Multiplayer.** `FUN_004D0ED0`: after connecting, `wsprintf("data\%s", …)` with the
  map/style/script names from the session; `FUN_00407930` reads them from the `.mmp` ini,
  `GetPrivateProfileStringA("MapFiles", "GMPFile"/"STYFile"/"SCRFile", …)`. V.
- **Replays.** `Replay_ReadHeader` (`0x45F270`) sets all four. V (xref only).

The actual load sequence is **`LoadGMP_and_STY_Files` (`0x45B469`)**, called from `InitGame`
(`0x461DE0`, call at `0x46201D`). Its first instruction (`mov byte [0x676204], 1`) is from the
11.44 patch, which is why the function starts at an odd address. In order (V, disassembly):

1. `LoadGXT(g_LocaleSettings)` — `.gxt`.
2. unless the byte `0x5EAD72` is set (H: the debug `skip_audio` flag): `0x410550(GetStyFilePath())` — loads the
   district **sound bank** named after the style (`wil.sty` → `data\audio\wil.sdt/.raw`).
3. `LoadSty(g_StyleData, GetStyFilePath())`.
4. `LoadMAP_GMPFile(g_MapBlocks, getGmpPath())`.
5. `0x489530` on `g_ObjectPrefabsContainer`, `relToGBHGraphic` (`0x4C30A0`) on
   `g_TextureCache` (post-load passes, not traced).
6. `loadScript(g_MissionScript, GetStyPath2())` — `.scr`.
7. if the save slot is non-empty: `FUN_0047F0B0(g_MissionScript, save path)` — the save file.
8. `CarModelTable_Load(g_CarModelTable, path)` — `nyc.gci` (path `0x676EEC`, default
   `data\nyc.gci`; the 11.44 patch can override it, see GXT below).

The frontend uses a fixed style: `InitFrontend` calls `LoadGXT` then `LoadSty(…, "data\fstyle.sty")`
(`0x456BC2`/`0x456BD2`); `Init` (`0x457830`) loads the frontend sound bank with the same path
(`0x4578CF` → `0x410550`). V.

**Down to the host.** Every open above ends in the CRT (`fopen` → `_fsopen` → `__openfile` →
`CreateFileA`; `.seq` additionally `FindFirstFileA`), so the game never sees our pak: the Win32
shims in `host/w32_files.asm` (`CreateFileA`, `ReadFile`, `SetFilePointer`, `FindFirstFileA`,
…) resolve `data\…` through `host/w32_vfs.asm` (`vfs_find`/`vfs_read_at`) against `data.pak`,
overlay first. See `docs/win32-shims.md` ("KERNEL32 — files").

## `.sty` — style (`LoadSty`, `0x4C0820`)

`LoadSty(path)` on `g_StyleData` (`0x670684`, a `StyleData*`, 0x106C bytes, built by
`StyleData_Ctor` `0x4C08D0`): `File_Open`, read the 6-byte header, `Header_CheckMagic("GBST")`
(`0x5754E0`), `Header_CheckVersion(700)` (so DMA's documented 600 would be rejected), then loop
`File_TryRead(8-byte chunk header)`; a chunk with size 0 is skipped without dispatch, anything
else goes to **`readChunk` (`0x4C05B0`)**, a `strncmp` ladder. After the loop: `File_Close`, then
`FUN_004C0100` (post-load fixups). V.

Shipped chunk sets: `wil/ste/bil.sty` = TILE PPAL SPRB FONB DELX DELS PALX OBJI RECY SPRG SPRX
PALB CARI SPEC (SPEC is always last); `fstyle.sty` = PPAL SPRB FONB PALX SPRG SPRX PALB.

| Chunk | Reader (VA, name) | Destination | Status | Evidence |
|---|---|---|---|---|
| PALB | `0x4BFF20` `palette_base` | `this+0x10` raw counts (`PaletteBase`, 16 B); `this+0x0C` a copy turned into **bases** (exclusive prefix sum, `0x4BF7B0`); `this+0x00` (u16) = sum of the 8 counts = total virtual palettes | V | asserts size == 0x10 (error `0x409`); `0x4BF790` sums 8 u16; prefix sum in place. wil: total 3202. Note the type names are swapped: `paletteBase2` (`+0x0C`) holds bases, `paletteBase` (`+0x10`) counts |
| SPRB | `0x4BFE70` `sprites_bases` | `this+0x18` raw counts (`SpriteBase`, 12 B); `this+0x14` prefix-summed bases | V | asserts size == 0xC; `0x4BF7B0` with count 6. No total stored |
| FONB | `0x4BFDD0` `font_base` | `this+0x1C` = malloc'd chunk (u16 count, count × u16), the per-font counts prefix-summed **in place**; `this+0x02` = sum (total font sprites); then `FUN_004BFCC0(count)` | V | asserts size ≥ 2 and size == 2·count+2 (wil 16 = 7 fonts, fstyle 30 = 14). `0x4BFCC0` accepts only 7 or 14 and writes font-role ids to globals `0x670640`–`0x670680`; what each role is, **H** |
| SPRX | `0x4BFC60` `sprite_index` | `this+0x20` = malloc(size+8) holding the 8-byte entries; `this+0x04` (u16) = size/8 **+ 1** | V | count asserted ≤ 0xFFFF. Post-load (`0x4C0100`) adds `this+0x34` (SPRG base) to each entry's u32 offset → absolute pointer; it loops `count` = size/8+1 times, so the 8 spare bytes get fixed up too (harmless) |
| OBJI | `0x4BFBE0` `map_object_info` | `this+0x24` = malloc'd chunk; `this+0x06` (u16) = size/2 | V | 2-byte records (u8 model, u8 sprite count — field meaning from the DMA spec, **H**); asserts size even, count < 0x10000. wil: 24 records |
| PALX | `0x4BFB80` `palette_index` | `this+0x28` = new(0x8000) `PaletteIndex` (u16[16384]) | V | asserts size == 0x8000. wil max value 274 < 320 physical palettes |
| PPAL | `0x4BFB50` `physical_palettes` | `this+0x2C` = 64 KB-aligned buffer, `this+0x30` raw pointer (for free); `this+0x08` (u16) = size >> 10 = physical palette count (wil 320) | V | `0x4059F0` aligned alloc, `File_Read` of the whole chunk. Column-interleaved BGRA layout untouched in memory |
| TILE | `0x4BFAD0` `tiles` | `this+0x3C` = 64 KB-aligned buffer, `this+0x44` raw pointer; then `FUN_004BF7F0` | V | `0x4BF7F0` allocates `this+0x40` = u16[1024]: identity for 0…991, 0 for 992…1023. **H**: the tile-number remap table that ANIM tile animations rewrite (992 = PALB tile count) |
| SPRG | `0x4BFB20` `sprite_graphics` | `this+0x34` = 64 KB-aligned buffer, `this+0x38` raw pointer | V | whole chunk read. 256-byte stride rows as on disk |
| DELS | `0x4BFAB0` `delta_store` | `this+0x48` = malloc'd chunk (concatenated delta streams) | V | raw read |
| DELX | `0x4BFA60` `delta_index` | raw chunk to `this+0x4C` (temporary, freed and zeroed at the end); `FUN_004BF840` expands it into `this+0x50` with size `this+0x60`; `FUN_004BF980` builds `this+0x54`; post-load `FUN_004BF900` | V | on disk `{u16 sprite, u8 n, u8 pad, n × u16 len}` (4+2n). In memory `{u16 sprite, u8 n, u8 0, n × {u32 offset, u16 len, u16 pad}}` (4+8n), offsets running sums of `len`; `0x4BF900` adds `this+0x48` (DELS base) → pointers. `this+0x54` = `{u16 max_sprite+1, …, u32 entry_ptr[sprite]}` (lookup by sprite id; error `0x3EA` on a duplicate sprite). wil: DELX 2004 B |
| CARI | `0x4C0580` `car_info` | `this+0x58` = malloc'd chunk (variable-size `CarInfo` records, in place); `parseCarInfoChunk` (`0x4C0410`) builds `this+0x5C` = new `AllCarsInfo` (1028 B: `CarInfo *cars[256]` by model, u8 total at `+0x400`) | V | per record: asserts w,h ≤ 0x80, num_remaps ≤ 0x40, `sprite` ∈ {0,1}, ≤ 256 cars, door count ≤ 5 (error `0x453` + model); **rewrites `CarInfo.sprite` in place from the 0/1 flag to the accumulated sprite index**. Record length = 0xE + num_remaps + 1 + 2·num_doors |
| RECY | `0x4C0010` `car_recycling_info` | `this+0x64` = malloc'd chunk, `this+0x68` (u16) = size | V | raw read. wil: 21 bytes, car models terminated by 255 (content from data, consumer not traced) |
| SPEC | `0x4C00A0` `UNK_SPEC` | `this+0x6C` `int[1024]` (indexed by tile number) | V | **Ignores the chunk size and reads from the file itself**: `FUN_004C0040(n)` for n = 2…10 reads u16 tile ids until a 0 and stores `this[0x6C + tile*4] = n`. So SPEC = 9 zero-terminated tile lists, the list index + 2 being a surface type. Verified on data: wil/ste/bil SPEC have exactly 9 zeros, the last one at the chunk end; the chunk only works because it is last. Which n means which surface, **H** (DMA spec order) |
| PSXT | `0x4BFB10` `PSX_tiles` | — | V | `File_Skip(size)` (PlayStation tiles, not used on PC). Absent from shipped PC styles |
| OVLY | `0x4BFB00` `UNK_OVLY` | — | V | `File_Skip(size)`. Not in shipped styles |
| other | `0x402F60` | — | V | default branch skips by size |

`StyleData` fields not written by any chunk reader: `+0x6A` (byte), `+0x0A` gap — unknown.
Consumers of the sprite tables (`GetSpriteEntry` `0x4BF280`, `GetSpriteIndex` `0x4BF2A0`,
`GetCarInfoById` `0x4BF1F0`, `RegisterStylePalettes` `0x4C2970`, `GetSpriteTexture`
`0x4C2AC0`) are named in `re/` but were not traced for this map.

## `.gmp` — map (`LoadMAP_GMPFile`, `0x464990`)

`LoadMAP_GMPFile(path)` on `g_MapBlocks` (`0x662C08`, `MapBlocks*`, 0x370 bytes, built by
`MapBlocks_Ctor` `0x464A40`): `File_Open`, read the 6-byte header **without checking it** (no
`GBMP`/500 check at all — any 6 bytes pass), loop chunk headers, dispatch non-empty chunks to
**`mapSegment` (`0x464890`)**, then `File_Close`, `processS11` (`0x464980`, ZONE post-pass), and
error `0x84` if `this+0` (the DMAP grid) is still NULL — DMAP is the one mandatory chunk. V.

Shipped chunk set: CMAP DMAP ZONE [MOBJ] PSXM [ANIM] LGHT EDIT RGEN (note **EDIT**, not EDGE;
no UMAP/THSR in any shipped map).

| Chunk | Reader (VA, name) | Destination | Status | Evidence |
|---|---|---|---|---|
| DMAP | `0x4646A0` `DMAP_section` | `this+0x000` → new(0x40010) grid object (ctor `0x4630B0` zeroes the tail): `+0x00000` u32 base[256×256] (read 0x40000 B), `+0x40000` u32 column-word count, `+0x40008` → column words, `+0x40004` u32 block count, `+0x4000C` → 12-byte `block_info` array. `MapBlocks+0x358`/`+0x360` = column-word count, `+0x35C` = its capacity (count + 0x400); `+0x34C`/`+0x354` = block count, `+0x350` = capacity (count + 200) | V | limits: count+0x400 ≤ 0x20000 (error `0x467`), count+200 ≤ 0x20000 (`0x469`); asserts chunk size == 0x40008 + 4·columns + 12·blocks (`0x409`). The slack lets the game add blocks/columns at runtime (save games, `FUN_0047F0B0`). Base values stay word offsets, not pointers |
| ZONE | `0x464640` `ZONE_section` | `this+0x328` = malloc'd raw chunk; `FUN_004644E0` builds `this+0x32C` = `{u16 count, pad, u32 ptr[count]}` pointing at each record | V | record stride = 6 + byte[5] (name length) — matches `{u8 type, x, y, w, h, u8 name_len, name}`. Typed `ushort len` at `+0x32C`, really a pointer |
| (ZONE post) | `0x464980` `processS11` | `this+0x330` = u8[count] zone → info-slot index; `this+0x334` = (slots+1) × 22-byte records | V (code) / H (meaning) | only zones of type 1, 10, 15 get a slot (same name ⇒ same slot, by `strncmp` of names); each slot initialised to 11 u16 `{500,300,300,100,0,500,50,40,10,200,40}`. **H**: per-navigation-zone car/ped density info that `SET_ZONE_*_INFO` script commands edit (types 1 nav, 10 info, 15 local nav per DMA spec) |
| MOBJ | `0x464590` `FUN_00464590` | `this+0x338` = malloc'd chunk, `this+0x344` = size/6 | V | asserts size % 6 == 0 (error `0x28`). Consumer `FUN_0046A4D0` (from `startGame` `0x45B5F0`): per record u16 x, u16 y (→ fixed via `0x462ED0`), u8 rotation (`0x462EF0`), u8 object type; `FindMaxZ` for z; `SpawnObject(g_ObjectSpawner, …)`. V |
| ANIM | `0x464670` `ANIM_section` | `this+0x340` = malloc'd chunk; `FUN_00464550` walks it | V | stride = 6 + 2·byte[4] ⇒ `{u16 base, u8 frame_rate, u8 repeat, u8 anim_length, u8 pad, u16 tiles[anim_length]}`. Each record → `FUN_004C3470`: allocate from `g_TileAnimPool` (`0x671C0C`, 50 × 0x18 entries) and initialise from the record (`0x4C32A0`, `0x4C32E0`) |
| LGHT | `0x4645F0` `FUN_004645f0` | `this+0x33C` = malloc'd chunk, `this+0x348` = size/16 | V | asserts size % 16 == 0 (error `0x33`). Consumer `FUN_004692B0` (from `startGame`): per record `+0` u32 colour, `+4/+6/+8` u16 x, y, z, `+0xA` u16 radius, `+0xC` u8 intensity, `+0xD` u8 shape, `+0xE` u8 on-time, `+0xF` u8 off-time → `FUN_00469010(g_LightManager, …)`, and `FUN_00469070` (flicker) when on-time ≠ 0. Field roles from argument order + DMA spec: **H** for the exact names |
| RGEN | `0x464880` `FUN_00464880` | `g_RoadNetwork` (`0x5D351C`, `RoadNetwork`, 0xCC68 B) via `FUN_0040D250` | V | **ignores the chunk size and reads fixed sizes**: 0x2210 B → `+0x8` (`nodes[545]`, 16 B each), 0x1108 B → `+0xA830`, 0x1108 B → `+0xB938` (545 × 8 B each), u16 → `+0x4`, u16 → `+0xCC62`, u16 → `+0xCC64`; then zeroes `+0x0` (`routeCount`); debug flag `0x5EAD99` dumps the junctions. Total 0x4426 = 17446 = the RGEN size in every shipped map. What the two 545×8 arrays and three u16 are: unknown |
| CMAP, UMAP, PSXM, EDIT, EDGE, THSR | `0x402F60` | — | V | not matched by `mapSegment` → skipped by size. So the PC game ignores CMAP (it only uses DMAP) and the PSX/editor chunks |

## `.gxt` — text (`LoadGXT`, `0x4C2540`)

On `g_LocaleSettings` (`0x671550`, `LocaleSettings`; language char at `+0x10`, from registry
`language`, see `LocaleSettings_Ctor` `0x4C2620`). `sprintf(strPathToGXT /*0x676CD8*/,
"data\%c.gxt", lang)` and `sprintf(magic, "GBL%c", lang - 0x20)`, then **jumps into the 11.44
patch at `0x56DF08`**: if the patch flag `0x676204` is set (it is, by `LoadGMP_and_STY_Files`)
it resets the GCI path `0x676EEC` and the `.mmp` path `0x676DDC` to `data\nyc.gci`, and in
multiplayer (`isMultiplayer` `0x673E2C`) reads `[MapFiles] GCIFile` / `GXTFile` from the map's
`.mmp` ini with `GetPrivateProfileStringA` into the GCI path and `strPathToGXT`. If the
`.mmp` names `e.gxt`, the player's own language letter is put back into the path; any other
GXT name forces the language to `e` (and the expected magic to `GBLE`). It returns through `0x3F1664` (clears the flag) to
`File_Open(strPathToGXT)`. Header: 6 bytes, `Header_CheckMagic("GBLE"…)`,
`Header_CheckVersion(100)`. Chunks via `parseChunk` (`0x4C2330`); after `File_Close`,
`FUN_004C20B0`. All V.

| Chunk | Reader | Destination | Status | Evidence |
|---|---|---|---|---|
| TKEY | `0x4C2060` | `this+0x0` = new(n·12) array of `LocaleSingle {u32 offset → WCHAR *text, char id[8]}`, `this+0x4` = n = size/12 | V | `FUN_004C20B0` then adds the TDAT base to every `offset` → pointer. Lookup `FindLocale` (`0x4C2120`) = `bsearch` on `id` (entries must be sorted), fallback string `0x575540` |
| TDAT | `0x4C2150` | `this+0x8` = new(size) u16 text, `this+0xC` = size/2 | V | raw read |
| other | `0x402F60` | — | V | skipped |

Shipped: `e/f/g/i/s.gxt` (and `bob_*.gxt`) = header `GBL?` + u16 100, TKEY then TDAT.
`FUN_004C2450`/`0x4C21A0` (upper-casing tables `0x594CF8`/`0x594DF8` per language) are text
layout helpers, not loaders.

## `.sdt` + `.raw` — district sound bank (`FUN_004B6B40`)

Not via the File module and **not via `mss32`**: plain CRT `fopen`/`fread`.
`0x410550` (Ghidra name `LoadSty` — wrong, it is a sound thunk) sets ECX = `g_SoundManager`
(`0x5DCBC8`) and jumps to `FUN_00416D30`: if sound is enabled, `FUN_00416570` cuts the style
path to its stem (after the last `\`, before the `.`, into `0x5DCB08`: `wil`) and jumps to
**`FUN_004B6B40`** on `g_MssAudioDevice` (`0x66C950`). V:

1. `"data\audio\" + stem + ".RAW"` (`0x5752E0` + `0x5752D8`), `fopen(…, "rb")`; if missing,
   `data\audio\BIL.RAW`. `fseek(END)`/`ftell` for the size, refuse > 0x5D1420 bytes
   (≈ 6.1 MB), `rewind`, `fread` the whole file into the preallocated buffer at `this+0x1EA8`.
2. `stem + ".SDT"` (`0x5752D0`), fallback `BIL.SDT`; `fread(this+0xA8, 0x18, 0x140)` — **always
   320 entries of 24 bytes**, whatever the file size (fstyle.sdt has only 18; the rest keep the
   ctor defaults).
3. `this+0xA4 = 1` (bank loaded).

The ctor (`FUN_004B6CE0`) initialises the 320 entries to `{0, 0, 11025, 0, 0, -1}` — which
confirms the entry layout `u32 offset, u32 size, u32 rate, u32 rate variation, i32 loop start,
i32 loop end`. V. The RAW buffer at `this+0x1EA8` is `AIL_mem_alloc_lock` memory and samples
are later pointed into it with `AIL_set_sample_address` (per `docs/win32-shims.md`, "Audio";
not re-traced here). The individual calls from SDT entry to `mss32` sample handle (`Mss_Init2DSamples`
`0x4B6F70`, `Mss_Init3DSamples` `0x4B72B0`) were not traced; our `mss32` replacement is
`host/w32_audio.asm`.

## `.scr` — mission script (`loadScript`, `0x47F280`)

On `g_MissionScript` (`0x6644BC`), skipped entirely when `g_skipMission` (`0x5EADAE`). Copies
the path into `this+0x35C` (`pathToScriptFile[256]`), `File_Open`, then (V):

| Part | Size | Destination |
|---|---|---|
| base pointers | 12000 B (6000 × u16) | `this+0x46C` `base_pointers` |
| script code | 65536 B | `this+0x334C` |
| strings length | u16 | local, passed to `ParseStrings` (`0x475D30`) |
| strings | rest of file, ≤ 5118 B (`File_ReadRest`) | `*(this+0x1334C)` `ptrToStrings` |

Every shipped top-level `.scr` is exactly 82656 = 12000 + 65536 + 2 + 5118 bytes. Then
`ParseStrings`, `nothing` (`0x475E00`), `loadSubScripts` (`0x476070`): it builds
`"data\%s\" + name` (`0x573F50`) for each sub-mission and reads them with the File module into
`this+0x13354`+… (fixed-size reads plus `File_ReadRest`); the exact sub-script layout is **H**
(there are 10028-byte `.scr` files in the pak that do not have the 82656-byte layout).

## `nyc.gci` — car handling (`CarModelTable_Load`, `0x432FC0`)

On `g_CarModelTable` (`0x5E5488`). Copies the path to `0x5E5448`, then
`CarEngineData_LoadGci` (`0x432D10`), `CarModelTable_ValidateEngineData` (`0x432CD0`),
`CarModelTable_BuildPhysicsData` (`0x432EA0`). In `CarEngineData_LoadGci` (V):

- n = `g_StyleData->allCarsInfo->totalCars` (`FUN_00432850`: `[this+0x5C]+0x400`) — the GCI
  must describe exactly as many models as the style's CARI.
- `FUN_00402B20` reads the whole text file (CRT `fopen "rb"`, `File.cpp` errors);
  new(n × 0x48) records → `CarModelTable+0x804`; the text parser `FUN_0041D800` fills them;
  error if the parser reports a problem (`carinfo.cpp` line 0xBC), if the output is not a
  multiple of 0x48, or if the count ≠ n.
- `CarModelTable+0x404 + model*4` ← record pointer (by the record's first byte, the model).

0x48 = 72 B = 4 bytes + 17 × 4-byte fixed-point values, matching the 21 text fields. That the
parser scales by 0x4000 comes from gta2_re via `lessons.md`, **H** here. `CarModelTable+0x404`
is typed `CarInfo*[256]` in `re/` — wrong, it holds GCI records.

## Frontend `.tga` (`LoadFrontendImage`, `0x452D50`)

`LoadFrontendImages` (`0x452E20`, from `InitFrontend`) calls the renderer export at
`0x595330` with the image count (`0x592DC0`), then `LoadFrontendImage(i)` for each. Per image
(V): `g_FrontendImages[i]` (`0x591F68`, `FrontendImage {char path[128]; u32 size; int handle}`
× 25) gives path and **expected size**; CRT `fopen "rb"`, `malloc(size)`, `fread` must return
exactly `size` (error `0xBB`), then `handle = gbh_LoadImage(buffer)` — the TGA is parsed by
the renderer DLL (ours: `docs/renderer-api.md`), not by the game. `DrawFrontendBackground`
reloads images through the same function.

## Other files (brief)

| File | Reader | Status | Note |
|---|---|---|---|
| `.seq` | `FUN_00455340` | V | see "Who builds the paths" |
| save game (`player\…`) | `FUN_0047F0B0` | V (structure) | 0x748 B into `buf466`, then three u32-counted blocks into the DMAP grid's spare capacity (`FUN_004642A0` hands out the buffers, `FUN_00464250` commits counts) — saves carry map edits |
| `data\kanji.dat` | `KanjiFont_LoadKanjiDat` (`0x460F10`) | H | File module (xref), Japanese only |
| replays `.rep` | `Replay_ReadHeader` (`0x45F270`), `Keyboard_InitAttractReplay` | H | File module (xref) |
| unknown 0x52-byte header | `FUN_00452D00` | unknown | File module; reads 82 bytes, keeps 3 |

## Coverage summary

| Format | Units | Verified reader + destination | Hypothesis | Unknown |
|---|---|---|---|---|
| `.sty` | 16 tags (14 shipped + PSXT, OVLY) | 16 | meanings of: tile remap table (`+0x40`), FONB font roles, SPEC surface numbering, OBJI field names | `StyleData+0x6A` |
| `.gmp` | 12 tags (8 shipped + UMAP, EDGE, THSR, CMAP-as-skip) | 12 (6 parsed, 6 confirmed skipped) | ZONE slot info meaning, LGHT field names | RGEN's two 545×8 arrays and three u16 |
| `.gxt` | header + 2 chunks | 3 | — | — |
| `.sdt`/`.raw` | 2 files | 2 | — | path into mss32 samples (not traced) |
| `.scr` | 4 parts + sub-scripts | 4 | sub-script layout | — |
| `nyc.gci` | 1 | 1 (container, count, index) | field scaling (0x4000) | `FUN_0041D800` parser internals |
| `.tga` | 1 | 1 | — | — |
| `.seq` | 1 | 1 (parse + limits) | FrontEnd level-table layout | — |

So: every chunk the game can see in a `.sty`/`.gmp`/`.gxt` has its reader and destination
verified (31 of 31); the open questions are what some destination fields *mean*, not where
they are.

Things worth knowing before writing a loader-compatible tool or patch:

- **SPEC and RGEN readers ignore the chunk size.** A SPEC that is not last, or with ≠ 9 lists,
  desynchronises the rest of the style; an RGEN not 17446 bytes desynchronises the map.
- **The GMP header is never validated.** The style header is (GBST, 700); GXT is (GBL+lang, 100).
- **Chunk order is free** except for the above; chunks of size 0 are skipped without dispatch.
- DMAP is mandatory (error `0x84`); every other chunk is optional.
- Sound banks are read with the CRT, not mss32; the SDT read is a fixed 320 × 24 bytes.

## Proposed names for Seq 27

Nothing below was applied. "was" is the current Ghidra name; types are offsets within the
object the function works on.

Functions:

| VA | was | proposed | why |
|---|---|---|---|
| `0x403160` | `fopen` | `File_Open` | wraps CRT fopen into `g_File` |
| `0x402FB0` | `fread` | `File_Read` | (dst, &size), errors on short read |
| `0x403000` | `readChunkHeader` | `File_TryRead` | generic; false at EOF |
| `0x402F60` | `FUN_00402f60` | `File_Skip` | fseek SEEK_CUR |
| `0x402EB0` | `fclose` | `File_Close` | |
| `0x403040` | `File_ReadAll` | `File_ReadRest` | reads to EOF with a max |
| `0x460EE0` | `FUN_00460ee0` | `FileHeader_CheckMagic` | |
| `0x460EC0` | `FUN_00460ec0` | `FileHeader_CheckVersion` | |
| `0x4059F0` | `malloc` | `MallocAligned64K` | returns 64 KB-aligned, raw ptr out |
| `0x4BF790` | `FUN_004bf790` | `SumU16` | |
| `0x4BF7B0` | `FUN_004bf7b0` | `CountsToBases` | exclusive prefix sum |
| `0x4BF7F0` | `FUN_004bf7f0` | `StyleData_InitTileRemap` | |
| `0x4BF840` | `FUN_004bf840` | `StyleData_ExpandDeltaIndex` | |
| `0x4BF980` | `FUN_004bf980` | `StyleData_BuildDeltaBySprite` | |
| `0x4BF900` | `FUN_004bf900` | `StyleData_ResolveDeltaPointers` | |
| `0x4BFCC0` | `FUN_004bfcc0` | `StyleData_SetFontRoles` | 7 or 14 fonts |
| `0x4C0040` | `FUN_004c0040` | `StyleData_ReadSurfaceList` | SPEC list n |
| `0x4C00A0` | `UNK_SPEC` | `StyleChunk_SPEC` | |
| `0x4C0100` | `FUN_004c0100` | `StyleData_PostLoadFixups` | |
| `0x4C05B0` | `readChunk` | `StyleData_ReadChunk` | |
| `0x4BFAB0`, `0x4BFA60`, … | `delta_store`, `delta_index`, `tiles`, … | `StyleChunk_DELS`, `StyleChunk_DELX`, `StyleChunk_TILE`, `StyleChunk_SPRG`, `StyleChunk_PPAL`, `StyleChunk_PALX`, `StyleChunk_OBJI`, `StyleChunk_SPRX`, `StyleChunk_FONB`, `StyleChunk_SPRB`, `StyleChunk_PALB`, `StyleChunk_CARI`, `StyleChunk_RECY`, `StyleChunk_PSXT`, `StyleChunk_OVLY` | optional: one prefix for all chunk readers |
| `0x464890` | `mapSegment` | `MapBlocks_ReadChunk` | |
| `0x4644E0` | `FUN_004644e0` | `MapBlocks_IndexZones` | |
| `0x464980` | `processS11` | `MapBlocks_BuildZoneInfoSlots` | |
| `0x464590` | `FUN_00464590` | `MapChunk_MOBJ` | |
| `0x4645F0` | `FUN_004645f0` | `MapChunk_LGHT` | |
| `0x464550` | `FUN_00464550` | `MapBlocks_StartTileAnims` | |
| `0x464880` | `FUN_00464880` | `MapChunk_RGEN` | |
| `0x40D250` | (no function defined) | `RoadNetwork_LoadRGEN` | needs a function created |
| `0x4630B0` | `FUN_004630b0` | `MapGrid_Ctor` | |
| `0x46A4D0` | `FUN_0046a4d0` | `MapBlocks_SpawnMapObjects` | MOBJ consumer |
| `0x4692B0` | `FUN_004692b0` | `MapBlocks_CreateLights` | LGHT consumer |
| `0x4C3470` | `FUN_004c3470` | `TileAnimPool_AddFromMap` | |
| `0x4C2330` | `parseChunk` | `LocaleSettings_ReadGxtChunk` | |
| `0x4C2060` | `FUN_004c2060` | `GxtChunk_TKEY` | |
| `0x4C2150` | `FUN_004c2150` | `GxtChunk_TDAT` | |
| `0x4C20B0` | `FUN_004c20b0` | `Gxt_ResolveKeyPointers` | |
| `0x56DF08` | `FUN_0056df08` | `Patch1144_LoadGXT_MmpOverrides` | 11.44 patch code |
| `0x410550` | **`LoadSty`** | `Sound_LoadLevelBank_Thunk` | wrong name: it loads audio |
| `0x416D30` | `FUN_00416d30` | `SoundManager_LoadLevelBank` | |
| `0x416570` | `FUN_00416570` | `PathToStem` | writes `0x5DCB08` |
| `0x4B6B40` | `FUN_004b6b40` | `MssAudio_LoadBank` | .RAW + .SDT |
| `0x4B6CE0` | `FUN_004b6ce0` | `MssAudio_Ctor` | |
| `0x45E500` | `GetStyPath2` | `Menu_GetScrPath` | it is the .scr slot |
| `0x45E4E0` | `getGmpPath` | `Menu_GetGmpPath` | |
| `0x45E4F0` | `GetStyFilePath` | `Menu_GetStyPath` | |
| `0x45E510` | `FUN_0045e510` | `Menu_GetSavePath` | |
| `0x45E410`/`430`/`450`/`470` | `FUN_…` | `Menu_SetGmpPath` / `Menu_SetStyPath` / `Menu_SetScrPath` / `Menu_SetSavePath` | |
| `0x45E8D0` | `FUN_0045e8d0` | `Menu_LoadDebugLevelFromRegistry` | |
| `0x455340` | `FUN_00455340` | `FrontEnd_LoadSeq` | |
| `0x452530` | `FUN_00452530` | `Seq_ReadLabelLine` | |
| `0x4527A0` | `FUN_004527a0` | `FrontEnd_AddSeqLevel` | |
| `0x4556A0` | `FUN_004556a0` | `FrontEnd_SelectLevel` | H (copies entry to Menu) |
| `0x407930` | `FUN_00407930` | `Network_ReadMmpMapFiles` | |
| `0x47F0B0` | `FUN_0047f0b0` | `MissionScript_LoadSaveGame` | |
| `0x402B20` | `FUN_00402b20` | `ReadWholeFile` | |
| `0x41D800` | `FUN_0041d800` | `Gci_ParseText` | H |
| `0x432850` | `FUN_00432850` | `StyleData_GetTotalCars` | |
| `0x452D00` | `FUN_00452d00` | — | unknown, leave |

Globals:

| VA | was | proposed |
|---|---|---|
| `0x5D25F0` | `DAT_005d25f0` | `g_File` (FILE*) |
| `0x5D25F4` | `DAT_005d25f4` | `g_FileIsOpen` |
| `0x5DCB08` | `DAT_005dcb08` | `g_LevelStem` (char[]) |
| `0x676204` | `DAT_00676204` | `g_Patch1144_LoadingLevel` |
| `0x676EEC` | `DAT_00676eec` | `g_GciPath` |
| `0x676DDC` | `DAT_00676ddc` | `g_MmpPath` |
| `0x5E5448` | `DAT_005e5448` | `g_CarModelTable_GciPath` |
| `0x5EAD72` | `DAT_005ead72` | `g_skipAudio` (H: registry `skip_audio`) |
| `0x670640`–`0x670680` | `DAT_…` | `g_FontRole_*` (17 u32, set by `StyleData_SetFontRoles`) |

Struct fixes (`StyleData`, `/_STY`):

| Offset | was | proposed |
|---|---|---|
| `+0x00` | `_countOfpalettes` | `totalVirtualPalettes` |
| `+0x02` | `relToFontBase` | `totalFontSprites` |
| `+0x04` | `spriteIndexRel` | `spriteCount` (size/8+1) |
| `+0x06` | `relToMapObjectInfo` | `mapObjectInfoCount` |
| `+0x08` | `size_physical_palette` | `physicalPaletteCount` |
| `+0x0C` | `paletteBase2` | `paletteBases` (prefix sums) |
| `+0x10` | `paletteBase` | `paletteCounts` (raw PALB) |
| `+0x14` | `spriteBase2` | `spriteBases` |
| `+0x18` | `spriteBase` | `spriteCounts` (raw SPRB) |
| `+0x1C` | `fontBase` | `fontBases` (`{u16 count; u16 base[count]}`) |
| `+0x20` | `spriteIndex` | `spriteIndex` (`SpriteEntry*`) |
| `+0x30` | `i9` | `physicalPalettesRaw` |
| `+0x34` | `sprite_graphics` | ok |
| `+0x38` | `i13` | `spriteGraphicsRaw` |
| `+0x3C` | `i10` | `tiles` |
| `+0x40` | `i21` | `tileRemap` (u16[1024], H meaning) |
| `+0x44` | `i11` | `tilesRaw` |
| `+0x48` | `i14` | `deltaStore` |
| `+0x4C` | `i18` | `deltaIndexRaw` (freed after load) |
| `+0x50` | `i15` | `deltaIndex` (expanded) |
| `+0x54` | `i20` | `deltaBySprite` |
| `+0x58` | `car_info_chunk` | `carInfoRaw` |
| `+0x60` | `i19` | `deltaIndexSize` |
| `+0x64` | `i1` | `recycleModels` (u8*) |
| `+0x68` | `short1` | `recycleModelsSize` |
| `+0x6C` | `iArr1024` | `tileSurfaceType[1024]` |

`SpriteEntry.ptr`: offset into SPRG on disk, absolute pointer after `StyleData_PostLoadFixups`.
`CarInfo.sprite` (`+0x1`): becomes the accumulated sprite index after `parseCarInfoChunk`
(type it as `UINT8 spriteIndex`, not `bool_`).

`MapBlocks` (0x370): `+0x000` `MapGrid *grid` (new type: `u32 base[65536]; u32 columnCount;
u32 blockCount; u32 *columns; BlockInfo *blocks;`, 0x40010 B), `+0x328` `zoneData`, `+0x32C`
`zoneIndex` (pointer, not `ushort len`), `+0x330` `zoneInfoSlot` (u8*), `+0x334` `zoneInfo`
(22-byte records), `+0x338` `mapObjects`, `+0x33C` `lights`, `+0x340` `tileAnims`, `+0x344`
`mapObjectCount`, `+0x348` `lightCount`, `+0x34C`/`+0x354` `blockCount`, `+0x350`
`blockCapacity`, `+0x358`/`+0x360` `columnWordCount`, `+0x35C` `columnWordCapacity`.

`LocaleSettings`: `+0x0` `LocaleSingle *keys`, `+0x4` `keyCount`, `+0x8` `WCHAR *text`,
`+0xC` `textLength` (u16 units) — the `S2 s2` at `+0x8` is these two fields.

`CarModelTable`: `+0x404` `GciRecord *byModel[256]` (not `CarInfo*`), `+0x804` `GciRecord
*records` (not `countB`); new type `GciRecord`, 0x48 B.

`RoadNetwork`: `+0x4`, `+0xCC62`, `+0xCC64` u16 from RGEN; `+0xA830`, `+0xB938` `u8[545][8]`
from RGEN (meaning unknown).

`MssAudioDevice` (`0x66C950`, new type): `+0xA4` `bankLoaded`, `+0xA8` `SdtEntry entries[320]`
(24 B: offset, size, rate, rateVariation, loopStart, loopEnd), `+0x1EA8` `u8 *raw`.
