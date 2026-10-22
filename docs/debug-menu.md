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
- Feature modules (`debug_paths.asm`, `debug_roads.asm`, `debug_roadblocks.asm`,
  `debug_emergency.asm`, `player_move.asm`) exported `dm_<name>_change` / `dm_<name>_fmt`
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

## 4. The v2 structure

### Records (all macros in `host/debug_menu.asm`; a module file only needs them)

```nasm
DM_PAGE  name, parent, order, "Title"[, draw, key, rows, rowfmt, rowchange]
DM_ITEM  page, order, KIND, "label", data
DM_FRAME order, fn          ; fn() once per gameplay frame, on the game's side, before the HUD
```

- `DM_PAGE` emits a page record **and** the link item `Title...` on its parent, so a page
  appears in its parent's list by itself. `parent = 0` only for the root `dmp_root`.
- Optional page callbacks, all 0 by default:
  - `draw(rdi = page)` after the list: the preview pane or any extra content.
  - `key(edi = DIK) -> eax = 1 consumed` before the generic keys.
  - `rows() -> eax = n` dynamic rows shown before the registered items (for lists built at run
    time, e.g. the models of the current style); `rowfmt(edi = row, rsi = buf)` writes the row
    label; `rowchange(edi = row, esi = -1 / +1 / 0 enter)`.
- Item kinds: `DM_ACTION` (data = fn, run deferred on the game's side), `DM_FLAG` (data = a
  byte toggled 0/1), `DM_VALUE` (data = `dmv_x` = `{change(esi = dir), fmt(rdi = text end)}`,
  `DMVALUE x` makes the pair from `dm_x_change` / `dm_x_fmt`), `DM_PAGE` (emitted by `DM_PAGE`).
  Every page gets `Back` (or `Close` on the root) as its last row automatically.
- `order`: rows sort by it (ties keep link order); leave gaps of 10.

### Runtime

- First open: `dm_build` walks `__dm_items` once and makes a sorted row array per page.
- `dm_page` is the current page; each page remembers its selection and scroll offset.
- Up to `DM_VISIBLE` (16) rows show at once; a scroll bar appears when there are more.
- `dm_defer(rdi = fn)`: queue a function for the game's side of the frame (`hk_DrawUI`, after
  the `DM_FRAME` hooks). Actions and spawners use it.

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

### Reusable components

- `dm_text_at(rdi = ASCII, esi = x, edx = y, ecx = 1 highlighted)` — game font text at any spot.
- `dm_rect(edi = x1, esi = y1, edx = x2, ecx = y2, r8d = argb)` — a flat box.
- `dm_sprite(rdi = DMSPRITE*)` — any sprite: `DS_TYPE` (SPRITE_TYPE 2 car, 3 ped, 4 code
  obj, 5 map obj, 6 user, 7 font), `DS_ID` (relative to the type's base), `DS_PAL` (palette
  kind), `DS_REMAP`, `DS_X`/`DS_Y` centre, `DS_BOX` fit size (0 = use `DS_SCALE` percent),
  `DS_ROT` (1440 per turn). It looks up the sprite's w/h in the style to fit it into the box.
- `dm_text_w(rdi = ASCII) -> eax` — a string's width in 640x480 units at the menu's text
  size (`GetGTATextWidth` `0x4CB0C0`). The list box grows to its title and visible rows
  (at least `DM_W_MIN`), so nothing leaves it; a pane measures its own lines the same way.
- `dm_pane(esi = y1, ecx = y2, edx = width)` — the pane frame right of the list box; its
  content starts at `[dm_pane_x]` (set every frame from the box's measured width).
- `dm_sprite_wh(edi = type, esi = id) -> eax = w | h << 8` — a sprite's size.
- `dm_toast_set(rax = string)` — the message line at the bottom.
- `dm_player_ped`, `dm_car`, `dm_spawn_car` (model = `dm_spawnable[dm_model]`, returns the
  Car*), `dm_call_car` (a fastcall on a Car*) — shared game helpers.
- `dm_spawn_pos(rdi = out dd[4], esi = distance SCR_f) -> eax` — where spawners put things:
  SCR_f x, y, z and the rotation, that far in front of the player on foot, facing the same way
  (`DM_SPAWN_DIST` = 1.5 blocks for cars and objects, 1 block for peds); eax = the
  player's Sprite*, or 0 with rdx = a toast string (no player, in a car). `dm_spawn_car`,
  `spawn_ped.asm` and `spawn_object.asm` use it.
- `dm_car_info(edi = model) -> eax = CarInfo*` or 0 — `g_StyleData 0x670684 +0x5C` →
  `AllCarsInfo.cars[model]` (re/ `GetCarInfoById` 0x4BF1F0).
- `dm_gxt(rdi = key, rsi = out, edx = size)` — game text (`Gxt_FindTextW` 0x4C2120 on
  `g_LocaleSettings` 0x671550) as ASCII.

All layout is in 640x480 units, scaled by the main camera's `uiScale` like the HUD.

## 5. How to add a page (recipe)

1. Create `host/menu/<thing>.asm`. `build.sh` includes every file there.
2. Declare the page and its rows. The page's link shows up on the parent by itself:

```nasm
; host/menu/hello.asm — a minimal page under the root
section .data
    DM_PAGE  dmp_hello, dmp_root, 90, "Hello"
    DM_ITEM  dmp_hello, 10, DM_FLAG,   "A toggle: ", hello_flag
    DM_ITEM  dmp_hello, 20, DM_ACTION, "Say hi", hello_say
section .text
hello_say:                          ; runs on the game's side of the frame
    lea rax, [s_hello]
    jmp dm_toast_set
section .rodata
s_hello: db "Hi", 0
section .bss
hello_flag: resb 1
```

3. Need graphics? Give the page a `draw` callback and call `dm_sprite` from it.
   Need a list built at run time? Give it `rows` / `rowfmt` / `rowchange`.
4. Need per-frame work (an overlay, a watchdog)? `DM_FRAME order, fn` in the same file.
5. `host/build.sh`, run, open K.

Adding an entry to an existing page is one line in your module:
`DM_ITEM dmp_vehicle, 45, DM_VALUE, "Turbo: ", dmv_turbo`.

`host/menu/spawn_car.asm` is built exactly this way (a page under `dmp_spawn` with dynamic
rows: `rows` lists the style's models, `rowfmt` names them, `rowchange` takes LEFT / RIGHT as
the remap and RETURN as "spawn" through `dm_defer`; a `draw` callback with `dm_pane` and
`dm_sprite`) and is the worked example for larger pages. It needed no line outside its file.

## 6. Pages today

- **root** (`debug_menu.asm`): Quick save, Get all weapons, Add $100000, Camera zoom; Ped
  paths (`debug_paths.asm`), Mouse turning and Strafe (`player_move.asm`); links.
- **Player** (`menu/player.asm`): wanted level and lock, skin, body; roadblocks
  (`debug_roadblocks.asm` registers them), ambulance / fire truck (`debug_emergency.asm`).
- **Vehicle** (`menu/vehicle.asm`): the current / last car, colour, invincible, repair, explode.
- **Spawn** (`menu/spawn.asm`): a group page for spawners.
  - **Car** (`menu/spawn_car.asm`): every spawnable car model of the current style, its
    name from the GXT, sorted by the style's rating (99 special first, then good, average,
    bad; DMA's GTA2 Style Format), LEFT / RIGHT picks the remap (game's random, none, or each of the
    model's own remaps), a rotating preview with that remap at 2-3x size, size / seats /
    rating class / remap count; RETURN spawns it 1.5 blocks in front of the player with that remap.
  - **Ped** (`menu/spawn_ped.asm`): one row per ped remap 0..52 (the look), named from the
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
  - **Object** (`menu/spawn_object.asm`): every world object type the level's prefab table
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
    200..244 `Object_NewPhysicsObjUnlessBlocked`, the rest `SpawnObject`), so it gets the
    collision grid, a pickup its default ammo and is collectable; "Blocked here" when the
    game refuses (something in the way, a full pool). Not offered: projectiles, particle
    systems, lights, logic and car-shop objects, crane / crusher parts, the moving pickup
    clones 64..108, the bonus token (it would use up one of the level's token flags), the
    bonus letters (GXT "na"; picking one up would call AddWeapon with a letter's index) and
    ringing / in-call phones (touching one answers it through the mission script). Seq 27's
    notes on what is safe: `seq52_prep.md` (Seq 27 report).
- **Debug flags** (`menu/flags.asm`): the game's own flags; Road network (`debug_roads.asm`).

## 7. RE facts used (sources)

| What | Address | Source |
|---|---|---|
| `DrawSprite2D` stdcall, 11 args, `RET 0x2C` | `0x4CBA50` | own disassembly + Seq 27 report |
| `Hud_DrawSprite2DScaled` (HUD wrapper, scale = uiScale, a11 = 0) | `0x4C71B0` | own disassembly + Seq 27 |
| `GetSpriteIndex` = `spriteBases[type-2] + id` | `0x4BF2A0` | own decompile |
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
| `PedSetObjective` thiscall(Ped*; objective, timer) RET 8 (clears the target), `Ped_SetObjTargetPed` thiscall(Ped*; Ped*) | `0x43BBC0`, `0x403AC0` | Seq 27, SET_CHAR_OBJECTIVE handler 0x47A1E0 |
| `PedGroupCreate` fastcall(Ped* leader, edx; byte n), `PedGroupAddPed` fastcall(PedGroup*, 0; Ped*), `Ped.group` +0x164, `PedGroup.membersCount` +0x34 (max 8) | `0x440350`, `0x404C90` | Seq 27, re/gta2_types.h |
| Ped frames: graphicType * 158 + anim, walk = 0..7; DrawSprite2D palette kind 4 takes the raw PED_REMAP | `0x497DF0`, `0x4C2AC0` | Seq 27 + style render (`bun tools/formats/cli.ts sty --sprite`) |
| ped pool `PedManager_S25*` +0 freeListHead; Ped +0x238 class, +0x240 occupation, +0x17C gang, +0x288 / +0x28C threat search / reaction | `0x5E5BBC` | re/gta2_types.h, Seq 27 |
| `SpawnCar`, TrafficManager, CarsScale | `0x426AC0`, `0x5E4CA4`, `0x5E4D4C` | gta2-seuko-mod `spawn-car.cpp` |
| `g_ObjectPrefabsContainer` (+0x87F4 `ObjectPrefab* byId[300]`), `ObjectPrefabs_Get` | `0x665B40`, `0x488170` | re/globals.csv, re/gta2_types.h, docs/re/objects-and-weapons.md |
| `ObjectPrefab`: +0x1C remap, +0x1E sprite id, +0x28 sprite type (4 / 5), +0x30 palette kind, +0x34 kind, +0x40 grid, +0x44 impact, +0x48 explosive, +0x64 ticks/frame, +0x6C frames | — | re/gta2_types.h; +0x28 goes to `Sprite_SetCollisionKind` in `ObjectPrefab_ApplyToPosition` `0x4883A0` (own decompile) |
| Style map objects become prefabs, id = OBJI model | `0x488450` `ObjectPrefabs_InitFromStyle` | own decompile |
| `SpawnObject` / `Object_NewPhysicsObjUnlessBlocked` thiscall(`g_ObjectSpawner` `0x665788`; type, x, y, z, rot), ret 0x14, insert into the grid; the script picks by type 200..244 | `0x4852E0`, `0x485480`; `Script_Decl_OBJ_DATA_SET` `0x476EA0` | own disassembly + decompile |
| `ObjectSpawner_CreateObject`: default ammo for weapon pickups, bonus-token flags | `0x484E00` | own decompile |
| `StyleData` +0x10 palette counts (`PaletteBase`: +8 code obj, +0xA map obj remaps) | `0x670684` | re/gta2_types.h |

## 8. Next pages the structure makes cheap

- **Skin picker with preview**: the Player page's skin row gets a `draw` callback.
- **Car respray with preview**: the Vehicle page's colour row, same component.
- **Weapons page**: one row per weapon, HUD weapon icon as preview (user sprites, type 6).
- **Teleport**: dynamic rows from the map's zones (`gmp` zones).
- **Gang respect / cop level / time of day** sliders, **sprite browser** (any type, any id,
  any palette) as a debugging tool for RE.
