/* config_test.c — host test of the config.yaml reader (host/c/config.c), without the
 * loader: the NASM symbols config.c uses (registry, key_table, player_move's controls,
 * fail) are stubs here, fail() longjmps back with its message. `host/build.sh --test`.
 */
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include "../c/game.h"

void cfg_set_path(const char *path);
void config_apply(void);
extern int32_t cam_zoom_cfg NASM(cam_zoom_cfg);

/* ---- stubs ---------------------------------------------------------------------------- */

struct reg_val { uint32_t key, type, size, live; char *name; uint8_t *data; };
static struct reg_val vals[16];
static uint32_t dwords[16];
static int nvals;

int reg_key_add(const char *path) NASM(reg_key_add);
int reg_key_add(const char *path) { (void)path; return 3; }

struct reg_val *reg_val_find(int key, const char *name) NASM(reg_val_find);
struct reg_val *reg_val_find(int key, const char *name)
{
    for (int i = 0; i < nvals; i++)
        if (vals[i].live && vals[i].key == (uint32_t)key && !strcasecmp(vals[i].name, name))
            return &vals[i];
    return 0;
}

void reg_val_set(int key, const char *name, uint32_t type, const void *data, uint32_t size)
    NASM(reg_val_set);
void reg_val_set(int key, const char *name, uint32_t type, const void *data, uint32_t size)
{
    struct reg_val *v = reg_val_find(key, name);
    if (!v) {
        v = &vals[nvals];
        dwords[nvals] = 0;
        *v = (struct reg_val){ (uint32_t)key, 0, 0, 1, strdup(name), (uint8_t *)&dwords[nvals] };
        nvals++;
    }
    v->type = type;
    v->size = size;
    memcpy(v->data, data, 4);
}

static jmp_buf failed;
static char fail_msg[1024];
_Noreturn void fail(const char *msg) NASM(fail);
_Noreturn void fail(const char *msg)
{
    snprintf(fail_msg, sizeof fail_msg, "%s", msg);
    longjmp(failed, 1);
}

struct key_ent { uint16_t sdl; uint8_t dik, vk; uint32_t pad; const char *name; };
const struct key_ent key_table[] NASM(key_table) = {
    { 4, 0x1E, 'A', 0, "A" }, { 20, 0x10, 'Q', 0, "Q" }, { 8, 0x12, 'E', 0, "E" },
    { 225, 0x2A, 0x10, 0, "LSHIFT" }, { 0xFFFF, 0, 0, 0, 0 },
};
uint8_t pm_strafe_on NASM(pm_strafe_on);
uint8_t pm_mouse_on NASM(pm_mouse_on);
uint8_t pm_key_left NASM(pm_key_left);
uint8_t pm_key_right NASM(pm_key_right);
int32_t pm_mouse_sens NASM(pm_mouse_sens);
static int reports;
void pm_report(void) NASM(pm_report);
void pm_report(void) { reports++; }

uint8_t mods_passenger_enter;

static long mods_bonus = -1;
int c32_cfg_mods(const char *key, const char *val, const char **msg)
{
    if (strcmp(key, "car_enter_bonus"))
        return 1;
    char *end;
    long v = strtol(val, &end, 10);
    if (end == val || *end || v < 0) {
        *msg = "mods.car_enter_bonus: bad";
        return -1;
    }
    mods_bonus = v;
    return 0;
}

/* ---- tests ---------------------------------------------------------------------------- */

static int failures;
static char path[256];

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* write text to a temp file and apply it; returns 0 or 1 if fail() was called */
static int run(const char *text)
{
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
    fail_msg[0] = 0;
    cfg_set_path(path);
    if (setjmp(failed))
        return 1;
    config_apply();
    return 0;
}

static uint32_t debug_val(const char *name, int *live)
{
    struct reg_val *v = reg_val_find(3, name);
    *live = v != 0;
    return v ? *(uint32_t *)v->data : 0;
}

int main(void)
{
    snprintf(path, sizeof path, "/tmp/gta2_config_test_%d.yaml", (int)getpid());
    int live;

    /* defaults are in place before main */
    CHECK(cam_zoom_cfg == 70 && pm_strafe_on == 1 && pm_mouse_on == 0);
    CHECK(pm_key_left == 0x10 && pm_key_right == 0x12 && pm_mouse_sens == 100);
    CHECK(mods_passenger_enter == 1);

    CHECK(run("# a comment\n"
              "camera:\n"
              "  zoom: 150   # comment after a blank\n"
              "\n"
              "controls:\n"
              "  strafe: no\n"
              "  mouse_turn: ON\n"
              "  strafe_left: a\n"
              "  strafe_right: LSHIFT\n"
              "  mouse_sensitivity: 250\r\n"
              "mods:\n"
              "  car_enter_bonus: 500\n"
              "  passenger_enter: off\n"
              "debug:\n"
              "  DO_BLOOD: true\n"
              "  show_player_names: off\n"
              "  do_show_ids: false\n"
              "  no_such_flag: maybe\n"
              "weather:\n"
              "  rain: whatever\n") == 0);
    CHECK(cam_zoom_cfg == 150 && pm_strafe_on == 0 && pm_mouse_on == 1);
    CHECK(pm_key_left == 0x1E && pm_key_right == 0x2A && pm_mouse_sens == 250);
    CHECK(mods_bonus == 500 && reports == 1 && mods_passenger_enter == 0);
    CHECK(debug_val("do_blood", &live) == 1 && live);
    CHECK(debug_val("show_player_names", &live) == 0 && live);   /* by value: dword 0 */
    debug_val("do_show_ids", &live);
    CHECK(!live);
    CHECK(run("debug:\n  do_blood: 0\n") == 0);                   /* false deletes it */
    debug_val("do_blood", &live);
    CHECK(!live);
    CHECK(run("camera:\n  zoom: auto\n") == 0 && cam_zoom_cfg == -1);
    CHECK(run("camera:\n  zoom: 25\n") == 0 && cam_zoom_cfg == 25);
    CHECK(run("camera:\n  zoom#x: 3\n") == 0 && cam_zoom_cfg == 25); /* '#' inside a word: unknown key */

    /* errors: the line number and why */
    static const struct { const char *text, *msg; } bad[] = {
        { "debug:\n\tdo_blood: true\n", "config: %s:2: tabs are not allowed" },
        { "camera:\n  zoom: 999\n", "config: %s:2: camera.zoom: expected auto or a percentage 25..400" },
        { "camera:\n  zoom: 50x\n", "config: %s:2: camera.zoom: expected auto or a percentage" },
        { "controls:\n  mouse_sensitivity: 5\n", "config: %s:2: controls.mouse_sensitivity: expected a percentage 10..1000" },
        { "controls:\n  strafe_left: NOPE\n", "config: %s:2: controls.strafe_left: expected a key name" },
        { "controls:\n  strafe: 2\n", "config: %s:2: controls.strafe: expected true or false" },
        { "debug:\n  do_blood: maybe\n", "config: %s:2: debug.do_blood: expected true or false" },
        { "mods:\n  car_enter_bonus: -3\n", "config: %s:2: mods.car_enter_bonus: bad" },
        { "zoom: 50\n", "config: %s:1: a top-level key must be a section header" },
        { "  zoom: 50\n", "config: %s:1: indented key before any section header" },
        { "camera:\n  - zoom\n", "config: %s:2: only 'key: value' lines" },
        { "camera:\n  zoom 50\n", "config: %s:2: expected 'key: value' or 'section:'" },
        { "camera:\n  : 50\n", "config: %s:2: expected 'key: value' or 'section:'" },
        { "weather:\n  'x': 1\n", "config: %s:2: only 'key: value' lines" },
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        char want[512];
        snprintf(want, sizeof want, bad[i].msg, path);
        int r = run(bad[i].text);
        if (r != 1 || strncmp(fail_msg, want, strlen(want))) {
            printf("FAIL bad[%zu]: got %s '%s'\n  want '%s...'\n", i, r ? "fail" : "no fail",
                   fail_msg, want);
            failures++;
        }
    }
    CHECK(cam_zoom_cfg == 25);          /* a refused value changes nothing */

    /* --config= naming a missing file is an error */
    fail_msg[0] = 0;
    cfg_set_path("/nonexistent/config.yaml");
    if (!setjmp(failed)) {
        config_apply();
        CHECK(!"missing --config file accepted");
    }
    CHECK(!strcmp(fail_msg, "config: cannot open /nonexistent/config.yaml"));

    remove(path);
    printf("config_test: %s (%d failure(s))\n", failures ? "FAIL" : "PASS", failures);
    return failures != 0;
}
