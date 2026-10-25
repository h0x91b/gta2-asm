/* c32_abi.h — the C32 image header, shared by the 32-bit image (rt.c) and the 64-bit
 * host that loads it (host/c/c32_host.c), and the service structs both sides fill. Every field is a 32-bit VA, so the layout is the
 * same on both sides. The header is the first thing in the image (c32.ld, .c32.head). */
#ifndef C32_ABI_H
#define C32_ABI_H

#include <stdint.h>

#define C32_MAGIC   0x32334343u         /* "CC32" */
#define C32_VERSION 1u

struct c32_header {
    uint32_t magic, version;
    uint32_t base;                      /* link address = where the image must be mapped */
    uint32_t image_end;                 /* end of the bytes in the blob */
    uint32_t bss_start, bss_end;        /* zeroed by the host */
    uint32_t start;                     /* void __stdcall c32_start(void): runs C32_INITs */
    uint32_t imports, n_imports;        /* struct c32_import[]: host services */
    uint32_t exports, exports_end;      /* struct c32_export[] (c32.h), 8 bytes each */
};

/* One host service: the host binds slot to a 32-bit import stub for "c32!<name>"
 * (shimtab_c32 in host/c32_blob.asm); the image calls it through slot. */
struct c32_import {
    uint32_t name;                      /* const char* */
    uint32_t slot;
};

/* foot_input's reply (c32/player_move.c <- c32_host.c), written by the host into the
 * image's memory: the on-foot controls of this tick */
struct c32_foot_input {
    int32_t mouse_on;                   /* controls.mouse_turn */
    int32_t strafe;                     /* +1 left key, -1 right key, 0 none, both or strafe off */
    int32_t mouse_px;                   /* whole pixels of x motion since the last tick */
    int32_t mouse_ok;                   /* mouse_px is usable (focus, no stale backlog) */
    int32_t mouse_sens;                 /* controls.mouse_sensitivity, percent */
};

/* sprite_probe's tag (c32/sprite_probe.c -> host/c/sprite_probe.c): the sprite Sprite_Draw
 * is drawing right now, read by the host's gbh_DrawQuad while active is 1 */
#define SP_OWNER_CAR 1
#define SP_OWNER_PED 2
struct c32_sprite_tag {
    uint32_t active;                    /* 1 while the original Sprite_Draw runs */
    uint32_t seq;                       /* +1 per Sprite_Draw call (tells two draws apart) */
    uint32_t sprite;                    /* Sprite* */
    uint32_t deltas;                    /* cars: Car.deltasBitstate at entry */
    uint16_t type, id, kind, remap;     /* Sprite +0x30, +0x22, +0x34, +0x24 */
    uint8_t shrink, owner;              /* Sprite +0x38; 0 / SP_OWNER_CAR / SP_OWNER_PED */
    uint8_t graphic, ped_remap, armed;  /* peds: Ped.graphicType, Ped.remap, a weapon selected */
    uint8_t anim, anim_frame, walk_sub; /* peds: PedGameObject +0x6C, +0x68, +0x10 */
};

#endif
