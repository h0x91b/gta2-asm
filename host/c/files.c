/* files.c — KERNEL32 file shims on top of data.pak + the overlay (vfs.c). Each is an
 * import handler uint64_t f(const uint32_t *args) (docs/host-c.md, "Import shims in C");
 * the table with the stdcall pop counts is host/w32_files.asm.
 *
 * The host chdir()s into the overlay directory and the game sees it as C:\GTA2 (path
 * policy: vfs.c). Handles are the NASM handle table's (w32_core.asm): an overlay file is
 * HT_FILE {fd}, a pak file opened read-only HT_PAK {pak index, u64 position}, a search
 * HT_FIND {host find block}.
 */
#include <dirent.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "vfs.h"

/* w32_core.asm: the handle table and the Win32 error codes */
#define HT_FREE 0
#define HT_STD  1
#define HT_FILE 2
#define HT_FIND 3
#define HT_PAK  7
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define ERROR_INVALID_HANDLE 6
#define ERROR_NO_MORE_FILES  18

#define GENERIC_READ   0x80000000u
#define GENERIC_WRITE  0x40000000u
#define INVALID_HANDLE 0xFFFFFFFFu
#define ATTR_DIRECTORY 0x10
#define ATTR_NORMAL    0x80

struct handle { uint32_t type, fd; uint64_t extra; };
uint32_t handle_new(uint32_t type, uint32_t fd, uint64_t extra) NASM(handle_new);
struct handle *handle_get(uint32_t h) NASM(handle_get);
extern uint32_t last_error NASM(last_error);          /* w32_core.asm */
extern uint32_t std_handles[3] NASM(std_handles);     /* w32_kernel32.asm */
extern uint8_t trace NASM(trace);                     /* loader.asm: --trace */

static const char virt_dir[] = "C:\\GTA2";
static char find_tmp[PATH_MAX_W];

#define STR(a) ((char *)(uintptr_t)(a))

/* fd for a file/std handle, -1 otherwise */
static int handle_fd(uint32_t h)
{
    struct handle *e = handle_get(h);
    return e && (e->type == HT_FILE || e->type == HT_STD) ? (int)e->fd : -1;
}

/* the handle entry if it is an open pak file, else 0 */
static struct handle *pak_handle(uint32_t h)
{
    struct handle *e = handle_get(h);
    return e && e->type == HT_PAK ? e : 0;
}

/* CreateFileA(name, access, share, sec, disposition, flags, template).
 * Overlay file (or nothing anywhere): host open(), created in the overlay as asked.
 * Pak file: read-only access gets an HT_PAK handle; write access copies the entry to the
 * overlay first (unless it is about to be truncated). */
void map_on_open(const char *name);     /* map.c: a .gmp names the level */

uint64_t k32_CreateFileA(const uint32_t *args)
{
    map_on_open(STR(args[0]));
    uint32_t access = args[1], disp = args[4], h;
    int r = vfs_resolve(STR(args[0]));
    if (r == VFS_REFUSED)
        goto not_found;
    int fl = 0;
    if (access & GENERIC_WRITE)
        fl = access & GENERIC_READ ? O_RDWR : O_WRONLY;
    if (disp == 1)                      /* CREATE_NEW */
        fl |= O_CREAT | O_EXCL;
    if (disp == 2)                      /* CREATE_ALWAYS */
        fl |= O_CREAT | O_TRUNC;
    if (disp == 4)                      /* OPEN_ALWAYS */
        fl |= O_CREAT;
    if (disp == 5)                      /* TRUNCATE_EXISTING */
        fl |= O_TRUNC;
    if (r >= 0) {
        if (!(access & GENERIC_WRITE)) {
            h = handle_new(HT_PAK, (uint32_t)r, 0);
            printf("  [vfs] CreateFileA(%s) -> pak %s (%u bytes), handle 0x%x\n",
                   STR(args[0]), vfs_path, pak_ents[r].size, h);
            last_error = 0;
            return h;
        }
        if (disp == 3 || disp == 4)     /* OPEN_EXISTING / OPEN_ALWAYS keep the contents */
            vfs_copy_out(r, vfs_path);
    }
    if (fl & O_CREAT)
        mkdir_parents(vfs_path);
    int fd = open(vfs_path, fl, 0644);
    if (fd < 0)
        goto not_found;
    h = handle_new(HT_FILE, (uint32_t)fd, 0);
    if ((access & GENERIC_WRITE) || trace)  /* writes always logged, reads with --trace */
        printf("  [w32] CreateFileA(%s) -> overlay %s, handle 0x%x\n", STR(args[0]), vfs_path, h);
    last_error = 0;
    return h;
not_found:
    printf("  [w32] CreateFileA(%s) -> not found\n", STR(args[0]));
    last_error = ERROR_FILE_NOT_FOUND;
    return INVALID_HANDLE;
}

uint64_t k32_ReadFile(const uint32_t *args)         /* (h, buf, n, read*, overlapped) */
{
    struct handle *p = pak_handle(args[0]);
    int64_t n;
    if (p) {
        n = vfs_read_at((int)p->fd, STR(args[1]), args[2], p->extra);
        if (n < 0)
            goto bad;
        p->extra += (uint64_t)n;
    } else {
        int fd = handle_fd(args[0]);
        if (fd < 0 || (n = read(fd, STR(args[1]), args[2])) < 0)
            goto bad;
    }
    if (args[3])
        wr32(args[3], (uint32_t)n);
    return 1;
bad:
    last_error = ERROR_INVALID_HANDLE;
    return 0;
}

uint64_t k32_WriteFile(const uint32_t *args)        /* (h, buf, n, written*, overlapped) */
{
    int fd = handle_fd(args[0]);
    ssize_t n;
    if (fd < 0 || (n = write(fd, STR(args[1]), args[2])) < 0) {
        last_error = ERROR_INVALID_HANDLE;
        return 0;
    }
    if (args[3])
        wr32(args[3], (uint32_t)n);
    return 1;
}

/* SetFilePointer(h, lo, hi*, method) -> the new position (the game reads the low dword;
 * *hi gets the high one) */
uint64_t k32_SetFilePointer(const uint32_t *args)
{
    int64_t dist = (int32_t)args[1], pos;   /* 64-bit = hi:lo when hi* is given */
    if (args[2])
        dist = (int64_t)((uint64_t)rd32(args[2]) << 32 | args[1]);
    struct handle *p = pak_handle(args[0]);
    if (p) {
        int64_t base = 0;               /* FILE_BEGIN */
        if (args[3] == 1)               /* FILE_CURRENT */
            base = (int64_t)p->extra;
        else if (args[3] == 2)          /* FILE_END */
            base = pak_ents[p->fd].size;
        pos = base + dist;
        if (pos < 0)
            goto bad;
        p->extra = (uint64_t)pos;
    } else {
        int fd = handle_fd(args[0]);    /* FILE_BEGIN/CURRENT/END = SEEK_SET/CUR/END */
        if (fd < 0 || (pos = lseek(fd, dist, (int)args[3])) < 0)
            goto bad;
    }
    if (args[2])
        wr32(args[2], (uint32_t)((uint64_t)pos >> 32));
    return (uint64_t)pos;
bad:
    last_error = ERROR_INVALID_HANDLE;
    return INVALID_HANDLE;
}

uint64_t k32_SetEndOfFile(const uint32_t *args)     /* (h) */
{
    int fd = handle_fd(args[0]);
    if (fd < 0)
        return 0;
    ftruncate(fd, lseek(fd, 0, SEEK_CUR));
    return 1;
}

uint64_t k32_GetFileType(const uint32_t *args)      /* FILE_TYPE_DISK 1 / CHAR 2 / UNKNOWN 0 */
{
    struct handle *e = handle_get(args[0]);
    if (!e)
        return 0;
    if (e->type == HT_STD)
        return 2;
    return e->type == HT_PAK || e->type == HT_FILE;
}

uint64_t k32_GetStdHandle(const uint32_t *args)     /* (-10 / -11 / -12) */
{
    uint32_t i = -args[0] - 10;
    return i > 2 ? INVALID_HANDLE : std_handles[i];
}

uint64_t k32_GetFileAttributesA(const uint32_t *args)   /* (path) */
{
    int r = vfs_resolve(STR(args[0]));
    if (r == VFS_OVERLAY)
        return S_ISDIR(vfs_st.st_mode) ? ATTR_DIRECTORY : ATTR_NORMAL;
    if (r >= 0)
        return pak_ents[r].flags & PAK_DIR ? ATTR_DIRECTORY : ATTR_NORMAL;
    if (r == VFS_NONE && vfs_is_dir(vfs_path))
        return ATTR_DIRECTORY;
    last_error = ERROR_FILE_NOT_FOUND;
    return INVALID_HANDLE;              /* INVALID_FILE_ATTRIBUTES */
}

/* ---- directory search -------------------------------------------------------------
 * The overlay directory is listed first (dir = 0 once done or if it does not exist),
 * then the pak entries directly inside path that the overlay does not have. */
struct find {
    DIR *dir;
    char path[PATH_MAX_W];
    char pat[260];
    uint32_t idx;                       /* next pak index */
    uint32_t plen;                      /* strlen(path), 0 = root */
};

/* fill WIN32_FIND_DATAA (320 bytes): attributes 0, nFileSizeHigh 28, Low 32, cFileName 44 */
static void find_fill(gptr fd, const char *name, uint32_t attr, uint64_t size)
{
    memset(STR(fd), 0, 320);
    strncpy(STR(fd) + 44, name, 259);
    wr32(fd, attr);
    wr32(fd + 28, (uint32_t)(size >> 32));
    wr32(fd + 32, (uint32_t)size);
}

/* 1 = filled, 0 = no more. Skips "." and "..". */
static int find_next(struct find *f, gptr fd)
{
    struct stat st;
    while (f->dir) {
        struct dirent *de = readdir(f->dir);
        if (!de) {
            closedir(f->dir);
            f->dir = 0;
            break;
        }
        const char *n = de->d_name;
        if (!strcmp(n, ".") || !strcmp(n, "..") || fnmatch(f->pat, n, FNM_CASEFOLD))
            continue;
        snprintf(find_tmp, sizeof find_tmp, "%s/%s", f->path, n);
        if (stat(find_tmp, &st))        /* stat dir/name for size + attributes */
            find_fill(fd, n, ATTR_NORMAL, 0);
        else
            find_fill(fd, n, S_ISDIR(st.st_mode) ? ATTR_DIRECTORY : ATTR_NORMAL,
                      (uint64_t)st.st_size);
        return 1;
    }
    for (uint32_t i = f->idx; i < pak_count; ) {
        const struct pak_ent *pe = &pak_ents[i++];
        const char *leaf = pe->name;    /* must be path + "/" + leaf */
        if (f->plen) {
            if (strncasecmp(leaf, f->path, f->plen) || leaf[f->plen] != '/')
                continue;
            leaf += f->plen + 1;
        }
        if (!*leaf || strchr(leaf, '/') || fnmatch(f->pat, leaf, FNM_CASEFOLD))
            continue;
        snprintf(find_tmp, sizeof find_tmp, "%s/%s", f->path, leaf);
        if (!stat(find_tmp, &st))       /* the overlay's copy was listed already */
            continue;
        f->idx = i;
        find_fill(fd, leaf, pe->flags & PAK_DIR ? ATTR_DIRECTORY : ATTR_NORMAL, pe->size);
        return 1;
    }
    return 0;
}

uint64_t k32_FindFirstFileA(const uint32_t *args)   /* (pattern, WIN32_FIND_DATAA*) */
{
    struct find *f = malloc(sizeof *f);
    const char *pat;
    /* split "dir\pattern" on a host copy (the game's string may be read-only) */
    strncpy(find_tmp, STR(args[0]), PATH_MAX_W - 1);
    find_tmp[PATH_MAX_W - 1] = 0;
    char *sep = strrchr(find_tmp, '\\');
    if (!sep)
        sep = strrchr(find_tmp, '/');
    if (!sep) {
        strcpy(f->path, ".");
        pat = STR(args[0]);
    } else {
        *sep = 0;
        const char *dir = win_path(find_tmp);
        if (!dir)
            goto fail;
        strcpy(f->path, dir);
        pat = sep + 1;
    }
    strncpy(f->pat, pat, 259);
    f->pat[259] = 0;
    if (!strcmp(f->pat, "*.*"))         /* Windows "*.*" also matches names without a dot */
        strcpy(f->pat, "*");
    f->idx = 0;
    f->plen = strcmp(f->path, ".") ? (uint32_t)strlen(f->path) : 0;
    f->dir = opendir(f->path);
    if (!f->dir && !vfs_is_dir(f->path))
        goto fail;
    if (!find_next(f, args[1]))
        goto fail;                      /* find_next closed the directory */
    uint32_t h = handle_new(HT_FIND, 0, (uint64_t)(uintptr_t)f);
    if (trace)
        printf("  [w32] FindFirstFileA(%s) -> 0x%x\n", STR(args[0]), h);
    return h;
fail:
    free(f);
    printf("  [w32] FindFirstFileA(%s) -> no match\n", STR(args[0]));
    last_error = ERROR_FILE_NOT_FOUND;
    return INVALID_HANDLE;
}

uint64_t k32_FindNextFileA(const uint32_t *args)    /* (h, WIN32_FIND_DATAA*) */
{
    struct handle *e = handle_get(args[0]);
    if (!e || e->type != HT_FIND) {
        last_error = ERROR_INVALID_HANDLE;
        return 0;
    }
    int r = find_next((struct find *)(uintptr_t)e->extra, args[1]);
    if (!r)
        last_error = ERROR_NO_MORE_FILES;
    return (uint64_t)r;
}

uint64_t k32_FindClose(const uint32_t *args)        /* (h) */
{
    struct handle *e = handle_get(args[0]);
    if (!e || e->type != HT_FIND)
        return 0;
    struct find *f = (struct find *)(uintptr_t)e->extra;
    if (f->dir)
        closedir(f->dir);
    free(f);
    e->type = HT_FREE;
    return 1;
}

/* ---- directories / paths ------------------------------------------------------------ */

uint64_t k32_GetCurrentDirectoryA(const uint32_t *args)    /* (size, buf): never leaves C:\GTA2 */
{
    uint32_t len = sizeof virt_dir - 1;
    if (args[0] <= len)
        return len + 1;
    strcpy(STR(args[1]), virt_dir);
    return len;
}

uint64_t k32_SetCurrentDirectoryA(const uint32_t *args)    /* only the game directory itself */
{
    printf("  [w32] SetCurrentDirectoryA(%s)\n", STR(args[0]));
    const char *p = win_path(STR(args[0]));
    if (p && !strcmp(p, "."))
        return 1;
    last_error = ERROR_PATH_NOT_FOUND;
    return 0;
}

uint64_t k32_GetFullPathNameA(const uint32_t *args)        /* (name, size, buf, filepart*) */
{
    const char *name = STR(args[0]);
    int n = name[1] == ':' ? snprintf(STR(args[2]), args[1], "%s", name)
                           : snprintf(STR(args[2]), args[1], "%s\\%s", virt_dir, name);
    if (args[3])
        wr32(args[3], (uint32_t)(uintptr_t)strrchr(STR(args[2]), '\\') + 1);
    return (uint32_t)n;
}

uint64_t k32_GetDriveTypeA(const uint32_t *args)
{
    (void)args;
    return 3;                           /* DRIVE_FIXED */
}

/* GetPrivateProfileStringA(app, key, default, buf, size, file): no INI files are
 * supported yet; returns the default and logs the request. */
uint64_t k32_GetPrivateProfileStringA(const uint32_t *args)
{
    printf("  [w32] GetPrivateProfileStringA(%s, [%s] %s): no INI support, default\n",
           STR(args[5]), STR(args[0]), STR(args[1]));
    char *buf = STR(args[3]);
    strncpy(buf, args[2] ? STR(args[2]) : "", (uint32_t)(args[4] - 1));
    buf[(int64_t)args[4] - 1] = 0;
    return strlen(buf);
}
