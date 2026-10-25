# Dreams roadmap: HD sprites, custom traffic cars, Russian

The RE needed for three user goals, tracked by Seq 27. Per dream: what is known (with VAs and doc links), what is open,
and the next step. Marks: (V) verified in code or live, (U) unverified / hypothesis.

Status 2026-10-25: program started. Phase 1 (HD sprites) is next.

| Dream | Phase | Deliverable | State |
|---|---|---|---|
| 1. HD sprites (peds and cars first) | 1 | [sprites-hd.md](sprites-hd.md) | started |
| 2. Own car models in ambient traffic | 2 | [custom-cars.md](custom-cars.md) | not started |
| 3. Russian version | 3 | [fonts-localization.md](fonts-localization.md) update | not started |

## 1. HD sprites

Known before this program:
- Every sprite draw goes `StyleData_GetSpriteEntry` (8-byte {ptr, w, h}) → `TextureCache_GetSpriteTexture(g_TextureCache,
  type, id, pal, remap)` → `gbh_DrawQuad` (V, HUD and font paths: [hud-and-menus.md](hud-and-menus.md), [gxt.md](gxt.md)).
- `g_TextureCache` 0x671978 (`TextureCache`, 0x15D8 bytes) holds tile and sprite textures; tiles are keyed by tile index after
  `StyleData_GetTileRemap`, so map HD textures key on the remapped tile ([map-and-renderer.md](map-and-renderer.md) §2.6, §3.3) (V).
- Our renderer implements `gbh_RegisterTexture` / `gbh_DrawQuad` in `host/c/renderer_gbh.c` ([renderer-sdl.md](renderer-sdl.md),
  [renderer-api.md](../renderer-api.md)).

Open: the sprite → texture cache keying and eviction, what a draw carries, remaps/palettes, deltas, ped animation frame →
sprite id, whether sprite size feeds game logic, the hook design.

Next step: phase 1 research (three parallel RE agents), then `sprites-hd.md`.

## 2. Custom cars in traffic

Known before this program: `nyc.gci` → `CarModelTable_Load` 0x432FC0 ([formats/loader-map.md](../formats/loader-map.md));
traffic model choice `CarManager_PickTrafficModel` 0x424980 (U, name only); physics in [car-physics.md](car-physics.md),
car AI and sound in [cars-and-car-ai.md](cars-and-car-ai.md).

Open: everything in phase 2.

## 3. Russian

Known: the plan is [fonts-localization.md](fonts-localization.md) option 2 (glyph substitution in our port); text format and
tools in [gxt.md](gxt.md).

Open: phase 3 checklist (gxt.md §10 questions, text baked into images, language selection, live check of the hook points).
