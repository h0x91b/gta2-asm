# Cars, car sound and car AI in gta2.exe 11.44

The car module `0x410000–0x42FFFF` (car sound, camera, doors, lifecycle, pools, CarManager, the
CarAI helpers) and the drive-order / route-finding code it calls (`RoadNetwork_*` 0x40C000–0x40E3FF,
`CarAI_*` 0x430000–0x432800), read from the binary in Seq 43. Every address is a VA in vanilla
`gta2.exe` 11.44 (base `0x3F0000`); every name is in the Ghidra DB (`gta-2-recovered.gpr`, program
`gta2.segments.fixed.exe`) and therefore in `re/`. "V" = the body was read in the 11.44
decompiler/disassembly; "H" = hypothesis, the name carries `unsure_`. Constants are Fix16 Q14
(`raw / 0x4000`, see [math-helpers.md](math-helpers.md)); zero-in-file `DAT_` values come from
[`re/static_constants.csv`](../../re/static_constants.csv).

Related: [car-physics.md](car-physics.md) (CarPhysics, 0x49D000+), [gangs-and-peds.md](gangs-and-peds.md)
§7 (ambulance / fire-engine managers) and "Calling the services on demand",
[ped-ai.md](ped-ai.md) (ped objectives that give drive orders).

Coverage: the live DB had **348** unnamed functions in `0x410000–0x42FFFF` at the start of Seq 43
(census 2026-10-21 23:55 via `find_functions has_custom_name=false`) and **0** at the end (see §9).

## 1. What lives where

| range | subsystem |
|---|---|
| 0x410000–0x414E4F | sound events and the car-sound helpers: `SoundEventQueue_*`, `SoundEvent_InitFrom*Hit`, impact sample pickers, car-model → engine-sound tables (`unsure_CarModel_GetEngine*`), `CarSound_Add*` emitters, voice range / volume, CarPhysics and CarDoor read-only getters used by sound |
| 0x414E50–0x41DDFF | `SoundMgr_*` (g_SoundManager, the game-side mixer above mss32): request queue, 16 voices, 1020 source slots, listener, pan / distance / Doppler, police radio phrase queue; ComboList (bonus checks, unrelated to sound) |
| 0x41DE00–0x41F5FF | Camera: target / smoothed position, shake, pan, view size, visibility tests |
| 0x41F600–0x42179F | CarDoor, model predicates, roof attachments, upgrades / shop, Sprite helpers, CarManager traffic lists and category counters, CarDeltas |
| 0x4217A0–0x42A4FF | Car lifecycle: model checks, lights / siren deltas, damage, wreck, explosion, recycling, trailers, trains, pools |
| 0x42A500–0x42FFFF | CarAI helpers and drive orders: `CarAI_Ctor/Reinit`, `Fix16_ChebyshevDist`, `CarAI_SetRouteTarget`, junction reservation, lane change, `CarAI_UpdateDriveOrder`, `CarDriveOrder_Drive` |
| 0x430000–0x432800 | CarAI per-tick: `CarAI_FollowRoute`, `CarAI_ApplyRouteTurn`, `CarAI_FollowLane`, `CarAI_UpdateJunctionTurn`, `CarAI_DriveStep`, `CarAI_Update`, `CarAI_PreUpdate` |
| 0x40C600–0x40E3FF | RoadNetwork (RGEN junction graph): segment → junction lookup, A*-like search, route slots |

## 2. Car sound (SoundManager)

`g_SoundManager` 0x5DCBC8 (a static `SoundManager` object, 0x5578 bytes; was `S6`, 0x5540) sits above our mss32 reimplementation
([win32-shims.md](../win32-shims.md) "Audio"). Per tick `SoundMgr_Update` → `SoundMgr_UpdateFrame`:

1. flip the request double buffer (`+0x98`), reset the sort index;
2. `SoundMgr_UpdateListenerAndSources` 0x417030: listener from the player's ped (or its car), then
   `SoundMgr_UpdateSource` 0x4163A0 for every active slot — a switch on the source kind: 1 sprite
   (ped / car / object → `SoundMgr_UpdateSpriteSource` 0x4162C0), 2 music stream, 3 radio, 6 event
   queue, 7 weapon, 10 vocal, 0xB HUD counter;
3. each branch fills the pending request (`SoundManager+0x30`, a 0x68-byte record) and calls
   `SoundMgr_QueueRequest` 0x4171A0 when audible (`SoundMgr_IsVoiceInRange` 0x4116B0,
   `SoundMgr_ComputeVoiceVolume` 0x4116F0 → `SoundMgr_CalcDistanceVolume` 0x416DA0);
4. repeating requests are re-issued, then the sorted requests are mapped onto the 16 Miles voices
   (`SoundManager+0xDC0`, 0x68 each) by (slot, emitter id).

Sources live in a 1020-entry slot table at `SoundManager+0x147C` (stride 0xC: `+0` used, `+1` age capped at 10,
`+4` source*, `+8` extra*); the active list is at `+0x444C`, count `+0x543C`. A source
(`SoundClient`, 16 bytes, pool of 1000) is `+0 kind, +4 inactive, +8 voice channel, +0xC owner`.

Car sources: `SoundMgr_UpdateCarSource` 0x415DF0 dispatches on the car's info index (0x36, 0x3C
special); the default chain adds engine, heavy-vehicle slide / idle, speed loops, tyre slip, doors,
alarm, horn (`SoundMgr_UpdateCarHorn` 0x415880, `Car_IsHonking`), siren (`SoundMgr_UpdateCarSiren`
0x415A90, `Car_IsSirenActive` 0x414F80 = emergency lights && `SIREN_ON` bit), damaged engine, shop
and bomb ticks. Police radio: a ring of 15 phrase ids (`policeQueue`, **15 dwords** at
`SoundManager+0x552C`, read index `+0x5528`, write index `+0x5529`) filled by crime-report /
car-description / location builders and drained by `PoliceRadio_Update` 0x41C600 (§2d).

### 2a. Layers, top to bottom (U1 pass, 2026-10-24)

"Verified" in §2a–§2f = read in code at the quoted VA; nothing here was reproduced at runtime.

1. **Game objects → SoundClient.** Every object that makes sound owns a 16-byte `SoundClient`
   (`kind, disabled, sourceSlot, owner`) from `g_SoundClientPool` 0x5D85A0 (`SoundClientPool_Create`
   0x410750), plus three embedded or static ones: `SoundManager.vocalClient` +0x5454 (kind 10, slot in
   `vocalSourceSlot` +0x5450), `SoundManager.radioClient` +0x550C (kind 3, slot in `radioSourceSlot`
   +0x5508) and `g_FrontendMusicSoundClient` 0x5EAF40 (kind 2, owner `MainMenuSoundPlay`).
   `SoundMgr_AttachClient` 0x417DB0 hands out a 1-based source slot (1..1019, table +0x147C, stride
   0xC); `SoundMgr_DetachSource` 0x416C10 releases it.
2. **Per frame.** `SoundMgr_Update` 0x418050 runs via `SoundMgr_Update_Thunk` 0x410520, called from
   `FrontEnd_UpdateMode` and `Game_StepByStatus`. When the game is not paused it increments
   `frameCounter` +0x5448 (every 5th frame sets `slowTick`) and calls `SoundMgr_UpdateFrame` 0x417EA0
   → `SoundMgr_UpdateListenerAndSources` 0x417030 → `SoundMgr_UpdateSource` 0x4163A0, a switch on the
   client kind: sprite (ped / car / object), music, radio (`SoundManager_UpdateRadio` 0x4B2D50, which
   also runs `PoliceRadio_Update`), event queue, weapon, crane, crusher, vocal, HUD counter. Each
   branch fills `pendingRequest` (+0x30, 0x68 bytes: sample / category, position, volume, radius,
   loop) and calls `SoundMgr_QueueRequest` 0x4171A0 after the audibility test
   `SoundMgr_IsVoiceInRange(this, maxDistSq)` 0x4116B0. `SoundMgr_ApplyRequestsToVoices` 0x417410
   maps the sorted requests onto `voiceCount` voices: 16 2D, or `num3DVoices` +0x1C when a 3D
   provider is open.
3. **MssAudio wrapper (`g_MssAudioDevice` 0x66C950) → mss32.** Every wrapper indexes a handle array
   and tail-jumps to the AIL import with the remaining arguments unchanged. The call contract the
   host has to honour is in [win32-shims.md](../win32-shims.md) "How the game uses mss32".
4. **Radio** (§2c) and **police radio** (§2d) ride on the same request / stream machinery.
5. **Startup:** `initSound` 0x416490 → `MssAudio_Startup2D(this, &sm+0x5440)` 0x4B7250 (AIL_startup,
   waveOutOpen 22050 Hz, 16 2D samples, master volume 0x7F). The +0x5440 out-param is never written.

Doppler: `SoundMgr_ApplyDopplerToFrequency` 0x416F20, f' = f·c/(c+v) with c = `speedOfSound` +0x4
(5.0) and v the per-tick distance change divided by `ticksPerSecondFix` +0xC (30.0); no shift when
|v| ≥ c. Pan: `SoundMgr_CalcPan(radius, relX)` 0x416E50, slewed ±10 per frame. Pitch: SDT rate ±
`SoundMgr_GetPitchJitter`. Sample length in ticks = entry size · `ticksPerSecond` (+0x8, 30) / rate
(0x416890, 0x417410).

### 2b. SoundManager / MssAudio / MssBankEntry fields settled in U1

`SoundManager` is still 0x5578 bytes, `MssAudio` 0x2718, `MssBankEntry` 0x18. Conf. = confidence.

| struct+off | name (was) | type | meaning | evidence VA | conf. |
|---|---|---|---|---|---|
| SM+0x3 | `musicLoopTrackD` (unsure_musicMode) | byte | 1 → frontend music client loops `d.wav`, 0 → `m.wav` | 0x411A50; Ctor 0x417EF0 = 1; cleared 0x411A50 / 0x416C10 | high |
| SM+0x4 | `speedOfSound` (unsure_fix16_4) | Fix16 | Doppler c = 5.0 | 0x416F20 | high |
| SM+0x8 | `ticksPerSecond` (unsure_int8) | byte | 30 (+0x9..0xB unused) | 0x416890, 0x417410, 0x4B1D40 (cap 30·90000) | high |
| SM+0xC | `ticksPerSecondFix` (unsure_fix16_c) | Fix16 | 30.0, Doppler divisor | Ctor `Fix16_FromUChar(30)`, 0x416F20 | high |
| SM+0x18/19/1A/1B | `unusedInit18/19/1a/1b` (unsure_flag18..1b) | byte | Ctor writes 1/1/1/0, no reader | Ctor 0x417EF0 | high (unread) |
| SM+0x1C | `num3DVoices` (unsure_flag1c) | byte | out-param of `MssAudio_Init3DSamples` 0x4B72B0 (was `Mss_Init3DSamples`) (provider max, capped 16, < 8 = fail); copied to `voiceCount` | via `SoundMgr_Set3DSoundEnabled` 0x416640 | high |
| SM+0x1D | `sound3DActive` | byte | the global label `g_sound3DActive` 0x5DCBE5 duplicates this field (safe to delete) | — | high |
| SM+0x1450 | `unusedFlag1450` (unsure_int1450) | byte | written 0, no reader | 0x417F98 / 0x416D80 | high |
| SM+0x5440 | `startup2DOutUnused` (unsure_int5440) | int | `LEA EAX,[ESI+0x5440]; PUSH`, callee ignores it | 0x41649D | high |
| SM+0x5444 | `unusedInt5444` (unsure_int5444) | int | Ctor only | 0x417FEB | high |
| SM+0x5448 | `frameCounter` (unsure_int5448) | uint | ++ per unpaused update; %5 slowTick, %10 PumpQueue retry, &1, %0x82 | 0x4180B9..CD | high |
| SM+0x5450 | `vocalSourceSlot` (relToAudio) | int | slot of the vocal client (the client itself is +0x5454) | 0x4112B0, 0x4105B0 | high |
| SM+0x5468 | `radioSlots` | RadioStationSlot[5] | 5 stations, stride 0x1C; base+0x544C+i·0x1C = slot i−1 (1-based addressing) | 0x4B2350 loop | high |
| SM+0x54F4 | `radioWasInCar` (unsure_radioFlag54f4) | byte | previous-frame copy of +0x54F5 | 0x4B2DC3 | high |
| SM+0x54F5 | `radioInCar` (gap) | byte | 1 in a radio car (not train, not wrecked) | 0x4B2E16 / 0x4B2EB5 | high |
| SM+0x54F8 | `radioPrevSlot` (unsure_radioFlag54f8) | byte | previous-frame copy of `radioCurrentSlot` +0x54F7 | 0x4B2DBA | high |
| SM+0x54FC | `radioBand` | byte → **int** | 0/1: which file variant is streamed | 0x4B26CE, 0x4B2AD0, 0x4B2830 | high |
| SM+0x5500 | `radioPrevBand` (gap) | int | previous-frame copy; a change re-opens the stream | 0x4B2DC9 / 0x4B26CE | high |
| SM+0x5508 | `radioSourceSlot` (radioStreamId) | int | return of `SoundMgr_AttachClient` — a slot, not a stream | 0x4B2FD5 | high |
| SM+0x550C | `radioClient` (unsure_radioClientKind/Byte10/Int18) | SoundClient | kind 3, disabled 0, owner 0 | 0x4B2FB5..0x4B2FCA | high |
| SM+0x5522 | `policeLastCopStars` (gap) | short | wanted level seen last frame | 0x41C772 / 0x41CB8B / 0x41CBF4 | high |
| SM+0x5524 | `policeHighestCrimeKind` (gap) | CRIME_KIND | highest kind since `PoliceRadio_Reset` 0x41C200; phrase 0x49+kind | 0x41C211, 0x41CC04 | high |
| SM+0x552C | `policeQueue` | byte[15] → **uint[15]** | phrase ring, index ·4, ends exactly at 0x5568 | 0x41BF90 / 0x41C000 | high |
| SM+0x5568/69 | `policeCopKillTileX/Y` (policeType8TileX/Y) | byte | tile of the last kind-8 event (CRIME_KILL_LAW_ENFORCEMENT) | 0x41C600 | high |
| SM+0x556A | `policeCopKillFollowUpTimer` (policeStandbyTimer) | ushort | (rand%10+15)·100 ticks; at 1→0 the follow-up fires | 0x41C600 | high |
| SM+0x556C | `policeShotsFiredCooldown` (unsure_policeTimer556c) | ushort | 600..2129 ticks, case 2 (CRIME_FIRE_WEAPON) | 0x41C600 | medium-high (phrase wording unheard) |
| SM+0x556E | `policeCarDescCooldown` (unsure_policeTimer556e) | ushort | 300..1299 ticks, gates `PoliceRadio_QueueCarDescription` | 0x41C600 case 0 | high |
| SM+0x5570 | `policeLocationReportCooldown` (unsure_policeTimer5570) | ushort | 150..1216 ticks, case 3 + case 7 | 0x41C600 | medium-high |
| SM+0x5574 | `policeLastDescribedCarModel` (unsure_policeCarDescState) | int | car info index last described; 0x57 = on foot | 0x41C350 | high |
| MssAudio+0x4 | `unsure_cdDriveLetter` (unsure_musicVolume) | byte | Ctor = 99 = `'c'`, only reader 0x416630 | Ctor 0x4B6CE0 | low (guess; "volume" disproved) |
| MssAudio+0x26B4 | `selected3DProviderIdx` (unsure_selectedProvider) | int | open 3D provider, −1 none | 0x4B655B | high |
| MssAudio+0x26B8 | `eaxSupported` (unsure_eaxAvailable) | int | provider answers "EAX environment selection" != −1 | 0x4B6550 | high |
| MssBankEntry+0xC/0x10/0x14 | `rateVariation` / `loopStart` / `loopEnd` (unsure_fieldB4/B8/BC) | int | SDT fields ([lessons.md](../formats/lessons.md)); loop end −1 = none | getters 0x4B6040/60/80 | high |

### 2c. Radio

Five station slots `radioSlots` +0x5468, added by script RADIO_STATION
(`SoundManager_Radio_AddStation(this, stationId, x, y)` 0x4B2BC0, thunk 0x410580) and removed by
`SoundManager_Radio_RemoveStationAt(x, y)` 0x410590 (body 0x4B2350, caller
`MissionScript_DeleteItemByCmd`). Each frame `SoundManager_UpdateRadio` 0x4B2D50 copies current →
previous state (`radioInCar` → `radioWasInCar`, `radioCurrentSlot` → `radioPrevSlot`, `radioBand` →
`radioPrevBand`), then picks or keeps a station. Signal strength sets `radioBand` with hysteresis
0x6F / 0x59; a band change re-opens `<id>.wav` (band 1) vs `<id>A.wav` (band 0) and mixes in static
(samples 0x89 / 0x8A). In an emergency car the special track 0x65 plays. On foot, in a train or in
a wrecked car the radio is "off" (slot 0x66 → track 0xC with a 0x3C fade).

### 2d. Police radio

`PoliceRadio_Update` 0x41C600 runs every unpaused frame (from `SoundManager_UpdateRadio`, also with
MSS audio off). It drains `g_CrimeEventQueue` (entries are `CRIME_KIND`, pushed by
`CrimeEvent_Report` 0x44A200, see "Crime event queue" below), keeps the highest kind and its tile
x/y (9 is meant as a fallback only, but see the bug note below) and reacts to wanted-level changes against `policeLastCopStars`. Three cooldowns throttle the reports
(`policeShotsFiredCooldown`, `policeCarDescCooldown`, `policeLocationReportCooldown`). A cop kill
(kind 8) arms `policeCopKillFollowUpTimer`; on expiry `PoliceRadio_QueueCopKillFollowUp` 0x41C100
queues 0x79, 0x5F, 0x5B, 0x78 (when > 3 slots are free). Phrase ids 0x45..0x88 go into the 15-dword
`policeQueue` and are played one by one on the extra sample (`PoliceRadio_PumpQueue` 0x41C000 →
`ExtraSample_PlayEntry`).

#### Crime event queue (V = code read, not run; struct pass 4, 2026-10-25)

`g_CrimeEventQueue` 0x5E79EC points to a `CrimeEventQueue` (0xCC B = `operator_new` size in
`Game_Ctor` 0x45D1D5, `CrimeEventQueue_Ctor` 0x44A1F0, deleted in `Game_Dtor`): `+0` `writeIndex`
(ushort), `+2` `readIndex`, `+4` `events[10]`; `CrimeEvent` is 0x14 B: `+0` `kind` (`CRIME_KIND`),
`+4` `actorPedId`, `+8/+0xC/+0x10` `posX/posY/posZ` (Fix16). It is a pure producer → police-radio
channel: it does not feed the wanted level (stars come from `PoliceManager` / ped wanted points).

- **Producer**: only `CrimeEvent_Report` 0x44A200, `void __thiscall (CrimeEventQueue* queue /*ECX*/,
  CRIME_KIND kind, Ped* ped)`, RET 8. Every caller does `MOV ECX,[0x5E79EC]` right before the call.
  Hook trap: a C32 hook declared `__stdcall (kind, ped)` (the old Ghidra signature) leaves ECX garbage
  (hypothesis from the convention, not tried); use `__thiscall` / ECX = `*(CrimeEventQueue**)0x5E79EC`.
- **Callers** (V, xrefs): kind 1 `PlayerScore_OnCarDamaged` / `_OnCarRammed`; 2 every `Weapon_Fire*`
  and `CarWeapon_Fire*`, molotov/grenade throw, electrogun; 3 `PlayerScore_OnCarDestroyed` /
  `_OnFullBusDestroyed`; 4 `_OnBusHijacked`; 5 `_OnCarjack`. Kinds 6..9 come from **one** site,
  `PlayerScore_OnPedKilled` 0x4B84FB (gang rival → 9; plain civilian killed with weapon 1 or 3 → 6,
  other civilian → 7; law enforcement / army / FBI / SWAT / medic / fireman → 8), gated by
  `Crime_IsPedKillCredited`; the actor passed is the **player's controlled ped, not the victim**.
- **What `Report` does**: skips (does nothing at all) actors whose `Ped_GetOccupation` is POLICE 0x18,
  SWAT 0x19, FBI 0x1A, ARMY_IN_VEHICLE 0x1B, POLICE_ON_FOOT 0x1D, 0x1E, ARMY_ON_FOOT 0x1F,
  ROAD_BLOCK_GUARD 0x25 (jump table 0x44A29C; MEDIC / FIREMAN / GUARD / TANK_DRIVER are *not* excluded).
  Kind < 3: pushed only if `CrimeEventQueue_ContainsKind` finds none of that kind queued (dedup within
  the frame). Kind ≥ 3: `Ped_SetWitnessMark(actor)` 0x4331D0, always pushed, and for a
  player-controlled actor `PoliceManager_UpdateCriminalPosition`. For every kind, a player-controlled
  actor also gets `CrimeStats_CountCrime`. The **push is not gated on the actor being the player**:
  an AI ped firing a weapon or destroying a car queues an event too (stats stay player-only; whether
  AI peds reach those call sites in play was not traced).
- **Ring** (`CrimeEventQueue_Push` 0x44A110 / `_Pop` 0x44A160): push stores at `writeIndex`, advances
  mod 10, and if it caught `readIndex` advances that too: empty = `write == read`, **max 9 live
  events, overflow silently drops the oldest**. Pop copies `kind, x, y, z` (not the ped id) out,
  clears the slot, advances `readIndex` unless empty, returns `kind != 0`.
  `CrimeEvent_Set` snapshots the actor's x/y/z **at push time** (`Ped_GetById` without a NULL check;
  fine today because callers pass a live ped's id).
- **Consumer**: `PoliceRadio_Update` pops until empty and keeps the highest kind with its tile
  position (`Fix16_ToIntB(posX/posY)`; `posZ` and the actor id are never used); everything that is not
  the frame's top event is discarded.
- **Bug (V by control flow, not run)**: if the first drained event is kind 9 (gang kill) and nothing
  is taken yet, it is taken, and `else if (best < kind)` can never beat 9 afterwards, so a cop kill
  (8) queued later in the same frame is ignored: the opposite of "9 only as a fallback". Radio phrase
  only; low severity.
- `Crime_IsCarDestroyCredited` 0x44A2C0 / `Crime_IsPedKillCredited` 0x44A370 get the queue in ECX but
  never use it: they are gates (`explosionDamageLatch`, `DAT_0066A3C9`, crusher list,
  `Game_PlayerCameraSeesSprite`), not queue methods; the meaning of the two latches is unsettled.
- Unknown: `Ped_SetWitnessMark` semantics; whether non-player peds ever hit kinds 1/2 in play.

### 2e. Functions settled in U1

| VA | name (was) | signature |
|---|---|---|
| 0x410520 | `SoundMgr_Update_Thunk` (audio) | `void __stdcall (void)` |
| 0x410540 | `SoundMgr_DetachSource_Thunk` (relatedToS6) | `void __stdcall (uint slot)` |
| 0x416C10 | `SoundMgr_DetachSource` (relatedToS6) | `void __thiscall (SoundManager*, uint slot)` |
| 0x416750 | `SoundMgr_ClearSourceSlot` (ff2) | `void __thiscall (SoundManager*, uint slot)` |
| 0x410590 | `SoundManager_Radio_RemoveStationAt` (SoundMgr_CancelVocalAt) | `void __stdcall (Fix16 x, Fix16 y)` |
| 0x410660 | `unsure_Sound_GetCdDriveLetter` (unsure_Audio_GetCdDriveLetter) | `byte __stdcall (void)` |
| 0x41C100 | `PoliceRadio_QueueCopKillFollowUp` (unsure_PoliceRadio_QueueType8FollowUpPhrases) | unchanged |
| 0x4156C0 | `CarSound_AddTankCarContactLoop` (unsure_) | unchanged; Car flag 0x2000 = touching another car this tick |
| 0x414200 | `CarSound_AddAiCarSpeedLoop` (unsure_CarSound_AddSpeedLoopC) | unchanged; runs only without a player driver |
| 0x417D90 | `SoundManager_RadioSlots_Ctor` (SoundMgr_VocalSlots_Ctor) | unchanged |
| 0x4B2F20 / 0x410560 | `SoundManager_Radio_InitOnce(_Thunk)` (SoundManager_InitOnce) | unchanged |
| 0x4B6020/40/60/80 | `MssAudio_GetBankEntrySampleRate / _RateVariation / _LoopStart / _LoopEnd` (…FieldB0OrOne/B4/B8/BC) | `int __thiscall (MssAudio*, int entry)` |
| 0x4116B0 | `SoundMgr_IsVoiceInRange` | `bool __thiscall (SoundManager*, Fix16 maxDistSq)` (argument was missing: RET 4) |
| 0x4107B0 / 0x410A70 | `SoundMgr_PickImpactSample3Tier / 2Tier` | `bool __thiscall (SoundManager*, byte impactVolume)` |
| 0x416640 | `SoundMgr_Set3DSoundEnabled` | `bool __thiscall (SoundManager*, bool enable)` |
| 0x410670 / 0x410680 | `Sound_Set3DSoundEnabled` / `Sound_Is3DSoundActive` | `bool __stdcall (bool)` / `bool __stdcall (void)` |
| 0x416E50 | `SoundMgr_CalcPan` | `byte __stdcall (Fix16 radius, Fix16 relX)` (RET 8) |
| 0x4B25A0 | `SoundManager_Radio_IsTrainCarModel` | `bool __stdcall (Car*)` |
| 0x4B2BC0 / 0x410580 | `SoundManager_Radio_AddStation` / `SoundMgr_AddRadioStation_Thunk` | `(SoundManager*,) int stationId, Fix16 x, Fix16 y` (RET 0xC) |
| 0x41C0D0 | `PoliceRadio_GetFreeQueueSlots` | `byte __fastcall (SoundManager*)` |

MssAudio wrapper prototypes are listed with the call contract in win32-shims.md.

Struct pass 4 (2026-10-25, code read only): `MssAudio` (0x2718, a static object built by a CRT
initialiser; `MssAudio_Ctor` 0x4B6CE0 has no code xref, size trusted from the last field) now types
its handles with the `/Miles` typedefs `HDIGDRIVER` (+0, also the `AIL_waveOutOpen` out pointer, so
`this` is passed as out param in `OpenWaveOut` 0x4B6DE0), `HSAMPLE samples2D[16]` (+0x58),
`HSAMPLE extraSample` (+0x98), `HSTREAM streams[2]` (+0x9C), `HPROVIDER providers[256]` (+0x1EB4),
`HPROVIDER provider3D` (+0x26C0), `H3DSAMPLE samples3D[16]` (+0x26C4). They are plain `void*`
typedefs (no opaque Miles structs). Handle 0 = free; every wrapper skips it and tail-jumps into the
`AIL_*` import. Details the host needs:
- `OpenWaveOut` builds a WAVEFORMAT (tag 1, 2 ch, 22050 Hz), sets preferences 1 = 0x25, 0xF = 0,
  0x21 = `use3D`, 0x1F = 1 (meanings not decoded), allocates the 6.1 MB bank buffer
  (`AIL_mem_alloc_lock(0x5D1420)`). Sample types: 2D voices MONO_16 PCM_SIGNED, the extra sample
  MONO_8 unsigned.
- `LoadBank(styleName)` 0x4B6B40 reads `data\audio\<name>.RAW` + `.SDT` and **falls back to `bil`** when
  the level bank cannot be opened; a RAW larger than 0x5D1420 is refused; `bankEntries` are 0x140 ×
  0x18 B from the SDT.
- `PlayRange(first, last)` (phone chatter) needs `first < last` and a finished previous play;
  `ExtraSample_End` 0x4B6A60 and `_Stop` 0x4B6B20 are byte-identical.
- `Stream_OpenTrack`: opening stream 0 with `musicEnabled == 0` does nothing; a 0 result (missing
  file) is stored silently. `Stream_GetPlaybackRate` returns 0x5622 when the stream is 0.
- `SoundMgr_ApplyRequestsToVoices` passes a **loop count with 0 = forever** (request +0x30) and the
  loop block (+0x34 / +0x38).
- `MssBankEntry.sampleRate` is `MssAudio_GetBankEntrySampleRate`; `Mss_A3D_DisableSplash` 0x4B5ED0
  (writes `HKCU\Software\Aureal\A3D` `SplashScreen=0`, `SplashAudio=0`) is not an `MssAudio_` method.
Host-vs-game mismatches (H1-H3, found by code read): [../win32-shims.md](../win32-shims.md) "Host vs
game contract".

### 2f. Sound hazards and open questions (U1)

| VA | what | trigger | severity | status |
|---|---|---|---|---|
| 0x41C000 | `PoliceRadio_PumpQueue` clamps `if (read > 14) read = 15`, which would read `policeQueue[15]` (= +0x5568, the cop-kill tile / timer) as a phrase id | none: `read` is always kept % 15, the clamp is dead | none | verified by code (decompile + QueuePhrase / ClearQueue modulo) |
| 0x4B2FD5 | the radio client is attached once and never detached (`SoundManager_Reset` skips it) | permanent: 1 of the 1019 slots stays used | none | verified by code (two xrefs of +0x5508, both in InitOnce) |
| 0x416630 / MssAudio+4 | the "CD drive letter" (`'c'`) is read by the intro-movie path builders and ignored | — | none (dead remnant) | verified by code (0x452990..0x4529DA) |
| 0x4B6890 | `MssAudio_Stream_SetVolume` masks the volume `&0xFF` | — | info for `host/c/audio.c` | verified by code |
| 0x4B6B40 | `MssAudio_LoadBank`: with neither the level's `.SDT` nor `BIL.SDT` it `_fclose`s the already closed RAW handle and then `fread`s from NULL | a pak lacking a level's .SDT **and** bil.sdt | low (pak has all) | code path read |
| 0x4B6B40 | `LoadBank` path buffers are fixed stack arrays, copy length unchecked | style name longer than ~36 chars (mods) | low | code read |
| 0x4B6600 | `Enumerate3DProviders` copies each provider name into a 0x50-byte `operator_new` block unchecked, never freed | 3D only, name > 79 chars | low | code read |
| 0x4B6F70 / 0x4B6DE0 | `Init2DSamples` with `use3D` closes and reopens the device, but `extraSample` is not re-allocated (`Alloc` skips a non-zero handle): stale handle | only after a 3D provider was opened (unreachable on the host) | low | code read |
| 0x4B67E0 / 0x4B7000 | music fade-out = up to 127 × `AIL_delay(1)`, blocking the game thread ~1.3 s at CD volume 0x4C (2 s at max); from `SoundMgr_DetachSource` 0x416C63 | leaving frontend music | cosmetic, same in the original | code read |
| 0x4B66A0 | `MusicStream_IsDone` is false forever when `musicEnabled == 0` | — | none | code read |

Open:

- What the samples sound like: tank car-contact loop = level bank 0x24, AI speed loop = bank 0,
  police phrases 0x45..0x88. The "shots fired" / location phrase meanings are inferred from
  `CRIME_KIND`, not heard (`bun tools/formats/cli.ts` can extract the SDT entries).
- MssAudio+4 as a CD drive letter is a hypothesis (value `'c'` + movie-path callers); proven: it is
  not a volume and has no effect.
- +0x18..0x1B, +0x1450, +0x5444: unread in every scan run (absolute refs, typed `this` accesses in
  196 functions, disp ≥ 0x100 in sound functions); a read through an unusual base register is not
  ruled out 100 %.
- `MssAudio_Init2DSamples(arg)` 0x4B6F70 (was `Mss_Init2DSamples`; callers pass 1, the argument is
  unused). `MssAudio+0x2704..0x270C` (was `unsure_listenerPos[3]`, a wrong guess) are
  `eaxEffectVolume / eaxDecayTime / eaxDamping`, stored by `MssAudio_Eax_SetEffectParams` 0x4B6460
  `(float effectVolume, float decayTime, float damping)` (checked against the Miles attribute names
  "EAX effect volume / decay time / damping"); −1.0 = unset. That function has no caller in 11.44.
- Decompiler artefact: callers of `PoliceRadio_GetFreeQueueSlots` show `QueuePhrase(this_0x, …)`
  because Ghidra assumes the fastcall callee clobbers ECX; it only reads it.
- Duplicate names: `CarSound_AddDoors` is at both 0x4143B0 and 0x4156B0 (the thunk); global label
  `g_sound3DActive` 0x5DCBE5 duplicates SoundManager+0x1D.

## 3. Camera, doors, CarManager

- **Camera** (0x41DE00–0x41F5FF): `cameraPosTarget` (+0x10) is set by `Camera_SetTarget` from
  `Camera_FollowCar` / `Camera_FollowPed`; `cameraPos` (+0x98) is the smoothed position, `+0xAC` its
  speed. `Camera_Tick` 0x41F2F0: `followState` (+0x3C) 1 = spring smoothing, 2 = snap; shake while
  `+0x30 != 0` (H); then boundaries and `Camera_CommitTarget`. `Camera_IsWorldPointOnScreen`
  0x41E710 tests 0 ≤ x < 640, 0 ≤ y < 480 in game screen units.
- **CarDoor** (16 bytes, `Car+0xC + i*0x10`, 4 doors): state `+4` 0 none, 6 closed
  (`CarDoor_Init`), 1/2 opening / open, 3..5 closing; `CarDoor_RequestOpen` 0x41F680 refreshes the
  hold timer `+0xC = 0x32`.
- **CarManager** category counters and caps (`CarManager_HasRoomForType` 0x420CE0 /
  `_Strict` 0x420C40, all signed `setl`):

  | category | field | cap | strict |
  |---|---|---|---|
  | RECYCLED + PROT_RECYCLED | +0x28 + +0x40 | < 16 | < 15 |
  | AMBULANCE | +0x2C | < 2 | < 1 |
  | FIRE_TRUCK | +0x30 | < 2 | < 1 |
  | UNIT | +0x34 | < 6 | < 5 |
  | ROADBLOCK | +0x38 | < 12 | < 11 |
  | MISSION | +0x3C | < 24 | < 23 |
  | PARKED | +0x44 | < 200 | < 200 |
  | COP_CALLED (10) | +0x48 | < 12 | < 11 |

  `CarManager_Ctor` 0x428FA0 does not write `+0x48` or `+0x68` and the object comes from a
  non-zeroed `operator new(0x6C)` (Seq 27, re-verified here): `copCalledCars` starts as heap
  contents. Runtime effect not measured.

## 4. CarAI per tick

`Car_Update` → `CarAI_PreUpdate` 0x4327A0 (scratch reset, heading = body rotation, travelDir =
heading class, halt handling) → `CarAI_Update` 0x432370:

1. `g_CarAI_carX/Y/Z` (0x5E53D8 / 0x5E5320 / 0x5E50EC) ← car body x / y / z (scratch globals every
   helper reads);
2. if `car->driveOrder && ai->isOffRoad == 0`: **`CarAI_UpdateDriveOrder` 0x42D390 every
   tick**, sets `g_CarAI_driveOrderActive` 0x5E507E = 1 and `g_CarAI_hasDriveOrder` 0x5E5081;
3. off-road mode (`isOffRoad` +0x3C, §4a): steer by `offRoadTurn` +0x50, count `offRoadTicks` +0x58;
   `> 200` → `car.isAbandoned` (mission drivers exempt; the counter is **cumulative**, see §4b);
4. `CarAI_DriveStep` 0x431C10 probes ahead (`g_CarAI_probeX/Y` 0x5E5244 / 0x5E5198);
   `CarAI_ReactToNearbyCar` 0x42FB80 (flags 0x1000) and `CarAI_HandleCarAhead` 0x431770. All three
   clear `g_CarAI_driveOrderActive` on a car ahead / obstacle / map collision; when it got cleared
   (and the order is not FOLLOW_TARGET) `CarAI_Update` also drops `flags & 0x10`;
5. drive order with `followRoadActive == 0` → `CarDriveOrder_Drive` 0x42D820 (direct driving, §5b);
6. `routeSlot > 0 && ai->flags & 0x10 && followRoadActive == 1` → **`CarAI_FollowRoute` 0x430320**
   → `CarAI_ApplyRouteTurn` 0x4300E0;
7. `CarAI_FollowLane` 0x430CC0 (lane keeping, `CarAI_UpdateJunctionTurn` → `CarAI_TryStartTurn` /
   `CarAI_ReserveJunction`; ambient traffic picks turns at random with `CarAI_PickRandomTurn`).
   FollowLane sets flags 0x10 when the car's tile has a green or red arrow in `travelDir` (jump table
   0x431744, arrow byte block+0xA) — except heading W, which tests the wrong red bit (§4b).

`ai->flags` (+0x24): 0x02 inside the current junction rect, 0x10 on a lane tile whose arrows match
travelDir (set by `CarAI_FollowLane`, cleared by `CarAI_Update` / `CarAI_DriveStep`), 0x08 no arrow on the
probe tile ahead (off lane), 0x40 reverse / off-road turn (U2 reads 0x40 / 0x80 as the off-road turn
bits; the off-road *state* is `isOffRoad` +0x3C, not a flag), 0x80 turn committed, 0x100 lane change in
progress (`laneChangeTargetLane`), 0x800 route U-turn pending (`routeUTurnExitDir` +0x38; never read, see
§6b), 0x1000 reacting to a nearby car, 0x20000 junction reserved, 0x40000 / 0x80000 steer into the
target's lane, 0x100000 halted, 0x200000 copy of a driver flag.

**Direction conventions** (verified in Seq H1, 2026-10-23):

- Tile arrow byte = block_info +0xA: bit0 green left (W), bit1 green right (E), bit2 green up (N),
  bit3 green down (S), bits 4–7 the same in red. `MapBlock_HasArrow(block, layer, dir)` 0x40C6D0:
  dir 1 N, 2 S, 3 W, 4 E; layer 1 green, 2 red, 3 either.
- Heading class (`Ang16_ToHeadingClass` 0x472C00): **1 N, 2 S, 3 E, 4 W** (N = −y). Proven by the
  `CarAI_ApplyRouteTurn` turn table, `MapBlock_HasArrowHeadingClass` 0x40C810 (class 3 → arrow 4 E)
  and `Rail_StepPosByHeadingClass` 0x4630D0. The older plate of `CarAI_IsExitDirRightTurn`
  (1 = −x, 2 = +x, 3 = −y, 4 = +y) was wrong and is fixed.
- Link direction (`RoadJunction_GetLinkDirTo` 0x40D0C0): 1 N, 2 S, 3 W, 4 E. `RoadJunction` link
  slots +0 N, +2 S, +4 E, +6 W (all 312 wil junctions checked against geometry). Links are directed:
  87 of 731 on wil are one-way.
- `RoadSegment.junction1` = west (H segment) / north (V) end, `junction2` = east / south end (366/366
  H and 365/365 V wil segments). Segment rects include the junction tiles at both ends.
- Ang16 = 4 units per degree; the CRT static init (0x5009A0…) builds angle constants as `deg × 4`:
  0x5E5110 4°, 0x5E5120 10°, 0x5E518C 12°, 0x5E5354 32°, 0x5E51A0 45°, 0x5E53D4 90°, 0x5E52A4 180°,
  0x5E51CC 270°, 0x5E50F8 0. Sprite rotation 0 faces +y (S), 90° E, 180° N, 270° W.

### 4a. Off-road mode, lane change, junction reservation (U2 pass, 2026-10-24)

Read in code (typed p-code scan of all functions + untyped `Sprite.owner → Car.ai` scan + byte-operand
scan), not reproduced at runtime.

- **Off-road mode** (`CarAI.isOffRoad` +0x3C, was `unsure_unstickState`). `CarAI_FollowLane`
  0x430CC0 sets flags 0x10 only when the car's own tile carries an arrow in its `travelDir`. Without
  it, `CarAI_SteerByArrowAheadOffLane` 0x42B8A0 looks at the tile ahead: arrow there → steer onto it
  (and, if the car was off-road, clear `isOffRoad` and re-enable `driveOrder.followRoadActive`); no
  arrow → flags 8, and the *first* time set `isOffRoad = 1` (0x42BE47) and probe the four neighbour
  tiles for any arrow, storing the way back in `offRoadTurn` (+0x50). While `isOffRoad`:
  `CarAI_Update` skips `CarAI_UpdateDriveOrder`, counts `offRoadTicks` (+0x58, was `stuckTicks`;
  > 200 → `car.isAbandoned`, mission drivers exempt) and steers by `offRoadTurn`;
  `CarDriveOrder_Drive` skips aim / steer and treats the target as "far". Contact with another car
  (`CarAI_ReactToNearbyCar` 0x42FBB8) also clears `isOffRoad`.
- **Lane change.** `CarAI_TryLaneChange` 0x42C8B0: no change during the first 21 ticks
  (`ageTicks` +0x2B < 0x15), on ramps, off lane or while turning; only around a slower car ahead that
  is not itself changing lane. Uses `Car_CountLaneTiles` (lane index + lane count); sets flags 0x100
  and `laneChangeTargetLane` (+0x2F, lane ± 1). `CarAI_UpdateLaneChangeAlign` 0x42C030 steers until
  the current lane equals it. +0x2D / +0x2E are written alongside (lane index / 0) and never read.
- **Junction reservation (left turns).** `CarAI_ReserveJunction` 0x42B350 writes `leftTurnExitDir`
  (+0x48, left of travelDir: N→W, S→E, E→N, W→S) and scans the cross street; other cars whose own
  +0x48 differs are told to yield (their `blockingCar` = us, `avoidTimer` = 5).

`CarAI_ReserveJunction`, `CarAI_TryLaneChange`, `CarAI_SteerByArrowAheadOffLane` and
`CarAI_UpdateLaneChangeAlign` were re-read in this pass; the names stand.

### 4b. CarAI / drive-order hazards (U2)

| VA | what | trigger | severity | status |
|---|---|---|---|---|
| 0x430DD5 → 0x430DE3 (`CarAI_FollowLane`, jump table 0x431744) | **West lane test uses the wrong red bit**: case W tests green-left 0x01, then falls into the N case's red test 0x40 (red up) instead of 0x10 (red left) | car heading W on a tile whose only W arrow is red (not "on lane" → off-lane steer, may enter off-road mode); car heading W on a tile with a red N arrow counts as on lane | low–medium (red arrows = special roads) | verified by code (disassembly + jump-table bytes); effect on traffic is a hypothesis |
| 0x43250F (`CarAI_Update`) | `offRoadTicks` is never reset when the car returns to a lane (only Ctor / Reinit): the > 200 abandonment counts the **lifetime total** | AI car that leaves the road network several times | low (earlier abandonment) | verified by code (+0x58 written only by Ctor / Reinit / Update) |
| 0x42E31D / 0x42E727, 0x42FBCF | `ramArmed` is sticky for the order's life: after one SIDE_PUSH ram, every later contact with the target does 500 damage, even after the chase re-planned to TAIL / FOLLOW | chase that reached SIDE_PUSH once | low–medium (maybe by design) | verified by code (writers: 2× set 1, `CarDriveOrder_Reset` 0) |
| 0x4ABC66 / 0x4ABCC3 (`PoliceCrew_UpdateChaseDriveOrder` 0x4ABAE0) | `blockHitCount` is seeded from `Ped.chaseHitCount` every tick (if non-zero) and on STOPPED **added back** to it → the ped's count roughly doubles per finished chase | wanted player stopped by a cop car twice | low | arithmetic verified by code; intent is a hypothesis |
| 0x42B80E | `leftTurnExitDir` is never cleared after the turn; other cars compare against a stale value | car that turned left long ago, standing in cross traffic | low | verified by code (writes only in ReserveJunction + Ctor / Reinit) |

## 5. Drive orders and route finding

A ped objective (`Ped_Obj1_GoToAreaInCar` 0x438C40 for GO_TO_POINT; see [ped-ai.md](ped-ai.md))
gives the car a `CarDriveOrder` (0x40 bytes, pool of 20): `+8 mode` (1 GO_TO_POINT, 2 FOLLOW_TARGET,
3–5 chase variants), `+0xC` maneuver 0..0xF for direct driving, `+0x14/18/1C` target x/y/z,
`+0x20 isUrgent`, `+0x22 followRoadActive`, `+0x26 arrived`, `+0x30 targetPed`,
`+0x34 retryCooldown` (300, or 100 for cops / copLevel ≥ 3).

**`CarAI_UpdateDriveOrder` 0x42D390**, every tick:

- `ai->targetSpeed = driver->carSpeed`; target = order x/y/z (GO_TO_POINT) or the target ped's
  position.
- `Fix16_ChebyshevDist` 0x42A6B0 (`max(|dx|, |dy|)`) to the target `< 5.0` (`DAT_5E50B8`) stops road
  following — **only when mode != GO_TO_POINT**.
- urgent orders never route: when no player camera sees the car, it is teleported onto the target's
  arrow tile (`Car_TryPlaceOnArrowTileAt`), repaired, crew despawned.
- otherwise: `RoadNetwork_FreeRoute`, find a road block with arrows at the target (x, y, z) or
  (x, y, z − 1), else `PedPathfinder_FindSpawnTile(kind 1, wide 0)` (call at 0x42D689: fails while
  the ped pathfinder's `searchInProgress` is stuck at 1, and takes the first of ≤ 7 BFS-popped tiles
  with any road arrow, whatever its direction; see [ped-ai.md](ped-ai.md) §8); then `CarAI_SetRouteTarget(x, y, blockZ, 3)`,
  `followRoadActive = 1`. **The route is recomputed from scratch every tick**, so `routeStep`
  (+0x56) stays 0 — it is written only by `CarAI_Ctor`, `CarAI_Reinit` and `SetRouteTarget`.

**`CarAI_SetRouteTarget` 0x42ACF0**: `RoadNetwork_FindRoute(car x, car y, ToInt(car z − 1),
target x, y, z, 3)` → `ai->routeSlot`; on success writes the order's target x/y and **target z =
the original order z (`DAT_5E5218`), not the road block's z**.

**`RoadNetwork_FindRoute` 0x40E030** (`short __thiscall (RoadNetwork*, carTileX, Y, Z, targetTileX,
Y, Z, int arrowLayer)`, via thunk 0x40E0F0) = `InitSearch` 0x40D690 + `RunSearch` 0x40DFA0 +
`StoreRoute` 0x40CC10: a best-first search over the RGEN junction graph (4 links per junction).
The route is stored as u16 junction ids in `routes[slot*0x100 + i]` (`RoadNetwork+0x2218`),
0-terminated, slots 1..49 (`RoadNetwork_FindFreeRouteSlot` 0x40CB90). A car already on the target's
segment therefore gets the pair [junction behind, junction ahead] with the target inside its bounding
box — the "route growing with the junctions behind it" seen in Seq 39 is this per-tick re-plan, not a
moving goal.

- **Start and goal come from tile arrows only** (`RoadNetwork_InitSearch`). The car's heading is
  not an input. `RoadNetwork_FindSegmentJunctionAtTile` picks the V segment table if the tile has an
  up or down arrow, else H if it has left / right, else none. Kind 1 = the segment end *ahead* in the
  tile's arrow direction (V: up arrow → junction1 / N, else junction2 / S; H: left arrow → junction1 /
  W, else junction2 / E), kind 0 = the end behind. Start = kind 0; if the car is outside that
  junction's rect, kind 1 (the normal case on a segment: the junction ahead). Goal = kind 1 of the
  target tile. If goal == start, the start reverts to the kind-0 result.
- **Cost** (`RoadNetwork_NewSearchNode` 0x40C9D0, from the disassembly): `parent.cost + linkLength +
  h(node)`, h = |ΔminX| + |ΔminY| to the goal junction. The parent cost already contains the parent's
  h, so heuristics **accumulate**: this is neither A* nor a shortest path. The start node
  (`RoadNetwork_NewStartNode` 0x40CA70) costs h.
- **Open list** sorted ascending (`RoadNetwork_InsertOpenSorted` 0x40CB00). A junction is marked
  visited when it is inserted, so the first path to reach it wins. `RoadNetwork_NextOpenNode`
  0x40CBF0 = first unclosed node. `RoadNetwork_ExpandNode` 0x40DB70 tries links N, S, W, E and
  returns as soon as the goal is **pushed** (accepted on discovery). Closed links (bit 15 clear =
  SWITCH_ROAD) and junctions of the wrong kind (`RoadJunction_MatchesKind` 0x40C5D0: arrowKind 1
  green, 2 red, 3 both; wil has 262 / 31 / 18) are skipped.

**Following the route.** Because `routeStep` stays 0, only `routes[0]` (the junction ahead) and
`routes[1]` matter. `CarAI_ApplyRouteTurn` 0x4300E0 maps (heading class, link dir) to Car TurnLeft /
TurnRight / nothing (straight) and asks for a lane change toward the turn side (`Car_CountLaneTiles`,
Car route bits 2/3). When the best path leaves the start junction backwards it only writes
`routeUTurnExitDir` (+0x38) and flags 0x800 (§6b, B1). `CarAI_UpdateJunctionTurn` 0x430650 probes
0.5 ahead; on a junction surface it reads the turn bits, and `CarAI_TryStartTurn` 0x42ADA0 starts
the turn only if the next block carries the exit arrow (green; red too with a drive order) and the
car is still more than 45° away from the exit heading → `turnExitDir`, flags 0x80, `turnTimer`
0x14. No turn bits and a block with a single perpendicular arrow = forced turn (bends, T ends).

**Arrival.** `driveOrder->arrived` has one writer, `CarAI_FollowRoute` 0x430320 (stores at
0x4304DE, 0x43053C, 0x430626). It arrives when

- (a) `routes[slot][step] == 0`, or the car's tile equals the target tile exactly
  (`ToInt(x) == ToIntB(target x) && ToInt(y) == ToIntB(target y)`, no z, no tolerance); or
- (b) the target is inside `RoadNetwork_IsTileInJunctionPairBounds(routes[0], routes[1])` **and**
  `ToInt(car z − 1.0) == ToIntB(order z)` (0x43041F..0x430444, `JNZ 0x4305B5`) **and** the car has
  passed the target along `RoadJunction_GetLinkDirTo(routes[0], routes[1])` (1: car y ≤ t y,
  2: car y ≥ t y, 3: car x ≤ t x, 4: car x ≥ t x). The same branch, while not yet passed, sets
  `ai->flags` 0x40000 / 0x80000 to steer into the target's lane.

On arrival: `CarPhysics_SteerPlus`, `followRoadActive = 0`, `Car_HaltAIIfHasAI`, `arrived = 1`.

### 5b. `CarDriveOrder_Drive` 0x42D820: direct driving and close pursuit

Typed `void __fastcall CarDriveOrder_Drive(CarAI *ai)` (the caller passes ESI = ai in ECX; the old
signature had no parameter, so the decompile showed a Car with door fields). It is the
**close-range pursuit state machine** used whenever `followRoadActive == 0`. GO_TO_POINT only ever
uses maneuver 0 (aim straight at the point). The state is `CarDriveOrder.maneuver` (+0xC), enum
`CAR_DRIVE_MANEUVER`. T = the target ped's car (`g_CarAI_targetCar` 0x5E5084), R = its rotation;
side A = R − 90°, side B = R + 90° (which one is left is not verified).

| # | `MANEUVER_` | aim point (pass 1) | exit (pass 2, distance to the aim point) |
|---|---|---|---|
| 0 | TAIL | 3.0 behind T (no car: the order point) | after 10 near ticks → 5 (bumps an ally already in 5 to 3) |
| 1 | TAIL_B | 3.0 behind T | no pass-2 case; no writer of 1 found in Drive (who sets it: unknown) |
| 2 | TAIL_OFFSET | 3.0 behind + 0.5 to side B | as 0 |
| 3 / 4 | FLANK_WAIT_A/B | 1.0 to side A/B + 0.5 ahead | after 10 ticks, side spot free → 6 / 7 |
| 5 | FOLLOW | cops vs ≤ 1 star: 1.0 behind; else T | waits `maneuverTicks` (400/0 by cop level, 80, 10; FOLLOW_TARGET 100), then free side → 6 / 7 |
| 6 / 7 | ALONGSIDE_A/B | 0.75 to side A/B, honks (`CarAI_HonkIfAllowed` 0x42A5B0) | < 0.625 → 8 / 9 |
| 8 / 9 | SIDE_PUSH_A/B | alongside for `sidePushTicks`, then `ramArmed` = 1 and aim 1.0 ahead of T (ram) | gives up the ram when `blockHitCount` > 3 → 10 / 11 |
| 10 / 11 | OVERTAKE_A/B | 0.75 to the side + 1.5 ahead | < 0.25 → 12 |
| 12 | CUT_IN | 3.0 ahead of T | < 1.5 → `blockHitCount`++, 13 |
| 13 | BLOCK_SPIN | 3.0 ahead, steers back toward the order point, handbrake when \|heading − R\| ≤ 12° | target speed < 0.03 → 15 |
| 14 | UNUSED_14 | — | — |
| 15 | STOPPED | `Car_HaltAI`, flags 0x100000 | — |

Far away (≥ 2.0) or off-road: `targetLockTicks` counts down, then the chase modes reset to 2
or 0 depending on allies already in 0 / 5 (`CarDriveOrderPool_FindAlliedDriverByManeuverTargetingPed`
0x446340, `CarDriveOrderPool_CountAlliedDriversTargetingPed` 0x4463C0). While `ramArmed` is set,
`CarAI_ReactToNearbyCar` gives T 500 damage on contact (`Car_AddDamage`). Steering: ATan2 to the aim
point, straight within ±8°, small random corrections (`Random_S16(4)`), sign flipped when reversing
(flags 0x40). Speed: match T (`Car_GetPhysicsSpeed`) with gas / coast / FullStop.

## 6. Why dispatched services drive past their target (Seq 43 bug hunt)

**Verdict: native 11.44 behaviour, not a port bug.** Evidence chain (traces from a `-DDE_TRACE`
build of `host/debug_emergency.asm`, since ported to C32 `host/c32/emergency.c`, where the same
trace is `C32FLAGS_EXTRA=-DDE_TRACE`; Downtown, 2026-10-22):

1. Both services get a GO_TO_POINT order, `isUrgent = 0` (paramedics: `Ped+0x26C` = 0, written at
   0x47323A). Trace: `ai flags 00012012 order mode 1 followRoad 1 arrived 0 urgent 0` — flag 0x10 is
   set, `CarAI_FollowRoute` runs every tick.
2. The order's z is the **sprite z of the ground**: 2.0 (`0x8000`) on flat road, for the ambulance
   (node z of `PedPathfinder_FindSpawnTile` 0x49D7A0), the fire truck (`ToIntB` of the wreck's z
   in `FireEngineSlot_Update` 0x450F10) and mission scripts alike (`goto_area_in_car` with z 2.0,
   `docs/formats/specs/scripting/example/bil/bil_rm3.mis:147`). A car on flat road also has z 2.0.
   Trace: `order target 2a0000,200000,8000 car pos …,…,8000`.
3. So the z gate of branch (b) compares `ToInt(2.0 − 1.0) = 1` with `ToIntB(2.0) = 2` and never
   passes on flat ground: no lane steering, no "passed the target" arrival. Only the exact-tile test
   (a) remains. The road at x = 168..170 is three lanes one way; the truck and the MEDICAR drive at
   x = 169, the target is at x = 168, and they pass one tile beside it forever.
4. Lowering the order z to 1.0 does not help either: `CarAI_UpdateDriveOrder` plans with that z and
   no longer finds the road block (route slot −1). No single z value satisfies both on flat ground.
5. The proximity stops in the slot code need the car standing still: `Ped_Obj1_GoToAreaInCar`
   counts only while `Car_GetFrameDisplacementLength == 0` (0x421EC0); `AmbulanceSlot_UpdateParamedics` waits for
   Chebyshev < 8.0 and a timer > 0x32, `FireEngineSlot_Update` state 2 for < 3.0 and a timer > 100.
6. Port inputs ruled out: the CRT static constants read on this path are correct at runtime
   (`5E512C = 0x4000`, `5E50B8 = 0x14000`, `5E520C = 0x8000`, `5E5398 = 0x1EB`); the chain uses no
   time, `rand`, FPU or camera (`RoadNetwork_FindRoute`, not the `*Offscreen` variant); the search
   buffers are cleared by `InitSearch`; the deciding values are integer map / sprite data.
7. Control experiment: NOPing only the `JNZ` at 0x430444 made the ambulance steer into lane
   x = 168, stop at (168, 129), free its route, and the paramedics revived the body.

Not done: a side-by-side run of the original game on Windows, and a natively triggered dispatch
without the K menu (the K entries only enqueue the body or light the car; everything after is the
game's own code, so the menu path *is* the native dispatch). Arrival on slopes / bridges
(fractional z) is untested.

**Workaround** (`host/c32/emergency.c`, `hk_follow_route`, a `c32_callhook`): a call hook on the
`call CarAI_FollowRoute` in `CarAI_Update` (0x432678) that, after the first K-menu call and only for
the vehicles held by the ambulance / fire-engine slots, sets the order's z to car z − 1.0 for the
duration of the call and restores it afterwards (`CarAI_UpdateDriveOrder` must keep planning with the
sprite z). Every other car runs the vanilla path. With it the MEDICAR stops at the body and the crew
revives it; the fire truck reaches the wreck, hoses (slot states 3 → 4 → 5) and leaves.

## 6b. Why `gta2ctl drive_to` takes a wrong turn (seq:58, Seq H1)

Seq 58 saw `drive_to` cars turn the wrong way at the first junction. The hypothesis was "the
start junction is chosen by the tile's arrow, not the car's heading". Checked in code and with an
offline simulation of the game's exact search over the real wil.gmp RGEN and DMAP arrows (no live
run). Three causes are possible:

1. **B1: route U-turns are never executed (most likely).** When the best path leaves the start
   junction back the way the car came, `CarAI_ApplyRouteTurn` 0x4300E0 only writes
   `routeUTurnExitDir` (+0x38, at 0x430204 / 0x430249 / 0x43027C / 0x4302B9) and sets flags 0x800.
   Nothing in `.text` reads +0x38 or tests bit 0x800 of `CarAI.flags` (every `test` of 0x800 /
   `ah,8` checked; the other 12 hits are Ped +0x21C). No turn bit is set, so the car drives
   **straight through** the junction, away from the target, and the per-tick re-plan retries from
   the next junction. Simulation, 4000 random wil trips: **23 % of routes start with a U-turn**;
   treating "U-turn" as "straight", every trip still arrives, median detour 1.0×, p90 1.36×, worst
   21× the planned hop count. A target behind the car = "went the wrong way at the first junction,
   then came back".
2. **B6: start junction ignores the heading (confirmed, but rarely the cause).** Start and goal come
   from tile arrows only (§5). Over every wil lane tile, with the car heading along its own tile's
   arrow, the start is the junction ahead on 13435 of 13437 single-arrow tiles (exceptions at
   (218..219, 167)), and the car's own junction when it is inside one. It only bites when the car
   **faces against its tile's arrows** (other lane of a two-way road, parked backwards, reversing):
   the route is planned from the junction behind the car, and `ApplyRouteTurn` applies that
   junction's turn, relative to the car's heading, at the junction actually ahead: a mirrored turn.
3. **B2: random turn when blocked.** `CarAI_UpdateJunctionTurn` 0x430650 calls
   `CarAI_PickRandomTurn` when `g_CarAI_driveOrderActive` is false at a junction entry. The flag is
   set by `UpdateDriveOrder` every tick and cleared in the same tick by `ReactToNearbyCar`,
   `HandleCarAhead` and `DriveStep` (car ahead / obstacle in the probe); `CarAI_Update` then also drops
   flags 0x10, so FollowRoute is skipped. A routed car queued behind another car at a junction where
   its route goes **straight** (turn bits clear) gets a random left / right that `TryStartTurn`
   commits. With a route turn pending the bits stay from the previous tick, so only "straight" hops
   are hit.

Which one caused the seq:58 run is **unknown** (no log of heading vs arrow, target bearing or a car
ahead). Likelihood from the code: B1, then B6, then B2.

**Deterministic test** with `drive_to --debug`: (a) a target straight behind the car in its own lane
on an empty road — expect straight on and a loop around; (b) the same target, car turned 180° in the
opposite lane — expect a mirrored turn; (c) a target ahead past a junction with a parked car in the
lane — expect an occasional random turn. The debug line should print `routes[0..1]`, the link dir and
`ai->flags & 0x800`.

**Workaround options** (host side, none done):

- (a) when flags 0x800 is set, feed `routeUTurnExitDir` as a turn (two same-side turns, or a hook that
  sets TurnLeft twice);
- (b) mark the junction behind as visited before the search (a hook in `RoadNetwork_InitSearch` that
  sets `visited[kind-0 junction] = 1`): no U-turn routes at all. **The smallest change.**
- (c) give the drive_to car a heading-based start junction (hook `FindSegmentJunctionAtTile` for that
  car).

The developers had a native precedent: `SomeSwitch` 0x41D0B0 is their debug key handler. Key 6 runs
two `RoadNetwork_FindRoute` tests; key 7 makes the player's car auto-drive to (3, 3, 1)
(`Car_InitAIWithRouteTarget` + `Car_StartDriving`) and logs its junction list ("Junc: %d"); 8 level
exit, 9 save, 10 fire engine, 11 quit.

### Route and car-AI bugs (Seq H1)

| # | VA | what | trigger | severity | confidence |
|---|---|---|---|---|---|
| B1 | 0x4300E0 (+0x38, 0x800) | route U-turn written, never executed | best path leaves the start junction backwards (23 % of random wil trips) | medium (detours, "drives away first") | high (static: no reader anywhere) |
| B2 | 0x430650 + 0x42FB80 / 0x431770 / 0x431C10 | routed car gets a random turn when blocked at a junction where the route goes straight | car ahead / obstacle at the junction entry | medium | high (code); frequency unmeasured |
| B3 | 0x40C9D0 | accumulating heuristic + goal-on-push + first-path-wins → routes are not shortest | always | low (quality) | high |
| B4 | 0x446340 | `FindAlliedDriverByManeuverTargetingPed` tests the alliance of each driver **with the target ped** (`Ped_AreAllied(targetPed, driver)`), not with the caller, so for cops chasing the player the "ally in maneuver 0/5" branches of 0x42D820 probably never match | police pursuit | low | medium (depends on `Ped_AreAllied` 0x4462F0: both cops, or same Ped+0x17C) |
| B5 | 0x40C9D0 | node pool index has no bound check against 0x884 nodes | cannot overflow: ≤ 545 junctions, each pushed once | none | high |
| B6 | 0x40D690 | start junction ignores the heading | car facing against its tile's arrows | medium for drive_to / mission cars placed backwards | high |
| B7 | 0x40D510 | arrow tiles outside every RGEN segment give no start → no route (route slot −1, the car only lane-follows) | 1321 arrow tiles on wil | low | high (simulation) |

`Ped_AreAllied` 0x4462F0 is `__stdcall`, but every caller also sets ECX = pool (harmless).

**Measured fix (seq:58, 2026-10-23).** Option (b) applied for the `drive_to` car only: a call hook
at 0x42AD41 runs `InitSearch`, sets `visited` of the kind-0 junction behind the car's heading (kept
while the car is inside a junction), then `RunSearch` and `StoreRoute`; the original path is the
fallback. Over the same 4 legs: 11190 → 6807 frames, samples with U-turn flag 0x800 541 → 6. The
remaining missed turns were not routing: with the player car's handling the AI turn was too wide,
fixed by nudging the heading toward `turnExitDir` while `CarAI.flags & 0x80` (turn in progress).

## 7. Structures (DB state after Seq 43)

- `CarAI` (0x78, alloc stride in CarAIPool 0x8F74 = 4 + 306·0x78): `+0 parentCar`, `+8 turnTimer`,
  `+9/+A turnTileX/Y`, `+0xC nextFree`, `+0x10 heading`, `+0x14/18/1C` speed cur / goal / step,
  `+0x24 flags` (§4), `+0x28 routeSlot` (s8, −1 none), `+0x2A stillTicks`, `+0x2C avoidTimer`,
  `+0x38 routeUTurnExitDir` (was `routeExitCode`; written only by `CarAI_ApplyRouteTurn`, ctor and
  reinit, never read), `+0x44 turnExitDir`, `+0x4C travelDir`, `+0x50 offRoadTurn`,
  `+0x54 laneFollowCooldown`, `+0x56 routeStep` (always 0, §5), `+0x74 targetSpeed`. Fields settled
  in U2 (2026-10-24; no `unsure_` left in CarAI or CarDriveOrder):

  | off | name (was) | type | meaning | evidence VA | conf. |
  |---|---|---|---|---|---|
  | 0x04 / 0x20 / 0x29 | `unusedZeroed04 / 20 / 29` (gap) | uint / uint / byte | zeroed by Ctor / Reinit only | 0x42A9F2 / 0x42AA35 / 0x42AA40, Reinit 0x42AAC5 / 0x42AB00 / 0x42AB11 | high |
  | 0x2B | `ageTicks` (unsure_ticksSinceReset) | byte | ticks since Ctor / Reinit, ++ saturating 0xFF; < 0x15 → no lane change | `CarAI_PreUpdate` 0x4327BF; read 0x42C8E0 | high |
  | 0x2D / 0x2E | `laneChangeStartLaneA / B` (gap) | byte | write-only: lane index (change toward lane−1) or 0; same value in both | 0x42CFC7 / 0x42CFCA, 0x42D343 / 0x42D346 | high (write-only); name = what is written |
  | 0x2F | `laneChangeTargetLane` (unsure_laneTarget) | byte | lane being moved to while flags 0x100 | set 0x42CFD4 / 0x42D35C; compared 0x42C094 | high |
  | 0x34 | `unusedZeroed34` (unsure_initOnly34) | int | Ctor / Reinit only | 0x42AA74 / 0x42AB45 | high |
  | 0x3C | `isOffRoad` (unsure_unstickState) | int 0/1 | off-road mode, §4a | set 0x42BE47; cleared 0x42B965 / 0x42FBB8; read 0x4323BF / 0x432506, 0x42D8E8 | high |
  | 0x40 | `laneAlignDir` (unsure_laneDir) | int | write-only: heading class the lane follower aligns to (travelDir or turnExitDir) | 0x430E91..0x43152A | high |
  | 0x48 | `leftTurnExitDir` (unsure_leftTurnExitDir) | int | exit heading after a left turn; read on other cars | written 0x42B3F8..0x42B6D5; read 0x42B80E | high |
  | 0x58 | `offRoadTicks` (stuckTicks) | ushort | ++ only while `isOffRoad`; > 200 → abandoned; never reset (§4b) | 0x43250F / 0x43252E | high |
  | 0x5C / 0x60 / 0x64 | `unusedZeroed5C / 60 / 64` (unsure_initOnly5C/60/64) | SCR_f | Ctor / Reinit only | 0x42AA59/62/6B, 0x42AB2A/33/3C | high |

  Untouched gaps (no access in any scan → padding): 0x0B, 0x12–0x13, 0x31–0x33.
- `CarDriveOrder` (0x40 = pool stride, pool 0x500 = 20): see §5; `+0xC maneuver`
  (`CAR_DRIVE_MANEUVER`, was `unsure_maneuver`), `+0x34 retryCooldown`. Settled in U2:

  | off | name (was) | type | meaning | evidence VA | conf. |
  |---|---|---|---|---|---|
  | 0x10 | `ramArmed` (unsure_ramArmed, earlier unsure_driveFlag) | byte | set by SIDE_PUSH; then contact with the target = 500 damage; sticky (§4b) | set 0x42E31D / 0x42E727; read 0x42FBCF; cleared only `CarDriveOrder_Reset` 0x4461A4 | high |
  | 0x21 / 0x24 / 0x25 | `unusedZeroed21 / 24 / 25` (gap) | byte | Reset only (the `[ESI+0x24]` byte tests elsewhere are `CarAI.flags`) | 0x4461CA / 0x4461D3 / 0x4461D6 | high |
  | 0x23 | `unusedInit23` (gap) | byte | Reset writes **1**, no reader | 0x4461D0 | high |
  | 0x2A | `targetLockTicks` (unsure_approachTicks) | ushort | ++ to 10 while close in TAIL, = 100 in FOLLOW, −− while far; at 0 the chase re-plans (grace period) | 0x42EF8A, 0x42F0DF, 0x42F05C / 0x42F71E; zeroed 0x42D545, 0x42FC32/46 | high (mechanics); name = interpretation |
  | 0x2C | `maneuverTicks` (unsure_phaseTicks) | ushort | FLANK_WAIT / FOLLOW wait counter; read / zeroed on an ally | 0x42F2AA…0x42F868, 0x42F03E | high |
  | 0x2E | `sidePushTicks` (unsure_sideTicks) | ushort | ticks alongside before the ram | 0x42E101 / 0x42E50F; zeroed 0x42FC25 | high |
  | 0x38 | `unusedZeroed38` (gap) | uint | Reset only | 0x4461F5 | high |
  | 0x3C | `blockHitCount` (unsure_blockAttempts) | byte | ++ when CUT_IN / BLOCK reaches 1.5 of the target; SIDE_PUSH gives up the ram at > 3; shared with `Ped.chaseHitCount` by `PoliceCrew_UpdateChaseDriveOrder` | ++ 0x42FA1B; read 0x42E268 / 0x42E672; 0x4ABC66 / 0x4ABCC3 | high |
  | 0x3F | `unused3F` (end) | byte | no access; seuko-mod `end` marker | — | high |

  Untouched gaps: 0x01–0x03, 0x11–0x13, 0x27–0x29, 0x36–0x37, 0x3D–0x3E. U2 also fixed the
  prototypes of `CarAI_Ctor`, `_Reinit`, `_ReserveJunction`, `_SteerByArrowAheadOffLane` (`void (CarAI*
  ai)`) and the return type (`void`) of `_UpdateLaneChangeAlign`, `_TryLaneChange`,
  `_UpdateDriveOrder`, `_ReactToNearbyCar`, `_FollowLane`, `_PreUpdate`; no caller uses their EAX.
- `RoadSegment` (8): `+0 junction1` (W / N end), `+2 junction2` (E / S end). `RoadJunction`: link
  slots +0 N, +2 S, +4 E, +6 W; `+8 arrowKind` 1 green / 2 red / 3 both. RGEN tail: `junctionCount`
  (312 on wil, +4), then `hSegCount` (+0xCC62, 366) and `vSegCount` (+0xCC64, 365); the two 545 × 8
  arrays are the H and V `RoadSegment` tables (see [loader-map.md](../formats/loader-map.md)).
- `CarManager` (0x6C): §3. `CarDoor`: §3. `SoundManager` layout: §2 (filled in the DB 2026-10-22, ~55 fields + `radioSlots[5]` `RadioStationSlot` @0x5468; the existing `S5` slot type is the 0xC slot record, `SoundClient` is 16 bytes — the 0x30
  layout currently in the DB is the weapon's).

## 8. Open questions

- Answered in Seq H1: flags 0x10 is set by `CarAI_FollowLane` (tile arrow in travelDir) and
  cleared by `CarAI_Update` / `CarAI_DriveStep`; the maneuver table is §5b; 0x5E5084 is
  `g_CarAI_targetCar`. Answered in U2: off-road mode / lane change / junction reservation (§4a),
  every CarAI and CarDriveOrder field (§7).
- Which of B1 / B6 / B2 caused the seq:58 wrong turn (test recipe in §6b).
- Side A / B = left / right of the target car (needs the `Ang16_PolarToXY` convention vs sprite
  rotation; the angle table suggests R + 90° = the car's left, unverified).
- Who sets `CarDriveOrder.mode` 3 and 5 (`DRIVE_ORDER_UNSURE_ATTACK_B`); only writers of 1, 2, 4 were
  found (`Ped_Obj1_GoToAreaInCar`, the FollowCarInCar / Unk10 objectives, `Ped_Obj1_DriveAttackTarget`).
  Who sets maneuver 1.
- `offRoadTurn` 1 vs 2: which is left / right (SteerPlus vs SteerMinus sign) — not checked (U2).
- `laneChangeStartLaneA/B` (+0x2D / +0x2E) and `CarDriveOrder.unusedInit23`: written, never read;
  whatever they were for was removed. Other unnamed bits of `CarAI.flags` were out of U2's scope.
- Whether the West red-bit slip in `CarAI_FollowLane` (§4b) visibly changes traffic on red-arrow
  roads (not observed live).
- Still without a good name: 0x5E507D (set when Drive / FollowLane is on heading, then flags
  0x2000), 0x420350 (horn start; no function defined there; the horn gate is `Car_IsPoliceModel`
  0x41F6E0), `SomeSwitch` 0x41D0B0 (the debug key handler, §6b).
- Sound source kinds 8 / 9, car info indices 0x36 / 0x3C, sample bank ids → cue names (see also
  §2f for the U1 sound open questions).
- Camera `+0x30` (shake amplitude vs `CAMERA_MOVEMENT` bitmask) and the `+0x60/+0x64` split: medium
  confidence, struct left unchanged.
- `copCalledCars` (+0x48) heap garbage: runtime value never dumped.

## 9. Functions named in Seq 43

All 348 functions that were unnamed at the start, by slice (names as exported to `re/functions.csv`; "V" unless the name carries `unsure_`; evidence from the slice reports, empty where the name is a plain field accessor). Slices: sound events (Sonnet agent N1), SoundManager (N2), camera / doors / CarManager (N3), lifecycle / CarAI helpers (N4); route bug hunt (B) and coordinator checks in §5–6.

#### Sound events, car-sound helpers (0x410000–0x414E4F, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x410010 | SoundEvent_InitFromPedHit | V | classifies g_CollisionResult.kind/.hitSprite -> event type 8/4/6/7 |
| 0x4100F0 | SoundEvent_InitFromObjectHit | V | same, types 10/3/7/9, +0x18 objType, +0x1c |
| 0x410210 | SoundEventQueue_AddHit | V | appends event at queue+4+cnt*0x28, cnt at +0xc84 |
| 0x4102A0 | SoundEventQueue_AddImpactEventSurfaceBelow | V | event types 0xb/0xc/1, z shifted |
| 0x410370 | SoundEventQueue_AddImpactEvent | V | same without z shift |
| 0x410440 | SoundEventQueue_ReleaseClient | V | from SoundEventQueue_Dtor; returns client to pool via 40fe60 |
| 0x410460 | SoundEventQueue_AddHitDefaultVolume | V | wrapper of 410210 with DAT_005d82d0 |
| 0x410480 | SoundEventQueue_AddHitWithKind | V | sets g_CollisionResult.kind then 410460 |
| 0x410500 | SoundMgr_Init_Thunk | V | initSound(&g_SoundManager) |
| 0x410570 | SoundMgr_Reset_Thunk | V | SoundManager_Reset(g_SoundManager), from Game_Dtor |
| 0x410580 | SoundMgr_AddRadioStation_Thunk | V | caller Script_Decl_RADIO_STATION |
| 0x410590 | SoundManager_Radio_RemoveStationAt (was SoundMgr_CancelVocalAt) | V | removes the radio station slot at an (x,y) pair (body 0x4B2350; 0x5E2014 = radio slot i−1 addressing, stride 0x1C); caller MissionScript_DeleteItemByCmd |
| 0x4105C0 | Sound_SetSFXVolume | V | clamp 0x7f -> SFXVolume |
| 0x410630 | Sound_GetCDVolume | V | returns CDVol |
| 0x410640 | MssAudio_ReleaseDevice_Thunk | V | _AIL_digital_handle_release_4; WndProc only |
| 0x410650 | SoundMgr_ReacquireDevice_Thunk | V | SoundMgr_ReacquireAudioDevice(g_SoundManager) = reacquire; WndProc |
| 0x410660 | unsure_Sound_GetCdDriveLetter (was unsure_Audio_GetCdDriveLetter) | H | returns MssAudio+4 = `'c'` (99); read by the intro-movie path builders and ignored |
| 0x410690 | SoundClientPool_Dtor | V | *p=0 (only a thunk caller) |
| 0x4106A0 | SoundClientPool_InitFreeList | V | 1000 nodes x16, link +0xc |
| 0x4106F0 | SoundClientPool_Ctor | V | wraps 4106a0, no callers (static init) |
| 0x410700 | thunk → SoundClientPool_Dtor_Thunk | V | thunk |
| 0x410710 | SoundClient_FreeVoice | V | SoundMgr_DetachSource on node+8; called by 40fe60 (pool free) |
| 0x410790 | Sound_NopPreInit | V | empty; from initSound |
| 0x4107A0 | Sound_NopPreShutdown | V | empty; from 4164d0 |
| 0x4107B0 | SoundMgr_PickImpactSample3Tier | V | vol<0xf none; <0x28 ->0x25; <0x5a ->0x26; else 0x27; writes SoundManager+0x44/0x50 |
| 0x410800 | Sound_PlayStreamTrackByCode | V | code 0x40..0x68 (+0x88) -> track -> MssAudio_Stream_OpenTrack |
| 0x410A70 | SoundMgr_PickImpactSample2Tier | V | samples 0x28/0x29 |
| 0x410AC0 | SoundMgr_PickImpactSample3TierNoCutoff | V | as 4107b0 w/o cutoff |
| 0x410B10 | SoundMgr_PickSurfaceImpactSample | V | by event+0x20 -> 0x27/0x26/0x44 |
| 0x410BF0 | Fix16_RoundToInt | V | (x+0x2000)>>14; Fix16 has 14 fractional bits |
| 0x410E20 | CarModel_GetEngineLoopSample | V | model -> 3..8; only caller 414fa0 |
| 0x410EE0 | CarModel_GetSirenSample | V | -> 0xe/0xf |
| 0x410F00 | CarModel_GetHornSample | V | -> 0x10..0x17 |
| 0x410FC0 | CarModel_GetHornBaseFreq | V | returns sample rates (0x5622 = 22050 ...) |
| 0x411120 | CarModel_IsHeavyVehicle | V | set {3,7,0xb,0x11,0x15,0x3a,0x3f,0x40,0x56}; same set as 413eb0 idle |
| 0x4112B0 | SoundMgr_CreateVocalClient | V | SoundMgr_AttachClient of the type-10 client at SoundManager+0x5454; slot into vocalSourceSlot +0x5450 |
| 0x4112F0 | SoundMgr_DestroyVocalClient | V | detaches vocalSourceSlot (+0x5450) |
| 0x411330 | SoundMgr_UpdateVocalClient | V | VOCAL id SoundManager+0x5464 -> MssAudio_Stream_OpenTrack, clears it |
| 0x4116B0 | SoundMgr_IsVoiceInRange | V | dist2(+0x28) < arg, lazy sqrt -> +0x58, flag +0x2c |
| 0x4116F0 | SoundMgr_ComputeVoiceVolume | V | 416da0 attenuation -> +0x54, halved if muffled |
| 0x411730 | SoundMgr_GetDistSqToListener | V | (+0x38-+0x1468)^2+(+0x3c-+0x146c)^2 |
| 0x4117B0 | Sprite_GetXYZ | V | +0x14/+0x18/+0x1c; caller Hud_ArrowTarget_UpdatePosition |
| 0x4117D0 | Ped_TakeTrainStop | H | read-and-clear +0x13c (receiver = driver Ped from Car_GetDriver) |
| 0x4117F0 | Ped_TakeTrainStop2 | H | identical twin of 4117d0 |
| 0x411810 | CarPhysics_IsReverseGasOn | V | CarPhysics+0x94 |
| 0x411820 | CarPhysics_GetThrottle | V | +0x60 (receiver = Car+0x64? no: CarDriveOrder in Car+0x60; here param is CarPhysics from Car+0x58 in 413160) |
| 0x411830 | CarPhysics_GetWheelSpinTimer | V | +0xac |
| 0x411840 | CarPhysics_GetFrontSlip | V | +0x84 |
| 0x411850 | CarPhysics_GetRearSlip | V | +0x88 |
| 0x411860 | CarPhysics_GetGroundMaterial | V | +0x9c |
| 0x411870 | CarDoor_IsOpeningStart | V | state==2 && animationFrame==0 && frameDelay==0 |
| 0x411890 | CarDoor_IsClosingAtFrame1 | V | state==3 && animationFrame==1 |
| 0x4118B0 | Car_GetDriver | V | Car+0x54, 19 callers |
| 0x411950 | Car_TakeDriverReaction | V | Car+0xac read-and-clear |
| 0x411990 | Car_GetHornStateOrZero | V | Car+0xa7, 0 if >0xf8 |
| 0x4119B0 | Car_HasBomb | V | push 0x84 (OBJECT_TYPE_CAR_BOMB); call Car_FindAttachmentByType |
| 0x4119C0 | Car_IsEngineStateSiren | V | engineState==4 = REL_TO_CAR_SIREN; caller is siren sound |
| 0x4119D0 | Car_TakeShopReaction | V | Car+0xb4 |
| 0x4119F0 | Car_IsTurretBeingRotated | V | Car+0xb8 |
| 0x411A00 | Crane_GetBasePosition | V | *(x+0x2c)+4; IS_ITEM_ONSCREEN case 4 + type-8 client |
| 0x411A10 | Crusher_GetHasTarget | V | x+0x2c |
| 0x411A20 | Crusher_GetPosX | V | owner+0x24 of type-9 client |
| 0x411A30 | Crusher_GetPosY | V | owner+0x28 |
| 0x411A40 | HudPagerEntry_GetTimerTicks | V | *p |
| 0x411A50 | SoundMgr_UpdateMusicClient | V | type-2 client, MusicStream_IsDone -> Close/Open, vol SoundManager+0x25*6/10 |
| 0x411D20 | SoundMgr_UpdateCraneSource | V | type 8 case of 4163a0; owner flags +0x156..+0x159 |
| 0x412010 | SoundMgr_UpdateCrusherSource | V | type 9; owner +0x24/+0x28 pos |
| 0x4121F0 | SoundMgr_CalcImpactVolume | V | event type 2..5 -> normalised volume; default random 5..14 |
| 0x4123C0 | CarSound_AddDriverReaction | H | Car_TakeDriverReaction -> samples 0x101..0x10f, layer 7 |
| 0x412680 | CarSound_AddTrainCabSpeedLoopA | V | speed/maxspeed -> vol, sample 4, layer 0 |
| 0x412830 | CarSound_AddTrainCabSpeedLoopB | V | sample 5, layer 2, vol 0x7f scale |
| 0x4129D0 | SoundMgr_GetChannelCar | V | channel -> client owner -> Sprite_GetCar |
| 0x412A20 | CarSound_AddTrainStopSound | H | Car_GetDriver -> Ped+0x13c -> sample 0x8b/0x8c, layer 3 |
| 0x412BD0 | CarSound_AddTankSpeedLoop | V | engine on, layer 5, sample 0xc |
| 0x412D80 | CarSound_AddTurretRotation | V | Car_IsTurretBeingRotated, layer 4, sample 0xb |
| 0x412EB0 | CarSound_AddBombTick | V | Car_HasBomb, layer 0xf |
| 0x412FE0 | CarSound_AddShopReaction | V | Car_TakeShopReaction -> samples 0x3e..0x43, one-shot |
| 0x413160 | CarSound_AddEngine | V | engine on, layer 0, sample 1 |
| 0x4139A0 | CarSound_AddAlarm | V | Car+0x8e alarmTimer, layer 6 |
| 0x413BD0 | CarSound_AddDamagedEngine | V | engine on and Car.damage(+0x74)>16000, layer 1 |
| 0x413DF0 | CarSound_PickDoorSample | V | model -> 0x1a..0x1f |
| 0x413EB0 | CarSound_AddHeavyVehicleIdle | V | speed==0 & heavy model, sample 7, layer 2 |
| 0x414030 | CarSound_AddHeavyVehicleSlide | V | !IsVelocityAlignedWithHeading & heavy model, layer 0xb |
| 0x414200 | CarSound_AddAiCarSpeedLoop (was unsure_CarSound_AddSpeedLoopC) | V | sample 2, layer 2; runs only when the car has no player driver |
| 0x4143B0 | CarSound_AddDoors | V | per door: IsOpeningStart->layer 9, IsClosingAtFrame1->layer 0xa |
| 0x414780 | CarSound_AddSiren | V | engineState==4, layer 0xc, sample 1/2 by carInfo parity |
| 0x4148D0 | CarSound_AddTyreSlip | V | front/rear slip, wheelSpinTimer vs CarPhysicsData thresholds, layer 0xd |

#### SoundManager, police radio, ComboList (0x414E50–0x41DDFF, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x414E50 | SoundMgr_UpdateOnScreenCounterSource | V | called from UpdateSource for kind 0xB; sample 0x39, vol by value of HudPagerEntry_GetTimerTicks (thresholds 0x97/0x12D) |
| 0x414F80 | Car_IsSirenActive | V | IsCarHasEmergencyLights && lightsBitstate SIREN_ON |
| 0x414FA0 | SoundMgr_ResolveRequestParams | V | switch on request category (+0x58): picks sample, freq, radius, loop, bank fields B0/B8/BC |
| 0x4150E0 | SoundMgr_PickEventSample | V | event id (+0x18) + category 1/3/7/9 -> sample id (SoundManager+0x44), pitch (SoundManager+0x50) from random SoundManager+0x1454/58 |
| 0x415520 | SoundMgr_ResolveEventCategory9 | V | id filter then PickEventSample(..,9) |
| 0x4156B0 | thunk → CarSound_AddDoors | V | thunk |
| 0x4156C0 | CarSound_AddTankCarContactLoop (was unsure_) | V | needs Car_IsEngineOn + Car_HasFlag2000 (touching another car this tick); request type 0xE, cat 0xD, level bank 0x24 |
| 0x415880 | SoundMgr_UpdateCarHorn | V | Car_IsHonking; request type 8, cat 5; skips fire truck/tank/siren cases |
| 0x415A90 | SoundMgr_UpdateCarSiren | V | Car_IsSirenActive + engine on; type 7, cat 4, vol 0x46 |
| 0x415BE0 | SoundMgr_ResolveEventCategory1 | V | PickEventSample(..,1) |
| 0x415BF0 | SoundMgr_ResolveEventCategory3 | V | ids 200..244 / 0x40..0x6C -> Sound_PlayStreamTrackByCode, else (..,3) |
| 0x415C30 | SoundMgr_ResolveEventCategory7 | V | same ranges, (..,7) |
| 0x415C70 | SoundMgr_UpdateCarSource_Model3C | V | dispatcher branch for car info idx 0x3C |
| 0x415CC0 | SoundMgr_UpdateCarSource_Model36 | V | branch for idx 0x36 |
| 0x415D20 | SoundMgr_UpdateCarSource_Default | V | engine, siren, horn, 4139A0.. chain |
| 0x415DF0 | SoundMgr_UpdateCarSource | V | stores Car_HasPlayerDriver in source+4; switch Car_GetCarInfoIdx |
| 0x415EF0 | SoundMgr_ResolveEventSample | V | switch on event category: 1,10->Cat1; 2,4,5,0xC->410xxx; 3; 7; 9 |
| 0x415F90 | SoundMgr_UpdateEventQueueSource | V | kind 6: walks SoundEventQueue (events 0x28, count +0xC84), best candidate queued |
| 0x4162C0 | SoundMgr_UpdateSpriteSource | V | kind 1: ped->UpdatePedSource, car->UpdateCarSource, object->UpdateObjectSource |
| 0x4163A0 | SoundMgr_UpdateSource | V | switch kind: 1,6,7,8,9,10,0xB; kind 3 -> SoundManager_UpdateRadio; kind 2 -> 411A50 (music) |
| 0x4164D0 | SoundMgr_Shutdown | V | SoundManager_Reset, ends samples, clears slots, MssAudio_Shutdown |
| 0x4166D0 | SoundMgr_Is3DActive | V | init && [+0x1D] |
| 0x4166E0 | SoundMgr_GetPitchJitter | V | random % bank field B4, sign toggled via DAT_00591DF5 |
| 0x4167C0 | SoundMgr_InsertRequestSorted | V | memmove into sorted index (0xD9C + buf*16) |
| 0x416880 | Fix16_PtrToInt | V | *p >> 14 (also used by NearestSprite_SpiralSearch) |
| 0x416890 | SoundMgr_RecalcRequestRemaining | V | bank size * SoundManager[+8] / freq into request+0x44, -3 when no loop |
| 0x4168E0 | SoundMgr_GetPosRelativeToListener | V | Fix16_Sub with +0x1468/146C/1470 |
| 0x416940 | Fix16_ToFloatStore | V | stdcall(Fix16, float*) |
| 0x416960 | SoundMgr_ScaleVolumeByDistanceFade | V | linear fade in last 1/4 of radius |
| 0x4169A0 | SoundMgr_ResetRequestSortIndex | V | fills sort index with numVoices, count=0 |
| 0x4169E0 | SoundMgr_ResetVoices | V | init 16 voices (0xDC0, 0x68 each) |
| 0x416B20 | SoundMgr_ReseedRandoms | V | 5x Crt_Rand into +0x1454 |
| 0x416B50 | Ped_GetZ | V | writes *(Ped+0x1B4) to out; sibling of Ped_GetX/Y; 46 callers |
| 0x416B70 | Camera_GetFollowedPed | V | returns +0x34; nonzero -> ped branch in 417030 |
| 0x416B80 | Car_GetBodyPos | V | reads Car+0x50 -> +0x14/18/1C (Sprite*) |
| 0x416BB0 | Car_GetBodyRotation | V | reads u16 at *(Car+0x50) |
| 0x416BF0 | SoundMgr_ShutdownIfInitialized | V | wrapper on SoundManager[0] |
| 0x416D60 | SoundMgr_ReacquireAudioDevice | V | AIL_digital_handle_reacquire |
| 0x416DA0 | SoundMgr_CalcDistanceVolume | V | clamp 0..0x7F; called by 4116F0 |
| 0x416E50 | SoundMgr_CalcPan | V | pan 10..0x75 from relative X, table at 0x591DF8 |
| 0x416F20 | SoundMgr_ApplyDopplerToFrequency | V | scales freq by relative speed vs DAT_005E2228 |
| 0x417030 | SoundMgr_UpdateListenerAndSources | V | listener from player ped/car, loop active list calling UpdateSource |
| 0x4171A0 | SoundMgr_QueueRequest | V | 39 xrefs; copies SoundManager+0x30 (0x68 B) into queue; key (0x7F-vol)*[+0x4C] |
| 0x417260 | SoundMgr_RequeueRepeatingRequests | V | replays previous buffer entries with remaining counter (+0x4C of record) |
| 0x417410 | SoundMgr_ApplyRequestsToVoices | V | MssAudio_Sample[3D]_* calls |
| 0x417CE0 | SoundMgr_Apply3DDistanceFade | V | only when 3D; __ftol2 + 416960 |
| 0x417D90 | SoundManager_RadioSlots_Ctor (was SoundMgr_VocalSlots_Ctor) | V | vector_constructor_iterator(+0x5468,0x1C,5) = radioSlots |
| 0x417EA0 | SoundMgr_UpdateFrame | V | flip buffer, UpdateListener, Requeue, Fade, Apply, age slots |
| 0x417EF0 | SoundMgr_Ctor | V | defaults |
| 0x418050 | SoundMgr_Update | V | pause handling + every-5th-frame flag +0x544C |
| 0x418100 | SoundMgr_PlayPhoneCallChatter | V | ExtraSample_PlayRange with random 0x45../0x57.. or 0x73../0x83.. |
| 0x4181C0 | SoundObj_GetAmbientType | V | byte +0x26 |
| 0x4181D0 | SoundObj_IsAmbientEmitter | V | *(info+8)+0x34 == 0xC |
| 0x4181E0 | SoundMgr_UpdateAmbientObjectSource | V | 8 KB switch types 3..0x33; per-type cooldowns DAT_005E24xx |
| 0x41A3C0 | SoundMgr_UpdateObjectSourceByType | V | switch on Object_GetModel(obj) (5,0x71,0x80,0x8B,0xA4..,0xB9..,0xC5) |
| 0x41B030 | SoundMgr_UpdateObjectSource | V | picks 4181E0 or 41A3C0 |
| 0x41B060 | SoundMgr_TickPedSpeechCooldown | V | DAT_005E2B98 6->0 |
| 0x41B090 | PedGameObject_GetState2 | H | returns +0xC; sole caller UpdatePedSource |
| 0x41B0B0 | Ped_ConsumePendingSpeechEvent | V | read +0x250 then zero |
| 0x41B0D0 | SoundMgr_UpdatePedSpeech | V | event 1..0x1C -> sample ranges 0xD2..0x13x |
| 0x41B7B0 | SoundMgr_UpdatePedSource | V | callees Ped_IsPlayerControlled (was Ped_HasWeapons), Player_GetCurrentCar, Sprite_GetSpeed, 41B0D0 |
| 0x41BF60 | PoliceRadio_ClearQueue | V | fills 15 entries with 0x79, idx 0 |
| 0x41BF90 | PoliceRadio_QueuePhrase | V | ring buffer, id clamp 0x45..0x88 |
| 0x41C000 | PoliceRadio_PumpQueue | V | plays next phrase when ExtraSample finished |
| 0x41C0D0 | PoliceRadio_GetFreeQueueSlots | V |  |
| 0x41C0F0 | SoundMgr_NoOp | V | single ret |
| 0x41C100 | PoliceRadio_QueueCopKillFollowUp (was unsure_PoliceRadio_QueueType8FollowUpPhrases) | V | queues 0x79,0x5F,0x5B,0x78 when >3 free; fired by policeCopKillFollowUpTimer |
| 0x41C150 | PoliceRadio_FindDistrictAtPos | V | zone type 3 named m## |
| 0x41C200 | PoliceRadio_Reset | V |  |
| 0x41C240 | PoliceRadio_QueueLocationPhrases | V | compass 0x73..0x77 + district 0x79+n |
| 0x41C350 | PoliceRadio_QueueCarDescription | V | colour (sprite id) + model class; caller PoliceRadio_Update |
| 0x41C5A0 | PoliceRadio_QueueCrimeReport | V | caller PoliceRadio_Update |
| 0x41CC70 | Weapon_GetField04 | V | int at +4, must be 0 in UpdateWeaponSource; also used by Ped_Obj2_ApproachAndAttackTarget |
| 0x41CC80 | Weapon_ConsumeFiredFlag | V | read +0x2C then zero |
| 0x41CC90 | Weapon_GetWeaponType | V | +0x1C |
| 0x41CCA0 | SoundMgr_UpdateWeaponSource | V | kind 7; sample 0x137..0x13F by weapon type |
| 0x41D010 | WorldObject_Dtor | H | zeroes +0,+4,+8,+0x10; caller WorldObjectPool_Ctor |
| 0x41D030 | WorldObject_ScalarDeletingDtor | H | 0 xrefs |
| 0x41D070 | Box3_Ctor | V | returns this; callers PoliceRoadblock_Ctor, TrafficSpawner_Ctor |
| 0x41D8A0 | ComboEntry_Reset | V | defaults (-1, 0x57, 0x33, ..) |
| 0x41D8F0 | thunk → ComboEntry_Reset | V | thunk |
| 0x41D950 | ComboList_FindFreeEntry | V | first entry with +0x2A == 0, else 10 |
| 0x41D980 | ComboList_PollEntry | V | returns -1 inactive, -2, -3 done, -4; caller ScriptThread_GetBonusResult |
| 0x41D9D0 | ComboEntry_MatchField14 | V | pattern groups for param_7 |
| 0x41DA60 | ComboEntry_MatchOccupation | V | pattern groups 0x2E..0x31 for param_4 |
| 0x41DB10 | ComboEntry_MatchCarModel | V | groups {3,0xC,0x16,0x1E,0x34,0x36,0x54}, wildcards 0x33/0x38 |
| 0x41DD20 | ComboList_FindMatchingEntry | V | scans 10 entries; caller ComboList_Add |

#### Camera, doors, CarManager, Sprite (0x41DE00–0x42179F, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x41DE40 | ComboList_AddBonusCheck | V | 0x2c-byte slot, 10 slots (10 = full), caller Script_Op_START_BONUS_CHECK |
| 0x41DF70 | Camera_StorePrevPos | V | cameraPos2(0x88) := cameraPos(0x98) |
| 0x41DFB0 | Camera_ResetElevationOffset | V | +0x40 = 0 |
| 0x41E010 | Camera_ResetSmoothing | V | 0x98 := 0x0, velocity(0xac) := 0; Player_Watch*/OnWasted/OnBusted/OnLevelStart/WARP_FROM_CAR_TO_POINT |
| 0x41E350 | Box3_SetXYRanges | V | writes [0..3] = xmin,xmax,ymin,ymax (use in 41f180) |
| 0x41E370 | Box3_SetZRange | V | writes [4],[5] |
| 0x41E390 | SpriteBounds_IsSquareAndSmall | H | a==b && a<=DAT_005e3e10 |
| 0x41E3D0 | Camera_SetTarget | V | target x,y, z=p3+elev(0x40), w |
| 0x41E410 | Camera_CommitTarget | V | cameraPosTarget2 := cameraPosTarget |
| 0x41E480 | Camera_IsTrackingSprite | V | compares with followCar(0x38) / ped(0x34)'s car |
| 0x41E4E0 | Camera_IncreaseElevationOffset | V | +0x40 += step, clamp; Player_ApplyDebugZoomKeys |
| 0x41E510 | Camera_DecreaseElevationOffset | V | +0x40 -= step, clamp at 0 |
| 0x41E540 | Camera_ClampTargetZ | V | +0x18 clamped to [0, DAT_005e3d54] |
| 0x41E580 | Camera_ShiftTargetByCameraDelta | V | target += (cameraPos - cameraPos2) of other camera |
| 0x41E710 | Camera_IsWorldPointOnScreen | V | WorldPointToScreen, 0<=x<640, 0<=y<480 |
| 0x41EAD0 | Camera_SetShake | V | +0x30 = const * arg |
| 0x41EB00 | Camera_ApplyShake | V | +0x30 added to pos xyz, then *= -DAT_005e4008 (damped) |
| 0x41EB70 | Camera_SetViewSize | V | 0x68/0x6c w/h, 0x70/0x74 half, 0x60/0x64=-1, uiScale(0xa8)=w/640 |
| 0x41EEF0 | Camera_UpdatePanOffsetFromKeys | V | 4 key flags -> ramps 0x48/0x4c, counters 0x50-0x5c |
| 0x41F0A0 | Camera_ResetPanVelocity | V | Vec2_SetZero(0x48), zero 0x50-0x5c |
| 0x41F0D0 | Camera_ApplyPanOffset | V | adds 0x48/0x4c * scale |
| 0x41F180 | Camera_IsPositionInView | V | Box3 around camera vs sprite bounds |
| 0x41F2F0 | Camera_Tick | V | followState(0x3c) 1 smooth / 2 snap, shake, UpdateBoundaries, commit |
| 0x41F680 | CarDoor_RequestOpen | V | state 1/2 -> timer(+0xc)=0x32; 3..6 -> state 2, byte1=4 |
| 0x41F6E0 | Car_IsPoliceModel | V | model in {12,52,84} |
| 0x41F880 | Car_GetDoorCount | V | StyleData_GetCarDoorInfo(model)[0] |
| 0x41F8A0 | Car_OpenAllDoors | V | loop CarDoor_RequestOpen |
| 0x41F8F0 | Car_CloseAllDoors | V | loop CarDoor_RequestClose |
| 0x41F9B0 | DamageFire_GetEffectTypeForStage | V | 1->0xc,2->0xd,3->0xe; Car_SpawnDamageFireEffect |
| 0x41FA60 | Car_IsInCrusherList | V | wrapper of CrusherManager_ContainsCar (crusher array, count +0x90, stride 0x30, car at +0x14) |
| 0x41FAB0 | Car_GetTrailerCabOrSelf | V | Car+0x64 ? (*+0x64)+8 : this |
| 0x41FAC0 | Car_GetCornerAngle | V | atan2(h/2,w/2) of CarInfo |
| 0x41FBD0 | Car_AttachGangDecal | V | ObjectSpawner_SpawnObject(KILL_FRENZY+p), attach to sprite(0x50) |
| 0x41FC70 | Car_GetTrailerOrSelfBody | V | ctrl ? ctrl->[0xc]->+0x50 : +0x50 |
| 0x41FC90 | Ang16_RotateXY | V | x'=x cos + y sin, y'=y cos - x sin |
| 0x41FE40 | Fix16_SwapXYIfDir3or4 | V | swap when 2<p<5 |
| 0x41FE70 | RelTable_GetSigned | V | table[i] or -table[-i] |
| 0x41FF20 | CarInfo_GetRearWindowOffsetFix16 | V | relTable[this+0xb] |
| 0x41FF40 | CarInfo_GetFrontWindowOffsetFix16 | V | relTable[this+0xa] |
| 0x41FF60 | CarInfo_GetScaledWidthFix16 | V | relTable[this+2]*DAT_005e4fb4 |
| 0x420220 | StyleData_GetSpriteWidth | V | StyleData_GetSpriteEntry(id)->w |
| 0x420230 | StyleData_GetSpriteSizeFix16 | V | relTable[w], relTable[h] |
| 0x420270 | Car_GetLookAheadZ | V | physics(0x58) ? CarPhysics_GetLookAheadZ : sprite+0x1c |
| 0x420470 | Box3_SetXYRangesWithZCenter | V | 4 stack args + z -+ DAT_005e4d50 |
| 0x4204D0 | Box3_SetFromCenterSize | V | 6 fields from center/size |
| 0x420590 | Fix16Holder_Load | V | *out = *this; callers 420720/420740/Ped_React... |
| 0x420660 | Sprite_SetZ | V | +0x1c + Sprite_MarkBoundsDirty |
| 0x4206E0 | Sprite_SetField22 | V | short +0x22 |
| 0x4206F0 | Sprite_SetSpriteType (was Sprite_SetCollisionKind) | V | +0x30 spriteType + Sprite_SetDefaultLayerByKind |
| 0x420710 | Sprite_SetOwner | V | CarManager_SpawnCar: FUN(car2->body, car2) writes body+8 = car |
| 0x420720 | Sprite_GetFrameWidth | H | Fix16Holder_Load(*(this+4)); Car_IsSpriteZDifferent |
| 0x420740 | Sprite_GetBodyWidth | H | Fix16Holder_Load(*(this+0xc)); CrusherSlot_Update, Car_IsSpriteZDifferent |
| 0x4207E0 | ListHead_Init | V | *this=0; Car_InitAttachments(&attachments), Crane_Init, WeaponManager_Ctor(&hitCarList), CarManager_Ctor(2 globals) |
| 0x420B50 | Ped_GetOwnerSlot | V | Ped+0x267 |
| 0x420B60 | Ped_GetId | V | Ped+0x200 (byte-identical twin at 0x4C4F20, renamed `Ped_GetIdTwin` to avoid a duplicate name) |
| 0x420C30 | OwnerSlot_IsValid | V | slot<13 |
| 0x420D80 | CarDeltas_Ctor | V | Car_Ctor: FUN(&car->deltasBitstate) |
| 0x420D90 | CarDeltas_Reset | V | Car_Reset, Car_BecomeWreck on &deltasBitstate |
| 0x420DA0 | TrafficSpawner_ScalarDeletingDtor | V | TrafficSpawner_Dtor + free; CarManager_FreePools |
| 0x420E00 | Sprite_ScalarDeletingDtor | V | thunk_Sprite_ReleaseSoundClient + free; CarManager_FreePools |
| 0x420E40 | CarAIPool_ClearLast | V | *this=0 from CarAIPool_ScalarDeletingDtor |
| 0x420E60 | TrailerControllerPool_ClearHead | V | *this=0 from TrailerControllerPool_ScalarDeletingDtor |
| 0x420EA0 | PedQueue_IsEmpty | V | *p==0; Car_IsTaxiAvailableForHire, AmbulanceSlot_Update, Ped_UpdateTaxiPassenger |
| 0x420FF0 | WorldObject_GetOwnerSlot | V | byte +0x26, passed to OwnerSlotTable_GetPedId; Object type 0x84 (projectile) |
| 0x421020 | WorldObject_GetShopId | V | byte +0x26 of object type 0x82; only Car_OnEnterShop |
| 0x421030 | SpritePool_Free | V | unlink (Sprite_DtorBody) + push, +0xc = next |
| 0x421050 | WorldObject_GetParamByte26 | V | byte +0x26; bonusTokenAllowed[], DoorManager_ShouldDoorBlock, surface code |
| 0x421080 | WorldObject_KindHasOwnerSlot (was unsure_WorldObject_KindHasOwnerSlot) | H | (*(this+8))+0x34 not in {1,6,7,8,9,10,12} |
| 0x4210B0 | WorldObject_IsPrefabGridKind3 | V | (*(this+8))+0x40 == 3; Sprite_ShouldCollideWithSprite |
| 0x4210C0 | CarAI_ClearParentCar | V | *p=0; CarAIPool_Free |
| 0x421150 | CarPhysics_GetLinearVelocity | V | Vec2 at +0x40 |
| 0x421170 | CarPhysics_SetLinearVelocity | V | Car_ZeroVelocity calls it with Car+0x58 |
| 0x421190 | CarPhysics_SetAngularVelocity | V | +0x74 = defaultX in Car_ZeroVelocity right after SetLinearVelocity |
| 0x4211C0 | Fix16Vec2_GetLengthOut | V | wrapper of Fix16Vec2_GetLength |
| 0x4211E0 | CarPhysics_GetVelocityAngle | V | Fix16Vec2_GetAngle(+0x40) |
| 0x421310 | CarDoor_Ctor | V | Car_Ctor eh_vector_constructor_iterator(car->carDoor,16,4,...) |
| 0x421340 | CarDoor_ClearState | V | state=0; Car_InitDoors |
| 0x421360 | CarDoor_IsActive | V | state not in {0,6} |
| 0x421380 | CarDoor_SetPedInDoor | V | +8=x; Ped_Obj2_EnterCar/LeaveCar, Car_InitDoors |
| 0x421430 | Car_ClearRearLightsOnDeltas | V | CarDeltas_ClearBit(5), (0x16); Car_AlarmStop, Car_BrakeLightsOff, Car_UpdateLightsAndSiren |
| 0x4214F0 | Car_IsDrivenByNonPlayer | V | Car+0x54 && !Ped_IsPedClass(PLAYER) |
| 0x421530 | Car_SetRouteBit3 | V | +0xa6 |
| 0x4215C0 | Car_HasPlayerDriver | V | driver->player && occupation != EMPTY |
| 0x421610 | Car_IsTrainModel | V | model == 0x3b (TRAIN) |
| 0x421740 | Car_IsFreeTrailer | V | !trailerController && IsTrailer |
| 0x421760 | Car_IsFreeArticCab | V | !trailerController && IsArticCab |
| 0x421780 | Car_IsMedicar | V | model == 0x22 (MEDICAR) |

#### Car lifecycle, pools, CarAI helpers (0x4217A0–0x42FFFF, 87)

| address | name | V/H | evidence |
|---|---|---|---|
| 0x4217B0 | Car_IsJeep | V | carModel==30 |
| 0x4217C0 | Car_IsApc | V | ==3 |
| 0x4217D0 | Car_IsGt24640 | V | ==19 |
| 0x4217E0 | Car_IsTvVan | V | ==67 |
| 0x421810 | Car_SetRoofDecalDelta | H | CarDeltas_SetBit(0xf), from CarManager_SpawnCar |
| 0x421870 | Car_GetDriverPlayer | V | driver+0x15c |
| 0x421950 | Car_SetShopReaction | V | Car+0xb4 |
| 0x4219A0 | Player_IsWeaponAmmoFull | V | this+0x718+idx*4 -> Weapon_IsAmmoFull |
| 0x4219F0 | Hud_CarName_Hide | V | *p=0; from Car_OnDriverLeft |
| 0x421C00 | Car_GetMaxSpeed | V | engine.max_speed * Car_GetDamageFactorOnSpeed |
| 0x421C40 | Car_GetHitchWorldPos | V | const (trailer/car) rotated + body pos; caller trailer search |
| 0x421CB0 | Car_GetRearWheelOffsetVec | V | Vec2(0, physData+8) |
| 0x421DF0 | Car_IsOnSurface6 | V | physics+0x98 (surfaceType)==6 |
| 0x421E00 | Car_GetVelocityAngle | V | angle of physics+0x40 else body rotation |
| 0x421E70 | Car_GetVelocity | V | physics+0x40/44; train uses actor |
| 0x421EC0 | Car_GetFrameDisplacementLength | V | length of velocity, 0 w/o physics |
| 0x421EF0 | Car_GetMinHalfExtent | V | g_Fix16Div64Table[min(w,h)] |
| 0x421F40 | Car_NeedsRemapChange | V | num_remaps>1 && spriteId!=remap |
| 0x421F80 | Car_NeedsRemapChangeWithTrailer | V |  |
| 0x421FD0 | Car_ApplyRemap | V | Sprite_SetRemap on car+trailer |
| 0x422260 | Car_UnlinkFromWorld | V | RemoveSprite x2, CarPool_UnlinkUsed, SetDetached |
| 0x4222D0 | Car_ResumeAICruise | V | ai+0x18=DAT_5e4dc4; Car_ResumeAI; 12 callers |
| 0x4224A0 | unsure_Car_IsDoorOffCentre | H |  |
| 0x422500 | Car_GetDoorWorldPos | V |  |
| 0x422980 | Car_SirenRearLightsOffA | V | called by Car_SirenOff; bits 0x12/0x11, obj 0xac/0xad |
| 0x422A40 | Car_SirenRearLightsOffB | V | called by Car_SirenOff; bits 0x12/0x11, obj 0xac/0xad |
| 0x422AA0 | Car_SirenLightsOnA | V | bit 0x10, obj 0xa5 (+0xac swat/fire) |
| 0x422B70 | Car_SirenLightsOffA | V | bit 0x10, obj 0xa5 (+0xac swat/fire) |
| 0x422BD0 | Car_SirenLightsOnB | V | bit 0xf, obj 0xab (+0xad) |
| 0x422CB0 | Car_SirenLightsOffB | V | bit 0xf, obj 0xab (+0xad) |
| 0x422E00 | Car_SetNumberGraphic | V | clear bits 0xb..0x14, set 0xb+idx |
| 0x4230D0 | Car_IsDamagePosBroken | V | idx 0..4 -> bits 2,3,1,0,4 |
| 0x4232E0 | Car_ZeroVelocity | V | linVel=zero, angVel=0 |
| 0x423310 | Car_IsFrameWidthChanged | H |  |
| 0x4233B0 | Car_ShrinkFrameBounds | H |  |
| 0x423480 | Car_GetEffectiveDriver | V | trailer -> cab driver |
| 0x423590 | Car_ShowCarNameForLocalPlayer | V | Hud_CarName_Show |
| 0x423630 | Car_StepTurretToward | V | attach 0x72/0x94/0xf8 |
| 0x4237B0 | Car_InitAIWithRouteTarget | V | AllocAI+SetParentCar+SetRouteTarget(x,y,z,flag); identical copies |
| 0x4237F0 | Car_InitAIWithRouteTargetB | V | AllocAI+SetParentCar+SetRouteTarget(x,y,z,flag); identical copies |
| 0x423850 | Car_UpdateBrakeLightsFromFootBrake | V |  |
| 0x423A70 | Car_AreAllDoorsSettled | V | all 4 doors state 0 or 6 |
| 0x423B50 | Car_UpdateForHireLight | V | engine on && no passenger |
| 0x423C30 | Car_UpdatePopupLightsAnim | V | every 3rd frame shifts bits 0xb..0xe, 0x1c..0x1f |
| 0x424360 | Car_UpdateAttachmentLightByLid | V |  |
| 0x4243C0 | Car_GetSpriteLayerForState | V | 0xe / 0x14 / 0x11,0x16 |
| 0x424E30 | Car_CanPedEnter | V |  |
| 0x424F80 | Car_IsEnterCandidateForSearchPed | H |  |
| 0x424FF0 | Car_TryPlaceOnRoadColumn | V | scans up to 200 tiles for arrow block, teleports car if unseen |
| 0x4253C0 | CarAIPool_ScalarDeletingDtor | V | called from CarManager_FreePools |
| 0x4253E0 | TrailerControllerPool_ScalarDeletingDtor | V | called from CarManager_FreePools |
| 0x425400 | CarPool_Dtor | V | 306 x 0xbc / 306 x 0xb0 |
| 0x425430 | CarPhysicsPool_Dtor | V | 306 x 0xbc / 306 x 0xb0 |
| 0x425450 | PedQueue_Ctor | V | ResetIntPtr |
| 0x4254F0 | CarAIPool_PushFree | V | item+0xc=head; head=item |
| 0x425650 | Car_ClearLightDeltaBits | V |  |
| 0x425780 | Car_HasFlag1000 | V |  |
| 0x425790 | Car_GetModelInertia | V |  |
| 0x4257B0 | Car_CanBeResprayed | V | "nespray" brief otherwise |
| 0x425A40 | Car_IsDoorExitClear | V |  |
| 0x425B60 | Car_IsPavementBesideDoor | V |  |
| 0x425D60 | Car_IsBlastImmune | H |  |
| 0x4268C0 | Car_TryPlaceOnArrowTileAt | V | wrapper; caller CarAI_UpdateDriveOrder |
| 0x426D70 | CarPool_ScalarDeletingDtor | V |  |
| 0x426D90 | CarPhysicsPool_ScalarDeletingDtor | V |  |
| 0x426EE0 | Car_RepairWithTrailer | V |  |
| 0x427B20 | Car_DetachTrailerAndBlockReattach | V |  |
| 0x427CA0 | Car_TryRespray | V |  |
| 0x4295C0 | Car_ArmOrDetonateBomb | V | spawn CAR_BOMB or TriggerExplosion(0x14) |
| 0x429800 | Car_DropTrailerIfAny | V |  |
| 0x429FC0 | Car_UpdateSystemsAndWreckTimer | V |  |
| 0x429FF0 | Car_FollowParentSpritePose | V |  |
| 0x42A500 | CarManager_ResetJunctionReserveCooldown | V | DAT_5e5090=0 (ReserveJunction counter) |
| 0x42A5B0 | CarAI_HonkIfAllowed (was Car_StartHonkIfAllowed) | V | arg is the CarAI ([ecx] = parentCar); if Car_IsPoliceModel(0x41F6E0): Car.hornState(+0xa7)=0x2d |
| 0x42A5D0 | CarAI_IsExitDirRightTurn | V | (travelDir,turnExitDir) = (1,3)(2,4)(3,2)(4,1); heading class 1 N, 2 S, 3 E, 4 W (H1) |
| 0x42A620 | Fix16_AssignFromChar | V | *this = c<<14 |
| 0x42A630 | Fix16_Frac | V | *y & 0x3fff |
| 0x42A660 | HeadingClass_Opposite | V | 1<->2, 3<->4, else 0 |
| 0x42A6B0 | Fix16_ChebyshevDist | V | max(abs(bx-ax),abs(by-ay)); 57 xrefs |
| 0x42A720 | Vec2_ToLocalFrame | V | rotates (p-o) by Ang16 |
| 0x42A830 | MapBlocks_GetColumnEntryPtr | V | this+(y*256+x)*4 |
| 0x42A850 | MapBlocksRef_GetBlock | V | column entry -> block by z |
| 0x42A9B0 | CarAI_RaiseCurSpeed | V | if cur(+0x14)<v then cur=v |
| 0x42A9E0 | CarAI_Ctor | V | zeroes CarAI, routeSlot=-1, flags=(flags&0xFFC12010)\ |
| 0x42AAC0 | CarAI_Reinit | V | same without Ang16 ctor |
| 0x42ABE0 | CarPhysics_SetReverseGasOnly | V | writes +0x91/93/94/95 |
| 0x42FE80 | CarAI_UpdateSpeedRamp | V | cur->goal by step(+0x1c), then ReleaseControls; caller CarAI_FollowRoad (rail) |

### Names added by Seq 47 (slice 1): drive-order pool helpers, taxi list

All "HasAlliedManeuver…" scan the 20-entry `CarDriveOrderPool` for an in-use order whose driver (+4) is allied (`Ped_AreAllied`) with the given ped and whose maneuver (+0xC) is in the set; only caller `CarDriveOrder_Drive` (maneuver meanings still open).

| Address | Name | Conf | Evidence |
|---|---|---|---|
| 0x433120 | TaxiList_PopFront | V | `*head = head->next(+4)`; caller TaxiList_Add |
| 0x433130 | TaxiList_PushFront | V | `node->next = *head; *head = node`; caller TaxiList_Clear |
| 0x4462E0 | CarDriveOrderPool_DtorBody | V | eh vector dtor 20 x 0x40; caller CarDriveOrderPool_Dtor |
| 0x446340 | CarDriveOrderPool_FindAlliedDriverByManeuverTargetingPed | V | targetPed(+0x30)==ped, allied, maneuver==arg → driver |
| 0x4463C0 | CarDriveOrderPool_CountAlliedDriversTargetingPed | V | counts orders with targetPed==arg1, driver allied with arg2 |
| 0x446410 | CarDriveOrderPool_HasAlliedManeuver0D0F | V | maneuver 0xD/0xF |
| 0x446480 | CarDriveOrderPool_HasAlliedManeuver08 | V | maneuver 8 |
| 0x4464E0 | CarDriveOrderPool_HasAlliedManeuver060810 | V | maneuver 6/8/0xA |
| 0x446550 | CarDriveOrderPool_HasAlliedManeuver09 | V | maneuver 9 |
| 0x4465B0 | CarDriveOrderPool_HasAlliedManeuver07090B | V | maneuver 7/9/0xB |
| 0x446620 | CarDriveOrderPool_HasAlliedManeuver06To09Or0D | V | maneuver 6..9 or 0xD |
| 0x446690 | CarDriveOrderPool_HasAlliedManeuver04To05 | V | maneuver 4..5 |
| 0x446AA0 | CollisionResult_IsHitObjectWallResponse3 (was unsure_CollisionHit_IsObjectPrefabSolidVsCar3) | V | hit kind==3 and prefab wallResponse (+0x4C) == 3; caller CarPhysics_StepAndResolveCollisions (raises the iteration cap) |
