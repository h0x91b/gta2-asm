> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…`, see [../../reference.md](../../reference.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Vehicle fire — provisional implementation

Player: damaged-engine crackle precedes/announces the small flame; small fire slowly
consumes the car, large fire consumes it quickly, then explosion. Exit before the blast.

Pinned gta2_re51d2ce3d source findings:
- Car_BC::AccumulateDamage43DA90:16000=>SpawnDamageFireEffect(1),25000=>effect2,
  31500=>PrepareForExplosion,32000=>HandleCarExplosion(19).
- SpawnDamageFireEffect43B870 uses rear/front window offsets from CARI and attaches
  the explosion object to the car sprite at the hit/local position.
- sub43BB90 maps effect1=>Wolfy state12; effect2=>13; effect3=>14 (apparently unused).
- Object_5C::CreateExplosion52A3D0 creates object113. Fire emitters use timer9999
  (persistent marker); explosion states18/19/20 etc get100. Do not interpret9999 as
  a fire lifetime or100 as the delay until a burning car explodes.
- Wolfy state3/12 emits Particle state3, code-object sprite base+96, counter32.
  Particle UpdateDirectedBurstSweep539040 is STUB at this revision. Small-flame
  animation/propagation and exact self-damage rate are not established.
- Wolfy state13/14 emits Particle state36 from base. UpdateShortAnim53B580 advances
  once then adds4 to sprite index on subsequent updates until state5 terminates.
- Phi8CA8 field8CA4 comes from object-definition112 sprite; constructor default99
  is not the shipped base. Phi.cpp hardcoded Phi_6C counts before row112 sum to305; this is not STY OBJI. wil codeObject category starts551, giving global base856.
- sound_obj::HandleCarDamageSound4177D0 selects sample1 when engine on and damage>16000;
  volume grows with(damage-16000)/16000. wil1 is22050Hz,8325frames, loop whole clip.
  Gain0.3 in our mixer is provisional. Source handler is WIP; player listening remains
  useful. Current implementation only plays this while player drives, not nearby empty cars.

Implemented: explicit burning state, small/large progression, saved integer burn remainder,
explosion tick, stopped wreck and occupant death. Player calibration: small stage150 seconds
(9000 ticks, 1 damage/tick); large30 seconds (1800 ticks, 35/9 damage/tick carried exactly).
Once ignited, a car continues burning without further collisions. Additional damage hastens it.
The damaged-engines comparison fixture deliberately has damage but no active burning.

Provisional artwork: wil.sty global IDs952..958 small,864..870 large,912..928 provisional burst.
Code-object-relative IDs401..407,313..319,361..380 respectively. Flame cadence halved
on player request: floor(tick*25/99). Player says these flames and damaged-engine sound1
look/sound wrong; do not call their identity or sequence confirmed. Original pixels alone
are not proof of a correct animation. No hospital respawn yet.

Player retracted identification of929..934 as car fire: these may be flamethrower jet
frames. No renderer change was applied from that identification. Catalogue links accept
?style=wil&sprite=952 and select the matching category automatically.

Player subsequently identified the full global range wil929..944 as flamethrower jet (sound wil316). Exclude it from car-fire selection.

Removed929..931 from the end of the provisional explosion animation after the player identified them as flamethrower. The remaining912..928 burst still needs visual confirmation.

## Original wreck artwork

TurnToWreck4436A0 selects CARI[original.wreck+72].sprite, switches to the base sprite
palette and clears damage overlays. The exporter preserves this mapping in car-colors.json.
Romero uses model74/sprite67; Wellard model75/sprite68; Panto model78/sprite71.
HandleCarExplosion calls sub441380, which starts fieldA9_timer at50; CountDownToWreck
then calls TurnToWreck at zero. Our rendering waits99 host ticks (50*33ms=1650ms),
using the existing explodedAt state. This changes artwork, not the already stopped
wreck physics. Source SpawnFire after conversion is still not reproduced.

Live cars and wrecks now use their own sprite width/16 and height/16 metre dimensions;
previously all artwork was normalized to one4m length. This was especially wrong for
compact cars. The city browser checks actual reported mesh dimensions against source
sprite metadata for every current model. Both city and fire-lab browser checks inspect
original wreck pixels, unpainted palette and absent ordinary dent overlays.

## Explosion sound

wil188 (22050Hz,57312 PCM frames) is connected as a one-shot. Named reference
SFX_LRG_EXPLOSION OGG decodes to57311 frames, Pearson correlation0.998024115 with
our PCM at zero lag. Provenance/measurement: explosion-audio-match.json. This is an
inference from named audio, not an implemented gta2_re call-site (object sound
processing is STUB at the pinned revision).

The shared audio observer emits up to4 nearest active explosions within64 metres,
with provisional inverse-square-like gain, no occlusion or stereo placement yet.
Integer frame/tick comparison determines expiry; saved explodedAt determines seek
position. Loading a new world releases mixer voices, allowing a restored explosion
to play even when the prior world used the same event key and had already finished.
Frozen frames retain completed voice markers to prevent repeated playback.
Browser test covers real output RMS, on-foot/city/dead occupant, pause, clip completion
without repeated playback, restoring the same event and expiry.168 GTA tests/typecheck.

## Area damage and chains

Shared blast.ts now applies each new explosion once, using source antiStrength through
the same integer damage accumulator as impacts. Provisional calibration: radius8m,
linear falloff from32000 vehicle damage /100 pedestrian HP. Vehicle distance is to
its oriented body edge. Ground levels separated by1.7m or more do not interact.
Occupants receive damage through their car and die if it explodes; on-foot players
receive direct damage, with jump height included in distance.

Fire updates gather newly exploded cars first, then apply all their damage. Newly
lethal targets therefore explode on the next tick, avoiding array-order chain timing.
explodedAt already serializes the event, so no replay-only history field is added.
The shared blast-chain.json scenario checks three sequential explosions at0/1/2 and
save continuation through the first link. The far car/player remain safe. Browser
checks the same chain in the original city with nearby source vehicles.

The old fire escape scenario now runs away for120 ticks after exiting; simply standing
beside the car would correctly be hurt. Remaining: verified original radius/falloff,
wall occlusion, blast impulse/knockback, NPC targets and player-attributed blast rewards.
Do not describe the provisional radius as an original-executable measurement.
