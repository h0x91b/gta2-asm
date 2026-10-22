/* dm.h — the K menu (in-game debug menu) for host C pages: records, macros, components.
 * Design, keys and the "how to add a page" recipe: docs/debug-menu.md.
 *
 * Nothing lists the menu's content. Every page file declares its pages, rows and per-frame
 * hooks with DM_PAGE / DM_ITEM / DM_FRAME, which put fixed-size records into the Mach-O
 * sections __DATA,__dm_pages / __dm_items / __dm_frame; the linker concatenates them across
 * the whole build (C objects and the NASM feature modules alike, same record layout:
 * host/debug_menu.asm keeps DM_ITEM / DM_FRAME / DMVALUE for NASM). core.c builds a sorted
 * row list per page once, on the first gameplay frame. A new page is a new file in
 * host/c/menu/ and nothing else.
 *
 * Layout is in 640x480 units, scaled by the main camera's uiScale like the game's HUD.
 */
#ifndef DM_H
#define DM_H

#include "../game.h"

/* item kinds (the NASM DM_* values) */
enum { DM_ACTION = 0, DM_FLAG = 2, DM_CLOSE = 3, DM_LINK = 4, DM_BACK = 5, DM_VALUE = 6 };

/* DirectInput key codes the pages use */
enum {
    DIK_ESCAPE = 0x01, DIK_BACK = 0x0E, DIK_RETURN = 0x1C, DIK_K = 0x25, DIK_B = 0x30,
    DIK_NUMPADENTER = 0x9C, DIK_HOME = 0xC7, DIK_UP = 0xC8, DIK_PRIOR = 0xC9,
    DIK_LEFT = 0xCB, DIK_RIGHT = 0xCD, DIK_END = 0xCF, DIK_DOWN = 0xD0, DIK_NEXT = 0xD1,
};

/* 640x480 layout */
#define DM_X        16
#define DM_Y        104                 /* below the HUD bars */
#define DM_LINE     17
#define DM_PAD      6
#define DM_VISIBLE  16                  /* rows shown at once, more scroll */
#define DM_TOAST_FRAMES 120

struct dm_item;

/* A page: static data plus its runtime row list. Callbacks are optional (0):
 *   draw(page)            after the list: the preview pane or any extra content
 *   key(dik) -> 1         consumed, before the generic keys
 *   rows() -> n           dynamic rows shown before the registered items
 *   rowfmt(row, buf)      a dynamic row's label into a 128-byte buffer
 *   rowchange(row, dir)   dir = -1 LEFT / +1 RIGHT / 0 RETURN */
struct dm_page {
    const char *title;
    struct dm_page *parent;             /* 0 = the root */
    void (*draw)(struct dm_page *page);
    int (*key)(int dik);
    int (*rows)(void);
    void (*rowfmt)(int row, char *buf);
    void (*rowchange)(int row, int dir);
    struct dm_item **items;             /* runtime: sorted, Back / Close last */
    int32_t nitems, sel, top, order;
};

/* One row. data: DM_ACTION fn(), DM_FLAG a byte toggled 0 / 1, DM_VALUE a dm_value,
 * DM_LINK the page to open. */
struct dm_item {
    struct dm_page *page;
    int32_t order, kind;
    const char *label;
    const void *data;
};

/* A DM_VALUE row: change(item, dir) and fmt(end of the label text) */
struct dm_value {
    void (*change)(const struct dm_item *item, int dir);
    void (*fmt)(char *end);
};

struct dm_frame {
    int32_t order, pad;
    void (*fn)(void);
};

_Static_assert(sizeof(struct dm_page) == 80, "DM_PAGE record");
_Static_assert(sizeof(struct dm_item) == 32, "DM_ITEM record, as host/debug_menu.asm");
_Static_assert(sizeof(struct dm_frame) == 16, "DM_FRAME record, as host/debug_menu.asm");

#define DM_SECT(s)  __attribute__((used, section("__DATA," s)))
#define DM_CAT_(a, b) a##b
#define DM_CAT(a, b) DM_CAT_(a, b)

/* DM_PAGE(name, parent, order, "Title"[, .draw = f, .key = f, .rows = f, .rowfmt = f,
 * .rowchange = f]): a page, and its link row "Title..." on the parent at that order. The
 * page is a global under its own name for NASM too (dmp_x, no underscore). */
#define DM_PAGE(name, parent_, order_, title_, ...)                                        \
    struct dm_page name __asm__(#name) DM_SECT("__dm_pages") =                             \
        { .title = title_, .parent = &parent_, .order = order_, __VA_ARGS__ };             \
    static struct dm_item DM_CAT(name, _link) DM_SECT("__dm_items") =                      \
        { &parent_, order_, DM_LINK, title_ "...", &name }

/* the page of another file, as a parent or for DM_ITEM */
#define DM_PAGE_EXTERN(name) extern struct dm_page name __asm__(#name)

/* DM_ITEM(page, order, kind, "label", data): one row of a page */
#define DM_ITEM(page, order_, kind_, label_, data_)                                        \
    static struct dm_item DM_CAT(dm_item_, __LINE__) DM_SECT("__dm_items") =               \
        { &page, order_, kind_, label_, (const void *)(data_) }

/* DM_FRAME(order, fn): fn() once per gameplay frame on the game's side, before the HUD,
 * lowest order first, whether the menu is open or not */
#define DM_FRAME(order_, fn_)                                                              \
    static struct dm_frame DM_CAT(dm_frame_, __LINE__) DM_SECT("__dm_frame") =             \
        { order_, 0, fn_ }

/* DM_VALUE_FNS(x): the dm_value dmv_x from x_change / x_fmt */
#define DM_VALUE_FNS(x) static const struct dm_value dmv_##x = { x##_change, x##_fmt }

/* the well-known pages */
DM_PAGE_EXTERN(dmp_root);
DM_PAGE_EXTERN(dmp_player);
DM_PAGE_EXTERN(dmp_vehicle);
DM_PAGE_EXTERN(dmp_spawn);
DM_PAGE_EXTERN(dmp_flags);

/* ---- runtime (core.c) ---- */

extern struct dm_page *dm_page;         /* the current page */
extern int32_t dm_pane_x;               /* where a page's preview pane content starts */
extern const char *dm_toast NASM(dm_toast);
extern int32_t dm_toast_left NASM(dm_toast_left);

int dm_dyn(void);                       /* the current page's dynamic rows */
void dm_defer(void (*fn)(void));        /* fn() on the game's side of this frame */
void dm_toast_set(const char *s);       /* the message line at the bottom */

/* ---- drawing components (core.c), 640x480 units ---- */

void dm_text_at(const char *s, int x, int y, int highlighted);
int dm_text_w(const char *s);           /* width at the menu's text size */
void dm_rect(int x1, int y1, int x2, int y2, uint32_t argb);
void dm_pane(int y1, int y2, int width);/* the pane box right of the list box */

/* dm_sprite: any style sprite with any remap, scaled and rotated (DrawSprite2D) */
struct dm_sprite {
    int32_t type;                       /* SPRITE_TYPE: 2 car, 3 ped, 4 code obj, 5 map obj, 6 user, 7 font */
    int32_t id;                         /* relative to the type's sprite base */
    int32_t pal;                        /* palette kind: 2 none, 3 car, 4 ped, 5 code obj, 6 map obj, 7 user, 8 font */
    int32_t remap;                      /* index within that palette base */
    int32_t x, y;                       /* centre */
    int32_t box;                        /* fit the diagonal into this many units (0: use scale) */
    int32_t scale;                      /* percent of the HUD's 1:1 size, when box = 0 */
    int32_t rot;                        /* 1440 units per turn (Sprite.rotation) */
};
int dm_sprite(const struct dm_sprite *ds);   /* 0 when there is no such sprite */
uint32_t dm_sprite_wh(int type, int id);     /* w | h << 8, 0 if none */
CarInfo *dm_car_info(int model);             /* this style's CarInfo for the model, or 0 */
int dm_gxt(const char *key, char *out, int size);   /* game text as ASCII, its length */

/* ---- shared game helpers (helpers.c) ---- */

Ped *dm_player_ped(void);
Player *dm_player(void);
Car *dm_car(int *in_it);                /* the car the player is in, else the last one */
extern const char s_dm_noplayer2[] NASM(s_dm_noplayer2);
extern const char *const dm_car_names[]; /* CAR_MODEL4 names by id */
#define DM_NCARNAMES 87
extern const uint8_t dm_spawnable[] NASM(dm_spawnable);
#define DM_NSPAWNABLE 79
extern int32_t dm_model NASM(dm_model); /* index into dm_spawnable: the last model spawned */
extern int km_car_remap_last;           /* the palette remap km_spawn_car used: -1 random, -2 none */

/* NASM glue (host/debug_menu.asm, w32_*.asm) */
uint64_t dm_cb(const void *fn, uint64_t a, uint64_t b) NASM(dm_cb);
extern int32_t cam_zoom_pct NASM(cam_zoom_pct);

#endif
