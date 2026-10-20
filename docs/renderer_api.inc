; GTA2 renderer plugin ABI (dmavideo.dll Vid_* + d3ddll.dll gbh_*), NASM form.
; Same content as docs/renderer_api.h; explanation in docs/renderer-api.md.
; All exports are __stdcall (callee pops; args on the stack, EAX return).
; Addresses: dmavideo base 0x1000000, d3ddll base 0xE00000, gta2.exe 0x3F0000.

; ------------------------------------------------------------- structures

struc VidMode                   ; 0x40
    .id             resd 1      ; 0x00
    .device_id      resd 1      ; 0x04
    .width          resd 1      ; 0x08
    .height         resd 1      ; 0x0c
    .pitch          resd 1      ; 0x10
    .bpp            resd 1      ; 0x14
    .r_shift        resd 1      ; 0x18
    .r_bits         resd 1      ; 0x1c
    .g_shift        resd 1      ; 0x20
    .g_bits         resd 1      ; 0x24
    .b_shift        resd 1      ; 0x28
    .b_bits         resd 1      ; 0x2c
    .x_shift        resd 1      ; 0x30
    .x_bits         resd 1      ; 0x34
    .next           resd 1      ; 0x38
    .valid          resd 1      ; 0x3c
endstruc

struc VidDevice                 ; 0x2c + strings
    .id             resd 1      ; 0x00 1 = primary
    .flags          resd 1      ; 0x04 bit0 = can render windowed
    .description    resd 1      ; 0x08
    .name           resd 1      ; 0x0c
    .next           resd 1      ; 0x10
    .guid_ptr       resd 1      ; 0x14
    .guid           resd 4      ; 0x18
    .vid_mem        resd 1      ; 0x28
endstruc

VID_F_LOCKED        equ 0x00000001
VID_F_WRITES        equ 0x00000002
VID_F_TRIPLE        equ 0x00000010
VID_F_FLIPCHAIN     equ 0x00000020
VID_F_3DDEVICE      equ 0x00000040
VID_F_SYSMEM_BACK   equ 0x00000080
VID_F_MODECHANGE    equ 0x00000100
VID_F_NOVSYNC       equ 0x00000200
VID_F_LOST          equ 0x10000000
VID_MODE_WINDOWED   equ -2

struc VidCtx                    ; 0x4c4
    .one            resd 1      ; 0x000
    .flags          resd 1      ; 0x004 VID_F_*      (game reads/writes)
    .found_width    resd 1      ; 0x008
    .found_height   resd 1      ; 0x00c
    .found_bpp      resd 1      ; 0x010
    .next_mode_id   resd 1      ; 0x014
    .next_device_id resd 1      ; 0x018
    .num_modes      resd 1      ; 0x01c              (game reads)
    .num_devices    resd 1      ; 0x020
    .modes          resd 1      ; 0x024
    .modes_tail     resd 1      ; 0x028
    .devices        resd 1      ; 0x02c
    .devices_tail   resd 1      ; 0x030
    .device_id      resd 1      ; 0x034
    .unk_38         resd 1      ; 0x038
    .find_iter      resd 1      ; 0x03c
    .mode_id        resd 1      ; 0x040 -2 windowed  (game reads)
    .unk_44         resd 1      ; 0x044
    .width          resd 1      ; 0x048              (game reads)
    .height         resd 1      ; 0x04c              (game reads)
    .surface        resd 1      ; 0x050 pixels       (game reads)
    .pitch          resd 1      ; 0x054 bytes/row    (game reads)
    .r_shift        resd 1      ; 0x058
    .r_bits         resd 1      ; 0x05c              (game reads: 5 => 555 for Bink)
    .g_shift        resd 1      ; 0x060
    .g_bits         resd 1      ; 0x064              (game reads)
    .b_shift        resd 1      ; 0x068
    .b_bits         resd 1      ; 0x06c              (game reads)
    .x_shift        resd 1      ; 0x070
    .x_bits         resd 1      ; 0x074
    .hinstance      resd 1      ; 0x078
    .hmodule        resd 1      ; 0x07c
    .fullscreen     resd 1      ; 0x080
    .slot_table     resd 1      ; 0x084
    .hresult        resd 1      ; 0x088
    .ddraw          resd 1      ; 0x08c
    .unk_090        resb 0x90   ; 0x090
    .ddraw4         resd 1      ; 0x120
    .unk_124        resb 0x10   ; 0x124
    .primary        resd 1      ; 0x134
    .back           resd 1      ; 0x138
    .lock_desc      resb 0x7c   ; 0x13c DDSURFACEDESC2
    .clipper        resd 1      ; 0x1b8
    .unk_1bc        resb 0xc    ; 0x1bc
    .hal_caps       resb 0x17c  ; 0x1c8
    .hel_caps       resb 0x17c  ; 0x344
    .hwnd           resd 1      ; 0x4c0
endstruc

struc GbhVertex                 ; 0x20 (= D3DTLVERTEX)
    .x              resd 1      ; 0x00 float
    .y              resd 1      ; 0x04 float
    .z              resd 1      ; 0x08 float
    .rhw            resd 1      ; 0x0c float (DLL writes = z)
    .diffuse        resd 1      ; 0x10 ARGB
    .specular       resd 1      ; 0x14
    .u              resd 1      ; 0x18 float, texels
    .v              resd 1      ; 0x1c float, texels
endstruc

GBH_F_TILE_FLIPX     equ 0x00000008
GBH_F_TILE_FLIPY     equ 0x00000010
GBH_F_TILE_ROT_MASK  equ 0x00000060
GBH_F_ALPHA_MASK     equ 0x00000380
GBH_F_ALPHA_A        equ 0x00000080
GBH_F_ALPHA_B        equ 0x00000100
GBH_F_ADDITIVE       equ 0x00000200
GBH_F_VERTEX_COLOUR  equ 0x00002000
GBH_F_TILE_CUSTOM_UV equ 0x00004000
GBH_F_LIGHTING       equ 0x00008000
GBH_F_SPRITE_RECT    equ 0x00010000
GBH_F_NO_FILTER      equ 0x00020000

struc GbhTexture                ; 0x20, game writes .width/.height/.pixels
    .id             resw 1      ; 0x00
    .unk_02         resw 1      ; 0x02
    .unk_04         resw 1      ; 0x04
    .lock_state     resw 1      ; 0x06
    .locked_pixels  resd 1      ; 0x08
    .x              resb 1      ; 0x0c
    .y              resb 1      ; 0x0d
    .width          resw 1      ; 0x0e
    .height         resw 1      ; 0x10
    .pal_registered resb 1      ; 0x12
    .tflags         resb 1      ; 0x13
    .pixels         resd 1      ; 0x14 8bpp, pitch 256
    .palette16      resd 1      ; 0x18
    .cache          resd 1      ; 0x1c
endstruc

struc GbhLight                  ; 0x14
    .packed         resd 1      ; 0x00 intensity | radius<<8 | type<<16
    .x              resd 1      ; 0x04 float
    .y              resd 1      ; 0x08 float
    .z              resd 1      ; 0x0c float
    .rgb            resd 1      ; 0x10
endstruc

struc GbhImage                  ; 0x10
    .in_use         resd 1
    .width          resd 1
    .height         resd 1
    .surface        resd 1
endstruc

struc GbhGlobals                ; returned by gbh_GetGlobals
    .polys_drawn     resd 1     ; 0x00
    .texture_changes resd 1     ; 0x04
    .cache_flushes   resd 1     ; 0x08
    .frame_time      resd 1     ; 0x0c
    .cache_size      resd 12    ; 0x10
endstruc

; gbh_BlitImage / gbh_LoadImage results
GBH_IMG_OK          equ 0
GBH_IMG_BAD_HANDLE  equ -1
GBH_IMG_BAD_RECT    equ -2      ; also LoadImage: not a 16bpp type-2 TGA
GBH_IMG_OFFSCREEN   equ -3      ; also LoadImage: surface create/lock failed
GBH_IMG_BLIT_FAIL   equ -4
GBH_IMG_LOST        equ -10     ; surface lost: game reloads the TGA and blits again

; ------------------------------------------------------------- export table
; EXPORT name, ordinal, stdcall arg bytes, game slot in gta2.exe (0 = not imported by gta2.exe)
; "used" = gta2.exe calls it outside its loader (raw xref scan of the slot).

%macro RENDERER_EXPORTS 0
; dmavideo.dll (22, ordinals = alphabetical)
    EXPORT Vid_CheckMode,        1, 16, 0x595024 ; used
    EXPORT Vid_ClearScreen,      2, 32, 0x595064 ; used
    EXPORT Vid_CloseScreen,      3,  4, 0x59503c ; used (d3ddll hooks this slot)
    EXPORT Vid_DisableWrites,    4,  4, 0x595058
    EXPORT Vid_EnableWrites,     5,  4, 0x595054
    EXPORT Vid_FindDevice,       6,  8, 0x595034 ; used
    EXPORT Vid_FindFirstMode,    7,  8, 0x59502c
    EXPORT Vid_FindMode,         8,  8, 0x595028
    EXPORT Vid_FindNextMode,     9,  4, 0x595030
    EXPORT Vid_FlipBuffers,     10,  4, 0x595044 ; used
    EXPORT Vid_FreeSurface,     11,  4, 0x595060 ; used (d3ddll hooks this slot)
    EXPORT Vid_GetSurface,      12,  4, 0x59505c ; used (d3ddll hooks this slot)
    EXPORT Vid_GetVersion,      13,  0, 0x59501c
    EXPORT Vid_GrabSurface,     14,  4, 0x59504c
    EXPORT Vid_InitDLL,         15,  8, 0x59506c ; used (by the loader itself)
    EXPORT Vid_Init_SYS,        16,  8, 0x595020 ; used
    EXPORT Vid_ReleaseSurface,  17,  4, 0x595048
    EXPORT Vid_SetDevice,       18,  8, 0x595038 ; used
    EXPORT Vid_SetGamma,        19, 16, 0x595070 ; used
    EXPORT Vid_SetMode,         20, 12, 0x595040 ; used (d3ddll hooks this slot)
    EXPORT Vid_ShutDown_SYS,    21,  4, 0x595050 ; used
    EXPORT Vid_WindowProc,      22, 20, 0x595068 ; used
; d3ddll.dll (42, ordinals = alphabetical; two pairs share one address)
    EXPORT ConvertColourBank,    1,  4, 0x595328 ; used (stub)
    EXPORT DrawLine,             2, 20, 0x67535c ; stub
    EXPORT MakeScreenTable,      3, 12, 0x595324 ; used
    EXPORT SetShadeTableA,       4, 20, 0x59532c ; stub
    EXPORT gbh_AddLight,         5,  4, 0x5952f0 ; used
    EXPORT gbh_AssignPalette,    6,  8, 0x595308 ; used
    EXPORT gbh_BeginLevel,       7,  0, 0x59531c ; stub, = EndLevel
    EXPORT gbh_BeginScene,       8,  0, 0x595314 ; used
    EXPORT gbh_BlitBuffer,       9, 24, 0x595340 ; stub
    EXPORT gbh_BlitImage,       10, 28, 0x59533c ; used (frontend)
    EXPORT gbh_CloseDLL,        11,  0, 0x5952b0 ; used
    EXPORT gbh_CloseScreen,     12,  4, 0        ; installed into the Vid_CloseScreen slot by gbh_InitDLL
    EXPORT gbh_Convert16BitGraphic, 13, 8, 0     ; not imported
    EXPORT gbh_ConvertColour,   14, 12, 0x5952e0
    EXPORT gbh_DrawFlatRect,    15,  8, 0x5952cc ; used
    EXPORT gbh_DrawQuad,        16, 16, 0x5952c4 ; used (frontend text/sprites)
    EXPORT gbh_DrawQuadClipped, 17, 20, 0x5952c8
    EXPORT gbh_DrawTile,        18, 16, 0x5952bc ; used (= DrawTilePart)
    EXPORT gbh_DrawTilePart,    19, 16, 0x5952c0
    EXPORT gbh_DrawTriangle,    20, 16, 0x5952d0 ; used
    EXPORT gbh_EndLevel,        21,  0, 0x595320 ; stub
    EXPORT gbh_EndScene,        22,  0, 0x595318 ; used
    EXPORT gbh_FreeImageTable,  23,  0, 0x595334 ; used
    EXPORT gbh_FreePalette,     24,  4, 0x595304 ; used
    EXPORT gbh_FreeTexture,     25,  4, 0x5952fc ; used
    EXPORT gbh_GetGlobals,      26,  0, 0x5952b8 ; used
    EXPORT gbh_GetUsedCache,    27,  4, 0x5952f8 ; used (debug display)
    EXPORT gbh_Init,            28,  4, 0x5952ac ; used
    EXPORT gbh_InitDLL,         29,  4, 0x5952a8 ; used
    EXPORT gbh_InitImageTable,  30,  4, 0x595330 ; used
    EXPORT gbh_LoadImage,       31,  4, 0x595338 ; used
    EXPORT gbh_LockTexture,     32,  4, 0x59530c ; used
    EXPORT gbh_Plot,            33, 16, 0x5952dc ; stub (game's debug line drawer)
    EXPORT gbh_PrintBitmap,     34,  4, 0x5952d4
    EXPORT gbh_RegisterPalette, 35,  8, 0x595300 ; used
    EXPORT gbh_RegisterTexture, 36, 20, 0x5952e4 ; used
    EXPORT gbh_ResetLights,     37,  0, 0x5952ec ; used
    EXPORT gbh_SetAmbient,      38,  4, 0x5952f4 ; used
    EXPORT gbh_SetCamera,       39, 16, 0x5952e8 ; used
    EXPORT gbh_SetColourDepth,  40,  0, 0x5952d8 ; used
    EXPORT gbh_SetWindow,       41, 16, 0x5952b4 ; used
    EXPORT gbh_UnlockTexture,   42,  4, 0x595310 ; used
%endmacro

; gta2.exe table handed to Vid_InitDLL (arg 2): 22 pointers to the slots above, in
; THIS order (not alphabetical): GetVersion, Init_SYS, CheckMode, FindDevice, SetDevice,
; FindMode, FindFirstMode, FindNextMode, CloseScreen, SetMode, FlipBuffers, ReleaseSurface,
; GrabSurface, ShutDown_SYS, EnableWrites, DisableWrites, GetSurface, FreeSurface,
; ClearScreen, WindowProc, InitDLL, SetGamma. d3ddll patches entries 8 (CloseScreen), 9 (SetMode),
; 16 (GetSurface), 17 (FreeSurface).
GTA2_VID_SLOT_TABLE equ 0x675300
GTA2_VID_CTX_PTR    equ 0x673d20  ; VidCtx* global
GTA2_HWND_PTR       equ 0x673d18  ; HWND global
