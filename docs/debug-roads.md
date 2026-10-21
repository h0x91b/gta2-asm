# Road network overlay (debug menu)

K → **Debug flags...** → **Road network:** — LEFT / RIGHT / RETURN cycle
`off → cars → peds → cars + peds`. Drawn every gameplay frame under the HUD and the menu
(`host/debug_roads.asm`, called from `hk_DrawUI` next to Ped paths). Off = nothing of it runs.

## What is drawn

| layer | look | source |
|---|---|---|
| lane arrows | white stem + square head on every road tile, one per green arrow bit | gmp block `+0xa` low nibble (1 left, 2 right, 4 up, 8 down): what ambient traffic follows (`TrafficSpawner_TrySpawnSide` 0x4B34E0, `CarPhysics_ApplySteeringAssist` 0x4A17C0) |
| segments | thin grey rectangles | `RoadNetwork` 0x5D351C `hSegments` +0xa830 / `vSegments` +0xb938 (`RoadSegment`: junction1, junction2, min/max tile) |
| junctions | yellow rectangles, id on a dark plate once a tile is ≥ 24 units on screen | `RoadNetwork.junctions` +8 (`RoadJunction` 16 B; ids from 1 until `minX == 0`, as `RoadNetwork_ShowJunctionIds` 0x40D120) |
| links | dotted line junction → junction, a quarter tile to the right of travel, square head 1.5 tiles before the target; blue open, red closed (SWITCH_ROAD) | link u16: id bits 0-8 (0x40CE90), length 9-14 (0x40CEA0), open bit 15 (0x40CED0) |
| traffic lights | big square in the glow's own live colour on a black rim | `TrafficLights` 0x6721CC → `TrafficJunction` glow `Light*` at +0x10..+0x1c, rgb +0x10; `TrafficJunction_ApplyPhase` 0x4C3A10 sets lamp frame and glow colour together (0xff00 / 0xff8000 / 0xff0000) |
| routes | car → junctions still ahead, in the car's hue, first 9 numbered | `CarAI.routeSlot` +0x28 ≥ 1, `RoadNetwork.routes` +0x2218 (256 u16 per slot, 0-terminated), `routeStep` +0x56 (`CarAI_FollowRoute` 0x430320, `RoadNetwork_StoreRoute` 0x40CC10) |
| pavement (peds) | translucent green fill, bright green border to non-pavement | top non-air block of the column with ground type 2 |

**Peds have no graph.** A dummy (npc) may step onto a tile only when its ground type is
pavement: `PedGameObject_CanCrossTileEdge` 0x495220 returns true for ground 2 (and 4), and for
road / field only for the player, drones and peds in the crossing state (+0x10 == 0xF);
`Ped_StartCrossingRoadIfAtCurb` 0x43B7C0 starts that crossing from a curb. The ambient spawner
uses the same test (`MapBlocks_FindPavementTopBlock` 0x466910). Peds with an objective get
on-demand tile paths from `PedPathfinder` 0x66A7E4: that is the **Ped paths** toggle.

Ambient traffic never routes (RoadNetwork_FindRoute 0x40E030 serves drive orders only), so the
graph and the route layer matter for scripted drives; the arrows are what ordinary cars follow.

## Cost

Only tiles inside the player camera's world rect (`Camera +0x20`, plus one tile) are scanned,
and only junctions / segments / links / lights overlapping it are projected; each junction's
screen point is computed once per frame. Map and graph are read live (a column walk is a few
loads), so SWITCH_ROAD and CHANGE_BLOCK show at once. Every 300 frames a `roads:` line on stdout
counts what was drawn and the light phase.

## Verified (2026-10-21, Downtown)

- Host map reads match the `.gmp` decoder exactly: view x 146..172 y 129..149 → 134 pavement
  and 106 arrow tiles in both (`tools/formats` map parser vs the overlay's counter).
- Lights: at junction 200 (trafficlight32 zone, 157,167) the squares sit on the game's lamps and
  turn green → red between frames 1000 and 1150, matching the lamp sprites (phase 4 = E/W green).
- Arrow and link directions agree (right-hand traffic: upper lanes westbound, lower eastbound).
- Test build: `NASMFLAGS='-DDR_TEST=800 -DDR_TX=159 -DDR_TY=165' host/build.sh` teleports the
  player to that tile at frame 800 (`Ped_Teleport` 0x435C80) so a lit junction is in view.

## Known limits

- **Routes not seen live**: no car had `routeSlot ≥ 1` in the runs (also with 3 wanted stars:
  cops chase without RGEN routes). The layer follows the code but is untested in play; a
  mission drive order is the way to see it.
- A link is kept when the box over its two junctions meets the view, so a long one still shows
  with both ends off-screen; it is a straight line between centres, not the road's shape.
- Pavement and arrows use the column's top non-air block: under a bridge or roof the tile below
  is not drawn.
- Overlays are drawn at the surface height, so perspective makes them look offset under tall
  roofs at the screen edges.
