# SDL3 renderer: dmavideo.dll + d3ddll.dll in NASM

`host/w32_renderer.asm` replaces both renderer plugins the game loads with
`LoadLibraryA` (API recovered in [`renderer-api.md`](renderer-api.md)). With it,
`host/build.sh --load --entry` runs vanilla `gta2.exe` into its **frontend loop and
draws the original main menu** in the SDL3 window: background TGAs, the GTA2 logo,
PLAY / OPTIONS / QUIT text from `fstyle.sty`, the DMA and Rockstar logos.

It also draws **gameplay**: PLAY → the first level (Downtown, `wil`) with city tiles,
slopes, peds, cars, HUD and the original per-vertex point lighting (see "Gameplay" below).

## How the game reaches it

The plugins are ordinary shim tables, `shimtab_dmavideo` and `shimtab_d3ddll` (listed in
`w32_tables.asm`). Every name in a shim table is a "system" module, so
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
| back buffer | a 640×480 `ARGB8888` render-target texture. All drawing goes into it. |
| present | `Vid_FlipBuffers`: render target → window, letterboxed by `SDL_SetRenderLogicalPresentation(640, 480, LETTERBOX)` on the window target, linear scaling, vsync on. The window stays the size the game asked for (960×720 from the registry's `window_width/height`). |
| 2D surface | a 640×480 `RGB565` CPU buffer in low memory, handed out as `ctx->surface` by `Vid_GetSurface` (Bink writes there). If the game locked it since the last upload, it is uploaded to a streaming texture and drawn into the back buffer at `gbh_BeginScene` (under the 3D primitives) or at `Vid_FlipBuffers` (Bink-only frames). `Vid_ClearScreen` clears both. |
| textures | up to 262 143 (`MAX_TEX`; `wil` registers 73 104, plus ~29 000 for the frontend, which are not freed). `gbh_RegisterTexture` allocates a real 0x20-byte `GbhTexture` in low memory (the game pokes `width/height/pixels`) plus a host cache entry (index in `GbhTexture.cache`). On draw, the 8-bit indices (pitch 256) are expanded through the palette into an `ARGB8888` SDL texture of exactly `w×h`, index 0 = alpha 0. The cache key is (pixels, width, height, palette, palette generation), and Lock/Unlock/AssignPalette mark it dirty, so retargeted textures rebuild. |
| palettes | `gbh_RegisterPalette` copies the 256 colours (stride 64 dwords) into a host table as `0xFF000000 \| rgb`, and applies the original's in-place edits to the game's data (`pal[0] = 0`, other zeros → `0x10000`). Re-registering bumps the palette's generation. |
| tiles | `gbh_DrawTile` (= `gbh_DrawTilePart`, d3ddll `0xe043f0`): unless `GBH_F_TILE_CUSTOM_UV`, UVs = 0.5…63.4999 of the 64×64 tile; rotate `0x20` (new[i] = old[i+3]), `0x40` (= both mirrors), `0x60` (new[i] = old[i+1]), FLIPX swaps the (u,v) of vertices 0↔1 / 2↔3, FLIPY 0↔3 / 1↔2; written back into the caller's vertices like the original; then the DrawQuad path. |
| lighting | `GBH_F_LIGHTING` and ambient ≠ 1.0 (as the original): per vertex `c' = min(1, c · brightness/255 · Σ light.c · I · (r − d)/r + ambient)` over the type-1 lights of `gbh_AddLight` with d ≤ r; the vertex's world position is `v[i+4].x/y/z` (d3ddll `ApplyPointLightsToVertices`). `gbh_AddLight` precomputes I = packed&0xff /255, r = (packed>>8 &0xff)/255·8, r², 1/r, rgb/255; `gbh_ResetLights` empties the list (≤ 1024, logged once if exceeded). The original's table square root is `sqrtss`. |
| quads | `gbh_DrawQuad` / `gbh_DrawTriangle` → `SDL_RenderGeometry` (fan of 4 = indices `0 1 2 0 2 3`). Fix-ups from §2.3: cull on `v[0].z <= 0`; UVs are texels → divided by the texture size; `GBH_F_SPRITE_RECT` builds the `w×h` quad from `v[0].x/y`; diffuse = brightness grey unless `GBH_F_VERTEX_COLOUR` (alpha from diffuse only in the blended modes); blend `BLEND` (opaque mode too, it doubles as the index-0 alpha test) or `ADD` for `0x200`; `NEAREST` for `GBH_F_NO_FILTER`/`SPRITE_RECT`, else `LINEAR`. `rhw` ignored (screen-space, affine). |
| flat rects | `gbh_DrawFlatRect` → untextured geometry, alpha-blended by the colour's alpha. |
| images | `gbh_LoadImage` parses the in-memory TGA (type 2, 16 bpp, bottom-up unless descriptor bit 5) into an `XRGB1555` texture; `gbh_BlitImage` checks the source rect like the original (−1 bad handle, −2 bad rect) and does `SDL_RenderTexture`. Never returns −10 (surface lost). |

All SDL functions are `dlsym`'ed from the handle `setup_user32` opened (`sdl_lib`):
SDL stays dlopen'ed, see AGENTS.md.

## Export status

dmavideo (all 22 resolve):

| export | status |
|---|---|
| `Vid_InitDLL`, `Vid_Init_SYS`, `Vid_CheckMode`, `Vid_FindDevice`, `Vid_SetDevice`, `Vid_FindMode`, `Vid_FindFirstMode`, `Vid_FindNextMode` | real. One device (id 1, can render windowed), one mode (id 1 = 640×480×16, RGB565). The VidCtx, device and mode lists live in low memory with the original layout. |
| `Vid_SetMode` | first call creates renderer, back buffer, CPU buffer on the game's SDL window. Always 640×480, `fullscreen = (mode != -2)`; returns 0. Fullscreen requests stay windowed. |
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
| `--shot=PATH` | with `--frames`, save the back buffer of the last frame as BMP (`SDL_RenderReadPixels` + `SDL_SaveBMP`) |

Example: `host/build.sh --load --entry --frames=300 --shot=/tmp/menu.bmp`.

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

## Known gaps

- **Input**: none yet (DirectInput reports nothing pressed), so the menu cannot be
  navigated. Owned by the parallel input task.
- **Version string** shows `V0.0`: `GetFileVersionInfoSizeA` reports no version
  resources (`win32-shims.md`). Reading `VS_VERSION_INFO` from the exe's `.rsrc` would
  fix it.
- **Resolution** is fixed at 640×480 for the frontend and gameplay alike: the registry
  shim forces `screen\window_width/height` to 640×480 (`win32-shims.md`, Registry) and
  the SDL window shows it at 960×720. Native gameplay at the window size would need a
  back buffer of that size during gameplay only (the frontend is hard-wired to 640×480)
  and `Vid_SetMode` to honour it.
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
