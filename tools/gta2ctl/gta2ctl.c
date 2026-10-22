/* gta2ctl — send one command to a running game started with --ctl and print its JSON reply
 * (docs/gta2ctl.md). Native client, no dependencies; host/build.sh builds it next to this
 * file (tools/gta2ctl/gta2ctl).
 *
 *   gta2ctl [--sock=PATH] [--wait-sock=SEC] [--timeout=SEC] COMMAND [ARGS...]
 *   gta2ctl list                      the game sockets found, live or stale
 *
 * Socket: --sock=PATH, else $GTA2_CTL, else the only live gta2ctl-*.sock in $TMPDIR, the
 * per-user temp dir or /tmp. --wait-sock=SEC keeps looking (a game that is still starting).
 * --timeout=SEC (default 600) bounds the wait for the reply in wall-clock time.
 * Exit: 0 ok, 1 error (also: no game, bad usage), 2 timeout (the game's or --timeout).
 */
#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_FOUND 32

static double now(void)
{
    struct timeval tv;
    gettimeofday(&tv, 0);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static int try_connect(const char *path)
{
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof sa.sun_path)
        return -1;
    strcpy(sa.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* every gta2ctl-*.sock in the temp dirs; live[i] = connectable */
static int scan(char found[][1024], int *live)
{
    char dirs[3][1024];
    int nd = 0, n = 0;
    const char *t = getenv("TMPDIR");
    if (t && *t)
        snprintf(dirs[nd++], sizeof dirs[0], "%s", t);
#ifdef _CS_DARWIN_USER_TEMP_DIR
    if (confstr(_CS_DARWIN_USER_TEMP_DIR, dirs[nd], sizeof dirs[0]) > 0)
        nd++;
#endif
    snprintf(dirs[nd++], sizeof dirs[0], "/tmp");
    for (int d = 0; d < nd; d++) {
        size_t l = strlen(dirs[d]);
        while (l > 1 && dirs[d][l - 1] == '/')
            dirs[d][--l] = 0;
        int dup = 0;
        for (int e = 0; e < d; e++)
            dup |= !strcmp(dirs[e], dirs[d]);
        DIR *dir = dup ? 0 : opendir(dirs[d]);
        struct dirent *de;
        while (dir && (de = readdir(dir)) && n < MAX_FOUND) {
            size_t len = strlen(de->d_name);
            if (strncmp(de->d_name, "gta2ctl-", 8) || len < 13 || strcmp(de->d_name + len - 5, ".sock"))
                continue;
            snprintf(found[n], 1024, "%s/%s", dirs[d], de->d_name);
            int fd = try_connect(found[n]);
            live[n] = fd >= 0;
            if (fd >= 0)
                close(fd);
            n++;
        }
        if (dir)
            closedir(dir);
    }
    return n;
}

static int usage(void)
{
    fprintf(stderr, "usage: gta2ctl [--sock=PATH] [--wait-sock=SEC] [--timeout=SEC] COMMAND [ARGS...]\n"
                    "       gta2ctl list\n"
                    "commands: gta2ctl help (asks the game); docs/gta2ctl.md\n");
    return 1;
}

int main(int argc, char **argv)
{
    const char *sock = getenv("GTA2_CTL");
    double wait_sock = 0, timeout = 600;
    int i = 1;
    for (; i < argc && !strncmp(argv[i], "--", 2); i++) {
        if (!strncmp(argv[i], "--sock=", 7))
            sock = argv[i] + 7;
        else if (!strncmp(argv[i], "--wait-sock=", 12))
            wait_sock = atof(argv[i] + 12);
        else if (!strncmp(argv[i], "--timeout=", 10))
            timeout = atof(argv[i] + 10);
        else
            return usage();
    }
    if (i >= argc)
        return usage();

    static char found[MAX_FOUND][1024];
    int live[MAX_FOUND];
    if (!strcmp(argv[i], "list")) {
        int n = scan(found, live);
        for (int k = 0; k < n; k++)
            printf("%s %s\n", live[k] ? "live " : "stale", found[k]);
        return 0;
    }

    /* the request line; shot's path is made absolute (the game's cwd is its overlay dir) */
    char line[4096] = "", cwd[1024];
    for (int k = i; k < argc; k++) {
        const char *a = argv[k];
        char abs[2048];
        if (k == i + 1 && !strcmp(argv[i], "shot") && a[0] != '/' && getcwd(cwd, sizeof cwd)) {
            snprintf(abs, sizeof abs, "%s/%s", cwd, a);
            a = abs;
        }
        if (strlen(line) + strlen(a) + 2 >= sizeof line) {
            fprintf(stderr, "gta2ctl: command too long\n");
            return 1;
        }
        if (k > i)
            strcat(line, " ");
        strcat(line, a);
    }
    strcat(line, "\n");

    double t0 = now();
    int fd = -1;
    for (;;) {
        if (sock && *sock) {
            fd = try_connect(sock);
            if (fd < 0 && now() - t0 >= wait_sock) {
                fprintf(stderr, "gta2ctl: cannot connect to %s: %s\n", sock, strerror(errno));
                return 1;
            }
        } else {
            int n = scan(found, live), nlive = 0, pick = -1;
            for (int k = 0; k < n; k++)
                if (live[k])
                    nlive++, pick = k;
            if (nlive == 1)
                fd = try_connect(found[pick]);
            if (nlive > 1) {
                fprintf(stderr, "gta2ctl: %d live games, pick one with --sock=PATH or GTA2_CTL:\n", nlive);
                for (int k = 0; k < n; k++)
                    if (live[k])
                        fprintf(stderr, "  %s\n", found[k]);
                return 1;
            }
            if (fd < 0 && now() - t0 >= wait_sock) {
                fprintf(stderr, "gta2ctl: no live game (start it with --ctl)\n");
                return 1;
            }
        }
        if (fd >= 0)
            break;
        usleep(100 * 1000);
    }

    size_t len = strlen(line), off = 0;
    while (off < len) {
        ssize_t w = write(fd, line + off, len - off);
        if (w <= 0) {
            fprintf(stderr, "gta2ctl: write: %s\n", strerror(errno));
            return 1;
        }
        off += (size_t)w;
    }
    static char reply[1 << 16];
    size_t got = 0;
    t0 = now();
    while (!memchr(reply, '\n', got)) {
        int left = (int)((timeout - (now() - t0)) * 1000);
        struct pollfd p = { .fd = fd, .events = POLLIN };
        if (left <= 0 || poll(&p, 1, left) == 0) {
            fprintf(stderr, "gta2ctl: no reply within %.0f s\n", timeout);
            return 2;
        }
        ssize_t r = read(fd, reply + got, sizeof reply - 1 - got);
        if (r <= 0) {
            fprintf(stderr, "gta2ctl: the game closed the connection\n");
            return 1;
        }
        got += (size_t)r;
        if (got >= sizeof reply - 1)
            break;
    }
    reply[got] = 0;
    fputs(reply, stdout);
    if (!strncmp(reply, "{\"ok\":true", 10))
        return 0;
    return strstr(reply, "\"result\":\"timeout\"") ? 2 : 1;
}
