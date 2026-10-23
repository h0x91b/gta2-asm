/* renderer.h — what renderer.c (SDL setup, dmavideo.dll Vid_*) and renderer_gbh.c
 * (d3ddll.dll gbh_*) share: the SDL3 entry points, the renderer plugin structures as the
 * game sees them and the backend state. Design: docs/renderer-sdl.md; API recovered from
 * the shipped DLLs: docs/renderer-api.md.
 */
#ifndef RENDERER_H
#define RENDERER_H

#include <stdbool.h>
#include <stdint.h>

#include "game.h"

/* ---- SDL3 (dlsym'ed from sdl_lib; no SDL headers, like audio.c) ---------------------- */

#define SDL_PIXELFORMAT_XRGB1555    0x15130f02u
#define SDL_PIXELFORMAT_RGB565      0x15151002u
#define SDL_PIXELFORMAT_ARGB8888    0x16362004u
#define SDL_TEXTUREACCESS_STATIC    0
#define SDL_TEXTUREACCESS_STREAMING 1
#define SDL_TEXTUREACCESS_TARGET    2
#define SDL_BLENDMODE_NONE          0u
#define SDL_BLENDMODE_BLEND         1u
#define SDL_BLENDMODE_ADD           2u
#define SDL_SCALEMODE_NEAREST       0
#define SDL_SCALEMODE_LINEAR        1
#define SDL_LOGICAL_PRESENTATION_LETTERBOX 2

typedef struct SDL_Renderer SDL_Renderer;
typedef struct SDL_Texture SDL_Texture;
typedef struct SDL_Surface SDL_Surface;
typedef struct SDL_Window SDL_Window;
typedef struct { int x, y, w, h; } SDL_Rect;
typedef struct { float x, y, w, h; } SDL_FRect;
typedef struct {
    float x, y;                         /* position */
    float r, g, b, a;                   /* color */
    float u, v;                         /* tex_coord */
} SDL_Vertex;

#define R_SDL_FNS(X) \
    X(SDL_Renderer *, SDL_CreateRenderer, (SDL_Window *, const char *)) \
    X(void, SDL_DestroyRenderer, (SDL_Renderer *)) \
    X(const char *, SDL_GetRendererName, (SDL_Renderer *)) \
    X(bool, SDL_SetRenderVSync, (SDL_Renderer *, int)) \
    X(bool, SDL_SetRenderLogicalPresentation, (SDL_Renderer *, int, int, int)) \
    X(SDL_Texture *, SDL_CreateTexture, (SDL_Renderer *, uint32_t, int, int, int)) \
    X(void, SDL_DestroyTexture, (SDL_Texture *)) \
    X(bool, SDL_UpdateTexture, (SDL_Texture *, const SDL_Rect *, const void *, int)) \
    X(bool, SDL_SetTextureBlendMode, (SDL_Texture *, uint32_t)) \
    X(bool, SDL_SetTextureScaleMode, (SDL_Texture *, int)) \
    X(bool, SDL_SetRenderTarget, (SDL_Renderer *, SDL_Texture *)) \
    X(bool, SDL_SetRenderDrawColor, (SDL_Renderer *, uint8_t, uint8_t, uint8_t, uint8_t)) \
    X(bool, SDL_SetRenderDrawBlendMode, (SDL_Renderer *, uint32_t)) \
    X(bool, SDL_RenderClear, (SDL_Renderer *)) \
    X(bool, SDL_RenderFillRect, (SDL_Renderer *, const SDL_FRect *)) \
    X(bool, SDL_RenderTexture, (SDL_Renderer *, SDL_Texture *, const SDL_FRect *, const SDL_FRect *)) \
    X(bool, SDL_RenderGeometry, (SDL_Renderer *, SDL_Texture *, const SDL_Vertex *, int, const int *, int)) \
    X(bool, SDL_RenderPresent, (SDL_Renderer *)) \
    X(SDL_Surface *, SDL_RenderReadPixels, (SDL_Renderer *, const SDL_Rect *)) \
    X(bool, SDL_SaveBMP, (SDL_Surface *, const char *)) \
    X(void, SDL_DestroySurface, (SDL_Surface *)) \
    X(const char *, SDL_GetError, (void))

#define R_DECL(ret, name, args) extern ret (*r_##name) args;
R_SDL_FNS(R_DECL)
#undef R_DECL

/* ---- the plugin ABI (docs/renderer_api.inc; 32-bit layouts, game pointers as gptr) ---- */

#define VID_F_LOCKED        0x00000001u
#define VID_F_WRITES        0x00000002u
#define VID_F_FLIPCHAIN     0x00000020u
#define VID_F_3DDEVICE      0x00000040u
#define VID_F_NOVSYNC       0x00000200u
#define VID_MODE_WINDOWED   (-2)

#pragma pack(push, 1)
typedef struct {                        /* 0x40 */
    int32_t id, device_id, width, height, pitch, bpp;
    int32_t r_shift, r_bits, g_shift, g_bits, b_shift, b_bits, x_shift, x_bits;
    gptr next;                          /* VidMode* */
    int32_t valid;
} VidMode;

typedef struct {                        /* 0x2c */
    int32_t id, flags;                  /* flags bit 0: can render windowed */
    gptr description, name, next, guid_ptr;
    uint32_t guid[4];
    uint32_t vid_mem;
} VidDevice;

typedef struct {                        /* 0x4c4 */
    int32_t one;
    uint32_t flags;                     /* VID_F_* */
    int32_t found_width, found_height, found_bpp;
    int32_t next_mode_id, next_device_id, num_modes, num_devices;
    gptr modes, modes_tail, devices, devices_tail;
    int32_t device_id, unk_38;
    gptr find_iter;                     /* VidMode* */
    int32_t mode_id;                    /* -2 windowed */
    int32_t unk_44;
    int32_t width, height;
    gptr surface;
    int32_t pitch;
    int32_t r_shift, r_bits, g_shift, g_bits, b_shift, b_bits, x_shift, x_bits;
    gptr hinstance, hmodule;
    int32_t fullscreen;
    gptr slot_table;
    uint32_t hresult, ddraw;
    uint8_t unk_090[0x90];
    uint32_t ddraw4;
    uint8_t unk_124[0x10];
    uint32_t primary, back;
    uint8_t lock_desc[0x7c];
    uint32_t clipper;
    uint8_t unk_1bc[0xc];
    uint8_t hal_caps[0x17c], hel_caps[0x17c];
    gptr hwnd;
} VidCtx;

typedef struct {                        /* 0x20 = D3DTLVERTEX */
    float x, y, z, rhw;
    uint32_t diffuse, specular;         /* ARGB */
    float u, v;                         /* texels */
} GbhVertex;

typedef struct {                        /* 0x20; the game writes width/height/pixels */
    uint16_t id, unk_02, unk_04, lock_state;
    gptr locked_pixels;
    uint8_t x, y;
    uint16_t width, height;
    uint8_t pal_registered, tflags;
    gptr pixels;                        /* 8 bpp, pitch 256 */
    gptr palette16;
    uint32_t cache;                     /* our texture cache index */
} GbhTexture;

typedef struct {                        /* 0x14 */
    uint32_t packed;                    /* intensity | radius << 8 | type << 16 */
    float x, y, z;
    uint32_t rgb;
} GbhLight;

typedef struct {                        /* gbh_GetGlobals */
    uint32_t polys_drawn, texture_changes, cache_flushes, frame_time;
    uint32_t cache_size[12];
} GbhGlobals;
#pragma pack(pop)

_Static_assert(sizeof(VidMode) == 0x40, "VidMode");
_Static_assert(sizeof(VidDevice) == 0x2c, "VidDevice");
_Static_assert(sizeof(VidCtx) == 0x4c4, "VidCtx");
_Static_assert(sizeof(GbhVertex) == 0x20, "GbhVertex");
_Static_assert(sizeof(GbhTexture) == 0x20, "GbhTexture");
_Static_assert(sizeof(GbhLight) == 0x14, "GbhLight");

#define GBH_F_TILE_FLIPX     0x00000008u
#define GBH_F_TILE_FLIPY     0x00000010u
#define GBH_F_TILE_ROT_MASK  0x00000060u
#define GBH_F_ALPHA_MASK     0x00000380u
#define GBH_F_ADDITIVE       0x00000200u
#define GBH_F_VERTEX_COLOUR  0x00002000u
#define GBH_F_TILE_CUSTOM_UV 0x00004000u
#define GBH_F_LIGHTING       0x00008000u
#define GBH_F_SPRITE_RECT    0x00010000u
#define GBH_F_NO_FILTER      0x00020000u

#define GBH_IMG_BAD_HANDLE  (-1)
#define GBH_IMG_BAD_RECT    (-2)        /* also LoadImage: not a 16 bpp type-2 TGA */
#define GBH_IMG_OFFSCREEN   (-3)        /* also LoadImage: no renderer / texture */

/* ---- backend state (renderer.c) ------------------------------------------------------ */

#define FB_W 640                        /* the frontend is laid out for 640x480 (renderer-api.md §4) */
#define FB_H 480

extern SDL_Renderer *r_renderer;
extern gptr r_ctx;                      /* VidCtx* (Vid_Init_SYS / gbh_InitDLL) */
extern gptr r_cpu_fb;                   /* RGB565 CPU buffer, r_tw x r_th, pitch r_pitch */
extern uint8_t r_fb_touched;            /* the game locked it since the last upload */
extern uint32_t r_quads, r_blits, r_tex_builds, r_texs;   /* the flip stats line */

/* NASM services (w32_core.asm, loader.asm) */
uint64_t low_alloc(uint32_t size, uint32_t align) NASM(low_alloc);   /* zeroed, below 4 GB */
uint32_t heap_alloc(uint32_t size, uint32_t flags) NASM(heap_alloc);
uint32_t heap_free(uint32_t ptr) NASM(heap_free);
_Noreturn void fail(const char *msg) NASM(fail);

static inline VidCtx *vid_ctx(gptr p) { return GP(VidCtx, p); }

SDL_Texture *r_texture(uint32_t format, int access, int w, int h);
void r_sdl_error(const char *what);
void r_upload_fb(void);
uint64_t vid_lock_quiet(const uint32_t *args);
void gbh_setup(void);                   /* renderer_gbh.c, from setup_renderer */

#endif
