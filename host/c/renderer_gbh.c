/* renderer_gbh.c — d3ddll.dll (gbh_*) on SDL3's SDL_Renderer: textures, palettes,
 * quads/triangles/tiles, the point lighting and the frontend images. The back buffer,
 * the CPU buffer and the frame loop are renderer.c's. API: docs/renderer-api.md; design:
 * docs/renderer-sdl.md.
 *
 *   gbh_DrawQuad/Triangle/Tile -> SDL_RenderGeometry (DrawTile permutes the tile UVs
 *   first; GBH_F_LIGHTING applies the gbh_AddLight point lights + ambient per vertex).
 *   8-bit textures are expanded through their palette to ARGB8888 (index 0 = transparent)
 *   and cached per GbhTexture, keyed on (pixels, width, height, palette, palette
 *   generation): the game retargets textures by poking those fields.
 *   gbh_LoadImage/BlitImage -> one XRGB1555 texture per TGA, SDL_RenderTexture.
 *
 * The float maths is single precision in the original's operation order (SSE, no
 * contraction), so a port of it draws exactly the same pixels.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "renderer.h"

#pragma STDC FP_CONTRACT OFF

#define MAX_TEX     0x40000             /* texture cache entries (index 0 unused); wil registers 73104 */
#define MAX_PAL     16384               /* palette indices */
#define MAX_IMG     64                  /* image table slots (the game asks for 25) */
#define CONV_SIZE   0x100000            /* conversion scratch: 256x256x4 texels or a 640x480x2 TGA */
#define MAX_LIGHTS  1024                /* the original has no bound; the game adds a few dozen */
#define HEAP_ZERO_MEMORY 0x08

static const union { uint32_t u; float f; } INV255 = { 0x3b808081 };   /* 1/255 as the asm had it */
#define F_INV255 (INV255.f)

/* a light, precomputed as d3ddll keeps them at 0xe459e0 (11 dwords) */
struct light {
    uint32_t packed;
    float i;                            /* intensity / 255 */
    float r, r2, invr;                  /* radius / 255 * 8 (world units), its square, 1/r */
    float x, y, z;
    float cr, cg, cb;                   /* r, g, b / 255 */
};

/* texture cache entry (host memory; GbhTexture.cache holds its index) */
struct tce {
    SDL_Texture *sdl;
    uint32_t pixels;                    /* key: pixels the SDL texture was built from (free-list link) */
    uint32_t w, h;
    uint32_t pal;                       /* palette index (AssignPalette changes it) */
    uint32_t gen;                       /* key: pal_gen[pal] at build time */
    uint32_t dirty;                     /* Lock/Unlock/AssignPalette: rebuild before the next draw */
};

static const int quad_idx[6] = { 0, 1, 2, 0, 2, 3 };   /* D3D triangle fan of 4 as two triangles */

static gptr r_globals;                  /* GbhGlobals* (low memory) */
static uint32_t r_ambient;              /* float bits: lighting compares it with 1.0 bit for bit */
static uint32_t r_cull[4], r_camera[4]; /* gbh_SetWindow / gbh_SetCamera, stored, unused */
static uint8_t r_relock;
static uint32_t r_pals;
static struct light lights[MAX_LIGHTS];
static uint32_t n_lights;
static uint8_t lights_warned;
static uint32_t *pal_ptr[MAX_PAL];      /* 256 x 0xAARRGGBB each */
static uint32_t pal_gen[MAX_PAL];
static uint32_t grey_pal[256];
static struct tce tex_cache[MAX_TEX];
static uint32_t tc_used, tc_free;
static uint32_t img_count;
static int32_t img_w[MAX_IMG], img_h[MAX_IMG];
static SDL_Texture *img_tex[MAX_IMG];
static uint8_t conv_buf[CONV_SIZE] __attribute__((aligned(16)));

static inline float flt(uint32_t bits)
{
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

void gbh_setup(void)
{
    tc_used = 1;
    for (uint32_t i = 0; i < 256; i++)
        grey_pal[i] = 0xFF000000u | i << 16 | i << 8 | i;
}

uint64_t gbh_init_dll(const uint32_t *a)        /* (VidCtx*): no slot patching, both DLLs are ours */
{
    r_ctx = a[0];
    if (!r_globals)
        r_globals = (gptr)low_alloc(sizeof(GbhGlobals), 16);
    return 0;
}

uint64_t gbh_init(const uint32_t *a)            /* (int) -> 0 */
{
    (void)a;
    puts("  [gbh] gbh_Init: SDL_Renderer backend");
    return 0;
}

uint64_t gbh_get_globals(const uint32_t *a)
{
    (void)a;
    return r_globals;
}

uint64_t gbh_set_window(const uint32_t *a)      /* (float l, t, r, b): the cull rect; SDL clips */
{
    memcpy(r_cull, a, sizeof r_cull);
    return 0;
}

uint64_t gbh_set_ambient(const uint32_t *a)     /* (float): only lighting uses it */
{
    r_ambient = a[0];
    return 0;
}

uint64_t gbh_set_camera(const uint32_t *a)      /* (float l, t, r, b): the visible world rect; unused */
{
    memcpy(r_camera, a, sizeof r_camera);
    return 0;
}

uint64_t gbh_reset_lights(const uint32_t *a)
{
    (void)a;
    n_lights = 0;
    return 0;
}

/* gbh_AddLight(GbhLight *) (d3ddll 0xe01d70): packed = intensity | radius << 8 | type << 16;
 * precomputes intensity/255, r = radius/255*8, r^2, 1/r, rgb/255 like the original. */
uint64_t gbh_add_light(const uint32_t *a)
{
    if (n_lights >= MAX_LIGHTS) {
        if (!lights_warned) {
            lights_warned = 1;
            puts("  [gbh] gbh_AddLight: more than MAX_LIGHTS lights in a frame, extra ones dropped");
        }
        return 0;
    }
    const GbhLight *g = GP(GbhLight, a[0]);
    struct light *l = &lights[n_lights++];
    uint32_t p = g->packed;
    l->packed = p;
    l->i = (float)(int)(p & 0xff) * F_INV255;
    l->r = (float)(int)(p >> 8 & 0xff) * F_INV255;
    l->r = l->r * 8.0f;
    l->r2 = l->r * l->r;
    l->invr = 1.0f / l->r;
    l->x = g->x;
    l->y = g->y;
    l->z = g->z;
    l->cr = (float)(int)(g->rgb >> 16 & 0xff) * F_INV255;
    l->cg = (float)(int)(g->rgb >> 8 & 0xff) * F_INV255;
    l->cb = (float)(int)(g->rgb & 0xff) * F_INV255;
    return 0;
}

/* The original's per-vertex point lighting (d3ddll ApplyPointLightsToVertices). The world
 * position of v[i] is in v[i + 4].x/y/z. Per channel c (0..1):
 *   c' = min(1, c * brightness/255 * sum(light.c * I * (r - d) / r) + ambient)
 * over lights of type 1 with d^2 <= r^2. The original's table sqrt is sqrtss here. */
static void apply_lights(SDL_Vertex *sv, int n, uint8_t brightness, const GbhVertex *v)
{
    float b = (float)brightness * F_INV255;
    float amb = flt(r_ambient);
    for (int i = 0; i < n; i++) {
        const GbhVertex *w = &v[i + 4];
        float sr = 0, sg = 0, sb = 0;
        for (uint32_t k = 0; k < n_lights; k++) {
            const struct light *l = &lights[k];
            if ((l->packed & 0x30000) != 0x10000)
                continue;
            float dx = w->x - l->x, dy = w->y - l->y, dz = w->z - l->z;
            float d2 = dx * dx;
            d2 = d2 + dy * dy;
            d2 = d2 + dz * dz;
            if (d2 > l->r2)
                continue;
            float t = (l->r - sqrtf(d2)) * l->invr;
            if (!(t > 0.0f))
                continue;
            t = t * l->i;
            sr = sr + l->cr * t;
            sg = sg + l->cg * t;
            sb = sb + l->cb * t;
        }
        float c;
        c = sv[i].r * b * sr + amb;
        sv[i].r = c < 1.0f ? c : 1.0f;
        c = sv[i].g * b * sg + amb;
        sv[i].g = c < 1.0f ? c : 1.0f;
        c = sv[i].b * b * sb + amb;
        sv[i].b = c < 1.0f ? c : 1.0f;
    }
}

/* gbh_BeginScene: the original unlocks a locked 2D surface (and EndScene re-locks it);
 * here the locked CPU buffer also gets drawn under the 3D primitives. */
uint64_t gbh_begin_scene(const uint32_t *a)
{
    (void)a;
    r_relock = 0;
    if (r_ctx && (vid_ctx(r_ctx)->flags & VID_F_LOCKED)) {
        r_relock = 1;
        vid_ctx(r_ctx)->surface = 0;
        vid_ctx(r_ctx)->flags &= ~(VID_F_LOCKED | VID_F_WRITES);
    }
    if (r_renderer && r_fb_touched) {
        r_fb_touched = 0;
        r_upload_fb();
    }
    if (r_globals)
        GP(GbhGlobals, r_globals)->polys_drawn = 0;
    return 0;
}

uint64_t gbh_end_scene(const uint32_t *a)
{
    (void)a;
    if (r_relock) {
        r_relock = 0;
        vid_lock_quiet(&r_ctx);
    }
    return 0;
}

/* ---- palettes ---------------------------------------------------------------- */

/* gbh_RegisterPalette(index, u32 *pal): 256 x 0x00RRGGBB, stride 64 dwords. Like the
 * original it edits the caller's data (pal[0] = 0, other zeros -> 0x10000). */
uint64_t gbh_register_palette(const uint32_t *a)
{
    uint32_t idx = a[0];
    if (idx >= MAX_PAL) {
        printf("  [gbh] gbh_RegisterPalette: index %d out of range, ignored\n", (int32_t)idx);
        return 0;
    }
    if (!pal_ptr[idx])
        pal_ptr[idx] = malloc(1024);
    uint32_t *host = pal_ptr[idx];
    gptr pal = a[1];
    wr32(pal, 0);
    host[0] = 0;                        /* index 0: transparent */
    for (uint32_t c = 1; c < 256; c++) {
        uint32_t e = rd32(pal + c * 256);   /* stride 64 dwords = 256 bytes */
        if (!e)
            wr32(pal + c * 256, e = 0x10000);
        host[c] = (e & 0x00FFFFFF) | 0xFF000000u;
    }
    pal_gen[idx]++;
    r_pals++;
    return 0;
}

uint64_t gbh_free_palette(const uint32_t *a)    /* (index) */
{
    uint32_t idx = a[0];
    if (idx < MAX_PAL) {
        free(pal_ptr[idx]);
        pal_ptr[idx] = 0;
        pal_gen[idx]++;
    }
    return 0;
}

/* ---- textures ---------------------------------------------------------------- */

/* a cache entry index (zeroed, dirty) */
static uint32_t tc_alloc(void)
{
    uint32_t i = tc_free;
    if (i)
        tc_free = tex_cache[i].pixels;  /* free-list link */
    else if ((i = tc_used) < MAX_TEX)
        tc_used++;
    else
        fail("renderer: texture cache full");
    tex_cache[i] = (struct tce){ .dirty = 1 };
    return i;
}

/* gbh_RegisterTexture(u16 w, u16 h, u8 *pixels, int palette, char translucent) */
uint64_t gbh_register_texture(const uint32_t *a)
{
    gptr p = heap_alloc(sizeof(GbhTexture), HEAP_ZERO_MEMORY);
    GbhTexture *t = GP(GbhTexture, p);
    uint32_t i = tc_alloc();
    t->id = (uint16_t)i;
    t->cache = i;
    t->width = (uint16_t)a[0];
    t->height = (uint16_t)a[1];
    t->pixels = a[2];
    t->pal_registered = 1;
    tex_cache[i].pal = a[3];
    r_texs++;
    return p;
}

uint64_t gbh_free_texture(const uint32_t *a)    /* (GbhTexture*) */
{
    if (!a[0])
        return 0;
    uint32_t i = GP(GbhTexture, a[0])->cache;
    if (i) {
        struct tce *e = &tex_cache[i];
        if (e->sdl) {
            r_SDL_DestroyTexture(e->sdl);
            e->sdl = 0;
        }
        e->pixels = tc_free;
        tc_free = i;
    }
    heap_free(a[0]);
    return 0;
}

/* the cache entry of a GbhTexture (0 if it has none) */
static struct tce *tc_entry(const GbhTexture *t)
{
    return t->cache ? &tex_cache[t->cache] : 0;
}

uint64_t gbh_lock_texture(const uint32_t *a)    /* (GbhTexture*): the game pokes width/height/pixels next */
{
    GbhTexture *t = GP(GbhTexture, a[0]);
    t->lock_state = 1;
    struct tce *e = tc_entry(t);
    if (e)
        e->dirty = 1;
    return 0;
}

uint64_t gbh_unlock_texture(const uint32_t *a)
{
    GbhTexture *t = GP(GbhTexture, a[0]);
    t->lock_state = 0;
    struct tce *e = tc_entry(t);
    if (e)
        e->dirty = 1;
    return 0;
}

uint64_t gbh_assign_palette(const uint32_t *a)  /* (GbhTexture*, palette) */
{
    struct tce *e = tc_entry(GP(GbhTexture, a[0]));
    if (e) {
        e->pal = a[1];
        e->dirty = 1;
    }
    return 0;
}

/* the SDL texture matching a GbhTexture's current pixels/size/palette (rebuilt when any
 * of them changed), or 0 if it cannot be drawn */
static SDL_Texture *tex_get(const GbhTexture *t)
{
    struct tce *e = tc_entry(t);
    if (!e)
        return 0;
    uint32_t w = t->width, h = t->height;
    uint32_t gen = e->pal < MAX_PAL ? pal_gen[e->pal] : 0;
    if (e->sdl && !e->dirty && t->pixels == e->pixels && w == e->w && h == e->h && gen == e->gen)
        return e->sdl;
    e->gen = gen;
    if (!w || !h || w > 256 || h > 256)
        return 0;
    if (e->sdl && (w != e->w || h != e->h)) {
        r_SDL_DestroyTexture(e->sdl);
        e->sdl = 0;
    }
    if (!e->sdl && !(e->sdl = r_texture(SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC,
                                        (int)w, (int)h)))
        return 0;
    e->w = w;
    e->h = h;
    e->pixels = t->pixels;
    e->dirty = 0;
    /* palette (a grey ramp if the index was never registered) */
    const uint32_t *pal = e->pal < MAX_PAL && pal_ptr[e->pal] ? pal_ptr[e->pal] : grey_pal;
    const uint8_t *src = (const uint8_t *)(uintptr_t)e->pixels;   /* 8-bit, pitch 256 */
    uint32_t *dst = (uint32_t *)conv_buf;
    for (uint32_t y = 0; y < h; y++, src += 256)
        for (uint32_t x = 0; x < w; x++)
            *dst++ = pal[src[x]];
    r_SDL_UpdateTexture(e->sdl, 0, conv_buf, (int)(w * 4));
    r_tex_builds++;
    return e->sdl;
}

/* ---- drawing ------------------------------------------------------------------- */

/* draw_prim(args, vertex count): renderer-api.md §2.3 -> SDL_RenderGeometry */
static uint64_t draw_prim(const uint32_t *a, int n)
{
    uint32_t flags = a[0];
    if (!r_renderer)
        return 0;
    const GbhVertex *v = GP(GbhVertex, a[2]);
    int32_t z0;
    memcpy(&z0, &v->z, 4);
    if (z0 <= 0)                        /* z <= 0 (float sign/zero as int): culled */
        return 0;
    SDL_Texture *tex = 0;               /* 0 = untextured */
    const GbhTexture *t = GP(GbhTexture, a[1]);
    if (t) {
        if (!(tex = tex_get(t)))
            return 0;
        r_SDL_SetTextureBlendMode(tex, (flags & GBH_F_ALPHA_MASK) == GBH_F_ADDITIVE
                                       ? SDL_BLENDMODE_ADD
                                       : SDL_BLENDMODE_BLEND);   /* also the alpha test of index 0 */
        r_SDL_SetTextureScaleMode(tex, flags & (GBH_F_NO_FILTER | GBH_F_SPRITE_RECT)
                                       ? SDL_SCALEMODE_NEAREST : SDL_SCALEMODE_LINEAR);
    }
    float iw = 0, ih = 0, tw = 0, th = 0;   /* UVs come in texels */
    if (t) {
        tw = (float)t->width;
        th = (float)t->height;
        iw = 1.0f / tw;
        ih = 1.0f / th;
    }
    uint8_t bright = (uint8_t)a[3];
    float grey = (float)bright * F_INV255;
    SDL_Vertex sv[4];
    for (int i = 0; i < n; i++) {
        sv[i].x = v[i].x;
        sv[i].y = v[i].y;
        if (flags & GBH_F_VERTEX_COLOUR) {
            uint32_t d = v[i].diffuse;
            sv[i].r = (float)(int)(d >> 16 & 0xff) * F_INV255;
            sv[i].g = (float)(int)(d >> 8 & 0xff) * F_INV255;
            sv[i].b = (float)(int)(d & 0xff) * F_INV255;
            sv[i].a = 1.0f;
            if (flags & GBH_F_ALPHA_MASK)   /* opaque mode ignores diffuse alpha */
                sv[i].a = (float)(int)(d >> 24) * F_INV255;
        } else {
            sv[i].r = sv[i].g = sv[i].b = grey;
            sv[i].a = 1.0f;
        }
        sv[i].u = v[i].u * iw;
        sv[i].v = v[i].v * ih;
    }
    if ((flags & GBH_F_LIGHTING) && r_ambient != 0x3f800000)   /* and ambient != 1.0, as the original */
        apply_lights(sv, n, bright, v);
    /* GBH_F_SPRITE_RECT: only v[0].x/y/z are valid; build a w x h quad, whole texture */
    if ((flags & GBH_F_SPRITE_RECT) && n == 4 && tex) {
        float x0 = sv[0].x, y0 = sv[0].y, x1 = x0 + tw, y1 = y0 + th;
        sv[0].u = 0;
        sv[0].v = 0;
        sv[1].x = x1;
        sv[1].y = y0;
        sv[1].u = 1.0f;
        sv[1].v = 0;
        sv[2].x = x1;
        sv[2].y = y1;
        sv[2].u = 1.0f;
        sv[2].v = 1.0f;
        sv[3].x = x0;
        sv[3].y = y1;
        sv[3].u = 0;
        sv[3].v = 1.0f;
        for (int i = 1; i < 4; i++) {   /* v[0]'s colour for all four */
            sv[i].r = sv[0].r;
            sv[i].g = sv[0].g;
            sv[i].b = sv[0].b;
            sv[i].a = sv[0].a;
        }
    }
    r_SDL_RenderGeometry(r_renderer, tex, sv, n, n == 4 ? quad_idx : 0, n == 4 ? 6 : 0);
    r_quads++;
    if (r_globals)
        GP(GbhGlobals, r_globals)->polys_drawn++;
    return 0;
}

uint64_t gbh_draw_quad(const uint32_t *a)       /* (flags, GbhTexture*, GbhVertex v[4], u8 brightness) */
{
    return draw_prim(a, 4);
}

uint64_t gbh_draw_triangle(const uint32_t *a)   /* (flags, GbhTexture*, GbhVertex v[3], u8 brightness) */
{
    return draw_prim(a, 3);
}

/* gbh_DrawTile(flags, GbhTexture*, GbhVertex v[4], u8 brightness) (= gbh_DrawTilePart):
 * d3ddll 0xe043f0. Unless GBH_F_TILE_CUSTOM_UV, the UVs become the 64x64 tile
 * (0.5..63.4999); then the rotate/flip flags permute the (u, v) pairs between the
 * vertices, written back into the caller's array like the original, and it is a DrawQuad
 * (which sees the adjusted flags, also written back). */
uint64_t gbh_draw_tile(uint32_t *a)
{
    GbhVertex *v = GP(GbhVertex, a[2]);
    uint32_t flags = a[0];
    if (!(flags & GBH_F_TILE_CUSTOM_UV)) {
        float lo = flt(0x3f000000), hi = flt(0x427dffe6);   /* 0.5, 63.4999 */
        v[0].u = lo; v[0].v = lo;
        v[1].u = hi; v[1].v = lo;
        v[2].u = hi; v[2].v = hi;
        v[3].u = lo; v[3].v = hi;
    }
    uint64_t uv[4], s;                  /* (u, v) of v[0..3] as raw bits */
    for (int i = 0; i < 4; i++)
        memcpy(&uv[i], &v[i].u, 8);
    switch (flags & GBH_F_TILE_ROT_MASK) {
    case 0x20:                          /* new[i] = old[i+3] */
        s = uv[3]; uv[3] = uv[2]; uv[2] = uv[1]; uv[1] = uv[0]; uv[0] = s;
        break;
    case 0x40:                          /* 180 degrees = both mirrors */
        flags ^= GBH_F_TILE_FLIPX | GBH_F_TILE_FLIPY;
        break;
    case 0x60:                          /* new[i] = old[i+1] */
        s = uv[0]; uv[0] = uv[1]; uv[1] = uv[2]; uv[2] = uv[3]; uv[3] = s;
        break;
    }
    if (flags & GBH_F_TILE_FLIPX) {     /* 0<->1, 2<->3 */
        s = uv[0]; uv[0] = uv[1]; uv[1] = s;
        s = uv[2]; uv[2] = uv[3]; uv[3] = s;
    }
    if (flags & GBH_F_TILE_FLIPY) {     /* 0<->3, 1<->2 */
        s = uv[0]; uv[0] = uv[3]; uv[3] = s;
        s = uv[1]; uv[1] = uv[2]; uv[2] = s;
    }
    for (int i = 0; i < 4; i++)
        memcpy(&v[i].u, &uv[i], 8);
    a[0] = flags;
    return draw_prim(a, 4);
}

/* gbh_DrawFlatRect(GbhVertex v[4], u32 argb): untextured quad, alpha-blended by argb's alpha */
uint64_t gbh_draw_flat_rect(const uint32_t *a)
{
    if (!r_renderer)
        return 0;
    const GbhVertex *v = GP(GbhVertex, a[0]);
    uint32_t c = a[1];
    float cr = (float)(int)(c >> 16 & 0xff) * F_INV255, cg = (float)(int)(c >> 8 & 0xff) * F_INV255;
    float cb = (float)(int)(c & 0xff) * F_INV255, ca = (float)(int)(c >> 24) * F_INV255;
    SDL_Vertex sv[4];
    for (int i = 0; i < 4; i++)
        sv[i] = (SDL_Vertex){ v[i].x, v[i].y, cr, cg, cb, ca, 0, 0 };
    r_SDL_SetRenderDrawBlendMode(r_renderer, SDL_BLENDMODE_BLEND);
    r_SDL_RenderGeometry(r_renderer, 0, sv, 4, quad_idx, 6);
    r_SDL_SetRenderDrawBlendMode(r_renderer, SDL_BLENDMODE_NONE);
    r_quads++;
    return 0;
}

/* ---- images (frontend backgrounds) -------------------------------------------- */

static void free_images(void)
{
    for (int i = 0; i < MAX_IMG; i++)
        if (img_tex[i]) {
            SDL_Texture *t = img_tex[i];
            img_tex[i] = 0;
            r_SDL_DestroyTexture(t);
        }
}

uint64_t gbh_init_image_table(const uint32_t *a)    /* (count) -> 0 / -1 */
{
    free_images();
    if (a[0] > MAX_IMG)
        return (uint32_t)-1;
    img_count = a[0];
    return 0;
}

uint64_t gbh_free_image_table(const uint32_t *a)    /* -> 0 */
{
    (void)a;
    free_images();
    img_count = 0;
    return 0;
}

/* gbh_LoadImage(void *tga) -> slot, -1 table full, -2 not a 16-bit type-2 TGA, -3 no renderer */
uint64_t gbh_load_image(const uint32_t *a)
{
    gptr tga = a[0];
    if (!r_renderer)
        return (uint32_t)GBH_IMG_OFFSCREEN;
    uint32_t slot = 0;                  /* a free slot */
    while (slot < img_count && img_tex[slot])
        slot++;
    if (slot >= img_count)
        return (uint32_t)GBH_IMG_BAD_HANDLE;
    uint32_t w = rd16(tga + 12), h = rd16(tga + 14);
    if (rd8(tga + 2) != 2 || rd8(tga + 16) != 16 || !w || !h || w * h > CONV_SIZE / 2) {
        printf("  [gbh] gbh_LoadImage(0x%x): not a 16-bit uncompressed TGA\n", tga);
        return (uint32_t)GBH_IMG_BAD_RECT;
    }
    /* pixel data: header 18 + id length + colour map */
    gptr src = tga + rd8(tga) + 18;
    if (rd8(tga + 1))
        src += rd16(tga + 5) * ((rd8(tga + 7) + 7u) >> 3);
    /* rows into conv_buf top-down (bottom-up unless descriptor bit 5) */
    int top_down = rd8(tga + 17) & 0x20;
    for (uint32_t r = 0; r < h; r++, src += w * 2)
        memcpy(conv_buf + (top_down ? r : h - 1 - r) * w * 2, (const void *)(uintptr_t)src, w * 2);
    SDL_Texture *t = r_texture(SDL_PIXELFORMAT_XRGB1555, SDL_TEXTUREACCESS_STATIC, (int)w, (int)h);
    if (!t)
        return (uint32_t)GBH_IMG_OFFSCREEN;
    img_tex[slot] = t;
    img_w[slot] = (int32_t)w;
    img_h[slot] = (int32_t)h;
    r_SDL_UpdateTexture(t, 0, conv_buf, (int)(w * 2));
    printf("  [gbh] gbh_LoadImage -> slot %d (%dx%d)\n", slot, w, h);
    return slot;
}

/* gbh_BlitImage(idx, sl, st, sr, sb, dx, dy) -> 0, -1 bad handle, -2 bad rect */
uint64_t gbh_blit_image(const uint32_t *a)
{
    uint32_t i = a[0];
    if (i >= img_count || !img_tex[i] || !r_renderer)
        return (uint32_t)GBH_IMG_BAD_HANDLE;
    int32_t sl = (int32_t)a[1], st = (int32_t)a[2], sr = (int32_t)a[3], sb = (int32_t)a[4];
    if (sl < 0 || sl >= sr || st < 0 || st >= sb || sr > img_w[i] || sb > img_h[i])
        return (uint32_t)GBH_IMG_BAD_RECT;     /* 0 <= sl < sr <= w, 0 <= st < sb <= h */
    SDL_FRect src = { (float)sl, (float)st, (float)(sr - sl), (float)(sb - st) };
    SDL_FRect dst = { (float)(int32_t)a[5], (float)(int32_t)a[6], src.w, src.h };
    r_SDL_RenderTexture(r_renderer, img_tex[i], &src, &dst);
    r_blits++;
    return 0;
}
