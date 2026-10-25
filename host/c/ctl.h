/* ctl.h — gta2ctl, the shell control channel (docs/gta2ctl.md). ctl.c owns the socket,
 * the protocol, the commands and telemetry; ctl_game.c reads and steers the game. */
#ifndef CTL_H
#define CTL_H

#include <stddef.h>
#include "game.h"

/* ---- state snapshot: the flat fields of `state`, telemetry and `wait` ---------------- */
enum {
    F_FRAME, F_IN_GAME, F_PAUSED, F_FOCUS, F_X, F_Y, F_Z, F_HEADING, F_HEALTH, F_ARMOUR,
    F_MONEY, F_WANTED, F_WANTED_POINTS, F_IN_CAR, F_DRIVER, F_CAR_ID, F_CAR_MODEL, F_SPEED,
    F_WEAPON, F_AMMO, F_PED_STATE, F_OBJECTIVE, F_PED_ID, F_DEAD, F_NFIELDS
};
struct ctl_field { const char *name; char kind; };   /* kind: 'i' int, 'f' float, 'b' bool */
extern const struct ctl_field ctl_fields[F_NFIELDS];

typedef struct {
    double v[F_NFIELDS];
    uint8_t valid[F_NFIELDS];
} ctl_state;

void ctl_snapshot(ctl_state *s);
int ctl_field_index(const char *name);          /* -1 = unknown */

/* ---- JSON output ------------------------------------------------------------------- */
typedef struct { char buf[16384]; size_t len; } jbuf;
void jb_printf(jbuf *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void jb_str(jbuf *b, const char *s);            /* a quoted, escaped JSON string */
void ctl_fields_json(jbuf *b, const ctl_state *s);   /* "name":value,... (no braces) */
void ctl_lists_json(jbuf *b);                   /* ,"cars":[...],"peds":[...] */
int ctl_ped_json(jbuf *b, int id);              /* ,"ped":{...}; 0 = no live ped with that id */
int ctl_hunt_json(jbuf *b, int id);             /* ,"hunt":{...},"target":{...},"hunters":[...] */

/* ---- game access (ctl_game.c) -------------------------------------------------------- */
Ped *ctl_ped(void);                             /* the local player's ped, or 0 */
int ctl_pos(int32_t *x, int32_t *y, int32_t *z);   /* the player's (or his car's) position */
gptr ctl_car_by_id(uint32_t id);                /* a live car with that id, or 0 */
gptr ctl_nearest_car(void);                     /* the nearest car that is not the player's */
int32_t ctl_dist(int32_t ax, int32_t ay, int32_t bx, int32_t by);   /* SCR_f */
int ctl_teleport(int32_t x, int32_t y, int32_t z, int has_z, const char **why);
int ctl_order_enter(gptr car, int passenger, const char **why);
int ctl_order_exit(const char **why);
void ctl_cancel_objective(void);
int ctl_order_walk(int32_t x, int32_t y, int32_t z, const char **why);   /* experimental */
void ctl_clear_objective(void);
void ctl_autopilot_off(void);
void ctl_drive_debug(void);
void ctl_drive_assist(void);
int ctl_sms(const char *text);
uint32_t ctl_brief_text(gptr key);
int ctl_order_drive(int32_t x, int32_t y, int32_t z, const char **why);  /* experimental */               /* a pending ENTER_CAR, before the door */

/* steering: applied by ctl_on_foot after Player_MoveOnFoot every tick */
enum { STEER_NONE, STEER_GOTO, STEER_FACE };
typedef struct {
    int mode;
    int32_t tx, ty, radius;                     /* goto: target and arrival radius, SCR_f */
    int heading;                                /* face: Ang16 */
    int done;                                   /* set by ctl_on_foot: arrived / facing */
} ctl_steer_t;
extern ctl_steer_t ctl_steer;
void ctl_on_foot(gptr player, gptr ped);        /* after Player_MoveOnFoot (c32/player_move.c) */

#define SCR_ONE 16384.0
static inline double scr_to_f(int32_t v) { return v / SCR_ONE; }
static inline int32_t f_to_scr(double v) { return (int32_t)(v * SCR_ONE + (v < 0 ? -0.5 : 0.5)); }

#endif
