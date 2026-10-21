> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Shared city and lab vehicle pipeline

All vehicles created by createWorld now receive a source handling profile. The old
constant-acceleration path has been removed. Maps supply placements, road axes and wall
geometry; advanceHandling, moveAgainstWalls, pair contacts, damage/fire, skids, audio
and sprite rendering are shared. A paired city/lab test runs equivalent inputs and
checks identical handling, heading and speed plus translated positions.

The ten currently spawned models are0,1,2,5,8,10,12,13,14,16. Generated profiles combine
NYC.GCI forces/gears/antiStrength with wil CARI body/wheel dimensions. Regenerate with
`bun games/gta2/tools/import-handling.ts`. This covers all16 currently parked city cars, not
all83 vehicle types or future traffic. The original source parameters do not establish
perfect physical fidelity of our approximate solver.

Original GMP wall segments are converted locally to oriented wall geometry at the
vehicle elevation. They go through the same swept contact/impulse/damage solver as
lab walls. Ground/void support checks remain map geometry queries. The previous city
path merely rejected movement, giving no wall damage or rebound. Copying primitive
burning state out of swept poses is necessary just like damage/damageMask; otherwise
wall damage can reach the ignition threshold without starting fire.

Audio source: gta2_re51d2ce3d sound_obj::samp_idx_for_model417AC0,
GetVehicleAudioClass417BA0 and ConvertToPlayBackRate417C60, with numeric IDs from
enums.hpp. All current models have rev and horn mappings; bank loading derives IDs
from the profile table. Envelopes remain provisional; the player doubts damage sample1.

Car colour exports now contain4092 dent/remap variants per district, covering these
same ten models. Browser verification checks each model's actual rendered damage mask,
engine voice and horn. Original PNG readback tests cover all exported pixels.

Intentional old-scenario changes: legacy acceleration7m/s at tick60 is now source
handling12.271301839239266 in procedural Downtown (Aniston BD4) and11.463375184523786
in Driving lab (Romero). The brake-to-rest budget grows from60 to240 ticks, ending
at tick300. Source car dimensions make the five-car vault end one tick later at211,
y=-12.616666666666674 instead of210/-12.5. These are real behavioral changes from
removing the legacy path, not bookkeeping hash changes. Existing original-Downtown
scenario expectations remain unchanged. No golden hashes were replaced.

Verification:165 GTA tests, typecheck; browser-downtown.ts menu/keyboard/handbrake/save,
browser-city-integration.ts all ten models and city fire/death/save. No NPC traffic,
blast-area/chain damage or correct final fire artwork is implied. Start a new city
session: saves created with legacy vehicles lack their new handling state.
