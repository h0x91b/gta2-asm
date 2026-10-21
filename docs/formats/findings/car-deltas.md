> **Ported** from an earlier browser reimplementation of GTA2 (not published). Sentences
> about "our", the importer, the sim, labs or runtime describe that project, not `gta2.exe`;
> paths under `games/gta2/` are in that project, not in this repository. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Original car damage sprites

DMA GTA2 Style Format v4.6, Deltas and Car Delta Usage (archived formats/GTA2 Style Format.txt):
DELX entry is u16 sprite, u8 count, pad, count*u16 lengths. DELS concatenates all streams.
Each stream repeats u16 relative offset, u8 run length, indexed pixels. Cursor advances
through the written run before the next offset. Page stride is256, not sprite width.
Index0 may erase base pixels; alpha overlays alone cannot reproduce a dent.

Damage bits0..4: rear right, rear left, front left, front right, windscreen.
Mirror bits22..31 and door/light animation are not implemented by the new compositor.
Only first five actual stored deltas are composed for this layer.

Importer keeps668 clean car/palette variants and adds1054 combinations for Romero/Wellard
per district:31 nonempty masks times34 base/remapped appearances. Runtime uses extracted
PNG/JSON; no binary STY decoding in the browser. Rebuild all via gta:import or only car
atlases via bun games/gta2/tools/import-car-damage.ts. All three district atlases rebuilt.

Pair impact magnitude>=1 selects a local contact quadrant and permanently ORs its bit.
This selection is a provisional mapping onto source deltas, not a complete port of the
original contact-area classifier. A central tie chooses right with1e-8 tolerance to avoid
sin(pi) noise choosing a different half. Source TryDamageArea compares antiStrength*impact
against1. Both current profiles have antiStrength1. Glass is inspectable, not yet emitted
by a gameplay event. Wall dents, broken lights, moving doors and other models remain.

The Body damage demo displays clean/four corners/glass/all for both models. Car impacts
and its shared scenario produce real dents. Save/restore retains masks. Tests verify
run boundaries, untouched pixels, all exported damage-atlas rows against decoded sprites,
quadrants and continuation. Agent Browser checks rendered mask identities and screenshots.
