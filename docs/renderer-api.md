# GTA2 renderer plugin API (dmavideo.dll + d3ddll.dll)

Spec for reimplementing the two renderer plugins on SDL3. Everything here was
recovered from the shipped binaries in `gta2/` (11.44 install), not from guesses:

| file | SHA-256 | base | exports |
|---|---|---|---|
| `dmavideo.dll` | `f5eb2e2f…5ce1d` | `0x1000000` | 22 `Vid_*` |
| `d3ddll.dll` | `dbf72c15…75a90` | `0xE00000` | 42 (`gbh_*` + 4 legacy) |

Method: throwaway headless Ghidra 12.1.4 imports of copies of both DLLs and of
`gta2.exe` (decompile + `objdump` for the spots the decompiler garbled), plus
raw byte scans of `gta2.exe` `.text` for every import slot. Afterwards both DLLs
were annotated in the user's Ghidra project `gta-2-recovered` (programs
`/d3ddll.dll`, `/dmavideo.dll`) with the same names, prototypes and types.
Machine-readable companions: [`renderer_api.h`](renderer_api.h) (C, the source
of the Ghidra types) and [`renderer_api.inc`](renderer_api.inc) (NASM `struc`s,
flags, export table with ordinals, arg bytes and gta2.exe slot addresses).

None of the three reference repos (seuko-mod, gta2-resurection, gta2-mouse)
documents this API; they only hook game code. `re/globals.csv` names a few
slots (`d3ddll_gbh_BeginScene` @ `0x595314`, `dmavideo_Vid_FlipBuffers` @
`0x595044`, …) and they agree with the table below.

## TL;DR for the SDL implementer

- **Everything is `__stdcall`** (callee pops, `ret N`), 32-bit, args 4 bytes each,
  return in EAX. Floats are passed as 4-byte stack slots, not on the FPU stack.
- **The game only runs in 16-bit colour.** It asks `Vid_CheckMode(ctx, w, h, 16)`;
  every surface the game or d3ddll writes is 16 bpp. The pixel layout (555 vs
  565) is whatever `VidCtx.r/g/b_shift/bits` say; **pick RGB565** and fill those
  fields (`r_shift 11 r_bits 5, g_shift 5 g_bits 6, b_shift 0 b_bits 5`).
- **The frontend/menu is not a framebuffer-blit path.** Each menu frame is:
  `gbh_BlitImage` the 640×480 background TGA halves (offscreen-surface blits),
  then `gbh_DrawQuad` every text glyph and sprite (textured, paletted, 8-bit
  sources), then flip. So the shortest path to a visible menu is
  ~24 small functions, below. No `gbh_DrawTile`/`DrawTriangle`/lighting needed.
- **The menu assumes 640×480**: backgrounds are blitted at fixed pixel coords
  (`0..278` + `278..640`, height 480). Run the game at 640×480 logical and let
  SDL scale.
- **Three structs are ABI**, because the game reads/writes their fields
  directly: `VidCtx` (returned by `Vid_Init_SYS`), `GbhTexture` (returned by
  `gbh_RegisterTexture`; the game rewrites `width`/`height`/`pixels`), and the
  32-byte `GbhVertex` (= `D3DTLVERTEX`). Everything else is opaque.
- If both DLLs are reimplemented, the d3ddll↔dmavideo coupling (d3ddll calls
  `GetProcAddress` on dmavideo and **patches four of gta2.exe's Vid_* slots**)
  can be dropped — just keep the observable behaviour (see §3.3).

## 1. Loading: how gta2.exe gets the plugins

All addresses gta2.exe VAs (own analysis of vanilla 11.44).

| step | where | what |
|---|---|---|
| names | `0x4cb3f0` | settings store (registry readers `0x4b5660` int / `0x4b5770` string): `renderdevice` → `0x673470`, `videodevice` → `0x673588`, `rendername` (default `d3ddll.dll`, ptr at `0x595008`) → buffer `0x673478`, `videoname` (default `dmavideo.dll`, ptr `0x59500c`) → buffer `0x6732f0`. Renderer kind `0x673580`: 0 = `softdll.dll`, 2 = `3dfx.dll`, else 1 (d3d). |
| window | WinMain `~0x4d13c0` | window created, `SetWindowPos`, DirectInput init `0x44ba00(hInstance)`, then `0x4cc6d0` |
| load dmavideo | `0x4d2e50(name)` | builds the slot table `0x675300` (22 ptrs to the slots `0x59501c..0x595070`, order: GetVersion, Init_SYS, CheckMode, FindDevice, SetDevice, FindMode, FindFirstMode, FindNextMode, CloseScreen, SetMode, FlipBuffers, ReleaseSurface, GrabSurface, ShutDown_SYS, EnableWrites, DisableWrites, GetSurface, FreeSurface, ClearScreen, WindowProc, InitDLL, SetGamma), `LoadLibraryA`, 22× `GetProcAddress` (any missing → `MessageBox "Error Patching DLL Function"`, fail), then **`Vid_InitDLL(hModule, 0x675300)`** |
| video init | `0x4cc6d0` | `ctx = Vid_Init_SYS(hInstance, 0)` → global `0x673d20`; `Vid_SetDevice(ctx, videodevice)`; if renderer kind == 1 `ctx->flags |= 0x40`; `0x4cb6c0` (returns 16, desktop depth check); `Vid_FindDevice(ctx, videodevice)->flags & 1` → "can window" `0x6735a4` |
| mode set | `0x4cc5c0` | `Vid_CloseScreen(ctx)`; `ctx->flags` bit 0x10 = `tripple_buffer`; windowed (`start_mode` 0): `0x4cb730` resizes the window to `window_width × window_height` and calls `Vid_SetMode(ctx, hwnd, -2)`; fullscreen (`start_mode` 1, default): `0x4cb570`: `id = Vid_CheckMode(ctx, full_width, full_height, 16)` (fallback 640×480), `ctx->flags |= 0x100`, `Vid_SetMode(ctx, hwnd, id)`, hide cursor, `WS_POPUP`. Then gamma (`0x4cb990`) |
| load d3ddll | `0x4cae50` → `0x4d4730(name, ctx)` | `0x4d3770`: `LoadLibraryA`, 40× `GetProcAddress` into slots `0x5952a8..0x595340` (+ `DrawLine` → `0x67535c`); then **`gbh_InitDLL(ctx)`**, `stats = gbh_GetGlobals()` → `0x675360` |
| first frame | `0x4cc6d0` tail | `Vid_ClearScreen(ctx,0,0,0, 0,0,w,h)`; `Vid_FlipBuffers(ctx)`; `Vid_ClearScreen(...)` again |
| d3d init | `0x4caea0` | **`gbh_Init(0)`** (after `ShowWindow/UpdateWindow`) |
| frontend | `0x457830` → `InitFrontend 0x456a60` | load `data\fstyle.sty`, register palettes/textures (`0x4c30a0`), `gbh_SetColourDepth()` + `ConvertColourBank` per 64 palettes (`0x4caeb0`), `gbh_SetAmbient(1.0f)`, `gbh_InitImageTable(25)` + 25× `gbh_LoadImage(tga)` (`0x452e20`) |
| shutdown | `0x4cb890` | `gbh_CloseDLL()` + FreeLibrary; `Vid_ShutDown_SYS(ctx)` + FreeLibrary |

Unloaded slots point at `0x4d2cf0` ("A DMA Video Function was called without the
DLL being loaded") / `0x4d35c0` (the GBH equivalent).

`gbh_CloseScreen`, `gbh_Convert16BitGraphic` are exported but not imported by
the game. `DrawLine`'s slot `0x67535c` is in `.bss`.

**Host shim consequence:** `LoadLibraryA("d3ddll.dll")` / `("dmavideo.dll")`
must return a fake HMODULE and `GetProcAddress` must resolve all 22 + 40 names
(plus `Vid_*` names again if the real d3ddll is ever used). Note the data files
are lower-case on disk (`data/frontend/1_play.tga`) while the exe asks for
`data\frontend\1_Play.tga`: the file shim must be case-insensitive and map `\`.

## 2. Export reference

Notation: `ctx` = `VidCtx*`. "DD"/"D3D" = what the original does internally
(DirectX 6 interfaces: IDirectDraw + IDirectDraw4, IDirectDrawSurface4,
IDirect3D3, IDirect3DDevice3). Return conventions differ per function: most
dmavideo calls return **0 = success, 1 = failure**.

### 2.1 dmavideo.dll

Ordinal = alphabetical. "slot" = gta2.exe pointer it is stored in. **Bold** = called
by gta2.exe at run time.

| ord | export | args (bytes) | returns | what it does / DirectDraw calls |
|---|---|---|---|---|
| 13 | `Vid_GetVersion()` | 0 | `VidVersion*` | static `{float 1.81; "DMA Video (Direct Draw implementation). Version…"}`. Not called by the game. |
| 16 | **`Vid_Init_SYS(HINSTANCE hinst, u32 flags)`** | 8 | `VidCtx*` or NULL | `LoadLibrary("ddraw.dll")` probe; alloc 0x4c4 ctx; flags: `0x40` kept, `0x400` use `DirectDrawEnumerateExA`, `0x800` skip mode enumeration. `DirectDrawEnumerateA` → device list (primary = id 1). For each device: `DirectDrawCreate`, QI IDirectDraw4, `GetCaps` (bit0 of device flags ← `dwCaps2 & DDCAPS2_CANRENDERWINDOWED`), `EnumDisplayModes` → mode list (`VidMode`, ids from 1). Default ctx flags `0x220`. Game passes `(hInstance, 0)`. |
| 1 | **`Vid_CheckMode(ctx, int w, int h, int bpp)`** | 16 | mode id or 0 | find mode on the current device (or any if none), set `found_*`. Game: bpp always 16. |
| 6 | **`Vid_FindDevice(ctx, int id)`** | 8 | `VidDevice*` or NULL | list lookup. Game tests `->flags & 1`. |
| 18 | **`Vid_SetDevice(ctx, int id)`** | 8 | 0 ok / 1 fail | if different from current: close screen, release DD objects, `DirectDrawCreate(guid)` + QI IDirectDraw4. id 0 just releases. Note: returns 0 also when nothing changed. |
| 8 | `Vid_FindMode(ctx, int id)` | 8 | `VidMode*` | lookup by id, sets `found_*`. Unused by game. |
| 7 | `Vid_FindFirstMode(ctx, int bpp)` | 8 | mode id or 0 | iterator over modes of that bpp (`find_iter`). Unused by game. |
| 9 | `Vid_FindNextMode(ctx)` | 4 | mode id or 0 | continue. Unused by game. |
| 3 | **`Vid_CloseScreen(ctx)`** | 4 | void | if a mode is set: `RestoreDisplayMode`, `SetCooperativeLevel(hwnd, DDSCL_NORMAL)`, release primary (and back buffer if windowed), `mode_id = 0`. **Slot is replaced by d3ddll** with `gbh_CloseScreen`. |
| 20 | **`Vid_SetMode(ctx, HWND hwnd, int mode_id)`** | 12 | 0 ok / 1 fail | closes the old screen. Fullscreen (`mode_id > 0`): switch device if the mode is on another one, `SetCooperativeLevel(hwnd, EXCLUSIVE\|FULLSCREEN\|ALLOWMODEX)`, `SetDisplayMode(w,h,bpp)`, primary flip chain (`DDSCAPS_PRIMARYSURFACE\|FLIP\|COMPLEX\|VIDEOMEMORY` + `3DDEVICE` if flag 0x40, 1 or 2 back buffers per flag 0x10, fallbacks), `GetAttachedSurface(BACKBUFFER)`, `GetSurfaceDesc` → pixel format into ctx `+0x58..+0x74`, `width/height`. Windowed (`-2`): `SetCooperativeLevel(NORMAL)`, primary surface + clipper on hwnd, offscreen back buffer of the client size (vidmem, or sysmem if flag 0x80; `3DDEVICE` if 0x40), `mode_id = -2`. `fullscreen = (mode_id != -2)`. **Slot hooked by d3ddll** (see §3.3). |
| 10 | **`Vid_FlipBuffers(ctx)`** | 4 | void | `IsLost`/`Restore` both surfaces (sets flag `0x10000000`). Fullscreen: `Flip(NULL, DDFLIP_WAIT [\|NOVSYNC if 0x200])`. Windowed: `Blt(client rect on screen ← back buffer, DDBLT_WAIT)`. |
| 14 | `Vid_GrabSurface(ctx)` | 4 | void | `Lock` back buffer (`DDLOCK_WAIT`) into `lock_desc`, flag \|= 1. |
| 17 | `Vid_ReleaseSurface(ctx)` | 4 | void | `Unlock`, flag &= ~1. |
| 5 | `Vid_EnableWrites(ctx)` | 4 | 0 / 1 | needs locked: `surface = lock_desc.lpSurface`, `pitch = lock_desc.lPitch`, flag \|= 2. |
| 4 | `Vid_DisableWrites(ctx)` | 4 | 0 / 1 | `surface = 0`, flag &= ~2. |
| 12 | **`Vid_GetSurface(ctx)`** | 4 | 0 ok / 1 | = GrabSurface + EnableWrites. After it, `ctx->surface/pitch` point at the back buffer. **Slot rerouted through d3ddll** (plain forwarder). |
| 11 | **`Vid_FreeSurface(ctx)`** | 4 | 0 / 1 | = DisableWrites + ReleaseSurface. **Slot rerouted through d3ddll** (forwarder). |
| 2 | **`Vid_ClearScreen(ctx, u8 r, u8 g, u8 b, int left, int top, int right, int bottom)`** | 32 | void | `Blt(DDBLT_COLORFILL)` on the back buffer, colour packed with the ctx shifts/bits; retries on `DDERR_SURFACELOST`/`WASSTILLDRAWING`. Game always clears `(0,0,0, 0,0,w,h)`. |
| 19 | **`Vid_SetGamma(ctx, float r, float g, float b)`** | 16 | 0 ok / 1 fail | QI `IDirectDrawGammaControl` on primary, build 3×256 ramps, `SetGammaRamp`. Game: `gamma` setting (default 10) × const; on failure retries for 30 frames. |
| 22 | **`Vid_WindowProc(ctx, HWND, UINT, WPARAM, LPARAM)`** | 20 | 0 | stub. Game calls it from its WndProc (`0x4d0db9`). |
| 21 | **`Vid_ShutDown_SYS(ctx)`** | 4 | void | close screen, release DD objects, free lists and ctx. |
| 15 | **`Vid_InitDLL(HMODULE self, void ***slot_table)`** | 8 | 0 | stores both globally; every later ctx gets them at `+0x7c`/`+0x84` (needed by d3ddll). |

Window-activation handling in the game (`~0x4d0b70`): when deactivated in a mode
that cannot run windowed → `Vid_CloseScreen` + minimise; on reactivation →
mode set again (`0x4cc5c0`) + `0x4cb880` (re-run `gbh_SetColourDepth`).

### 2.2 d3ddll.dll

Ordinal = alphabetical; `gbh_BeginLevel`=`gbh_EndLevel` and
`gbh_DrawTile`=`gbh_DrawTilePart` share an address. "menu" = needed for the
frontend (§4).

| ord | export | args (bytes) | returns | what it does / D3D calls | menu |
|---|---|---|---|---|---|
| 29 | **`gbh_InitDLL(VidCtx *ctx)`** | 4 | void | keep `ctx`, save FPU CW, `GetProcAddress(ctx->hmodule, "Vid_…")` ×21 (all but Vid_SetGamma) into its own table at `0xe10788` (missing → MessageBox, `FreeLibrary`), build sqrt table, **patch gta2.exe slots** via `ctx->slot_table`: CloseScreen ← `gbh_CloseScreen`, SetMode ← hook, GetSurface/FreeSurface ← forwarders. | ✔ |
| 28 | **`gbh_Init(int unused)`** | 4 | 0 ok / 1 fail | create renderer: QI IDirect3D3 from `ctx->ddraw`, enum D3D devices, pick by back-buffer bit depth, `CreateDevice` on `ctx->back`, viewport, enumerate texture formats (opaque 565/555 + alpha 1555/4444), allocate the texture cache (12 page sizes × N `IDirectDrawSurface4`+`IDirect3DTexture2` pairs, count scaled by free video memory), default render states (cull none, alpha test, clamp, Gouraud, dither, bilinear), detect RIVA/RagePro/Permedia quirks; then `gbh_SetColourDepth()`. Registry `HKCU\…\GTA2\Screen\special_recognition`. | ✔ |
| 11 | **`gbh_CloseDLL()`** | 0 | void | free cache + D3D device, **restore** the 4 gta2.exe slots, free tables. | ✔ (exit) |
| 12 | `gbh_CloseScreen(VidCtx*)` | 4 | void | free cache + D3D device, then the real `Vid_CloseScreen`. Installed into the game's CloseScreen slot. | (via slot) |
| 40 | **`gbh_SetColourDepth()`** | 0 | void | derive screen 16-bit packing (shifts, masks, 50% blend mask) from `ctx +0x58..+0x6c`. | ✔ |
| 14 | `gbh_ConvertColour(r, g, b)` | 12 | screen u16 | pack 8-bit RGB to the screen format. Not called by the game. | |
| 13 | `gbh_Convert16BitGraphic(u16 *px, int bytes)` | 8 | void | in-place 555 → screen format. Not imported. | |
| 1 | **`ConvertColourBank(void*)`** | 4 | void | **empty stub** (`ret 4`). Game calls it once per 64-palette bank. | ✔ (no-op) |
| 3 | **`MakeScreenTable(void *pixels, int pitch, int height)`** | 12 | void | fill a row-pointer table for the software `gbh_PrintBitmap`. Game calls it every frame after `Vid_GetSurface`. | ✔ (can be no-op) |
| 41 | **`gbh_SetWindow(float l, float t, float r, float b)`** | 16 | void | screen-space cull rect; primitives whose bbox is fully outside are dropped (no real clipping). Game: `(0, 0, w-1, h-1)` every frame. | ✔ |
| 8 | **`gbh_BeginScene()`** | 0 | void | if the 2D surface is locked (`ctx->flags & 1`), **unlock it via `Vid_FreeSurface`** and remember; reset stats, frame counter++, `IDirect3DDevice3::BeginScene`. | ✔ |
| 22 | **`gbh_EndScene()`** | 0 | void | `EndScene`; re-lock via `Vid_GetSurface` if BeginScene unlocked; frame time stat. | ✔ |
| 7 / 21 | `gbh_BeginLevel()` / `gbh_EndLevel()` | 0 | void | empty. Not called. | |
| 36 | **`gbh_RegisterTexture(u16 w, u16 h, u8 *pixels, int palette, char translucent)`** | 20 | `GbhTexture*` | malloc 0x20, nothing uploaded yet (lazy). `pixels` = 8-bit indices with **row pitch 256**. `translucent` only honoured on ATI RagePro. | ✔ |
| 25 | **`gbh_FreeTexture(GbhTexture*)`** | 4 | void | evict cache slot, free. | ✔ |
| 32 | **`gbh_LockTexture(GbhTexture*)`** | 4 | void | mark locked, evict cached upload. Game then writes `width/height/pixels`… | ✔ |
| 42 | **`gbh_UnlockTexture(GbhTexture*)`** | 4 | void | …and unlocks; next draw re-uploads. | ✔ |
| 6 | **`gbh_AssignPalette(GbhTexture*, int palette)`** | 8 | void | switch palette (evicts upload). | ✔ |
| 35 | **`gbh_RegisterPalette(int index, u32 *pal)`** | 8 | void | `pal` = 256 × `0x00RRGGBB` with **stride 64 dwords** (STY palette-page column). **Writes the caller's data**: `pal[0] = 0` (colour 0 = transparent) and any other 0 becomes `0x10000`. Converts to 2×256 u16 (opaque format, alpha format). | ✔ |
| 24 | **`gbh_FreePalette(int index)`** | 4 | void | free the converted table. | ✔ (exit) |
| 16 | **`gbh_DrawQuad(u32 flags, GbhTexture*, GbhVertex v[4], u8 brightness)`** | 16 | void | the workhorse, see §2.3. D3D: upload to cache if needed (8-bit → 16-bit through palette, index 0 → alpha 0), `SetTexture`, render states for flags, `DrawPrimitive(TRIANGLEFAN, XYZRHW\|DIFFUSE\|SPECULAR\|TEX1, v, 4, DONOTUPDATEEXTENTS)`. | ✔ |
| 20 | `gbh_DrawTriangle(u32 flags, GbhTexture*, GbhVertex v[3], u8 brightness)` | 16 | void | same, `TRIANGLELIST` of 3. Game: slopes (`0x46c210`). | |
| 18/19 | `gbh_DrawTile(u32 flags, GbhTexture*, GbhVertex v[4], u8 brightness)` | 16 | void | 64×64 map tile: unless `0x4000` sets UVs to 0.5…63.4999, applies tile rotate/flip flags (`0x60`,`0x08`,`0x10`) by permuting UVs, then DrawQuad. | |
| 17 | `gbh_DrawQuadClipped(flags, tex, v, brightness, float *clip)` | 20 | void | DrawQuad with a 2D clip (polygon splitter). Not called by the game. | |
| 15 | `gbh_DrawFlatRect(GbhVertex v[4], u32 argb)` | 8 | void | untextured: copies x,y,z of 4 verts, colour = `argb`, alpha blend + colour key off, `SetTexture(0, NULL)`, fan of 4. Game: UI boxes (`0x474110`). | (maybe) |
| 34 | `gbh_PrintBitmap(void *desc)` | 4 | void | software 8-bit → 16-bit blit into the `MakeScreenTable` rows (opaque/keyed/50% modes). **Not called** by the game. | |
| 30 | **`gbh_InitImageTable(int count)`** | 4 | 0 / -1 | allocate `count` `GbhImage` slots. Game: 25. | ✔ |
| 31 | **`gbh_LoadImage(void *tga)`** | 4 | slot index ≥ 0, or -1 table full, -2 bad format, -3 DD error | decode an in-memory **16-bit uncompressed bottom-up TGA** (A1R5G5B5) into an offscreen `IDirectDrawSurface4` in screen format (`CreateSurface`, `Lock`, convert, `Unlock`). | ✔ |
| 10 | **`gbh_BlitImage(int idx, int sl, int st, int sr, int sb, int dx, int dy)`** | 28 | 0, -1, -2, -3, -4, **-10 = surface lost** | `Blt(back buffer rect (dx,dy)-(dx+sr-sl, dy+sb-st) ← image rect (sl,st,sr,sb), DDBLT_WAIT)`. Rejects rects outside image/screen. On -10 the game reloads the TGA with `gbh_LoadImage` and blits again. | ✔ |
| 23 | **`gbh_FreeImageTable()`** | 0 | 0 | release all image surfaces. | ✔ (exit) |
| 9 | `gbh_BlitBuffer(6 args)` | 24 | 0 | stub. | |
| 38 | **`gbh_SetAmbient(float a)`** | 4 | void | ambient = a × 255 (used only by lighting). Frontend: 1.0. | ✔ (store) |
| 37 | `gbh_ResetLights()` | 0 | void | light count = 0. | |
| 5 | `gbh_AddLight(GbhLight*)` | 4 | void | append a point light (radius, 1/r, intensity, rgb). | |
| 39 | `gbh_SetCamera(float, float, float, float)` | 16 | void | stores 4 floats (game passes the visible world rect). | |
| 26 | **`gbh_GetGlobals()`** | 0 | `GbhGlobals*` | pointer to per-frame stats; game reads it for its debug overlay. Must be valid memory. | ✔ |
| 27 | `gbh_GetUsedCache(int page)` | 4 | count | cache slots used this frame (debug overlay). | |
| 33 | `gbh_Plot(float x, float y, float z, u16 colour)` | 16 | void | empty stub (game's debug line drawer `0x4caf60` calls it). | |
| 2 | `DrawLine(5 args)` | 20 | void | empty stub. | |
| 4 | `SetShadeTableA(5 args)` | 20 | void | empty stub. | |

### 2.3 Draw call semantics (DrawQuad / DrawTriangle / DrawTile)

Per call, in order (d3ddll `0xe02cc0`, `0xe04020`):

1. Cull: return if `v[0].z <= epsilon`, or the vertices' bbox is outside the
   `gbh_SetWindow` rect.
2. `GBH_F_SPRITE_RECT (0x10000)` (DrawQuad only): the game filled only
   `v[0].x, v[0].y, v[0].z`; the DLL builds an axis-aligned quad of
   `texture.width × texture.height` pixels at (x, y) with UV = whole texture, and
   forces `GBH_F_NO_FILTER`. (RIVA quirk: x/y rounded.)
3. Filter: `0x20000` → point sampling, else bilinear (`TEXTUREMAG/MIN`).
4. Blend (`flags & 0x380`): 0 → opaque (alpha test still culls index 0);
   `0x80`/`0x100` → `SRCALPHA/INVSRCALPHA`, `MODULATEALPHA`; `0x200` → additive
   `ONE/ONE`.
5. Texture: lazily uploaded into a cache page (power-of-two 8…256, edge texels
   duplicated), palette entry 0 → fully transparent, others opaque.
6. Vertex fix-up: `rhw = z`; `u,v *= 1/page_size` (game UVs are **texels**);
   `specular = 0`; unless `GBH_F_VERTEX_COLOUR (0x2000)`:
   `diffuse = 0xFF000000 | b<<16 | b<<8 | b` with `b = brightness` arg.
7. `GBH_F_LIGHTING (0x8000)` and ambient ≠ 255: per-vertex point lights added to
   diffuse (world pos taken from fields past the vertex — gameplay only).
8. `DrawPrimitive` (fan of 4 / list of 3).

Frontend text (`0x4cc100`) and sprites (`0x4cba50`, `0x4cbdb0`) use exactly:
`gbh_DrawQuad(flags | 0x20000 [| 0x10000 when unscaled], tex, verts @0x6733f0,
0xFF)`, `z = 0.0001`, UVs `0..w`, `0..h` (minus a tiny bias). `flags` comes from
`0x4cb050` (translucency of the sprite).

## 3. Data structures across the boundary

Full definitions with every offset: [`renderer_api.h`](renderer_api.h) /
[`renderer_api.inc`](renderer_api.inc). Summary:

### 3.1 `VidCtx` (0x4c4, from `Vid_Init_SYS`)

What **gta2.exe** reads/writes (must be right in a reimplementation):

| off | field | game use |
|---|---|---|
| +0x04 | `flags` | ORs in `0x10` (triple buffer), `0x40` (d3d renderer), `0x100` (before SetMode) |
| +0x1c | `num_modes` | bound check in the resolution list (`~0x4cb8c1`) |
| +0x40 | `mode_id` | `-2` = windowed (picks window_width/height vs mode size) |
| +0x48/+0x4c | `width`/`height` | clears, cull rect, `MakeScreenTable` |
| +0x50/+0x54 | `surface`/`pitch` | after `Vid_GetSurface`: Bink copies video frames straight into it (`0x481e00`), `MakeScreenTable` |
| +0x5c/+0x64/+0x6c | R/G/B bit counts | Bink: `5,5,5` → 555 else 565 |

What **d3ddll** additionally uses: `+0x7c hmodule`, `+0x84 slot_table`,
`+0x8c/+0x120` DD objects, `+0x134/+0x138` surfaces, `+0x13c` lock desc,
`+0x1c8` HAL caps, `+0x58..+0x6c` pixel format. Irrelevant once both DLLs are ours.

Mode list (`VidMode`, 0x40) and device list (`VidDevice`) hang off the ctx; the
game only touches `VidDevice.flags & 1`.

### 3.2 d3ddll handles

- **`GbhTexture` (0x20)**: `+0x0e width u16`, `+0x10 height u16`, `+0x14 pixels`
  are **written by gta2.exe** (`0x4c2bc0`, `0x4c2c80`, `0x4c2ce0`: Lock → poke →
  Unlock to retarget a texture at another sprite/tile without re-registering).
  `+0x0c/+0x0d` = x/y origin in the 256-wide page (0 in practice). The rest is
  private. Pixels: 8-bit palette indices, **pitch 256** (they point into STY
  sprite/tile pages).
- **Palette**: an int index 0…N (game registers one per STY palette, frontend
  ~`fstyle.sty` count), source = `u32 *` with stride 64.
- **Image**: an int index into the image table.
- **`GbhVertex` (0x20)** = D3DTLVERTEX: `x, y, z, rhw, diffuse, specular, u, v`.
- **`GbhLight` (0x14)**: `packed (intensity | radius<<8 | type<<16), x, y, z, rgb`.
- **`GbhGlobals`**: stats block, see header.

### 3.3 The d3ddll ↔ dmavideo coupling

`gbh_InitDLL` overwrites four of gta2.exe's Vid_* slots through
`ctx->slot_table` (indices 8, 9, 16, 17 of the 22-entry table at `0x675300`):

| game slot | becomes | effect |
|---|---|---|
| `Vid_CloseScreen` `0x59503c` | `gbh_CloseScreen` | free textures/D3D before DirectDraw goes away |
| `Vid_SetMode` `0x595040` | hook `0xe04d80` | `ctx->device_id = 0` (force DD re-create), real SetMode, on success re-run the `gbh_Init` body (re-create D3D for the new surfaces) |
| `Vid_GetSurface` `0x59505c` | `0xe04db0` | forwarder |
| `Vid_FreeSurface` `0x595060` | `0xe04dc0` | forwarder |

`gbh_CloseDLL` restores them. For an SDL port with both DLLs replaced the same
effect is: a mode change invalidates the renderer's textures/targets, and
`gbh_BeginScene`/`EndScene` bracket the 3D work with an unlock/re-lock of the
2D surface.

## 4. Frame structure and the main menu

### 4.1 Frontend frame (`0x4585f0`, called from the frontend loop `0x45a320`)

```
0x4caec0: Vid_GetSurface(ctx)                 ; lock back buffer, ctx->surface/pitch valid
          MakeScreenTable(ctx->surface, ctx->pitch, ctx->height)
          gbh_SetWindow(0, 0, w-1, h-1)       ; w/h = window size if mode -2, else ctx size
gbh_BeginScene()                              ; unlocks the 2D surface (Vid_FreeSurface)
0x453020: background                          ; gbh_BlitImage, retry after gbh_LoadImage on -10
0x458590: menu contents                       ; gbh_DrawQuad per glyph/sprite (+ gbh_BlitImage for
                                              ;  image #23 Mask3.tga 451x144 at (0x55,0))
gbh_EndScene()                                ; re-locks
0x4caf50: Vid_FreeSurface(ctx)
Vid_FlipBuffers(ctx)
Vid_ClearScreen(ctx, 0,0,0, 0,0, ctx->width, ctx->height)
```

Background (`0x453020`): image pair from screen id → table `0x591f68`
(stride 0x88: `char path[0x80]; u32 size; int handle`), 25 entries
(`1.tga`, `1_Play.tga`, `1_Options.tga`, … `Credits.tga`). Main menu:
`gbh_BlitImage(left_img, 0,0,278,480, 0,0)` then
`gbh_BlitImage(right_img, 0,0,362,480, 278,0)` (`1_Play.tga` 278×480 +
`1.tga` 362×480); full-screen pages (`Credits`, `3_Tables`, …) blit
`0,0,640,480` once. Image files: `data/frontend/*.tga`, 16 bpp, type 2,
descriptor 0x01 (bottom-up, 1 attribute bit).

Text and sprites come from `data\fstyle.sty` loaded at frontend init: palettes
→ `gbh_RegisterPalette`, sprites/fonts → `gbh_RegisterTexture` (one per
sprite, `w×h` from the sprite entry, pixels in the 256-wide pages), 0x400
64×64 tiles and a 0x80×0x80 scratch texture.

Intro movies (Bink, `0x481e00`) write decoded frames **directly into
`ctx->surface`** between `Vid_GetSurface` and `Vid_FreeSurface`, then flip —
that is the only true framebuffer path. The `mss32`/`binkw32` shims can skip
video (`skip_frontend`/no intro) to avoid it.

### 4.2 Gameplay frame (`0x45a5a0` + `0x461960`)

Same lock/`MakeScreenTable`/`SetWindow`, `gbh_BeginScene`, world (`0x472110`:
`gbh_SetAmbient`, per camera `gbh_ResetLights` + `gbh_SetCamera(rect)` +
`gbh_AddLight`…; tiles `gbh_DrawTile` from `0x46c2c0..0x471ce0`; slopes
`gbh_DrawTriangle`; sprites/cars/peds `gbh_DrawQuad` from `0x4be060`; texture
retargeting via Lock/Unlock/AssignPalette), HUD (`gbh_DrawQuad`,
`gbh_DrawFlatRect`), optional stats overlay (`gbh_GetGlobals`,
`gbh_GetUsedCache`), `gbh_EndScene`, `Vid_FreeSurface`, `Vid_FlipBuffers`,
`Vid_ClearScreen` only in some modes. `flags` gets `0x8000` globally when the
`lighting` setting is on (`0x67358c`).

### 4.3 Minimal export subset

**Main menu (must work):**

- dmavideo (12): `Vid_InitDLL`, `Vid_Init_SYS`, `Vid_SetDevice`, `Vid_FindDevice`,
  `Vid_CheckMode`, `Vid_CloseScreen`, `Vid_SetMode`, `Vid_SetGamma` (return 0),
  `Vid_GetSurface`, `Vid_FreeSurface`, `Vid_FlipBuffers`, `Vid_ClearScreen`;
  plus `Vid_WindowProc` (return 0) and `Vid_ShutDown_SYS` for a clean exit.
- d3ddll (17 real): `gbh_InitDLL`, `gbh_Init`, `gbh_GetGlobals`,
  `gbh_SetColourDepth`, `gbh_SetWindow`, `gbh_BeginScene`, `gbh_EndScene`,
  `gbh_RegisterPalette`, `gbh_RegisterTexture`, `gbh_LockTexture`,
  `gbh_UnlockTexture`, `gbh_AssignPalette`, **`gbh_DrawQuad`**,
  `gbh_InitImageTable`, **`gbh_LoadImage`**, **`gbh_BlitImage`**, `gbh_SetAmbient`
  (store only); no-op stubs: `ConvertColourBank`, `MakeScreenTable`.
- All other exports still must **resolve** (the loaders abort on a missing
  name): give them correct-`ret N` stubs (`ret 0/4/8/12/16/20/24/28` per the arg
  bytes in the table). Wrong `ret N` = corrupted stack.

**Gameplay, on top:** `gbh_DrawTile`, `gbh_DrawTriangle`, `gbh_DrawFlatRect`,
`gbh_FreeTexture`, `gbh_FreePalette`, `gbh_ResetLights`, `gbh_AddLight`,
`gbh_SetCamera`, `gbh_GetUsedCache`, `gbh_FreeImageTable`, `gbh_CloseDLL`; the
full flag set of §2.3 including lighting.

## 5. SDL3 implementation plan

### 5.1 Options

1. **SDL_Renderer (recommended start).** Textures `SDL_PIXELFORMAT_ARGB8888`
   (or `ARGB1555`) created on first draw; `SDL_RenderGeometry` takes
   `SDL_Vertex {pos, color(float RGBA), tex_coord}` — a direct map of
   `GbhVertex` (drop `z`/`rhw`, UV ÷ texture size). Blend modes:
   `SDL_BLENDMODE_BLEND` (0x80/0x100), `SDL_BLENDMODE_ADD` (0x200), none;
   `SDL_SetTextureScaleMode` NEAREST for `0x20000`, LINEAR otherwise.
   Background images become static textures blitted with `SDL_RenderTexture`.
   Render to a 640×480 target texture, present scaled
   (`SDL_SetRenderLogicalPresentation`). GTA2 draws back-to-front with no
   depth buffer here (no render state set in `0xe01a90`/`0xe02960` enables ZENABLE), so no z handling is needed.
   Perspective: GTA2 quads are screen-space and essentially affine; `rhw` can be
   ignored at first.
2. **SDL_GPU.** Same model with an explicit pipeline; buys batching and a real
   shader for palette lookup (upload 8-bit indices + palette texture). Worth it
   only if SDL_Renderer is too slow for gameplay (thousands of quads/frame).
3. **Software rasterizer into a 16-bit framebuffer** (like the original
   `softdll.dll`), then one `SDL_UpdateTexture` per frame. Simplest mental model
   for `ctx->surface` (Bink and any direct writes just work), but we would write
   a textured, blended triangle filler in NASM. Good fallback, not first choice.

Recommendation: option 1, with a 16-bit **CPU-side back buffer** kept only for
what really needs memory (`Vid_GetSurface` / Bink): mark it dirty when the game
had it locked and upload it as a full-screen texture under the GPU-drawn
primitives in `gbh_BeginScene`.

### 5.2 Mapping

| export | SDL3 |
|---|---|
| `Vid_Init_SYS` | `SDL_Init(VIDEO)`; allocate a `VidCtx` (0x4c4, **below 4 GB**), one device (id 1, flags 1), a mode list with 640×480×16 (+ desktop modes), `next_*` counters |
| `Vid_SetMode(ctx, hwnd, id)` | create/resize the SDL window (the game's HWND is our shim's handle), renderer, 640×480 target; fill `mode_id`, `width/height`, `fullscreen`, `r/g/b` = 565; invalidate textures; return 0 |
| `Vid_CloseScreen` / `ShutDown_SYS` | destroy target/textures / everything |
| `Vid_GetSurface` / `FreeSurface` | point `surface/pitch` at a 640×480×2 CPU buffer, set/clear flags 1\|2 |
| `Vid_FlipBuffers` | finish the frame: `SDL_SetRenderTarget(NULL)`, render target texture, `SDL_RenderPresent` |
| `Vid_ClearScreen` | `SDL_SetRenderDrawColor` + `SDL_RenderFillRect` (and clear the CPU buffer) |
| `Vid_SetGamma` | return 0 (or a shader/colour-mod later) |
| `gbh_RegisterPalette` | copy 256 colours (stride 64 dwords) into our own table, **apply the same in-place edits** (`pal[0]=0`, other 0 → 0x10000) |
| `gbh_RegisterTexture` etc. | allocate a real `GbhTexture` (0x20, below 4 GB) so game pokes land; keep an SDL texture cache keyed by (`pixels`, `width`, `height`, palette) and drop it on Lock/AssignPalette |
| `gbh_DrawQuad/Triangle/Tile` | §2.3 fix-ups → `SDL_RenderGeometry` (quad = 2 triangles via indices) |
| `gbh_DrawFlatRect` | `SDL_RenderGeometry` without texture |
| `gbh_LoadImage` | parse TGA (bottom-up 1555) → `SDL_CreateTexture`; return slot |
| `gbh_BlitImage` | `SDL_RenderTexture(src rect → dst rect)`; return 0 (never -10) |
| `gbh_BeginScene/EndScene` | set the 640×480 target; upload the CPU buffer if dirty |

### 5.3 Risks and traps

- **stdcall from 32-bit code into 64-bit SDL.** Every export is entered in the
  32-bit LDT segment; our thunks must pop exactly the arg bytes of §2 (`ret N`)
  and convert 32-bit stack args (floats included) to SysV registers.
- **Memory below 4 GB**: `VidCtx`, `GbhTexture`, `GbhGlobals`, the slot pointers
  and the CPU back buffer are dereferenced by 32-bit code.
- **Palette writes**: `gbh_RegisterPalette` mutates the game's palette data;
  skipping that changes which colours are transparent.
- **Texture retargeting**: the game rewrites `GbhTexture.pixels/width/height`
  without telling us except via Lock/Unlock — key caches on content pointer,
  not on the handle alone.
- **Fixed 640×480 frontend coordinates**; other resolutions misplace the menu.
- **16-bit expectations**: Bink and any code using `ctx->surface` assume 2 bytes
  per pixel and the bit counts at `+0x5c/+0x64/+0x6c`.
- **FPU**: the original sets the x87 control word (round-to-nearest, 24-bit
  precision bits) in `gbh_InitDLL`; game float math assumes it stays sane across
  calls — our thunks must not leave the x87/SSE state changed.
- `Vid_SetMode` return: **1 = failure** — the game shows an error and falls back
  to 640×480 / windowed, so return 0.
- Windowed vs fullscreen: `start_mode` (registry, default 1 = fullscreen).
  Choosing windowed (`-2`) is simplest; then the game uses
  `window_width/height` (default 640×480) for the cull rect.

## 6. gta2.exe annotations to apply later in Ghidra

Collected for `gta2.segments.fixed.exe`. **Applied 2026-10-20** where the address had no
name yet; addresses that already carried a name kept it, so in Ghidra (and `re/`) look for:
slots `d3ddll_<export>` / `dmavideo_<export>` (not `pgbh_*` / `pVid_*`), `SVideoPtr` (type
`SVideo *`, = `VidCtx`, 0x4c4 B) for `g_VidCtx`, `ptrToMainWindow` / `hInstance` (now typed),
`rendername` / `dmavideo.dll` (now `char[256]`), `GBHGraphicsError`, `InitVideoDll` (=
LoadDmaVideo), `ApplyGammaAndWindowSize` (= SetVideoMode), `SetFullscreenMode`,
`SetWindowedMode`, `d3ddll_ConvertColourBank` (function at 0x4caeb0), `d3d` (= BeginFrame2D),
`SetGamma` / `gamma`, `DrawGTAText` (seuko name, = DrawText2D), `relToGBHGraphic`,
`eachFrame`, `draw`. `g_GbhStats` is typed `void *` (GbhGlobals is not modelled yet).

| address | kind | proposed name / type |
|---|---|---|
| `0x59501c..0x595070` | data, 22 × ptr | `pVid_GetVersion` … `pVid_SetGamma` (order: GetVersion, Init_SYS, CheckMode, FindMode, FindFirstMode, FindNextMode, FindDevice, SetDevice, CloseScreen, SetMode, FlipBuffers, ReleaseSurface, GrabSurface, ShutDown_SYS, EnableWrites, DisableWrites, GetSurface, FreeSurface, ClearScreen, WindowProc, InitDLL, SetGamma at `+0x00..+0x54` — see `renderer_api.inc`); typed function pointers. **`0x59503c`, `0x595044`, `0x595064` already have user names — keep them.** |
| `0x5952a8..0x595340` | data, 39 × ptr | `pgbh_*` slots (see `renderer_api.inc`); **`0x5952b4`, `0x595314`, `0x595318`, `0x595324`, `0x595328` already named — keep** |
| `0x67535c` | data ptr | `pDrawLine` |
| `0x675300` | data, `void **[22]` | `VidSlotTable` (passed to `Vid_InitDLL`) |
| `0x673d20` | data `VidCtx *` | `g_VidCtx` |
| `0x673d18` | data `HWND` | `g_hWnd` |
| `0x673e28` | data `HINSTANCE` | `g_hInstance` |
| `0x675360` | data `GbhGlobals *` | `g_GbhStats` |
| `0x6752e8` / `0x675364` | data `HMODULE` | `g_hDmaVideo` / `g_hRenderDll` |
| `0x673478` / `0x6732f0` | `char[256]` | `g_RenderDllName` / `g_VideoDllName` |
| `0x673580` | int | `g_RendererKind` (0 soft, 1 d3d, 2 3dfx) |
| `0x4d2cf0` / `0x4d35c0` | func | `VidNotLoadedError` / `GbhNotLoadedError` |
| `0x4d2da0` | func `(VidCtx*)` | `UnloadDmaVideo` |
| `0x4d2e50` | func `int __stdcall (char*)` | `LoadDmaVideo` |
| `0x4d35f0` / `0x4d3730` | func | `ResetGbhSlots` / `UnloadRenderDll` |
| `0x4d3770` | func `int __stdcall (char*)` | `LoadRenderDllExports` |
| `0x4d4730` | func `int __stdcall (char*, VidCtx*)` | `LoadRenderDll` |
| `0x4cb3f0` | func | `ReadRendererSettings` |
| `0x4cc6d0` | func | `InitVideo` |
| `0x4cc5c0` | func | `SetVideoMode` |
| `0x4cb570` / `0x4cb730` | func | `SetFullscreenMode` / `SetWindowedMode` |
| `0x4cae50` | func | `InitRenderer` |
| `0x4caea0` | func | `InitRendererDevice` (`gbh_Init(0)`) |
| `0x4caeb0` | func | `SetRendererColourDepth` |
| `0x4caec0` | func | `BeginFrame2D` (GetSurface + MakeScreenTable + SetWindow) |
| `0x4caf50` | func | `EndFrame2D` (FreeSurface) |
| `0x4cb890` | func | `ShutdownVideo` |
| `0x4cb930` / `0x4cb990` | func | `SetGamma` / `ApplyGammaSetting` |
| `0x4cb6f0` | func | `CanRenderWindowed` |
| `0x4585f0` | func | `DrawFrontendFrame` |
| `0x453020` | func | `DrawFrontendBackground` |
| `0x452d50` / `0x452e20` | func | `LoadFrontendImage(idx)` / `LoadFrontendImages` |
| `0x591f68` | data `FrontendImage[25]` (`char path[0x80]; u32 size; int handle`) | `g_FrontendImages` |
| `0x4cba50` / `0x4cbdb0` / `0x4cc100` | func | `DrawSprite2D` / `DrawSprite2DAt` / `DrawText2D` (all → `gbh_DrawQuad`) |
| `0x474110` | func | `DrawFlatRect2D` |
| `0x4c30a0` | func | `RegisterStyleTextures` |
| `0x4c2970` / `0x4c29c0` | func | `RegisterStylePalettes` / `FreeStylePalettes` |
| `0x45a5a0` / `0x461960` | func | `DrawGameFrame` / `DrawGameFrameAndFlip` |
| `0x472110` | func | `SetupFrameLighting` |
