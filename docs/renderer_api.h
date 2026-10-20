/* GTA2 renderer plugin ABI: dmavideo.dll (Vid_*) + d3ddll.dll (gbh_*).
 * Recovered by disassembling the shipped DLLs (see docs/renderer-api.md).
 * 32-bit x86, all exports __stdcall. Offsets are the ones the DLLs and gta2.exe
 * actually touch; "unk" fields were never seen used across the boundary.
 * This file is also what was imported into the Ghidra programs /d3ddll.dll and
 * /dmavideo.dll (category /gta2_renderer).
 */

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;

/* ---------------------------------------------------------------- dmavideo */

/* One display mode, from IDirectDraw4::EnumDisplayModes. 0x40 bytes. */
typedef struct VidMode {
    int  id;          /* 0x00 mode id (1, 2, ...); -2 = "windowed" is never a node */
    int  device_id;   /* 0x04 VidDevice.id it belongs to */
    int  width;       /* 0x08 */
    int  height;      /* 0x0c */
    int  pitch;       /* 0x10 DDSURFACEDESC.lPitch as enumerated */
    int  bpp;         /* 0x14 dwRGBBitCount */
    int  r_shift;     /* 0x18 lowest set bit of the red mask */
    int  r_bits;      /* 0x1c number of bits in the red mask */
    int  g_shift;     /* 0x20 */
    int  g_bits;      /* 0x24 */
    int  b_shift;     /* 0x28 */
    int  b_bits;      /* 0x2c */
    int  x_shift;     /* 0x30 unused bits (e.g. bit 15 of 555), 0 if none */
    int  x_bits;      /* 0x34 */
    struct VidMode *next; /* 0x38 */
    int  valid;       /* 0x3c always 1 */
} VidMode;

/* One DirectDraw device, from DirectDrawEnumerateA. Variable size (strings follow). */
typedef struct VidDevice {
    int   id;         /* 0x00 1 = primary display driver (GUID NULL), then 2, 3, ... */
    u32   flags;      /* 0x04 bit0 = can render windowed (HAL dwCaps2 & DDCAPS2_CANRENDERWINDOWED) */
    char *description;/* 0x08 */
    char *name;       /* 0x0c */
    struct VidDevice *next; /* 0x10 */
    void *guid_ptr;   /* 0x14 -> guid below, or NULL for the primary device */
    u32   guid[4];    /* 0x18 */
    u32   vid_mem;    /* 0x28 DDCAPS.dwVidMemTotal */
} VidDevice;

/* VidCtx.flags (+0x04) */
#define VID_F_LOCKED        0x00000001 /* back buffer locked (Grab/GetSurface) */
#define VID_F_WRITES        0x00000002 /* surface/pitch published at +0x50/+0x54 */
#define VID_F_TRIPLE        0x00000010 /* 2 back buffers (game: "tripple_buffer") */
#define VID_F_FLIPCHAIN     0x00000020 /* default on (Init_SYS) */
#define VID_F_3DDEVICE      0x00000040 /* add DDSCAPS_3DDEVICE (game sets it for d3ddll) */
#define VID_F_SYSMEM_BACK   0x00000080 /* windowed back buffer in system memory */
#define VID_F_MODECHANGE    0x00000100 /* game ORs it in right before every Vid_SetMode */
#define VID_F_NOVSYNC       0x00000200 /* Flip(DDFLIP_WAIT|DDFLIP_NOVSYNC); default on */
#define VID_F_LOST          0x10000000 /* a surface was lost/restored this frame */

/* The video context returned by Vid_Init_SYS. Heap block of 0x4c4 bytes.
 * gta2.exe keeps the pointer in a global at 0x673d20 and reads only
 * +0x04 +0x1c +0x40 +0x48 +0x4c +0x50 +0x54 +0x5c +0x64 +0x6c.
 * d3ddll additionally reads +0x7c +0x84 +0x8c +0x120 +0x134 +0x138 +0x13c.. +0x1c8.. */
typedef struct VidCtx {
    int        one;            /* 0x000 = 1 */
    u32        flags;          /* 0x004 VID_F_* */
    int        found_width;    /* 0x008 result of the last Find/Check call */
    int        found_height;   /* 0x00c */
    int        found_bpp;      /* 0x010 */
    int        next_mode_id;   /* 0x014 starts at 1 */
    int        next_device_id; /* 0x018 starts at 2 (primary = 1) */
    int        num_modes;      /* 0x01c */
    int        num_devices;    /* 0x020 */
    VidMode   *modes;          /* 0x024 list head */
    VidMode   *modes_tail;     /* 0x028 */
    VidDevice *devices;        /* 0x02c list head */
    VidDevice *devices_tail;   /* 0x030 */
    int        device_id;      /* 0x034 current device (0 = none) */
    int        unk_38;         /* 0x038 */
    VidMode   *find_iter;      /* 0x03c FindFirst/NextMode cursor */
    int        mode_id;        /* 0x040 current mode id; -2 windowed; 0 none */
    int        unk_44;         /* 0x044 */
    int        width;          /* 0x048 current screen width */
    int        height;         /* 0x04c current screen height */
    void      *surface;        /* 0x050 locked back buffer pixels (NULL unless VID_F_WRITES) */
    int        pitch;          /* 0x054 bytes per row of the locked back buffer */
    int        r_shift;        /* 0x058 screen pixel format (copied from the VidMode / surface desc) */
    int        r_bits;         /* 0x05c */
    int        g_shift;        /* 0x060 */
    int        g_bits;         /* 0x064 */
    int        b_shift;        /* 0x068 */
    int        b_bits;         /* 0x06c */
    int        x_shift;        /* 0x070 */
    int        x_bits;         /* 0x074 */
    void      *hinstance;      /* 0x078 Vid_Init_SYS arg 1 (game's hInstance) */
    void      *hmodule;        /* 0x07c Vid_InitDLL arg 1 (dmavideo's own HMODULE); d3ddll GetProcAddress's on it */
    int        fullscreen;     /* 0x080 1 fullscreen, 0 windowed */
    void    ***slot_table;     /* 0x084 Vid_InitDLL arg 2: gta2.exe table of 22 pointers to its Vid_* slots */
    int        hresult;        /* 0x088 last DirectDraw HRESULT */
    void      *ddraw;          /* 0x08c IDirectDraw* */
    u8         unk_090[0x90];  /* 0x090 */
    void      *ddraw4;         /* 0x120 IDirectDraw4* (QueryInterface from +0x8c) */
    u8         unk_124[0x10];  /* 0x124 */
    void      *primary;        /* 0x134 IDirectDrawSurface4* primary */
    void      *back;           /* 0x138 IDirectDrawSurface4* back buffer (render target) */
    u8         lock_desc[0x7c];/* 0x13c DDSURFACEDESC2 of the last Lock: lPitch @0x14c, lpSurface @0x160 */
    void      *clipper;        /* 0x1b8 IDirectDrawClipper* (windowed) */
    u8         unk_1bc[0xc];   /* 0x1bc */
    u8         hal_caps[0x17c];/* 0x1c8 DDCAPS (HAL) */
    u8         hel_caps[0x17c];/* 0x344 DDCAPS (HEL) */
    void      *hwnd;           /* 0x4c0 HWND given to Vid_SetMode */
} VidCtx;                      /* 0x4c4 */

/* Vid_GetVersion() result */
typedef struct VidVersion {
    float version;             /* 1.81 */
    char  text[1];             /* "DMA Video (Direct Draw implementation). Version ..." */
} VidVersion;

/* ---------------------------------------------------------------- d3ddll */

/* Vertex passed to gbh_DrawTriangle/Quad/Tile (3 or 4 of them, contiguous).
 * Same layout as D3DTLVERTEX / FVF XYZRHW|DIFFUSE|SPECULAR|TEX1. 0x20 bytes.
 * The DLL rewrites some fields in place (rhw, diffuse, specular, u, v). */
typedef struct GbhVertex {
    float x;        /* 0x00 screen x, pixels */
    float y;        /* 0x04 screen y, pixels */
    float z;        /* 0x08 1/depth style value; <= epsilon culls the whole primitive (only v[0] checked) */
    float rhw;      /* 0x0c overwritten with z by the DLL */
    u32   diffuse;  /* 0x10 0xAARRGGBB; overwritten with 0xFF,b,b,b unless GBH_F_VERTEX_COLOUR */
    u32   specular; /* 0x14 overwritten with 0 */
    float u;        /* 0x18 texels (0..width); DLL multiplies by 1/cache_page_size */
    float v;        /* 0x1c texels */
} GbhVertex;

/* draw flags: first argument of gbh_DrawTriangle/Quad/Tile */
#define GBH_F_TILE_FLIPX       0x00000008 /* DrawTile: mirror */
#define GBH_F_TILE_FLIPY       0x00000010 /* DrawTile: mirror other axis */
#define GBH_F_TILE_ROT_MASK    0x00000060 /* DrawTile: 0x20 / 0x40 / 0x60 = rotate UVs */
#define GBH_F_ALPHA_MASK       0x00000380 /* any: alpha blending on */
#define GBH_F_ALPHA_A          0x00000080 /*  SRCALPHA/INVSRCALPHA, MODULATEALPHA */
#define GBH_F_ALPHA_B          0x00000100 /*  same D3D state as 0x80 */
#define GBH_F_ADDITIVE         0x00000200 /*  ONE/ONE */
#define GBH_F_VERTEX_COLOUR    0x00002000 /* keep caller's diffuse; else grey from the brightness arg */
#define GBH_F_TILE_CUSTOM_UV   0x00004000 /* DrawTile: keep caller's UVs; else 0.5..63.4999 */
#define GBH_F_LIGHTING         0x00008000 /* apply gbh_AddLight lights + ambient to diffuse */
#define GBH_F_SPRITE_RECT      0x00010000 /* DrawQuad: only v[0] x,y,z given; quad = texture w x h, implies 0x20000 */
#define GBH_F_NO_FILTER        0x00020000 /* point sampling; else bilinear */

/* A texture handle (gbh_RegisterTexture). 0x20 bytes, allocated by the DLL.
 * gta2.exe WRITES width/height/pixels directly between Lock/UnlockTexture,
 * so this layout is part of the ABI. */
typedef struct GbhTexture {
    u16   id;           /* 0x00 serial */
    u16   unk_02;       /* 0x02 */
    u16   unk_04;       /* 0x04 */
    u16   lock_state;   /* 0x06 0x100 while locked */
    void *locked_pixels;/* 0x08 = pixels while locked */
    u8    x;            /* 0x0c origin inside the 256-wide page (always 0 from RegisterTexture) */
    u8    y;            /* 0x0d */
    u16   width;        /* 0x0e texels */
    u16   height;       /* 0x10 texels */
    u8    pal_registered; /* 0x12 1 once its palette was registered (also the u/v divisor) */
    u8    tflags;       /* 0x13 1 locked, 0x40 cached without alpha, 0x80 translucent-capable */
    u8   *pixels;       /* 0x14 8-bit indices, row pitch 256 bytes (GTA2 style page layout) */
    u16  *palette16;    /* 0x18 converted palette: [0..255] opaque fmt, [256..511] alpha fmt */
    void *cache;        /* 0x1c texture cache slot holding the uploaded copy, or NULL */
} GbhTexture;

/* gbh_AddLight argument. 0x14 bytes. */
typedef struct GbhLight {
    u32   packed;       /* 0x00 bits 0-7 intensity, 8-15 radius, 16-17 type (1 = point; others skipped) */
    float x;            /* 0x04 world */
    float y;            /* 0x08 */
    float z;            /* 0x0c */
    u32   rgb;          /* 0x10 0x00RRGGBB */
} GbhLight;

/* d3ddll image table entry (gbh_InitImageTable / LoadImage / BlitImage). 0x10 bytes. */
typedef struct GbhImage {
    int   in_use;       /* 0x00 */
    int   width;        /* 0x04 */
    int   height;       /* 0x08 */
    void *surface;      /* 0x0c IDirectDrawSurface4* offscreen copy, screen pixel format */
} GbhImage;

/* d3ddll palette slot (internal array at 0xe13e00, 12 bytes each). */
typedef struct GbhPaletteSlot {
    u32  *source;       /* 0x00 caller's palette (u32 0x00RRGGBB, stride 64 dwords) */
    u16  *converted;    /* 0x04 512 u16: opaque texture format, then alpha texture format */
    int   registered;   /* 0x08 1 */
} GbhPaletteSlot;

/* gbh_GetGlobals() result (d3ddll .data 0xe43ea0): per-frame statistics. */
typedef struct GbhGlobals {
    int   polys_drawn;     /* 0x00 triangles (a quad counts 2) */
    int   texture_changes; /* 0x04 */
    int   cache_flushes;   /* 0x08 */
    int   frame_time;      /* 0x0c */
    int   cache_size[12];  /* 0x10 slots per cache page size */
} GbhGlobals;

/* gbh_LoadImage input: an in-memory .tga file: uncompressed true colour
 * (type 2), no colour map, 16 bpp (A1R5G5B5), bottom-up. Checked: b[1]==0,
 * b[2]==2, b[16]==16. width = u16 @12, height = u16 @14, pixels at 18+idlen. */
