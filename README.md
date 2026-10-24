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
In a game, **K** opens a debug menu and pauses the game (game font and sprites; arrows, PAGE UP / DOWN, HOME / END,
RETURN, BACKSPACE = back): quick save where you
stand (not during a mission), all weapons, +$100000, live camera zoom (70% by default, `camera.zoom` in config.yaml; 100 = vanilla), Ped paths (each ped's next
10 path cells, numbered 1 = next, in a colour of its own; else a tick showing where it faces); a Player page (set
or lock the wanted level, skin and body type; place real police, FBI or army roadblocks on the
nearest road ahead, which stay until you remove them; call an ambulance or a fire truck the
game's own way: a nearby body is queued, or a ped killed, for the ambulance; a parked car
mid-lane is set alight for the fire truck — `host/c32/emergency.c`), a Vehicle page (colour,
invincibility, repair or explode the car you are in or left last), a Spawn page with **Spawn >
Car**: every car of the level by its in-game name, LEFT / RIGHT picks the remap (random, none or
each of the model's own) with a big rotating preview of the car in it, RETURN spawns it in front
of you in that remap; and a
Debug flags page (FPS / camera info / invulnerability / no police and a few other DMA
flags, and the Road network overlay: lane arrows, the junction graph, live traffic lights,
routes, the pavement peds walk on; [docs/debug-roads.md](docs/debug-roads.md)). BACKSPACE or Back
returns to the parent page; ESC or K closes the menu. Every page is its own file that registers
itself; how to add one: [docs/debug-menu.md](docs/debug-menu.md).
Flags and internals: [host/README.md](host/README.md), [docs/](docs/).

## Inspect the game files

`tools/formats/` decodes styles, maps, sound banks and car handling straight from
`data.pak` (needs [Bun](https://bun.sh)):

```sh
bun tools/formats/cli.ts sty data/wil.sty --summary
bun tools/formats/cli.ts gmp data/wil.gmp --block 40,135,3
bun tools/formats/cli.ts sty data/wil.sty --sprite 0 --out formats-out/car.png
```

Format notes: [docs/formats/](docs/formats/README.md).

## Credits

Built on other people's work: gta2-seuko-mod by izawartka, the user's earlier
gta2-resurection and gta2-mouse, M1sterMo's [gta2-browser](https://github.com/M1sterMo/gta2-browser)
(GTA2 in the browser — [play it](https://m1stermo.github.io/gta2/)), DMA Design's format documents via gtamp.com, gta2_re,
SDL3, NASM, Ghidra and more. Every source, what was taken from it and its terms:
[CREDITS.md](CREDITS.md).
