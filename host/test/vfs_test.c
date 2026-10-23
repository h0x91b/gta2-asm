/* vfs_test.c — host test of the pak VFS (host/c/vfs.c) without the loader: writes small
 * Stored zips into a temp directory and checks the index (local-header data offsets, "dir/"
 * entries), case-insensitive lookup, directories, clipped reads, win_path's path policy,
 * the overlay winning over the pak, copy-out before a write, and that a non-Stored or
 * broken pak is refused (exit 1, in a child process). `host/build.sh --test`.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../c/vfs.h"

/* ---- stub ------------------------------------------------------------------------------ */

void fail(const char *msg) NASM(fail) __attribute__((noreturn));
void fail(const char *msg)
{
    printf("loader: FAIL: %s\n", msg);
    exit(2);
}

/* ---- checks ----------------------------------------------------------------------------- */

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static void check_path(const char *in, const char *want)
{
    const char *got = win_path(in);
    if (!want ? got != 0 : !got || strcmp(got, want)) {
        printf("FAIL win_path(\"%s\") = %s%s%s, want %s\n", in, got ? "\"" : "", got ? got : "0",
               got ? "\"" : "", want ? want : "0");
        failures++;
    }
}

/* ---- zip writer -------------------------------------------------------------------------- */

struct zent { const char *name; const char *data; int method; int lextra; };

static void p16(FILE *f, unsigned v) { fputc(v & 0xFF, f); fputc(v >> 8 & 0xFF, f); }
static void p32(FILE *f, uint32_t v) { p16(f, v & 0xFFFF); p16(f, v >> 16); }

/* a zip of ents (CRCs left 0: the loader never checks them); lextra = extra bytes in the
 * local header only, so its data offset differs from what the central record implies */
static void write_zip(const char *path, const struct zent *ents, int n)
{
    FILE *f = fopen(path, "wb");
    uint32_t off[16];
    for (int i = 0; i < n; i++) {
        uint32_t len = (uint32_t)strlen(ents[i].data), nl = (uint32_t)strlen(ents[i].name);
        off[i] = (uint32_t)ftell(f);
        p32(f, 0x04034B50); p16(f, 20); p16(f, 0); p16(f, ents[i].method); p32(f, 0); p32(f, 0);
        p32(f, len); p32(f, len); p16(f, nl); p16(f, ents[i].lextra);
        fputs(ents[i].name, f);
        for (int k = 0; k < ents[i].lextra; k++)
            fputc(0xEE, f);
        fputs(ents[i].data, f);
    }
    uint32_t cd = (uint32_t)ftell(f);
    for (int i = 0; i < n; i++) {
        uint32_t len = (uint32_t)strlen(ents[i].data), nl = (uint32_t)strlen(ents[i].name);
        p32(f, 0x02014B50); p16(f, 20); p16(f, 20); p16(f, 0); p16(f, ents[i].method);
        p32(f, 0); p32(f, 0); p32(f, len); p32(f, len); p16(f, nl); p16(f, 0); p16(f, 0);
        p16(f, 0); p16(f, 0); p32(f, 0); p32(f, off[i]);
        fputs(ents[i].name, f);
    }
    uint32_t cd_end = (uint32_t)ftell(f);
    p32(f, 0x06054B50); p16(f, 0); p16(f, 0); p16(f, n); p16(f, n); p32(f, cd_end - cd); p32(f, cd);
    p16(f, 3); fputs("hi!", f);                   /* a comment: the EOCD is not the last 22 */
    fclose(f);
}

/* run vfs_open_pak(path) in a child: its exit status and the first output line */
static int open_in_child(const char *path, char *line, size_t cap)
{
    int fds[2];
    pipe(fds);
    fflush(stdout);
    pid_t pid = fork();
    if (!pid) {
        dup2(fds[1], 1);
        vfs_open_pak(path);
        exit(0);
    }
    close(fds[1]);
    ssize_t got = read(fds[0], line, cap - 1);
    line[got > 0 ? got : 0] = 0;
    close(fds[0]);
    int st;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static void write_file(const char *path, const char *data)
{
    FILE *f = fopen(path, "wb");
    fputs(data, f);
    fclose(f);
}

static char *slurp(const char *path)
{
    static char buf[256];
    FILE *f = fopen(path, "rb");
    if (!f)
        return 0;
    buf[fread(buf, 1, sizeof buf - 1, f)] = 0;
    fclose(f);
    return buf;
}

int main(void)
{
    char tmp[] = "/tmp/vfs_test.XXXXXX", pak[256], line[512], buf[64];
    if (!mkdtemp(tmp))
        return 1;

    /* ---- refused paks ---- */
    snprintf(pak, sizeof pak, "%s/deflate.pak", tmp);
    const struct zent bad[] = { { "a.txt", "aaaa", 0, 0 }, { "data/b.raw", "bbbb", 8, 0 } };
    write_zip(pak, bad, 2);
    CHECK(open_in_child(pak, line, sizeof line) == 1);
    CHECK(strstr(line, "entry data/b.raw is not Stored (method 8)") != 0);
    snprintf(pak, sizeof pak, "%s/junk.pak", tmp);
    write_file(pak, "this is not a zip file at all, just some bytes");
    CHECK(open_in_child(pak, line, sizeof line) == 1);
    CHECK(strstr(line, "is not a zip this loader understands") != 0);
    snprintf(pak, sizeof pak, "%s/missing.pak", tmp);
    CHECK(open_in_child(pak, line, sizeof line) == 1);
    CHECK(strstr(line, "cannot open") != 0);

    /* ---- index ---- */
    snprintf(pak, sizeof pak, "%s/data.pak", tmp);
    const struct zent good[] = {
        { "gta2.ebin", "MZ-image", 0, 0 },
        { "data/", "", 0, 0 },
        { "data/Audio/fstyle.raw", "0123456789", 0, 7 },
        { "data/wil.sty", "pak style", 0, 0 },
        { "test/x.txt", "x", 0, 0 },              /* no explicit "test/" entry */
    };
    write_zip(pak, good, 5);
    vfs_open_pak(pak);
    CHECK(pak_count == 5);
    CHECK(sizeof(struct pak_ent) == 24);          /* loader.asm's PAK_ENT_SIZE */
    CHECK(!strcmp(pak_ents[1].name, "data") && pak_ents[1].flags == PAK_DIR);
    CHECK(pak_ents[2].flags == 0 && pak_ents[2].size == 10);

    CHECK(vfs_find("gta2.ebin") == 0);
    CHECK(vfs_find("DATA/audio/FSTYLE.RAW") == 2);
    CHECK(vfs_find("data/wil") == -1);
    CHECK(vfs_find("data") == 1);

    CHECK(vfs_is_dir("."));
    CHECK(vfs_is_dir("data"));
    CHECK(vfs_is_dir("Data/AUDIO"));              /* implicit, from an entry below it */
    CHECK(vfs_is_dir("test"));
    CHECK(!vfs_is_dir("dat"));
    CHECK(!vfs_is_dir("data/wil.sty"));
    CHECK(!vfs_is_dir("nothere"));

    /* clipped reads, from the LOCAL header's offset (7 extra bytes there only) */
    memset(buf, 0, sizeof buf);
    CHECK(vfs_read_at(2, buf, sizeof buf, 0) == 10 && !memcmp(buf, "0123456789", 10));
    CHECK(vfs_read_at(2, buf, 3, 4) == 3 && !memcmp(buf, "456", 3));
    CHECK(vfs_read_at(2, buf, 64, 8) == 2 && !memcmp(buf, "89", 2));
    CHECK(vfs_read_at(2, buf, 64, 10) == 0);
    CHECK(vfs_read_at(2, buf, 64, 999) == 0);

    /* ---- overlay ---- */
    char home[256], ovl[512];
    snprintf(home, sizeof home, "%s/home", tmp);
    setenv("HOME", home, 1);
    enter_overlay_dir();
    snprintf(ovl, sizeof ovl, "%s/Library/Application Support/gta2-resurrected", home);
    struct stat st;
    CHECK(!stat(ovl, &st) && S_ISDIR(st.st_mode));
    char cwd[512];
    CHECK(getcwd(cwd, sizeof cwd) && strstr(cwd, "/gta2-resurrected"));

    /* ---- win_path: the path policy ---- */
    check_path("C:\\GTA2\\data\\wil.sty", "data/wil.sty");
    check_path("c:\\gta2/data/wil.sty", "data/wil.sty");
    check_path("\\GTA2\\data", "data");
    check_path("/gta2", ".");
    check_path("C:\\GTA2", ".");
    check_path("C:\\GTA2\\", ".");
    check_path("data\\\\audio\\.\\fstyle.raw", "data/audio/fstyle.raw");
    check_path(".\\data", "data");
    check_path("C:data\\x", "data/x");            /* "C:foo" = relative */
    check_path("data\\..\\x", "data/../x");       /* ".." is kept as typed */
    check_path("", 0);
    check_path("C:\\Windows\\win.ini", 0);
    check_path("\\GTA2x\\y", 0);
    check_path("D:\\GTA3\\y", 0);
    char lng[1100];
    memset(lng, 'a', sizeof lng);
    lng[1022] = 0;
    CHECK(win_path(lng) != 0);                    /* 1022 chars fit, 1023 do not */
    lng[1022] = 'a';
    lng[1023] = 0;
    CHECK(win_path(lng) == 0);

    /* resolve: refused / none / pak, then the overlay wins */
    CHECK(vfs_resolve("C:\\Windows\\x") == VFS_REFUSED);
    CHECK(vfs_resolve("nothere.txt") == VFS_NONE && !strcmp(vfs_path, "nothere.txt"));
    CHECK(vfs_resolve("C:\\GTA2\\DATA\\WIL.STY") == 3);
    CHECK(vfs_resolve("C:\\GTA2") == VFS_OVERLAY && S_ISDIR(vfs_st.st_mode));

    struct vfs_file f = vfs_load("data\\wil.sty");
    CHECK(f.data && f.size == 9 && !memcmp(f.data, "pak style", 9));
    int zero = 1;
    for (int i = 0; f.data && i < 16; i++)
        zero &= f.data[9 + i] == 0;
    CHECK(zero);                                  /* +16 zero bytes of slack */
    free(f.data);
    f = vfs_load("data\\nothere.sty");
    CHECK(!f.data && !f.size);
    f = vfs_load("C:\\Windows\\x");
    CHECK(!f.data && !f.size);

    char p[256];
    strcpy(p, "data/sub/deeper/file.txt");        /* mkdir_parents: only the directories */
    mkdir_parents(p);
    CHECK(!strcmp(p, "data/sub/deeper/file.txt"));
    CHECK(!stat("data/sub/deeper", &st) && S_ISDIR(st.st_mode));
    CHECK(stat("data/sub/deeper/file.txt", &st));
    write_file("data/wil.sty", "overlay!");
    CHECK(vfs_resolve("C:\\GTA2\\data\\wil.sty") == VFS_OVERLAY);
    f = vfs_load("C:\\GTA2\\Data\\Wil.sty");
    CHECK(f.data && f.size == 8 && !memcmp(f.data, "overlay!", 8));
    free(f.data);

    /* copy-out: a pak file about to be written lands in the overlay, parents created */
    CHECK(vfs_resolve("data\\Audio\\fstyle.raw") == 2);
    strcpy(p, vfs_path);
    CHECK(vfs_copy_out(2, p) == 1);
    CHECK(slurp(p) && !strcmp(slurp(p), "0123456789"));
    CHECK(vfs_resolve("data\\Audio\\fstyle.raw") == VFS_OVERLAY);
    strcpy(p, "data/wil.sty/x");                  /* write failure (a file as parent): 0 */
    CHECK(vfs_copy_out(0, p) == 0);

    char cmd[300];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", tmp);
    system(cmd);
    if (failures) {
        printf("vfs_test: %d FAILED\n", failures);
        return 1;
    }
    printf("vfs_test: ok\n");
    return 0;
}
