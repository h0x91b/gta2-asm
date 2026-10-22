/* config.c — the user's settings: config.yaml in the overlay dir, or --config=PATH.
 *
 * The format is a small, line-based subset of YAML (there is no YAML library on the host
 * side, and a full parser is not worth it for flat settings):
 *   # comment                  at the start of a line or after a blank
 *   section:                   a top-level key without a value opens a section
 *     key: value               an indented key belongs to the last section
 * Indent with spaces only. Lists, quotes, flow syntax and multi-line values are errors
 * (with the line number, the loader stops); unknown sections and keys are reported and
 * skipped. config.example.yaml lists every key.
 *
 * Every key is one line of `keys[]` below: section, name, type, storage, default, range.
 * The defaults are written into the storage before main (cfg_defaults), so a run without
 * a config, or without --entry, sees them too. Types:
 *   BOOL   uint8_t 0/1: true/false, yes/no, on/off, 1/0 (any case)
 *   INT    int32_t, decimal, min..max
 *   ZOOM   int32_t, `auto` (ZOOM_AUTO) or decimal min..max
 *   KEY    uint8_t DIK, a key name as in --keys (key_table, w32_dinput.asm)
 *   DEBUG  a game debug flag in the in-memory registry (no storage, see below)
 *   MODS   any key of the section goes to a handler (C32 mods, c32_cfg_mods)
 * A key is logged as `config: section.key = value` when applied, unless it is QUIET
 * (controls: pm_report prints them in one line after the config).
 *
 * Sections:
 *   debug  the game's own debug flags. HiddenDebugFlags (0x451930, called once from
 *          WinMain at 0x4D121A) reads them from HKCU\SOFTWARE\DMA Design Ltd\GTA2\Debug
 *          through RegGet (0x4B53B0), which reports a flag as set when the value merely
 *          EXISTS (MOV BL,1 on RegQueryValueExA == 0; the data is never looked at). So
 *          `true` creates the value and `false` deletes it from our in-memory registry
 *          (gta2_install.reg already seeds do_blood and do_debug_keys). The exception,
 *          show_player_names, is read by value with default 1
 *          (GetSettingBooleanWithDefaultValue 0x4B5AE0) and is written as dword 0/1.
 *          Applied before the game starts: a change needs a restart. Names compare
 *          case-insensitively, like the registry.
 *          From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 *          src/modules/modmenu/utils/categorized-native-cheats-data.cpp and
 *          src/events/after-debug-flags.cpp @25b1985 — the idea, the RISKY marks and the
 *          name GetSettingBooleanWithDefaultValue; the registry path is own analysis.
 *   controls  on-foot strafe and mouse turning (player_move.asm): strafe, strafe_left,
 *          strafe_right (key names as in --keys), mouse_turn, mouse_sensitivity (percent).
 *   camera zoom: auto | percent (25..400). The camera's target zoom (cameraPosTarget.zoom,
 *          the view scale) is multiplied by percent/100 on its way to the camera
 *          (hk_CameraPosApply, w32_hooks.asm); smaller = more city. Vanilla 1280x960
 *          shows the same part of the city as 640x480, only magnified (measured), so
 *          auto = 640 / window width keeps the original 640x480 pixel scale at any size.
 *          Without the key it is 70%; `zoom: 100` is the vanilla view.
 *   mods   gameplay mods (C32, docs/c32.md): passenger_enter (Shift+Enter gets in as a
 *          passenger, docs/passenger.md; a BOOL here), and the rest through c32_cfg_mods
 *          (c/c32_host.c): car_enter_bonus (dollars per car entry, 0 = off).
 *
 * Called from NASM: cfg_set_path (loader.asm, --config=), config_apply (w32_advapi32.asm,
 * after the registry seed). Host test: host/test/config_test.c (build.sh --test).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include "game.h"

#define CFG_LINE    1024
#define CFG_PATH    1024
#define ZOOM_AUTO   (-1)                 /* ZOOM_*: also equs in c_bridge.asm (hooks, K menu) */
#define ZOOM_MIN    25
#define ZOOM_MAX    400

/* ---- NASM side (host/c_bridge.asm) ----------------------------------------------------- */

/* w32_advapi32.asm: the in-memory registry */
struct reg_val { uint32_t key, type, size, live; char *name; uint8_t *data; };
int reg_key_add(const char *path) NASM(reg_key_add);                /* index, -1 = full */
struct reg_val *reg_val_find(int key, const char *name) NASM(reg_val_find);
void reg_val_set(int key, const char *name, uint32_t type, const void *data,
                 uint32_t size) NASM(reg_val_set);
/* loader.asm: print "loader: FAIL: msg", exit 1 */
_Noreturn void fail(const char *msg) NASM(fail);
/* w32_dinput.asm: {u16 SDL scancode, u8 DIK, u8 VK, u32 0, char *name}, ends at 0xFFFF */
struct key_ent { uint16_t sdl; uint8_t dik, vk; uint32_t pad; const char *name; };
extern const struct key_ent key_table[] NASM(key_table);
/* player_move.asm: the controls, and their one-line summary */
extern uint8_t pm_strafe_on NASM(pm_strafe_on);
extern uint8_t pm_mouse_on NASM(pm_mouse_on);
extern uint8_t pm_key_left NASM(pm_key_left);
extern uint8_t pm_key_right NASM(pm_key_right);
extern int32_t pm_mouse_sens NASM(pm_mouse_sens);
void pm_report(void) NASM(pm_report);
/* c32_host.c: the mods section, 0 applied, 1 unknown key, -1 bad value (*msg = why) */
int c32_cfg_mods(const char *key, const char *val, const char **msg);
extern uint8_t mods_passenger_enter;    /* c32_host.c, read by c32/passenger.c */

/* camera.zoom for hk_CameraPosApply (w32_hooks.asm): ZOOM_AUTO or percent */
int32_t cam_zoom_cfg NASM(cam_zoom_cfg);

/* ---- the keys ------------------------------------------------------------------------- */

enum { T_BOOL, T_INT, T_ZOOM, T_KEY, T_DEBUG, T_MODS };
enum { F_QUIET = 1, F_VALUE = 2 };      /* not logged; DEBUG read by value, not presence */

struct cfg_key {
    const char *section, *name;         /* name 0: every key of the section (MODS) */
    uint8_t type, flags;
    void *ptr;                          /* uint8_t (BOOL, KEY) or int32_t (INT, ZOOM) */
    int32_t def, min, max;
    const char *what;                   /* INT, ZOOM: "expected <what> min..max" */
};

#define DBG(n)  { "debug", n, T_DEBUG, 0, 0, 0, 0, 0, 0 }

static const struct cfg_key keys[] = {
    { "camera",   "zoom",              T_ZOOM, 0,       &cam_zoom_cfg,  70, ZOOM_MIN, ZOOM_MAX, "a percentage" },
    { "controls", "strafe",            T_BOOL, F_QUIET, &pm_strafe_on,  1,  0,  1,    0 },
    { "controls", "mouse_turn",        T_BOOL, F_QUIET, &pm_mouse_on,   0,  0,  1,    0 },
    { "controls", "strafe_left",       T_KEY,  F_QUIET, &pm_key_left,   0x10, 0, 0,   0 }, /* DIK_Q */
    { "controls", "strafe_right",      T_KEY,  F_QUIET, &pm_key_right,  0x12, 0, 0,   0 }, /* DIK_E */
    { "controls", "mouse_sensitivity", T_INT,  F_QUIET, &pm_mouse_sens, 100, 10, 1000, "a percentage" },
    { "mods",     "passenger_enter",   T_BOOL, 0,       &mods_passenger_enter, 1, 0, 1, 0 },
    { "mods",     0,                   T_MODS, 0,       0,              0,  0,  0,    0 },
    /* every name HiddenDebugFlags (0x451930) reads with RegGet, in its order, plus
     * show_player_names; do_3d_sound is left out (another key, via 0x4B5000) */
    DBG("play_replay"), DBG("do_test"), DBG("skip_mission"), DBG("show_cycle"),
    DBG("do_brian_test"), DBG("do_iain_test"), DBG("skip_tiles"), DBG("do_show_counters"),
    DBG("do_show_camera"), DBG("do_show_input"), DBG("do_show_timing"),
    DBG("do_show_collision_box"), DBG("do_show_physics"), DBG("do_show_imaginary"),
    DBG("skip_user"), DBG("skip_traffic_lights"), DBG("skip_recycling"),
    DBG("log_collisions"), DBG("do_show_traffic_lights_info"), DBG("do_show_ids"),
    DBG("limit_recycling"), DBG("no_annoying_chars"), DBG("skip_slopes"), DBG("skip_left"),
    DBG("skip_right"), DBG("skip_top"), DBG("skip_bottom"), DBG("skip_lid"),
    DBG("log_routefinder"), DBG("do_mike"), DBG("skip_particles"), DBG("show_hidden_faces"),
    DBG("get_all_weapons"), DBG("do_exit_after_replay"), DBG("dont_get_car_back"),
    DBG("do_show_instruments"), DBG("skip_ambulance"), DBG("skip_police"),
    DBG("skip_frontend"), DBG("do_invulnerable"), DBG("show_all_arrows"), DBG("do_show_horn"),
    DBG("keep_weapons_after_death"), DBG("skip_skidmarks"), DBG("do_show_junc_ids"),
    DBG("do_corner_window"), DBG("do_infinite_lives"), DBG("do_load_savegame"),
    DBG("skip_audio"), DBG("do_debug_keys"), DBG("log_random"), DBG("log_random_extra"),
    DBG("log_input"), DBG("log_directinput"), DBG("ignore_replay_header"), DBG("skip_trains"),
    DBG("skip_buses"), DBG("skip_quit_confirm"), DBG("do_sync_check"),
    DBG("skip_fire_engines"), DBG("show_brief_number"), DBG("skip_window_check"),
    DBG("skip_replay_sync_check"), DBG("do_show_object_ids"), DBG("do_kill_phones_on_answer"),
    DBG("do_miss_logging"), DBG("do_text_id_test"), DBG("do_police_1"), DBG("do_police_2"),
    DBG("do_police_3"), DBG("skip_draw"), DBG("do_free_shopping"), DBG("skip_dummies"),
    DBG("do_blood"),
    { "debug", "show_player_names", T_DEBUG, F_VALUE, 0, 0, 0, 0, 0 },
};
#define NKEYS (sizeof keys / sizeof keys[0])

static const char REG_DEBUG[] = "HKEY_CURRENT_USER\\SOFTWARE\\DMA Design Ltd\\GTA2\\Debug";
static const char MSG_BOOL[] = "expected true or false (also yes/no, on/off, 1/0)";

/* the defaults, before main: nothing reads a setting before the loader starts */
__attribute__((constructor)) static void cfg_defaults(void)
{
    for (size_t i = 0; i < NKEYS; i++) {
        const struct cfg_key *k = &keys[i];
        if (k->type == T_BOOL || k->type == T_KEY)
            *(uint8_t *)k->ptr = (uint8_t)k->def;
        else if (k->type == T_INT || k->type == T_ZOOM)
            *(int32_t *)k->ptr = k->def;
    }
}

/* ---- the file ------------------------------------------------------------------------- */

static const char *cfg_path;            /* 0 = config.yaml in the overlay dir (the cwd) */
static int cfg_explicit;                /* --config= given: a missing file is an error */
static char cfg_abs[CFG_PATH];

/* --config=PATH: remember it as an absolute path, because the loader chdirs into the
 * overlay dir before the config is read */
void cfg_set_path(const char *path)
{
    cfg_explicit = 1;
    cfg_path = path;
    if (path[0] != '/' && getcwd(cfg_abs, sizeof cfg_abs)
        && strlen(cfg_abs) + 1 + strlen(path) < sizeof cfg_abs) {
        strcat(cfg_abs, "/");
        strcat(cfg_abs, path);
        cfg_path = cfg_abs;
    }
}

static int cfg_line_no;

static _Noreturn void cfg_error(const char *msg)
{
    static char buf[CFG_LINE];
    snprintf(buf, sizeof buf, "config: %s:%d: %s", cfg_path, cfg_line_no, msg);
    fail(buf);
}

static _Noreturn void cfg_bad_value(const struct cfg_key *k, const char *expected)
{
    char msg[256];
    snprintf(msg, sizeof msg, "%s.%s: %s", k->section, k->name, expected);
    cfg_error(msg);
}

/* 1, 0, or -1 if v is not a boolean */
static int cfg_bool(const char *v)
{
    static const char *const on[] = { "true", "yes", "on", "1" };
    static const char *const off[] = { "false", "no", "off", "0" };
    for (int i = 0; i < 4; i++) {
        if (!strcasecmp(v, on[i]))
            return 1;
        if (!strcasecmp(v, off[i]))
            return 0;
    }
    return -1;
}

/* a whole decimal number in min..max, else 0 */
static int cfg_int(const char *v, int32_t min, int32_t max, int32_t *out)
{
    char *end;
    long n = strtol(v, &end, 10);
    if (end == v || *end || n < min || n > max)
        return 0;
    *out = (int32_t)n;
    return 1;
}

/* a debug flag into the registry; logs what is set and what was actually removed (not
 * every absent `false`) */
static void cfg_debug_set(const struct cfg_key *k, int on)
{
    int key = reg_key_add(REG_DEBUG);
    if (key < 0)
        return;
    if (on || (k->flags & F_VALUE)) {
        uint32_t dword = (uint32_t)on;
        reg_val_set(key, k->name, 4 /* REG_DWORD */, &dword, 4);
    } else {
        struct reg_val *v = reg_val_find(key, k->name);
        if (!v)
            return;
        v->live = 0;
    }
    printf("config: debug.%s = %s\n", k->name, on ? "on" : "off");
}

/* apply one `key: val` of a known section; 1 applied, 0 unknown key */
static int cfg_set(const char *section, const char *key, const char *val)
{
    const struct cfg_key *k = 0;
    for (size_t i = 0; i < NKEYS && !k; i++) {
        if (strcmp(keys[i].section, section))
            continue;
        if (!keys[i].name || (keys[i].type == T_DEBUG ? !strcasecmp(keys[i].name, key)
                                                      : !strcmp(keys[i].name, key)))
            k = &keys[i];
    }
    if (!k)
        return 0;
    char expected[128];
    int32_t n;
    switch (k->type) {
    case T_BOOL:
    case T_DEBUG:
        if ((n = cfg_bool(val)) < 0)
            cfg_bad_value(k, MSG_BOOL);
        if (k->type == T_DEBUG) {
            cfg_debug_set(k, n);
            return 1;
        }
        *(uint8_t *)k->ptr = (uint8_t)n;
        break;
    case T_INT:
    case T_ZOOM:
        if (k->type == T_ZOOM && !strcmp(val, "auto"))
            n = ZOOM_AUTO;
        else if (!cfg_int(val, k->min, k->max, &n)) {
            snprintf(expected, sizeof expected, "expected %s%s %d..%d",
                     k->type == T_ZOOM ? "auto or " : "", k->what, k->min, k->max);
            cfg_bad_value(k, expected);
        }
        *(int32_t *)k->ptr = n;
        break;
    case T_KEY: {
        const struct key_ent *e = key_table;
        while (e->sdl != 0xFFFF && strcasecmp(e->name, val))
            e++;
        if (e->sdl == 0xFFFF || !e->dik)
            cfg_bad_value(k, "expected a key name as in --keys (Q, E, A, LSHIFT, ...)");
        *(uint8_t *)k->ptr = e->dik;
        break;
    }
    case T_MODS: {
        const char *msg = 0;
        int r = c32_cfg_mods(key, val, &msg);
        if (r < 0)
            cfg_error(msg);
        return r == 0;                  /* c32_cfg_mods logs it */
    }
    }
    if (!(k->flags & F_QUIET))
        printf("config: %s.%s = %s\n", k->section, k->name, val);
    return 1;
}

static int cfg_section_known(const char *name)
{
    for (size_t i = 0; i < NKEYS; i++)
        if (!strcmp(keys[i].section, name))
            return 1;
    return 0;
}

/* strip trailing CR/LF/blanks (everything <= ' ', like reg_rstrip) */
static void rstrip(char *s)
{
    size_t n = strlen(s);
    while (n && (unsigned char)s[n - 1] <= ' ')
        s[--n] = 0;
}

/* read the config and apply it; runs after the registry seed */
void config_apply(void)
{
    if (!cfg_path)
        cfg_path = "config.yaml";
    FILE *f = fopen(cfg_path, "r");
    if (!f) {
        if (cfg_explicit) {
            static char msg[CFG_LINE];
            snprintf(msg, sizeof msg, "config: cannot open %s", cfg_path);
            fail(msg);
        }
        printf("config: %s not found (optional), defaults\n", cfg_path);
        pm_report();
        return;
    }
    static char line[CFG_LINE];
    char section[CFG_LINE] = "";
    int in_section = -1;                /* -1 none yet, 0 unknown (skipped), 1 known */
    int nset = 0;
    cfg_line_no = 0;
    while (fgets(line, sizeof line, f)) {
        cfg_line_no++;
        for (char *c = line; *c; c++)   /* a comment: '#' at column 0 or after a blank */
            if (*c == '#' && (c == line || c[-1] == ' ' || c[-1] == '\t')) {
                *c = 0;
                break;
            }
        rstrip(line);
        if (!line[0])
            continue;
        int indent = (int)strspn(line, " ");
        char *key = line + indent;
        if (*key == '\t')
            cfg_error("tabs are not allowed in indentation, use spaces");
        if (strchr("-\"'{[", *key))
            cfg_error("only 'key: value' lines are supported (no lists, quotes or {} [])");
        char *val = strchr(key, ':');
        if (!val)
            cfg_error("expected 'key: value' or 'section:'");
        *val++ = 0;
        val += strspn(val, " ");
        rstrip(key);
        if (!key[0])
            cfg_error("expected 'key: value' or 'section:'");
        if (!indent) {                  /* top level: a section header */
            if (*val)
                cfg_error("a top-level key must be a section header ('debug:'), not 'key: value'");
            in_section = cfg_section_known(key);
            if (in_section)
                snprintf(section, sizeof section, "%s", key);
            else
                printf("config: %s:%d: unknown section '%s', skipped\n", cfg_path, cfg_line_no, key);
            continue;
        }
        if (in_section < 0)
            cfg_error("indented key before any section header");
        if (!in_section)
            continue;
        if (cfg_set(section, key, val))
            nset++;
        else
            printf("config: %s:%d: unknown key '%s', skipped\n", cfg_path, cfg_line_no, key);
    }
    fclose(f);
    printf("config: %s -> %d setting(s) applied\n", cfg_path, nset);
    pm_report();
}
