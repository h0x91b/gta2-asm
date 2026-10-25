# Dreams roadmap: HD sprites, custom traffic cars, Russian

The RE needed for three user goals, tracked by Seq 27. Per dream: what is known (with VAs and doc links), what is open,
and the next step. Marks: (V) verified in code or live, (U) unverified / hypothesis.

Status 2026-10-25: phase 1 (HD sprites) closing: H2 (remaps, palettes, deltas) and H3 (ped frames, car sprite ids, logical
size), H1 (texture path) done, the live probe `gta2ctl sprites` (8f6bf00) confirmed the draw key; written up in
`sprites-hd.md`. Phase 2 (custom cars) running in parallel: C1 model limits + per-model tables, C2 traffic picker, C3 model ->
assets + tooling.

| Dream | Phase | Deliverable | State |
|---|---|---|---|
| 1. HD sprites (peds and cars first) | 1 | [sprites-hd.md](sprites-hd.md) | RE done |
| 2. Own car models in ambient traffic | 2 | [custom-cars.md](custom-cars.md) | RE running |
| 3. Russian version | 3 | [fonts-localization.md](fonts-localization.md) update | not started |

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

Known before this program: `nyc.gci` → `CarModelTable_Load` 0x432FC0 ([formats/loader-map.md](../formats/loader-map.md));
traffic model choice `CarManager_PickTrafficModel` 0x424980 (U, name only); physics in [car-physics.md](car-physics.md),
car AI and sound in [cars-and-car-ai.md](cars-and-car-ai.md).

Open: everything in phase 2 (C1/C2/C3 running).

## 3. Russian

Known: the plan is [fonts-localization.md](fonts-localization.md) option 2 (glyph substitution in our port); text format and
tools in [gxt.md](gxt.md).

Open: phase 3 checklist (gxt.md §10 questions, text baked into images, language selection, live check of the hook points).
