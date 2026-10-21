> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# First ambient pedestrians

The original district and the Pedestrian movement lab use `sim/population.ts` and
`sim/pavement.ts`. Lab rectangles supply sidewalk cells; they do not provide movement
code. The renderer shares the player's original atlas lookup/UV/size function.

A saved population owns a xorshift32 state, monotonically increasing IDs, a 24-person
budget, spawn/despawn counters and explicit view half extents in metres. Every60 ticks
it attempts up to2 offscreen spawns. A bounded multi-source BFS starts at inner-view
sidewalk nodes and visits only the active rectangle. Only reachable nodes outside1.1
view half extents can spawn, so the initial route necessarily visits the inner view
as it existed at spawn. Unreachable blocks are not used to pad the budget.

The active rectangle extends TWO FULL SCREEN WIDTHS/HEIGHTS from the player (four
half extents on each axis), implementing the player's two-screen description. Real
play sends camera extents through `populationView`; headless replay stores/sets those
same inputs explicitly. Rendering never mutates population state. Camera height60/zoom
and FOV44 produce halfHeight=60/zoom*tan(22deg); width uses viewport aspect.

After reaching the initial destination, each pedestrian chooses a connected neighbour,
avoiding immediate reversal when alternatives exist. Following keeps identity alive;
only leaving the active rectangle despawns it. Routes are not pulled back toward a
player who moved after spawn. These route policies reconstruct the user's description;
they are not claimed as a recovered original routing algorithm.

Each4-metre edge takes120 integer ticks: provisional2m/s. Store integer edgeTick and
compute position by interpolation; there is no accumulating float threshold. Original
walk/run distinction, exact NPC walk cadence and speed still need reconstruction.
Current art reuses relative8..15 at12 ticks/frame, original remaps25/18 (black/blue).
Red/green criminal appearances are deliberately not assigned professions yet.

`gta.pedestrians()` returns detached IDs, positions, heading, route and seen status.
`populationView{halfWidth,halfHeight}` is a normal validated command. Saves validate
node IDs, every edge, unique actor IDs, counters, PRNG and fractional-step clocks.
Old city saves without population start with an empty seeded population.

Verification: shared JSON scenario at ticks1/720/1800 (2/19/24 actors,0/7/19 seen),
partial-edge saves, deterministic seeds, sustained following, despawn, invalid routes,
and source Downtown route endpoints.183 GTA tests and typecheck pass. Browser checks
real menu/keyboard, source sprite positions and frame sequences, city/lab continuation,
detached observations and actual camera footprint input. Existing Downtown car checks
are rerun with population present. No golden hashes replaced; new city state/behaviour
naturally changes ad-hoc world hashes.

Pending: pedestrians still do not avoid one another, cars or the player. No run-over,
punch, blast damage, death or panic response yet. No slopes or road crossings; population
can be below budget if no reachable offscreen pavement exists. No professions, voices,
traffic drivers, buses or police. The city now has walking people, not a complete NPC world.

## Source walking correction

Supersedes the first-layer2m/s and run-frame approximation above. Pinned char.cpp
`TickMovementStateMachine_54C900`, state1, assigns k_dword_6FD7B8=Q14(256).
`sub_54DD70` selects animation0 below the collision-repulsion threshold. Animation0
uses relative0..7 and advances after3 source updates. Thus base walking pace is
(256/16384)*4/.033 =1.8939393939m/s, one animation frame per99ms. Source jitter,
turning and occupation-dependent states are still not reconstructed.

An edge has15840 integer units; each host tick adds125. After crossing an edge, the
remainder enters the next edge immediately.3168 movement ticks consume exactly25
edges/100m, leaving zero remainder. Frame phase advances50 units per host tick,
297 units per frame,2376 per cycle; each actor saves its own phase, frozen while down.
This changes NPC walking only; player run cadence and speed remain player-calibrated.

Legacy edgeTick/120 maps exactly to edgeUnits=edgeTick*132, preserving position
without rounding. New saves carry edgeUnits/walkPhase. Migration does not mutate input.
Tests restore during an edge, follow the new continuation and prove no remainder loss.

Observed scenario census, before / after:

| Tick | Population | Seen before | Seen after |
| --- | --- | --- | --- |
|1|2 /2|0|0|
|720|19 /19|7|6|
|1800|24 /24|19|19|

One arrival is later at the slower source pace. This is an intentional mechanical
change, not bookkeeping. No golden hashes replaced.190 GTA tests and typecheck pass.

Motion receipt:1440x900 viewport, zoom1, FOV44, camera60m above support.
The ground view height is48.48m; walking is about35.16 screen pixels/second.
The contact sheet crops the same viewport region without changing the game camera.
