/* vfs.c — the game's files: read-only data.pak + a writable overlay directory.
 *
 * data.pak is a plain zip of the old gta2/ folder with every entry Stored (method 0,
 * tools/mkpak.sh), so a file is one contiguous byte range: no decompression code. At
 * startup the End of Central Directory and the central directory are read once into a
 * table name -> (data offset, size); the data offset comes from each LOCAL header
 * (offset + 30 + name len + extra len). Anything that is not a Stored, unencrypted,
 * non-zip64 entry stops the loader with an error.
 *
 * The overlay (~/Library/Application Support/gta2-resurrected/) is the host's current
 * directory, so win_path resolves game paths against it. Lookup order: overlay file,
 * then pak entry (case-insensitive, '/' separators, as win_path produced it). Every
 * write goes to the overlay; a pak-only file opened for writing is copied out first.
 *
 * Path policy: the game is told it lives in C:\GTA2 (GetModuleFileNameA /
 * GetCurrentDirectoryA). win_path maps
 *   C:\GTA2\x, \GTA2\x (any case, either slash)  -> x
 *   relative paths                                -> relative to the game root
 *   any other absolute path                       -> refused (not found)
 * drops "." components, and resolves every component case-insensitively against the
 * overlay on disk (Windows is case-insensitive, APFS here is too by default, but nothing
 * guarantees it). A path missing from the overlay is then looked up in the pak.
 */
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "vfs.h"

#define EOCD_MAX 65557                  /* 22-byte EOCD + the longest zip comment */

void fail(const char *msg) NASM(fail) __attribute__((noreturn));   /* loader.asm */

struct pak_ent *pak_ents;
const char *pak_path;
uint32_t pak_count;
char vfs_path[PATH_MAX_W];
struct stat vfs_st;

static int pak_fd;
static uint64_t pak_fd_size;
static char overlay_dir[PATH_MAX_W];

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static void pak_exit(const char *fmt, const char *name, unsigned method)
{
    printf(fmt, pak_path, name, method);
    exit(1);
}
#define BAD_ZIP() pak_exit("loader: FAIL: %s is not a zip this loader understands " \
                           "(rebuild it with tools/mkpak.sh)\n", 0, 0)

/* vfs_open_pak: open and index data.pak; exits 1 on any problem */
void vfs_open_pak(const char *path)
{
    pak_path = path;
    pak_fd = open(path, O_RDONLY);
    if (pak_fd < 0)
        pak_exit("loader: FAIL: cannot open %s (build it with tools/mkpak.sh)\n", 0, 0);
    off_t size = lseek(pak_fd, 0, SEEK_END);
    pak_fd_size = (uint64_t)size;
    uint64_t tail = pak_fd_size < EOCD_MAX ? pak_fd_size : EOCD_MAX;
    if (tail < 22)
        BAD_ZIP();
    uint8_t *t = malloc(tail);
    if (pread(pak_fd, t, tail, (off_t)(pak_fd_size - tail)) != (ssize_t)tail)
        BAD_ZIP();
    int64_t e = (int64_t)tail - 22;     /* EOCD: the last "PK\5\6" in the tail */
    while (e >= 0 && le32(t + e) != 0x06054B50)
        e--;
    if (e < 0)
        BAD_ZIP();
    pak_count = le16(t + e + 10);
    uint64_t cd_size = le32(t + e + 12), cd_off = le32(t + e + 16);
    free(t);
    if (cd_off + cd_size > pak_fd_size)
        BAD_ZIP();
    uint8_t *cd = malloc(cd_size);
    if (pread(pak_fd, cd, cd_size, (off_t)cd_off) != (ssize_t)cd_size)
        BAD_ZIP();
    const uint8_t *end = cd + cd_size, *r = cd;
    pak_ents = malloc((pak_count + 1) * sizeof *pak_ents);
    for (uint32_t i = 0; i < pak_count; i++) {
        struct pak_ent *pe = &pak_ents[i];
        if (r + 46 > end || le32(r) != 0x02014B50)
            BAD_ZIP();
        pe->name = strndup((const char *)r + 46, le16(r + 28));
        uint32_t csize = le32(r + 20);
        if ((le16(r + 8) & 1) || le16(r + 10) != 0 || csize != le32(r + 24) || csize == 0xFFFFFFFF)
            pak_exit("loader: FAIL: %s: entry %s is not Stored (method %u); "
                     "rebuild it with tools/mkpak.sh (zip -0)\n", pe->name, le16(r + 10));
        pe->size = csize;
        pe->flags = 0;
        uint8_t lh[30];                 /* local header: its own name/extra lengths */
        uint32_t lh_off = le32(r + 42);
        if (pread(pak_fd, lh, 30, lh_off) != 30 || le32(lh) != 0x04034B50)
            BAD_ZIP();
        pe->off = (uint64_t)lh_off + 30 + le16(lh + 26) + le16(lh + 28);
        if (pe->off + pe->size > pak_fd_size)
            BAD_ZIP();
        size_t len = strlen(pe->name);  /* "dir/" -> "dir" + PAK_DIR */
        if (len && pe->name[len - 1] == '/') {
            pe->name[len - 1] = 0;
            pe->flags = PAK_DIR;
        }
        r += 46 + le16(r + 28) + le16(r + 30) + le16(r + 32);
    }
    free(cd);
    printf("pak: %s, %u entries, all Stored\n", pak_path, pak_count);
}

/* vfs_find: the pak index of a path relative to the game root, -1 if absent */
int vfs_find(const char *rel)
{
    for (uint32_t i = 0; i < pak_count; i++)
        if (!strcasecmp(pak_ents[i].name, rel))
            return (int)i;
    return -1;
}

/* vfs_is_dir: 1 if the pak has rel as a directory (an explicit "dir/" entry or any entry
 * below it; "." is the root), else 0 */
int vfs_is_dir(const char *rel)
{
    if (!strcmp(rel, "."))
        return 1;
    size_t len = strlen(rel);
    for (uint32_t i = 0; i < pak_count; i++) {
        const char *n = pak_ents[i].name;
        if (strncasecmp(n, rel, len))
            continue;
        if (n[len] == '/' || (!n[len] && (pak_ents[i].flags & PAK_DIR)))
            return 1;
    }
    return 0;
}

/* vfs_read_at: bytes read, clipped to the entry (0 at or past its end), -1 on an I/O
 * error */
int64_t vfs_read_at(int idx, void *buf, uint64_t n, uint64_t pos)
{
    const struct pak_ent *pe = &pak_ents[idx];
    if (pos >= pe->size)
        return 0;
    if (n > pe->size - pos)
        n = pe->size - pos;
    return pread(pak_fd, buf, n, (off_t)(pe->off + pos));
}

/* ci_fix_last: vfs_path[comp..] is a component that does not exist as typed; replace it
 * with a case-insensitive match from its parent directory, if any. */
static void ci_fix_last(size_t comp)
{
    DIR *d;
    if (comp) {
        vfs_path[comp - 1] = 0;
        d = opendir(vfs_path);
        vfs_path[comp - 1] = '/';
    } else {
        d = opendir(".");
    }
    if (!d)
        return;
    struct dirent *de;
    while ((de = readdir(d)))
        if (!strcasecmp(de->d_name, vfs_path + comp)) {
            strcpy(vfs_path + comp, de->d_name);    /* same length, different case */
            break;
        }
    closedir(d);
}

/* win_path: a Windows path -> host path (vfs_path), 0 if refused */
char *win_path(const char *p)
{
    static char in[PATH_MAX_W];
    if (!*p)
        return 0;
    if (p[1] == ':')
        p += 2;                         /* drop the drive letter (any); "C:foo" = relative */
    if (*p == '\\' || *p == '/') {      /* absolute: must be \GTA2 or below */
        if (strncasecmp(p + 1, "GTA2", 4))
            return 0;
        p += 5;
        if (*p == '\\' || *p == '/')
            p++;
        else if (*p)
            return 0;
    }
    size_t i = 0;                       /* '/' separators */
    for (;; i++) {
        in[i] = p[i] == '\\' ? '/' : p[i];
        if (!in[i])
            break;
        if (i + 1 >= PATH_MAX_W - 1)
            return 0;
    }
    size_t len = 0;                     /* resolve component by component */
    vfs_path[0] = 0;
    const char *c = in;
    for (;;) {
        while (*c == '/')               /* collapse repeated separators */
            c++;
        if (!*c)
            break;
        const char *ce = c;
        while (*ce && *ce != '/')
            ce++;
        size_t n = (size_t)(ce - c);
        if (n == 1 && *c == '.') {      /* "." component: nothing to append */
            c = ce;
            continue;
        }
        if (len)
            vfs_path[len++] = '/';
        size_t comp = len;
        if (len + n + 1 >= PATH_MAX_W)
            return 0;
        memcpy(vfs_path + len, c, n);
        len += n;
        vfs_path[len] = 0;
        if (stat(vfs_path, &vfs_st))    /* not as typed: a case-insensitive match? */
            ci_fix_last(comp);
        c = ce;
    }
    if (!len)
        strcpy(vfs_path, ".");
    return vfs_path;
}

/* vfs_resolve: VFS_REFUSED / VFS_NONE / VFS_OVERLAY (vfs_path is the overlay path, vfs_st
 * its stat) or a pak index (vfs_path = its relative name) */
int vfs_resolve(const char *game_path)
{
    if (!win_path(game_path))
        return VFS_REFUSED;
    if (!stat(vfs_path, &vfs_st))
        return VFS_OVERLAY;
    int i = vfs_find(vfs_path);
    return i == -1 ? VFS_NONE : i;
}

/* vfs_load: a whole game file (overlay, then pak) */
struct vfs_file vfs_load(const char *game_path)
{
    struct vfs_file f = { 0, 0 };
    int r = vfs_resolve(game_path);
    if (r <= VFS_NONE)
        return f;
    uint64_t size = r == VFS_OVERLAY ? (uint64_t)vfs_st.st_size : pak_ents[r].size;
    uint8_t *buf = malloc(size + 16);
    memset(buf + size, 0, 16);
    if (r == VFS_OVERLAY) {
        int fd = open(vfs_path, O_RDONLY);
        if (fd < 0)
            goto bad;
        ssize_t got = pread(fd, buf, size, 0);
        close(fd);
        if (got != (ssize_t)size)
            goto bad;
        printf("  [vfs] %s -> overlay (%u bytes)\n", game_path, (unsigned)size);
    } else {
        if (vfs_read_at(r, buf, size, 0) != (int64_t)size)
            goto bad;
        printf("  [vfs] %s -> pak (%u bytes)\n", game_path, (unsigned)size);
    }
    f.data = buf;
    f.size = size;
    return f;
bad:
    free(buf);
    return f;
}

/* mkdir_parents: create every directory named before a '/' in path */
void mkdir_parents(char *path)
{
    if (!*path)
        return;
    for (char *p = path + 1; *p; p++)
        if (*p == '/') {
            *p = 0;
            mkdir(path, 0755);          /* EEXIST is fine */
            *p = '/';
        }
}

/* vfs_copy_out: copy pak entry idx to the overlay path; 1 ok, 0 failed */
int vfs_copy_out(int idx, char *path)
{
    mkdir_parents(path);
    uint32_t size = pak_ents[idx].size;
    uint8_t *buf = malloc((size_t)size + 1);
    int ok = 0;
    if (vfs_read_at(idx, buf, size, 0) == size) {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            ssize_t w = write(fd, buf, size);
            close(fd);
            if (w == (ssize_t)size) {
                printf("  [vfs] copied the pak's %s to the overlay (%u bytes) before writing\n",
                       path, size);
                ok = 1;
            }
        }
    }
    free(buf);
    return ok;
}

/* enter_overlay_dir: mkdir -p + chdir ~/Library/Application Support/gta2-resurrected/ */
void enter_overlay_dir(void)
{
    const char *home = getenv("HOME");
    if (!home)
        fail("create/enter the overlay directory");
    snprintf(overlay_dir, sizeof overlay_dir, "%s/Library/Application Support/gta2-resurrected/",
             home);
    mkdir_parents(overlay_dir);
    if (chdir(overlay_dir))
        fail("create/enter the overlay directory");
    printf("overlay: %s (writes land here, its files win over the pak; seen by the game as "
           "C:\\GTA2)\n", overlay_dir);
}
