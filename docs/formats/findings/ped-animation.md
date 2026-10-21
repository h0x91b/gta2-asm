> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Original pedestrian sprites

The player now uses original `wil.sty` pedestrian sprites and an original remap palette. The importer exports all 53 pedestrian remaps to separate PNG/JSON atlases under `styles/wil/peds/`; the browser loads only its four selectable outfits.

DMA's supplied `scripting/example/bil.mis` declares the player with remap 25. That is the Claude default. Alternate selectable outfit colours use original remaps 17 (red), 16 (green), and 18 (blue); these are our colour choices, not a claim about original character-selection slots.

The pedestrian palette base is cumulative PALB tile + sprite + car-remap counts: 992 + 2089 + 37 = 3118 in wil.sty. A default sprite palette is not a character palette: it produces the red/green source-colour appearance. Remap 25 therefore uses virtual palette 3143. Geometry and pixels are never redrawn or AI-generated.

Frame ranges were cross-checked against [OpenGTA2's Ped implementation](https://github.com/ikkentim/opengta2/blob/main/src/OpenGta2.Client/Peds/Ped.cs), then inspected in the local atlas: walking uses relative ped frames 8–15 and idle 53–64. SPRB's pedestrian base is 77 in wil.sty, so these correspond to absolute sprites 85–92 and 130–141.

Animation is selected from integer world ticks: four ticks per walking frame, three per sprint frame and twelve per idle frame. These timings are provisional, not a claim of exact original timing (the reference reconstruction uses 0.06 seconds for walking). Sprint currently reuses walking frames faster. Jump now uses frames 16–23, with frame 21 held while sliding on cars. Simulation state/physics are unchanged by frame selection, and save continuation produces the same frame.


## Vault / car slide

The player confirmed a single Space press sustains sliding across adjacent cars; A/D steers slowly. They played the fixture and confirmed resemblance, requesting 20% faster turning: 1.08 rad/s now. Launch speed 7 m/s, air phase 48 ticks, landing 18 ticks and roof height 1.2 m remain provisional. Car support is observable in `player.vault` with phase, support ID and visited IDs; the state is saved and validated.

Source frame provenance: CriminalRETeam/gta2_re, revision `51d2ce3d4b8d32b6d48ff5c938cc98521061691b`, `Source/char.cpp`, `Char_B4::DoJump_5454D0` and animation Jumping_5. The source selects relative frames 16–23, with frame 5 special during sliding. Source art is taller than idle (idle 53: 18×10; slide 21: 18×20); it also applies a small scale envelope. We apply up to 1.09 extra scale, not an additional 2–3x multiplication on already taller artwork. Exact original timing and physics are not claimed.

## Player pace correction, 2026-09-05

The experienced player confirmed that the playable character always runs; separate walking/running belongs to ambient NPCs. Our previous 4.2 m/s default plus Shift 7 m/s was an invented player mode. It had not recently changed (verified against commit 9c099f8), but was slower than the intended ordinary player movement.

Pinned gta2_re `Source/char.cpp`: `k_dword_6FD868 = Fix16(256,0)`, `gRunOrJumpSpeed_6FD7D0 = 4 * k_dword_6FD868`, initialization assigns that to `field_3C_run_or_jump_speed`, and the player-input path approaches that speed for ordinary forward movement. With Q14, 4 metres/block and the 33 ms source scheduler this is 7.575757… m/s. `games/gta2/src/sim/pedestrian.ts` records this conversion. Our player now uses it for every ordinary movement command. This is still a reconstructed constant, not an original-executable measured trajectory; the source has additional movement/animation states not yet reproduced.

The old optional `sprint` command/save field remains accepted for compatibility but does not alter player movement or animation pace. Keyboard Shift no longer produces a special run mode. Existing run animation timing (3 host ticks/frame) is reused; exact source animation timing remains pending. The walking scenario's checkpoints intentionally changed to the longer one-second run distance; vehicle trajectories are unaffected.

Player correction after testing: run movement speed is correct, but frames changed twice as fast as intended. Cadence is now **6 host ticks per frame** (was 3); source-relative 8-frame cycle remains. One cycle is 48 ticks / 0.8 seconds. Translation stays 7.575757… m/s. This cadence is player-calibrated rather than a recovered original animation clock.

## NPC walking is separate from player running

The first pedestrian population reused8–15 too slowly. It now uses source animation0, relative0–7 (wil global77–84), with one frame per99ms and an independent saved phase. Source walking state1 uses Q14(256) per33ms =1.893939m/s. Player running remains8–15 at the player-approved6 ticks/frame and7.575757m/s. See pedestrian-population.md for exact edge-clock migration and remaining routing approximations.
