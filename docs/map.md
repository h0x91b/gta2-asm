# Radar and city map (M) with fog of war

GTA2 has no map. We add two (not in the original game), both in `host/c/map.c`:

- **Radar**: a round minimap in the bottom-right corner, drawn every gameplay frame. It
  follows the player and by default turns with them (facing is always up; a small white
  arrowhead on the rim points north). Range 11 tiles on foot, 17 in a car, eased. It shows the
  city's roofs and streets, the player as a white arrow and the HUD's arrows as markers:
  inside the circle where they are, on the rim pointing their way when out of range.
- **Full map**: M opens a full-screen map of the level, north up, centred on the player at
  2.5× the fit-to-screen zoom; the game is paused while it is up.

| Key (map open) | Does |
|---|---|
| M or ESC | close |
| arrows | pan |
| `+` / `-` / PAGE UP / PAGE DOWN (and the keypad's) | zoom, 0.8× … 8× of the whole city on screen |
| SPACE | back to the player |

While the map is up it takes every key, so the game never sees ESC (no quit prompt) or a
movement key. M is free in the game: `Player_OnKeyDown` 0x4A7010 handles DIK 1-11, 0x2E,
0x3B-0x44, 0x47-0x58, 0xB5, 0xC7, 0xC9, 0xD1 (own decompile; 0x2E C and 0xC9/0xD1 only with
`do_debug_keys`), and the 12 default control bindings (`gta2_install.reg`, `Control\0..11`)
are arrows, LCTRL, RETURN, SPACE, Z, X, TAB, LALT, RSHIFT. The K menu (K) is closed when M
arrives, else M goes nowhere; the radar hides while the K menu is open.

**Fog of war.** Both views show the city only where the player's camera has been. Each tile
has a fog byte, 255 unseen … 0 seen; every running frame the tiles inside the player camera's
world rect and within 9 tiles of the player lose 24, so a street fades in over ~10 frames as it comes on screen, and the fog
texture is filtered linearly, which softens its edges. Unexplored tiles are drawn under a
97 % dark veil (the outline of the city just shows through). The full map's top line shows
the explored share of the 256×256 grid (Downtown: every column has a lid, so it is the
share of the whole square). The fog is saved as `maps/<level>.fog` (65 536 bytes, one per
tile, row-major y·256+x) in the overlay dir `~/Library/Application Support/gta2-resurrected/`
— on leaving the level, every 600 frames while it changes, and at a `--frames` exit — and
loaded when the game opens the level's `.gmp` (`<level>` = its base name, e.g. `wil`).
Delete the file, or use K → Map → "Forget explored map", to start over.

Settings: `config.yaml` section `map:` (`config.example.yaml`): `minimap`, `rotate`, `fog`,
`key`; K → Map has the same switches plus "Reveal the whole map" (marks every tile seen and
saves that) and "Forget explored map".

## Design

Where it is drawn, options considered:

| Option | For | Against |
|---|---|---|
| C32 with the game's `DrawFlatRect2D` 0x474110 (like the K menu's world overlays) | game-side, under the HUD | a map is thousands of boxes per frame (each a gbh quad); no rotation, no round clip, no texture |
| Register our own textures with the game (`gbh_RegisterTexture`) and draw with `DrawSprite2D` | the game's own pipeline | goes through the game's texture cache and palettes, needs a 2048² image the game has no slot for |
| **Host C at `Vid_FlipBuffers`, SDL directly (chosen)** | one texture for the map, one for the fog; the radar is a 72-triangle fan with rotated texture coordinates, so the round clip is free; a few `SDL_RenderGeometry` calls a frame; `--shot` and `gta2ctl shot` see it | drawn over the whole frame, HUD and K menu included (hence the radar hides while the menu is open) |

`vid_flip_buffers` (`renderer.c`) calls `map_frame` right after it counts the flip, before
`ctl_frame` (gta2ctl's `shot`) and the present. `map_frame` only reads game memory, except for
three style lookups per level (below), which are `call32`s from inside the flip handler.

### The map image

Built once per level (per `Game*` and `MapGrid*`, logged as `map: frame N, image of
wil built`): a 2048×2048 ARGB texture, 8 pixels per tile.

- Column (x, y): `g_MapBlocks` 0x662C08 → `MapBlocks.grid` → `MapGrid.base[y*256+x]` → the
  column word at `columns + base*4` = `{u8 height, u8 offset, u16, u32 blockIndex[]}`, blocks
  12 bytes at `MapGrid.blocks` (`MapBlocks_GetBlock` 0x4653C0, [re/map-and-renderer.md](re/map-and-renderer.md) §2.2).
- From the top block down, the lids (BlockInfo +8, tile = bits 0-9, 1..991) until the first
  that is not flat (bit 12); a flat lid's texel 0 is see-through and shows the lid below, a
  solid lid's texel 0 is black (as the renderer draws it, [renderer-sdl.md](renderer-sdl.md),
  "Index 0").
- Tile pixels: `StyleData` (`g_StyleData` 0x670684) `+0x3C tiles` + `((t & ~3) << 6 | t & 3) * 64`,
  pitch 256 (`StyleData_GetTilePixels` 0x4C2EB0, own disassembly). Palette: virtual palette
  = the tile number (the tile palette base is 0), physical = `PALX[t]` (`+0x28`,
  `StyleData_GetPhysicalPalette` 0x4BF530), colour `c` at `+0x2C physical_palettes +
  (p >> 6) * 0x10000 + (p & 63) * 4 + c * 256` (the PPAL page layout of
  `tools/formats/style.ts` `paletteColor`).
- Each tile is box-filtered 64×64 → 8×8 once (mean colour of the non-zero texels plus their
  coverage), then placed rotated (bits 14-15) and flipped (bit 13) per lid; the rotation table
  is gta2-browser's (see [CREDITS.md](../CREDITS.md)) and was checked against the game view
  (below). Roofs get a mild brightness by height (0.8 at z 2, +0.07 per level, 0.72…1.15) so
  blocks read apart from the street.

Runtime map edits (doors, `CHANGE_BLOCK`) and tile animations are not followed: the image is
the level as loaded.

### The player and the markers

- Position: `ctl_pos` (`ctl_game.c`: the car's body while in a car, else the ped's). Facing:
  the car's or the ped's body `Sprite.rotation`, an Ang16 (1440 per turn) with direction
  `(sin h, cos h)`, 0 = +y = south on screen. Measured: a car at heading 0 driven forward went
  from y 195.0 to 199.0.
- Fog: the tiles inside `Player.viewCamera.cameraBoundaries` (`Camera +0x20`, Fix16 world
  rect) and a 9-tile disc around the player, only while `Game.gameStatus` is 1 (running), so the paused map and a menu do not
  explore.
- Markers: `g_HudManager` 0x672F40 `+0x1F18` `HudArrowPool`, 17 `HudArrow`s
  ([re/hud-and-menus.md](re/hud-and-menus.md) §2.1, §4); shown when `inUse` and `visible` (the
  HUD's own decision, `Hud_Arrow_ShouldShow` 0x4CA770) and the current target is not empty or
  another player (mode 0 / 6), at the target's `posX/posY`. Colour: 1 yellow, 2 red, 3 green
  (gang jobs), 5 the mission target (flashing), 4 a gang's own arrow in the colour of its
  USER sprite (`Hud_Arrow_Draw` 0x4C82C0 draws `DrawSprite2D(6, spriteId)`): the mean of its
  opaque texels, brightened to a full channel, via `StyleData_GetSpriteIndex` 0x4BF2A0,
  `StyleData_GetSpriteEntry` 0x4BF280 and `StyleData_GetPaletteIndex` 0x4BF430 (kind 2). In
  Downtown at the start these are the three gang arrows, sprites 1/2/3 → green `#0eff00`,
  blue `#2828ff`, white (measured).

### Pause

The full map pauses the game like the K menu: `dm_pause_sync` (`menu/core.c`) treats
"menu open or map open" alike (`gameStatus` 1 → 2, `UnpauseGame` 0x45BA60 on close, the
game's pause screen hidden), see [debug-menu.md](debug-menu.md) "Pause".

## Verified (2026-10-24, Downtown, 1280×960)

`tests/ctl/map.sh [OUT_DIR]` runs the whole thing with a private `HOME` (a fresh overlay, so
the player's own `maps/wil.fog` is never touched): radar on foot facing 0° and 90°, M (the game
reports `paused`), the map before exploring, a drive, the radar while driving, the map after,
then a second start of the level that must load the saved fog (`map: level wil, explored tiles
1502 (maps/wil.fog)`) and shows it. PASS.

- The map matches the city: teleported to (140.5, 200.5) with `fog: false`, the full map at 8×
  around the player shows the same L-shaped roof, the road above and the junction to the left
  as the game view (orientation, rotation and flips of the lids).
- The explored trail on the full map runs from the start plaza to the teleport and down the
  drive, the player arrow at its end pointing the way the car drove.

The disc is there because the rect alone lagged: in the first test the car, driving south,
sat on the leading edge of the revealed area on both views while the screen showed city ahead
of it (the rect seems to trail the camera in a car; not traced further).

## Known limits

- The map image does not follow runtime map edits or animated tiles (see above).
- Only the HUD's arrows are markers: no shops, phones or pickups of their own (gta2-browser
  also scans the object pool for those).
- Fog is per tile of the camera's rect: at the default zoom a frame reveals ~30×22 tiles; the
  whole level is 256×256, so "explored" grows slowly by design.
- The radar sits in the bottom-right corner at a fixed size (62 units of 640×480 radius);
  pager timers and briefs do not overlap it in the runs so far.
