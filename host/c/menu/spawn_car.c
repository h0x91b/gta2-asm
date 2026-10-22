/* spawn_car.c — Spawn > Car: every car model of the current level's style that SpawnCar
 * accepts, named from the GXT, with a remap picker and a live, rotating preview of the car
 * in that remap. Built through the recipe in docs/debug-menu.md: one DM_PAGE with dynamic
 * rows (sc_rows / sc_rowfmt / sc_rowchange) and a draw callback (sc_draw) that uses the
 * shared dm_sprite component; the spawn itself is km_spawn_car (helpers.c, spawn.h).
 *
 *   UP / DOWN       model           LEFT / RIGHT   remap: random (the game's pick on spawn),
 *   RETURN          spawn it 1.5 blocks in front     none (the sprite's own colours), or
 *                   of the player with that remap     each of the model's own remaps
 *
 * Facts (re/ + Seq 27 report seq49-car-sprite-remap.md): CarInfo (dm_car_info) +1
 * spriteIndex = id relative to the car sprite base, +4 num_remaps, +0xe remap[] = indices
 * into the car-remap palette base (palette kind 3).
 */
#include <stdio.h>
#include <string.h>
#include "dm.h"
#include "../spawn.h"

#define SC_PANE_H  268
#define SC_BOX     150                  /* preview: the car's diagonal fits this many units */
#define SC_SPIN    3                    /* preview rotation per frame (1440 per turn) */
#define SPAWN_DIST 0x6000               /* 1.5 blocks */
#define SC_NLINES  6
#define SC_LINE    64

static int sc_remap;                    /* -1 random, 0 none, i = CarInfo.remap[i - 1] */
static int sc_spawn_choice;
static int sc_n;
static uint8_t sc_idx[256];             /* the rows, as dm_spawnable indices */

/* a row's CAR_MODEL4 id */
static int sc_model(int row)
{
    return dm_spawnable[sc_idx[row]];
}

/* sc_idx by CarInfo.rating, highest first (99 "not recycled": tanks, cops, buses; then
 * 21..23 good, 11..13 average, 1..3 bad: DMA's GTA2 Style Format, docs/formats/specs/),
 * stable, so ties keep the model order */
static void sc_sort(void)
{
    uint8_t key[256];
    for (int i = 0; i < sc_n; i++)
        key[i] = dm_car_info(sc_model(i))->rating;
    for (int i = 1; i < sc_n; i++) {
        uint8_t idx = sc_idx[i], k = key[i];
        int c = i;
        for (; c > 0 && key[c - 1] < k; c--) {
            key[c] = key[c - 1];
            sc_idx[c] = sc_idx[c - 1];
        }
        sc_idx[c] = idx;
        key[c] = k;
    }
}

/* the spawnable models this style has */
static int sc_rows(void)
{
    sc_n = 0;
    for (int i = 0; i < DM_NSPAWNABLE; i++)
        if (dm_car_info(dm_spawnable[i]))
            sc_idx[sc_n++] = (uint8_t)i;
    sc_sort();
    return sc_n;
}

static const char *sc_class(int rating)
{
    if (rating == 99)
        return "special";
    if (rating >= 21)
        return "good";
    if (rating >= 11)
        return "average";
    return "bad";
}

/* the GXT name ("car%d") into a buffer of 64, else our CAR_MODEL4 name */
static void sc_name(int model, char *buf)
{
    char key[16];
    snprintf(key, sizeof key, "car%d", model);
    if (!dm_gxt(key, buf, 40) || buf[0] == ' ')     /* e.gxt has " " for the unused models */
        strcpy(buf, dm_car_names[model]);
}

static void sc_rowfmt(int row, char *buf)
{
    sc_name(sc_model(row), buf);
}

/* sc_remap clamped to that model's remaps */
static int sc_remap_for(const CarInfo *ci)
{
    return ci && sc_remap > ci->num_remaps ? ci->num_remaps : sc_remap;
}

/* sc_spawn (deferred): km_spawn_car 1.5 blocks in front of the player */
static void sc_spawn(void)
{
    int32_t pos[4];
    Sprite *pl = GP(Sprite, km_spawn_pos(pos, SPAWN_DIST));
    gptr car = 0;
    int model = dm_spawnable[dm_model];
    if (pl)
        car = km_spawn_car(model, sc_spawn_choice, pos[0], pos[1], pos[2], pos[3]);
    dm_toast_set(km_spawn_why);
    if (!car)
        return;
    printf("menu: spawned car model %d; player at %d,%d rot %d -> car at %d,%d\n",
           model, pl->x, pl->y, (uint16_t)pl->rotation, pos[0], pos[1]);
    Sprite *body = GP(Sprite, GP(Car, car)->body);
    if (body)
        printf("menu: spawn car remap choice %d -> body remap %d palette kind %d\n",
               km_car_remap_last, body->remap, body->paletteKind);
}

/* LEFT / RIGHT the remap, RETURN spawns */
static void sc_rowchange(int row, int dir)
{
    CarInfo *ci = dm_car_info(sc_model(row));
    int r = sc_remap_for(ci);
    if (!dir) {                         /* the choice now, the spawn on the game's side */
        sc_spawn_choice = r;
        dm_model = sc_idx[dm_page->sel];
        dm_defer(sc_spawn);
        return;
    }
    if (!ci)
        return;
    r += dir;                           /* wrap over -1 .. num_remaps */
    if (r < -1)
        r = ci->num_remaps;
    if (r > ci->num_remaps)
        r = -1;
    sc_remap = r;
}

/* the preview pane for the selected model. The text lines are built first and measured
 * (dm_text_w), so the pane fits the widest of them and the preview. */
static void sc_draw(struct dm_page *page)
{
    if ((uint32_t)page->sel >= (uint32_t)dm_dyn())
        return;                         /* on Back */
    int model = sc_model(page->sel);
    CarInfo *ci = dm_car_info(model);
    if (!ci)
        return;
    char l[SC_NLINES][SC_LINE];
    struct dm_sprite ds = { .type = 2, .id = ci->spriteIndex, .pal = 2 };  /* SPRITE_TYPE_CAR */
    sc_name(model, l[0]);
    int r = sc_remap_for(ci);
    if (r > 0) {
        ds.pal = 3;                     /* car remap; none / random: the sprite's own colours */
        ds.remap = ci->remap[r - 1];
    }
    if (r < 0)
        snprintf(l[1], SC_LINE, "Remap: random");
    else if (!r)
        snprintf(l[1], SC_LINE, "Remap: none");
    else
        snprintf(l[1], SC_LINE, "Remap: %d of %d (%d)", r, ci->num_remaps, ds.remap);
    snprintf(l[2], SC_LINE, "Model %d  %dx%d", model, ci->w, ci->h);
    snprintf(l[3], SC_LINE, "Seats %d  Rating %d %s", ci->passengers + 1, ci->rating,
             sc_class(ci->rating));    /* passengers, plus the driver */
    strcpy(l[4], "Left Right: remap");
    strcpy(l[5], "Return: spawn");
    uint32_t w = SC_BOX;                /* width: the preview or the widest line */
    for (int i = 0; i < SC_NLINES; i++) {
        uint32_t lw = (uint32_t)dm_text_w(l[i]);
        if (lw > w)
            w = lw;
    }
    dm_pane(DM_Y, DM_Y + SC_PANE_H, (int)w);
    dm_text_at(l[0], dm_pane_x, DM_Y, 1);
    ds.x = (int32_t)(w / 2) + dm_pane_x;
    ds.y = DM_Y + 18 + SC_BOX / 2 + 4;
    ds.box = SC_BOX;
    ds.rot = (int32_t)(r_frames * SC_SPIN % 1440);
    dm_sprite(&ds);
    int y = DM_Y + SC_PANE_H - 5 * DM_LINE - DM_LINE / 2;  /* lines 1..5 at the bottom, */
    for (int i = 1; i < SC_NLINES; i++, y += DM_LINE) {    /* a gap before the keys */
        if (i == 4)
            y += DM_LINE / 2;
        dm_text_at(l[i], dm_pane_x, y, 0);
    }
}

DM_PAGE_EXTERN(dmp_spawn);
DM_PAGE(dmp_spawn_car, dmp_spawn, 10, "Car", .draw = sc_draw, .rows = sc_rows,
        .rowfmt = sc_rowfmt, .rowchange = sc_rowchange);
