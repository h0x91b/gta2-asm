# Wanted thief: the police hunt a ped

K menu → Spawn → **Wanted thief: 4 stars** (LEFT / RIGHT 1..6, RETURN spawns), or
`gta2ctl spawn thief [STARS]`. A car thief in red (`PED_REMAP` 17, the ambient mugger's
bright red; role "car thief": occupation 16, class 6, so the game's own `Ped_UpdateCarThief`
0x442050 makes him jack a nearby ambient car) appears 1.5 blocks in front of the player, and
the police hunt **him** exactly as they hunt a player with that many stars: patrol cars
nearby join with sirens, police cars are dispatched, at 4 stars a SWAT van, at 5 FBI, at 6
the army; cops on foot and the crews shoot him; when he has driven a stolen car for 3 s a
roadblock goes up ahead of it. The player's own wanted level is not touched.

Code: C32 `host/c32/wanted_thief.c` (the hunt), host `host/c/menu/wanted_thief.c` (the row,
`km_spawn_wanted_thief` in `host/c/spawn.h`), the cop predicate in `host/c32/city_fights.c`
(`wt_hunted`), roadblocks through `host/c32/roadblocks.c` (`rb_place_near`). Test:
`tests/ctl/wanted_thief.sh` (env `STARS`, `POLLS`, `STEAL=1`, `AWAY=X,Y`).

## Why it works: the pursuit is not player-specific

Read in Ghidra (`gta2.segments.fixed.exe`, 2026-10-25):

| Function | What | Player gate? |
|---|---|---|
| `PoliceManager_UpdatePursuitTargets` 0x4AA030 | per pursuit slot (`PoliceManager.pursuitTargets[4]` +0x464, 0x7C each): stars from `Ped_GetCopStars(criminal)` 0x434C00 (= `Ped.wantedPoints` +0x20A), crews wanted, dispatches, SWAT at 4, FBI at 5, army at 6 | none (the busted flag is guarded by `pedClass == PLAYER`) |
| `PoliceCrew_Update` 0x4AD600 | the crew's AI: drive to `lastSeen`, LEAVE_CAR, KILL_CHAR_ON_FOOT / DRIVE_AND_ATTACK_CHAR / GO_TO_CHAR_CAR_DOOR on `target->criminal` | none |
| `PoliceManager_DispatchCrewToPursuit` 0x4A9EF0, `PoliceCrew_AddToPursuit` 0x4A9720 | a crew on a road tile near `lastSeen` | none |
| `PoliceManager_RegisterCriminal` 0x4A9D60 | puts a ped into a slot | **`Ped_IsPlayerControlled`**, and its only caller in `Ped_Update` requires `pedClass == 2` (`jnz` 0x44571C) |
| `PoliceManager_AssignCarCrewToCriminal` 0x4AABB0 | a patrol car whose cop saw the criminal joins the chase | **`Ped_IsPlayerControlled`** |
| `Ped_ShouldReactToPed` 0x4371D0, cop branch | a cop marks a *player* as sighted (`PoliceManager_MarkCriminalSighted` 0x4AACA0) and attacks him; a non-player only when he is attacking | **player only** |
| `PoliceManager_Update` 0x4AEF70 | runs `UpdatePursuitTargets` only while `g_policeHaveCriminals` (0x66B7A4) == 1 | — |

So the mod does what the three gated functions would have done, every frame
(`wt_frame`, called from the host's `DM_FRAME`):

1. **Enrol**: the thief into the first free slot (slot 0 when it is free), filled as
   `RegisterCriminal` fills one; `wantedPoints` pinned to the stars' threshold (600, 1600,
   3000, 5000, 8000, 12000); `g_policeHaveCriminals = 1`.
2. **Sighted**: `MarkCriminalSighted` every frame (lastSeen = his position, `sightTimer` 250):
   the police always know where he is, so the chase never drops to SEARCHING.
3. **Patrol cars**: every 15 frames each `PATROL` crew whose car is within 24 blocks joins,
   as `AssignCarCrewToCriminal` does (target, `PURSUE`, `AddToPursuit`, siren).
4. **First crew**: `UpdatePursuitTargets` dispatches the first crew from IDLE only while
   `liveTrafficCrews == 0` — for a player the patrol cars cover that case through step 3's
   native twin. Downtown always has patrol cars, so after 60 IDLE frames with none nearby
   the mod dispatches that first crew itself, with the IDLE branch's settings.
5. **Cops on foot**: the predicate hook says yes for any cop observer vs the thief, so foot
   cops and roadblock guards who see him give themselves KILL_CHAR_ON_FOOT.
6. **Roadblocks**: once he has been in a car for 90 frames (stars ≥ 3), a roadblock of our own
   (`rb_place_near`, the K menu's roadblocks) on the road ahead of the car; at most 2, one
   per 600 frames, the oldest taken down for a new one, all taken down when the hunt ends.
7. **Stays in the world**: `offscreenTicks = 0` (a class-6 ped despawns 100 ticks off
   screen, which would end the hunt at once).
8. **300 hp** at the start (a ped has 100): at 4 stars a 100-hp thief on foot lasted ~10 s,
   too short to see him run; with 300 the chase lasts ~20 s.

The hunt ends when he dies or leaves the game (or a new thief is spawned): his stars go to 0,
the game's own `ENDED` branch sends the crews home (a slot still IDLE with no crew is freed by
us: IDLE has no way out), our roadblocks are removed.

**Slot packing.** `UpdatePursuitTargets` stops at the first empty slot and only slot 0's
`sightTimer` counts down (`PoliceManager_UpdateFirstPursuitTimer` 0x4A9E80). If the player gets
stars while the thief is hunted, the player takes slot 1; when the thief's hunt ends slot 0
would empty and freeze the player's pursuit. So once a hunt has run, whenever slot 0 is empty and
a later one is not, the later one moves down and every crew's `target` pointer follows. Until
the first thief the mod does not touch the slots at all.

## Verification (2026-10-25, Downtown, `tests/ctl/wanted_thief.sh`)

City fights off; player on the pavement at (168.5, 133.5); `spawn thief 4`; 40 polls 30 frames
apart (`polls.txt`):

```
patrol car 64 joins the chase of ped 19
slot 0 state 3, crews 1 (police 1, swat 0), copLevel 4
slot 0 state 3, crews 3 (police 2, swat 1), copLevel 4
t=3: 3 cops after him: 18(occ 24) 20(occ 24) 17(occ 24) | player stars 0
t=6: 8 cops after him: 22(occ 25) 20(occ 24) 24(occ 25) 25(occ 25) 23(occ 25) 21(occ 24) 18(occ 24) 17(occ 24) | player stars 0
t=8: thief 25hp
t=9: thief 0hp — hunt over after 320 frames: he is dead (8 hunters at the end)
```

(That run was with 100 hp. Occupation 24 = POLICE (car crews), 25 = SWAT.) Three crews (two police cars and the SWAT van)
within 2 s, eight cops on him at once, the player at 0 stars throughout. On foot right next to
a patrol car he does not get far: a 4-star player on foot would not either.

With 300 hp (rebased on master 92400c1), the three variants of the test:

| run | what happened |
|---|---|
| default | ran ~10 blocks north and east along the pavement, 8 cops on him at once (police + SWAT), 300 → 0 hp in ~20 s (599 frames), player 0 wanted points |
| `STEAL=1` (`hunt steal`: a car spawned on the road next to him) | in the car within 2 s, drove south; after 90 frames a roadblock went up ahead (`roadblock ahead of ped 19 (slot 0)`); roadblock guards (occ 37), police and SWAT boxed the car in, up to 10 on him at once; dead after ~793 frames (3 runs of 3) |
| `AWAY=168.5,175.5` (player teleported 42 blocks away right after the spawn) | the chase ran off screen: crews spawn near his last-seen point, not near the player; 7 cops, dead 18 blocks north of the start after 370 frames |

He never stole a car by himself in these runs: `Ped_UpdateCarThief` only tries the single
nearest car, and next to the start that is a police car, which it skips. `hunt steal` gives
the same ENTER_CAR order the game's AI would, renewed for up to 300 frames, with
`goalPosition` (+0x1B8) set to the car: `Ped_UpdateCarThief` drops ENTER_CAR when the goal is
far from him, and the goal is worked out from the car only after it has run, so an order
without it was dropped on the next tick (a flee task first, measured in 3 runs of 3).

## Limits

- One thief at a time (the pursuit has 4 slots and the player needs one).
- He is always "seen": no losing the police by hiding. A sight model (only cops who see him
  refresh `lastSeen`) is possible with `MarkCriminalSighted` from the predicate hook instead.
- The player can still collect stars of his own (shooting cops, stealing a cop car); the two
  pursuits then share the crews the game has (20 crew slots, 10 emergency vehicle slots).
- `copLevel` follows the highest wanted level in any slot, so while a 4-star thief is hunted the
  game behaves as at police level 4 everywhere: the ambient ped cap halves (25), foot cops get
  their guns.
