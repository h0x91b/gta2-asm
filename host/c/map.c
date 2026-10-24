/* map.c — the radar (a round minimap in the bottom-right corner) and the full-screen city
 * map on M, with fog of war that clears where the camera has been and is kept per level
 * in the overlay dir. Not in the original game. Design and RE facts: docs/map.md.
 *
 * 64-bit host C on the renderer's side of a frame: vid_flip_buffers calls map_frame just
 * before it presents, so everything here is SDL_RenderGeometry into the back buffer, over
 * the game's finished frame (HUD and K menu included), and --shot / gta2ctl shot see it.
 * Nothing here calls game code; the game state is only read (the image and the game's
 * heap are mapped 1:1, game.h).
 *
 *  - The map image is built once per level from the game's own map in memory and its style:
 *    for every column the topmost lid (MapBlocks, docs/re/map-and-renderer.md §2.2), its
 *    64x64 tile (StyleData +0x3c, StyleData_GetTilePixels 0x4C2EB0) through the tile's
 *    physical palette (StyleData +0x28 PALX, StyleData_GetPhysicalPalette 0x4BF530; PPAL
 *    pages at +0x2c, 64 palettes per 64 KB page, a colour every 256 bytes) box-filtered to
 *    MP_PX x MP_PX pixels, rotated / flipped as the lid word says. A flat lid (bit 12) is
 *    see-through where its texel is 0 and shows the lid under it. Idea and the rotation
 *    table from gta2-browser by M1sterMo (https://github.com/M1sterMo/gta2-browser, MIT,
 *    port/platform/map_web.cpp gta2_port_map_render_rows @66d3462); written anew here.
 *  - Fog: one byte per tile, 255 unseen .. 0 seen. Every running frame, the tiles inside the
 *    player camera's world rect (Camera +0x20 cameraBoundaries) and within MP_SEE_R of the
 *    player lose MP_FOG_STEP, so a newly
 *    seen street fades in over a few frames; the 256x256 fog texture is drawn with linear
 *    filtering, which softens its edges. Saved as maps/<level>.fog (65536 bytes) under the
 *    overlay dir (the host's cwd, vfs.c), loaded when the game opens the level's .gmp.
 *  - Markers: the HUD's own arrows (g_HudManager 0x672F40 +0x1F18 HudArrowPool, 17 x
 *    HudArrow 0x7C, docs/re/hud-and-menus.md §2.1): those the HUD shows now (inUse, visible),
 *    at their current target's position, in the arrow's colour; on the radar's rim when
 *    they are out of range, pointing their way.
 */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include "renderer.h"
#include "ctl.h"
#include "menu/dm.h"

#define G_MAP_BLOCKS    0x662C08        /* MapBlocks* (re/globals.csv) */
#define G_STYLE         0x670684        /* StyleData* (re/globals.csv) */
#define G_HUD           0x672F40        /* HudManager* (re/globals.csv) */
#define G_WINDOW_W      0x673578
#define G_WINDOW_H      0x6732E8

#define MP_PX           8               /* map image pixels per tile */
#define MP_SIZE         (256 * MP_PX)
#define MP_TILES        992             /* lid tiles that exist (the original's range) */
#define MP_FOG_STEP     24              /* fog lost per frame in view: ~10 frames to clear */
#define MP_SEE_R        9               /* tiles around the player always seen */
#define MP_SAVE_FRAMES  600             /* save a changed fog this often */
#define MP_SEG          72              /* radar circle segments */
#define MP_VMAX         16384

/* DIK codes the full map uses */
enum {
    K_ESC = 0x01, K_MINUS = 0x0C, K_EQUALS = 0x0D, K_SPACE = 0x39, K_NUM_MINUS = 0x4A,
    K_NUM_PLUS = 0x4E, K_UP = 0xC8, K_PGUP = 0xC9, K_LEFT = 0xCB, K_RIGHT = 0xCD,
    K_DOWN = 0xD0, K_PGDN = 0xD1,
};

/* config.yaml map: (config.c sets the defaults before main) */
uint8_t map_minimap_on;                 /* map.minimap */
uint8_t map_rotate;                     /* map.rotate: heading-up radar, else north-up */
uint8_t map_fog_on;                     /* map.fog: false = the whole city is shown */
uint8_t map_key_dik;                    /* map.key, DIK (default M) */

int dm_is_open(void);                   /* menu/core.c */

static char mp_level[32];               /* "wil": the .gmp's base name, lower case */
static gptr mp_built_for;               /* the Game* the image was built for */
static gptr mp_built_grid;              /* ... and its MapGrid* */
static SDL_Texture *mp_tex, *mp_fog_tex;
static uint8_t mp_fog[65536];           /* per tile, y * 256 + x: 255 unseen .. 0 seen */
static uint8_t mp_solid[65536];         /* the column has a lid: counts for "explored" */
static uint32_t mp_solid_n;
static uint8_t mp_fog_dirty, mp_fog_tex_dirty;
static uint32_t mp_saved_frame;

static uint8_t mp_open;                 /* the full map is up */
static uint8_t mp_held[256];            /* keys held while it is up (pan / zoom) */
static double mp_cx, mp_cy, mp_zoom = 2.5; /* full map: centre (tiles), zoom (x fit) */
static double mp_head = -4, mp_range;   /* radar: shown heading (radians), radius (tiles) */

/* ---- the batch: untextured or one texture, flushed with one SDL_RenderGeometry -------- */

static SDL_Vertex vb[MP_VMAX];
static int ib[MP_VMAX * 3 / 2];
static int nv, ni;

static void flush(SDL_Texture *tex)
{
    if (ni)
        r_SDL_RenderGeometry(r_renderer, tex, vb, nv, ib, ni);
    nv = ni = 0;
}

static int vtx(float x, float y, uint32_t argb, float u, float v)
{
    if (nv >= MP_VMAX)
        return nv - 1;
    vb[nv] = (SDL_Vertex){ x, y, (argb >> 16 & 255) / 255.0f, (argb >> 8 & 255) / 255.0f,
                           (argb & 255) / 255.0f, (argb >> 24) / 255.0f, u, v };
    return nv++;
}

static void tri_i(int a, int b, int c)
{
    if (ni + 3 > (int)(sizeof ib / sizeof ib[0]))
        return;
    ib[ni++] = a, ib[ni++] = b, ib[ni++] = c;
}

static void rect(float x0, float y0, float x1, float y1, uint32_t argb)
{
    int a = vtx(x0, y0, argb, 0, 0), b = vtx(x1, y0, argb, 0, 0);
    int c = vtx(x1, y1, argb, 0, 0), d = vtx(x0, y1, argb, 0, 0);
    tri_i(a, b, c);
    tri_i(a, c, d);
}

static void disc(float cx, float cy, float r, int seg, uint32_t argb)
{
    int c = vtx(cx, cy, argb, 0, 0), first = nv;
    for (int i = 0; i < seg; i++) {
        double a = i * 2 * M_PI / seg;
        vtx(cx + (float)(r * cos(a)), cy + (float)(r * sin(a)), argb, 0, 0);
    }
    for (int i = 0; i < seg; i++)
        tri_i(c, first + i, first + (i + 1) % seg);
}

static void ring(float cx, float cy, float r0, float r1, int seg, uint32_t argb)
{
    int first = nv;
    for (int i = 0; i < seg; i++) {
        double a = i * 2 * M_PI / seg, c = cos(a), s = sin(a);
        vtx(cx + (float)(r0 * c), cy + (float)(r0 * s), argb, 0, 0);
        vtx(cx + (float)(r1 * c), cy + (float)(r1 * s), argb, 0, 0);
    }
    for (int i = 0; i < seg; i++) {
        int a = first + 2 * i, b = first + 2 * ((i + 1) % seg);
        tri_i(a, a + 1, b + 1);
        tri_i(a, b + 1, b);
    }
}

/* an arrow head at (x, y) pointing along (dx, dy) (unit), `len` long, with a dark rim */
static void arrow(float x, float y, double dx, double dy, float len, uint32_t argb)
{
    for (int pass = 0; pass < 2; pass++) {
        float l = pass ? len : len + 2.5f, w = l * 0.62f;
        uint32_t c = pass ? argb : 0xE0000000u;
        float tx = x + (float)(dx * l * 0.6), ty = y + (float)(dy * l * 0.6);
        float bx = x - (float)(dx * l * 0.4), by = y - (float)(dy * l * 0.4);
        float nx = (float)-dy * w * 0.5f, ny = (float)dx * w * 0.5f;
        float mx = x - (float)(dx * l * 0.15), my = y - (float)(dy * l * 0.15);
        int t = vtx(tx, ty, c, 0, 0), m = vtx(mx, my, c, 0, 0);
        int a = vtx(bx + nx, by + ny, c, 0, 0), b = vtx(bx - nx, by - ny, c, 0, 0);
        tri_i(t, a, m);
        tri_i(t, m, b);
    }
}

/* ---- a 5x7 font for the full map's two lines of text ------------------------------------ */

static const char font_chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%.-+/:,|";
static const uint8_t font[][7] = {
    {14,17,17,31,17,17,17}, {30,17,17,30,17,17,30}, {14,17,16,16,16,17,14}, {30,17,17,17,17,17,30},
    {31,16,16,30,16,16,31}, {31,16,16,30,16,16,16}, {14,17,16,23,17,17,15}, {17,17,17,31,17,17,17},
    {14,4,4,4,4,4,14},      {7,2,2,2,2,18,12},      {17,18,20,24,20,18,17}, {16,16,16,16,16,16,31},
    {17,27,21,21,17,17,17}, {17,17,25,21,19,17,17}, {14,17,17,17,17,17,14}, {30,17,17,30,16,16,16},
    {14,17,17,17,21,18,13}, {30,17,17,30,20,18,17}, {15,16,16,14,1,1,30},   {31,4,4,4,4,4,4},
    {17,17,17,17,17,17,14}, {17,17,17,17,17,10,4},  {17,17,17,21,21,21,10}, {17,17,10,4,10,17,17},
    {17,17,17,10,4,4,4},    {31,1,2,4,8,16,31},     {14,17,19,21,25,17,14}, {4,12,4,4,4,4,14},
    {14,17,1,2,4,8,31},     {31,2,4,2,1,17,14},     {2,6,10,18,31,2,2},     {31,16,30,1,1,17,14},
    {6,8,16,30,17,17,14},   {31,1,2,4,8,8,8},       {14,17,17,14,17,17,14}, {14,17,17,15,1,2,12},
    {24,25,2,4,8,19,3},     {0,0,0,0,0,12,12},      {0,0,0,31,0,0,0},       {0,4,4,31,4,4,0},
    {1,1,2,4,8,16,16},      {0,12,12,0,12,12,0},    {0,0,0,0,12,4,8},       {4,4,4,4,4,4,4},
};

static float text_w(const char *s, float px)
{
    return (float)strlen(s) * 6 * px - px;
}

static void text(const char *s, float x, float y, float px, uint32_t argb)
{
    for (; *s; s++, x += 6 * px) {
        const char *at = *s ? strchr(font_chars, *s >= 'a' && *s <= 'z' ? *s - 32 : *s) : 0;
        if (!at)
            continue;
        const uint8_t *g = font[at - font_chars];
        for (int r = 0; r < 7; r++)
            for (int c = 0; c < 5; c++)
                if (g[r] >> (4 - c) & 1)
                    rect(x + c * px, y + r * px, x + (c + 1) * px, y + (r + 1) * px, argb);
    }
}

/* ---- fog: load, save, per-frame update ------------------------------------------------- */

static void fog_path(char *out, size_t n)
{
    snprintf(out, n, "maps/%s.fog", mp_level);
}

static void fog_save(void)
{
    if (!mp_level[0] || !mp_fog_dirty)
        return;
    char path[64], tmp[72];
    fog_path(path, sizeof path);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    mkdir("maps", 0755);
    FILE *f = fopen(tmp, "wb");
    if (!f || fwrite(mp_fog, 1, sizeof mp_fog, f) != sizeof mp_fog) {
        printf("map: could not write %s: %s\n", tmp, strerror(errno));
        if (f)
            fclose(f);
        return;
    }
    fclose(f);
    if (rename(tmp, path)) {
        printf("map: could not write %s: %s\n", path, strerror(errno));
        return;
    }
    mp_fog_dirty = 0;
    mp_saved_frame = r_frames;
}

static void fog_load(void)
{
    char path[64];
    fog_path(path, sizeof path);
    memset(mp_fog, 255, sizeof mp_fog);
    FILE *f = fopen(path, "rb");
    size_t n = f ? fread(mp_fog, 1, sizeof mp_fog, f) : 0;
    if (f)
        fclose(f);
    if (f && n != sizeof mp_fog) {
        printf("map: %s is %zu bytes, not %zu: starting unexplored\n", path, n, sizeof mp_fog);
        memset(mp_fog, 255, sizeof mp_fog);
    }
    uint32_t seen = 0;
    for (int i = 0; i < 65536; i++)
        seen += mp_fog[i] < 128;
    printf("map: level %s, explored tiles %u (%s)\n", mp_level, seen, n ? path : "new");
    mp_fog_dirty = 0;
    mp_fog_tex_dirty = 1;
}

/* files.c: the game opens a file; a .gmp is the level it is about to play */
void map_on_open(const char *name)
{
    size_t n = strlen(name);
    if (n < 5 || strcasecmp(name + n - 4, ".gmp"))
        return;
    const char *base = name + n - 4;
    while (base > name && base[-1] != '\\' && base[-1] != '/' && base[-1] != ':')
        base--;
    char level[sizeof mp_level];
    size_t len = (size_t)(name + n - 4 - base);
    if (len >= sizeof level)
        len = sizeof level - 1;
    for (size_t i = 0; i < len; i++) {
        char c = base[i];
        level[i] = (c >= 'A' && c <= 'Z') ? c + 32 : (c == '/' || c == '.') ? '_' : c;
    }
    level[len] = 0;
    if (!strcmp(level, mp_level))
        return;                         /* the same level again: the fog stays as it is */
    fog_save();
    strcpy(mp_level, level);
    fog_load();
    mp_built_for = 0;                   /* rebuild the image */
}

void map_reset_fog(void)
{
    memset(mp_fog, 255, sizeof mp_fog);
    mp_fog_dirty = mp_fog_tex_dirty = 1;
    printf("map: frame %u, explored map of %s reset\n", r_frames, mp_level);
}

static void fog_update(void)
{
    Game *g = game();
    Player *pl = game_player();
    if (!g || !pl || g->gameStatus != 1)
        return;
    WorldRect *v = &pl->viewCamera.cameraBoundaries;
    int x0 = v->left >> 14, x1 = v->right >> 14, y0 = v->top >> 14, y1 = v->bottom >> 14;
    if (x1 < x0 || y1 < y0 || x1 - x0 > 80 || y1 - y0 > 80)
        return;                         /* the camera is not set up yet */
    /* the camera's rect lags behind a fast car: also a disc around the player */
    int32_t px, py, pz;
    int have_p = ctl_pos(&px, &py, &pz);
    double cx = px / 16384.0, cy = py / 16384.0;
    if (have_p) {
        x0 = x0 < (int)cx - MP_SEE_R ? x0 : (int)cx - MP_SEE_R;
        x1 = x1 > (int)cx + MP_SEE_R ? x1 : (int)cx + MP_SEE_R;
        y0 = y0 < (int)cy - MP_SEE_R ? y0 : (int)cy - MP_SEE_R;
        y1 = y1 > (int)cy + MP_SEE_R ? y1 : (int)cy + MP_SEE_R;
    }
    int rx0 = v->left >> 14, rx1 = v->right >> 14, ry0 = v->top >> 14, ry1 = v->bottom >> 14;
    x0 = x0 < 0 ? 0 : x0, y0 = y0 < 0 ? 0 : y0;
    x1 = x1 > 255 ? 255 : x1, y1 = y1 > 255 ? 255 : y1;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            int in_rect = x >= rx0 && x <= rx1 && y >= ry0 && y <= ry1;
            double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
            if (!in_rect && !(have_p && dx * dx + dy * dy <= MP_SEE_R * MP_SEE_R))
                continue;
            uint8_t *f = &mp_fog[y * 256 + x];
            if (*f) {
                *f = *f > MP_FOG_STEP ? *f - MP_FOG_STEP : 0;
                mp_fog_dirty = mp_fog_tex_dirty = 1;
            }
        }
}

static uint32_t fog_explored_pct(void)
{
    uint32_t seen = 0;
    for (int i = 0; i < 65536; i++)
        seen += mp_solid[i] && mp_fog[i] < 128;
    return mp_solid_n ? (seen * 100 + mp_solid_n / 2) / mp_solid_n : 0;
}

static void fog_upload(void)
{
    static uint32_t px[65536];
    if (!mp_fog_tex_dirty || !mp_fog_tex)
        return;
    for (int i = 0; i < 65536; i++) {
        uint32_t a = map_fog_on ? mp_fog[i] * 248u / 255u : 0;
        px[i] = a << 24 | 0x0A0C12;
    }
    r_SDL_UpdateTexture(mp_fog_tex, 0, px, 256 * 4);
    mp_fog_tex_dirty = 0;
}

/* ---- the map image ------------------------------------------------------------------- */

struct cell { uint8_t r, g, b, cov; };  /* a tile's MP_PX x MP_PX cell: colour, coverage 0..64 */

/* every lid tile box-filtered to MP_PX x MP_PX cells; texel 0 counts as see-through (a flat
 * lid shows what is under it there; a solid one is drawn black there, as Seq 65 found) */
static void tiles_reduce(struct cell (*out)[MP_PX * MP_PX])
{
    StyleData *st = GP(StyleData, rd32(G_STYLE));
    const int step = 64 / MP_PX;
    for (uint32_t t = 0; t < MP_TILES; t++) {
        gptr pix = (gptr)st->tiles + ((t & ~3u) << 6 | (t & 3)) * 64;  /* 0x4C2EB0 */
        uint32_t phys = rd16((gptr)st->palleteIndex + t * 2);           /* 0x4BF530 */
        gptr pal = (gptr)st->physical_palettes + (phys >> 6) * 0x10000 + (phys & 63) * 4;
        for (int cy = 0; cy < MP_PX; cy++)
            for (int cx = 0; cx < MP_PX; cx++) {
                uint32_t r = 0, g = 0, b = 0, n = 0;
                for (int y = 0; y < step; y++)
                    for (int x = 0; x < step; x++) {
                        uint8_t i = rd8(pix + (uint32_t)(cy * step + y) * 256 + (uint32_t)(cx * step + x));
                        if (!i)
                            continue;
                        uint32_t c = rd32(pal + i * 256u);
                        r += c >> 16 & 255, g += c >> 8 & 255, b += c & 255, n++;
                    }
                struct cell *o = &out[t][cy * MP_PX + cx];
                o->r = (uint8_t)(n ? r / n : 0), o->g = (uint8_t)(n ? g / n : 0);
                o->b = (uint8_t)(n ? b / n : 0);
                o->cov = (uint8_t)(n * 64 / (uint32_t)(step * step));
            }
    }
}

/* a lid's cell at (u, v) of the tile drawn rotated / flipped as the lid word says */
static const struct cell *lid_cell(struct cell (*cells)[MP_PX * MP_PX], uint16_t lid, int u, int v)
{
    const int m = MP_PX - 1;
    int tu, tv;
    switch (lid >> 14 & 3) {
    case 1:  tu = v, tv = m - u; break;
    case 2:  tu = m - u, tv = m - v; break;
    case 3:  tu = m - v, tv = u; break;
    default: tu = u, tv = v; break;
    }
    if (lid >> 13 & 1)
        tu = m - tu;
    return &cells[lid & 0x3FF][tv * MP_PX + tu];
}

static int map_build(void)
{
    MapBlocks *mb = GP(MapBlocks, rd32(G_MAP_BLOCKS));
    StyleData *st = GP(StyleData, rd32(G_STYLE));
    if (!mb || !mb->grid || !st || !st->tiles || !st->palleteIndex || !st->physical_palettes)
        return 0;
    if (!mp_tex) {
        mp_tex = r_texture(SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, MP_SIZE, MP_SIZE);
        mp_fog_tex = r_texture(SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, 256, 256);
        if (!mp_tex || !mp_fog_tex)
            return 0;
        r_SDL_SetTextureBlendMode(mp_tex, SDL_BLENDMODE_BLEND);
        r_SDL_SetTextureScaleMode(mp_tex, SDL_SCALEMODE_LINEAR);
        r_SDL_SetTextureBlendMode(mp_fog_tex, SDL_BLENDMODE_BLEND);
        r_SDL_SetTextureScaleMode(mp_fog_tex, SDL_SCALEMODE_LINEAR);
    }
    struct cell (*cells)[MP_PX * MP_PX] = malloc(sizeof *cells * MP_TILES);
    uint32_t *img = malloc((size_t)MP_SIZE * MP_SIZE * 4);
    if (!cells || !img)
        fail("map: out of memory");
    tiles_reduce(cells);
    MapGrid *grid = GP(MapGrid, mb->grid);
    mp_solid_n = 0;
    for (int ty = 0; ty < 256; ty++)
        for (int tx = 0; tx < 256; tx++) {
            /* the column's lids, top down, to the first solid one (MapBlocks_GetBlock 0x4653C0) */
            gptr col = grid->columns + grid->base[ty * 256 + tx] * 4;
            int height = rd8(col), offset = rd8(col + 1), n = 0, top_z = 0;
            uint16_t lids[8];
            for (int z = height - 1; z >= offset && z >= 0 && n < 8; z--) {
                gptr blk = grid->blocks + rd32(col + 4 + (uint32_t)(z - offset) * 4) * 12;
                uint16_t lid = rd16(blk + 8);
                if (!(lid & 0x3FF) || (lid & 0x3FF) >= MP_TILES)
                    continue;
                if (!n)
                    top_z = z;
                lids[n++] = lid;
                if (!(lid & 0x1000))
                    break;              /* solid: nothing under it shows */
            }
            mp_solid[ty * 256 + tx] = n > 0;
            mp_solid_n += n > 0;
            /* higher roofs a little brighter, so blocks read apart from the street */
            double shade = n ? 0.80 + 0.07 * (top_z - 2) : 1;
            shade = shade < 0.72 ? 0.72 : shade > 1.15 ? 1.15 : shade;
            for (int v = 0; v < MP_PX; v++)
                for (int u = 0; u < MP_PX; u++) {
                    double r = 0, g = 0, b = 0, a = 0;     /* bottom up, premultiplied */
                    for (int l = n - 1; l >= 0; l--) {
                        const struct cell *c = lid_cell(cells, lids[l], u, v);
                        double k = (lids[l] & 0x1000) ? c->cov / 64.0 : 1;
                        r = c->r * k + r * (1 - k), g = c->g * k + g * (1 - k);
                        b = c->b * k + b * (1 - k), a = k + a * (1 - k);
                    }
                    uint32_t R = (uint32_t)fmin(255, r * shade), G = (uint32_t)fmin(255, g * shade);
                    uint32_t B = (uint32_t)fmin(255, b * shade), A = (uint32_t)(a * 255);
                    img[(size_t)(ty * MP_PX + v) * MP_SIZE + (size_t)(tx * MP_PX + u)] =
                        A << 24 | R << 16 | G << 8 | B;
                }
        }
    r_SDL_UpdateTexture(mp_tex, 0, img, MP_SIZE * 4);
    free(img);
    free(cells);
    mp_fog_tex_dirty = 1;
    printf("map: frame %u, image of %s built (%dx%d, %u tiles with a lid)\n", r_frames,
           mp_level[0] ? mp_level : "?", MP_SIZE, MP_SIZE, mp_solid_n);
    return 1;
}

/* ---- the player and the markers ---------------------------------------------------- */

struct player_view {
    double x, y;                        /* tiles */
    double fx, fy;                      /* the facing direction, unit */
    int in_car;
};

static int player_view(struct player_view *pv)
{
    Ped *ped = ctl_ped();
    int32_t x, y, z;
    if (!ped || !ctl_pos(&x, &y, &z))
        return 0;
    Car *car = GP(Car, ped->currentCar);
    PedGameObject *go = GP(PedGameObject, ped->gameObject);
    Sprite *s = car ? GP(Sprite, car->body) : go ? GP(Sprite, go->body) : 0;
    double h = (s ? (uint16_t)s->rotation : (uint16_t)ped->rotation) * (2 * M_PI / 1440);
    /* Ang16 0 faces +y (south on screen), x = sin(h), y = cos(h) (ctl_game.c; measured: a car
     * at heading 0 driven forward went from y 195 to 199) */
    pv->x = x / 16384.0, pv->y = y / 16384.0;
    pv->fx = sin(h), pv->fy = cos(h);
    pv->in_car = car != 0;
    return 1;
}

/* a HUD arrow sprite's colour (USER sprite, type 6, as Hud_Arrow_Draw 0x4C82C0 draws it):
 * the mean of its opaque texels through its own palette, brightened to a full channel.
 * StyleData_GetSpriteIndex 0x4BF2A0, _GetSpriteEntry 0x4BF280, _GetPaletteIndex 0x4BF430
 * (kind 2 = sprite), all thiscall; cached per level */
static uint32_t arrow_rgb[64];

static uint32_t arrow_colour(int id)
{
    if (id < 0 || id >= 64)
        return 0xFFE0E0E0u;
    if (arrow_rgb[id])
        return arrow_rgb[id];
    gptr st = rd32(G_STYLE);
    uint32_t idx = game_thiscall(0x4BF2A0, st, 2, 6u, (uint32_t)id) & 0xFFFF;
    SpriteEntry *e = GP(SpriteEntry, game_thiscall(0x4BF280, st, 1, idx));
    uint32_t virt = game_thiscall(0x4BF430, st, 2, 2u, idx) & 0xFFFF;
    uint32_t phys = rd16((gptr)GP(StyleData, st)->palleteIndex + virt * 2);
    gptr pal = (gptr)GP(StyleData, st)->physical_palettes + (phys >> 6) * 0x10000 + (phys & 63) * 4;
    uint32_t r = 0, g = 0, b = 0, n = 0;
    for (int y = 0; e && e->ptr && y < e->h; y++)
        for (int x = 0; x < e->w; x++) {
            uint8_t i = rd8(e->ptr + (uint32_t)y * 256 + (uint32_t)x);
            if (!i)
                continue;
            uint32_t c = rd32(pal + i * 256u);
            r += c >> 16 & 255, g += c >> 8 & 255, b += c & 255, n++;
        }
    uint32_t m = r > g ? (r > b ? r : b) : (g > b ? g : b);
    if (!n || !m)
        return arrow_rgb[id] = 0xFFE0E0E0u;
    arrow_rgb[id] = 0xFF000000u | (r * 255 / m) << 16 | (g * 255 / m) << 8 | (b * 255 / m);
    printf("map: arrow sprite %d colour 0x%06x\n", id, arrow_rgb[id] & 0xFFFFFF);
    return arrow_rgb[id];
}

struct marker {
    double x, y;
    uint32_t argb;
    int flash;
};

static int markers(struct marker *out, int max)
{
    gptr hud = rd32(G_HUD);
    if (!hud)
        return 0;
    HudArrowPool *pool = GP(HudArrowPool, hud + 0x1F18);
    int n = 0;
    for (int i = 0; i < 17 && n < max; i++) {
        HudArrow *a = &pool->arrows[i];
        if (!a->inUse || !a->visible || !a->current)
            continue;
        HudArrowTarget *t = GP(HudArrowTarget, a->current);
        if (t->mode == 0 || t->mode == 6)
            continue;                   /* no target, or another player (multiplayer) */
        static const uint32_t colours[] = { 0xFFE0E0E0, 0xFFFFD21F, 0xFFFF3B30, 0xFF38D84A,
                                            0xFF9AA0A6, 0xFFFF5CA8 };
        /* 1-3: a gang job (yellow / red / green); 4: a gang's own arrow, in its sprite's
         * colour; 5: the mission target, flashing */
        uint32_t c = a->colour >= 1 && a->colour <= 3 ? colours[a->colour]
                   : a->colour == 4 ? arrow_colour(a->spriteId) : colours[5];
        out[n++] = (struct marker){ t->posX / 16384.0, t->posY / 16384.0, c, a->colour == 5 };
    }
    return n;
}

/* ---- the radar ---------------------------------------------------------------------- */

static void radar_draw(const struct player_view *pv, float bw, float bh)
{
    float k = bh / 480;                 /* 640x480 units */
    float R = 62 * k, rim = 5 * k;
    float cx = bw - R - rim - 14 * k, cy = bh - R - rim - 14 * k;
    /* range: wider in a car, eased */
    double want = pv->in_car ? 17 : 11;
    mp_range = mp_range ? mp_range + (want - mp_range) * 0.05 : want;
    double s = R / mp_range;            /* pixels per tile */
    /* screen basis: ex, ey are the world directions of screen right and down */
    double ex = 1, exy = 0, eyx = 0, ey = 1;
    if (map_rotate) {
        double want_h = atan2(pv->fy, pv->fx);
        if (mp_head < -3.5)
            mp_head = want_h;
        double d = remainder(want_h - mp_head, 2 * M_PI);
        mp_head = remainder(mp_head + d * 0.25, 2 * M_PI);
        double fx = cos(mp_head), fy = sin(mp_head);
        ex = -fy, exy = fx;             /* right of facing */
        eyx = -fx, ey = -fy;            /* down = behind */
    } else {
        mp_head = -4;
    }
    /* world offset -> screen, and back for the fan's texture coordinates */
#define TO_SX(dx, dy) (cx + (float)(((dx) * ex + (dy) * exy) * s))
#define TO_SY(dx, dy) (cy + (float)(((dx) * eyx + (dy) * ey) * s))

    disc(cx, cy, R + rim, MP_SEG, 0xD8050608u);
    disc(cx, cy, R, MP_SEG, 0xFF0D1016u);
    flush(0);
    for (int layer = 0; layer < 2; layer++) {
        int c = vtx(cx, cy, 0xFFFFFFFFu, (float)(pv->x / 256), (float)(pv->y / 256)), first = nv;
        for (int i = 0; i < MP_SEG; i++) {
            double a = i * 2 * M_PI / MP_SEG, ox = R * cos(a), oy = R * sin(a);
            double wx = pv->x + (ox * ex + oy * eyx) / s, wy = pv->y + (ox * exy + oy * ey) / s;
            vtx(cx + (float)ox, cy + (float)oy, 0xFFFFFFFFu, (float)(wx / 256), (float)(wy / 256));
        }
        for (int i = 0; i < MP_SEG; i++)
            tri_i(c, first + i, first + (i + 1) % MP_SEG);
        flush(layer ? mp_fog_tex : mp_tex);
        if (!map_fog_on)
            break;
    }
    ring(cx, cy, R - 1.2f * k, R, MP_SEG, 0x40FFFFFFu);
    /* north on the rim */
    double nx = TO_SX(0, -1) - cx, ny = TO_SY(0, -1) - cy, nl = hypot(nx, ny);
    nx /= nl, ny /= nl;
    arrow(cx + (float)(nx * (R + rim * 0.3)), cy + (float)(ny * (R + rim * 0.3)), nx, ny,
          9 * k, 0xFFE8E8E8u);
    /* markers: inside where they are, else on the rim pointing their way */
    struct marker m[17];
    int nm = markers(m, 17);
    int blink = (r_frames / 8) & 1;
    for (int i = 0; i < nm; i++) {
        double dx = m[i].x - pv->x, dy = m[i].y - pv->y;
        float sx = TO_SX(dx, dy), sy = TO_SY(dx, dy);
        double ox = sx - cx, oy = sy - cy, d = hypot(ox, oy);
        uint32_t c = m[i].flash && blink ? 0xFFFFFFFFu : m[i].argb;
        if (d < R - 5 * k) {
            disc(sx, sy, 4.2f * k, 12, 0xE0000000u);
            disc(sx, sy, 3.0f * k, 12, c);
        } else {
            ox /= d, oy /= d;
            arrow(cx + (float)(ox * (R + rim * 0.5)), cy + (float)(oy * (R + rim * 0.5)), ox, oy,
                  10 * k, c);
        }
    }
    /* the player */
    double px = TO_SX(pv->fx, pv->fy) - cx, py = TO_SY(pv->fx, pv->fy) - cy, pl = hypot(px, py);
    arrow(cx, cy, px / pl, py / pl, 11 * k, 0xFFFFFFFFu);
    flush(0);
#undef TO_SX
#undef TO_SY
}

/* ---- the full map -------------------------------------------------------------------- */

static void full_draw(const struct player_view *pv, float bw, float bh)
{
    float k = bh / 480;
    double fit = (bh - 60 * k) / 256.0;     /* the whole 256 tiles on screen at zoom 1 */
    /* keys held: zoom, then pan below */
    int zin = mp_held[K_PGUP] || mp_held[K_EQUALS] || mp_held[K_NUM_PLUS];
    int zout = mp_held[K_PGDN] || mp_held[K_MINUS] || mp_held[K_NUM_MINUS];
    mp_zoom *= zin ? 1.03 : zout ? 1 / 1.03 : 1;
    mp_zoom = mp_zoom < 0.8 ? 0.8 : mp_zoom > 8 ? 8 : mp_zoom;
    double s = fit * mp_zoom;
    float cx = bw / 2, cy = bh / 2 + 6 * k;
    /* keep the city on screen: centred on an axis it fits, else no empty margin (only the
     * view is clamped; mp_cx/cy stay where the player panned, within the city) */
    double hw = cx / s, hh = (bh - 30 * k - cy) / s, vx, vy;
#define VIEW() (vx = hw >= 128 ? 128 : mp_cx < hw ? hw : mp_cx > 256 - hw ? 256 - hw : mp_cx, \
                vy = hh >= 128 ? 128 : mp_cy < hh ? hh : mp_cy > 256 - hh ? 256 - hh : mp_cy)
    VIEW();
    int px_ = (mp_held[K_RIGHT] != 0) - (mp_held[K_LEFT] != 0);
    int py_ = (mp_held[K_DOWN] != 0) - (mp_held[K_UP] != 0);
    if (px_ || py_) {                   /* pan from what is shown, about a 1/60 screen a frame */
        mp_cx = vx + px_ * 4.5 * k / s, mp_cy = vy + py_ * 4.5 * k / s;
        VIEW();
    }
#undef VIEW
#define SX(wx) (cx + (float)(((wx) - vx) * s))
#define SY(wy) (cy + (float)(((wy) - vy) * s))
    rect(0, 0, bw, bh, 0xF0080A0Eu);
    rect(SX(0), SY(0), SX(256), SY(256), 0xFF0D1016u);
    flush(0);
    for (int layer = 0; layer < 2; layer++) {
        int a = vtx(SX(0), SY(0), 0xFFFFFFFFu, 0, 0), b = vtx(SX(256), SY(0), 0xFFFFFFFFu, 1, 0);
        int c = vtx(SX(256), SY(256), 0xFFFFFFFFu, 1, 1), d = vtx(SX(0), SY(256), 0xFFFFFFFFu, 0, 1);
        tri_i(a, b, c);
        tri_i(a, c, d);
        flush(layer ? mp_fog_tex : mp_tex);
        if (!map_fog_on)
            break;
    }
    /* markers, then the player (pulsing so it is found at once) */
    struct marker m[17];
    int nm = markers(m, 17), blink = (r_frames / 8) & 1;
    for (int i = 0; i < nm; i++) {
        uint32_t c = m[i].flash && blink ? 0xFFFFFFFFu : m[i].argb;
        disc(SX(m[i].x), SY(m[i].y), 6 * k, 14, 0xE0000000u);
        disc(SX(m[i].x), SY(m[i].y), 4.5f * k, 14, c);
    }
    float pulse = (float)(0.5 + 0.5 * sin(r_frames * 0.15));
    ring(SX(pv->x), SY(pv->y), (9 + 5 * pulse) * k, (10.5f + 5 * pulse) * k, 32,
         (uint32_t)(255 * (1 - pulse)) << 24 | 0xFFFFFF);
    arrow(SX(pv->x), SY(pv->y), pv->fx, pv->fy, 13 * k, 0xFFFFFFFFu);
    /* the two text lines */
    char top[96], help[] = "M CLOSE  |  ARROWS MOVE  |  +/- ZOOM  |  SPACE YOU";
    snprintf(top, sizeof top, "%s  |  EXPLORED %u%%", mp_level[0] ? mp_level : "MAP",
             fog_explored_pct());
    if (!map_fog_on)
        snprintf(top, sizeof top, "%s  |  FOG OFF", mp_level[0] ? mp_level : "MAP");
    float px = 2 * k;
    rect(0, 0, bw, 24 * k, 0xC0000000u);
    text(top, (bw - text_w(top, px)) / 2, 5 * k, px, 0xFFFFD21Fu);
    float hp = 1.4f * k;
    text(help, (bw - text_w(help, hp)) / 2, bh - 14 * k, hp, 0xFFB8BCC4u);
    flush(0);
#undef SX
#undef SY
}

/* ---- the frame and the keys ---------------------------------------------------------- */

int map_is_open(void)
{
    return mp_open;
}

/* menu/core.c dm_key, first, while the K menu is closed: 1 = consumed */
int map_key(int dik, int down)
{
    if (!mp_open) {
        if (!down || dik != map_key_dik || !mp_built_for || !rd32(G_GAME) || !game_player())
            return 0;
        struct player_view pv;
        if (!player_view(&pv))
            return 0;
        mp_open = 1;
        mp_cx = pv.x, mp_cy = pv.y;
        memset(mp_held, 0, sizeof mp_held);
        printf("map: frame %u, map opened (explored %u%%)\n", r_frames, fog_explored_pct());
        return 1;
    }
    mp_held[dik & 255] = (uint8_t)(down != 0);
    if (down && (dik == map_key_dik || dik == K_ESC)) {
        mp_open = 0;
        printf("map: frame %u, map closed\n", r_frames);
    } else if (down && dik == K_SPACE) {
        struct player_view pv;
        if (player_view(&pv))
            mp_cx = pv.x, mp_cy = pv.y;
    }
    return 1;                           /* the game sees nothing while the map is up */
}

/* renderer.c vid_flip_buffers, before the present: draw into the back buffer */
void map_frame(void)
{
    gptr g = rd32(G_GAME);
    if (!g || !r_renderer) {
        if (mp_built_for) {             /* left the level */
            fog_save();
            mp_built_for = 0;
        }
        mp_open = 0;
        return;
    }
    Player *pl = game_player();
    MapBlocks *mb = GP(MapBlocks, rd32(G_MAP_BLOCKS));
    if (!pl || !mb)
        return;
    if (mp_built_for != g || mp_built_grid != mb->grid) {
        if (!map_build())
            return;
        mp_built_for = g;
        mp_built_grid = mb->grid;
        memset(arrow_rgb, 0, sizeof arrow_rgb);
    }
    if (map_fog_on)
        fog_update();
    if (mp_fog_dirty && r_frames - mp_saved_frame >= MP_SAVE_FRAMES)
        fog_save();
    struct player_view pv;
    if (!player_view(&pv))
        return;
    fog_upload();
    float bw = (float)(int32_t)rd32(G_WINDOW_W), bh = (float)(int32_t)rd32(G_WINDOW_H);
    if (bw < FB_W || bh < FB_H)
        bw = FB_W, bh = FB_H;
    r_SDL_SetRenderDrawBlendMode(r_renderer, SDL_BLENDMODE_BLEND);
    if (mp_open)
        full_draw(&pv, bw, bh);
    else if (map_minimap_on && !dm_is_open())
        radar_draw(&pv, bw, bh);
    r_SDL_SetRenderDrawBlendMode(r_renderer, SDL_BLENDMODE_NONE);
}

/* renderer.c, before --frames exits (which skips atexit) */
void map_shutdown(void)
{
    fog_save();
}

/* ---- K menu rows (root page) --------------------------------------------------------- */

static void map_reveal(void)
{
    memset(mp_fog, 0, sizeof mp_fog);
    mp_fog_dirty = mp_fog_tex_dirty = 1;
    printf("map: frame %u, whole map of %s revealed\n", r_frames, mp_level);
}

static void map_fog_change(const struct dm_item *it, int dir)
{
    (void)it, (void)dir;
    map_fog_on ^= 1;
    mp_fog_tex_dirty = 1;
}

static void map_fog_fmt(char *end)
{
    strcpy(end, map_fog_on ? "on" : "off");
}

DM_VALUE_FNS(map_fog);
DM_PAGE(dmp_map, dmp_root, 85, "Map");
DM_ITEM(dmp_map, 10, DM_FLAG, "Minimap: ", &map_minimap_on);
DM_ITEM(dmp_map, 20, DM_FLAG, "Minimap turns with you: ", &map_rotate);
DM_ITEM(dmp_map, 30, DM_VALUE, "Fog of war: ", &dmv_map_fog);
DM_ITEM(dmp_map, 40, DM_ACTION, "Reveal the whole map", map_reveal);
DM_ITEM(dmp_map, 50, DM_ACTION, "Forget explored map", map_reset_fog);
