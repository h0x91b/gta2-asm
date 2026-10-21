> **Ported** from the user's my-games project (`rts-dots2/games/gta2`, `bf84820c`,
> `docs/reference/gta2/`), written for a browser reimplementation. Sentences about "our",
> the importer, the sim, labs or runtime describe that project, not `gta2.exe`; paths under
> `games/gta2/` are in that repo. Original-game evidence is the DMA format documents
> (`formats/…`, see [../../reference.md](../../reference.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Collision damage, money and exploding figures

Evidence pinned to CriminalRETeam/gta2_re revision
51d2ce3d4b8d32b6d48ff5c938cc98521061691b, Source/:

- CarPhysics_B0::HandleCarCollision_55FF20 and ApplyImpactForcesAndDamage_55FA60
  use impulse magnitude, then Car_BC::ApplyImpactDamage_43D5D0 multiplies by200.
- AccumulateDamage_43DA90 applies model antiStrength and accumulates integer damage
  to32000. Romero/Wellard both have antiStrength1. Our pair impulse remains approximate.
- Collision call sites gate scoring above200 new damage. eager_benz::sub_593030
  selects1 below300,10 below400,otherwise100, multiplied by player bonus multiplier.
- WIP source attribution has ambiguous own/other-car call arguments. Our policy follows
  the player's explicit requirement: award only new damage to the OTHER vehicle in
  a player-occupied pair. Wall contact awards nothing. NPC-only pairs award nothing.
- New supplied GTA2_ECONOMY_RU.md supersedes remembered flat$10 and $50 pedestrian values.
  It is a user-supplied research synthesis, not independently verified in full.

Source URLs: https://github.com/CriminalRETeam/gta2_re/tree/51d2ce3d4b8d32b6d48ff5c938cc98521061691b/Source

Visual reference downloaded from https://www.game-over.net/review/nov99/gta2/Screen3.JPG
(local screenshots/GameOver-Score100.jpg): blue100 above a vehicle impact;
yellow cash with dollar prefix, hearts and multiplier at top right.
ExplodingScore_50::DrawSingleNumber_597100 selects sprite type6 (user), index163+digit.
These are wil atlas1356..1365, confirmed by inspecting extracted pixels.
PoolUpdate starts counter2, then expands/disperses digits and reduces intensity25 by2.
We reproduce the fixed33ms phases in60Hz ticks and use the base extracted palette;
colour remaps and exact alpha semantics remain provisional. Static screenshots do not
prove cadence. Browser sequence72/78/86/104 verifies our animation and final removal.

Current scope: pair damage and score, saved bonus multiplier (default1),16 recent
reward records with dropped counter, original digit sprites, basic cash/health HUD.
No bullet damage, destruction, fire, deformation, damage speed penalty, model-dependent
hijack payouts, mission multiplier changes, combo or shop services yet. Wall damage
is not yet accumulated, although wall contacts correctly award no cash.
