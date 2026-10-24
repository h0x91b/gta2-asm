# K menu (in-game debug menu) — structure, keys, how to add a page

The K menu is our own in-game tool: K opens it during gameplay, it is drawn with the game's
own font and sprites over the HUD, and every feature lives in a module that registers its
pages and entries itself. This document is the design record (v2, 2026-10-22) and the recipe
for growing it.

## 1. What it was (v1)

- `host/debug_menu.asm` held everything: the key handler (`dbgmenu_key`, called first by
  `input_key` in `w32_dinput.asm`), the draw (`dm_draw`, from the `DrawUI` call hook
  `hk_DrawUI`), the Player and Vehicle features, and **four central tables**: `dmp_main`,
  `dmp_player`, `dmp_vehicle`, `dmp_flags` (`DMITEM kind, "label", data`).
- Feature modules (`debug_paths.asm`, `debug_roads.asm` — both C32 now, see "World overlays" —, `debug_roadblocks.asm`,
  `debug_emergency.asm` — C32 now, see "Roadblocks and emergency services" —, `player_move.asm`, now C32 + `c32_host.c`) exported `dm_<name>_change` / `dm_<name>_fmt`
  pairs or flag bytes, and **debug_menu.asm listed them** in its tables. Their per-frame work
  (`rb_frame`, `de_run`, `dm_draw_paths`, `dr_draw`) was called by name from `hk_DrawUI`.
- Item kinds: action (an id dispatched by a `cmp`/`call` chain in `hk_DrawUI`), flag byte,
  value (`{change, fmt}` pair), page link, back, close, camera zoom (special-cased).
- Navigation: UP/DOWN (wrap), LEFT/RIGHT/RETURN change, only one level of sub-pages (Back
  always went to the main page), no scrolling (a page had to fit on screen), no graphics.

Adding anything therefore meant editing the central tables, often `hk_DrawUI` too, and a
long list (all car models, all remaps) was not possible at all.

## 2. Requirements for v2

1. **Extensibility first**: a new page or entry is a local change in its own file, with one
   registration, no edit of any central table, list or file.
2. A tree of pages of any depth; Back goes to the parent.
3. Data-driven entries: label, kind (action / toggle / value / page link), handler, order.
4. Long lists: scrolling, page up/down, home/end; dynamic rows (models of the current level).
5. A reusable preview pane: draw any game sprite (car, ped, object) with any remap, scaled
   and rotated, inside the menu.
6. Existing features keep working; menu actions that call game code still run on the game's
   side of the frame (`hk_DrawUI`), never inside the input handler.

## 3. Options

### 3a. Where the menu structure lives

| Option | How | For | Against |
|---|---|---|---|
| A. Central NASM tables (v1) | pages and items listed in debug_menu.asm | simplest, no runtime build | every feature edits the same file; merge conflicts between parallel tasks; violates req. 1 |
| B. Runtime registration calls | each module has `xx_menu_init` that calls `dm_add_item(...)` | flexible, dynamic | someone must call every `xx_menu_init` — a central list again (or a linker set anyway) |
| **C. Linker sets (chosen)** | each module emits fixed-size records into its own Mach-O sections `__DATA,__dm_pages` / `__dm_items` / `__dm_frame` with a macro; the linker concatenates them and `section$start$__DATA$__dm_items` / `section$end$…` bound the arrays; the menu builds the tree once at first open | zero central edits, static data (no init order), the same trick as C `__attribute__((section))` plugin tables; sorting by an `order` field keeps a stable layout | records must be fixed-size; the tree is built at run time (a few µs once) |
| D. External data file (yaml/json) | pages and labels in a file, handlers bound by symbol name | editable without rebuilding | needs a symbol table at run time, a parser in NASM, and handlers still need code; much bigger for no gain |

C wins: it is the only option that satisfies requirement 1 with no runtime glue, and it costs
~150 lines of NASM. New *files* are picked up by `host/build.sh`, which generates
`host/menu_modules.inc` (git-ignored) with one `%include` per `host/menu/*.asm`, so even
adding a file does not touch `loader.asm`.

Verified: NASM `-f macho64` with `section __DATA,__dm_items data align=8` from several places
in one translation unit, plus `extern section$start$__DATA$__dm_items`, links with ld 1230
and walks every record (scratch test 2026-10-22, then the real build).

### 3b. How to draw graphics in the menu

| Option | How | For | Against |
|---|---|---|---|
| **1. The game's `DrawSprite2D` (chosen)** | stdcall `0x4CBA50` (type, id, x, y, rot, scale, `PALETTE_BASE*`, remap, …); HUD sprites go through it (`Hud_DrawSprite2DScaled` `0x4C71B0`) | the game's own sprite index, texture cache, palettes and remaps; works for every sprite type; rotation and scale built in; draws through our `gbh_DrawQuad` like the HUD | must run on the game side (it does: `dm_draw` is inside `hk_DrawUI`) |
| 2. Our renderer directly | decode sprite pixels + palette from the style data ourselves, upload an SDL texture | independent of game state | duplicates the game's palette/remap logic; renderer-specific; violates "reuse the game" |
| 3. A real world car under the menu | spawn a hidden car and point a camera at it | "true" rendering incl. deltas | absurdly heavy, side effects on the world |

Option 1, verified in disassembly (`RET 0x2C`) by us and by Seq 27
(report `seq49-car-sprite-remap.md`): `x, y` are the sprite centre in screen pixels (SCR_f,
14 fraction bits), the quad is `w/h * scale / 2` rotated by `rot` (1440 units per turn, like
`Sprite.rotation`), `*palette` is the palette-base kind (2 sprite = no remap, 3 car remap,
4 ped remap, 5 code obj, 6 map obj, 7 user, 8 font) and `remap` the index within that base.

## 4. The structure (v2, in host C since v3)

### v3: the port to 64-bit host C (Seq 55, 2026-10-22)

The framework and every page moved from NASM (`host/debug_menu.asm` + `host/menu/*.asm`,
4745 lines) to host C in `host/c/menu/` (one file per page, `docs/host-c.md`). Same keys,
rows, layout, log lines; screenshots and logs compared scenario by scenario. What stays NASM
is glue in `host/debug_menu.asm` (see "NASM glue" below).

How a C file registers itself, options considered:

| Option | For | Against |
|---|---|---|
| **A. The same linker sets, from C (chosen)** | `__attribute__((used, section("__DATA,__dm_items")))` records with the exact NASM layout, so C pages and the not-yet-ported NASM feature modules land in one array and sort together; static data, no init order, zero runtime glue | records stay fixed-size; a page needs the macro, not a function call |
| B. Constructor registration (`__attribute__((constructor))` calling `dm_register`) | ordinary C, dynamic | runs before `_main` in libSystem's init (ordering vs our own setup); the NASM modules' records would need a second path or a rewrite now |
| C. A central C table | trivial | violates requirement 1, merge conflicts between parallel tasks |

A also kept the NASM `DM_ITEM` / `DM_FRAME` / `DMVALUE` macros working unchanged, which the
wave-1 rule required. Wave 2 moved every NASM feature module to C / C32; the macros went with
the last one (player_move, Seq 62).

### Records (macros in `host/c/menu/dm.h`)

```c
DM_PAGE(name, parent, order, "Title"[, .draw = f, .key = f, .rows = f, .rowfmt = f, .rowchange = f]);
DM_ITEM(page, order, KIND, "label", data);
DM_FRAME(order, fn);        /* fn() once per gameplay frame, on the game's side, before the HUD */
DM_VALUE_FNS(x);            /* static const struct dm_value dmv_x = { x_change, x_fmt } */
DM_PAGE_EXTERN(name);       /* another file's page, as a parent or for DM_ITEM */
```

- `DM_PAGE` emits a page record **and** the link item `Title...` on its parent, so a page
  appears in its parent's list by itself. Only the root (`root.c`) is written by hand
  (no parent, no link). Every page is a global under its own name without the underscore
  (`dmp_player`), so NASM can `extern` it; `dm.h` declares the well-known ones.
- Optional page callbacks (0 by default):
  - `void draw(struct dm_page *page)` after the list: the preview pane or any extra content.
  - `int key(int dik)` → 1 consumed, before the generic keys.
  - `int rows(void)` dynamic rows shown before the registered items (lists built at run time,
    e.g. the models of the current style); `void rowfmt(int row, char *buf)` writes a row
    label (128 bytes); `void rowchange(int row, int dir)`, dir -1 / +1 / 0 RETURN.
- Item kinds: `DM_ACTION` (data = `void fn(void)`, run deferred on the game's side),
  `DM_FLAG` (data = a byte toggled 0/1, may be a game address), `DM_VALUE` (data =
  `&dmv_x`, `{void change(const struct dm_item *, int dir), void fmt(char *end)}`),
  `DM_LINK` (emitted by `DM_PAGE`). Every page gets `Back` (or `Close` on the root) last.
- `order`: rows sort by it (ties keep link order: the C objects in `build.sh` order); leave
  gaps of 10.

### Runtime (`core.c`)

- First gameplay frame: `dm_build` walks `__dm_items` once and makes a sorted row array per
  page, and sorts the `__dm_frame` records in place.
- `dm_page` is the current page; each page remembers its selection and scroll offset.
- Up to `DM_VISIBLE` (16) rows show at once; a scroll bar appears when there are more.
- `dm_defer(fn)`: queue a function for the game's side of the frame (`dm_on_drawui`, after
  the `DM_FRAME` hooks). Actions and spawners use it.

### NASM glue (`host/debug_menu.asm`)

- `hk_DrawUI` / `hk_PauseOverlay`: the two CALLHOOK handlers; `hk_DrawUI` hands the
  DrawUI `ecx` to `dm_on_drawui`.
- `dbgmenu_key` (for `input_key`), `dm_player_ped` (eax = Ped\*, ecx = Player\*, every other
  register kept), `dm_call_car`: the register contracts the NASM callers were written
  against, as thin shims over C.
- `dm_cb(fn, a, b)`: how C calls anything that may be NASM (frame hooks, value pairs,
  actions, `low_alloc`, `input_release_all`). It keeps rbx, rbp, r12-r15 and aligns the
  stack whatever the callee does, because NASM callbacks were only ever checked against
  NASM callers.
- C data the feature modules read or write keeps its NASM name through `NASM()` labels:
  `dm_toast`, `dm_toast_left`, `dm_model`, `dm_spawnable`, `dm_last_car(_id)`,
  `s_dm_noplayer2`, `fmt_dm_int`, `dm_paused`; `f_dm_rot2rad` stays NASM data.

### Keys

| Key | Does |
|---|---|
| K | open / close (the game is paused while it is open) |
| ESC | close |
| UP / DOWN | select (wraps) |
| PAGE UP / PAGE DOWN | 10 rows up / down |
| HOME / END | first / last row |
| LEFT / RIGHT | change the value (on Spawn car / object: the remap; on Spawn ped: the role) |
| RETURN | activate (open page, run action, toggle; on Spawn car / ped / object: spawn) |
| PAGE UP / PAGE DOWN | on Spawn object: the previous / next group (instead of 10 rows) |
| B | on Spawn ped: the behaviour (normal / hostile / follows you) |
| BACKSPACE | back to the parent page |

### Pause

While the menu is open the game is paused (`dm_pause_sync`, the first `DM_FRAME`): a running
game (`Game +0 gameStatus` 1) that allows pausing (`+0x23` = 1, the game's own test in
`ToggleGamePause` `0x45BAA0`) is set to 2, `GAME_PAUSED`. `Game_StepByStatus` then only runs
`Game_TickPaused` (cameras), but `DrawUI` still runs, so the frame hooks, deferred actions and
the menu keep working, and a car spawned meanwhile appears in place. On close
`UnpauseGame` `0x45BA60` restores 1 (it also flushes DirectInput and clears the player's
input). A pause the player made with the game's own key is left alone. The game's "pause"
screen (`Hud_PauseOverlay_Draw` `0x4C9FA0`, called by `DrawUI` at `0x4CA4F9`) is skipped by a
CALLHOOK while the pause is ours.

### Reusable components (`dm.h`)

- `dm_text_at(s, x, y, highlighted)` — game font text at any spot.
- `dm_rect(x1, y1, x2, y2, argb)` — a flat box.
- `dm_sprite(&(struct dm_sprite){ .type, .id, .pal, .remap, .x, .y, .box, .scale, .rot })` —
  any sprite: type (SPRITE_TYPE 2 car, 3 ped, 4 code obj, 5 map obj, 6 user, 7 font), id
  (relative to the type's base), palette kind, remap, centre, `box` fit size (0 = use
  `scale` percent), `rot` (1440 per turn). It looks up w/h in the style to fit the box.
- `dm_text_w(s)` — a string's width in 640x480 units at the menu's text size
  (`GetGTATextWidth` `0x4CB0C0`). The list box grows to its title and visible rows (at least
  `DM_W_MIN`), so nothing leaves it; a pane measures its own lines the same way.
- `dm_pane(y1, y2, width)` — the pane frame right of the list box; its content starts at
  `dm_pane_x` (set every frame from the box's measured width).
- `dm_sprite_wh(type, id)` → `w | h << 8`; `dm_car_info(model)` → `CarInfo *` or 0
  (`g_StyleData 0x670684 +0x5C` → `AllCarsInfo.cars[model]`, re/ `StyleData_GetCarInfo` 0x4BF1F0);
  `dm_gxt(key, out, size)` — game text (`Gxt_FindTextW` 0x4C2120 on `g_LocaleSettings`
  0x671550) as ASCII.
- `dm_toast_set(s)` — the message line at the bottom.
- `dm_player()`, `dm_player_ped()`, `dm_car(&in_it)` — shared game helpers (`helpers.c`).

### Spawning without the UI (`host/c/spawn.h`)

The Spawn pages are a UI over four plain functions, also used by gta2ctl (Seq 58):
`km_spawn_pos(out[4], dist)` (where the menu spawns: that far in front of the player on
foot, facing the same way; 1.5 blocks for cars and objects, 1 for peds),
`km_spawn_car(model, remap, x, y, z, rot)`, `km_spawn_ped(remap, role, behave, x, y, z, rot)`,
`km_spawn_object(type, remap, x, y, z, rot)`. Each returns the game object's VA or 0 and
sets `km_spawn_why` to the menu's toast text; call them on the game's side of a frame. The
pages print the `menu: spawn ...` log lines themselves.

All layout is in 640x480 units, scaled by the main camera's `uiScale` like the HUD.

### Known limits

- `dm_sprite` computes `uiScale * k` in 32 bits, like the NASM did. Computed, not
  observed: at `uiScale` 2.0 (1280x960) the ped preview's 450 % (k = 73728) wraps to a
  negative scale; the spinning preview looks right in the screenshots, so it was kept for
  parity. A 64-bit product is
  the fix if a fixed-angle preview ever needs it.
- `km_spawn_pos` uses libm `sin`/`cos` in doubles where the NASM used x87 `fsincos` at the
  game's 24-bit precision: a spawn point may differ by 1/16384 of a block.

## 5. How to add a page (recipe)

1. Create `host/c/menu/<thing>.c`. `build.sh` compiles every file there.
2. Declare the page and its rows. The page's link shows up on the parent by itself:

```c
/* host/c/menu/hello.c — a minimal page under the root */
#include "dm.h"

static uint8_t hello_flag;

static void hello_say(void)             /* runs on the game's side of the frame */
{
    dm_toast_set("Hi");
}

DM_PAGE(dmp_hello, dmp_root, 90, "Hello");
DM_ITEM(dmp_hello, 10, DM_FLAG, "A toggle: ", &hello_flag);
DM_ITEM(dmp_hello, 20, DM_ACTION, "Say hi", hello_say);
```

3. A value row: `static void x_change(const struct dm_item *it, int dir)` and
   `static void x_fmt(char *end)`, then `DM_VALUE_FNS(x);` and
   `DM_ITEM(page, order, DM_VALUE, "X: ", &dmv_x);`.
4. Need graphics? Give the page `.draw = f` and call `dm_sprite` from it. A list built at
   run time? `.rows` / `.rowfmt` / `.rowchange`. Per-frame work (an overlay, a watchdog)?
   `DM_FRAME(order, fn);` in the same file.
5. `host/build.sh`, run, open K.

Adding a row to an existing page is one line in your own file:
`DM_PAGE_EXTERN(dmp_vehicle);` (not needed for the pages `dm.h` declares) and
`DM_ITEM(dmp_vehicle, 45, DM_VALUE, "Turbo: ", &dmv_turbo);`.

`host/c/menu/spawn_car.c` is the worked example for larger pages: a page under `dmp_spawn`
with dynamic rows (`rows` lists the style's models, `rowfmt` names them, `rowchange` takes
LEFT / RIGHT as the remap and RETURN as "spawn" through `dm_defer`) and a `draw` callback
with `dm_pane` and `dm_sprite`.

### A row for a C32 module

C32 code runs in the game's segment and cannot register host records itself; its row lives
in host C (the mod's host file, like `host/c/c32_host.c`, or a page file) and reaches the
C32 side through `C32_EXPORT` (`docs/c32.md`, "Exports"). A sketch (not built; the live
example is below):

```c
/* host C */                                   /* host/c32/turbo.c (C32) */
static uint32_t *turbo;   /* = c32_find("turbo_on") once the image is loaded */
                                               uint32_t turbo_on;
static void turbo_change(const struct dm_item *it, int dir)
{                                              C32_EXPORT(turbo_on);
    (void)it; (void)dir;
    *turbo ^= 1;          /* a plain store: the image is mapped 1:1 */
}
static void turbo_fmt(char *end) { strcpy(end, *turbo ? "on" : "off"); }
DM_VALUE_FNS(turbo);
DM_ITEM(dmp_vehicle, 45, DM_VALUE, "Turbo: ", &dmv_turbo);
```

A C32 *function* (an action) is exported the same way (`C32_EXPORT(turbo_now)`) and called
from a `DM_ACTION` with `call32((gptr)(uintptr_t)c32_find("turbo_now"), 0, 0, 0, 0, 0)` —
actions run deferred on the game's side, where calling 32-bit code is allowed. The Mods
page's "Car entry bonus" (`c32_host.c`) is the live example of the value-row form.


## 6. Pages today

Files are in `host/c/menu/` unless a path is given.


- **root** (`root.c`): Quick save, Get all weapons, Add $100000, Camera zoom; Ped
  paths (`overlays.c`, drawn by C32 `debug_paths.c`), Mouse turning and Strafe (`c32_host.c`, for `c32/player_move.c`); links.
- **Player** (`player.c`): wanted level and lock, skin, body; roadblocks
  (`roadblocks.c`, C32 `host/c32/roadblocks.c`), ambulance / fire truck (`emergency.c`, C32
  `host/c32/emergency.c`); see "Roadblocks and emergency services" below.
- **Vehicle** (`vehicle.c`): the current / last car, colour, invincible, repair, explode.
- **Spawn** (`spawn.c`): a group page for spawners.
  - **Car** (`spawn_car.c`): every spawnable car model of the current style, its
    name from the GXT, sorted by the style's rating (99 special first, then good, average,
    bad; DMA's GTA2 Style Format), LEFT / RIGHT picks the remap (game's random, none, or each of the
    model's own remaps), a rotating preview with that remap at 2-3x size, size / seats /
    rating class / remap count; RETURN spawns it 1.5 blocks in front of the player with that remap.
  - **Ped** (`spawn_ped.c`): one row per ped remap 0..52 (the look), named from the
    PED_REMAP enum (`Remap N (civilian)` for the unnamed ones), the level's gangs tagged with
    their gang (`Yakuza (yakuzagang)`) and sorted first, then police, emergency / special roles,
    named looks, plain civilians. LEFT / RIGHT picks the role: auto (the look's own: gang member
    for a level gang's remap, cop for 0..3, army for 4, Elvis 12, fireman 14, car thief 15,
    medic 16, mugger 17, else civilian) or any of civilian, gang member, cop, SWAT, FBI, army,
    medic, fireman, Elvis, mugger, car thief, psycho, criminal, stand-still bloke. A role is an
    occupation, a body (graphicType: dummy / gang / emergency frame block), a ped class, threat
    search / reaction and a weapon, copied from the game's own spawn site of that kind. B picks
    the behaviour: normal, hostile (KILL_CHAR_ON_FOOT on the player) or follows you (joins the
    player's group). The preview walks (frames 0..7 of the role's body) and turns, in that remap,
    with remap / occupation / body / gang / behaviour lines. RETURN spawns it 1 block in front.
    Layout choice: rows are the looks because that is the long, browsable axis the request
    names ("Remap N with its gang / occupation") and it is per level only in the gang tags;
    the role is a short cycle that applies to any look (a cop in Elvis' remap is a valid debug
    case), and "auto" keeps the common case one key. The behaviour is orthogonal to both, so it
    gets its own key instead of a third list.
  - **Object** (`spawn_object.c`): every world object type the level's prefab table
    holds (the game's static tables plus the style's map objects; 122 in Downtown), named
    from the GXT for pickups (`c%02d`, like the game's pickup message) and from the
    `OBJECT_TYPE` enum otherwise (an unnamed map object reads "Map object N"), in groups:
    street furniture (the style's map objects and their moving / dead variants), weapon,
    car weapon and power-up pickups, explosives, phones (the idle ones), other (skids,
    blood, gang decals, fire, ...). PAGE UP / PAGE DOWN jump between groups,
    LEFT / RIGHT picks the remap (own colours or each remap of the code / map object
    palette), the preview is the object's sprite up to 4x, animated for the animated
    kinds, with type, sprite id, size, frames, kind and solid / pushable / explosive. RETURN
    spawns it 1.5 blocks in front of the player through the script's own call (pickups
    200..244 `Object_NewPhysicsObjUnlessBlocked`, the rest `ObjectSpawner_SpawnObject`), so it gets the
    collision grid, a pickup its default ammo and is collectable; "Blocked here" when the
    game refuses (something in the way, a full pool). Not offered: projectiles, particle
    systems, lights, logic and car-shop objects, crane / crusher parts, the moving pickup
    clones 64..108, the bonus token (it would use up one of the level's token flags), the
    bonus letters (GXT "na"; picking one up would call Ped_AddWeapon with a letter's index) and
    ringing / in-call phones (touching one answers it through the mission script). Seq 27's
    notes on what is safe: `seq52_prep.md` (Seq 27 report).
- **Map** (`host/c/map.c`): Minimap, Minimap turns with you, Fog of war, Reveal the whole
  map, Forget explored map ([map.md](map.md)).
- **Mods** (`mods.c`): Car entry bonus, Passenger and City fights (registered by
  `host/c/c32_host.c`; City fights: [city-fights.md](city-fights.md)).
- **Debug flags** (`flags.c`): the game's own flags; Road network (`overlays.c`, drawn by C32
  `debug_roads.c`, [debug-roads.md](debug-roads.md)).

### World overlays: Ped paths and Road network (C32, Seq 61)

The two overlays drawn over the world under the HUD moved from NASM (`debug_paths.asm` 670 +
`debug_roads.asm` 1188 lines) to C (2026-10-23). Where the code went, options considered:

| Option | For | Against |
|---|---|---|
| All host C | one flavour, `printf` and the menu next to it | every point is a `WorldPointToScreen` and every dot a `DrawFlatRect2D`: ~100-250 boxes and as many projections per frame, each a `call32` mode switch; the game structs read through `GP()` casts |
| All C32 | game calls are plain `call`s, `re/gta2_types.h` structs as they are | a C32 module cannot register menu records or print `printf` lines (only `c32: ` prefixed `c32_log`), and `r_frames` / `cam_zoom_pct` live in host memory above 4 GB |
| **Split (chosen)** | the drawing — game memory reads and game calls — is C32 (`host/c32/debug_paths.c`, `debug_roads.c`, the shared toolkit `overlay.c`/`.h`); the rows, the two `DM_FRAME` hooks and the `paths:` / `roads:` stats lines are host C (`host/c/menu/overlays.c`): one `call32` per overlay per frame into the exported `dp_draw(frame)` / `dr_draw(mode, frame)`, the counters read back from the exported `dp_stats` / `dr_stats` | two files per feature |

Same rows, orders, keys and log lines as the NASM. The menu state (`Ped paths` flag,
`Road network` mode) is host data; the C32 functions get it as arguments. The heading tick
keeps the NASM's x87 `fsincos` sequence (inline asm) so it rounds the same. Test builds:
`C32FLAGS_EXTRA=-DDP_TEST=F` (every ped after the player at frame F) and
`C32FLAGS_EXTRA='-DDR_TEST=F -DDR_TX=X -DDR_TY=Y'` (teleport), formerly `NASMFLAGS`.

End to end: `tests/ctl/debug_overlays.sh` (both overlays through the menu's own keys, two
places, a walk with a planned path, screenshots, the stats lines). Parity with the NASM was
measured with a temporary harness that ran master's NASM and the C32 in the same frame, C32 in
record mode, and compared the `DrawFlatRect2D` argument streams: 0 mismatches over every
overlay frame of the test (roads 200+ frames / 40 060 boxes, paths 200+ frames / 22 007 boxes,
and the same with every ped on a path); the screenshots of a normal run match master's
byte for byte where the game itself repeats (two master runs differ after ~frame 1000).

### Roadblocks and emergency services (C32, Seq 60)

"Place roadblock" / "Remove roadblocks" and "Call ambulance" / "Call fire truck" (Player page)
moved from NASM (`debug_roadblocks.asm` 654 + `debug_emergency.asm` 1311 lines) to C
(2026-10-23), split like the overlays: the game logic — ped and car pool walks, map block
and road network reads, `Ped_SetObjective`, `Ped_OnDeath`, `SpawnCar`,
`Car_RequestFireTruckAndSpawnFlames`, `PoliceManager_TryCreateRoadblockAt` on our own slots —
is C32 (`host/c32/roadblocks.c`, `host/c32/emergency.c`, game structs from
`re/gta2_types.h`, every field pinned with `C32_OFFSET`); the four rows and two `DM_FRAME`
hooks are host C (`host/c/menu/roadblocks.c`, `host/c/menu/emergency.c`). Each hook does one
`call32` a frame into the exported `rb_frame(req, kind)` / `de_frame(req, frame, model,
last_car)`, which return the toast (a C32 string, read in place: the image is mapped 1:1);
`rb_up` (the "Remove roadblocks: N" count) and `de_spawned` (a car put on the road, which
becomes the menu's last car) are exported variables. The `CarAI_FollowRoute` arrival
workaround is a `c32_callhook` on 0x432678 now, not a NASM `CALLHOOK`. Same rows, orders,
keys, toasts and log lines; the lines now carry the `c32: ` prefix of `c32_log`.

One change on purpose: leaving a level forgets our roadblocks through a detour on
`DeinitGame` 0x462060. The NASM watched `Game*` for a change, but quit + "Replay previous
area" gets a new `Game` at the same address: measured on master (2026-10-23), the slot
survived the replay and "Remove roadblocks" ran `PoliceRoadblock_Remove` on the previous
level's freed cars and peds ("Removed 1 roadblocks" in a level that had none).

Test builds: `C32FLAGS_EXTRA=-DDE_TRACE` (the per-frame slot / route trace, formerly
`NASMFLAGS=-DDE_TRACE`). Dropped: `DE_TEST_TP` (teleport at a frame) and `RB_TRACE` (the
player's position every 50 frames) — `gta2ctl teleport` / `state` do both.

End to end: `tests/ctl/emergency.sh` (an ambulance and a fire truck next to the road east of
the start: the "emerg:" lines through the slot states, screenshots) and
`tests/ctl/roadblocks.sh` (one on foot, one from a car, driving into it, remove, quit to the
frontend and replay), both through the menu's own keys.
Parity with the NASM (same scenarios on master and on the port): emergency, all 11 `emerg:`
lines identical apart from frame numbers (ambulance queued for the same ped, slot stages
3 → 6 → 5, fire truck for the same car, states 1 → 2 → 3 → 4 → 5 → 0); roadblocks, every
`menu:` line identical (same tiles, cars, cops, first-car positions; the car stops at the
roadblock, y 151.5 → 146.988 both), apart from the Replay fix below. Screenshots up to the
first divergence in traffic are byte-identical.

## 7. RE facts used (sources)

| What | Address | Source |
|---|---|---|
| `DrawSprite2D` stdcall, 11 args, `RET 0x2C` | `0x4CBA50` | own disassembly + Seq 27 report |
| `Hud_DrawSprite2DScaled` (HUD wrapper, scale = uiScale, a11 = 0) | `0x4C71B0` | own disassembly + Seq 27 |
| `StyleData_GetSpriteIndex` = `spriteBases[type-2] + id` | `0x4BF2A0` | own decompile |
| `g_StyleData` StyleData*; +0x14 spriteBases, +0x20 sprite index (8-byte entries, w +4, h +5), +0x5C AllCarsInfo | `0x670684` | re/globals.csv, re/gta2_types.h |
| `CarInfo`: +1 spriteIndex, +2 w, +3 h, +4 num_remaps, +5 passengers, +7 rating, +0xE remap[] | — | re/gta2_types.h, Seq 27 |
| `Sprite_SetRemap` thiscall(Sprite*, ushort) | `0x4B9B00` | Ghidra (renamed from Position_* by Seq 27) + Seq 27 report |
| `Sprite_SetNoRemapState` fastcall(Sprite*) | `0x420700` | Ghidra (renamed from Position_* by Seq 27) + Seq 27 report |
| `Gxt_FindTextW` thiscall(LocaleSettings*, char* key), `car%d` keys | `0x4C2120`, `0x671550` | re/functions.csv + `GetCarModelName` 0x41F700 |
| `GetGTATextWidth` stdcall(wchar_t*, short font) -> glyph pixels at scale 1 | `0x4CB0C0` | re/functions.csv + Ghidra comment |
| `Game.gameStatus` +0 (1 run, 2 paused), `+0x23` pause allowed; `Game_StepByStatus`, `UnpauseGame` thiscall(Game*) | `0x5EB4FC`, `0x45BA60` | re/gta2_types.h, own decompile |
| `Hud_PauseOverlay_Draw` stdcall(void), its call in `DrawUI` | `0x4C9FA0`, `0x4CA4F9` | re/comments.csv, Ghidra xrefs |
| `Ped_Spawn` stdcall(x, y, z, PED_REMAP, Ang16 rot) -> Ped*, RET 0x14; sets sprite, remap, health 100, AREA / RUN_AWAY, graphicType 0 only; no empty-pool check | `0x43DB40` | Seq 27 (seq51_answer.md), CREATE_CHAR = `Script_Decl_CHAR_DATA_SET` 0x477560 |
| `Ped_SetPedClass` / `Ped_SetOccupation` thiscall(Ped*; value), RET 4 (Ghidra's fastcall prototype is wrong) | `0x403920`, `0x403970` | Seq 27 disassembly |
| `Ped_SetWeapon` fastcall(Ped*, edx; weapon), `Gang_PickWeaponByRespect` fastcall(GangRespect*) | `0x43D830`, `0x45DB70` | Seq 27 |
| `Ped_SetObjective` thiscall(Ped*; objective, timer) RET 8 (clears the target), `Ped_SetObjTargetPed` thiscall(Ped*; Ped*) | `0x43BBC0`, `0x403AC0` | Seq 27, SET_CHAR_OBJECTIVE handler 0x47A1E0 |
| `PedGroupCreate` fastcall(Ped* leader, edx; byte n), `PedGroupAddPed` fastcall(PedGroup*, 0; Ped*), `Ped.group` +0x164, `PedGroup.membersCount` +0x34 (max 8) | `0x440350`, `0x404C90` | Seq 27, re/gta2_types.h |
| Ped frames: graphicType * 158 + anim, walk = 0..7; DrawSprite2D palette kind 4 takes the raw PED_REMAP | `0x497DF0`, `0x4C2AC0` | Seq 27 + style render (`bun tools/formats/cli.ts sty --sprite`) |
| ped pool `PedManager*` +0 freeListHead; Ped +0x238 class, +0x240 occupation, +0x17C gang, +0x288 / +0x28C threat search / reaction | `0x5E5BBC` | re/gta2_types.h, Seq 27 |
| `CarManager_SpawnCar`, TrafficManager, CarsScale | `0x426AC0`, `0x5E4CA4`, `0x5E4D4C` | gta2-seuko-mod `spawn-car.cpp` |
| `g_ObjectPrefabsContainer` (+0x87F4 `ObjectPrefab* byId[300]`), `ObjectPrefabs_Get` | `0x665B40`, `0x488170` | re/globals.csv, re/gta2_types.h, docs/re/objects-and-weapons.md |
| `ObjectPrefab`: +0x1C remap, +0x1E sprite id, +0x28 sprite type (4 / 5), +0x30 palette kind, +0x34 kind, +0x40 grid, +0x44 impact, +0x48 explosive, +0x64 ticks/frame, +0x6C frames | — | re/gta2_types.h; +0x28 goes to `Sprite_SetSpriteType` in `ObjectPrefab_ApplyToPosition` `0x4883A0` (own decompile) |
| Style map objects become prefabs, id = OBJI model | `0x488450` `ObjectPrefabs_InitFromStyle` | own decompile |
| `ObjectSpawner_SpawnObject` / `Object_NewPhysicsObjUnlessBlocked` thiscall(`g_ObjectSpawner` `0x665788`; type, x, y, z, rot), ret 0x14, insert into the grid; the script picks by type 200..244 | `0x4852E0`, `0x485480`; `Script_Decl_OBJ_DATA_SET` `0x476EA0` | own disassembly + decompile |
| `ObjectSpawner_CreateObject`: default ammo for weapon pickups, bonus-token flags | `0x484E00` | own decompile |
| `StyleData` +0x10 palette counts (`PaletteBase`: +8 code obj, +0xA map obj remaps) | `0x670684` | re/gta2_types.h |

## 8. Next pages the structure makes cheap

- **Skin picker with preview**: the Player page's skin row gets a `draw` callback.
- **Car respray with preview**: the Vehicle page's colour row, same component.
- **Weapons page**: one row per weapon, HUD weapon icon as preview (user sprites, type 6).
- **Teleport**: dynamic rows from the map's zones (`gmp` zones).
- **Gang respect / cop level / time of day** sliders, **sprite browser** (any type, any id,
  any palette) as a debugging tool for RE.
