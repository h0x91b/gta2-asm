# gta2-asm

Runs the original, unmodified Windows `gta2.exe` (GTA2 11.44) natively on macOS. A
NASM host loads the 32-bit game image into memory, runs it in a 32-bit code segment
under Rosetta 2, and answers every Win32, DirectInput, audio and renderer call it makes
with its own shims on top of SDL3. The game's own code does the work; nothing is
reimplemented.

No game files are included. You need your own copy of GTA2.

## Requirements

- Apple Silicon Mac with Rosetta 2, Xcode command line tools, NASM (`brew install nasm`)
- SDL3 built for x86_64 (see "Toolchain" in [AGENTS.md](AGENTS.md))
- GTA2 **version 11.44**: the full installed game folder (`gta2.exe`, `data/`, ...).
  The community 11.44 installer from gtamp.com is the build this project targets.

## Make `data.pak`

The game is read from one file, `data.pak`, in the repository root: a zip with zero
compression of the whole game folder. Build it from your installed game:

```sh
tools/mkpak.sh /path/to/GTA2 data.pak
```

The script leaves your game folder untouched. Inside the pak it renames every `.exe`
to `.ebin`, and it warns if `gta2.exe` is not vanilla 11.44 (SHA-256 `dd5381c7…a5a2`).
`data.pak` is git-ignored: never commit it.

## Build and run

```sh
host/build.sh --load --entry
```

Saves and other files the game writes go to
`~/Library/Application Support/gta2-resurrected/`. Delete that folder to start clean.
Settings (for now the game's own debug flags: FPS counter, camera coordinates, skip
the main menu, …) go in `config.yaml` in that folder; copy
[config.example.yaml](config.example.yaml), which lists every one, or point at a file with
`--config=PATH`.
In a game, **K** opens a debug menu (game font, arrows + RETURN): quick save where you
stand (not during a mission), live camera zoom, and toggles for FPS / camera info /
invulnerability / no police and a few other DMA debug flags. ESC or K closes it.
Flags and internals: [host/README.md](host/README.md), [docs/](docs/).
