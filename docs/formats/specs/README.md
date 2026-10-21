# DMA Design's GTA2 specifications

Original documentation written by **DMA Design** (now Rockstar North) and released to the
GTA2 modding community; the copies here come from the archives hosted at **gtamp.com**.
All rights remain with their owners. They are kept here as reference for reversing the
game's loaders (`../loader-map.md`) and for the decoders in `tools/formats/`.

| File | What | From |
|---|---|---|
| `GTA2 Style Format.doc` / `.txt` | `.sty` (GBST) format, v4.6, 1999-11-16 | https://gtamp.com/GTA2/gta2formats.zip (byte-identical to the separately supplied `GTA2_Style_Format.doc`) |
| `GTA2 Map Format.doc` / `.txt` | `.gmp` (GBMP) format | https://gtamp.com/GTA2/gta2formats.zip |
| `scripting/GTA2 Scripting.doc` / `.txt` | mission script language (`.mis` → `.scr` via `miss2.exe`) | https://gtamp.com/GTA2/gta2script.7z |
| `scripting/README!.txt` | DMA's notes and disclaimer for the scripting kit | same archive |
| `scripting/example/bil.mis`, `scripting/example/bil/*.mis` | example sources: the Industrial main script and its 22 missions | same archive |

The `.doc` files are the originals and authoritative for tables and diagrams. The `.txt`
files are plain-text exports made for grepping, not DMA's.

`sources.json` records the archives' URLs, sizes and SHA-256 as downloaded on 2026-09-04;
`SHA256SUMS` covers every file in this directory (`shasum -a 256 -c SHA256SUMS`).

Not here on purpose: the scripting kit's binaries (`miss2.exe`, its debug CRT DLLs and its
binary parser tables `miss2.dfa` / `miss2.llr`) — the repository carries no executables or
binaries — and the manual/maps PDFs. See `../../reference.md` for where to get them.
