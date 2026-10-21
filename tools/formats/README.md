# tools/formats — GTA2 file-format decoders

TypeScript decoders for the game's data files, run with Bun (no npm dependencies). They
read straight from `data.pak` (`pak.ts`, same rules as `host/w32_vfs.asm`: Stored entries
only, case-insensitive paths) and document the on-disk layouts that `gta2.exe` parses into
memory — the starting point for reversing its loaders (`docs/formats/loader-map.md`).

Ported from the user's my-games project (`rts-dots2/games/gta2`, commit `bf84820c`), where
they were written and battle-tested for a browser reimplementation. Format notes and
traps: `docs/formats/`.

| File | Format |
|---|---|
| `pak.ts` | `data.pak` index and reads |
| `style.ts`, `deltas.ts`, `style-metadata.ts`, `car-colors.ts` | `.sty` GBST v600/700: PALX/PPAL/PALB palettes, TILE, SPRX/SPRG sprites, SPRB/FONB bases, CARI, DELX/DELS damage deltas |
| `map.ts` | `.gmp` GBMP v500: DMAP (preferred) / CMAP columns and blocks, faces, slopes, arrows, ZONE |
| `sound.ts` | `.sdt` + `.raw` sound banks → WAV |
| `gci.ts` | `nyc.gci` car handling (text) |
| `tga.ts`, `png.ts` | frontend TGA decode, PNG encode |
| `cli.ts` | the command line below |

## CLI

```sh
bun tools/formats/cli.ts help
bun tools/formats/cli.ts pak --grep '\.sty$'
bun tools/formats/cli.ts sty data/wil.sty --summary        # chunks, sprite/palette bases
bun tools/formats/cli.ts sty data/wil.sty --cars           # CARI records
bun tools/formats/cli.ts sty data/wil.sty --sprite 0 --palette 3110 --out formats-out/car.png
bun tools/formats/cli.ts gmp data/wil.gmp --block 40,135,3  # one block_info, decoded
bun tools/formats/cli.ts gmp data/wil.gmp --zones --type 2
bun tools/formats/cli.ts sdt data/audio/wil --wav 1 --out formats-out/wil1.wav
bun tools/formats/cli.ts gci --model 0
```

Extracted game data never goes into the repository: `--out` is required for anything that
writes, and a path inside the repo is refused unless git ignores it (`/formats-out/` is
ignored for this). `--pak <path>` reads another pak.

## Tests

```sh
bun test tools/formats
```

Fixture tests build synthetic files (no game data). Tests over the real files run only
when `data.pak` is present; they decode every tile and sprite of the four styles, all 17
maps, and round-trip all 978 sound bank samples.
