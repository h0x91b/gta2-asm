> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# First traffic signals

Source: `formats/GTA2 Map Format.txt` defines zone type2 as an automatically constructed traffic-light junction, requiring valid flat junction geometry. Runtime reads those original zone rectangles in metres and finds supported ground height. Lab rectangles are declarative data through the same signal API. Red special-route arrows remain unrelated to signal colors.

Provisional timing is shared globally: X green300ticks (5s), amber60 (1s), all-red clearance60 (1s), then the same forY; cycle840ticks. Absolute integer world.tick derives phase, so no extra clock or wall time exists. Source-equivalent durations, district offsets and original lamp artwork are not reconstructed yet. Lamps are deliberately provisional procedural overhead red/amber/green indicators, rendered in two instanced draws rather than one draw per bulb. `gta.signals()` exposes detached positions/phases; renderInfo.signals exposes displayed lamp counts/colors.

NPC driver tests desired travel ray against the zone rectangle and stops outside it on red. Amber permits entry if ordinary braking would no longer stop before the line. Already-inside vehicles clear the junction without being frozen by the changed phase. Height separation is respected. WaitingSignal is saved/queryable; signal waits reset obstacle horn timing, so ordinary drivers do not honk at red. Player input bypasses this driver policy and may run red. Steering, braking, contacts and audio remain shared systems.

Traffic signals lab stages two perpendicular drivers, one initially green and one initially red. Scenario signals.json checks waiting at tick300 and release by480. Unit tests cover exact phase boundaries, never two greens, clearance interval, already-inside/elevated cases, player red-running, saved wait and continuation.220 GTA tests/typecheck; Agent Browser verifies real E/W, shared scenario, actual rendered colors, saved wait, and the ordinary Downtown driver stopping at a source zone.16 fixed frames cover a full cycle; both original-city regressions remain required.

Limits: no demand-responsive phases, turn permissions, queue/junction reservations, pedestrian crossing phases or occlusion/visibility rules. Ground height sampling currently chooses a single supported level per source zone; multilayer junctions are not reconstructed. All timing and lamp geometry are provisional. City behavior changes at signal zones; no golden hashes replaced.

## Queue behavior

Traffic signals demo now has a three-car queue plus perpendicular traffic. Following clearance projects the other vehicle's oriented width AND length onto the desired travel axes; using width for both silently underestimates the rear of long cars. A follower inherits the nearest blocking driver's known red/amber signal wait, provided that signal still exists and its travel axis is not green. It does not honk at a red queue. Green clears this inherited reason, while ordinary obstacle clearance still makes each follower wait for space. The fixed vehicle update order can propagate a queue reason over successive ticks; this is not a junction reservation solver.

Before the fix at tick360, lab followers had blockedTicks98 and39 with no signal reason, causing unnecessary horn pulses. Afterward all three report crossing with blockedTicks0 and increased bumper clearance. Tests track ordered passage and save continuation; a staged original-city queue uses existing cars13/14/15 with different profiles. Its entire passage is counted across successive green phases and reproduced from a save. Requiring all cars to have positive speed at one arbitrary tick was a faulty check: the tail can legitimately encounter the next red. Browser now observes each car actually entering the source zone, rather than weakening the check to a moving-frame snapshot.222 tests/typecheck pass; no golden hashes replaced. Default city still starts with one driver; this layer prepares multiple-driver queues, not dynamic traffic population.
