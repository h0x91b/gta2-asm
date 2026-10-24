# SDL3 renderer: dmavideo.dll + d3ddll.dll in host C

`host/c/renderer.c` (SDL setup, the `Vid_*` half, the frame loop: present, `--shot`,
`--frames`) and `host/c/renderer_gbh.c` (the `gbh_*` half: textures, palettes, drawing,
lighting, images) replace both renderer plugins the game loads with
`LoadLibraryA` (API recovered in [`renderer-api.md`](renderer-api.md)). With it,
`host/build.sh --load --entry` runs vanilla `gta2.exe` into its **frontend loop and
draws the original main menu** in the SDL3 window: background TGAs, the GTA2 logo,
PLAY / OPTIONS / QUIT text from `fstyle.sty`, the DMA and Rockstar logos.

It also draws **gameplay**: PLAY → the first level (Downtown, `wil`) with city tiles,
slopes, peds, cars, HUD and the original per-vertex point lighting (see "Gameplay" below).

## How the game reaches it

The plugins are ordinary shim tables, `shimtab_dmavideo` and `shimtab_d3ddll` (listed in
`w32_tables.asm`), kept in NASM in `host/w32_renderer.asm`; each handler is a C import
handler `uint64_t f(const uint32_t *args)` (`docs/host-c.md`, "Import shims in C"). Every name in a shim table is a "system" module, so
`LoadLibraryA("dmavideo.dll")` returns a fake HMODULE and each of the 22 + 41
`GetProcAddress` calls gets a stub bound to our handler with the right stdcall pop. No
DLL code runs. The d3ddll↔dmavideo coupling (d3ddll patching four of gta2.exe's
`Vid_*` slots) is dropped: both sides are ours, so the observable behaviour is kept
directly (BeginScene unlocks the 2D surface, EndScene re-locks it).

## Backend

**SDL_Renderer** (option 1 of renderer-api.md §5.1). The macOS run picks the `metal`
renderer.

| piece | what it is |
|---|---|
| back buffer | an `ARGB8888` render-target texture of the game's windowed size, `window_width × window_height` (1280×960 by default, never smaller than 640×480; see "Resolution"). All drawing goes into it. |
| present | `Vid_FlipBuffers`: the top-left 640×480 of the render target in the frontend, all of it in gameplay → window, letterboxed by `SDL_SetRenderLogicalPresentation(w, h, LETTERBOX)` on the window target (re-set when the size changes), linear scaling, vsync on. The window is exactly the size the game asked for. |
| 2D surface | an `RGB565` CPU buffer of the back buffer's size (pitch = width × 2) in low memory, handed out as `ctx->surface` by `Vid_GetSurface` (Bink writes there). If the game locked it since the last upload, it is uploaded to a streaming texture and drawn into the back buffer at `gbh_BeginScene` (under the 3D primitives) or at `Vid_FlipBuffers` (Bink-only frames). `Vid_ClearScreen` clears both. |
| textures | up to 262 143 (`MAX_TEX`; `wil` registers 73 104, plus ~29 000 for the frontend, which are not freed). `gbh_RegisterTexture` allocates a real 0x20-byte `GbhTexture` in low memory (the game pokes `width/height/pixels`) plus a host cache entry (index in `GbhTexture.cache`). On draw, the 8-bit indices (pitch 256) are expanded through the palette into an `ARGB8888` SDL texture of exactly `w×h`, index 0 = `0x00000000` (transparent only in the blended modes, see below). The cache key is (pixels, width, height, palette, palette generation), and Lock/Unlock/AssignPalette mark it dirty, so retargeted textures rebuild. |
| palettes | `gbh_RegisterPalette` copies the 256 colours (stride 64 dwords) into a host table as `0xFF000000 \| rgb`, and applies the original's in-place edits to the game's data (`pal[0] = 0`, other zeros → `0x10000`). Re-registering bumps the palette's generation. |
| tiles | `gbh_DrawTile` (= `gbh_DrawTilePart`, d3ddll `0xe043f0`): unless `GBH_F_TILE_CUSTOM_UV`, UVs = 0.5…63.4999 of the 64×64 tile; rotate `0x20` (new[i] = old[i+3]), `0x40` (= both mirrors), `0x60` (new[i] = old[i+1]), FLIPX swaps the (u,v) of vertices 0↔1 / 2↔3, FLIPY 0↔3 / 1↔2; written back into the caller's vertices like the original; then the DrawQuad path. |
| lighting | `GBH_F_LIGHTING` and ambient ≠ 1.0 (as the original): per vertex `c' = min(1, c · brightness/255 · Σ light.c · I · (r − d)/r + ambient)` over the type-1 lights of `gbh_AddLight` with d ≤ r; the vertex's world position is `v[i+4].x/y/z` (d3ddll `ApplyPointLightsToVertices`). `gbh_AddLight` precomputes I = packed&0xff /255, r = (packed>>8 &0xff)/255·8, r², 1/r, rgb/255; `gbh_ResetLights` empties the list (≤ 1024, logged once if exceeded). The original's table square root is `sqrtss`. |
| quads | `gbh_DrawQuad` / `gbh_DrawTriangle` → `SDL_RenderGeometry` (fan of 4 = indices `0 1 2 0 2 3`). Fix-ups from §2.3: cull on `v[0].z <= 0`; UVs are texels → divided by the texture size; `GBH_F_SPRITE_RECT` builds the `w×h` quad from `v[0].x/y`; diffuse = brightness grey unless `GBH_F_VERTEX_COLOUR` (alpha from diffuse only in the blended modes); blend `NONE` in opaque mode (`flags & 0x380 == 0`), `BLEND` for `0x80`/`0x100`, `ADD` for `0x200` (see "Index 0: transparent only when blended"); `NEAREST` for `GBH_F_NO_FILTER`/`SPRITE_RECT`, else `LINEAR`. `rhw` ignored (screen-space, affine). |
| flat rects | `gbh_DrawFlatRect` → untextured geometry, alpha-blended by the colour's alpha. |
| images | `gbh_LoadImage` parses the in-memory TGA (type 2, 16 bpp, bottom-up unless descriptor bit 5) into an `XRGB1555` texture; `gbh_BlitImage` checks the source rect like the original (−1 bad handle, −2 bad rect) and does `SDL_RenderTexture`. Never returns −10 (surface lost). |

All SDL functions are `dlsym`'ed from the handle `setup_user32` opened (`sdl_lib`):
SDL stays dlopen'ed, see AGENTS.md.

## Export status

dmavideo (all 22 resolve):

| export | status |
|---|---|
| `Vid_InitDLL`, `Vid_Init_SYS`, `Vid_CheckMode`, `Vid_FindDevice`, `Vid_SetDevice`, `Vid_FindMode`, `Vid_FindFirstMode`, `Vid_FindNextMode` | real. One device (id 1, can render windowed), one mode (id 1 = 640×480×16, RGB565). The VidCtx, device and mode lists live in low memory with the original layout. |
| `Vid_SetMode` | first call creates the renderer on the game's SDL window; back buffer + CPU buffer are (re)created whenever the wanted size changes: windowed (-2) = `window_width × window_height` (read from the game, `0x673578`/`0x6732e8`), any other mode = 640×480, at least 640×480. `fullscreen = (mode != -2)`; returns 0. Fullscreen requests stay windowed. The advertised mode list stays one 640×480 mode. |
| `Vid_CloseScreen` | `mode_id = 0`; the renderer survives mode changes, so nothing has to be invalidated |
| `Vid_GetSurface`/`GrabSurface`/`EnableWrites`, `Vid_FreeSurface`/`ReleaseSurface`/`DisableWrites` | real (CPU buffer, flags 1\|2) |
| `Vid_FlipBuffers`, `Vid_ClearScreen` | real |
| `Vid_SetGamma` | returns 0, no gamma ramp |
| `Vid_WindowProc` | returns 0 (as the original) |
| `Vid_ShutDown_SYS` | destroys the renderer |
| `Vid_GetVersion` | silent stub (not called by the game) |

d3ddll (all 42 resolve): real `gbh_InitDLL`, `gbh_Init`, `gbh_GetGlobals` (low-memory
stats block, `polys_drawn` counted), `gbh_SetWindow` (stored), `gbh_BeginScene`,
`gbh_EndScene`, `gbh_RegisterPalette`, `gbh_FreePalette`, `gbh_RegisterTexture`,
`gbh_FreeTexture`, `gbh_LockTexture`, `gbh_UnlockTexture`, `gbh_AssignPalette`,
`gbh_DrawQuad`, `gbh_DrawTriangle`, `gbh_DrawTile` / `gbh_DrawTilePart`,
`gbh_DrawFlatRect`, `gbh_InitImageTable`, `gbh_LoadImage`, `gbh_BlitImage`,
`gbh_FreeImageTable`, `gbh_SetAmbient`, `gbh_ResetLights`, `gbh_AddLight`,
`gbh_CloseScreen` (= `Vid_CloseScreen`).

**Deliberate no-ops** (the original is empty too, or nothing of ours depends on it):
`ConvertColourBank` (empty in the original), `MakeScreenTable` (row table for the
software `gbh_PrintBitmap`, never called), `gbh_SetColourDepth` (we always use 565),
`gbh_CloseDLL`, `gbh_BeginLevel`/`EndLevel` (empty), `gbh_Plot`, `DrawLine`,
`SetShadeTableA`, `gbh_BlitBuffer` (empty), `gbh_GetUsedCache` (0, debug overlay only),
`gbh_SetCamera` (stores the 4 floats like the original; nothing in d3ddll reads them back
for drawing).

**Silent stubs** (return 0, log the first call, correct pop) remain only for exports the
game never calls (renderer-api.md §2.2): `gbh_DrawQuadClipped`, `gbh_ConvertColour`,
`gbh_Convert16BitGraphic`, `gbh_PrintBitmap`, `Vid_GetVersion`. None of them fired in a
900-frame gameplay run.

## Loader flags added

| flag | effect |
|---|---|
| `--frames=N` | exit (status 0) after N presented frames |
| `--shot=PATH` | with `--frames`, save the presented part of the last frame's back buffer as BMP (`SDL_RenderReadPixels` + `SDL_SaveBMP`): 640×480 in the frontend, the window size in gameplay |
| `--window=WxH` | (`win32-shims.md`) override `screen\window_width/height` for the run: window size and gameplay resolution |

Example: `host/build.sh --load --entry --frames=300 --shot=/tmp/menu.bmp`.

## Parity harness (Seq 63, 2026-10-23)

`tests/ctl/render_parity.sh [OUT_DIR]` (gta2ctl) takes 18 screenshots at fixed presented
frames: the main menu (60, 120), PLAY's screen (200), Downtown's first seconds (270-420), the
K menu root and its Debug flags page (440, 460), a teleport to the plaza (740), a spawned car
(760), driving it (860), on foot again (900), the road overlay on and off (960, 1020) and the
in-game quit prompt (1040, 1060). Every input is frame-scheduled and the level starts from the
same seed, so two runs of one build give byte-identical BMPs: compare two builds with `cmp`
(`LOADER=/path/to/other/loader` runs another binary, `WINDOW=640x480` another size). It also
writes `time.txt` (`/usr/bin/time -l`) and `flips.txt` (the wall time of every 120-frame
stats line).

The NASM → C port (Seq 63) was accepted on it: two master runs identical to each other, two
port runs identical to master (all 18 shots at 1280x960 and at 640x480, plus `--frames=300
--shot` in the menu and `--frames=500 --shot` in play at 960x720), and every `[vid]`/`[gbh]`
log line identical, counters included (flip 960: 193 661 quads, 499 blits, 748 texture
uploads). The C keeps the asm's single-precision operation order (`FP_CONTRACT OFF`, the same
`1/255` constant `0x3b808081`, multiply by reciprocals where the asm did). Time in the
renderer's import handlers (everything but `Vid_FlipBuffers`), measured with the same
temporary probe in `host_dispatch` for both builds: 2.379 ms/frame (master) vs 2.388 ms/frame
(C), 12 windows of 120 frames each, within the run-to-run spread (2.34-2.44); nearly all of it
is SDL/Metal itself, at ~300 renderer calls per in-game frame. The game paces itself to
~30 fps (`drawAndLimitFrames` busy-waits), so process CPU time (32 s user both) says nothing.

Running two games in parallel (two `render_parity.sh` at once) is **not** deterministic: from
frame 740 on the camera lands elsewhere. Compare builds with sequential runs.

### Index 0: transparent only when blended (Seq 65, 2026-10-24)

d3ddll uploads a texture in the format of the draw's blend mode (`UploadTextureToCacheSlot`
`0xe02810` → `ConvertIndexedPixelsToSurface` `0xe061d0`): with `flags & 0x380 == 0` it goes to
an opaque page through the palette's opaque table with an alpha mask of 0, so index 0 is drawn
as `pal[0]` = solid black and nothing is keyed; with `0x80`/`0x100`/`0x200` it goes to an alpha
page and index 0 becomes alpha 0, culled by the alpha test. We keep the one ARGB texture
(index 0 = `0x00000000`) and get the same result from the blend mode: `SDL_BLENDMODE_NONE` for
opaque draws writes index 0 as black, `BLEND`/`ADD` make it transparent. (d3ddll keeps a cached
page in its first format until evicted, unless the texture's byte `+0x13` has bit `0x80`; we
follow each draw's flags instead.)

Map faces get `0x80` from face bit 12 ("flat"), so flat walls and lids stay see-through. In a
gameplay run 126 k of 141 k blended draws have index-0 texels (flat faces, sprites) and only 29
of 259 k opaque ones do: diagonal faces (`0xc005`), which never test bit 12. The parity harness
changed by 24 pixels (a see-through sliver of a diagonal wall in the start view, frames 270-480),
nothing else. The "missing building faces" report was not explained by this: a counting build
of the same run dropped **no** primitive in `draw_prim` (no `v[0].z <= 0` cull, no texture that
failed to build) either, so any remaining hole is either not submitted by the game's map renderer
or overdrawn (no depth buffer, primitives land back to front). The `gbh_SetWindow` cull rect is
stored and ignored, so we draw more than the original, never less.

## Real output (2026-10-20)

`host/build.sh --load --entry --frames=300 --shot=…/shot1.bmp`; the PE-loading part,
the 15 function checks, the CRT/WinMain lines (unchanged from `win32-shims.md`) and the
63 `GetProcAddress(dmavideo.dll|d3ddll.dll, …) -> … (shim)` lines are omitted:

```
  [w32] LoadLibraryA(dmavideo.dll) -> 0x7f0d0000
  [vid] Vid_Init_SYS -> ctx 0x2000de30 (1 device, mode 1 = 640x480x16 RGB565)
  [w32] ShowWindow(0xab0000): SDL_ShowWindow -> 1
  [w32] ShowWindow(0xab0000): SDL_ShowWindow -> 1
  [vid] SDL renderer 'metal', back buffer 640x480 ARGB8888 target, letterboxed
  [vid] Vid_SetMode(mode -2, hwnd 0xab0000) -> 640x480
  [w32] LoadLibraryA(d3ddll.dll) -> 0x7f0e0000
  [vid] flip 1: 0 quads, 0 blits, 0 texture uploads so far
  [w32] ShowWindow(0xab0000): SDL_ShowWindow -> 1
  [gbh] gbh_Init: SDL_Renderer backend
  [w32] silent stub mss32.dll!_AIL_startup@0 -> 0 (first call from 0x4b7259)
  ... (8 more mss32 first calls: set_preference, waveOutOpen, allocate_sample_handle,
       init_sample, set_sample_type, mem_alloc_lock, waveOutClose, shutdown)
  [w32] FindFirstFileA(data\movie\intro.bik) -> no match
  [w32] IDirectInput8A::CreateDevice(keyboard) -> 0x200cc480
  [w32] silent stub DINPUT8!IDirectInputDevice8A::SetDataFormat -> 0 (first call from 0x453dc7)
  [w32] silent stub DINPUT8!IDirectInputDevice8A::SetCooperativeLevel -> 0 (first call from 0x453df0)
  [w32] silent stub DINPUT8!IDirectInputDevice8A::Acquire -> 0 (first call from 0x451ff0)
  [w32] FindFirstFileA(player\plyslot1.svg) -> no match
  ... (plyslot2..7.svg, no match)
  [gbh] gbh_LoadImage -> slot 0 (362x480)
  [gbh] gbh_LoadImage -> slot 1 (278x480)
  ... (slots 2-22)
  [gbh] gbh_LoadImage -> slot 23 (451x144)
  [gbh] gbh_LoadImage -> slot 24 (640x480)
  [vid] flip 120: 2737 quads, 238 blits, 19 texture uploads so far
  [vid] flip 240: 5497 quads, 478 blits, 19 texture uploads so far
  [vid] back buffer saved to …/shot1.bmp (frame 300)
  [vid] --frames: 300 frames presented, exiting
```

Exit status 0. Per menu frame: 2 `gbh_BlitImage` (left 278×480 + right 362×480 halves)
and 23 `gbh_DrawQuad` (glyphs and logos); 19 distinct textures in total, uploaded once.
The intro movie is skipped by the game itself: `data\movie\intro.bik` does not exist in
this install (registry `do_play_movie` = 0). Without `--frames` the game sits in the
frontend loop until the window is closed.

Verified by eye: the back-buffer BMP and a `screencapture -l <window id>` of the real
960×720 window both show the main menu as in the original (left taxi/crosshair photo,
black right half, GTA2 logo, PLAY highlighted red, OPTIONS, QUIT, DMA + Rockstar logos,
`GTA2 V0.0`).

## Gameplay (2026-10-21)

`host/build.sh --load --entry --keys=150:RETURN,250:RETURN --frames=900 --shot=…`: the
first RETURN opens PLAY, the second starts Downtown. The level loads (`e.gxt`, `wil.sty`,
`wil.gmp`, `wil.RAW/SDT`, the `wil_*.SCR` scripts), and the game loop runs; exit 0 after
900 frames (~640 of them in-game). Stats line at frame 840: 102 383 primitives drawn,
499 blits, 295 texture uploads, 73 104 textures registered. Per in-game frame about
150 primitives (tiles, slope triangles, peds, cars, HUD glyphs), nearly all with
`GBH_F_LIGHTING`; the world is drawn with ambient 0.3, the HUD with 1.0.

A screenshot shows the city from above, the player in the middle of the screen, peds,
the district name banner (`AVALON`), the respect bars on the left and money, the
multiplier and lives on the right.

## Resolution (2026-10-21)

Gameplay renders natively at the window size; the frontend stays 640×480.

- **Where the size comes from.** Windowed play (`start_mode` 0, the install's choice):
  `SetWindowedMode` `0x4cb730` resizes the window to `screen\window_width ×
  window_height` (globals `0x673578` / `0x6732e8`) and calls `Vid_SetMode(ctx, hwnd, -2)`.
  Every frame `BeginFrame2D` `0x4caec0` takes the view size from those two globals when
  `ctx->mode_id == -2` (else from `ctx->width/height`), stores `w-1`/`h-1` at
  `0x673584`/`0x673474` and passes them to `gbh_SetWindow`; gameplay centres the camera
  and anchors the HUD on that size. So `Vid_SetMode` sizes the back buffer to the same two
  globals (at least 640×480) — the host sets both values to 1280×960 after
  seeding the registry (the install's are 960×720), and `--window=WxH` picks others.
- **Frontend vs gameplay.** The frontend draws at fixed 640×480 coordinates into the
  top-left of the same back buffer; a flip presents that 640×480 part, letterboxed into the
  window. Gameplay is told apart by `ptrToGame` (`0x5EB4FC`, seuko-mod `memory.h`): set by
  `InitGame` `0x461de0`, zeroed by `DeinitGame` `0x462060`. While it is set, the flip
  presents the full `window_width × window_height`. The presented size is logged when it
  changes (`[vid] presenting WxH of the back buffer (flip N)`).
- **What a bigger window shows.** Measured on the frame-900 shots of the same run
  (downscale each by k, centre-crop, mean absolute grey difference against the 640×480
  shot, best k): 960×720 matches at k = 1.5 (diff 1.3/255), 1280×960 at k = 2.0 (1.2),
  1280×720 at k = 2.0 against the centre 640×360 of the 640×480 view (1.9). So the game
  scales the view with the window **width**: every 4:3 size shows exactly the same city,
  just sharper (the HUD scales too), and a wider-than-4:3 window keeps the horizontal
  extent and crops top and bottom (1280×720 shows 75 % of the 4:3 height). More pixels,
  not more city.
- **Checked**: `--window=1280x720 --keys=150:RETURN,250:RETURN,600:ESCAPE --frames=660`
  draws the in-game quit prompt ("Is that it?") centred at 1280×720. The main menu at
  the default size is unchanged (640×480 shot). Quitting play (`…,660:RETURN`) reloads
  the frontend, which then saw the confirming RETURN still held and started the level
  again (a new game, so `ptrToGame` was set again). Fixed in the DirectInput shim: keys
  held at `Acquire` read as up until released (`docs/win32-shims.md`, "Input"); the
  "PLAYER QUIT!" screen now appears.

## Known gaps

- **Input**: none yet (DirectInput reports nothing pressed), so the menu cannot be
  navigated. Owned by the parallel input task.
- **Version string** shows `V0.0`: `GetFileVersionInfoSizeA` reports no version
  resources (`win32-shims.md`). Reading `VS_VERSION_INFO` from the exe's `.rsrc` would
  fix it.
- **Resolution**: only windowed sizes; the frontend stays 640×480 letterboxed (hard-wired
  in the game). See "Resolution".
- **Lighting** follows the decompiled original, but has not been compared against a
  Windows run of the same scene; the level looks dark and greenish-tinted (ambient 0.3).
- **Depth/z**: none (back-to-front like the original).
- **Translucency modes** `0x80`/`0x100` use the diffuse alpha only when
  `GBH_F_VERTEX_COLOUR` is set, as derived from the original; not checked against
  gameplay sprites yet.
- **Gamma**: `Vid_SetGamma` is a no-op.
- **Fullscreen**: mode ids > 0 stay windowed; no `SDL_SetWindowFullscreen`.
- **Bink path**: implemented (CPU buffer upload at flip) but not exercised — no movie
  plays in this install.
- **Colour depth**: textures are 8888/1555 rather than the original's 565 surfaces, so
  colours are slightly more precise than on Windows; the CPU buffer is 565 as the game
  expects.
- **Surface lost / mode re-set**: the renderer is never recreated; `gbh_BlitImage`
  never asks for an image reload.
