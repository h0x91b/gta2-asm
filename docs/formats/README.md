# GTA2 file formats — notes

What the game's data files look like on disk, the traps in reading them, and (in
[loader-map.md](loader-map.md)) which `gta2.exe` functions read them into which structures.
The decoders that embody these layouts are in [`tools/formats/`](../../tools/formats/README.md).
DMA's own specs (format + scripting, with example missions): [specs/](specs/README.md).

| File | What |
|---|---|
| [lessons.md](lessons.md) | Format traps, verified against the shipped files. Start here. |
| [loader-map.md](loader-map.md) | Format/chunk → reader function → in-memory struct, each verified or hypothesis. |
| [findings/](findings/) | Topic notes ported from the user's my-games project. |
| [GTA2_REFERENCE_RU.md](GTA2_REFERENCE_RU.md) | Big Russian research reference: mechanics, city, all 63 missions, vehicles, weapons, cheats, sources. User-supplied (written for the user). |
| [GTA2_ECONOMY_RU.md](GTA2_ECONOMY_RU.md) | Russian note on the final game's score/money economy. User-supplied. |

## findings/ — by usefulness for this project

All of them were written for a browser **reimplementation** (my-games, `rts-dots2/games/gta2`
at `bf84820c`); each has a banner saying so. They are kept because they carry
original-game evidence: DMA spec readings, measured file contents, gta2_re function names
and player observations of the original game.

| Note | Format / original-game content | Reimplementation share |
|---|---|---|
| [sound-banks](findings/sound-banks.md) | SDT/RAW layout, U8 police channel, sample identifications | medium |
| [car-deltas](findings/car-deltas.md) | DELX/DELS layout, damage bits | low |
| [vehicle-data](findings/vehicle-data.md) | PALB/CARI remaps, NYC.GCI fields, Fix16 0x4000 | medium |
| [ped-animation](findings/ped-animation.md) | ped remap base, sprite frame ranges | medium |
| [roof-corners](findings/roof-corners.md) | slopes 49–52 + lid 1023 roof semantics | medium |
| [road-network](findings/road-network.md) | arrow bit directions | high |
| [traffic-signals](findings/traffic-signals.md) | zone type 2 junctions | high |
| [pavement-navigation](findings/pavement-navigation.md) | slope_type ground bits | high |
| [taxis](findings/taxis.md) | GCI models 51/56 ↔ CARI sprites, audio classes | medium |
| [collision-economy](findings/collision-economy.md), [car-fire](findings/car-fire.md), [punch-and-recovery](findings/punch-and-recovery.md), [pedestrian-audio](findings/pedestrian-audio.md), [lane-assist](findings/lane-assist.md), [shared-vehicles](findings/shared-vehicles.md), [pedestrian-population](findings/pedestrian-population.md) | gta2_re function names for damage, fire, punches, arrow steer assist, vehicle audio, ped movement; thresholds read from that source | high |

Left behind in my-games: `asset-pipeline.md` (its importer; the one format fact, CMAP≠DMAP,
is in lessons.md), `pedestrian-collisions.md` and `traffic-drivers.md` (pure simulation
design, no original-game evidence), the screenshot gallery, the listening-evidence JSON,
and the third-party binaries/PDFs (see ../reference.md; DMA's specs are in specs/).
