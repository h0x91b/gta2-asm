/* overlay.c — the world-overlay toolkit (overlay.h), shared by debug_paths.c and
 * debug_roads.c.
 *
 * World -> screen is the game's own WorldPointToScreen @0x40CFC0, fastcall(Camera* ecx,
 * edx; SCR_f x, y, z, SCR_f* outX, SCR_f* outY), ret 0x14, on the player's camera
 * (Game 0x5EB4FC ->currentPlayer ->viewCamera), the way the debug view ShowJunctionIds
 * 0x40D120 labels junctions (own disassembly). It reads the camera as the frame drew it,
 * so the camera.zoom factor is already in. Its result is in 640x480 units; times the main
 * camera's uiScale gives back-buffer pixels, the space DrawFlatRect2D @0x474110 (stdcall,
 * float x1, y1, x2, y2, argb) draws in. WorldPointToScreen from gta2-seuko-mod by
 * izawartka (https://github.com/izawartka/gta2-seuko-mod), src/game/functions.h @25b1985;
 * ShowJunctionIds (do_show_junc_id) was named in the user's 2021 Ghidra DB,
 * gta2-resurected.exe.gzf in https://github.com/h0x91b/gta2-resurection @87e1d98.
 *
 * Labels are our own 3x5 digits drawn with DrawFlatRect2D on a dark plate rather than
 * DrawGTAText: the game's font only takes palette remaps, not an arbitrary colour, and the
 * colour is what ties a label to its object.
 */
#include "overlay.h"

#define G_GAME      0x5EB4FC            /* Game* */
#define G_UI_CAMERA 0x5E3CC4            /* Camera* (main), uiScale at +0xa8 */
#define G_WINDOW_W  0x673578            /* back-buffer size */
#define G_WINDOW_H  0x6732E8

#define MAXDOTS 256                     /* per line */
#define PLATE   0xC0000000u             /* label background */
#define HUE_LOW 90                      /* lowest colour channel of a hue */

C32_OFFSET(Game, currentPlayer, 0x38);
C32_OFFSET(Player, viewCamera, 0x14C);
C32_OFFSET(Camera, uiScale, 0xA8);

GAME_FN(void, G2_FASTCALL, WorldPointToScreen, 0x40CFC0,
        (Camera *cam, int edx, SCR_f x, SCR_f y, SCR_f z, SCR_f *out_x, SCR_f *out_y));
GAME_FN(void, G2_STDCALL, DrawFlatRect2D, 0x474110,
        (float x1, float y1, float x2, float y2, uint32_t argb));

Camera *ov_cam;
int32_t ov_scale;

Player *ov_player(void)
{
    Game *game = *(Game **)G_GAME;
    return game ? game->currentPlayer : 0;
}

int ov_setup(void)
{
    Player *player = ov_player();
    Camera *ui = *(Camera **)G_UI_CAMERA;
    if (!player || !ui)
        return 0;
    ov_cam = &player->viewCamera;
    ov_scale = ui->uiScale;
    return 1;
}

struct ov_pt ov_project(int32_t x, int32_t y, int32_t z)
{
    SCR_f sx, sy;
    WorldPointToScreen(ov_cam, 0, x, y, z, &sx, &sy);
    /* SCR_f * SCR_f -> int */
    return (struct ov_pt){ (int32_t)(((int64_t)sx * ov_scale) >> 28),
                           (int32_t)(((int64_t)sy * ov_scale) >> 28) };
}

/* skipped when it is off the back buffer */
void ov_box(int32_t x1, int32_t y1, int32_t x2, int32_t y2, uint32_t argb)
{
    if (x2 < 0 || y2 < 0 || x1 >= *(int32_t *)G_WINDOW_W || y1 >= *(int32_t *)G_WINDOW_H)
        return;
    DrawFlatRect2D((float)x1, (float)y1, (float)x2, (float)y2, argb);
}

void ov_rect(int32_t x, int32_t y, int32_t half, uint32_t argb)
{
    ov_box(x - half, y - half, x + half, y + half, argb);
}

void ov_mark(struct ov_pt p, int32_t half_units, uint32_t argb)
{
    ov_rect(p.x, p.y, (int32_t)((uint32_t)(half_units * ov_scale) >> 14), argb);
}

static uint32_t at_least_1(uint32_t v)
{
    return v ? v : 1;
}

/* dots every 4 units between the two points */
void ov_line(struct ov_pt a, struct ov_pt b, uint32_t argb)
{
    int32_t dx = b.x - a.x, dy = b.y - a.y;
    int32_t ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
    uint32_t n = (uint32_t)(ay < ax ? ax : ay) / at_least_1((uint32_t)ov_scale >> 12);
    if (n < 2)
        return;
    if (n > MAXDOTS)
        n = MAXDOTS;
    int32_t half = (int32_t)at_least_1((uint32_t)ov_scale >> 15);   /* 1 px at 2x */
    for (int32_t i = 1; i < (int32_t)n; i++)
        ov_rect(dx * i / (int32_t)n + a.x, dy * i / (int32_t)n + a.y, half, argb);
}

/* hue (id * 2^16/phi) mod 2^16: neighbouring ids get far-apart hues, and an object keeps
 * its colour from frame to frame; the lowest channel is HUE_LOW, so even blue reads on the
 * dark label plate */
uint32_t ov_hue(uint32_t id)
{
    /* which of {0xFF, low, rising, falling} each of R, G, B is, per hue sector */
    static const uint8_t sel[6][3] = {
        { 0, 2, 1 }, { 3, 0, 1 }, { 1, 0, 2 }, { 1, 3, 0 }, { 2, 1, 0 }, { 0, 1, 3 },
    };
    uint32_t h = ((id * 40503u) & 0xFFFF) * 6;
    uint32_t sector = h >> 16, frac = ((h & 0xFFFF) * (255 - HUE_LOW)) >> 16;
    uint32_t v[4] = { 0xFF, HUE_LOW, frac + HUE_LOW, 0xFF - frac };
    return 0xFF000000u | v[sel[sector][0]] << 16 | v[sel[sector][1]] << 8 | v[sel[sector][2]];
}

/* 3x5 digits, a byte per row, bit 2 = the left column */
static const uint8_t font[10][5] = {
    { 7, 5, 5, 5, 7 }, { 2, 6, 2, 2, 7 }, { 7, 1, 7, 4, 7 }, { 7, 1, 7, 1, 7 }, { 5, 5, 7, 1, 1 },
    { 7, 4, 7, 1, 7 }, { 7, 4, 7, 5, 7 }, { 7, 1, 1, 1, 1 }, { 7, 5, 7, 5, 7 }, { 7, 5, 7, 1, 7 },
};

/* the number in digits of 2 x 2 units on a PLATE plate, 3 units up and right of p */
void ov_label(struct ov_pt p, uint32_t n, uint32_t argb)
{
    int32_t c = (int32_t)at_least_1((uint32_t)ov_scale >> 13);     /* cell: 2 units */
    uint32_t digit[3] = { n / 100, n % 100 / 10, n % 10 };
    int first = digit[0] ? 0 : digit[1] ? 1 : 2;
    int32_t off = (int32_t)((uint32_t)(ov_scale * 3) >> 14);       /* 3 units */
    int32_t x0 = p.x + off, y0 = p.y - off - 5 * c;
    int32_t w = ((3 - first) * 4 - 1) * c;                         /* plate: a cell around */
    ov_box(x0 - c, y0 - c, x0 + w + c, y0 + 6 * c, PLATE);
    for (int d = first; d < 3; d++, x0 += 4 * c) {
        const uint8_t *rows = font[digit[d]];
        for (int r = 0; r < 5; r++) {
            int col = 0;
            while (col < 3) {
                if (!(rows[r] >> (2 - col) & 1)) {
                    col++;
                    continue;
                }
                int start = col;            /* a run of set bits: one box */
                while (++col < 3 && rows[r] >> (2 - col) & 1)
                    ;
                ov_box(x0 + start * c, y0 + r * c, x0 + col * c, y0 + r * c + c, argb);
            }
        }
    }
}
