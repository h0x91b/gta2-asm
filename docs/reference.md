# Third-party GTA2 reference documents

These are DMA Design / Rockstar documents and community archives. They are **not** in this
repository (it is public and the files are not ours): download them yourself. The
SHA-256 values identify the exact copies the format decoders (`tools/formats/`) and the
notes in `docs/formats/` were checked against (my-games `docs/reference/gta2/sources.json`,
downloaded 2026-09-04).

| What | Source | Bytes | SHA-256 |
|---|---|---|---|
| DMA format specs: `GTA2 Map Format.doc`, `GTA2 Style Format.doc` | https://gtamp.com/GTA2/gta2formats.zip | 25 643 | `59ea2b0aa7d4c594700177640cff3cf60e65f3d10e20ffdea8818904dd7aeb9d` |
| ├ `GTA2 Map Format.doc` (in the zip) | | | `acb8436161714d00db7f64bdd76fe52070aa7148d7a8c922bfaba5808fac19cd` |
| └ `GTA2 Style Format.doc` v4.6, 1999-11-16 (in the zip) | | 40 448 | `3ed04a3b1c8bbdca90e7fd8837d8fc926faa1850c6155d893d7aac86fdc01963` |
| DMA scripting kit: `GTA2 Scripting.doc`, `miss2.exe` compiler + grammar, 22 example missions, `bil.mis` | https://gtamp.com/GTA2/gta2script.7z | 505 151 | `ace737b854db41ce1bd5b7b38e016d8aa0fe7b48b43efe2e84a4c5b638ce52df` |
| └ `GTA2 Scripting.doc` (in the archive) | | | `fdc375c65cb6892cc6ec218deb932b68b136b605c9513da4eb1c54ebff359964` |
| Game manual | https://gtamp.com/GTA2/gta2manual.pdf | 650 951 | `76cd15ddc1e703b647516e24bfffbca0eb8140391a7ee0861d71de366184be05` |
| District maps (geography, not the binary format) | https://gtamp.com/GTA2/gta2maps.pdf | 2 017 382 | `1a6786ea5d54b177c0dabbe8e32b3f18ae1e8831ea3d5024ae33b2f9a29cf9ff` |
| Text/font generator page snapshot | https://gtamp.com/text/ | 4 670 | `19b742ad595a416c703ad5c8271919af9b42011ca5b82107c50be17ba299cfb7` |

When a note cites `formats/GTA2 Map Format.txt` or `formats/GTA2 Style Format.txt`, it means
a plain-text export of the `.doc` above, made for searching; the `.doc` stays
authoritative for tables and diagrams.

Decompilation used by the ported findings: [CriminalRETeam/gta2_re](https://github.com/CriminalRETeam/gta2_re)
revision `51d2ce3d4b8d32b6d48ff5c938cc98521061691b`. Its function names are useful search
keys, but its `_XXXXXX` address suffixes are **not** 11.44 VAs (see `docs/formats/loader-map.md`).
The other reference repos (seuko-mod, gta2-resurection, gta2-mouse) are listed in
[AGENTS.md](../AGENTS.md), "Reference material".
