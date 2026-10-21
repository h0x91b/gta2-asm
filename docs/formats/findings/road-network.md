> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…`, see [../../reference.md](../../reference.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Directed normal traffic network

The shared headless `roadNetwork(mapId)` derives nodes in metres at each flat supporting cell with green arrows and non-air ground. Green arrows are the normal traffic network; red arrows are special/emergency routes. Arrows need not be on ground type1 (road): the DMA map specification explicitly allows any non-air ground. Source: local `formats/GTA2 Map Format.txt`, arrows section.

Imported XY directions: 1 left(-X), 2 right(+X), 4 up(-Y), 8 down(+Y). Do not paste coordinate increments from `Car_BC::CountConsecutiveArrowBlocks_4410D0` as imported XY. At pinned reverse-engineering revision51d2ce3d4b8d32b6d48ff5c938cc98521061691b that WIP function suggests swapped axes. An initial attempt produced no eight-node route anywhere and1881 false dead ends in Downtown. The stored original masks independently show bits1/2 continuous horizontally and4/8 vertically. Correct DMA directions yield86 dead ends and routes longer than100 nodes. The browser overlay aligns with painted lanes and turns. The same mistaken axis assumption existed in lane-assist: corrected 0x33→X,0xcc→Y; strength and angle threshold unchanged. Tests using synthetic vertical arrows now supply0xcc.

| District | Nodes | Directed edges | Dead ends | Omitted sloped cells |
|---|---:|---:|---:|---:|
| Downtown |15776|16842|86|580|
| Residential |16035|17230|123|649|
| Industrial |15311|16565|108|577|

Edges follow outgoing green bits and remain at the same elevation, sweeping shared terrain clearance with a provisional1m radius. This checks road-centre clearance, not a complete turning vehicle footprint. Nodes/edges are immutable and cached by immutable terrain identity. Stable BFS returns a directed path or an empty path; no forced reverse edge. Red routes, ramps and traffic-light phases are not traversed/implemented yet. Dead ends are observable and must not be silently joined by future drivers.

Map inspector: Show road arrows (green arrowheads), Nearby driving route (pink), named API showRoads/showRoadRoute/nearbyRoadRoute/roadNodes, detached state. Switching districts disposes GPU resources; shape fixture clears/disables road controls. Existing pavement inspector remains separate because pedestrian connectivity differs.

Verification: all208 GTA tests/typecheck, directed route and bridge/red-only fixtures, every original edge direction/elevation, at least100 reachable nodes from sampled starts per district. Agent Browser clicks the actual route button in all three districts, checks outgoing edges, API equivalence, detached data and clearing. City driving and vehicle-system regressions accompany the lane-axis correction. No golden hashes replaced; city steering along real roads changes intentionally. No autonomous drivers added in this layer.
