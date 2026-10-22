/* c32_abi.h — the C32 image header, shared by the 32-bit image (rt.c) and the 64-bit
 * host that loads it (host/c/c32_host.c). Every field is a 32-bit VA, so the layout is the
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

#endif
