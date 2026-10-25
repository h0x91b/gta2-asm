# Dreams roadmap: HD sprites, custom traffic cars, Russian

The RE needed for three user goals, tracked by Seq 27. Per dream: what is known (with VAs and doc links), what is open,
and the next step. Marks: (V) verified in code or live, (U) unverified / hypothesis.

Status 2026-10-25: phase 1 (HD sprites) closing: H2 (remaps, palettes, deltas) and H3 (ped frames, car sprite ids, logical
size), H1 (texture path) done, the live probe `gta2ctl sprites` (8f6bf00) confirmed the draw key; written up in
`sprites-hd.md`. Phase 2 (custom cars) done: `custom-cars.md`. Phase 3 (Russian) done: `fonts-localization.md` "RE status and
implementation steps", live glyph-hook probe `gta2ctl text`. All three dreams: RE done; each section below ends with the
implementation task to open.

| Dream | Phase | Deliverable | State |
|---|---|---|---|
| 1. HD sprites (peds and cars first) | 1 | [sprites-hd.md](sprites-hd.md) | RE done |
| 2. Own car models in ambient traffic | 2 | [custom-cars.md](custom-cars.md) | RE done |
| 3. Russian version | 3 | [fonts-localization.md](fonts-localization.md) update | RE done |

## 1. HD sprites

Known before this program:
- Every sprite draw goes `StyleData_GetSpriteEntry` (8-byte {ptr, w, h}) → `TextureCache_GetSpriteTexture(g_TextureCache,
  type, id, pal, remap)` → `gbh_DrawQuad` (V, HUD and font paths: [hud-and-menus.md](hud-and-menus.md), [gxt.md](gxt.md)).
- `g_TextureCache` 0x671978 (`TextureCache`, 0x15D8 bytes) holds tile and sprite textures; tiles are keyed by tile index after
  `StyleData_GetTileRemap`, so map HD textures key on the remapped tile ([map-and-renderer.md](map-and-renderer.md) §2.6, §3.3) (V).
- Our renderer implements `gbh_RegisterTexture` / `gbh_DrawQuad` in `host/c/renderer_gbh.c` ([renderer-sdl.md](renderer-sdl.md),
  [renderer-api.md](../renderer-api.md)).

Found in phase 1 ([sprites-hd.md](sprites-hd.md); the hook design is its §7):
- The draw key is fully known at `Sprite_Draw` 0x4BE060 entry: spriteType +0x30, spriteId +0x22 (category relative),
  paletteKind +0x34, remap +0x24, shrink +0x38, and for cars the delta mask Car+8. Live (V, `gta2ctl sprites`, Downtown,
  ~1000 frames, 32 736 sprite quads, 430 keys): every key always came with the same pixels + palette, 0 conflicts; the
  shadow quad uses the body's texture; the car light overlay is a separate texture.
- Peds: frame = block (0 dummy / 158 gang / 316 emergency) + offset 0..157 (H3 table; live: no id outside its block,
  walk/run/stand/jump/enter/exit offsets match; the sprite id lags the anim state by one tick).
- Deltas exist only for car sprites and are applied to pixels in the 48-slot car sprite cache (H2); remaps are full
  palettes, so an HD pack needs per-pixel palette indices or per-remap art, not a tint.
- HD rule: never change the logical sprite w/h (collision, z-layer, skid, crusher, HUD read it); swap only the texture.

- Textures: static handles per (sprite, remap) registered once per style load; only the 48 car delta slots change
  content, so the key must come from `Sprite_Draw`, not from the texture handle (H1).

Still unknown: live coverage of shrink/wrecks, the emergency ped block, armed peds; HUD/font sprites (not in scope).

Implementation task I would open: "HD sprite pack loader": turn the probe into the real hook (C32 tag already there),
host-side HD lookup by key with palette-index HD art + remap palettes, car delta overlay composition and cache,
UV normalisation by the logical size; first milestone = one HD ped frame set and one HD car with its deltas.

## 2. Custom cars in traffic

Found in phase 2 ([custom-cars.md](custom-cars.md)):
- Every per-model table has 256 slots indexed by the id byte; free ids 9, 15, 20, 43 and 88..254. **87 is the "no
  model" sentinel** in 8+ places; ids >= 128 only break two `CHECK_CAR_MODEL` script ops.
- A model = one CARI record + a car sprite (<= 64x128 if it has deltas; deltas optional) + one `nyc.gci` record (count
  must equal the CARI count) + `car<N>` in each `.gxt`; sound by hard-coded id switches with defaults.
- Traffic: lists built at level load from (RECY membership of the style) x `CarInfo.rating`; zone ratios pick
  good/bad/average/police/gang. A model not in the style's RECY never appears in single-player traffic (L census).
- **AI traffic drives with the physics row of model 24**, not its own (`Car_GetPhysicsModel` 0x4220A0, L probe).
- Hard-coded roles by id: police 12/52/84, emergency 34/17, taxi 56/51, bus 11, trains, army, trailers.

Still unknown: the delta-cache overflow of a wider sprite and a CARI id without GCI (crash) were not run; `value` byte
and a few flag consumers.

Implementation task I would open: "Custom traffic car, step 1": replace a plain civilian (e.g. 13 DART) in place with
new art + CARI fields through a `.sty` sprite writer and a mod layer in `vfs.c`, verify it in traffic with `gta2ctl`;
step 2 an append writer (CARI/SPRX/SPRG/PALB/PALX/RECY + `nyc.gci` + `.gxt`) for a new id 88; optional C32 detour
on `Car_GetPhysicsModel` for own AI handling.

## 3. Russian

Found in phase 3 ([fonts-localization.md](fonts-localization.md) "RE status and implementation steps"):
- All text goes through `DrawGTAText` 0x4CC100; glyph id, glyph width and upper-casing each have a single seam
  (0x4BF550 / 0x4BF570 / 0x4C21A0, V statically; L: `gta2ctl text swap` redrew every E of the pager through it).
- Cyrillic codes without hooks index past the sprite table (V), so the hooks are mandatory: a detour of the glyph
  branch at 0x4CC308 supplying an atlas entry + texture, the width hook, Cyrillic in `ToUpperChar`.
- No text baked into frontend images; WASTED/BUSTED etc. are GXT keys. Language: replace `e.gxt`, no exe patch.
- Typing names needs a `SKeyboard_GetCharForScancode` 0x4611F0 hook (layout files are byte-based).

Still unknown: whether EBP must be reloaded at the 0x4CC350 join; English words in street-sign tiles and the `.bik`
intros; whether saves store the profile name as wchar.

Implementation task I would open: "Russian text, step 1": draw `wil-font1` Cyrillic on the font sheet, a sheet
importer, the C32 detour at 0x4CC308 + width + upper-case hooks (from `host/c32/text_probe.c`), a test `e.gxt` with a
few Russian briefs, screenshot; then the other fonts, keyboard hook, the translation.
