/* ctl.c — gta2ctl: control a running game from the shell (docs/gta2ctl.md).
 *
 * --ctl[=PATH] opens a Unix domain socket (default $TMPDIR/gta2ctl-<pid>.sock). Protocol:
 * one request line "cmd arg ..." -> one JSON reply line, {"ok":true,...} or
 * {"ok":false,"error":"..."}. Nothing is done on the socket's own schedule: ctl_frame runs
 * once per presented frame from Vid_FlipBuffers (w32_renderer.asm), on the game thread
 * between two game frames, accepts clients, reads their lines, starts commands and steps
 * the blocking ones (goto, enter_car, wait, ...), which reply when done or on timeout.
 * One command per client at a time; several clients may be connected (an agent's script
 * and a `gta2ctl state` from another shell). Steering commands (goto, face, enter_car)
 * share the player: a new one preempts the old one, which replies "preempted".
 *
 * --telemetry=PATH[,every=N] writes the state fields as one JSON line every N frames,
 * with or without --ctl. Without both, nothing here runs (vanilla runs unchanged).
 *
 * 64-bit host C: a host feature (socket, CLI, logs), docs/host-c.md. */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include "ctl.h"
#include "spawn.h"

extern uint32_t ctl_autopilot_ticks;

/* NASM side (host/c_bridge.asm) */
struct key_entry { uint16_t scancode; uint8_t dik, vk; uint32_t pad; const char *name; };
extern const struct key_entry key_table[] NASM(key_table);   /* w32_dinput.asm */
void input_push_key(int scancode, int down) NASM(input_push_key);
void input_mouse_motion(float dx, float dy) NASM(input_mouse_motion);  /* w32_dinput.asm */
void r_save_shot(void) NASM(r_save_shot);                    /* w32_renderer.asm */
extern char *r_shot_path NASM(r_shot_path);

#define MAX_CLIENTS   8
#define LINE_MAX_     1024
#define MAX_ARGS      16
#define KEY_HOLD      4                 /* frames, as --keys */
#define ENTER_RANGE   (int32_t)(1.5 * SCR_ONE)   /* approach the car this close, then enter */
#define GOTO_RADIUS   (int32_t)(0.3 * SCR_ONE)
#define STUCK_FRAMES  90
#define STUCK_GAIN    (int32_t)(0.05 * SCR_ONE)
#define ENTER_TRIES   3
/* drive_to: close enough. The game's own test is the exact tile, and its route ends at a junction
 * past the goal, so a car often goes by the target in the other carriageway (~3.6 blocks off) */
#define DRIVE_RADIUS  (int32_t)(4.0 * SCR_ONE)
#define DRIVE_STUCK_MOVE (int32_t)(0.5 * SCR_ONE)    /* drive_to: moved, so not stuck */
#define DRIVE_STUCK_FRAMES 900                    /* drive_to: 30 s still = stuck (lights, jams) */
#define ENTER_WALK    900               /* frames to reach a door after the order */

enum { K_NONE, K_DRIVE, K_WALK, K_GOTO, K_FACE, K_ENTER, K_EXIT, K_KEY, K_WAIT, K_WAIT_FRAMES };
enum { PH_APPROACH, PH_ORDER, PH_WAIT };
enum { OP_EQ, OP_NE, OP_LT, OP_LE, OP_GT, OP_GE };

typedef struct {
    int fd;
    char in[LINE_MAX_ * 2];
    size_t inlen;
    int kind;                           /* the running command, K_NONE = idle */
    uint32_t start, deadline;           /* frames */
    /* goto / enter_car */
    int32_t best;
    uint32_t progress_frame;
    int32_t moved_x, moved_y;        /* drive_to: where the car was at progress_frame */
    int phase, tries, by_key, passenger, straight;
    gptr car;
    uint32_t car_id, order_frame;
    /* key */
    int scancode;
    uint32_t up_frame;
    /* wait */
    int field, op;
    double value;
} client_t;

static int ctl_enabled;
static char ctl_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static int listen_fd = -1;
static client_t clients[MAX_CLIENTS];
static int steer_owner = -1;            /* client index that owns ctl_steer */
static FILE *telem;
static uint32_t telem_every = 1;

/* ---- arguments and setup --------------------------------------------------------- */

static int abs_path(const char *in, char *out, size_t size)
{
    char cwd[1024];
    if (in[0] == '/' || !getcwd(cwd, sizeof cwd))
        return snprintf(out, size, "%s", in) < (int)size;
    return snprintf(out, size, "%s/%s", cwd, in) < (int)size;
}

/* eax = ctl_arg(rdi = argv[i]): 1 = one of ours (loader.asm's argument loop) */
int ctl_arg(const char *a)
{
    if (!strcmp(a, "--ctl")) {
        ctl_enabled = 1;
        return 1;
    }
    if (!strncmp(a, "--ctl=", 6)) {
        ctl_enabled = 1;
        if (!abs_path(a + 6, ctl_path, sizeof ctl_path)) {
            fprintf(stderr, "ctl: --ctl=PATH: path too long (max %zu)\n", sizeof ctl_path - 1);
            exit(1);
        }
        return 1;
    }
    if (!strncmp(a, "--telemetry=", 12)) {
        char path[1024];
        snprintf(path, sizeof path, "%s", a + 12);
        char *opt = strchr(path, ',');
        if (opt) {
            *opt++ = 0;
            if (strncmp(opt, "every=", 6) || (telem_every = (uint32_t)atoi(opt + 6)) == 0) {
                fprintf(stderr, "ctl: --telemetry=PATH[,every=N]: bad option '%s'\n", opt);
                exit(1);
            }
        }
        telem = fopen(path, "w");       /* now: the loader chdirs into the overlay later */
        if (!telem) {
            fprintf(stderr, "ctl: --telemetry: cannot write %s: %s\n", path, strerror(errno));
            exit(1);
        }
        printf("ctl: telemetry -> %s every %u frames\n", path, telem_every);
        return 1;
    }
    return 0;
}

void ctl_exit(void)
{
    if (listen_fd >= 0) {
        close(listen_fd);
        listen_fd = -1;
        unlink(ctl_path);
    }
    if (telem)
        fflush(telem);
}

/* ctl_init (_main, after the shims are set up): open the socket */
void ctl_init(void)
{
    for (int i = 0; i < MAX_CLIENTS; i++)
        clients[i].fd = -1;
    if (!ctl_enabled)
        return;
    if (!ctl_path[0]) {
        const char *tmp = getenv("TMPDIR");
        if (!tmp || !*tmp)
            tmp = "/tmp";
        size_t n = strlen(tmp);
        int len = snprintf(ctl_path, sizeof ctl_path, "%s%sgta2ctl-%d.sock", tmp,
                           tmp[n - 1] == '/' ? "" : "/", (int)getpid());
        if (len >= (int)sizeof ctl_path)
            snprintf(ctl_path, sizeof ctl_path, "/tmp/gta2ctl-%d.sock", (int)getpid());
    }
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", ctl_path);
    listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(ctl_path);
    if (listen_fd < 0 || bind(listen_fd, (struct sockaddr *)&sa, sizeof sa) < 0 ||
        listen(listen_fd, MAX_CLIENTS) < 0) {
        fprintf(stderr, "ctl: cannot listen on %s: %s\n", ctl_path, strerror(errno));
        exit(1);
    }
    fcntl(listen_fd, F_SETFL, O_NONBLOCK);
    atexit(ctl_exit);
    printf("ctl: listening on %s\n", ctl_path);
}

/* ---- replies ----------------------------------------------------------------------- */

static void send_line(client_t *c, jbuf *b)
{
    jb_printf(b, "\n");
    size_t off = 0;
    int spins = 0;
    while (off < b->len && c->fd >= 0) {
        ssize_t n = send(c->fd, b->buf + off, b->len - off, 0);
        if (n > 0) {
            off += (size_t)n;
        } else if (n < 0 && errno == EAGAIN && ++spins < 1000) {
            usleep(100);
        } else {
            break;                      /* the client went away; read() will notice */
        }
    }
}

static void begin_ok(jbuf *b)
{
    b->len = 0;
    jb_printf(b, "{\"ok\":true,\"frame\":%u", r_frames);
}

static void done(client_t *c, jbuf *b)
{
    jb_printf(b, "}");
    send_line(c, b);
    if (steer_owner == c - clients) {
        ctl_steer.mode = STEER_NONE;
        steer_owner = -1;
    }
    c->kind = K_NONE;
}

static void reply_error(client_t *c, const char *why)
{
    jbuf b = { .len = 0 };
    jb_printf(&b, "{\"ok\":false,\"frame\":%u,\"error\":", r_frames);
    jb_str(&b, why);
    done(c, &b);
}

/* a blocking command that did not get there: ok false, with the reason as "result" */
static void reply_result(client_t *c, int ok, const char *result, const char *extra)
{
    jbuf b = { .len = 0 };
    jb_printf(&b, "{\"ok\":%s,\"frame\":%u,\"result\":\"%s\",\"frames\":%u%s",
              ok ? "true" : "false", r_frames, result, r_frames - c->start, extra ? extra : "");
    int32_t x, y, z;
    if (ctl_pos(&x, &y, &z))
        jb_printf(&b, ",\"x\":%.3f,\"y\":%.3f,\"z\":%.3f", scr_to_f(x), scr_to_f(y), scr_to_f(z));
    done(c, &b);
}

/* ---- argument helpers ------------------------------------------------------------- */

static int num(const char *s, double *v)
{
    char *end;
    if (!s)
        return 0;
    if (!strcasecmp(s, "true"))
        return *v = 1, 1;
    if (!strcasecmp(s, "false"))
        return *v = 0, 1;
    *v = strtod(s, &end);
    return end != s && *end == 0;
}

static int inum(const char *s, int *v)
{
    double d;
    if (!num(s, &d) || d != floor(d))
        return 0;
    *v = (int)d;
    return 1;
}

static const struct key_entry *key_by_name(const char *name)
{
    for (const struct key_entry *k = key_table; k->scancode != 0xFFFF; k++)
        if (!strcasecmp(k->name, name))
            return k;
    return 0;
}

/* --name=value among argv[from..], or 0 */
static const char *opt(int argc, char **argv, const char *name)
{
    size_t n = strlen(name);
    for (int i = 1; i < argc; i++)
        if (!strncmp(argv[i], name, n) && argv[i][n] == '=')
            return argv[i] + n + 1;
    return 0;
}

static int flag(int argc, char **argv, const char *name)
{
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], name))
            return 1;
    return 0;
}

/* positional arguments without the --options */
static int positional(int argc, char **argv, char **out)
{
    int n = 0;
    for (int i = 0; i < argc; i++)
        if (strncmp(argv[i], "--", 2))
            out[n++] = argv[i];
    return n;
}

static void take_steer(client_t *c, int mode)
{
    int me = (int)(c - clients);
    if (steer_owner >= 0 && steer_owner != me && clients[steer_owner].kind != K_NONE) {
        client_t *old = &clients[steer_owner];
        steer_owner = -1;
        reply_result(old, 0, "preempted", 0);
    }
    steer_owner = me;
    memset(&ctl_steer, 0, sizeof ctl_steer);
    ctl_steer.mode = mode;
}

static int timeout_arg(const char *s, int def)
{
    int v;
    return s && inum(s, &v) && v > 0 ? v : def;
}

/* ---- commands -------------------------------------------------------------------- */

static const char help_text[] =
    "ping | state | teleport X Y [Z] | face DEG | goto X Y [TIMEOUT] [--straight [--radius=R]] | "
    "walk_to X Y (= goto) | drive_to X Y [TIMEOUT] [--debug] | "
    "enter_car nearest|ID [TIMEOUT] [--straight] [--key] [--passenger] | exit_car [TIMEOUT] [--key] | "
    "key NAME [FRAMES] | keydown NAME | keyup NAME | mouse DX [DY] | "
    "spawn car MODEL [REMAP] | spawn ped REMAP [ROLE] [--behave=normal|hostile|follow] | "
    "spawn object TYPE [REMAP] (spawn: [--at=X,Y[,Z]] [--rot=DEG]) | "
    "wait FIELD OP VALUE [TIMEOUT] | wait frames N | shot PATH | log TEXT | sms TEXT | sms_echo on|off | quit | help";

static const char *role_names[] = {
    "auto", "civilian", "gang", "cop", "swat", "fbi", "army", "medic", "fireman",
    "elvis", "mugger", "thief", "psycho", "criminal", "still",
};

static void cmd_state(client_t *c)
{
    jbuf b;
    ctl_state s;
    ctl_snapshot(&s);
    b.len = 0;
    jb_printf(&b, "{\"ok\":true,");
    ctl_fields_json(&b, &s);
    if (s.v[F_IN_GAME] != 0)
        ctl_lists_json(&b);
    done(c, &b);
}

static void cmd_spawn(client_t *c, int argc, char **argv)
{
    char *pos[MAX_ARGS];
    int np = positional(argc, argv, pos), id = 0, remap, role = 0, behave = 0;
    const char *kind = np > 1 ? pos[1] : "";
    if (np < 3 || !inum(pos[2], &id))
        return reply_error(c, "usage: spawn car MODEL [REMAP] | ped REMAP [ROLE] | object TYPE [REMAP]");
    int32_t at[4];
    const char *at_s = opt(argc, argv, "--at"), *rot_s = opt(argc, argv, "--rot");
    int is_car = !strcmp(kind, "car"), is_ped = !strcmp(kind, "ped");
    if (!is_car && !is_ped && strcmp(kind, "object"))
        return reply_error(c, "spawn: car, ped or object");
    if (!ctl_ped())
        return reply_error(c, "not in a game");
    if (at_s) {
        double x, y, z;
        int n = sscanf(at_s, "%lf,%lf,%lf", &x, &y, &z);
        int32_t px, py, pz;
        if (n < 2)
            return reply_error(c, "--at=X,Y[,Z]");
        ctl_pos(&px, &py, &pz);
        at[0] = f_to_scr(x), at[1] = f_to_scr(y), at[2] = n > 2 ? f_to_scr(z) : pz;
        at[3] = 0;
    } else if (!km_spawn_pos(at, is_ped ? 0x4000 : 0x6000)) {
        return reply_error(c, km_spawn_why);
    }
    if (rot_s) {
        double d;
        if (!num(rot_s, &d))
            return reply_error(c, "--rot=DEG");
        at[3] = ((int)lrint(d * 4) % 1440 + 1440) % 1440;
    }
    gptr va;
    int obj_id = -1;
    if (is_car) {
        remap = -1;
        if (np > 3 && !inum(pos[3], &remap))
            return reply_error(c, "spawn car MODEL [REMAP]: REMAP -1 random, 0 none, i the model's i-th");
        va = km_spawn_car(id, remap, at[0], at[1], at[2], at[3]);
        if (va)
            obj_id = (int)GP(Car, va)->id;
    } else if (is_ped) {
        if (np > 3 && !inum(pos[3], &role)) {
            for (role = 0; role < (int)(sizeof role_names / sizeof *role_names); role++)
                if (!strcasecmp(pos[3], role_names[role]))
                    break;
            if (role == (int)(sizeof role_names / sizeof *role_names))
                return reply_error(c, "spawn ped: unknown role (auto civilian gang cop swat fbi "
                                      "army medic fireman elvis mugger thief psycho criminal still)");
        }
        const char *b = opt(argc, argv, "--behave");
        if (b)
            behave = !strcmp(b, "hostile") ? 1 : !strcmp(b, "follow") ? 2 : 0;
        va = km_spawn_ped(id, role, behave, at[0], at[1], at[2], at[3]);
        if (va)
            obj_id = GP(Ped, va)->id;
    } else {
        remap = -1;
        if (np > 3 && !inum(pos[3], &remap))
            return reply_error(c, "spawn object TYPE [REMAP]");
        va = km_spawn_object(id, remap, at[0], at[1], at[2], at[3]);
    }
    if (!va)
        return reply_error(c, km_spawn_why);
    printf("ctl: spawn %s %d -> 0x%x id %d at %.2f %.2f %.2f: %s\n", kind, id, va, obj_id,
           scr_to_f(at[0]), scr_to_f(at[1]), scr_to_f(at[2]), km_spawn_why);
    jbuf b;
    begin_ok(&b);
    jb_printf(&b, ",\"kind\":\"%s\",\"id\":%d,\"va\":%u,\"x\":%.3f,\"y\":%.3f,\"z\":%.3f,"
              "\"heading\":%.2f,\"message\":", kind, obj_id, va, scr_to_f(at[0]),
              scr_to_f(at[1]), scr_to_f(at[2]), at[3] / 4.0);
    jb_str(&b, km_spawn_why);
    done(c, &b);
}

static int sms_echo;                     /* sms_echo on: each command as a brief */

static void start_command(client_t *c, char *line)
{
    char *argv[MAX_ARGS], *rest = 0, *save;
    int argc = 0;
    jbuf b;
    char text[sizeof clients[0].in], whole[sizeof clients[0].in];
    while (*line == ' ' || *line == '\t')
        line++;
    snprintf(whole, sizeof whole, "%s", line);
    rest = line + strcspn(line, " \t");    /* the rest of the line, for `log`, untokenised */
    snprintf(text, sizeof text, "%s", rest);
    rest = text;
    for (char *t = strtok_r(line, " \t", &save); t && argc < MAX_ARGS; t = strtok_r(0, " \t", &save))
        argv[argc++] = t;
    if (!argc)
        return;
    const char *cmd = argv[0];
    c->start = r_frames;
    c->kind = K_NONE;
    Ped *ped = ctl_ped();
    /* sms_echo: every script step shows up in the game as a brief (polls excepted) */
    if (sms_echo && ped && strcmp(cmd, "state") && strcmp(cmd, "ping") && strcmp(cmd, "sms") &&
        strcmp(cmd, "sms_echo"))
        ctl_sms(whole);

    if (!strcmp(cmd, "ping")) {
        begin_ok(&b);
        done(c, &b);
    } else if (!strcmp(cmd, "help")) {
        begin_ok(&b);
        jb_printf(&b, ",\"commands\":");
        jb_str(&b, help_text);
        done(c, &b);
    } else if (!strcmp(cmd, "state")) {
        cmd_state(c);
    } else if (!strcmp(cmd, "teleport")) {
        double x, y, z = 0;
        const char *why;
        if (argc < 3 || !num(argv[1], &x) || !num(argv[2], &y) || (argc > 3 && !num(argv[3], &z)))
            return reply_error(c, "usage: teleport X Y [Z] (blocks)");
        if (!ctl_teleport(f_to_scr(x), f_to_scr(y), f_to_scr(z), argc > 3, &why))
            return reply_error(c, why);
        printf("ctl: teleport %.3f %.3f%s\n", x, y, argc > 3 ? " (with z)" : "");
        begin_ok(&b);
        jb_printf(&b, ",\"x\":%.3f,\"y\":%.3f", x, y);
        done(c, &b);
    } else if (!strcmp(cmd, "face")) {
        double d;
        if (argc < 2 || !num(argv[1], &d))
            return reply_error(c, "usage: face DEG (0 = +y, 90 = +x)");
        if (!ped || ped->currentCar)
            return reply_error(c, ped ? "face: on foot only" : "not in a game");
        take_steer(c, STEER_FACE);
        ctl_steer.heading = ((int)lrint(d * 4) % 1440 + 1440) % 1440;
        c->kind = K_FACE;
        c->deadline = r_frames + 60;
    } else if (!strcmp(cmd, "walk_to") ||
               (!strcmp(cmd, "goto") && !flag(argc, argv, "--straight"))) {
        /* goto / walk_to: the game's own routing (GO_TO_AREA_ON_FOOT) */
        char *pos[MAX_ARGS];
        int np = positional(argc, argv, pos);
        double x, y;
        int32_t px, py, pz;
        const char *why;
        if (np < 3 || !num(pos[1], &x) || !num(pos[2], &y))
            return reply_error(c, "usage: goto X Y [TIMEOUT_FRAMES] [--straight [--radius=R]]");
        if (!ctl_pos(&px, &py, &pz) || !ctl_order_walk(f_to_scr(x), f_to_scr(y), pz, &why))
            return reply_error(c, ped ? why : "not in a game");
        take_steer(c, STEER_NONE);
        ctl_steer.tx = f_to_scr(x);
        ctl_steer.ty = f_to_scr(y);
        c->kind = K_WALK;
        c->deadline = r_frames + (uint32_t)timeout_arg(np > 3 ? pos[3] : 0, 3000);
        c->best = INT32_MAX;
        c->progress_frame = r_frames;
        printf("ctl: walk_to %.2f %.2f (GO_TO_AREA_ON_FOOT)\n", x, y);
    } else if (!strcmp(cmd, "drive_to")) {        /* experimental: the car AI drives */
        char *pos[MAX_ARGS];
        int np = positional(argc, argv, pos);
        double x, y;
        int32_t px, py, pz;
        const char *why;
        if (np < 3 || !num(pos[1], &x) || !num(pos[2], &y))
            return reply_error(c, "usage: drive_to X Y [TIMEOUT_FRAMES] [--debug]");
        if (!ctl_pos(&px, &py, &pz) || !ctl_order_drive(f_to_scr(x), f_to_scr(y), pz, &why))
            return reply_error(c, ped ? why : "not in a game");
        take_steer(c, STEER_NONE);
        ctl_steer.tx = f_to_scr(x);
        ctl_steer.ty = f_to_scr(y);
        c->kind = K_DRIVE;
        c->straight = flag(argc, argv, "--debug");
        c->deadline = r_frames + (uint32_t)timeout_arg(np > 3 ? pos[3] : 0, 5400);
        c->best = INT32_MAX;
        c->progress_frame = r_frames;
        printf("ctl: drive_to %.2f %.2f (GO_TO_AREA_IN_CAR)\n", x, y);
    } else if (!strcmp(cmd, "goto")) {
        char *pos[MAX_ARGS];
        int np = positional(argc, argv, pos);
        double x, y, r = scr_to_f(GOTO_RADIUS);
        const char *rs = opt(argc, argv, "--radius");
        if (np < 3 || !num(pos[1], &x) || !num(pos[2], &y) || (rs && !num(rs, &r)))
            return reply_error(c, "usage: goto X Y [TIMEOUT_FRAMES] [--radius=R] [--run]");
        if (!ped || ped->currentCar)
            return reply_error(c, ped ? "goto: on foot only (drive_to is phase 2)" : "not in a game");
        take_steer(c, STEER_GOTO);
        ctl_steer.tx = f_to_scr(x);
        ctl_steer.ty = f_to_scr(y);
        ctl_steer.radius = f_to_scr(r);
        c->kind = K_GOTO;
        c->deadline = r_frames + (uint32_t)timeout_arg(np > 3 ? pos[3] : 0, 1800);
        c->best = INT32_MAX;
        c->progress_frame = r_frames;
    } else if (!strcmp(cmd, "enter_car")) {
        char *pos[MAX_ARGS];
        int np = positional(argc, argv, pos), id;
        if (!ped)
            return reply_error(c, "not in a game");
        if (ped->currentCar)
            return reply_error(c, "already in a car");
        if (np < 2 || !strcmp(pos[1], "nearest"))
            c->car = ctl_nearest_car();
        else if (inum(pos[1], &id))
            c->car = ctl_car_by_id((uint32_t)id);
        else
            return reply_error(c, "usage: enter_car nearest|CAR_ID [TIMEOUT_FRAMES] [--key] [--passenger]");
        if (!c->car)
            return reply_error(c, "no such car");
        c->car_id = GP(Car, c->car)->id;
        c->by_key = flag(argc, argv, "--key");
        c->passenger = flag(argc, argv, "--passenger");
        c->tries = 0;
        c->straight = flag(argc, argv, "--straight") || c->by_key;
        c->phase = PH_APPROACH;         /* default: walk there by the game's routing */
        c->order_frame = 0;
        take_steer(c, c->straight ? STEER_GOTO : STEER_NONE);
        ctl_steer.radius = ENTER_RANGE;
        c->kind = K_ENTER;
        c->deadline = r_frames + (uint32_t)timeout_arg(np > 2 ? pos[2] : 0, 1800);
        c->best = INT32_MAX;
        c->progress_frame = r_frames;
    } else if (!strcmp(cmd, "exit_car")) {
        char *pos[MAX_ARGS];
        int np = positional(argc, argv, pos);
        if (!ped || !ped->currentCar)
            return reply_error(c, ped ? "not in a car" : "not in a game");
        c->car = ped->currentCar;
        c->by_key = flag(argc, argv, "--key");
        c->tries = 0;
        c->phase = PH_ORDER;
        c->kind = K_EXIT;
        c->deadline = r_frames + (uint32_t)timeout_arg(np > 1 ? pos[1] : 0, 600);
    } else if (!strcmp(cmd, "key") || !strcmp(cmd, "keydown") || !strcmp(cmd, "keyup")) {
        const struct key_entry *k = argc > 1 ? key_by_name(argv[1]) : 0;
        int frames = KEY_HOLD;
        if (!k)
            return reply_error(c, "usage: key NAME [FRAMES] (names as in --keys: RETURN, UP, A, ...)");
        if (argc > 2 && (!inum(argv[2], &frames) || frames < 1))
            return reply_error(c, "key: FRAMES >= 1");
        input_push_key(k->scancode, strcmp(cmd, "keyup") != 0);
        if (strcmp(cmd, "key")) {
            begin_ok(&b);
            done(c, &b);
            return;
        }
        c->scancode = k->scancode;
        c->up_frame = r_frames + (uint32_t)frames;
        c->kind = K_KEY;
    } else if (!strcmp(cmd, "mouse")) {
        /* relative motion in pixels, added where SDL mouse motion lands (the DirectInput
         * mouse and mouse turning read it); the real cursor is not touched */
        double dx, dy = 0;
        if (argc < 2 || !num(argv[1], &dx) || (argc > 2 && !num(argv[2], &dy)))
            return reply_error(c, "usage: mouse DX [DY] (pixels)");
        input_mouse_motion((float)dx, (float)dy);
        begin_ok(&b);
        done(c, &b);
    } else if (!strcmp(cmd, "wait")) {
        static const char *ops[] = { "==", "!=", "<", "<=", ">", ">=" };
        int n;
        if (argc >= 3 && !strcmp(argv[1], "frames") && inum(argv[2], &n) && n >= 0) {
            c->kind = K_WAIT_FRAMES;
            c->deadline = r_frames + (uint32_t)n;
            return;
        }
        if (argc < 4 || (c->field = ctl_field_index(argv[1])) < 0 || !num(argv[3], &c->value))
            return reply_error(c, "usage: wait FIELD OP VALUE [TIMEOUT_FRAMES] | wait frames N "
                                  "(FIELD: a state field, OP: == != < <= > >=)");
        static const char *words[] = { "eq", "ne", "lt", "le", "gt", "ge" };   /* zsh-safe */
        for (c->op = 0; c->op < 6 && strcmp(argv[2], ops[c->op]) && strcmp(argv[2], words[c->op]);
             c->op++)
            ;
        if (c->op == 6)
            return reply_error(c, "wait: OP is one of == != < <= > >= (or eq ne lt le gt ge)");
        c->kind = K_WAIT;
        c->deadline = r_frames + (uint32_t)timeout_arg(argc > 4 ? argv[4] : 0, 1800);
    } else if (!strcmp(cmd, "spawn")) {
        cmd_spawn(c, argc, argv);
    } else if (!strcmp(cmd, "shot")) {
        struct stat st;
        if (argc < 2)
            return reply_error(c, "usage: shot PATH.bmp (absolute; gta2ctl makes it so)");
        char *old = r_shot_path;
        r_shot_path = argv[1];
        unlink(argv[1]);
        r_save_shot();
        r_shot_path = old;
        if (stat(argv[1], &st) < 0)
            return reply_error(c, "shot: nothing written");
        printf("ctl: shot %s\n", argv[1]);
        begin_ok(&b);
        jb_printf(&b, ",\"path\":");
        jb_str(&b, argv[1]);
        done(c, &b);
    } else if (!strcmp(cmd, "sms")) {
        while (rest && (*rest == ' ' || *rest == '\t'))
            rest++;
        if (!rest || !*rest)
            return reply_error(c, "usage: sms TEXT");
        if (!ped || !ctl_sms(rest))
            return reply_error(c, "sms: no HUD (not in a game)");
        begin_ok(&b);
        done(c, &b);
    } else if (!strcmp(cmd, "sms_echo")) {
        if (argc < 2 || (strcmp(argv[1], "on") && strcmp(argv[1], "off")))
            return reply_error(c, "usage: sms_echo on|off");
        sms_echo = !strcmp(argv[1], "on");
        begin_ok(&b);
        jb_printf(&b, ",\"sms_echo\":%s", sms_echo ? "true" : "false");
        done(c, &b);
    } else if (!strcmp(cmd, "log")) {
        while (rest && (*rest == ' ' || *rest == '\t'))
            rest++;
        printf("ctl: log [frame %u] %s\n", r_frames, rest ? rest : "");
        begin_ok(&b);
        done(c, &b);
    } else if (!strcmp(cmd, "quit")) {
        begin_ok(&b);
        jb_printf(&b, ",\"quit\":true");
        done(c, &b);
        printf("ctl: quit at frame %u\n", r_frames);
        ctl_exit();
        _exit(0);
    } else {
        reply_error(c, "unknown command (try: help)");
    }
}

/* ---- blocking commands, one step per frame ------------------------------------------ */

static int cmp(double a, int op, double b)
{
    switch (op) {
    case OP_EQ: return fabs(a - b) < 1e-9;
    case OP_NE: return fabs(a - b) >= 1e-9;
    case OP_LT: return a < b;
    case OP_LE: return a <= b;
    case OP_GT: return a > b;
    default:    return a >= b;
    }
}

static void ctl_drive_stop(void)
{
    ctl_clear_objective();
    ctl_autopilot_off();
}

/* progress toward ctl_steer's target: 1 = stuck (no gain for STUCK_FRAMES unpaused frames) */
static int stuck(client_t *c)
{
    int32_t x, y, z;
    Game *g = game();
    if (!ctl_pos(&x, &y, &z))
        return 0;
    if (g && g->gameStatus == 2) {      /* paused: the player cannot move, not stuck */
        c->progress_frame = r_frames;
        return 0;
    }
    int32_t d = ctl_dist(x, y, ctl_steer.tx, ctl_steer.ty);
    if (d < c->best - STUCK_GAIN || c->best == INT32_MAX) {
        c->best = d;
        c->progress_frame = r_frames;
    }
    return r_frames - c->progress_frame > STUCK_FRAMES;
}

static void step_enter(client_t *c)
{
    Ped *ped = ctl_ped();
    Car *car = GP(Car, c->car);
    char extra[96];
    if (!ped)
        return reply_error(c, "player gone");
    if (ped->currentCar && ped->state == 10) {      /* PED_STATE_DRIVING_A_CAR: seated */
        Car *in = GP(Car, ped->currentCar);
        snprintf(extra, sizeof extra, ",\"car_id\":%u,\"car_model\":%u,\"target_car\":%s",
                 in->id, in->carModel, ped->currentCar == c->car ? "true" : "false");
        return reply_result(c, 1, in->driver == (gptr)(uintptr_t)ped ? "driver" : "passenger",
                            extra);
    }
    if (car->id != c->car_id || !car->body)
        return reply_result(c, 0, "car gone", 0);
    if ((int32_t)(r_frames - c->deadline) >= 0) {
        if (c->phase == PH_WAIT && ped->state != 3)
            ctl_cancel_objective();
        return reply_result(c, 0, "timeout", 0);
    }
    Sprite *s = GP(Sprite, car->body);
    switch (c->phase) {
    case PH_APPROACH:
        if (steer_owner != c - clients)
            return reply_result(c, 0, "preempted", 0);
        ctl_steer.tx = s->x;                         /* a driven car moves */
        ctl_steer.ty = s->y;
        if (!ctl_steer.done) {
            int32_t x, y, z;
            ctl_pos(&x, &y, &z);
            if (ctl_dist(x, y, s->x, s->y) > ENTER_RANGE) {
                if (!c->straight && (!c->order_frame || r_frames - c->order_frame >= 30)) {
                    const char *why;                 /* GO_TO_AREA_ON_FOOT, re-aimed at the car */
                    if (!ctl_order_walk(s->x, s->y, z, &why))
                        return reply_error(c, why);
                    c->order_frame = r_frames;
                }
                if (stuck(c)) {
                    if (!c->straight)
                        ctl_clear_objective();
                    return reply_result(c, 0, "stuck", 0);
                }
                return;
            }
        }
        if (!c->straight)
            ctl_clear_objective();
        ctl_steer.mode = STEER_NONE;                 /* a move would cancel the enter */
        c->phase = PH_ORDER;
        /* fall through */
    case PH_ORDER: {
        const char *why = "";
        if (c->by_key) {
            /* --passenger: Shift+Enter, the passenger mod's key (c32/passenger.c); LSHIFT
             * goes down first and up with RETURN */
            if (c->passenger)
                input_push_key(key_by_name("LSHIFT")->scancode, 1);
            input_push_key(key_by_name("RETURN")->scancode, 1);
            c->scancode = key_by_name("RETURN")->scancode;
            c->up_frame = r_frames + KEY_HOLD;
        } else if (!ctl_order_enter(c->car, c->passenger, &why)) {
            return reply_error(c, why);
        }
        printf("ctl: enter_car %u: %s%s (try %d)\n", c->car_id,
               c->by_key ? (c->passenger ? "LSHIFT+" : "") : "",
               c->by_key ? "RETURN" : c->passenger ? "ENTER_CAR objective, passenger" : "ENTER_CAR objective",
               c->tries + 1);
        c->order_frame = r_frames;
        c->phase = PH_WAIT;
        return;
    }
    default:
        if (c->by_key && c->up_frame && r_frames >= c->up_frame) {
            input_push_key(c->scancode, 0);
            if (c->passenger)
                input_push_key(key_by_name("LSHIFT")->scancode, 0);
            c->up_frame = 0;
        }
        /* entering: objective ENTER_CAR (35) or state ENTERING_CAR (3); else it was lost.
         * Still walking after ENTER_WALK frames: no door it can reach, give up this try. */
        if (ped->currentCar || ped->state == 3 || r_frames - c->order_frame < 30 ||
            (ped->objective == 35 && r_frames - c->order_frame < ENTER_WALK))
            return;
        ctl_cancel_objective();
        if (++c->tries >= ENTER_TRIES)
            return reply_result(c, 0, ped->objective == 35 ? "no reachable door" : "enter failed", 0);
        c->phase = PH_APPROACH;
        c->order_frame = 0;
        take_steer(c, c->straight ? STEER_GOTO : STEER_NONE);
        ctl_steer.radius = ENTER_RANGE;
        c->best = INT32_MAX;
        c->progress_frame = r_frames;
    }
}

static void step_exit(client_t *c)
{
    Ped *ped = ctl_ped();
    if (!ped)
        return reply_error(c, "player gone");
    if (!ped->currentCar && (ped->state == 0 || ped->state == 7))   /* WALK / STAYING */
        return reply_result(c, 1, "on foot", 0);
    if ((int32_t)(r_frames - c->deadline) >= 0)
        return reply_result(c, 0, "timeout", 0);
    if (c->phase == PH_ORDER) {
        const char *why;
        if (c->by_key) {
            c->scancode = key_by_name("RETURN")->scancode;
            input_push_key(c->scancode, 1);
            c->up_frame = r_frames + KEY_HOLD;
        } else if (!ctl_order_exit(&why)) {
            if (!ped->currentCar)
                return;                 /* already getting out */
            return reply_error(c, why);
        }
        c->order_frame = r_frames;
        c->phase = PH_WAIT;
        return;
    }
    if (c->by_key && c->up_frame && r_frames >= c->up_frame) {
        input_push_key(c->scancode, 0);
        c->up_frame = 0;
    }
    if (r_frames - c->order_frame > 60 && ped->currentCar && ped->objective != 36 &&
        ped->state != 4 && ++c->tries < ENTER_TRIES)
        c->phase = PH_ORDER;            /* LEAVE_CAR objective lost: again */
}

static void step(client_t *c)
{
    ctl_state s;
    jbuf b;
    char extra[400];
    switch (c->kind) {
    case K_DRIVE: {
        Ped *ped = ctl_ped();
        int32_t x, y, z;
        if (!ped)
            return reply_error(c, "player gone");
        ctl_pos(&x, &y, &z);
        Car *dc = GP(Car, ped->currentCar);
        ctl_drive_assist();
        if (c->straight && r_frames % 15 == 0)  /* drive_to --debug */
            ctl_drive_debug();
        snprintf(extra, sizeof extra, ",\"objective\":%u,\"status\":%u,\"ai\":%u,\"order\":%u"
                 ",\"carspeed\":%d,\"slot\":%d,\"tspeed\":%d,\"aiflags\":%u,\"engine\":%u,\"aban\":%u,\"aiticks\":%u,\"pmode\":%u,\"gas\":%u,\"brake\":%u,\"steer\":%d,\"aif\":%u",
                 ped->objective, ped->objectiveStatus, dc ? dc->ai : 0, dc ? dc->driveOrder : 0,
                 ped->carSpeed, dc && dc->ai ? (int)rd32(dc->ai + 0x28) : -9,
                 dc && dc->ai ? (int)rd32(dc->ai + 0x74) : -9, dc ? dc->aiFlags : 0,
                 dc ? dc->engineState : 0, dc ? dc->isAbandoned : 0, ctl_autopilot_ticks,
                 dc && dc->physics ? (unsigned)GP(CarPhysics, dc->physics)->mode : 0,
                 dc && dc->physics ? GP(CarPhysics, dc->physics)->isForwardGasOn : 0,
                 dc && dc->physics ? GP(CarPhysics, dc->physics)->isBrakeOn : 0,
                 dc && dc->physics ? GP(CarPhysics, dc->physics)->steering : 0,
                 dc && dc->ai ? rd32(dc->ai + 0x24) : 0);
        if (ctl_dist(x, y, ctl_steer.tx, ctl_steer.ty) < DRIVE_RADIUS)
            return ctl_drive_stop(), reply_result(c, 1, "arrived", extra);
        if (ped->objective == 14 && ped->objectiveStatus == 1)
            return ctl_drive_stop(), reply_result(c, 1, "arrived", extra);
        if (!ped->currentCar)
            return ctl_drive_stop(), reply_result(c, 0, "out of the car", extra);
        if (ped->objective != 14 || ped->objectiveStatus == 2)
            return ctl_drive_stop(), reply_result(c, 0, "objective lost", extra);
        if ((int32_t)(r_frames - c->deadline) >= 0)
            return ctl_drive_stop(), reply_result(c, 0, "timeout", extra);
        /* a route may lead away from the target (one-way streets, blocks around): stuck means
         * the car has not moved half a block in 10 s, lights and traffic included */
        if (c->best == INT32_MAX || ctl_dist(x, y, c->moved_x, c->moved_y) > DRIVE_STUCK_MOVE) {
            c->best = 0;
            c->moved_x = x;
            c->moved_y = y;
            c->progress_frame = r_frames;
        } else if (r_frames - c->progress_frame > DRIVE_STUCK_FRAMES)
            return ctl_drive_stop(), reply_result(c, 0, "stuck", extra);
        return;
    }
    case K_WALK: {
        Ped *ped = ctl_ped();
        int32_t x, y, z;
        if (!ped)
            return reply_error(c, "player gone");
        ctl_pos(&x, &y, &z);
        snprintf(extra, sizeof extra, ",\"objective\":%u,\"status\":%u", ped->objective,
                 ped->objectiveStatus);
        if (ped->objective == 12 && ped->objectiveStatus == 1)
            return ctl_clear_objective(), reply_result(c, 1, "arrived", extra);
        if (ctl_dist(x, y, ctl_steer.tx, ctl_steer.ty) < (int32_t)(0.5 * SCR_ONE))
            return ctl_clear_objective(), reply_result(c, 1, "arrived", extra);
        if (ped->objective != 12 || ped->objectiveStatus == 2)
            return ctl_clear_objective(), reply_result(c, 0, "objective lost", extra);
        if ((int32_t)(r_frames - c->deadline) >= 0)
            return ctl_clear_objective(), reply_result(c, 0, "timeout", extra);
        if (stuck(c))
            return ctl_clear_objective(), reply_result(c, 0, "stuck", extra);
        return;
    }
    case K_GOTO:
        if (steer_owner != c - clients)
            return reply_result(c, 0, "preempted", 0);
        if (ctl_steer.done)
            return reply_result(c, 1, "arrived", 0);
        if (!ctl_ped() || ctl_ped()->currentCar)
            return reply_result(c, 0, ctl_ped() ? "in a car" : "player gone", 0);
        if ((int32_t)(r_frames - c->deadline) >= 0)
            return reply_result(c, 0, "timeout", 0);
        if (stuck(c))
            return reply_result(c, 0, "stuck", 0);
        return;
    case K_FACE:
        if (ctl_steer.done) {
            snprintf(extra, sizeof extra, ",\"heading\":%.2f", ctl_steer.heading / 4.0);
            return reply_result(c, 1, "facing", extra);
        }
        if ((int32_t)(r_frames - c->deadline) >= 0)
            return reply_result(c, 0, "timeout", 0);
        return;
    case K_ENTER:
        return step_enter(c);
    case K_EXIT:
        return step_exit(c);
    case K_KEY:
        if (r_frames < c->up_frame)
            return;
        input_push_key(c->scancode, 0);
        begin_ok(&b);
        return done(c, &b);
    case K_WAIT_FRAMES:
        if ((int32_t)(r_frames - c->deadline) < 0)
            return;
        begin_ok(&b);
        jb_printf(&b, ",\"result\":\"done\"");
        return done(c, &b);
    case K_WAIT: {
        ctl_snapshot(&s);
        int hit = s.valid[c->field] && cmp(s.v[c->field], c->op, c->value);
        int late = (int32_t)(r_frames - c->deadline) >= 0;
        if (!hit && !late)
            return;
        b.len = 0;
        jb_printf(&b, "{\"ok\":%s,\"frame\":%u,\"result\":\"%s\",\"frames\":%u,\"%s\":",
                  hit ? "true" : "false", r_frames, hit ? "met" : "timeout", r_frames - c->start,
                  ctl_fields[c->field].name);
        if (s.valid[c->field])
            jb_printf(&b, "%g", s.v[c->field]);
        else
            jb_printf(&b, "null");
        return done(c, &b);
    }
    }
}

/* ---- the per-frame entry point ------------------------------------------------------- */

static void drop(client_t *c)
{
    if (c->kind == K_ENTER && c->phase == PH_WAIT)
        ctl_cancel_objective();
    if (c->kind == K_WALK)
        ctl_clear_objective();
    if (c->kind == K_DRIVE)
        ctl_drive_stop();
    if (c->kind == K_KEY || (c->up_frame && (c->kind == K_ENTER || c->kind == K_EXIT)))
        input_push_key(c->scancode, 0);
    if (c->up_frame && c->kind == K_ENTER && c->passenger)
        input_push_key(key_by_name("LSHIFT")->scancode, 0);
    if (steer_owner == c - clients) {
        ctl_steer.mode = STEER_NONE;
        steer_owner = -1;
    }
    close(c->fd);
    c->fd = -1;
    c->kind = K_NONE;
    c->inlen = 0;
}

static void telemetry(void)
{
    ctl_state s;
    jbuf b = { .len = 0 };
    if (!telem || r_frames % telem_every)
        return;
    ctl_snapshot(&s);
    jb_printf(&b, "{");
    ctl_fields_json(&b, &s);
    jb_printf(&b, "}\n");
    fwrite(b.buf, 1, b.len, telem);
    fflush(telem);
}

/* ctl_frame (Vid_FlipBuffers, once per presented frame) */
void ctl_frame(void)
{
    telemetry();
    if (listen_fd < 0)
        return;
    for (;;) {
        int fd = accept(listen_fd, 0, 0);
        if (fd < 0)
            break;
        int i, one = 1;
        for (i = 0; i < MAX_CLIENTS && clients[i].fd >= 0; i++)
            ;
        if (i == MAX_CLIENTS) {
            static const char full[] = "{\"ok\":false,\"error\":\"too many clients\"}\n";
            (void)!write(fd, full, sizeof full - 1);
            close(fd);
            continue;
        }
        fcntl(fd, F_SETFL, O_NONBLOCK);
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        memset(&clients[i], 0, sizeof clients[i]);
        clients[i].fd = fd;
    }
    for (int i = 0; i < MAX_CLIENTS; i++) {
        client_t *c = &clients[i];
        if (c->fd < 0)
            continue;
        if (c->kind != K_NONE)
            step(c);
        ssize_t n = read(c->fd, c->in + c->inlen, sizeof c->in - 1 - c->inlen);
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
            drop(c);
            continue;
        }
        if (n > 0)
            c->inlen += (size_t)n;
        while (c->kind == K_NONE && c->fd >= 0) {
            char *nl = memchr(c->in, '\n', c->inlen);
            if (!nl) {
                if (c->inlen >= sizeof c->in - 1) {
                    reply_error(c, "line too long");
                    c->inlen = 0;
                }
                break;
            }
            *nl = 0;
            if (nl > c->in && nl[-1] == '\r')
                nl[-1] = 0;
            char line[sizeof c->in];
            memcpy(line, c->in, (size_t)(nl - c->in) + 1);
            c->inlen -= (size_t)(nl + 1 - c->in);
            memmove(c->in, nl + 1, c->inlen);
            start_command(c, line);
        }
    }
}
