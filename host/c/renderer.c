/* renderer.c — dmavideo.dll (Vid_*) on SDL3's SDL_Renderer, plus the SDL setup and the
 * frame loop the whole renderer shares. The d3ddll.dll half (gbh_*) is renderer_gbh.c;
 * both export tables are shimtab_dmavideo / shimtab_d3ddll (w32_renderer.asm). API:
 * docs/renderer-api.md; design and gaps: docs/renderer-sdl.md.
 *
 * Backend: one SDL_Renderer on the game's window. Everything the game draws goes into an
 * ARGB8888 render-target texture (the "back buffer") of the windowed size the game lays
 * itself out for (screen\window_width x window_height, at least 640x480); Vid_FlipBuffers
 * presents the top-left 640x480 of it in the frontend and all of it in gameplay,
 * letterboxed into the window. Next to it lives an RGB565 CPU buffer of the same size in
 * low memory that Vid_GetSurface hands out (ctx->surface); when the game had it locked,
 * it is uploaded and drawn into the target at gbh_BeginScene / Vid_FlipBuffers.
 *
 * Every Vid_* export is an import handler (docs/host-c.md, "Import shims in C"):
 * uint64_t f(const uint32_t *args), args[0] = the first stdcall argument. Exports the
 * original declares void return 0.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "renderer.h"

/* gta2.exe globals the back buffer follows (re/globals.csv, own analysis of 0x4caec0) */
#define G_WINDOW_W  0x673578            /* window_width: BeginFrame2D's view width when mode_id = -2 */
#define G_WINDOW_H  0x6732e8            /* window_height */
/* G_GAME (game.h): ptrToGame, set by InitGame 0x461de0, zeroed by DeinitGame 0x462060 ->
 * nonzero = gameplay (InitGame/DeinitGame: gta2-seuko-mod by izawartka,
 * https://github.com/izawartka/gta2-seuko-mod, src/game/functions.h @25b1985) */

/* NASM: SDL and the window table (w32_user32.asm), --keys (w32_dinput.asm), gta2ctl */
extern void *sdl_lib NASM(sdl_lib);
void sdl_ensure(void) NASM(sdl_ensure);                 /* SDL_Init(VIDEO) on first use */
void *win_get(uint32_t hwnd) NASM(win_get);             /* window record or 0 */
extern uint32_t main_hwnd NASM(main_hwnd);
#define WN_SDL 40                                       /* window record: SDL_Window* */
void input_keys_frame(uint32_t frame) NASM(input_keys_frame);
void ctl_frame(void);
void ctl_exit(void);
void map_frame(void);                   /* map.c: the radar / the full map */
void map_shutdown(void);

#define R_DEF(ret, name, args) ret (*r_##name) args;
R_SDL_FNS(R_DEF)
#undef R_DEF

/* loader.asm sets these from --shot= / --frames=; gta2ctl's shot swaps r_shot_path */
char *r_shot_path NASM(r_shot_path);
uint32_t r_exit_frame NASM(r_exit_frame);
uint32_t r_frames NASM(r_frames);       /* presented frames (game.h) */

SDL_Renderer *r_renderer;
static SDL_Texture *r_target, *r_fbtex;
static int r_tw, r_th;                  /* back buffer / CPU buffer size */
static int r_pitch;                     /* CPU buffer pitch (r_tw * 2) */
static int r_gw, r_gh;                  /* gameplay view size (window_width/height when windowed) */
static int r_pw, r_ph;                  /* size the window target presents now (0 = not set yet) */
gptr r_ctx, r_cpu_fb;
uint8_t r_fb_touched;
uint32_t r_quads, r_blits, r_tex_builds, r_texs;
static gptr r_vid_hmodule, r_vid_slots;
static int32_t r_find_bpp;

void setup_renderer(void) NASM(setup_renderer);
void setup_renderer(void)
{
#define R_SYM(ret, name, args) \
    if (!(*(void **)&r_##name = dlsym(sdl_lib, #name))) \
        fail("SDL3 is missing a function the loader needs");
    R_SDL_FNS(R_SYM)
#undef R_SYM
    gbh_setup();
}

void r_sdl_error(const char *what)
{
    printf("  [vid] %s failed: %s\n", what, r_SDL_GetError());
}

/* an SDL texture, blend NONE, nearest; 0 (logged) on failure */
SDL_Texture *r_texture(uint32_t format, int access, int w, int h)
{
    SDL_Texture *t = r_SDL_CreateTexture(r_renderer, format, access, w, h);
    if (!t) {
        r_sdl_error("SDL_CreateTexture");
        return 0;
    }
    r_SDL_SetTextureBlendMode(t, SDL_BLENDMODE_NONE);
    r_SDL_SetTextureScaleMode(t, SDL_SCALEMODE_NEAREST);
    return t;
}

/* draw the CPU buffer (ctx->surface) into the back buffer */
void r_upload_fb(void)
{
    r_SDL_UpdateTexture(r_fbtex, 0, (const void *)(uintptr_t)r_cpu_fb, r_pitch);
    r_SDL_RenderTexture(r_renderer, r_fbtex, 0, 0);
}

/* ======================================================== dmavideo.dll (Vid_*) */

uint64_t vid_init_dll(const uint32_t *a)        /* (HMODULE self, void ***slot_table) */
{
    r_vid_hmodule = a[0];
    r_vid_slots = a[1];
    return 0;
}

static uint32_t low_strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    uint32_t p = (uint32_t)low_alloc((uint32_t)n, 4);
    memcpy((void *)(uintptr_t)p, s, n);
    return p;
}

/* RGB565 + the 640x480 geometry */
static void vid_fill_format(VidCtx *c)
{
    c->width = FB_W;
    c->height = FB_H;
    c->r_shift = 11;
    c->r_bits = 5;
    c->g_shift = 5;
    c->g_bits = 6;
    c->b_shift = 0;
    c->b_bits = 5;
    c->x_shift = 0;
    c->x_bits = 0;
}

/* Vid_Init_SYS(hinst, flags) -> VidCtx*: one device (id 1, can run windowed), one mode
 * (640x480x16, RGB565). Everything the game can dereference is in low memory. */
uint64_t vid_init_sys(const uint32_t *a)
{
    sdl_ensure();
    gptr ctx = (gptr)low_alloc(sizeof(VidCtx), 16);
    VidCtx *c = vid_ctx(ctx);
    c->one = 1;
    c->flags = (a[1] & VID_F_3DDEVICE) | VID_F_FLIPCHAIN | VID_F_NOVSYNC;  /* 0x220, the original's default */
    c->hinstance = a[0];
    c->hmodule = r_vid_hmodule;
    c->slot_table = r_vid_slots;
    vid_fill_format(c);

    gptr dev = (gptr)low_alloc(sizeof(VidDevice), 16);
    VidDevice *d = GP(VidDevice, dev);
    d->id = 1;
    d->flags = 1;
    d->description = d->name = low_strdup("SDL3 renderer");
    d->vid_mem = 64 << 20;
    c->devices = c->devices_tail = dev;
    c->num_devices = 1;
    c->next_device_id = 2;

    gptr mode = (gptr)low_alloc(sizeof(VidMode), 16);
    VidMode *m = GP(VidMode, mode);
    m->id = 1;
    m->device_id = 1;
    m->width = FB_W;
    m->height = FB_H;
    m->pitch = FB_W * 2;                /* of the one advertised mode; the CPU buffer's is r_pitch */
    m->bpp = 16;
    m->r_shift = 11;
    m->r_bits = 5;
    m->g_shift = 5;
    m->g_bits = 6;
    m->b_shift = 0;
    m->b_bits = 5;
    m->valid = 1;
    c->modes = c->modes_tail = mode;
    c->num_modes = 1;
    c->next_mode_id = 2;

    r_ctx = ctx;
    printf("  [vid] Vid_Init_SYS -> ctx 0x%x (1 device, mode 1 = 640x480x16 RGB565)\n", ctx);
    return ctx;
}

uint64_t vid_check_mode(const uint32_t *a)      /* (ctx, w, h, bpp) -> mode id or 0 */
{
    VidCtx *c = vid_ctx(a[0]);
    for (VidMode *m = GP(VidMode, c->modes); m; m = GP(VidMode, m->next))
        if ((int32_t)a[1] == m->width && (int32_t)a[2] == m->height && (int32_t)a[3] == m->bpp) {
            c->found_width = m->width;
            c->found_height = m->height;
            c->found_bpp = m->bpp;
            return (uint32_t)m->id;
        }
    return 0;
}

uint64_t vid_find_mode(const uint32_t *a)       /* (ctx, id) -> VidMode* or 0 */
{
    for (gptr p = vid_ctx(a[0])->modes; p; p = GP(VidMode, p)->next)
        if ((int32_t)a[1] == GP(VidMode, p)->id)
            return p;
    return 0;
}

/* the first mode from p on with r_find_bpp; remembered in ctx->find_iter */
static uint64_t vid_find_from(VidCtx *c, gptr p)
{
    for (; p; p = GP(VidMode, p)->next)
        if (GP(VidMode, p)->bpp == r_find_bpp) {
            c->find_iter = p;
            return (uint32_t)GP(VidMode, p)->id;
        }
    c->find_iter = 0;
    return 0;
}

uint64_t vid_find_first_mode(const uint32_t *a) /* (ctx, bpp) -> mode id or 0 */
{
    r_find_bpp = (int32_t)a[1];
    return vid_find_from(vid_ctx(a[0]), vid_ctx(a[0])->modes);
}

uint64_t vid_find_next_mode(const uint32_t *a)  /* (ctx) -> mode id or 0 */
{
    VidCtx *c = vid_ctx(a[0]);
    return vid_find_from(c, c->find_iter ? GP(VidMode, c->find_iter)->next : 0);
}

uint64_t vid_find_device(const uint32_t *a)     /* (ctx, id) -> VidDevice* or 0 */
{
    for (gptr p = vid_ctx(a[0])->devices; p; p = GP(VidDevice, p)->next)
        if ((int32_t)a[1] == GP(VidDevice, p)->id)
            return p;
    return 0;
}

uint64_t vid_set_device(const uint32_t *a)      /* (ctx, id) -> 0 */
{
    vid_ctx(a[0])->device_id = (int32_t)a[1];
    return 0;
}

uint64_t vid_close_screen(const uint32_t *a)    /* (ctx): the renderer survives mode changes */
{
    vid_ctx(a[0])->mode_id = 0;
    return 0;
}

/* (Re)create the back buffer, the RGB565 streaming texture and the CPU buffer at w x h,
 * leave the back buffer as the render target, cleared to black. 0 on failure. A replaced
 * CPU buffer stays allocated (low arena, no free). */
static int r_make_buffers(int w, int h)
{
    r_SDL_SetRenderTarget(r_renderer, 0);
    if (r_target)
        r_SDL_DestroyTexture(r_target);
    if (r_fbtex)
        r_SDL_DestroyTexture(r_fbtex);
    r_target = r_fbtex = 0;
    if (!(r_target = r_texture(SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_TARGET, w, h)))
        return 0;
    r_SDL_SetTextureScaleMode(r_target, SDL_SCALEMODE_LINEAR);
    if (!(r_fbtex = r_texture(SDL_PIXELFORMAT_RGB565, SDL_TEXTUREACCESS_STREAMING, w, h)))
        return 0;
    r_pitch = w * 2;
    r_cpu_fb = (gptr)low_alloc((uint32_t)(r_pitch * h), 16);   /* zeroed: fresh anonymous memory */
    r_tw = w;
    r_th = h;
    r_pw = 0;                           /* re-set the window's logical size at the next flip */
    r_SDL_SetRenderTarget(r_renderer, r_target);
    r_SDL_SetRenderDrawColor(r_renderer, 0, 0, 0, 255);
    r_SDL_RenderClear(r_renderer);
    printf("  [vid] back buffer %dx%d ARGB8888 target + RGB565 CPU buffer\n", w, h);
    return 1;
}

/* Vid_SetMode(ctx, hwnd, mode_id) -> 0 ok / 1 fail. First call creates the renderer on
 * the game's SDL window. The back buffer is sized for what the game will lay out: windowed
 * (-2) = window_width x window_height (BeginFrame2D 0x4caec0 reads them for the view),
 * anything else = the 640x480 mode; never smaller than the 640x480 frontend. A later call
 * with another size recreates the back buffer and the CPU buffer. */
uint64_t vid_set_mode(const uint32_t *a)
{
    VidCtx *c = vid_ctx(a[0]);
    int32_t mode = (int32_t)a[2];
    int gw = FB_W, gh = FB_H;
    int32_t ww = (int32_t)rd32(G_WINDOW_W), wh = (int32_t)rd32(G_WINDOW_H);
    if (mode == VID_MODE_WINDOWED && ww > 0 && wh > 0) {
        gw = ww;
        gh = wh;
    }
    r_gw = gw;
    r_gh = gh;
    int tw = gw > FB_W ? gw : FB_W;     /* target = max(game size, 640x480) */
    int th = gh > FB_H ? gh : FB_H;
    if (!r_renderer) {
        uint8_t *win = win_get(a[1]);
        if (!win && !(win = win_get(main_hwnd)))
            return 1;
        if (!(r_renderer = r_SDL_CreateRenderer(*(SDL_Window **)(win + WN_SDL), 0))) {
            r_sdl_error("SDL_CreateRenderer");
            return 1;
        }
        r_SDL_SetRenderVSync(r_renderer, 1);
        r_SDL_SetRenderDrawBlendMode(r_renderer, SDL_BLENDMODE_NONE);
        printf("  [vid] SDL renderer '%s', letterboxed into the window\n",
               r_SDL_GetRendererName(r_renderer));
    }
    if ((tw != r_tw || th != r_th) && !r_make_buffers(tw, th))
        return 1;
    vid_fill_format(c);
    c->mode_id = mode;
    c->fullscreen = mode != VID_MODE_WINDOWED;
    c->hwnd = a[1];
    printf("  [vid] Vid_SetMode(mode %d, hwnd 0x%x) -> game view %dx%d, back buffer %dx%d\n",
           mode, a[1], r_gw, r_gh, r_tw, r_th);
    return 0;
}

/* the part of the back buffer a flip shows: gameplay (ptrToGame set) is laid out for the
 * windowed size, the frontend for 640x480 */
static void r_present_size(int *w, int *h)
{
    int game = rd32(G_GAME) != 0;
    *w = game ? r_gw : FB_W;
    *h = game ? r_gh : FB_H;
}

uint64_t vid_set_gamma(const uint32_t *a)       /* (ctx, r, g, b) -> 0 (no gamma ramp yet) */
{
    (void)a;
    return 0;
}

/* Vid_EnableWrites: ctx->surface/pitch = the CPU buffer, without marking it as written */
uint64_t vid_lock_quiet(const uint32_t *a)
{
    VidCtx *c = vid_ctx(a[0]);
    if (!r_cpu_fb)
        return 1;
    c->surface = r_cpu_fb;
    c->pitch = r_pitch;
    c->flags |= VID_F_LOCKED | VID_F_WRITES;
    return 0;
}

/* Vid_GetSurface(ctx) = GrabSurface + EnableWrites */
uint64_t vid_get_surface(const uint32_t *a)
{
    r_fb_touched = 1;
    return vid_lock_quiet(a);
}

uint64_t vid_free_surface(const uint32_t *a)    /* (ctx) = DisableWrites + ReleaseSurface */
{
    VidCtx *c = vid_ctx(a[0]);
    c->surface = 0;
    c->flags &= ~(VID_F_LOCKED | VID_F_WRITES);
    return 0;
}

/* save the presented part of the back buffer (the current render target) to r_shot_path;
 * --shot at the last --frames flip and gta2ctl's shot (ctl.c) */
void r_save_shot(void) NASM(r_save_shot);
void r_save_shot(void)
{
    SDL_Rect rc = { 0, 0, 0, 0 };
    r_present_size(&rc.w, &rc.h);
    SDL_Surface *s = r_SDL_RenderReadPixels(r_renderer, &rc);
    if (!s) {
        r_sdl_error("SDL_RenderReadPixels");
        return;
    }
    r_SDL_SaveBMP(s, r_shot_path);
    r_SDL_DestroySurface(s);
    printf("  [vid] back buffer saved to %s (frame %u)\n", r_shot_path, r_frames);
}

/* Vid_FlipBuffers(ctx): present the back buffer (r_present_size of it). --shot=PATH saves
 * that part as BMP and --frames=N exits (status 0) after N flips. */
uint64_t vid_flip_buffers(const uint32_t *a)
{
    (void)a;
    if (!r_renderer)
        return 0;
    if (r_fb_touched) {
        r_fb_touched = 0;
        r_upload_fb();
    }
    r_frames++;
    map_frame();                        /* radar / full map over the finished frame (map.c) */
    input_keys_frame(r_frames);         /* --keys=FRAME:KEY,... */
    ctl_frame();                        /* gta2ctl commands and telemetry (ctl.c) */
    if (r_frames == 1 || r_frames % 120 == 0)
        printf("  [vid] flip %u: %u quads, %u blits, %u texture uploads so far, "
               "%u textures registered\n", r_frames, r_quads, r_blits, r_tex_builds, r_texs);
    int last = r_exit_frame && r_frames >= r_exit_frame;
    if (last && r_shot_path)
        r_save_shot();

    r_SDL_SetRenderTarget(r_renderer, 0);
    int pw, ph;
    r_present_size(&pw, &ph);
    if (pw != r_pw || ph != r_ph) {     /* window target: that size, letterboxed */
        r_pw = pw;
        r_ph = ph;
        r_SDL_SetRenderLogicalPresentation(r_renderer, pw, ph, SDL_LOGICAL_PRESENTATION_LETTERBOX);
        printf("  [vid] presenting %dx%d of the back buffer (flip %u)\n", r_pw, r_ph, r_frames);
    }
    r_SDL_SetRenderDrawColor(r_renderer, 0, 0, 0, 255);
    r_SDL_RenderClear(r_renderer);
    SDL_FRect src = { 0, 0, (float)r_pw, (float)r_ph };
    r_SDL_RenderTexture(r_renderer, r_target, &src, 0);
    r_SDL_RenderPresent(r_renderer);
    r_SDL_SetRenderTarget(r_renderer, r_target);
    if (last) {
        printf("  [vid] --frames: %u frames presented, exiting\n", r_frames);
        map_shutdown();
        ctl_exit();                     /* _exit skips atexit: remove the gta2ctl socket */
        _exit(0);
    }
    return 0;
}

/* Vid_ClearScreen(ctx, r, g, b, left, top, right, bottom): back buffer and CPU buffer */
uint64_t vid_clear_screen(const uint32_t *a)
{
    if (!r_renderer)
        return 0;
    uint8_t cr = (uint8_t)a[1], cg = (uint8_t)a[2], cb = (uint8_t)a[3];
    int32_t l = (int32_t)a[4], t = (int32_t)a[5], r = (int32_t)a[6], b = (int32_t)a[7];
    r_SDL_SetRenderDrawColor(r_renderer, cr, cg, cb, 255);
    SDL_FRect rc = { (float)l, (float)t, (float)(r - l), (float)(b - t) };
    r_SDL_RenderFillRect(r_renderer, &rc);
    /* CPU buffer: clamp the rect, fill with the packed 565 colour */
    uint16_t col = (uint16_t)((cr >> 3) << 11 | (cg >> 2) << 5 | cb >> 3);
    if (l < 0)
        l = 0;
    if (t < 0)
        t = 0;
    if (r > r_tw)
        r = r_tw;
    if (b > r_th)
        b = r_th;
    if (r - l <= 0)
        return 0;
    for (; t < b; t++) {
        uint16_t *row = (uint16_t *)(uintptr_t)(uint32_t)(r_cpu_fb + t * r_pitch) + l;
        for (int x = 0; x < r - l; x++)
            row[x] = col;
    }
    return 0;
}

uint64_t vid_shutdown_sys(const uint32_t *a)    /* (ctx) */
{
    (void)a;
    if (r_renderer) {
        r_SDL_DestroyRenderer(r_renderer);
        r_renderer = 0;
    }
    return 0;
}
