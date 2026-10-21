> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…`, see [../../reference.md](../../reference.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Punch and recovery

User requirement: Ctrl punches forward; the struck pedestrian falls, lies for a while,
then stands back up. `attack` is the shared command; keyboard hold reissues it without
restarting an active punch. City and lab both call `stepCombat`/`stepPopulation`.

Source evidence: CriminalRETeam/gta2_re revision
51d2ce3d4b8d32b6d48ff5c938cc98521061691b, Source/char.cpp.
`sub_54DD70` selects animation4 and calls `HandleClosePedInteraction_45CAA0`.
Animation4 selects relative115..122 while stationary,123..130 while moving.
Lying state22 selects animation15 for character state33; animation15 uses65..72.
Global wil sprite IDs add pedestrian base77:192..199 punch,142..149 fall.
The atlas contact sheet was inspected before wiring these ranges.

The original lying timer is60 source updates for a normal NPC and20 in another state;
the surrounding source includes multiple fall/death paths. Our first nonlethal cycle
is deliberately provisional:48-tick punch, impact at age12;48-tick fall,120-tick lying,
48-tick rise. Rise reverses65..72; no separate original get-up sequence is established.
Do not call those timings or reverse animation an exact source reconstruction.

Nearest upright target within1.6m and a forward60-degree half-cone is hit once.
Elevation must match; eight LOS samples use shared terrain/car collision. A target
behind a wall/car is not hit. The target keeps its graph position, edge clock and route
while down. It resumes the same identity/path after recovery. Existing movement remains
available during a punch; vault/vehicle entry wait until it finishes. No health damage,
cash reward, repeat ground attack, knockback, retaliatory AI or punch sound yet.

`punch` demo provides a near target, another target to the left and a wall-protected
case to the right. Initial NPCs are declarative fixture data, not special combat code.
`games/gta2/scenarios/punch.json` checks down/up at ticks13/60/180/229. Tests cover rear target,
wall/car obstruction, busy action, rejected boarding/jump, and saves during windup,
fall, lie and rise.188 GTA tests/typecheck pass. Agent Browser presses real Ctrl,
runs the same scenario, observes source frame72, checks restoration and hits an
ordinary Downtown NPC.16-frame4x4 contact sheet shows the entire cycle.

World changes are optional action/knockdown fields plus the new fixture. No golden
hashes replaced. Existing city walking and car regressions are rerun alongside it.
