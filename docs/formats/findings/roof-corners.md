> **Ported** from an earlier browser reimplementation of GTA2 (not published). Sentences
> about "our", the importer, the sim, labs or runtime describe that project, not `gta2.exe`;
> paths under `games/gta2/` are in that project, not in this repository. Original-game evidence is the DMA format documents
> (`formats/…` = [../specs/](../specs/README.md)) and CriminalRETeam/gta2_re
> rev `51d2ce3d`. **gta2_re address suffixes (`_43DA90` etc.) are NOT 11.44 addresses**:
> most land mid-function in our binary (checked byte-wise, see [../loader-map.md](../loader-map.md)).
> Treat them as names to search for, not VAs.

# Diagonal roof corners

Reported by player with upgrade-shop screenshots, 2026-09-05. Reproduced on wil shops at block corners (40,135,3), (50,135,3), (40,137,3), (50,137,3): slopes49–52, side tile626, lid1023. All four were rendered as detached vertical quads with the inclined roof missing.

Primary evidence: archived `formats/GTA2 Map Format.txt`, diagonal slopes section; pinned CriminalRETeam/gta2_re51d2ce3d4b8d32b6d48ff5c938cc98521061691b `Source/MapRenderer.cpp`, DrawTriangularDiagonal_4F0340 and Draw3SidedDiagonal*/Draw4SidedDiagonal*. Lid1023 is a geometry discriminator: three-sided pointed roof with triangular base, not an image to draw. Normal/zero lids select the inverse corner: triangular lid, inverted sloping triangle to the low corner and two full sides; omit the two small lower side triangles. Side textures use explicit triangle UVs: pointed (.5,0),(1,1),(0,1); inverse (0,0),(.5,1),(1,0). No slope-side transforms; lid transforms retained.

The old shape cache depended only on slope and defaulted49–52 to cube approximations. It now considers the lid marker. Shared shape interface carries optional per-vertex UVs for these triangular faces. All eight variants are in the shape inspector. Reserved62 remains explicitly unsupported. This fixes shape rendering across maps, not garage gameplay. Ground support for diagonals is still excluded by the existing terrain policy.

Regression `bun test games/gta2/tests/roof-corners.test.ts` failed before fix with6vertices instead of3. Now tests projected triangle area, peak heights, lid discriminator, UVs and original garage block records. The generic unsupported-shape test now uses reserved62 instead of49 because49 is implemented; its original reporting claim remains intact.133 GTA-tests/typecheck pass. Browser captures identical inspector camera before/after and actual game; all four shop corners join correctly, Downtown approximation count474→0 (not proof of all map features being complete).

Player confirmed these buildings are service garages: entering triggers paint/weapon/other upgrades. Those interactions belong to the existing full-game goal and are not implemented by this geometry repair.

## Player garage behavior clarification

Driving through Max Paynt repairs the car, chooses a different random allowed paint colour and clears the pursuit. Player recalls a price around1000, unconfirmed. Hell Oil equips an oil-slick weapon: Ctrl spills oil and other cars lose grip on it. Smith & Heston’s equips vehicle machine guns operated with Ctrl, with no visible separate barrels according to the player. Red Army Surplus may equip a timer bomb; player explicitly unsure. Verify these costs and bomb semantics against source/manual before implementation.
