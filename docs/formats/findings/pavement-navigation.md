> **Ported** from an earlier browser reimplementation of GTA2 (not published). Sentences
> about "our", the importer, the sim, labs or runtime describe that project, not `gta2.exe`;
> paths under `games/gta2/` are in that project, not in this repository. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Pavement navigation foundation

Source: `formats/GTA2 Map Format.txt`, slope_type bits 0–1: 0 air, 1 road,
2 pavement, 3 field. This identifies surface semantics, not the original NPC routing
algorithm. Our graph is a reconstruction and does not use original routefinder data yet.

`games/gta2/src/sim/pavement.ts` derives an immutable graph from the registered terrain.
Nodes are flat pavement block centres in metres with explicit elevation. Cardinal
neighbours connect only at the same elevation after a radius-aware sweep through the
shared collision query. Walls separate components; bridge layers never connect by XY
alone. Stable BFS returns a shortest path, or an empty array for disconnected nodes.
The cache is keyed by the frozen terrain data object, never a tick or mutable world.
The graph itself is derived data, not world state. The first pedestrian population now consumes it; see pedestrian-population.md.

| District | Nodes | Undirected edges | Components | Sloped pavement cells omitted |
| --- | ---: | ---: | ---: | ---: |
| Downtown | 18229 | 23610 | 296 | 1024 |
| Residential | 14245 | 17956 | 339 | 405 |
| Industrial | 15948 | 19674 | 351 | 606 |

`/gta-map` can display the graph and a nearby route. Cyan means pavement edges,
yellow means selected path. Node-ID fields and `gtaMap.showRoute(from,to)` share the
same BFS. `pavementNodes()` supplies detached readable node data; state reports counts,
unsupported cells and the selected path. Changing districts releases GPU line resources.
The inspector uses block units, so rendering divides graph metre coordinates by four.

Checks: synthetic wall, road, slope, alternate bridge level and shortest route;
all edge midpoints and reciprocal links in all three original districts; 177 GTA tests
and typecheck. Browser checks real route controls, API equivalence, disconnected result,
all districts and clearing controls for the shape fixture.

Pending before complete pedestrian navigation: slopes, safe road crossings, node/body
avoidance, active screen-sized population area, seeded route choices and continuation,
collision reactions and professions. Basic NPC state, walking and animation now use this graph in the city.
