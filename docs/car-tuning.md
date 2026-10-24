# Car tuning (K menu → Vehicle → Tuning)

Live handling of the car the player is in: LEFT / RIGHT on a row changes the value, and it
takes effect on the next physics tick (the menu pauses the game, so in practice: the moment
the menu closes). The physics are the game's own; only its per-model data is edited.

| Row | GCI field (`CarEngineData`) | Step | What it does in the physics ([re/car-physics.md](re/car-physics.md)) |
|---|---|---|---|
| Top speed | `max_speed` +0x28 | ×1.1 / ÷1.1 | the speed cap (`CarPhysics_LimitSpeed`); `gear2_speed` / `gear3_speed` scale with it |
| Acceleration | `thrust` +0x24 | ×1.1 | drive force (half + revs·fifth thrust, gears) |
| Turbo | `turbo` +0x1 | on / off | ×2 revs term at revs ≥ 3 |
| Mass | `mass` +0x4 | ×1.1 | `forceAccum / mass`, inertia, collision impulses (runtime value = GCI ×1.1) |
| Brakes | `brake_friction` +0x10 | ×1.1 | foot-brake drag and handbrake drag in the tyre model |
| Steering lock | `turn_ratio` +0x18 | ×1.1, max 1.5 (86°) | max front wheel angle |
| Turn-in | `turn_in` +0x14 | ±0.05, 0..0.9 | front grip +, rear grip − while steering |
| Rear grip | `rear_end_stability` +0x1C | ×1.1 | multiplies the rear axle's lateral and longitudinal grip |
| Handbrake slide | `handbrake_slide_value` +0x20 | ±0.05, 0..1 | rear lateral grip factor with the handbrake on |
| Front drive | `front_drive_bias` +0x8 | ±0.1, 0..1 | share of the drive force on the front axle (the rear gets the rest) |
| Damage taken | `anti_strength` +0x2C | ±0.1, 0..4 | damage multiplier, 0 = indestructible |

Scaled rows stay between 1/8 and 8× stock. Not offered: `front_mass_bias` (it moves the
centre of mass under a moving car: `cmPos` / `centerPos` would no longer agree),
`skid_threshhold` (tyre marks only, no grip), the gear multipliers.

Then **Reset this model** (the stock record back) and **Reset all models: N tuned**.
The header row names the physics model and says `stock` / `tuned`.

## Per model, not per car

Handling is per model in the game. `g_CarModelTable` (`0x5E5488`) has `engineData[256]`
(+0x404, one NYC.GCI record each) and `physicsData[256]` (+0x000, `CarPhysicsData`: inertia,
wheel offsets, cm offset, half / fifth / turbo thrust, rear drive bias, skid thresholds);
`CarPhysics_SelectModelData` `0x49ECC0` points `g_CurCarEngineData` / `g_CurCarPhysicsData`
at the entries of `Car_GetPhysicsModel(car)` `0x4220A0` at the top of every physics step.
A car owns no handling data of its own.

| Option | For | Against |
|---|---|---|
| **A. Edit the model's records in place (chosen)** | the game's own data path; no hook; every reader (physics, `Car_GetMaxSpeed`, `Car_GetMass`, engine sound pitch) agrees | every car of that model changes, AI traffic included |
| B. Per car: detour `SelectModelData` to a private copy for the player's car | only the player's car | 13 callers of `SelectModelData` are fine, but `Car_GetMaxSpeed`, `Car_GetMass`, `Car_GetModelInertia`, and `CarPhysics_CmFromCpViaModel` read the table directly — each needs its own hook, and a missed one desyncs the car silently |
| C. Per car: clone the records into a spare model id | one switch | there is no spare id: the model id also picks sprites, names, sounds, the GCI count is checked against the style's CARI |

So the tuning is a feature of the **model** the player is driving. The edit is logged with
the model id (`c32: car_tune: model 13 Top speed 0.240 -> 0.264 (110% of stock)`).

## How an edit is applied (`host/c32/car_tune.c`)

1. The first edit of a model copies its `CarEngineData` (the stock values).
2. The field changes in `engineData[model]`.
3. The game's `CarPhysicsData_Build` `0x432AA0` (thiscall: `ecx` = `physicsData[model]`,
   one `byte model`, `ret 4`; it reads `engineData[model]` itself) recomputes the derived
   record, as at level load.
4. **Build stops the game with fatal error 0x3F6 (carinfo.cpp:0x5B) unless
   `gear2_speed ≤ gear3_speed ≤ max_speed`** (disassembly 0x432AC7..0x432B0C). So Top speed
   sets both gear speeds to their stock share of the new top speed, clamped to that order.

The table is rebuilt from NYC.GCI on every level load (`CarModelTable_Load` `0x432FC0`), which
drops all edits; a changed `engineDataBlock` (+0x804) drops the stock copies too. "Tuned" is a
compare against the copy, not a flag.

## Code

- C32: `host/c32/car_tune.c` — `ct_frame(op, field, dir)` (stdcall, exported): 0 refresh,
  1 step, 2 reset this model, 3 reset all; fills the exported `ct_view` (model, tuned, current
  and stock value per row). No 64-bit division in the image (no compiler-rt), so the
  arithmetic stays in int32 (8× the heaviest mass, Tank 45 ×1.1, ×100 fits).
- Host: `host/c/menu/car_tune.c` — the page under Vehicle; the `DM_FRAME` calls `ct_frame`
  only while the page is current or a request is pending.

## Test: `tests/ctl/car_tune.sh [MODEL [OUT_DIR]]`

The same car (default Minx, model 13) down the same straight road in Downtown (y 228.5,
x 184 → 238), full throttle, peak `speed` per run, tuning through the menu's own keys:

| Run | Tuning | Peak speed (blocks/tick) |
|---|---|---|
| A | stock (`max_speed` 0.240) | 0.237 |
| B | Top speed and Acceleration +5 steps (160%: 0.386 / 0.225) | 0.376 (the new cap 0.386 is reached on a longer road: 0.386 in an earlier run) |
| C | Reset this model | 0.240 |
| D | Top speed −7 steps (51%: 0.123) | 0.123 (exactly the new cap) |
| E | Reset all models | log: `reset 1 models to stock` |

Measured 2026-10-24: PASS, ~3.5 min. One earlier run failed in D with the player out of the
car before x 238 (not reproduced; traffic on that road is the likely cause, the failure line
now prints the `state`). The speed cap matches `max_speed` to the third decimal in B and D.
