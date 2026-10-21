# GTA2 format lessons

Traps in reading the game's files, each one found the hard way and verified against the
shipped 11.44 data (the tests in `tools/formats/tests/` cover most of them). Adapted from
the user's my-games project (`rts-dots2/games/gta2/docs/lessons.md`, `bf84820c`): its
reimplementation rules (sim/render layering, browser checks, physics, saves) were
dropped; what is left is about the data, plus the two RE-hygiene lessons at the end.

## Styles (`.sty`, GBST)

- The header is `GBST` + u16 version, then unordered chunks `tag[4]` + u32 size. DMA's
  spec says version **600**; all four shipped styles say **700** with the same layouts.
  Keep unknown chunks; bounds-check every chunk before reading. Shipped chunk set
  (wil.sty): TILE PPAL SPRB FONB DELX DELS PALX OBJI RECY SPRG SPRX PALB CARI SPEC.
- **PPAL is column-interleaved**, not 64 contiguous palettes: colour `i` of physical
  palette `p` is at `(p/64)*65536 + i*256 + (p%64)*4`, in **BGRA** order. Index 0 is
  transparent whatever its stored alpha.
- **PALX** maps virtual palette → physical (u16 each). A tile uses virtual palette = tile id;
  a sprite uses `PALB.tile_count + sprite id` (sprite palettes come after tile palettes).
- **PALB/SPRB/FONB store counts, not bases.** Bases are running sums. wil.sty: palettes tile 0
  (992), sprite 992 (2089), car remap 3081 (37), ped remap 3118 (53), …; sprites car 0 (77),
  ped 77 (474), code obj 551, map obj 1103, user 1193, font 1366.
- **TILE**: 64×64 tiles, 16 per 256×256 page. **SPRG rows have a 256-byte stride**, not
  the sprite's width (SPRX entry: u32 offset, u8 w, u8 h, u16 pad).
- **CARI sprite bytes are counts (0/1), not ids**: accumulate them; a 0 shares the previous
  sprite. Model ids and sprite ids are different namespaces (Taxi model 56 is sprite 50).
- **Car remap 0 is not the base artwork.** CARI remaps are relative to the car-remap area
  (`PALB.tile + PALB.sprite`); the base sprite palette is a separate entry.
- Wreck artwork is a CARI lookup: sprite model `72 + wreck` (wreck < 9), not a tint or delta.
- **DELX/DELS deltas**: DELX entry = u16 sprite, u8 count, pad, count×u16 lengths; DELS is all
  streams concatenated. A stream is (u16 relative offset, u8 run length, run bytes)…; the
  cursor advances **through the written run** before the next offset; stride is 256. Index 0
  in a run erases base pixels: a dent is an indexed replacement, not an overlay. Damage bits
  0–4: rear right, rear left, front left, front right, windscreen (DMA spec, Car Delta
  Usage); my-games used deltas 7–10 as the door frames.
- Exploding score digits are **user** sprites 163–172 (as cited by my-games; global vs
  category-relative not recorded), not font glyphs. Always cite a
  sprite id with its style and whether it is global or category-relative.

## Maps (`.gmp`, GBMP)

- `GBMP` + u16 **500**, then chunks like GBST. Shipped wil.gmp: CMAP DMAP ZONE PSXM ANIM LGHT
  EDIT RGEN.
- Maps can carry **both CMAP (u16 words) and DMAP (u32 words) with different content**
  (Downtown: 75 566 differing voxel records, first at (0,0,4) lid tile/shading). The PC game
  uses DMAP; record which one you decoded, never assume they agree.
- DMAP: 256×256 u32 base grid → column store (counted u32 words) → counted array of 12-byte
  `block_info`. A column word 0 is `height | offset<<8`; **height is the exclusive top z**, and
  `offset` empty levels sit at the bottom, so only `height-offset` block refs follow.
- block_info: five u16 faces (left, right, top/north, bottom/south, **lid**), u8 arrows, u8
  slope_type. Face word: tile = bits 0–9, then side faces have wall (10) and bullet wall (11),
  but **the lid reuses bits 10–11 as a lighting level**; bits 12 flat, 13 flip, 14–15 rotation.
  Decoding lids with the wall flags is wrong.
- slope_type bits 0–1 = ground (0 air, 1 road, 2 pavement, 3 field), bits 2–7 = slope 0–63.
  Arrows: green (normal traffic) bits 0–3 left/right/up/down, red (special/emergency) 4–7;
  arrows are valid on any non-air ground, not only roads.
- Slope alone does not identify roof geometry: slopes 49–52 with **lid tile 1023** are pointed
  three-sided roofs (1023 is a shape marker, never drawn); with a normal lid they are inverse
  corners. Partial blocks (53–61) crop at 24/64 (centre 16/64).
- ZONE: u8 type, u8 x, y, w, h, u8 name length, name. Type 2 is an automatically built
  traffic-light junction.

## Sound banks (`.sdt` + `.raw`)

- SDT entries are 24 bytes: u32 offset, u32 size, u32 sample rate, u32 rate variation,
  i32 loop start, i32 loop end (−1 = none), offsets in bytes into the RAW.
- District banks have 320 entries, fstyle 18. **Ids 69–136 in district banks are unsigned
  8-bit** (police radio words); everything else is signed 16-bit mono. Do not infer the
  encoding from the rate or from odd/even sizes. 978 entries in the four banks, 204 of them U8.
  RIFF padding is not sample data.

## Other files

- Frontend **TGA files are mostly 16-bit RGB555** (bit 15 ignored), not RGB24; the main menu
  is two images side by side (278×480 + 362×480), and the logo crosses the seam.
- `nyc.gci` is text: `{comments}` and 21 fields per model (4 bytes, 17 `f`-prefixed
  decimals). Values are source units; **the game's own Fix16 parser scales by 0x4000**, not
  65536 (per gta2_re). 83 models.
- District stems: `wil` = Downtown, `ste` = Residential, `bil` = Industrial.

## RE hygiene

- Reverse-engineered handler names are hypotheses, not identities: a gta2_re "engine" sound
  handler turned out to be a horn when listened to. Keep provenance next to every mapping.
- gta2_re `_XXXXXX` suffixes are not 11.44 addresses: verify each one in our binary
  (`docs/formats/loader-map.md`) before using it.
