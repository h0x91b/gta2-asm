/* car_tune.c — the K menu's Vehicle → Tuning page: the handling of the car the player is in,
 * one row per value (LEFT / RIGHT change it), reset of this model and of every model. The
 * game logic is C32 (host/c32/car_tune.c, docs/car-tuning.md): a row only records the
 * request, and the DM_FRAME hands it to the C32 ct_frame on the game's side of the frame,
 * which also refreshes the exported ct_view the rows print. Handling is per model, so the
 * edit reaches every car of that model, traffic included.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dm.h"

#define CT_NFIELDS 11                   /* = fields[] in host/c32/car_tune.c */

struct ct_view {                        /* host/c32/car_tune.c */
    int32_t model, tuned, tuned_models;
    int32_t cur[CT_NFIELDS], stock[CT_NFIELDS];
};

enum { OP_STEP = 1, OP_RESET, OP_RESET_ALL };

static void *c32_need(const char *name)
{
    void *p = c32_find(name);
    if (!p) {
        printf("c32: FAIL: the image exports no %s\n", name);
        exit(1);
    }
    return p;
}

DM_PAGE_EXTERN(dmp_tune);

static uint32_t req, req_field;
static int32_t req_dir;
static gptr fn_frame;                   /* C32 exports: ct_frame, ct_view */
static const struct ct_view *view;

/* DM_FRAME: const char *ct_frame(op, field, dir) in C32, while the page is current */
static void ct_tick(void)
{
    if (!fn_frame) {
        fn_frame = (gptr)(uintptr_t)c32_need("ct_frame");
        view = c32_need("ct_view");
    }
    if (!req && dm_page != &dmp_tune)
        return;
    uint32_t a[3] = { req, req_field, (uint32_t)req_dir };
    req = 0;
    gptr toast = (gptr)call32(fn_frame, a, 3, 0, 0, 0);
    if (toast)
        dm_toast_set((const char *)(uintptr_t)toast);   /* C32 memory, mapped 1:1 */
}
DM_FRAME(40, ct_tick);

/* Q14 as "0.247" */
static void q14(char *buf, size_t n, int32_t v)
{
    snprintf(buf, n, "%.3f", v / 16384.0);
}

static void header_change(const struct dm_item *it, int dir)
{
    (void)it;
    (void)dir;
}

static void header_fmt(char *end)
{
    if (!view || view->model < 0) {
        strcpy(end, "Not in a car");
        return;
    }
    snprintf(end, 64, "%s (model %d): %s",
             view->model < DM_NCARNAMES ? dm_car_names[view->model] : "-", view->model,
             view->tuned ? "tuned" : "stock");
}

/* one row per field: the item's order / 10 - 1 is the field index */
static int field_of(const struct dm_item *it) { return it->order / 10 - 1; }

static void field_change(const struct dm_item *it, int dir)
{
    if (!dir)
        return;
    req = OP_STEP;
    req_field = (uint32_t)field_of(it);
    req_dir = dir;
}

/* the value and how it compares to stock: "0.272 (110%)" for scaled values, "0.30 (stock
 * 0.25)" for stepped ones, "on (stock off)" for turbo */
static void field_fmt_n(char *end, int f, int kind)
{
    if (!view || view->model < 0) {
        strcpy(end, "-");
        return;
    }
    int32_t v = view->cur[f], s = view->stock[f];
    char a[16], b[16];
    if (kind == 2)
        snprintf(end, 48, v == s ? "%s" : "%s (stock %s)", v ? "on" : "off", s ? "on" : "off");
    else if (kind == 1) {
        q14(a, sizeof a, v);
        q14(b, sizeof b, s);
        snprintf(end, 48, v == s ? "%s" : "%s (stock %s)", a, b);
    } else {
        q14(a, sizeof a, v);
        snprintf(end, 48, "%s (%d%%)", a, s ? (int)((int64_t)v * 100 / s) : 0);
    }
}

/* kind per field: 0 scaled x1.1, 1 fixed step, 2 on/off (host/c32/car_tune.c fields[]) */
#define CT_ROW(n, name, kind)                                       \
    static void f##n##_fmt(char *end) { field_fmt_n(end, n - 1, kind); } \
    static const struct dm_value dmv_f##n = { field_change, f##n##_fmt }; \
    DM_ITEM(dmp_tune, n * 10, DM_VALUE, name ": ", &dmv_f##n)

CT_ROW(1, "Top speed", 0);
CT_ROW(2, "Acceleration", 0);
CT_ROW(3, "Turbo", 2);
CT_ROW(4, "Mass", 0);
CT_ROW(5, "Brakes", 0);
CT_ROW(6, "Steering lock", 0);
CT_ROW(7, "Turn-in", 1);
CT_ROW(8, "Rear grip", 0);
CT_ROW(9, "Handbrake slide", 1);
CT_ROW(10, "Front drive", 1);
CT_ROW(11, "Damage taken", 1);

static void reset_change(const struct dm_item *it, int dir)
{
    (void)it;
    if (!dir)
        req = OP_RESET;
}

static void reset_fmt(char *end) { (void)end; }

static void resetall_change(const struct dm_item *it, int dir)
{
    (void)it;
    if (!dir)
        req = OP_RESET_ALL;
}

static void resetall_fmt(char *end) { snprintf(end, 32, "%d tuned", view ? view->tuned_models : 0); }

DM_VALUE_FNS(header);
DM_VALUE_FNS(reset);
DM_VALUE_FNS(resetall);

DM_PAGE(dmp_tune, dmp_vehicle, 60, "Tuning");
DM_ITEM(dmp_tune, 0, DM_VALUE, "", &dmv_header);
DM_ITEM(dmp_tune, 200, DM_VALUE, "Reset this model", &dmv_reset);
DM_ITEM(dmp_tune, 210, DM_VALUE, "Reset all models: ", &dmv_resetall);
