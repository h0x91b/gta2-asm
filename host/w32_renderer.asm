; w32_renderer.asm — the two renderer plugins' export tables, dmavideo.dll (Vid_*) and
; d3ddll.dll (gbh_*). The handlers are 64-bit host C on SDL3's SDL_Renderer
; (host/c/renderer.c: SDL setup, Vid_*, the frame loop; host/c/renderer_gbh.c: gbh_*),
; each an import handler uint64_t f(const uint32_t *args) (docs/host-c.md, "Import shims
; in C"); the stdcall argument bytes here are what common32 pops. API:
; docs/renderer-api.md; design and gaps: docs/renderer-sdl.md. The few exports the game
; never calls resolve to h_silent (return 0, log the first call), the deliberate no-ops
; to h_ret0.

extern _vid_check_mode, _vid_clear_screen, _vid_close_screen, _vid_free_surface
extern _vid_lock_quiet, _vid_find_device, _vid_find_first_mode, _vid_find_mode
extern _vid_find_next_mode, _vid_flip_buffers, _vid_get_surface, _vid_init_dll
extern _vid_init_sys, _vid_set_device, _vid_set_gamma, _vid_set_mode
extern _vid_shutdown_sys, _gbh_add_light, _gbh_assign_palette, _gbh_begin_scene
extern _gbh_blit_image, _gbh_draw_flat_rect, _gbh_draw_quad, _gbh_draw_tile
extern _gbh_draw_triangle, _gbh_end_scene, _gbh_free_image_table, _gbh_free_palette
extern _gbh_free_texture, _gbh_get_globals, _gbh_init, _gbh_init_dll
extern _gbh_init_image_table, _gbh_load_image, _gbh_lock_texture, _gbh_register_palette
extern _gbh_register_texture, _gbh_reset_lights, _gbh_set_ambient, _gbh_set_camera
extern _gbh_set_window, _gbh_unlock_texture

section .data
align 8
shimtab_dmavideo:
    dq s_dmavideo
    SHIM "Vid_CheckMode", 16, _vid_check_mode
    SHIM "Vid_ClearScreen", 32, _vid_clear_screen
    SHIM "Vid_CloseScreen", 4, _vid_close_screen
    SHIM "Vid_DisableWrites", 4, _vid_free_surface
    SHIM "Vid_EnableWrites", 4, _vid_lock_quiet
    SHIM "Vid_FindDevice", 8, _vid_find_device
    SHIM "Vid_FindFirstMode", 8, _vid_find_first_mode
    SHIM "Vid_FindMode", 8, _vid_find_mode
    SHIM "Vid_FindNextMode", 4, _vid_find_next_mode
    SHIM "Vid_FlipBuffers", 4, _vid_flip_buffers
    SHIM "Vid_FreeSurface", 4, _vid_free_surface
    SHIM "Vid_GetSurface", 4, _vid_get_surface
    SHIM "Vid_GetVersion", 0, h_silent
    SHIM "Vid_GrabSurface", 4, _vid_get_surface
    SHIM "Vid_InitDLL", 8, _vid_init_dll
    SHIM "Vid_Init_SYS", 8, _vid_init_sys
    SHIM "Vid_ReleaseSurface", 4, _vid_free_surface
    SHIM "Vid_SetDevice", 8, _vid_set_device
    SHIM "Vid_SetGamma", 16, _vid_set_gamma
    SHIM "Vid_SetMode", 12, _vid_set_mode
    SHIM "Vid_ShutDown_SYS", 4, _vid_shutdown_sys
    SHIM "Vid_WindowProc", 20, h_ret0
    dq 0
shimtab_d3ddll:
    dq s_d3ddll
    SHIM "ConvertColourBank", 4, h_ret0
    SHIM "DrawLine", 20, h_ret0
    SHIM "MakeScreenTable", 12, h_ret0
    SHIM "SetShadeTableA", 20, h_ret0
    SHIM "gbh_AddLight", 4, _gbh_add_light
    SHIM "gbh_AssignPalette", 8, _gbh_assign_palette
    SHIM "gbh_BeginLevel", 0, h_ret0
    SHIM "gbh_BeginScene", 0, _gbh_begin_scene
    SHIM "gbh_BlitBuffer", 24, h_ret0
    SHIM "gbh_BlitImage", 28, _gbh_blit_image
    SHIM "gbh_CloseDLL", 0, h_ret0
    SHIM "gbh_CloseScreen", 4, _vid_close_screen
    SHIM "gbh_Convert16BitGraphic", 8, h_silent
    SHIM "gbh_ConvertColour", 12, h_silent
    SHIM "gbh_DrawFlatRect", 8, _gbh_draw_flat_rect
    SHIM "gbh_DrawQuad", 16, _gbh_draw_quad
    SHIM "gbh_DrawQuadClipped", 20, h_silent
    SHIM "gbh_DrawTile", 16, _gbh_draw_tile
    SHIM "gbh_DrawTilePart", 16, _gbh_draw_tile
    SHIM "gbh_DrawTriangle", 16, _gbh_draw_triangle
    SHIM "gbh_EndLevel", 0, h_ret0
    SHIM "gbh_EndScene", 0, _gbh_end_scene
    SHIM "gbh_FreeImageTable", 0, _gbh_free_image_table
    SHIM "gbh_FreePalette", 4, _gbh_free_palette
    SHIM "gbh_FreeTexture", 4, _gbh_free_texture
    SHIM "gbh_GetGlobals", 0, _gbh_get_globals
    SHIM "gbh_GetUsedCache", 4, h_ret0
    SHIM "gbh_Init", 4, _gbh_init
    SHIM "gbh_InitDLL", 4, _gbh_init_dll
    SHIM "gbh_InitImageTable", 4, _gbh_init_image_table
    SHIM "gbh_LoadImage", 4, _gbh_load_image
    SHIM "gbh_LockTexture", 4, _gbh_lock_texture
    SHIM "gbh_Plot", 16, h_ret0
    SHIM "gbh_PrintBitmap", 4, h_silent
    SHIM "gbh_RegisterPalette", 8, _gbh_register_palette
    SHIM "gbh_RegisterTexture", 20, _gbh_register_texture
    SHIM "gbh_ResetLights", 0, _gbh_reset_lights
    SHIM "gbh_SetAmbient", 4, _gbh_set_ambient
    SHIM "gbh_SetCamera", 16, _gbh_set_camera
    SHIM "gbh_SetColourDepth", 0, h_ret0
    SHIM "gbh_SetWindow", 16, _gbh_set_window
    SHIM "gbh_UnlockTexture", 4, _gbh_unlock_texture
    dq 0

section .rodata
s_dmavideo:     db "dmavideo", 0
s_d3ddll:       db "d3ddll", 0
section .text
