# gta2ctl — control a running game from the shell

Agents used to test the game with `--keys=FRAME:KEY` and guessed frame timings. gta2ctl
replaces the guessing: start the game with `--ctl`, then a shell script calls
`gta2ctl <command>` and gets one JSON line back. Bash is the scripting language (loops, `if`,
`jq`); there is no language of our own.

```sh
host/build.sh                                   # builds host/loader and tools/gta2ctl/gta2ctl
(cd host && arch -x86_64 ./loader ../data.pak --entry --ctl --keys=150:RETURN,250:RETURN) &
C=tools/gta2ctl/gta2ctl
$C --wait-sock=60 wait in_game eq 1 1200        # the two RETURNs start Downtown
$C teleport 132 195
$C enter_car nearest                            # {"ok":true,...,"result":"driver","car_id":29,...}
$C state | jq .money
$C quit
```

The full worked example is `tests/ctl/smoke.sh` (below).

## Running the game with it

| Option (loader) | What |
|---|---|
| `--ctl` | open the socket at `$TMPDIR/gta2ctl-<pid>.sock` (printed: `ctl: listening on PATH`) |
| `--ctl=PATH` | the socket at PATH (made absolute; max 103 bytes, a Unix socket limit) |
| `--telemetry=PATH[,every=N]` | write the state fields as one JSON line every N presented frames (default 1), with or without `--ctl` |

Without these options nothing of gta2ctl runs. Several games with `--ctl` run side by side:
each has its own socket (the pid is in the default name).

## The client

`tools/gta2ctl/gta2ctl` is a small native C program (`tools/gta2ctl/gta2ctl.c`, built by
`host/build.sh`, git-ignored). It joins its arguments with spaces, sends them as one line,
prints the reply line and exits:

| Exit | Meaning |
|---|---|
| 0 | `"ok":true` |
| 1 | `"ok":false` (an error, or a blocking command that ended badly: `stuck`, `preempted`, …), no game, bad usage |
| 2 | `"result":"timeout"` (the game's frame timeout), or no reply within `--timeout` seconds |

| Client option | What |
|---|---|
| `--sock=PATH` | the game to talk to |
| `--wait-sock=SEC` | keep trying to connect for SEC seconds (a game that is still starting) |
| `--timeout=SEC` | wall-clock limit for the reply, default 600 (frames do not advance while a level loads) |
| `gta2ctl list` | the sockets found, `live` or `stale` (a game that was killed leaves its socket file behind) |

Which game: `--sock`, else `$GTA2_CTL`, else the only live `gta2ctl-*.sock` in `$TMPDIR`, the
per-user temp dir or `/tmp`. With two live games and no choice the client refuses and lists
them. **Agents running in parallel: always start the game with `--ctl=PATH` and export
`GTA2_CTL=PATH`** — "the only live one" is a convenience for a human at a terminal.

`shot` paths are made absolute by the client (the game's working directory is its overlay
`~/Library/Application Support/gta2-resurrected/`).

**zsh:** an unquoted `==` is zsh's `=command` expansion (`= not found`). Quote the operators
(`'=='`, `'>='`) or use the word forms `eq ne lt le gt ge`. bash has no such problem.

## Protocol

One request line `cmd arg arg...` → one reply line, JSON:
`{"ok":true,"frame":N,...}` or `{"ok":false,"frame":N,"error":"..."}`. Blocking commands that
end without reaching their goal reply `{"ok":false,...,"result":"stuck"}` (or `timeout`,
`preempted`, …). Anyone can speak it: `printf 'state\n' | nc -U "$GTA2_CTL"`.

Commands are executed on the game thread at a frame boundary: once per presented frame
`Vid_FlipBuffers` calls `ctl_frame` (`host/c/ctl.c`), which accepts clients, reads their lines,
starts commands and advances the blocking ones. Up to 8 clients at once, one command each at a
time (further lines queue). The steering commands (`goto`, `face`, `enter_car`) share the
player: a new one preempts the old one, which replies `"result":"preempted"`. Closing the
connection cancels the client's command.

Timeouts are in **presented frames** (`frame` in every reply). In gameplay one frame is about
one game tick (33 ms); while the game is paused frames still count, ticks do not.

## Commands

Coordinates are blocks (floats, 1.0 = one map block); headings are degrees, **0 = facing +y,
90 = facing +x** (the game's Ang16: x = sin h, y = cos h).

| Command | Blocks | Reply / notes |
|---|---|---|
| `ping` | | `{"ok":true,"frame":N}` |
| `help` | | the command list |
| `state` | | the state fields below, plus `cars` / `peds`: the 5 nearest of each |
| `teleport X Y [Z]` | | on foot: `Ped_Teleport` (ground z) or, with Z, `TeleportGameObject`; in a car: `TeleportCar` (moves the car). Takes effect on the next tick |
| `face DEG` | ≤ 60 frames | on foot; `"result":"facing"` |
| `goto X Y [TIMEOUT] [--straight [--radius=R]]` | default 3000 frames | walks there by the game's own routing: gives the player the GO_TO_AREA_ON_FOOT (12) objective, so the ped AI goes around walls and parked cars; our steering stays off. `arrived` (within 0.5 or objective passed), `objective lost`, `stuck`, `timeout`. Measured 2026-10-22: start (159.5, 139.5) → road (168.5, 133.5) in ~175 frames along a bent path, and back out of the start courtyard in 347 frames. `--straight`: the old straight walk (our steering), `arrived` within R (default 0.3), `stuck` = no 0.05-block gain in 90 unpaused frames. On foot only. `--run` is accepted and ignored |
| `walk_to X Y [TIMEOUT]` | | the same as `goto` (routed) |
| `enter_car nearest\|ID [TIMEOUT] [--straight] [--key] [--passenger]` | default 1800 frames | walks to within 1.5 blocks of the car by the game's routing (re-aimed every 30 frames, so it follows a moving car; `--straight`: our straight walk instead), then gives the game's own enter order; the game walks the ped to a door and gets in, jacking a driver if there is one. `"result":"driver"` / `"passenger"`, `car_id`, `car_model`, `target_car` (false = it ended up in another car). Failures: `stuck`, `no reachable door` (3 tries, 300 frames each), `enter failed`, `car gone`, `timeout`. `--key` presses RETURN instead (the game then picks the car half a block in front). `--passenger`: get in as a passenger (no jack): the order with the passenger flag and door 1 (`no passenger door` on doorless models), or with `--key` LSHIFT+RETURN, the passenger mod's key ([passenger.md](passenger.md)) |
| `exit_car [TIMEOUT] [--key]` | default 600 frames | `"result":"on foot"`; refused while the car is too fast to leave (`Car_CanExitCar`, \|v\| ≥ 0.3) |
| `drive_to X Y [TIMEOUT] [--debug]` | default 5400 frames | **experimental**: the game's own car AI drives the player's car there (as ambulances and fire engines go to a call): the player gets GO_TO_AREA_IN_CAR (14), the car gets a CarAI and a drive order, and for the run the car counts as a mission car with AI physics (see "Where the code is"). `arrived` (within 4 blocks, or the objective passed), `stuck` (moved < 0.5 block in 900 frames: lights and jams take a while), `out of the car`, `objective lost`, `timeout`. The car keeps its lane and follows the road arrows, so it may drive away from the target (one-way streets) before it comes back. `--debug`: the AI state every 15 frames into the game log (`ctl: drv …`). Driver only |
| `key NAME [FRAMES]` | FRAMES (default 4) | a tap: down now, up FRAMES later; names as in `--keys` (`RETURN`, `UP`, `LCONTROL`, `A`, …) |
| `keydown NAME` / `keyup NAME` | | hold / release (e.g. drive: `keydown UP` … `keyup UP`) |
| `spawn car MODEL [REMAP]` | | REMAP -1 random (default), 0 none, i = the model's i-th remap; `id` = the car id for `enter_car` |
| `spawn ped REMAP [ROLE] [--behave=normal\|hostile\|follow]` | | ROLE: `auto civilian gang cop swat fbi army medic fireman elvis mugger thief psycho criminal still` or its number (the K menu's roles) |
| `spawn object TYPE [REMAP]` | | an `OBJECT_TYPE` number |
| (spawn options) `--at=X,Y[,Z] --rot=DEG` | | default: in front of the player (1.5 blocks, 1 for a ped), facing his way, like the K menu. Mind the walls: a car spawned into one has no door to get in through |
| `wait FIELD OP VALUE [TIMEOUT]` | default 1800 frames | OP `== != < <= > >=` (or `eq ne lt le gt ge`); VALUE a number or `true`/`false`. `"result":"met"` with the field's value, or `timeout`. A field that does not exist right now (`money` in the frontend) is not met |
| `wait frames N` | N frames | `"result":"done"` |
| `shot PATH` | | the current frame as BMP (the `--shot` writer) |
| `log TEXT` | | `ctl: log [frame N] TEXT` into the game's log |
| `sms TEXT` | | shows TEXT in the game as a mission brief (the "SMS" with the speaker's face, bottom left), at once, replacing our previous one; on screen for ~0.1 s per character (`text_speed`). Printable ASCII only (no Cyrillic); `_` and `#` become `-` (a blank glyph and the highlight toggle) |
| `sms_echo on\|off` | | every following command (except `state` and `ping`) also arrives as an `sms` with its own text: a script's steps can be followed in the game window |
| `quit` | | replies, removes the socket and exits (status 0) |

Every command and its arguments are case-sensitive except key names.

## State fields

The flat fields of `state`, of every telemetry line and of `wait`. Outside a game only
`frame`, `in_game` and `focus` exist.

| Field | Type | What (source) |
|---|---|---|
| `frame` | int | presented frames (`r_frames`) |
| `in_game` | bool | a level is running with a player ped (`Game` 0x5EB4FC → `currentPlayer` → `ped`) |
| `paused` | bool | `Game.gameStatus == 2` (Esc, the K menu) |
| `focus` | bool | the window has keyboard focus (`have_focus`; see "Limits") |
| `x` `y` `z` | float | the player, blocks; the car's body while in a car |
| `heading` | float | degrees, as above (the ped's or the car's body rotation) |
| `health` | int | `Ped.health` |
| `armour` | int | `Player.powerups[ARMOR]` |
| `money` | int | `Player.score.money.value` |
| `wanted` / `wanted_points` | int | stars 0..6 (600, 1600, 3000, 5000, 8000, 12000 points, `Ped_GetCopStars`) / `Ped.wantedPoints` |
| `in_car` / `driver` | bool | `Ped.currentCar` set (only once seated) / that car's driver is the player |
| `car_id` / `car_model` | int | −1 on foot |
| `speed` | float | the car's \|`CarPhysics.linVel`\|, blocks per tick (×30 = blocks/s); 0 on foot |
| `weapon` / `ammo` | int | the selected (in a car: the car's) weapon, `WEAPON_INDEX`, −1 none |
| `ped_state` / `objective` | int | `Ped.state` (`PED_STATE`: 0 walk, 3 entering a car, 7 staying, 9 wasted, 10 in a car) / `Ped.objective` (35 ENTER_CAR, 36 LEAVE_CAR) |
| `ped_id` | int | the player's ped id |
| `dead` | bool | `Player.isDeadOrBusted` (wasted or busted, ~70 ticks until the respawn) |

`cars[]`: `id model remap x y z dist has_driver speed`, nearest first, the player's car left
out. `peds[]`: `id remap occupation x y z dist in_car alive`, the player left out.

Telemetry example (`--telemetry=t.jsonl,every=30`):

```
{"frame":270,"in_game":true,"paused":false,"focus":true,"x":159.500,"y":139.500,...,"dead":false}
```

## How agents should test

- **Prefer gta2ctl to `--keys` timings.** Use `--keys` only to get through the frontend
  (`--keys=150:RETURN,250:RETURN` starts Downtown), then `wait in_game == 1` **and
  `wait frame >= 260`** (past the last scripted key), and drive the rest with commands whose
  replies say when they are done. Without the second wait a level that started early (a real
  key press while the window had focus: measured, gameplay at frame 60) gets the pending
  `--keys` RETURNs as Enter, which enters or leaves a car in the middle of the test.
- One game per agent: `--ctl=$TMPDIR/gta2ctl-<something unique>.sock` and `GTA2_CTL` set to it;
  the socket name must match `gta2ctl-*.sock` to show up in `gta2ctl list`.
- Gate on facts, not on time: `wait money >= 333`, `wait in_car == 1`, `wait speed < 0.01`.
  Check the exit code (`set -e` stops at the first failure).
- Levels start from the same RNG seed (1) every time (Seq 27), so a scripted run without
  real input repeats closely: the smoke test's frames matched run to run within a few.
- Run it in a visible pane (`dev3 pane run`), and never with `--bg-audio`; nothing here moves
  the mouse or touches the desktop.

### `tests/ctl/smoke.sh`

`tests/ctl/smoke.sh [OUT_DIR]` starts Downtown with `--ctl`, a telemetry file and a config
with `mods: car_enter_bonus: 333`, then: `state`; `teleport 132 195` (2 blocks from parked car
29); `enter_car nearest`; `wait in_car == 1`; `wait money >= 333` (the bonus); `exit_car`;
`goto 132.5 199.5` (5 blocks across the plaza); `spawn car 13 --at=129,199 --rot=90`;
`enter_car <its id>`; `wait money >= 666`; `wait frames 60`; `shot`; `exit_car`; `shot`; `log`; `quit`.
Measured 2026-10-22: PASS, ~25 s, and two copies at once both PASS (two sockets, `gta2ctl
list` shows both, a bare `gta2ctl ping` refuses to pick).

Also measured by hand: jacking a stopped driven car (`teleport` next to it, `enter_car ID`:
`driver`, +$25 jack reward), driving with `keydown UP` / `wait speed > 0.05` / `keyup UP`.

## Where the code is

| Part | File | Why there |
|---|---|---|
| socket, protocol, commands, telemetry, options | `host/c/ctl.c` | a host feature (64-bit host C, `docs/host-c.md`) |
| state, nearest lists, teleport, enter/exit orders, steering | `host/c/ctl_game.c` | the game side of the same feature; its per-tick work is two `Player` fields, written from the existing NASM hook. A C32 half would need the command state twice, shared through exports |
| spawning | `host/c/spawn.h`, implemented by the K menu (`host/c/menu/helpers.c`, `spawn_ped.c`, `spawn_object.c`, `docs/debug-menu.md`) | the K menu's recipes |
| hooks into the host | `vid_FlipBuffers` → `ctl_frame` (`w32_renderer.asm`), `hk_MoveOnFoot` → `ctl_on_foot` (`player_move.asm`), `_main` → `ctl_arg` / `ctl_init` (`loader.asm`), `input_push_key` (`w32_dinput.asm`) | |
| game hooks (`w32_hooks.asm` CALLHOOKs, handlers in `player_move.asm`) | `CarDriverClass` 0x429EDC, `DriveCar` 0x4A78F3 (drive_to); `BriefText` 0x4C6561 / 0x4C65C2 (sms) | call-site detours that only change anything while gta2ctl uses them |
| client | `tools/gta2ctl/gta2ctl.c` | native, no Rosetta |

Game facts used (Seq 27's answers, `docs/re/ped-movement-collision.md`):

- **Steering** writes `Player.turnRate` (+8, the whole heading delta, so the ped turns in one
  tick) and `Player.moveSpeed` (+0xC = +1.0) after `Player_MoveOnFoot` 0x4A5C50 every tick; the
  walker 0x49A560 turns and steps through its own collision. Not while wasted/busted
  (`isDeadOrBusted`, `controlState`: the game drives the corpse then), in a cutscene
  (`controlsDisabled`), or while the ENTER_CAR objective walks the ped to a door.
- **Entering** is the enter branch of `Player_HandleControls` 0x4A76D0 with our car instead of
  `Ped_FindEnterableCarInFront`: `Ped_SetTask(NO_OBJ)`, `PedSetObjective(ENTER_CAR 35, 9999)`,
  `Ped_SetObjCar`, not as a passenger, door 0 (`--passenger`: passenger flag 1, door 1). No
  key and no focus needed. Vanilla 11.44 has no passenger key; the passenger mod adds
  Shift+Enter ([passenger.md](passenger.md)).
- **Exiting**: `Car_CanExitCar` 0x4222A0, then `PedSetObjective(LEAVE_CAR 36)` and
  `Ped_SetObjCar`.
- `Ped.currentCar` is set only when seated; a seated ped has no game object (position from
  the car).
- **drive_to** (Seq 27's recipe plus own measurements): `Car_AllocAI` 0x421510 +
  `CarAI_SetParentCar` 0x42A9D0 (a player's car has no CarAI), `Car_EngineOn` 0x426E00 (the
  gas key starts it otherwise), `Car.driverClass` (+0x7C) = 5 MISSION (`CarAI_DriveStep` drops
  the route flag for 2 PLAYER), `Car.aiFlags` &= ~3 (stale turn bits), `CarPhysics.mode`
  (+0x8C) = 1 AI (in 2 PLAYER the drive force needs the gear logic of `Player_DriveCar`, and the
  car did not move at all), then `PedSetObjective(GO_TO_AREA_IN_CAR 14)` with the target before
  and after the call. Two hooks for the run: `Ped_GetPedClass` in `Car_Update` answers 3 for
  the player (else `CarAI_PreUpdate` is skipped) and `Player_DriveCar` is skipped (keys). The
  stop undoes all of it: objective 0, `CarDriveOrderPool_Free` 0x446290, `Car_HaltAI`
  0x421540, `Car_FreeAI` 0x4266F0, class and physics mode back. The route is re-planned every
  tick (`CarAI_UpdateDriveOrder` 0x42D390).
- **Turn assist** (`ctl_drive_assist`): with the player's car the AI's junction turn was too
  wide (measured: ~60 of 90 degrees in the time the turn steers, CarAI flag 0x80), so the car
  left the junction over the kerb and lost its route. While the flag is up, the car is turned
  8 more Ang16 units per tick (about 2 degrees) toward `CarAI.turnExitDir` (+0x44), never past it.
  Measured on the same route: 22-33 unstick ticks and a lost route before, none after.
- **sms**: `Hud_Brief_Enqueue` 0x4C6690 (stdcall, ECX = `g_HudManager` [0x672F40] + 0xE4) with
  the key `ctlsms`, private priority 4, after `ClearAllBriefsWithPriority(4)` 0x4C6860; the
  `Gxt_FindTextW_thunk` calls in `Hud_Brief_PrepareCurrentText` answer our text (low arena,
  u16 font codes) for that key ([re/hud-and-menus.md](re/hud-and-menus.md) §3.1).

## Limits

- `goto --straight` walks straight: anything in the way ends in `stuck`. Plain `goto` routes.
- `drive_to` is experimental. It goes the game planner's way, which follows one-way streets
  and can be a long loop: measured 2026-10-23 over 5 legs in Downtown, 4 arrived (1467-4087
  frames), one 45-block leg drove 303 blocks, and a far one timed out halfway. The car waits at
  lights and in jams like traffic. A target off the road (a courtyard) ends next to its fence.
  `face` on foot only.
- After `teleport` on foot the camera does not follow at once: it stayed where it was for 250
  frames and snapped back on entering a car (Seq 59, 2026-10-22). Wait a while before a `shot`,
  or teleport only where needed.
- `key`/`keydown` go through SDL like `--keys`, so they need the game to see keyboard input:
  after the window has had focus and lost it, focus loss releases keys and the game's
  foreground keyboard is not acquired (`focus` false in `state`). `goto`, `face`, `enter_car`
  and `exit_car` without `--key` do not use keys and work regardless.
- Spawning in front of the player can put a car into a wall; use `--at`.
- The camera is not settled right after `enter_car`: entering switches to the car camera,
  which starts zoomed far in and pulls out (a `shot` 1 frame later showed only a roof
  close-up; 60 frames later the car and street, measured 2026-10-22). `wait frames 60`
  before a screenshot; phase 2 could expose the camera zoom as a `wait` field.

## For phase 2 and 3 (notes)

- Pathfinding (done in `goto`): the ped AI walks routes itself (`Ped_MoveTowardTarget`) once
  the player ped has GO_TO_AREA_ON_FOOT; `ctl_order_walk` sets the target after
  `PedSetObjective` (which zeroes `objectiveTargetPosition` +0x1DC) as well as before.
- Driving: in a car `turnRate`/`moveSpeed` are unused; `Player_DriveCar` 0x4A4C40 reads the
  key bools (`keyForward` gas, `keyBackward` brake/reverse, `keyLeft`/`keyRight` steering,
  `keyJump` handbrake). Steer by OR-ing `Player.inputWord` bits (0x1 fwd, 0x2 back, 0x4 left,
  0x8 right, 0x40 jump; 0x20 enter/exit) after `SetKeyState`, before the logic step — the
  real key path, focus-independent. Car heading `CarPhysics.heading` (+0x58).
- Determinism: the RNG is the CRT seed `random_seed` 0x595410, seeded 1 by `Game_Ctor`
  (`ResetRandomSeedTo1`); pacing is `drawAndLimitFrames` 0x462A30 (33 ms steps against
  `timeGetTime`). Registry `max_frame_rate = 0` (with `min_frame_rate = 0`) should make one
  logic tick per flip, untested; or give the `timeGetTime` shim a virtual clock (+33 ms per
  flip). Input is sampled once per tick, so injection keyed on `g_FrameCounter` 0x5E8108 is
  exact. Fast-forward = skip presents while keeping the tick/flip pairing.
- Seq 27's full answers (enter-car search radius, door positions `Car_GetDoorWorldPos`
  0x422500, game-state tests): `reply-seq58-gta2ctl-re.md` in its task (summarised above).
