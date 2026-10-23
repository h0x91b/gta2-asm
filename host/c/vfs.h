/* vfs.h — the game's files: read-only data.pak + the writable overlay (vfs.c), shared
 * with the KERNEL32 file shims (files.c). NASM callers use the same symbols under their
 * NASM names (c_bridge.asm). */
#ifndef VFS_H
#define VFS_H

#include <stdint.h>
#include <sys/stat.h>

#include "game.h"

/* One pak entry. 24 bytes, the layout loader.asm's read_image reads (PAK_ENT_SIZE). */
struct pak_ent {
    char *name;                         /* relative, '/' separators, "dir/" stored as "dir" */
    uint64_t off;                       /* data offset in the pak */
    uint32_t size;
    uint32_t flags;                     /* PAK_DIR */
};
#define PAK_DIR 1

/* vfs_resolve results; >= 0 is a pak index */
#define VFS_REFUSED (-3)                /* path outside C:\GTA2 */
#define VFS_NONE    (-2)                /* neither overlay nor pak (vfs_path: where to create) */
#define VFS_OVERLAY (-1)                /* overlay file/dir (vfs_path, vfs_st filled) */

#define PATH_MAX_W 1024

extern struct pak_ent *pak_ents NASM(pak_ents);
extern const char *pak_path NASM(pak_path);
extern uint32_t pak_count;

/* the last win_path / vfs_resolve result: the host path and (for VFS_OVERLAY) its stat */
extern char vfs_path[PATH_MAX_W];
extern struct stat vfs_st;

/* vfs_load: the whole file in a malloc'ed buffer (+16 zero bytes of slack) and its size
 * (rax:rdx in SysV); data 0 if it is in neither place */
struct vfs_file { uint8_t *data; uint64_t size; };

void vfs_open_pak(const char *path) NASM(vfs_open_pak);
int vfs_find(const char *rel) NASM(vfs_find);
int64_t vfs_read_at(int idx, void *buf, uint64_t n, uint64_t pos) NASM(vfs_read_at);
int vfs_resolve(const char *game_path) NASM(vfs_resolve);
struct vfs_file vfs_load(const char *game_path) NASM(vfs_load);
void enter_overlay_dir(void) NASM(enter_overlay_dir);
int vfs_is_dir(const char *rel);
int vfs_copy_out(int idx, char *path);
void mkdir_parents(char *path);
char *win_path(const char *path);

#endif
