> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…`, see [../../reference.md](../../reference.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Taxi fleet resource integration

Original NYC.GCI model51 is Taxi Xpress; model56 is Taxi. Wil CARI maps these to sprite45 and sprite50 (model IDs are not sprite IDs). Both have four doors and no remap list: use native painted artwork, not a random tint. Dimensions and axle positions come from CARI; all handling coefficients come from GCI through the existing importer and shared source-clock integrator.

Audio source: CriminalRETeam/gta2_re revision51d2ce3d4b8d32b6d48ff5c938cc98521061691b, Source/sound_obj.cpp and Source/enums.hpp. STYPECAB=51 uses samp_idx_for_model_417AC0 case4; TAXI=56 uses default3. GetVehicleAudioClass_417BA0 returns default horn16 for both. ConvertToPlayBackRate_417C60 gives default22050Hz for51 and19000Hz for56. These are source assignments; continuous engine rate/gain still use the existing provisional envelope validated by the player.

Supported models are separate from PARKED_MODELS. Adding a taxi to the parked selection would alter existing fixture geometry and vehicle identities. The shared spawn command and population now use SUPPORTED_MODELS, while the ten-model Turning traffic map explicitly retains its original selection. Taxi fleet is the two-model physical loop/keyboard/audio demo. Both source-road corner tests include taxis.

All31 nonzero damage masks per taxi are exported alongside the native base palette:62 additional combinations per district,4154 total. Runtime uses the same atlas/vehicle appearance path and original wreck mapping.

Passenger pickup, boarding, fares, occupied roof lamps and drop-off are not implemented in this step. CARI passenger count5 is preserved in assets but has not yet established whether the driver is included. Bus door flags need separate decoding. Do not infer those mechanics from the presence of these resources.
