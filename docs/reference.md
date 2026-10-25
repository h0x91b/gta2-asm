# Third-party GTA2 reference material not in the repository

DMA's format and scripting specs **are** committed: [docs/formats/specs/](formats/specs/README.md)
(with their gtamp.com URLs and SHA-256). What is listed here stays out of the repository:
binaries (the repo carries none) and documents that are not specs. SHA-256 values are of
the copies downloaded on 2026-09-04.

| What | Source | Bytes | SHA-256 |
|---|---|---|---|
| Scripting kit binaries: `miss2.exe` compiler, `MSVCRTD.DLL`, `MSVCIRTD.DLL`, parser tables `miss2.dfa`, `miss2.llr` | inside https://gtamp.com/GTA2/gta2script.7z | 505 151 (archive) | `ace737b854db41ce1bd5b7b38e016d8aa0fe7b48b43efe2e84a4c5b638ce52df` (archive) |
| Game manual | https://gtamp.com/GTA2/gta2manual.pdf | 650 951 | `76cd15ddc1e703b647516e24bfffbca0eb8140391a7ee0861d71de366184be05` |
| District maps (geography, not the binary format) | https://gtamp.com/GTA2/gta2maps.pdf | 2 017 382 | `1a6786ea5d54b177c0dabbe8e32b3f18ae1e8831ea3d5024ae33b2f9a29cf9ff` |
| Text/font generator page snapshot | https://gtamp.com/text/ | 4 670 | `19b742ad595a416c703ad5c8271919af9b42011ca5b82107c50be17ba299cfb7` |
| Rockstar Classics freeware installer (2004), the only official source of the radio music; `tools/get-game.sh` downloads it to `downloads/` (or the user keeps it as `setup.ebin`), git-ignored; `tools/add-music.sh` takes `data/GTAudio/` from it | https://archive.org/details/gta2_rockstar-classics (as used by [gta2-browser](https://github.com/M1sterMo/gta2-browser)) | 362 331 961 | SHA-1 `8c10c0d20f15912a9450b6fbe028f31928b29893` |

When a note cites `formats/GTA2 Map Format.txt` or `formats/GTA2 Style Format.txt`, the
file is now `docs/formats/specs/GTA2 Map Format.txt` / `GTA2 Style Format.txt`.

Decompilation used by the ported findings: [CriminalRETeam/gta2_re](https://github.com/CriminalRETeam/gta2_re)
revision `51d2ce3d4b8d32b6d48ff5c938cc98521061691b`. Its function names are useful search
keys, but its `_XXXXXX` address suffixes are **not** 11.44 VAs: it targets GTA2 10.5 (see `docs/formats/loader-map.md`).
The other reference repos (seuko-mod, gta2-resurection, gta2-mouse) are listed in
[AGENTS.md](../AGENTS.md), "Reference material"; every source with its terms is in
[CREDITS.md](../CREDITS.md).
