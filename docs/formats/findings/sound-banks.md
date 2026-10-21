> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…`, see [../../reference.md](../../reference.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Latest listening correction: ignition

The player identified wil1 and wil2 as ignition on entering a car. The former provisional loop of wil1 on damaged cars is removed. Entry now emits one shot after18ticks; odd models choose1 and even models2, matching the assignment in source418610 (whose label is misleading). Source22050Hz lengths8325/11020frames are respected; frozen ticks cannot restart a completed clip. No replacement damaged-engine sample is claimed.

# SDT / RAW sound banks

The importer exports the four supplied banks to `games/gta2/assets/audio/banks/{wil,ste,bil,fstyle}/`: numbered WAV files and `index.json`. District banks contain 320 entries each and the frontend contains 18, for 978 entries total. These are source entries, not unique recordings. Both members of each pair retain SHA-256 provenance in the manifest/index. No original file is changed.

## Encoding evidence

SDT entries are six little-endian 32-bit fields: byte offset, byte length, sample rate, sample-rate variation, loop start and loop end. The loops are byte offsets; -1 is the end sentinel. The WAV contains the original PCM payload without resampling or rate variation. Loop metadata is retained in JSON rather than silently converting every clip into an infinite loop.

Primary implementation references inspected 2026-09-05:

- [OpenGTA2 SoundEntry](https://github.com/ikkentim/opengta2/blob/main/src/OpenGta2.GameData/Audio/SoundEntry.cs) records the six fields, including variation. Its SoundLibrary confirms the ordinary mono PCM16 WAV layout but does not handle the separate U8 radio range.
- [GTA2 reconstruction cSampleManager, pinned revision](https://github.com/CriminalRETeam/gta2_re/blob/51d2ce3d4b8d32b6d48ff5c938cc98521061691b/Source/cSampleManager.cpp): ordinary channels use signed 16-bit mono; the separate radio handle is initialized by AllocSample_58DA80 as unsigned 8-bit mono, and PlayAtIdx_58E7F0 uses the SDT byte range/rate.
- [GTA2 reconstruction sound_obj, same revision](https://github.com/CriminalRETeam/gta2_re/blob/51d2ce3d4b8d32b6d48ff5c938cc98521061691b/Source/sound_obj.cpp): EnqueueRadioWord_4271B0 clamps IDs to 69–136, and ProcessPoliceRadioWordsPlayback_427220 sends that queue to the separate handle. Some reverse-engineered functions are marked WIP; this is independent reconstruction evidence, not an official released engine specification.

The supplied bytes independently support the distinction: district IDs 69–136 begin around U8 silence 0x80, include odd byte lengths, and ID 136 consists of ten 0x80 bytes. Decoding that record as PCM16 produces a large negative signal; U8 produces silence. There are 204 U8 entries across the three districts and 774 PCM16 entries across all banks.

Bit depth is selected by the known bank/profile and source ID, not by sample rate, oddness or waveform heuristics. Even-length radio samples are still U8; ordinary samples at low rates remain PCM16. Unknown bank profiles are refused by the importer. GTA1's 12-byte SDT record is a different format and must not be used here.

## Inspection

Open `/gta-sounds`, also linked from the game's main menu and the resource catalogue. The service page has bank selection, ID/category search, numbered sample list, waveform, duration/amplitude statistics, PCM/source metadata, download, native playback/seeking, speed and whole-clip repeat. Normal speed uses the original rate. Unknown effect names remain unclassified; identifying a sample's purpose is separate work.

`window.gtaSound` exposes `load(bank)`, `select(id)`, `play()`, `pause()`, `stop()`, `seek(seconds)`, `setRate(rate)`, `setLoop(boolean)`, `setVolume(volume)` and detached `state()` for agents. Native playback may require a user gesture. Waveform decoding can resample to the browser AudioContext rate; source frame count and rate remain explicit in metadata. Whole-clip repeat deliberately does not apply the original loop segment.

## Checks

`games/gta2/tests/sound.test.ts` tests truncated entries, RAW bounds, invalid rates/alignment/loops, field endianness, U8 ID boundaries and RIFF padding. Optional source integration reads every exported WAV back and compares its PCM bytes and rate/bit depth against all 978 source records. RIFF's alignment byte for an odd-sized U8 clip is excluded from the data length.

`games/gta2/tools/browser-sounds.ts` verifies menu reachability and 640×480 link bounds, waveform data, source-loop display, playback via a real button in every bank, U8 playback and zero-amplitude radio silence, rate retention, invalid-ID rejection, mobile width and absence of console/page errors. Playback-clock checks prove browser playback proceeds; they do not substitute for listening to identify the sound's gameplay meaning.

Vehicle audio is now connected on the two source-handling test models (see below). Ordinary city vehicles, horns, weapons, ambience, radio and mission sound remain pending.

## Vehicle event mapping investigation, 2026-09-05

The player reports the lack of engines and tyre squeal as a major fidelity gap. Manual labelling of all 978 entries is unnecessary: the pinned `sound_obj.cpp` names event handlers and assigns sample IDs. Assignments observed in that reconstruction (function names can be misleading; see listening correction below):

| Event / function | Sample IDs | Caveat |
| --- | --- | --- |
| Type_10_HandleCarSkidSound_418940 | 22 | Rate depends on surface; amplitude depends on lateral force and locked wheels. WIP function. |
| Type_3_HandleCarImpactSound_4174C0 | 12 / 13 | Selection code itself has unresolved decompiler comments; do not copy uncertain branches blindly. |
| Type_5_InitEngineSoundProfile_415730 → GetVehicleAudioClass_417BA0 | 16 default, 18 allard/sport group, 19 heavy, 17 small, 23 icecream, 20 train | **Do not loop as idle engines.** Despite the reconstructed name, player listening identified the added layer as a horn. 16/18 were removed; other IDs need contextual verification. |
| Type_1_6_416260 | samp_idx_for_model_417AC0 / 9 / 21 | Separate player rev/engine layer; not one universal engine loop. |

The implemented plan is `games/gta2/src/audio/vehicle-plan.ts`: Romero uses 3, Wellard uses 6, skid uses 22. The Web Audio mixer is presentation-only, follows SDT byte loop offsets and source sample rate, and maps gas/gears/slip to provisional rate/gain envelopes. It releases voices on pause/menu/mute and disposes resources on pagehide. It currently loads only three wil samples and covers the two handling models.


Player listening correction and acceptance: the first implementation also looped 16/18 as an idle layer, trusting the reconstruction's function name. The player heard a horn alongside the engine. Removing that layer corrected it; the player then confirmed the engine, squeal/braking and handbrake sounded right. This is evidence for these selected sounds/feel, not all sound mappings or exact original pitch envelopes. Never promote a reverse-engineered function name into an established sound identity without call-context or listening evidence.

Options now has vehicle sound volume, persisted with other settings. `gta.audioState()` exposes context/readiness, active sample IDs, gains/rates and measured output RMS; `gta.unlockAudio()` is the same browser-gesture activation path. API/scenario state and rendering do not depend on audio. Browser tests verify nonzero output, pitch change, skid sample, identical plan after load, mute/pause silence, model switching and menu cleanup. Headless tests prove mappings, loop conversion and observer purity. Player animation separately changed from 3 to 6 ticks/frame per player request, leaving movement speed unchanged.

## Explicit horn control

The player requested Tab (original key) or H. Both are now mapped during gameplay to `horn {ticks:0..600}`: nonzero sets a bounded horn budget, zero releases it. Held keys renew the budget; key release stops only the horn, preserving movement input. The sound is sample16 for Romero, sample18 for Wellard, using the same previously identified horn layer **only on an explicit command**. Other city cars temporarily use the default horn until their audio classes are mapped. Horn state is serializable and tick-based, and exiting the car cancels it.

The horn has no NPC reaction yet. Pedestrian novelty voice actions (burp/fart etc.) are recorded from the player's description but not implemented: the researched generic ped voice handlers did not establish those exact IDs. In particular, ProcessPed's 233–238 branch follows field_B0, whose initializer is labelled a screaming timer; it must not be relabelled as novelty sounds without better evidence.

### Player listening confirmation — 2026-09-05

The player listened to wil 233–238 and identified all six as male screams. wil 239 is the taxi call “cab free” (player transcription). These are not confirmed burp/fart samples; those remain unidentified. Do not extend this classification to all IDs below 238 or to other banks without checking.

Player identification in wil: 309 burp; 310 fart (the pedestrian horn); 311 pistol; 312 possibly automatic weapon or pistol (uncertain); 313 silenced automatic weapon; 314 shotgun; 316 flamethrower; 318 electroshock weapon. These are listening labels, not yet runtime event bindings.

Player identification in wil: 299–308 are random pedestrian voices. Exact phrases and triggering conditions remain unclassified.

### Pedestrian horn connected — 2026-09-05

Tab/H on foot invokes named `vocalize` once per keydown. Default alternates burp/fart (provisional choice; original selection logic still needs source confirmation). Explicit `vocalize {sound:"burp"|"fart"}` is available to scenarios. Identified wil 309/310 play once at 19000 Hz with no looping; source durations 4195/19000 and 5519/19000 seconds reserve 14 and 18 simulation ticks respectively (ceiling). Key release does not truncate the clip; active clips reject overlapping renewals. Cars retain held horn behavior. Mixer has one pedestrian voice or up to three vehicle voices, respects volume/menu/pause, and records completed audio nodes so frozen simulation ticks cannot restart a completed sample every frame. These sounds work on all maps, including original Downtown.

Verified: 121 GTA tests, typecheck, `games/gta2/tools/browser-vocal.ts` (real Tab/H, nonzero RMS for both IDs, no replay when ticks are frozen, pause, car horn), plus existing vehicle-audio browser regression for motors/skid/mute/model changes.
