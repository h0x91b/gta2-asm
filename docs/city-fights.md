# City fights: cops vs gangs, gangs vs gangs

A C32 mod (`host/c32/city_fights.c`, [c32.md](c32.md)) that lets the city fight without the
player: cops attack gang members, gang members attack cops, more armed gang members walk the
streets, and some of them turn up on a rival gang's turf. Off by default; off is the vanilla
behaviour (the hooks return what the original code returned and touch nothing).

- Config: `mods: city_fights: on` in `config.yaml` (`host/c/config.c` key table).
- K menu: Mods → **City fights** (a flag row, `host/c/c32_host.c`). The host byte is copied
  into the image's `city_fights` once a frame (a `DM_FRAME`), so the hooks read it without a
  mode switch; the switch takes effect on the next frame and is logged
  (`c32: city_fights on`).
- Test: `tests/ctl/city_fights.sh on|off [OUT_DIR]` (below).

RE background: [re/gangs-and-peds.md](re/gangs-and-peds.md) §4 (spawn) and §6 (the hostility
predicate), [re/ped-ai.md](re/ped-ai.md) (objectives / tasks).

## What vanilla does (verified in Ghidra, `gta2.segments.fixed.exe`)

- **The predicate** `Ped_ShouldReactToPed(observer, candidate)` 0x4371D0 (thiscall, `ret 4`,
  `al` = attack) is asked by both threat scans (`Ped_ThreatSearchCandidateFilter` 0x4B9A10:
  area mode skips AMBIENT-class candidates, line-of-sight mode does not). A yes from it makes
  `Ped_UpdateThreats` 0x43F340 give the observer task KILL_CHAR_ON_FOOT (20) on the candidate.
- **Cops** (occupations 24–27, 29–31, 37, no gang) attack a non-player only when that ped is
  attacking (`flags & 0x800`) or has task 20. A gang member minding his own business is left
  alone; once he shoots, cops shoot back.
- **Gang members** attack cops only with `GangRespect.highRespectFlag` (respect > 79), and
  another gang's member whenever `hostileToGang[id]` is set — initialised to 1 for every pair,
  never cleared, so **rival gangs already fight on sight in vanilla**.
- **Why they rarely meet**: `DummyPedManager_SpawnAmbientPed` 0x4404F0 makes an armed gang
  member only while `g_ArmedGangPedCount` (u8, 0x5E5BD4) < 4 — four for the whole city — and
  only for the gang whose zone holds the spawn tile. Foot cops are one at a time
  (`g_FootCopPedCount` 0x5E5BD3 is a 0/1 flag); car crews do not react to threats while
  seated.
- Cops keep the KILL task on a non-player: the give-up test in `Ped_UpdateThreats`
  (0x43FC6A..0x43FC87) drops it only when the target has no wanted stars **and** is a player.
  The function Ghidra calls `Ped_HasWeapons` 0x41B0A0 is `ped->player != 0` (+0x15C), not a
  weapon test.

## What the mod changes

| Hook | Where | Change when on |
|---|---|---|
| entry detour | `Ped_ShouldReactToPed` 0x4371D0 (displaces `sub esp,0xC; push esi; mov esi,[esp+0x14]`) | the original runs first; a **no** becomes a yes for a cop observer vs any gang member, and a gang observer vs any cop. Skipped: the player as candidate or observer with a player-centric threat search (3..6), invisible candidates, same group, a victim already attacked by ≥ 4 (the game's own cap) |
| entry detour | `DummyPedManager_SpawnAmbientPed` 0x4404F0 (stdcall, `ret 0x10`; displaces `sub esp,0x18; push ebx; push ebp; push esi`) | `g_ArmedGangPedCount` is lowered by up to 8 around the call and restored after it, so the cap is 12 armed members instead of 4 and the counter stays exact |
| mid hook | 0x440825 in the same function (`mov ecx,[esi+0x17C]`, between the gang's remap and `Gang_PickWeaponByRespect`) | one armed member in 3 becomes a **raider**: `ped->gang` and `ped->remap` switch to another gang of the level, so he wears its colours and carries its weapon on the local gang's turf |

Rival gangs fighting is the game's own rule; the mod only makes them meet. The raider's
random choice uses its own xorshift, not the game's `Random_S16`, so the level's random
stream is the same as vanilla until a raider is actually made.

Log lines (`c32: city_fights: …`): each new attacker/victim pair of a widened or gang-vs-gang
decision (the last 16 pairs are remembered, so a long fight logs once), each raider
(`ped 196 raids zaib turf as a loon member`) and each armed member above the vanilla cap.
`cf_stats` (exported) counts them.

## Verification (2026-10-24, Downtown)

`tests/ctl/city_fights.sh` walks from the start to the pavement at (168.5, 133.5) — a walk,
not a teleport: after a teleport the camera lags behind and peds off screen despawn in 40..100
ticks — then follows two spawned scenes through `gta2ctl ped ID` (health, state, task, target):

| scene | on | off |
|---|---|---|
| calm Zaibatsu member and a cop, 4 blocks apart, facing | both take task 20 on each other at once; the cop died (0 hp, state 9), the gang member kept 50 hp | 16 s side by side, both 100 hp, task 0: vanilla |
| Loonie vs Zaibatsu, 4 blocks apart | fight (task 20 both ways, both hurt) | the same fight: native |

Natural run, no spawned peds (mod on, player standing at (99, 20) on Zaibatsu turf near the
Loonies border, 90 s): 6 raiders (Yakuza and Loonies), the armed count reached 11 of 12,
Zaibatsu members attacked each raider 1–3 at a time, at least two Zaibatsu members and a
bystander died, a Loonie raider moved on from one victim to the next. With the mod off the
same 90 s had no task-20 ped near the player — and neither had a run with the mod on before
the raiders existed (only the predicate and the cap): every armed member there was a
Zaibatsu, and no foot cop came by. That run is why raiders exist.

K menu: Mods → "City fights: off" → RETURN → "City fights: on", log `c32: city_fights on`;
RETURN again → `c32: city_fights off` (run without config, keys through `gta2ctl key`).

## Limits and ideas

- Cops in cars still ignore gang fights (vanilla: a seated crew only scans for the player).
  Foot cops stay one at a time (`g_FootCopPedCount` is a flag, not a counter, so the
  lend-and-restore trick of the gang cap does not apply).
- Cops attack every gang member they see, not only armed ones; the K menu has no knob for it.
- Possible next steps: police *pursuit* of gang members with stars (the `JNZ` at 0x44571C in
  `Ped_Update`, [re/gangs-and-peds.md](re/gangs-and-peds.md) §8), a cap / ratio knob for the
  raiders, and gang cars raiding rival turf.
