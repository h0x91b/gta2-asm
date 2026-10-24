/* core.c — the K menu framework: K opens it in gameplay, drawn with the game's own font
 * (DrawGTAText) and sprites (DrawSprite2D) over the HUD from the DrawUI call hook
 * (hk_DrawUI, host/debug_menu.asm). Design, keys and the recipe: docs/debug-menu.md.
 *
 *   K / ESC          open / close (ESC does not reach the game while the menu is open)
 *   UP / DOWN        select (wraps); PAGE UP / PAGE DOWN 10 rows; HOME / END
 *   LEFT / RIGHT     change the value; RETURN activates; BACKSPACE back to the parent page
 *
 * While the menu is open every key press goes to it, not to the game; keys held when it
 * opens are released, so the player stops. Key releases always reach the game.
 *
 * Text: DrawGTAText @0x4CC100, stdcall(wchar_t* str, SCR_f x, SCR_f y, short font,
 * SCR_f scale, PALETTE_BASE* pal, int remap, int invisibility, SCR_f ?), ret 0x24; the
 * default font id is at 0x672F24. Box: DrawFlatRect2D @0x474110, stdcall(float x1, y1,
 * x2, y2, u32 argb), ret 0x14. Calls and addresses from gta2-seuko-mod by izawartka
 * (https://github.com/izawartka/gta2-seuko-mod), src/game/functions.h, memory.h,
 * src/modules/ui/components/text.cpp @25b1985.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dm.h"

/* MainCamera, DefaultFontId: gta2-seuko-mod src/game/memory.h @25b1985 */
#define UI_CAMERA   0x5E3CC4            /* Camera* (main), uiScale */
#define FONT_ID     0x672F24
/* g_StyleData (StyleData*) and g_LocaleSettings: re/globals.csv; layouts re/gta2_types.h,
 * confirmed by Seq 27 (report seq49-car-sprite-remap.md) */
#define STYLE_DATA  0x670684
#define LOCALE      0x671550

#define DM_PANE_GAP 12                  /* the preview pane starts this far right of the list box */
#define DM_TEXT_SCALE 0x3000            /* 0.75 (SCR_f, 14 fraction bits) */
#define DM_LINES    48                  /* low line buffers per frame */
#define DM_WCHARS   64
#define DM_LOWHDR   256                 /* dm_low: palette kinds +0, GXT key +16, measured text +128, then the lines */
#define DM_MEASURE  128
#define DM_W_MIN    150                 /* the list box grows with its widest line */
#define DM_DEFER_MAX 8

extern struct dm_page dm_pages_start[] __asm__("section$start$__DATA$__dm_pages");
extern struct dm_page dm_pages_end[] __asm__("section$end$__DATA$__dm_pages");
extern struct dm_item dm_items_start[] __asm__("section$start$__DATA$__dm_items");
extern struct dm_item dm_items_end[] __asm__("section$end$__DATA$__dm_items");
extern struct dm_frame dm_frames_start[] __asm__("section$start$__DATA$__dm_frame");
extern struct dm_frame dm_frames_end[] __asm__("section$end$__DATA$__dm_frame");

/* NASM: w32_dinput.asm, w32_core.asm (called through dm_cb: NASM register contracts) */
extern char input_release_all[] NASM(input_release_all);
extern char low_alloc[] NASM(low_alloc);

struct dm_page *dm_page;
int32_t dm_pane_x;
const char *dm_toast;
int32_t dm_toast_left;
uint8_t dm_paused NASM(dm_paused);      /* the game is paused by us (hk_PauseOverlay reads it) */

static uint8_t dm_open, dm_ui_seen, dm_built;
int map_key(int dik, int down);         /* ../map.c */
int map_is_open(void);
static gptr dm_low;                     /* low memory: palette kinds, GXT key, line buffers */
static const void *dm_defer_q[DM_DEFER_MAX];
static int dm_defer_n;
static uint32_t dm_ui_frame, dm_line_no;
static int32_t dm_scale, dm_dyn_rows, dm_box_x2;
static int32_t dm_hl_remap = 2;         /* font remap of the selected line: green (measured) */
static char dm_buf[128];

/* Back / Close, appended to every page by dm_build (not in the linker set) */
static struct dm_item dmi_back = { 0, 0x7FFFFFFF, DM_BACK, "Back", 0 };
static struct dm_item dmi_close = { 0, 0x7FFFFFFF, DM_CLOSE, "Close", 0 };

/* the game drew its HUD (DrawUI) within the last few frames */
static int dm_in_gameplay(void)
{
    return dm_ui_seen && r_frames - dm_ui_frame < 3;
}

int dm_dyn(void)
{
    return dm_page->rows ? dm_page->rows() : 0;
}

static uint32_t dm_total(void)
{
    return (uint32_t)dm_dyn() + (uint32_t)dm_page->nitems;
}

/* to the parent page (its selection is still on the link we came by); the root closes */
static void dm_back(void)
{
    if (dm_page->parent)
        dm_page = dm_page->parent;
    else
        dm_open = 0;
}

void dm_defer(void (*fn)(void))
{
    if (dm_defer_n < DM_DEFER_MAX)
        dm_defer_q[dm_defer_n++] = (const void *)fn;
}

void dm_toast_set(const char *s)
{
    dm_toast = s;
    dm_toast_left = DM_TOAST_FRAMES;
}

/* dir = -1 left / +1 right / 0 RETURN on an item */
static void dm_change(const struct dm_item *it, int dir)
{
    switch (it->kind) {
    case DM_CLOSE:
        dm_open = 0;
        break;
    case DM_ACTION:
        if (!dir)
            dm_defer((void (*)(void))it->data);
        break;
    case DM_LINK:
        if (!dir)
            dm_page = (struct dm_page *)it->data;
        break;
    case DM_BACK:
        dm_back();
        break;
    case DM_VALUE:
        dm_cb((const void *)((const struct dm_value *)it->data)->change,
              (uint64_t)(uintptr_t)it, (uint64_t)(int64_t)dir);
        break;
    default: {                          /* DM_FLAG: any key toggles */
        uint8_t *flag = (uint8_t *)it->data;
        *flag = (*flag ^ 1) & 1;
    }
    }
}

/* on the selected row */
static void dm_activate(int dir)
{
    uint32_t dyn = (uint32_t)dm_dyn();
    struct dm_page *p = dm_page;
    uint32_t sel = (uint32_t)p->sel;
    if (sel < dyn) {
        if (p->rowchange)
            p->rowchange((int)sel, dir);
    } else if (sel - dyn < (uint32_t)p->nitems) {
        dm_change(p->items[sel - dyn], dir);
    }
}

int dm_is_open(void)
{
    return dm_open;
}

/* called first by input_key (w32_dinput.asm, through dbgmenu_key): 1 = consumed */
int dm_key(int dik, int down)
{
    if (!dm_in_gameplay()) {
        dm_open = 0;                    /* left gameplay with the menu open */
        return 0;
    }
    if (!dm_open && map_key(dik, down)) /* the full map (map.c) takes M and, while up, all */
        return 1;
    if (!down)
        return 0;                       /* releases always reach the game */
    if (!dm_open) {
        if (dik != DIK_K || !dm_built)
            return 0;
        dm_open = 1;
        dm_cb(input_release_all, 0, 0); /* the player stops; ups pass through us */
        return 1;
    }
    if (dik == DIK_K || dik == DIK_ESCAPE) {
        dm_open = 0;
        return 1;
    }
    struct dm_page *p = dm_page;
    if (p->key && p->key(dik))
        return 1;
    uint32_t n = dm_total();
    int32_t sel = p->sel;
    switch (dik) {
    case DIK_UP:
        sel = sel - 1 < 0 ? (int32_t)n - 1 : sel - 1;
        break;
    case DIK_DOWN:
        sel = (uint32_t)(sel + 1) < n ? sel + 1 : 0;
        break;
    case DIK_PRIOR:
        sel = sel - 10 < 0 ? 0 : sel - 10;
        break;
    case DIK_NEXT:
        sel = (uint32_t)(sel + 10) < n ? sel + 10 : (int32_t)n - 1;
        break;
    case DIK_HOME:
        sel = 0;
        break;
    case DIK_END:
        sel = (int32_t)n - 1;
        break;
    case DIK_BACK:
        dm_back();
        return 1;
    case DIK_LEFT:
        dm_activate(-1);
        return 1;
    case DIK_RIGHT:
        dm_activate(1);
        return 1;
    case DIK_RETURN:
    case DIK_NUMPADENTER:
        dm_activate(0);
        return 1;
    default:
        return 1;
    }
    p->sel = sel;
    return 1;
}

/* every page gets its items (sorted by order, link order on ties) plus Back or Close; the
 * frame hooks get sorted by order in place. Once, on the first gameplay frame. */
static void dm_build(void)
{
    for (struct dm_page *p = dm_pages_start; p < dm_pages_end; p++) {
        int n = 0;
        for (struct dm_item *it = dm_items_start; it < dm_items_end; it++)
            n += it->page == p;
        struct dm_item **items = malloc((size_t)(n + 1) * sizeof *items);
        n = 0;
        for (struct dm_item *it = dm_items_start; it < dm_items_end; it++) {
            if (it->page != p)
                continue;
            int i = n++;                /* insertion sort, stable */
            for (; i > 0 && items[i - 1]->order > it->order; i--)
                items[i] = items[i - 1];
            items[i] = it;
        }
        items[n++] = p->parent ? &dmi_back : &dmi_close;
        p->items = items;
        p->nitems = n;
    }
    for (struct dm_frame *f = dm_frames_start + 1; f < dm_frames_end; f++) {
        struct dm_frame cur = *f, *g = f;
        for (; g > dm_frames_start && g[-1].order > cur.order; g--)
            g[0] = g[-1];
        *g = cur;
    }
    dm_page = &dmp_root;
    dm_built = 1;
}

/* ---- drawing ---- */

static uint32_t dm_font(void) { return rd16(FONT_ID); }

void dm_rect(int x1, int y1, int x2, int y2, uint32_t argb)
{
    float k = (float)dm_scale * (1.0f / 16384);
    float f[4] = { (float)x1 * k, (float)y1 * k, (float)x2 * k, (float)y2 * k };
    uint32_t a[5];
    memcpy(a, f, sizeof f);
    a[4] = argb;
    call32(0x474110, a, 5, 0, 0, 0);
}

/* the string as UTF-16 at a low buffer (at most DM_WCHARS - 1 characters) */
static void dm_widen(gptr dst, const char *s)
{
    int i = 0;
    for (; i < DM_WCHARS - 1 && s[i]; i++)
        wr16(dst + 2 * i, (uint8_t)s[i]);
    wr16(dst + 2 * i, 0);
}

/* Each call gets its own low line buffer (UTF-16), in case the game keeps the pointer. */
void dm_text_at(const char *s, int x, int y, int highlighted)
{
    if (dm_line_no >= DM_LINES)
        return;
    gptr str = dm_low + DM_LOWHDR + dm_line_no++ * DM_WCHARS * 2;
    dm_widen(str, s);
    wr32(dm_low, 2);                    /* PALETTE_BASE_SPRITE */
    wr32(dm_low + 4, 8);                /* PALETTE_BASE_FONT_REMAP */
    uint32_t a[9] = {
        str, (uint32_t)(x * dm_scale), (uint32_t)(y * dm_scale), dm_font(),
        (uint32_t)(dm_scale * DM_TEXT_SCALE >> 14),
        highlighted ? dm_low + 4 : dm_low, highlighted ? (uint32_t)dm_hl_remap : 0,
        0,                              /* SPRITE_INVISIBILITY_VISIBLE */
        1,
    };
    call32(0x4CC100, a, 9, 0, 0, 0);
}

static void dm_text(const char *s, int y, int highlighted)
{
    dm_text_at(s, DM_X, y, highlighted);
}

/* GetGTATextWidth @0x4CB0C0, stdcall(wchar_t* text, short font) -> glyph pixels at scale
 * 1.0 (re/functions.csv + its Ghidra comment; own decompile) */
int dm_text_w(const char *s)
{
    if (!dm_low)
        return 0;
    dm_widen(dm_low + DM_MEASURE, s);
    uint32_t a[2] = { dm_low + DM_MEASURE, dm_font() };
    uint32_t w = (uint32_t)call32(0x4CB0C0, a, 2, 0, 0, 0);
    return (int)(w * DM_TEXT_SCALE >> 14);
}

void dm_pane(int y1, int y2, int width)
{
    dm_rect(dm_pane_x - DM_PAD, y1 - DM_PAD, dm_pane_x + width, y2, 0x80000000);
}

/* a style sprite's index entry (StyleData +0x14 spriteBases[type - 2] + id, +0x20 entries,
 * 8 bytes: w +4, h +5; StyleData_GetSpriteIndex @0x4BF2A0), or 0 */
static gptr dm_sprite_entry(int type, int id)
{
    StyleData *st = GP(StyleData, rd32(STYLE_DATA));
    uint32_t t = (uint32_t)type - 2;
    if (!st || t > 5 || !st->spriteBases)
        return 0;
    uint32_t i = rd16(st->spriteBases + 2 * t) + (uint32_t)id;
    if (i >= (uint16_t)st->spriteCount || !st->spriteIndex)
        return 0;
    return st->spriteIndex + i * 8;
}

uint32_t dm_sprite_wh(int type, int id)
{
    gptr e = dm_sprite_entry(type, id);
    return e ? rd16(e + 4) : 0;
}

/* DrawSprite2D @0x4CBA50, stdcall(SPRITE_TYPE type, id, SCR_f x, y, Ang16 rot, SCR_f
 * scale, int* paletteKind, int remap, a9, a10, byte a11), ret 0x2C: x, y = centre in
 * screen pixels, quad = w, h * scale / 2. The HUD's wrapper Hud_DrawSprite2DScaled
 * @0x4C71B0 passes scale = uiScale (1:1 in 640x480 units) and a11 = 0, as we do. Own
 * disassembly, confirmed by Seq 27 (seq49-car-sprite-remap.md). */
int dm_sprite(const struct dm_sprite *ds)
{
    gptr e = dm_sprite_entry(ds->type, ds->id);
    if (!e)
        return 0;
    uint32_t w = rd8(e + 4), h = rd8(e + 5), k;
    if (!ds->box) {
        k = ((uint32_t)ds->scale << 14) / 100;
    } else {
        uint32_t d2 = w * w + h * h;
        if (!d2)
            return 0;
        k = (uint32_t)(int32_t)((double)(ds->box << 14) / sqrt((double)(int32_t)d2));
    }
    /* scale = uiScale * k in 32 bits, as the NASM had it (it wraps for scale = 450% at
     * uiScale 2: the ped preview; kept for parity, docs/debug-menu.md "Known limits") */
    int32_t scale = (int32_t)((uint32_t)dm_scale * k) >> 14;
    wr32(dm_low + 8, (uint32_t)ds->pal);
    uint32_t a[11] = {
        (uint32_t)ds->type, (uint32_t)ds->id, (uint32_t)(ds->x * dm_scale),
        (uint32_t)(ds->y * dm_scale), (uint32_t)ds->rot, (uint32_t)scale,
        dm_low + 8, (uint32_t)ds->remap, 0, 0, 0,
    };
    call32(0x4CBA50, a, 11, 0, 0, 0);
    return 1;
}

/* g_StyleData +0x5c AllCarsInfo.cars[256]; StyleData_GetCarInfo @0x4BF1F0, re/functions.csv */
CarInfo *dm_car_info(int model)
{
    StyleData *st = GP(StyleData, rd32(STYLE_DATA));
    if ((uint32_t)model > 255 || !st || !st->allCarsInfo)
        return 0;
    return GP(CarInfo, rd32(st->allCarsInfo + 4 * (uint32_t)model));
}

/* Gxt_FindTextW @0x4C2120, thiscall(LocaleSettings* = [0x671550], char* key) -> wchar_t*
 * (re/functions.csv; used the same way by GetCarModelName @0x41F700 with "car%d").
 * Non-ASCII characters become '?'. */
int dm_gxt(const char *key, char *out, int size)
{
    out[0] = 0;
    gptr locale = rd32(LOCALE);
    if (!locale || !dm_low)
        return 0;
    int i = 0;
    for (; i < 15 && key[i]; i++)
        wr8(dm_low + 16 + i, (uint8_t)key[i]);
    wr8(dm_low + 16 + i, 0);
    uint32_t a[1] = { dm_low + 16 };
    gptr w = (gptr)call32(0x4C2120, a, 1, 0, locale, 0);
    if (!w)
        return 0;
    for (i = 0; (uint32_t)i < (uint32_t)size - 1; i++) {
        uint16_t c = rd16(w + 2 * i);
        if (!c)
            break;
        out[i] = c < 0x80 ? (char)c : '?';
    }
    out[i] = 0;
    return i;
}

/* a row of the current page: its text into dm_buf */
static void dm_row_label(int row)
{
    struct dm_page *p = dm_page;
    if (row < dm_dyn_rows) {
        dm_buf[0] = 0;
        if (p->rowfmt)
            p->rowfmt(row, dm_buf);
        return;
    }
    const struct dm_item *it = p->items[row - dm_dyn_rows];
    strcpy(dm_buf, it->label);
    if (it->kind == DM_VALUE)
        dm_cb((const void *)((const struct dm_value *)it->data)->fmt,
              (uint64_t)(uintptr_t)(dm_buf + strlen(dm_buf)), 0);
    else if (it->kind == DM_FLAG)
        strcat(dm_buf, *(const uint8_t *)it->data ? "on" : "off");
}

/* the menu (when open) and the toast line, in 640x480 units times uiScale. The current page
 * shows DM_VISIBLE rows around the selection with a scroll bar when it has more, then its
 * draw callback (the preview pane). */
static void dm_draw(void)
{
    Camera *cam = GP(Camera, rd32(UI_CAMERA));
    if (!cam)
        return;
    dm_scale = cam->uiScale;
    if (!dm_low)
        dm_low = (gptr)dm_cb(low_alloc, DM_LOWHDR + DM_LINES * DM_WCHARS * 2, 16);
    dm_line_no = 0;
    if (dm_open) {
        struct dm_page *p = dm_page;
        dm_dyn_rows = dm_dyn();
        uint32_t rows = (uint32_t)dm_dyn_rows + (uint32_t)p->nitems;
        uint32_t sel = (uint32_t)p->sel;  /* keep the selection and the window in range */
        if (sel >= rows)
            p->sel = (int32_t)(sel = rows - 1);
        uint32_t top = (uint32_t)p->top;
        if (sel < top)
            top = sel;
        if (sel > top + DM_VISIBLE - 1)
            top = sel - DM_VISIBLE + 1;
        if (top + DM_VISIBLE > rows)
            top = (int32_t)(rows - DM_VISIBLE) < 0 ? 0 : rows - DM_VISIBLE;
        p->top = (int32_t)top;
        uint32_t vis = rows > DM_VISIBLE ? DM_VISIBLE : rows;

        uint32_t w = (uint32_t)dm_text_w(p->title);  /* the box fits the title and the rows */
        for (uint32_t r = top; r < top + vis; r++) {
            dm_row_label((int)r);
            uint32_t rw = (uint32_t)dm_text_w(dm_buf);
            if (rw > w)
                w = rw;
        }
        int32_t bw = (int32_t)w + DM_PAD;
        if (bw < DM_W_MIN)
            bw = DM_W_MIN;
        if (rows > DM_VISIBLE)
            bw += 6;                    /* room for the scroll bar */
        dm_box_x2 = bw + DM_X;
        dm_pane_x = dm_box_x2 + DM_PANE_GAP + DM_PAD;

        int bottom = (int)(vis + 1) * DM_LINE + DM_Y + DM_LINE / 2 + DM_PAD;
        dm_rect(DM_X - DM_PAD, DM_Y - DM_PAD, dm_box_x2, bottom, 0x80000000);
        dm_text(p->title, DM_Y, 0);
        int y = DM_Y + DM_LINE + DM_LINE / 2;
        for (uint32_t r = top; r < top + vis; r++, y += DM_LINE) {
            dm_row_label((int)r);
            dm_text(dm_buf, y, r == (uint32_t)p->sel);
        }
        if (rows > DM_VISIBLE) {        /* scroll bar: track and thumb at the box's right edge */
            dm_rect(dm_box_x2 - 4, DM_Y + DM_LINE, dm_box_x2 - 1, bottom - DM_PAD, 0x60FFFFFF);
            uint32_t h = (uint32_t)(bottom - DM_PAD - DM_Y - DM_LINE);
            int t1 = (int)(h * top / rows) + DM_Y + DM_LINE;
            int t2 = t1 + (int)(h * DM_VISIBLE / rows);
            dm_rect(dm_box_x2 - 4, t1, dm_box_x2 - 1, t2, 0xE0FFFFFF);
        }
        if (p->draw)
            p->draw(p);
    }
    if (dm_toast_left) {
        dm_toast_left--;
        dm_text(dm_toast, 480 - 3 * DM_LINE, 1);
    }
}

/* DrawUI(this) @0x4CA440, fastcall, no stack arguments: the HUD, called at 0x45A61F once
 * per gameplay frame; hk_DrawUI (host/debug_menu.asm) hands us its ecx. The DM_FRAME hooks
 * and the deferred menu actions run first (so their overlays sit under the HUD), then the
 * original, then the menu. Hook site from gta2-seuko-mod by izawartka
 * (https://github.com/izawartka/gta2-seuko-mod), src/events/draw-ui.cpp @25b1985. */
void dm_on_drawui(gptr ecx)
{
    dm_ui_frame = r_frames;
    dm_ui_seen = 1;
    if (!dm_built)
        dm_build();
    for (struct dm_frame *f = dm_frames_start; f < dm_frames_end; f++)
        dm_cb((const void *)f->fn, 0, 0);
    for (int i = 0; i < dm_defer_n; i++)  /* a deferred fn may queue another */
        dm_cb(dm_defer_q[i], 0, 0);
    dm_defer_n = 0;
    call32(0x4CA440, 0, 0, 0, ecx, 0);
    dm_draw();
}

/* dm_pause_sync (DM_FRAME, first): the game pauses while the menu is open. Open: a running
 * game (Game +0 gameStatus 1) that allows pausing (+0x23 = 1, ToggleGamePause @0x45BAA0's
 * own test) goes to 2 (GAME_PAUSED): Game_StepByStatus then only runs Game_TickPaused
 * (cameras), while DrawUI, and so this hook and the menu, still run. Closed: UnpauseGame
 * @0x45BA60 thiscall(Game*) puts 1 back, flushes DirectInput and clears the player's input.
 * A pause the player made on their own is left alone. hk_PauseOverlay hides the game's
 * "pause" screen meanwhile. Names and fields: re/functions.csv, re/gta2_types.h; own
 * decompile. */
static void dm_pause_sync(void)
{
    Game *g = game();
    if (!g)
        return;
    if (dm_open || map_is_open()) {     /* the full map (map.c) pauses the same way */
        if (dm_paused || g->gameStatus != 1 || g->playerCount != 1)  /* +0x23 */
            return;
        g->gameStatus = 2;
        dm_paused = 1;
        printf("menu: frame %d, game paused\n", r_frames);
    } else {
        if (!dm_paused)
            return;
        dm_paused = 0;
        if (g->gameStatus != 2)
            return;
        call32(0x45BA60, 0, 0, 0, (gptr)(uintptr_t)g, 0);
        printf("menu: frame %d, game resumed (gameStatus %d)\n", r_frames, game()->gameStatus);
    }
}
DM_FRAME(-100, dm_pause_sync);
