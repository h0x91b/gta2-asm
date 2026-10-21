> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Vehicle palettes and handling source

## Palette extraction and game use

DMA's preserved `GTA2_Style_Format.txt`, Palette Bases and Car Info, defines `CARI.remap` as model-specific relative indices into the car-remap palette area. In each of the supplied district styles, `PALB.tile + PALB.sprite = 3081`, and the car-remap area contains 37 palettes. Do not interpret remap 0 as the base sprite palette: base artwork and car remap 0 are separate entries.

`games/gta2/tools/car-colors.ts` exports the base sprite plus every allowed remap for each model. There are 668 model/colour entries for each of wil, ste and bil, including 83 base entries. Model 0 allows 20 remaps, model 1 allows 12; there is no universal six/eight-colour limit. The same sprite can belong to multiple model IDs with different allowed palettes.

Runtime reads `car-colors.png/json`. Existing fixture IDs deterministically select from the corresponding model's allowed remaps; no randomness or sim hash change is introduced. `gta.renderInfo().carAppearances` exposes the model, sprite and remap for visual verification. This temporary ID-based selection will become explicit vehicle appearance state when spawning/custom paint is introduced. The city still uses shared provisional dimensions/handling. The handling lab uses two source-derived profiles, as described below.

The resource catalogue's Car colours mode shows all variants, including labelled base art. Export tests compare every row of all three district outputs against the source decoder. Browser checks cover distinct palette pixels, pagination, gameplay colours and save/slide continuity. Visually compared against archived IGN-PC-SS2 / SS3: the missing body-colour variety is now present; original local lighting and compact HUD remain separate fidelity gaps.

## NYC.GCI

The supplied `games/gta2/original/data/nyc.gci` contains 83 models with four byte fields and seventeen f-prefixed values per record. `games/gta2/src/assets/gci.ts` parses this shipped syntax, preserves the decimal tokens and source names, rejects malformed/truncated/duplicate models, and exports `games/gta2/assets/vehicles/nyc.json`. The catalogue's Vehicle parameters mode displays it explicitly as **unconverted source units** (the catalogue caption predates the two-profile handling lab).

Fields include mass, drive/mass bias, brake friction, turn-in/ratio, rear stability, handbrake slide, thrust, maximum speed, anti strength, skid threshold, gear multipliers and shift speeds. Romero (0): mass 16.5, maxSpeed 0.245; Wellard (1): 14.5, 0.380. These numbers are not yet metres/second or SI masses.

The reverse-engineered primary source [CarInfo_808.cpp](https://github.com/CriminalRETeam/gta2_re/blob/51d2ce3d4b8d32b6d48ff5c938cc98521061691b/Source/CarInfo_808.cpp), `LoadModelPhysics_4546D0`, parses GCI and maps records by their model IDs, checking the record count against the style. `FloatStrToFix16_431000` multiplies by **0x4000**, not 65536 despite the Fix16 name. It truncates during decimal conversion. Do not translate these values into the 60 Hz sim by guessing the clock or scale. The handling lab below investigates those calculations; original executable traces remain needed for fidelity calibration.

The provided installation also contains `nyc.gci.bad` and a Fast Cars Lua mod. They remain preserved inputs, not alternatives automatically enabled by our importer. Provenance is the supplied installation, not a claim that every file is an untouched retail release.

## Flat-road handling lab, 2026-09-05

Playable at Test maps → Vehicle physics. Romero (0) and Wellard (1) use explicit profiles checked against the supplied GCI and STY dimensions/wheel offsets. `games/gta2/src/sim/handling.ts` reconstructs front/rear forces, separate linear/angular velocity, gearing, forward braking/reverse, and handbrake response. The ordinary city retains the legacy handling until this calibration layer is ready to generalize.

Research is pinned to CriminalRETeam/gta2_re revision `51d2ce3d4b8d32b6d48ff5c938cc98521061691b`: [CarPhysics_B0.cpp](https://github.com/CriminalRETeam/gta2_re/blob/51d2ce3d4b8d32b6d48ff5c938cc98521061691b/Source/CarPhysics_B0.cpp), [Game_0x40.cpp](https://github.com/CriminalRETeam/gta2_re/blob/51d2ce3d4b8d32b6d48ff5c938cc98521061691b/Source/Game_0x40.cpp), and [winmain.cpp](https://github.com/CriminalRETeam/gta2_re/blob/51d2ce3d4b8d32b6d48ff5c938cc98521061691b/Source/winmain.cpp). `LoadFromGciFile_454A00` applies mass conversion before derived inertia; `ApplyDriveForce_5615D0` separates wheel-point velocity from body heading. The normal scheduler interval is 33 ms. Our 60 Hz clock carries 50 units per host tick, executes a force update per 99 units, and integrates the latest velocity across the host tick (3000 units/s, 4 metres/block). Integer remainder is serialized; no elapsed wall time enters physics.

**Limits:** source reconstruction contains WIP functions. Our input braking state machine and dead zone are simplified; wheel offset scaling still needs original-executable trace verification. Only coefficients are quantized to Q14; subsequent arithmetic is float64. Host resampling is not source-exact integration. This is not a bit-identical recreation or proof of original handling feel. Turbo, road-arrow assistance, airborne/water behavior, damage, impulse collisions, tyre marks and the other 81 model profiles remain pending. Impacts currently stop the car. The original's calibrated traces have not been measured.

Evidence: `games/gta2/tests/handling.test.ts` checks distinct model acceleration, gearing/caps, braking into reverse, lateral response, source fields, integer carry, fixture isolation and save continuation. `games/gta2/scenarios/handling-demo.json` records **our implementation's** acceleration/turn/release trajectory; these checkpoint values are regression receipts, not measurements of GTA2. `games/gta2/tools/browser-handling.ts` replays that same scenario and separately exercises physical E/W/Space keys.

## Tyre marks on the handling lab

`UpdateWheelSkidEffects_55DC00` checks front/rear lateral force separately against the model threshold, scaled by `1 - Q14(0.1)` and `1 + Q14(0.1)` respectively (`CalculateCarInfo_4542A0`). `SpawnSkidSegment_55D200` connects the previous wheel point to the current one; losing the skid condition clears that wheel's anchor. The lab now follows this force threshold and wheel-position rule. A straight acceleration run leaves no marks; the scenario's sharp turn produces front/rear wheel segments as thresholds are crossed.

State includes bounded segments and continuation anchors. A 2048-segment FIFO cap and 0.16 m rendered width are explicit provisional presentation choices, not recovered original values. No original-lifetime claim: oldest marks are evicted by capacity, with a dropped count. Marks are computed headlessly, independent of camera visibility, and save/load preserves their continuation. A single instanced mesh draws them and is disposed with the scene.

Still missing: original skid-object sprites/length classes, surface-specific tracks, locked-wheel/burnout conditions, original object lifetime and tyre audio. This layer covers lateral-force marks on the flat asphalt lab only. Gallery comparison target: `AdrenalineVault-SS4` (paired dark marks on asphalt); the screenshot establishes appearance, not force thresholds or lifetime. The existing handling scenario's position/speed checkpoints remain unchanged; only skid-count assertions were added.

## Wall contact prototype and player corrections

The Wall impacts lab adds swept OBB contact against thin rectangular walls, a contact-point impulse using profile mass/inertia, and 5 cm maximum corner travel per subdivision. A face contact uses the average of supporting corners to avoid fabricated spin in a straight hit. Restitution 0.1 is provisional; this is not the original collision solver. Original `HandleWorldCollision_55FD00` uses a contact impulse and damage; our damage and moving-car impulses remain pending. Map boundaries/original map geometry still use the previous response.

Player feedback: handbrake should leave rear tyre marks even while going straight. Flat-road skid emission now includes rear-wheel handbrake drag when moving; this does not claim a complete locked-wheel or burnout model. Stationary handbrake leaves no trail.

Player feedback: normal exit is possible around walking speed. Current threshold is 4.2 m/s, explicitly based on player calibration rather than a decoded original constant. `CanExitCar_43AF10` calls `IsNearlyStopped_5636E0`, which compares GetLength_2 with Q14 0x1333; upstream conditions and the velocity measure need further investigation before converting that constant. Exit still stops the car immediately; unoccupied coasting is pending.

Reported performance issue: rubbing sideways along a wall appears to drop frames. A 3600-tick headless sweep on Wall impacts at steering -1/-0.3/0/0.3/1 stayed below 0.5 ms per tick in the measured run; max angular velocity stayed below 0.154 source radians/update. This does not reproduce or resolve the player's symptom. Need map/location confirmation and browser frame measurement, including the original city path.

### Wall-rubbing diagnosis resolved

Player screenshot identified Wall impacts, car almost parallel to the wall. Reproduction at x=-35, y=1.17, heading PI/2+0.01 and vx=.235 source units: **38 of 60 ticks rejected all movement**, despite the ~27 m/s speed reading. The cost was not a slow physics tick: full-pose rejection also discarded tangential movement. Fix separates the candidate pose by penetration depth plus 0.1 mm and applies the contact impulse, preserving travel along the wall. Regression first failed with 38 rejected ticks, then passed with zero; browser replay traveled to x=-9.48985 with no stuck ticks.

Browser timing is environment-specific, not a user's GPU benchmark. In the comparison run, advance+render CPU work averaged 0.385 ms freely and 0.355 ms along the wall. Headless frame intervals were 67.8/83.2 ms; these noisy display intervals do not establish actual user-device FPS. The directly reproduced stuck-motion symptom is corrected; do not claim a universal rendering-performance improvement.

## Calibrated profiles in original Downtown — 2026-09-05

Parked selection now shares explicit CARI model IDs between sim and renderer: sprite IDs [0,1,2,5,8,9,11,12,13,14] correspond to models [0,1,2,5,8,10,12,13,14,16]. Romero/Wellard (models0/1; parked IDs0,1,10,11) use tested handling, motor audio and saved skid trails. The other twelve parked cars retain legacy motion until their profiles are verified. This is four cars, not all83models. Art follows handling.model on lab maps too; changing maps replaces/disposes extracted geometry as required.

Road assistance queries the supporting flat GMP road block at current elevation, preserving source arrow-mask priority and bridge separation. Slopes remain excluded from assistance; city wall/car impacts still stop the car and have not acquired the lab wall impulse resolver. Elevation updates propagate from the driven car to its occupant. Old original-map saves lacking these handling profiles are rejected; start a new game for this layer.

The old 60tick acceleration/60tick handbrake scenario hit a parked car with the faster physics and would have falsely called the resulting stop braking. New scenario uses30ticks acceleration and120ticks handbrake, with explicit collisions=0 checkpoints: acceleration y712.7319897698774/speed5.536960197070554, stop y709.9192372939868/speed0. These are deliberate mechanics changes, not bookkeeping hash changes. Existing other scenarios stay unchanged. Browser verifies motor3, source artwork/model correspondence, skid rendering at z8, save continuation, real E/W/Space and collision-free shared scenario.

## Unoccupied coasting — 2026-09-05

Exit below the current4.2m/s threshold preserves linear/angular momentum; releases gas/foot/hand input. This pedal-release policy remains a provisional reconstruction. A shared vehicle step advances both occupied and moving unoccupied cars; only occupied movement follows controls and adds player distance. Empty vehicles receive no lane assist. Stationary cars skip updates, and `vehicleAtRest` checks linear and angular motion explicitly. Restore continues their existing handling state without extra timers. Legacy cars use their existing drag.

Lab `Exit while rolling` and shared scenario `coasting-demo.json` cover exit, separate pedestrian position, rolling and rest. Tests also cover wall contact, no overlap with the pedestrian, save continuation while the pedestrian moves and legacy coasting. Contact with a pedestrian currently stops motion, not damage; moving-body impulses, NPC drivers and unoccupied skid/audio observers remain later layers. Existing scenario expectations were not changed by this layer. 130 GTA-tests/typecheck and browser coasting+Downtown verified.
