; w32_renderer.asm — the two renderer plugins, dmavideo.dll (Vid_*) and d3ddll.dll
; (gbh_*), reimplemented on SDL3's SDL_Renderer. API: docs/renderer-api.md; design and
; gaps: docs/renderer-sdl.md.
;
; Backend: one SDL_Renderer on the game's window. Everything the game draws goes into an
; ARGB8888 render-target texture (the "back buffer") of the windowed size the game lays
; itself out for (screen\window_width x window_height, at least 640x480); Vid_FlipBuffers
; presents the top-left 640x480 of it in the frontend and all of it in gameplay,
; letterboxed into the window. Next to it lives an RGB565 CPU buffer of the same size in
; low memory that Vid_GetSurface hands out (ctx->surface); when the game had it locked,
; it is uploaded and drawn into the target at gbh_BeginScene / Vid_FlipBuffers.
;   gbh_DrawQuad/Triangle/Tile -> SDL_RenderGeometry (DrawTile permutes the tile UVs
;   first; GBH_F_LIGHTING applies the gbh_AddLight point lights + ambient per vertex); 8-bit textures are expanded through
;   their palette to ARGB8888 (index 0 = transparent) and cached per GbhTexture, keyed
;   on (pixels, width, height, palette, palette generation): the game retargets
;   textures by poking those fields.
;   gbh_LoadImage/BlitImage -> one XRGB1555 texture per TGA, SDL_RenderTexture.
; Everything the game calls (frontend and gameplay) is real or a deliberate no-op; the
; few exports it never calls resolve to h_silent (return 0, log the first call) with the
; right stdcall pop.

SDL_PIXELFORMAT_XRGB1555 equ 0x15130f02
SDL_PIXELFORMAT_RGB565   equ 0x15151002
SDL_PIXELFORMAT_ARGB8888 equ 0x16362004
SDL_TEXTUREACCESS_STATIC    equ 0
SDL_TEXTUREACCESS_STREAMING equ 1
SDL_TEXTUREACCESS_TARGET    equ 2
SDL_BLENDMODE_NONE  equ 0
SDL_BLENDMODE_BLEND equ 1
SDL_BLENDMODE_ADD   equ 2
SDL_SCALEMODE_NEAREST equ 0
SDL_SCALEMODE_LINEAR  equ 1
SDL_LOGICAL_PRESENTATION_LETTERBOX equ 2

%include "../docs/renderer_api.inc"

FB_W        equ 640             ; the frontend is laid out for 640x480 (renderer-api.md §4)
FB_H        equ 480
FB_PITCH    equ FB_W * 2        ; of the one advertised mode; the CPU buffer's is r_pitch
; gta2.exe globals the back buffer follows (re/globals.csv, own analysis of 0x4caec0)
G_WINDOW_W  equ 0x673578        ; window_width: BeginFrame2D's view width when mode_id = -2
G_WINDOW_H  equ 0x6732e8        ; window_height
G_GAME      equ 0x5EB4FC        ; ptrToGame (seuko-mod memory.h): set by InitGame 0x461de0,
                                ; zeroed by DeinitGame 0x462060 -> nonzero = gameplay
                                ; (InitGame/DeinitGame: gta2-seuko-mod by izawartka,
                                ; https://github.com/izawartka/gta2-seuko-mod,
                                ; src/game/functions.h @25b1985)
MAX_TEX     equ 0x40000         ; texture cache entries (index 0 unused); wil registers 73104
MAX_PAL     equ 16384           ; palette indices
MAX_IMG     equ 64              ; image table slots (the game asks for 25)
CONV_SIZE   equ 0x100000        ; conversion scratch: 256x256x4 texels or a 640x480x2 TGA

MAX_LIGHTS  equ 1024            ; the original has no bound; the game adds a few dozen
; light record (host memory), as d3ddll keeps them at 0xe459e0 (11 dwords)
L_PACKED    equ 0
L_I         equ 4               ; intensity / 255
L_R         equ 8               ; radius / 255 * 8 (world units)
L_R2        equ 12
L_INVR      equ 16
L_X         equ 20
L_Y         equ 24
L_Z         equ 28
L_CR        equ 32              ; r, g, b / 255
L_SIZE      equ 48

; texture cache entry (host memory; GbhTexture.cache holds its index)
TCE_SDL      equ 0               ; SDL_Texture*
TCE_PIXELS   equ 8               ; key: pixels the SDL texture was built from
TCE_W        equ 12
TCE_H        equ 16
TCE_PAL      equ 20              ; palette index (AssignPalette changes it)
TCE_GEN      equ 24              ; key: pal_gen[pal] at build time
TCE_DIRTY    equ 28              ; Lock/Unlock/AssignPalette: rebuild before the next draw
TCE_SIZE     equ 32

section .text

; ---- SDL renderer entry points (dlsym'ed from the handle setup_user32 opened) ---------
%macro RFNS 0
    RFN SDL_CreateRenderer
    RFN SDL_DestroyRenderer
    RFN SDL_GetRendererName
    RFN SDL_SetRenderVSync
    RFN SDL_SetRenderLogicalPresentation
    RFN SDL_CreateTexture
    RFN SDL_DestroyTexture
    RFN SDL_UpdateTexture
    RFN SDL_SetTextureBlendMode
    RFN SDL_SetTextureScaleMode
    RFN SDL_SetRenderTarget
    RFN SDL_SetRenderDrawColor
    RFN SDL_SetRenderDrawBlendMode
    RFN SDL_RenderClear
    RFN SDL_RenderFillRect
    RFN SDL_RenderTexture
    RFN SDL_RenderGeometry
    RFN SDL_RenderPresent
    RFN SDL_RenderReadPixels
    RFN SDL_SaveBMP
    RFN SDL_DestroySurface
%endmacro

setup_renderer:
    push rbx
%macro RFN 1
    mov rdi, [sdl_lib]
    lea rsi, [%%n]
    call _dlsym
    test rax, rax
    jz .no_sym
    mov [r_%1], rax
section .rodata
%%n: db %str(%1), 0
section .text
%endmacro
    RFNS
    mov dword [tc_used], 1
    pop rbx
    ret
.no_sym:
    lea rdi, [msg_sdl_sym]
    call fail

; r_sdl_error(rdi = what): log SDL_GetError()
r_sdl_error:
    push rbx
    mov rbx, rdi
    call [sdl_SDL_GetError]
    lea rdi, [fmt_r_sdlerr]
    mov rsi, rbx
    mov rdx, rax
    xor eax, eax
    call _printf
    pop rbx
    ret

; rax = r_texture(edi = format, esi = access, edx = w, ecx = h), blend NONE, nearest
r_texture:
    push rbx
    mov r8d, ecx                ; SDL_CreateTexture(r, fmt, access, w, h)
    mov ecx, edx
    mov edx, esi
    mov esi, edi
    mov rdi, [r_renderer]
    call [r_SDL_CreateTexture]
    mov rbx, rax
    test rax, rax
    jnz .ok
    lea rdi, [s_createtex]
    call r_sdl_error
    xor eax, eax
    pop rbx
    ret
.ok:
    mov rdi, rbx
    mov esi, SDL_BLENDMODE_NONE
    call [r_SDL_SetTextureBlendMode]
    mov rdi, rbx
    mov esi, SDL_SCALEMODE_NEAREST
    call [r_SDL_SetTextureScaleMode]
    mov rax, rbx
    pop rbx
    ret

; draw the CPU buffer (ctx->surface) into the back buffer
r_upload_fb:
    sub rsp, 8
    mov rdi, [r_fbtex]
    xor esi, esi
    mov edx, [r_cpu_fb]
    mov ecx, [r_pitch]
    call [r_SDL_UpdateTexture]
    mov rdi, [r_renderer]
    mov rsi, [r_fbtex]
    xor edx, edx
    xor ecx, ecx
    call [r_SDL_RenderTexture]
    add rsp, 8
    ret

; ======================================================== dmavideo.dll (Vid_*)

vid_InitDLL:                    ; (HMODULE self, void ***slot_table) -> 0
    mov eax, [rdi]
    mov [r_vid_hmodule], eax
    mov eax, [rdi + 4]
    mov [r_vid_slots], eax
    xor eax, eax
    ret

; Vid_Init_SYS(hinst, flags) -> VidCtx*: one device (id 1, can run windowed), one mode
; (640x480x16, RGB565). Everything the game can dereference is in low memory.
vid_Init_SYS:
    HENTER
    call sdl_ensure
    mov edi, VidCtx_size
    mov esi, 16
    call low_alloc
    mov r12, rax
    mov dword [r12 + VidCtx.one], 1
    mov eax, ARG(1)
    and eax, VID_F_3DDEVICE
    or eax, VID_F_FLIPCHAIN | VID_F_NOVSYNC     ; 0x220, the original's default
    mov [r12 + VidCtx.flags], eax
    mov eax, ARG(0)
    mov [r12 + VidCtx.hinstance], eax
    mov eax, [r_vid_hmodule]
    mov [r12 + VidCtx.hmodule], eax
    mov eax, [r_vid_slots]
    mov [r12 + VidCtx.slot_table], eax
    call vid_fill_format
    ; device 1
    mov edi, VidDevice_size
    mov esi, 16
    call low_alloc
    mov r13, rax
    mov dword [r13 + VidDevice.id], 1
    mov dword [r13 + VidDevice.flags], 1
    lea rdi, [s_vid_devname]
    call low_strdup
    mov [r13 + VidDevice.description], eax
    mov [r13 + VidDevice.name], eax
    mov dword [r13 + VidDevice.vid_mem], 64 << 20
    mov [r12 + VidCtx.devices], r13d
    mov [r12 + VidCtx.devices_tail], r13d
    mov dword [r12 + VidCtx.num_devices], 1
    mov dword [r12 + VidCtx.next_device_id], 2
    ; mode 1
    mov edi, VidMode_size
    mov esi, 16
    call low_alloc
    mov r14, rax
    mov dword [r14 + VidMode.id], 1
    mov dword [r14 + VidMode.device_id], 1
    mov dword [r14 + VidMode.width], FB_W
    mov dword [r14 + VidMode.height], FB_H
    mov dword [r14 + VidMode.pitch], FB_PITCH
    mov dword [r14 + VidMode.bpp], 16
    mov dword [r14 + VidMode.r_shift], 11
    mov dword [r14 + VidMode.r_bits], 5
    mov dword [r14 + VidMode.g_shift], 5
    mov dword [r14 + VidMode.g_bits], 6
    mov dword [r14 + VidMode.b_shift], 0
    mov dword [r14 + VidMode.b_bits], 5
    mov dword [r14 + VidMode.valid], 1
    mov [r12 + VidCtx.modes], r14d
    mov [r12 + VidCtx.modes_tail], r14d
    mov dword [r12 + VidCtx.num_modes], 1
    mov dword [r12 + VidCtx.next_mode_id], 2
    mov [r_ctx], r12d
    lea rdi, [fmt_vid_init]
    mov esi, r12d
    xor eax, eax
    call _printf
    mov eax, r12d
    HRET

; vid_fill_format(r12 = ctx): RGB565 + the 640x480 geometry
vid_fill_format:
    mov dword [r12 + VidCtx.width], FB_W
    mov dword [r12 + VidCtx.height], FB_H
    mov dword [r12 + VidCtx.r_shift], 11
    mov dword [r12 + VidCtx.r_bits], 5
    mov dword [r12 + VidCtx.g_shift], 5
    mov dword [r12 + VidCtx.g_bits], 6
    mov dword [r12 + VidCtx.b_shift], 0
    mov dword [r12 + VidCtx.b_bits], 5
    mov dword [r12 + VidCtx.x_shift], 0
    mov dword [r12 + VidCtx.x_bits], 0
    ret

; Vid_CheckMode(ctx, w, h, bpp) -> mode id or 0
vid_CheckMode:
    mov ecx, [rdi]
    mov ecx, [rcx + VidCtx.modes]
.walk:
    test ecx, ecx
    jz .none
    mov eax, [rdi + 4]
    cmp eax, [rcx + VidMode.width]
    jne .next
    mov eax, [rdi + 8]
    cmp eax, [rcx + VidMode.height]
    jne .next
    mov eax, [rdi + 12]
    cmp eax, [rcx + VidMode.bpp]
    jne .next
    mov edx, [rdi]
    mov eax, [rcx + VidMode.width]
    mov [rdx + VidCtx.found_width], eax
    mov eax, [rcx + VidMode.height]
    mov [rdx + VidCtx.found_height], eax
    mov eax, [rcx + VidMode.bpp]
    mov [rdx + VidCtx.found_bpp], eax
    mov eax, [rcx + VidMode.id]
    ret
.next:
    mov ecx, [rcx + VidMode.next]
    jmp .walk
.none:
    xor eax, eax
    ret

; Vid_FindMode(ctx, id) -> VidMode* or 0
vid_FindMode:
    mov ecx, [rdi]
    mov ecx, [rcx + VidCtx.modes]
.walk:
    test ecx, ecx
    jz .none
    mov eax, [rdi + 4]
    cmp eax, [rcx + VidMode.id]
    je .found
    mov ecx, [rcx + VidMode.next]
    jmp .walk
.found:
    mov eax, ecx
    ret
.none:
    xor eax, eax
    ret

; Vid_FindFirstMode(ctx, bpp) / Vid_FindNextMode(ctx) -> mode id or 0 (iterator in find_iter)
vid_FindFirstMode:
    mov edx, [rdi]
    mov eax, [rdi + 4]
    mov [r_find_bpp], eax
    mov ecx, [rdx + VidCtx.modes]
    jmp vid_find_from
vid_FindNextMode:
    mov edx, [rdi]
    mov ecx, [rdx + VidCtx.find_iter]
    test ecx, ecx
    jz vid_find_from
    mov ecx, [rcx + VidMode.next]
vid_find_from:                  ; edx = ctx, ecx = first candidate
    test ecx, ecx
    jz .none
    mov eax, [rcx + VidMode.bpp]
    cmp eax, [r_find_bpp]
    je .found
    mov ecx, [rcx + VidMode.next]
    jmp vid_find_from
.found:
    mov [rdx + VidCtx.find_iter], ecx
    mov eax, [rcx + VidMode.id]
    ret
.none:
    mov dword [rdx + VidCtx.find_iter], 0
    xor eax, eax
    ret

; Vid_FindDevice(ctx, id) -> VidDevice* or 0
vid_FindDevice:
    mov ecx, [rdi]
    mov ecx, [rcx + VidCtx.devices]
.walk:
    test ecx, ecx
    jz .none
    mov eax, [rdi + 4]
    cmp eax, [rcx + VidDevice.id]
    je .found
    mov ecx, [rcx + VidDevice.next]
    jmp .walk
.found:
    mov eax, ecx
    ret
.none:
    xor eax, eax
    ret

vid_SetDevice:                  ; (ctx, id) -> 0
    mov ecx, [rdi]
    mov eax, [rdi + 4]
    mov [rcx + VidCtx.device_id], eax
    xor eax, eax
    ret

vid_CloseScreen:                ; (ctx): the renderer survives mode changes
    mov ecx, [rdi]
    mov dword [rcx + VidCtx.mode_id], 0
    ret

; Vid_SetMode(ctx, hwnd, mode_id) -> 0 ok / 1 fail. First call creates the renderer on
; the game's SDL window. The back buffer is sized for what the game will lay out: windowed
; (-2) = window_width x window_height (BeginFrame2D 0x4caec0 reads them for the view),
; anything else = the 640x480 mode; never smaller than the 640x480 frontend. A later call
; with another size recreates the back buffer and the CPU buffer.
vid_SetMode:
    HENTER 16
    mov r12d, ARG(0)
    mov eax, FB_W
    mov ecx, FB_H
    cmp ARG(2), VID_MODE_WINDOWED
    jne .gsize
    mov edx, [abs G_WINDOW_W]
    mov esi, [abs G_WINDOW_H]
    test edx, edx
    jle .gsize
    test esi, esi
    jle .gsize
    mov eax, edx
    mov ecx, esi
.gsize:
    mov [r_gw], eax
    mov [r_gh], ecx
    mov r13d, FB_W                  ; target = max(game size, 640x480)
    cmp eax, r13d
    cmovg r13d, eax
    mov r14d, FB_H
    cmp ecx, r14d
    cmovg r14d, ecx
    cmp qword [r_renderer], 0
    jne .have_rend
    mov edi, ARG(1)
    call win_get
    test rax, rax
    jnz .have_win
    mov edi, [main_hwnd]
    call win_get
    test rax, rax
    jz .fail
.have_win:
    mov rdi, [rax + WN_SDL]
    xor esi, esi
    call [r_SDL_CreateRenderer]
    test rax, rax
    jz .sdl_fail
    mov [r_renderer], rax
    mov rdi, rax
    mov esi, 1
    call [r_SDL_SetRenderVSync]
    mov rdi, [r_renderer]
    mov esi, SDL_BLENDMODE_NONE
    call [r_SDL_SetRenderDrawBlendMode]
    mov rdi, [r_renderer]
    call [r_SDL_GetRendererName]
    lea rdi, [fmt_vid_renderer]
    mov rsi, rax
    xor eax, eax
    call _printf
.have_rend:
    cmp r13d, [r_tw]
    jne .make
    cmp r14d, [r_th]
    je .fill
.make:
    mov edi, r13d
    mov esi, r14d
    call r_make_buffers
    test eax, eax
    jz .fail
.fill:
    call vid_fill_format
    mov eax, ARG(2)
    mov [r12 + VidCtx.mode_id], eax
    xor ecx, ecx
    cmp eax, VID_MODE_WINDOWED
    setne cl
    mov [r12 + VidCtx.fullscreen], ecx
    mov eax, ARG(1)
    mov [r12 + VidCtx.hwnd], eax
    lea rdi, [fmt_vid_setmode]
    mov esi, ARG(2)
    mov edx, ARG(1)
    mov ecx, [r_gw]
    mov r8d, [r_gh]
    mov r9d, [r_tw]
    mov eax, [r_th]
    mov [rsp], rax
    xor eax, eax
    call _printf
    xor eax, eax
    HRET
.sdl_fail:
    lea rdi, [s_createrend]
    call r_sdl_error
.fail:
    mov eax, 1
    HRET

; eax = r_make_buffers(edi = w, esi = h): (re)create the back buffer, the RGB565 streaming
; texture and the CPU buffer at w x h, leave the back buffer as the render target, cleared
; to black. 0 on failure. A replaced CPU buffer stays allocated (low arena, no free).
r_make_buffers:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov rdi, [r_renderer]
    xor esi, esi
    call [r_SDL_SetRenderTarget]
    mov rdi, [r_target]
    test rdi, rdi
    jz .no_old_target
    call [r_SDL_DestroyTexture]
.no_old_target:
    mov rdi, [r_fbtex]
    test rdi, rdi
    jz .no_old_fbtex
    call [r_SDL_DestroyTexture]
.no_old_fbtex:
    mov qword [r_target], 0
    mov qword [r_fbtex], 0
    mov edi, SDL_PIXELFORMAT_ARGB8888
    mov esi, SDL_TEXTUREACCESS_TARGET
    mov edx, r12d
    mov ecx, r13d
    call r_texture
    test rax, rax
    jz .fail
    mov [r_target], rax
    mov rdi, rax
    mov esi, SDL_SCALEMODE_LINEAR
    call [r_SDL_SetTextureScaleMode]
    mov edi, SDL_PIXELFORMAT_RGB565
    mov esi, SDL_TEXTUREACCESS_STREAMING
    mov edx, r12d
    mov ecx, r13d
    call r_texture
    test rax, rax
    jz .fail
    mov [r_fbtex], rax
    lea eax, [r12 + r12]
    mov [r_pitch], eax
    mov edi, eax
    imul edi, r13d
    mov esi, 16
    call low_alloc                  ; zeroed: the arena is fresh anonymous memory
    mov [r_cpu_fb], eax
    mov [r_tw], r12d
    mov [r_th], r13d
    mov dword [r_pw], 0             ; re-set the window's logical size at the next flip
    mov rdi, [r_renderer]
    mov rsi, [r_target]
    call [r_SDL_SetRenderTarget]
    mov rdi, [r_renderer]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    mov r8d, 255
    call [r_SDL_SetRenderDrawColor]
    mov rdi, [r_renderer]
    call [r_SDL_RenderClear]
    lea rdi, [fmt_vid_buffers]
    mov esi, r12d
    mov edx, r13d
    xor eax, eax
    call _printf
    mov eax, 1
    jmp .out
.fail:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; eax, edx = r_present_size: the part of the back buffer a flip shows. Gameplay
; (ptrToGame set) is laid out for the windowed size, the frontend for 640x480.
r_present_size:
    mov eax, FB_W
    mov edx, FB_H
    cmp dword [abs G_GAME], 0
    je .out
    mov eax, [r_gw]
    mov edx, [r_gh]
.out:
    ret

vid_SetGamma:                   ; (ctx, r, g, b) -> 0 (no gamma ramp yet)
    xor eax, eax
    ret

; Vid_GetSurface(ctx) = GrabSurface + EnableWrites: ctx->surface/pitch = the CPU buffer
vid_GetSurface:
    mov byte [r_fb_touched], 1
vid_lock_quiet:                 ; same, without marking the buffer as written
    mov ecx, [rdi]
    mov eax, [r_cpu_fb]
    test eax, eax
    jz .fail
    mov [rcx + VidCtx.surface], eax
    mov edx, [r_pitch]
    mov [rcx + VidCtx.pitch], edx
    or dword [rcx + VidCtx.flags], VID_F_LOCKED | VID_F_WRITES
    xor eax, eax
    ret
.fail:
    mov eax, 1
    ret

vid_FreeSurface:                ; (ctx) = DisableWrites + ReleaseSurface
    mov ecx, [rdi]
    mov dword [rcx + VidCtx.surface], 0
    and dword [rcx + VidCtx.flags], ~(VID_F_LOCKED | VID_F_WRITES)
    xor eax, eax
    ret

; Vid_FlipBuffers(ctx): present the back buffer (r_present_size of it). --shot=PATH saves
; that part as BMP and --frames=N exits (status 0) after N flips.
vid_FlipBuffers:
    HENTER 16
    cmp qword [r_renderer], 0
    je .out
    cmp byte [r_fb_touched], 0
    je .fb_done
    mov byte [r_fb_touched], 0
    call r_upload_fb
.fb_done:
    inc dword [r_frames]
    mov edi, [r_frames]
    call input_keys_frame           ; --keys=FRAME:KEY,...
    mov eax, [r_frames]
    cmp eax, 1
    je .stats
    xor edx, edx
    mov ecx, 120
    div ecx
    test edx, edx
    jnz .no_stats
.stats:
    lea rdi, [fmt_vid_flip]
    mov esi, [r_frames]
    mov edx, [r_quads]
    mov ecx, [r_blits]
    mov r8d, [r_tex_builds]
    mov r9d, [r_texs]
    xor eax, eax
    call _printf
.no_stats:
    mov eax, [r_exit_frame]
    test eax, eax
    jz .present
    cmp [r_frames], eax
    jb .present
    cmp qword [r_shot_path], 0
    je .present
    call r_save_shot
.present:
    mov rdi, [r_renderer]
    xor esi, esi
    call [r_SDL_SetRenderTarget]
    call r_present_size
    cmp eax, [r_pw]
    jne .logical
    cmp edx, [r_ph]
    je .logical_ok
.logical:                           ; window target: that size, letterboxed
    mov [r_pw], eax
    mov [r_ph], edx
    mov rdi, [r_renderer]
    mov esi, eax
    mov ecx, SDL_LOGICAL_PRESENTATION_LETTERBOX
    call [r_SDL_SetRenderLogicalPresentation]
    lea rdi, [fmt_vid_present]
    mov esi, [r_pw]
    mov edx, [r_ph]
    mov ecx, [r_frames]
    xor eax, eax
    call _printf
.logical_ok:
    mov rdi, [r_renderer]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    mov r8d, 255
    call [r_SDL_SetRenderDrawColor]
    mov rdi, [r_renderer]
    call [r_SDL_RenderClear]
    mov dword [rsp], 0              ; SDL_FRect src = {0, 0, pw, ph}
    mov dword [rsp + 4], 0
    cvtsi2ss xmm0, dword [r_pw]
    movss [rsp + 8], xmm0
    cvtsi2ss xmm0, dword [r_ph]
    movss [rsp + 12], xmm0
    mov rdi, [r_renderer]
    mov rsi, [r_target]
    mov rdx, rsp
    xor ecx, ecx
    call [r_SDL_RenderTexture]
    mov rdi, [r_renderer]
    call [r_SDL_RenderPresent]
    mov rdi, [r_renderer]
    mov rsi, [r_target]
    call [r_SDL_SetRenderTarget]
    mov eax, [r_exit_frame]
    test eax, eax
    jz .out
    cmp [r_frames], eax
    jb .out
    lea rdi, [fmt_vid_exit]
    mov esi, [r_frames]
    xor eax, eax
    call _printf
    xor edi, edi
    call _exit
.out:
    HRET

; save the presented part of the back buffer (current render target) to [r_shot_path]
r_save_shot:
    push rbx
    sub rsp, 16
    call r_present_size
    mov dword [rsp], 0              ; SDL_Rect {0, 0, w, h}
    mov dword [rsp + 4], 0
    mov [rsp + 8], eax
    mov [rsp + 12], edx
    mov rdi, [r_renderer]
    mov rsi, rsp
    call [r_SDL_RenderReadPixels]
    test rax, rax
    jz .fail
    mov rbx, rax
    mov rdi, rax
    mov rsi, [r_shot_path]
    call [r_SDL_SaveBMP]
    mov rdi, rbx
    call [r_SDL_DestroySurface]
    lea rdi, [fmt_vid_shot]
    mov rsi, [r_shot_path]
    mov edx, [r_frames]
    xor eax, eax
    call _printf
    add rsp, 16
    pop rbx
    ret
.fail:
    lea rdi, [s_readpixels]
    call r_sdl_error
    add rsp, 16
    pop rbx
    ret

; Vid_ClearScreen(ctx, r, g, b, left, top, right, bottom): back buffer and CPU buffer
vid_ClearScreen:
    HENTER 16
    cmp qword [r_renderer], 0
    je .out
    mov rdi, [r_renderer]
    movzx esi, byte [rbx + 4]
    movzx edx, byte [rbx + 8]
    movzx ecx, byte [rbx + 12]
    mov r8d, 255
    call [r_SDL_SetRenderDrawColor]
    cvtsi2ss xmm0, ARG(4)
    movss [rsp], xmm0
    cvtsi2ss xmm0, ARG(5)
    movss [rsp + 4], xmm0
    mov eax, ARG(6)
    sub eax, ARG(4)
    cvtsi2ss xmm0, eax
    movss [rsp + 8], xmm0
    mov eax, ARG(7)
    sub eax, ARG(5)
    cvtsi2ss xmm0, eax
    movss [rsp + 12], xmm0
    mov rdi, [r_renderer]
    mov rsi, rsp
    call [r_SDL_RenderFillRect]
    ; CPU buffer: clamp the rect, fill with the packed 565 colour
    movzx eax, byte [rbx + 4]
    shr eax, 3
    shl eax, 11
    movzx ecx, byte [rbx + 8]
    shr ecx, 2
    shl ecx, 5
    or eax, ecx
    movzx ecx, byte [rbx + 12]
    shr ecx, 3
    or eax, ecx
    mov r9d, eax                    ; colour
    mov r10d, ARG(4)                ; left
    mov r11d, ARG(6)                ; right
    mov r12d, ARG(5)                ; top
    mov r13d, ARG(7)                ; bottom
    xor eax, eax
    cmp r10d, 0
    cmovl r10d, eax
    cmp r12d, 0
    cmovl r12d, eax
    mov eax, [r_tw]
    cmp r11d, eax
    cmovg r11d, eax
    mov eax, [r_th]
    cmp r13d, eax
    cmovg r13d, eax
    sub r11d, r10d                  ; width
    jle .out
.row:
    cmp r12d, r13d
    jge .out
    mov edi, r12d
    imul edi, [r_pitch]
    add edi, [r_cpu_fb]
    lea edi, [rdi + r10*2]
    mov ecx, r11d
    mov eax, r9d
    rep stosw
    inc r12d
    jmp .row
.out:
    HRET

vid_ShutDown_SYS:               ; (ctx)
    sub rsp, 8
    mov rdi, [r_renderer]
    test rdi, rdi
    jz .out
    call [r_SDL_DestroyRenderer]
    mov qword [r_renderer], 0
.out:
    add rsp, 8
    ret

; ======================================================== d3ddll.dll (gbh_*)

gbh_InitDLL:                    ; (VidCtx*): no slot patching needed, both DLLs are ours
    sub rsp, 8
    mov eax, [rdi]
    mov [r_ctx], eax
    cmp dword [r_globals], 0
    jne .out
    mov edi, GbhGlobals_size
    mov esi, 16
    call low_alloc
    mov [r_globals], eax
.out:
    add rsp, 8
    ret

gbh_Init:                       ; (int) -> 0
    sub rsp, 8
    lea rdi, [msg_gbh_init]
    call _puts
    add rsp, 8
    xor eax, eax
    ret

gbh_GetGlobals:
    mov eax, [r_globals]
    ret

gbh_SetWindow:                  ; (float l, t, r, b): the cull rect; SDL clips for us
    mov eax, [rdi]
    mov [r_cull], eax
    mov eax, [rdi + 4]
    mov [r_cull + 4], eax
    mov eax, [rdi + 8]
    mov [r_cull + 8], eax
    mov eax, [rdi + 12]
    mov [r_cull + 12], eax
    ret

gbh_SetAmbient:                 ; (float): only lighting uses it
    mov eax, [rdi]
    mov [r_ambient], eax
    ret

gbh_SetCamera:                  ; (float l, t, r, b): the visible world rect; stored, unused
    movups xmm0, [rdi]
    movups [r_camera], xmm0
    ret

gbh_ResetLights:
    mov dword [n_lights], 0
    ret

; gbh_AddLight(GbhLight *) (d3ddll 0xe01d70): packed = intensity | radius << 8 | type << 16;
; precomputes intensity/255, r = radius/255*8, r^2, 1/r, rgb/255 like the original.
gbh_AddLight:
    mov eax, [n_lights]
    cmp eax, MAX_LIGHTS
    jae .full
    inc dword [n_lights]
    imul eax, eax, L_SIZE
    lea rcx, [lights]
    add rcx, rax
    mov edx, [rdi]
    mov eax, [rdx + GbhLight.packed]
    mov [rcx + L_PACKED], eax
    movzx r8d, al
    cvtsi2ss xmm0, r8d
    mulss xmm0, [f_inv255]
    movss [rcx + L_I], xmm0
    mov r8d, eax
    shr r8d, 8
    and r8d, 0xff
    cvtsi2ss xmm0, r8d
    mulss xmm0, [f_inv255]
    mulss xmm0, [f_eight]
    movss [rcx + L_R], xmm0
    movaps xmm1, xmm0
    mulss xmm1, xmm0
    movss [rcx + L_R2], xmm1
    movss xmm1, [f_one]
    divss xmm1, xmm0
    movss [rcx + L_INVR], xmm1
    mov eax, [rdx + GbhLight.x]
    mov [rcx + L_X], eax
    mov eax, [rdx + GbhLight.y]
    mov [rcx + L_Y], eax
    mov eax, [rdx + GbhLight.z]
    mov [rcx + L_Z], eax
    mov eax, [rdx + GbhLight.rgb]
%assign sh 16
%assign off L_CR
%rep 3
    mov r8d, eax
    shr r8d, sh
    and r8d, 0xff
    cvtsi2ss xmm0, r8d
    mulss xmm0, [f_inv255]
    movss [rcx + off], xmm0
%assign sh sh - 8
%assign off off + 4
%endrep
    ret
.full:
    cmp byte [lights_warned], 0
    jne .r
    mov byte [lights_warned], 1
    sub rsp, 8
    lea rdi, [msg_lights_full]
    call _puts
    add rsp, 8
.r:
    ret

; apply_lights(rdi = SDL_Vertex[esi], edx = brightness, r12 = GbhVertex v[]): the
; original's per-vertex point lighting (d3ddll ApplyPointLightsToVertices). The world
; position of v[i] is in v[i + 4].x/y/z. Per channel c (0..1):
;   c' = min(1, c * brightness/255 * sum(light.c * I * (r - d) / r) + ambient)
; over lights of type 1 with d^2 <= r^2. The original's table sqrt is sqrtss here.
apply_lights:
    cvtsi2ss xmm8, edx
    mulss xmm8, [f_inv255]
    movss xmm9, [r_ambient]
    xor r8d, r8d
.v:
    cmp r8d, esi
    jae .done
    mov eax, r8d
    shl eax, 5
    lea r9, [r12 + rax + 0x80]
    lea r10, [rdi + rax]
    xorps xmm10, xmm10
    xorps xmm11, xmm11
    xorps xmm12, xmm12
    lea r11, [lights]
    mov ecx, [n_lights]
.l:
    test ecx, ecx
    jz .sum
    mov eax, [r11 + L_PACKED]
    and eax, 0x30000
    cmp eax, 0x10000
    jne .nl
    movss xmm0, [r9]
    subss xmm0, [r11 + L_X]
    mulss xmm0, xmm0
    movss xmm1, [r9 + 4]
    subss xmm1, [r11 + L_Y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [r9 + 8]
    subss xmm1, [r11 + L_Z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [r11 + L_R2]
    ja .nl
    sqrtss xmm0, xmm0
    movss xmm1, [r11 + L_R]
    subss xmm1, xmm0
    mulss xmm1, [r11 + L_INVR]
    xorps xmm2, xmm2
    comiss xmm1, xmm2
    jbe .nl
    mulss xmm1, [r11 + L_I]
    movss xmm2, [r11 + L_CR]
    mulss xmm2, xmm1
    addss xmm10, xmm2
    movss xmm2, [r11 + L_CR + 4]
    mulss xmm2, xmm1
    addss xmm11, xmm2
    movss xmm2, [r11 + L_CR + 8]
    mulss xmm2, xmm1
    addss xmm12, xmm2
.nl:
    add r11, L_SIZE
    dec ecx
    jmp .l
.sum:
%assign off 8
%rep 3
    movss xmm0, [r10 + off]
    mulss xmm0, xmm8
  %if off == 8
    mulss xmm0, xmm10
  %elif off == 12
    mulss xmm0, xmm11
  %else
    mulss xmm0, xmm12
  %endif
    addss xmm0, xmm9
    minss xmm0, [f_one]
    movss [r10 + off], xmm0
%assign off off + 4
%endrep
    inc r8d
    jmp .v
.done:
    ret

; gbh_BeginScene: the original unlocks a locked 2D surface (and EndScene re-locks it);
; here the locked CPU buffer also gets drawn under the 3D primitives.
gbh_BeginScene:
    sub rsp, 8
    mov byte [r_relock], 0
    mov ecx, [r_ctx]
    test ecx, ecx
    jz .fb
    test dword [rcx + VidCtx.flags], VID_F_LOCKED
    jz .fb
    mov byte [r_relock], 1
    mov dword [rcx + VidCtx.surface], 0
    and dword [rcx + VidCtx.flags], ~(VID_F_LOCKED | VID_F_WRITES)
.fb:
    cmp qword [r_renderer], 0
    je .out
    cmp byte [r_fb_touched], 0
    je .out
    mov byte [r_fb_touched], 0
    call r_upload_fb
.out:
    mov ecx, [r_globals]
    test ecx, ecx
    jz .r
    mov dword [rcx + GbhGlobals.polys_drawn], 0
.r:
    add rsp, 8
    ret

gbh_EndScene:
    cmp byte [r_relock], 0
    je .out
    mov byte [r_relock], 0
    sub rsp, 24
    mov eax, [r_ctx]
    mov [rsp], eax
    mov rdi, rsp
    call vid_lock_quiet
    add rsp, 24
.out:
    ret

; ---- palettes ----------------------------------------------------------------
; gbh_RegisterPalette(index, u32 *pal): 256 x 0x00RRGGBB, stride 64 dwords. Like the
; original it edits the caller's data (pal[0] = 0, other zeros -> 0x10000).
gbh_RegisterPalette:
    HENTER
    mov r12d, ARG(0)
    cmp r12d, MAX_PAL
    jae .bad
    lea rax, [pal_ptr]
    mov rax, [rax + r12*8]
    test rax, rax
    jnz .have
    mov edi, 1024
    call _malloc
    lea rcx, [pal_ptr]
    mov [rcx + r12*8], rax
.have:
    mov r13, rax
    mov r14d, ARG(1)
    mov dword [r14], 0
    mov dword [r13], 0              ; index 0: transparent
    mov ecx, 1
.c:
    mov eax, ecx
    shl eax, 8                      ; stride 64 dwords = 256 bytes
    mov edx, [r14 + rax]
    test edx, edx
    jnz .nz
    mov edx, 0x10000
    mov [r14 + rax], edx
.nz:
    and edx, 0x00FFFFFF
    or edx, 0xFF000000
    mov [r13 + rcx*4], edx
    inc ecx
    cmp ecx, 256
    jb .c
    lea rax, [pal_gen]
    inc dword [rax + r12*4]
    inc dword [r_pals]
    HRET
.bad:
    lea rdi, [fmt_gbh_badpal]
    mov esi, r12d
    xor eax, eax
    call _printf
    HRET

gbh_FreePalette:                ; (index)
    push rbx
    mov ebx, [rdi]
    cmp ebx, MAX_PAL
    jae .out
    lea rax, [pal_ptr]
    mov rdi, [rax + rbx*8]
    mov qword [rax + rbx*8], 0
    call _free
    lea rax, [pal_gen]
    inc dword [rax + rbx*4]
.out:
    pop rbx
    ret

; ---- textures ----------------------------------------------------------------
; eax = tc_alloc() -> cache entry index (zeroed, dirty)
tc_alloc:
    mov eax, [tc_free]
    test eax, eax
    jz .fresh
    mov ecx, eax
    shl ecx, 5
    lea rdx, [tex_cache]
    mov r8d, [rdx + rcx + TCE_PIXELS]  ; free-list link
    mov [tc_free], r8d
    jmp .init
.fresh:
    mov eax, [tc_used]
    cmp eax, MAX_TEX
    jae .full
    inc dword [tc_used]
.init:
    mov ecx, eax
    shl ecx, 5
    lea rdx, [tex_cache]
    add rdx, rcx
    mov qword [rdx + TCE_SDL], 0
    mov qword [rdx + TCE_PIXELS], 0
    mov qword [rdx + TCE_H], 0
    mov qword [rdx + TCE_GEN], 0
    mov dword [rdx + TCE_DIRTY], 1
    ret
.full:
    lea rdi, [msg_tc_full]
    call fail

; gbh_RegisterTexture(u16 w, u16 h, u8 *pixels, int palette, char translucent)
gbh_RegisterTexture:
    HENTER
    mov edi, GbhTexture_size
    mov esi, HEAP_ZERO_MEMORY
    call heap_alloc
    mov r12, rax
    call tc_alloc
    mov r13d, eax
    mov [r12 + GbhTexture.id], ax
    mov [r12 + GbhTexture.cache], r13d
    mov eax, ARG(0)
    mov [r12 + GbhTexture.width], ax
    mov eax, ARG(1)
    mov [r12 + GbhTexture.height], ax
    mov eax, ARG(2)
    mov [r12 + GbhTexture.pixels], eax
    mov byte [r12 + GbhTexture.pal_registered], 1
    shl r13d, 5
    lea rcx, [tex_cache]
    mov eax, ARG(3)
    mov [rcx + r13 + TCE_PAL], eax
    inc dword [r_texs]
    mov eax, r12d
    HRET

gbh_FreeTexture:                ; (GbhTexture*)
    HENTER
    mov r12d, ARG(0)
    test r12d, r12d
    jz .out
    mov r13d, [r12 + GbhTexture.cache]
    test r13d, r13d
    jz .free
    mov eax, r13d
    shl eax, 5
    lea r14, [tex_cache]
    add r14, rax
    mov rdi, [r14 + TCE_SDL]
    test rdi, rdi
    jz .link
    call [r_SDL_DestroyTexture]
    mov qword [r14 + TCE_SDL], 0
.link:
    mov eax, [tc_free]
    mov [r14 + TCE_PIXELS], eax
    mov [tc_free], r13d
.free:
    mov edi, r12d
    call heap_free
.out:
    HRET

; rcx = cache entry of GbhTexture* edi (0 if it has none)
tc_entry:
    mov ecx, [rdi + GbhTexture.cache]
    test ecx, ecx
    jz .none
    shl ecx, 5
    lea r8, [tex_cache]
    add rcx, r8
    ret
.none:
    xor ecx, ecx
    ret

gbh_LockTexture:                ; (GbhTexture*): the game pokes width/height/pixels next
    mov edi, [rdi]
    mov word [rdi + GbhTexture.lock_state], 1
    call tc_entry
    test rcx, rcx
    jz .r
    mov dword [rcx + TCE_DIRTY], 1
.r:
    ret

gbh_UnlockTexture:
    mov edi, [rdi]
    mov word [rdi + GbhTexture.lock_state], 0
    call tc_entry
    test rcx, rcx
    jz .r
    mov dword [rcx + TCE_DIRTY], 1
.r:
    ret

gbh_AssignPalette:              ; (GbhTexture*, palette)
    mov eax, [rdi + 4]
    mov edi, [rdi]
    call tc_entry
    test rcx, rcx
    jz .r
    mov [rcx + TCE_PAL], eax
    mov dword [rcx + TCE_DIRTY], 1
.r:
    ret

; rax = tex_get(edi = GbhTexture*) -> SDL_Texture* matching its current pixels/size/
; palette (rebuilt when any of them changed), or 0 if it cannot be drawn.
tex_get:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    call tc_entry
    test rcx, rcx
    jz .none
    mov rbx, rcx
    movzx r13d, word [r12 + GbhTexture.width]
    movzx r14d, word [r12 + GbhTexture.height]
    mov eax, [rbx + TCE_PAL]
    xor edx, edx
    cmp eax, MAX_PAL
    jae .gen
    lea rdx, [pal_gen]
    mov edx, [rdx + rax*4]
.gen:
    cmp qword [rbx + TCE_SDL], 0
    je .build
    cmp dword [rbx + TCE_DIRTY], 0
    jne .build
    mov eax, [r12 + GbhTexture.pixels]
    cmp eax, [rbx + TCE_PIXELS]
    jne .build
    cmp r13d, [rbx + TCE_W]
    jne .build
    cmp r14d, [rbx + TCE_H]
    jne .build
    cmp edx, [rbx + TCE_GEN]
    jne .build
    mov rax, [rbx + TCE_SDL]
    jmp .out
.build:
    mov [rbx + TCE_GEN], edx
    test r13d, r13d
    jz .none
    test r14d, r14d
    jz .none
    cmp r13d, 256
    ja .none
    cmp r14d, 256
    ja .none
    mov rdi, [rbx + TCE_SDL]
    test rdi, rdi
    jz .create
    cmp r13d, [rbx + TCE_W]
    jne .recreate
    cmp r14d, [rbx + TCE_H]
    je .convert
.recreate:
    call [r_SDL_DestroyTexture]
    mov qword [rbx + TCE_SDL], 0
.create:
    mov edi, SDL_PIXELFORMAT_ARGB8888
    mov esi, SDL_TEXTUREACCESS_STATIC
    mov edx, r13d
    mov ecx, r14d
    call r_texture
    test rax, rax
    jz .none
    mov [rbx + TCE_SDL], rax
.convert:
    mov [rbx + TCE_W], r13d
    mov [rbx + TCE_H], r14d
    mov eax, [r12 + GbhTexture.pixels]
    mov [rbx + TCE_PIXELS], eax
    mov dword [rbx + TCE_DIRTY], 0
    ; palette (a grey ramp if the index was never registered)
    mov eax, [rbx + TCE_PAL]
    lea r8, [grey_pal]
    cmp eax, MAX_PAL
    jae .pal
    lea rcx, [pal_ptr]
    mov rcx, [rcx + rax*8]
    test rcx, rcx
    cmovnz r8, rcx
.pal:
    mov esi, [rbx + TCE_PIXELS]      ; 8-bit source, pitch 256
    lea rdi, [conv_buf]
    xor r9d, r9d                    ; y
.y:
    xor r10d, r10d                  ; x
.x:
    movzx eax, byte [rsi + r10]
    mov eax, [r8 + rax*4]
    mov [rdi], eax
    add rdi, 4
    inc r10d
    cmp r10d, r13d
    jb .x
    add esi, 256
    inc r9d
    cmp r9d, r14d
    jb .y
    mov rdi, [rbx + TCE_SDL]
    xor esi, esi
    lea rdx, [conv_buf]
    lea ecx, [r13*4]
    call [r_SDL_UpdateTexture]
    inc dword [r_tex_builds]
    mov rax, [rbx + TCE_SDL]
    jmp .out
.none:
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---- drawing -------------------------------------------------------------------
; gbh_DrawTile(flags, GbhTexture*, GbhVertex v[4], u8 brightness) (= gbh_DrawTilePart):
; d3ddll 0xe043f0. Unless GBH_F_TILE_CUSTOM_UV, the UVs become the 64x64 tile
; (0.5..63.4999); then the rotate/flip flags permute the (u, v) pairs between the
; vertices, written back into the caller's array like the original, and it is a DrawQuad.
gbh_DrawTile:
    mov eax, [rdi + 8]              ; v
    mov ecx, [rdi]                  ; flags
    test ecx, GBH_F_TILE_CUSTOM_UV
    jnz .perm
    mov r8d, 0x3f000000             ; 0.5
    mov r9d, 0x427dffe6             ; 63.4999
    mov [rax + 0x00 + GbhVertex.u], r8d
    mov [rax + 0x00 + GbhVertex.v], r8d
    mov [rax + 0x20 + GbhVertex.u], r9d
    mov [rax + 0x20 + GbhVertex.v], r8d
    mov [rax + 0x40 + GbhVertex.u], r9d
    mov [rax + 0x40 + GbhVertex.v], r9d
    mov [rax + 0x60 + GbhVertex.u], r8d
    mov [rax + 0x60 + GbhVertex.v], r9d
.perm:
    mov r8, [rax + 0x00 + GbhVertex.u]   ; (u, v) of v[0..3]
    mov r9, [rax + 0x20 + GbhVertex.u]
    mov r10, [rax + 0x40 + GbhVertex.u]
    mov r11, [rax + 0x60 + GbhVertex.u]
    mov edx, ecx
    and edx, GBH_F_TILE_ROT_MASK
    cmp edx, 0x20                   ; new[i] = old[i+3]
    jne .r40
    xchg r8, r11
    xchg r9, r11
    xchg r10, r11
    jmp .flips
.r40:
    cmp edx, 0x40                   ; 180 degrees = both mirrors
    jne .r60
    xor ecx, GBH_F_TILE_FLIPX | GBH_F_TILE_FLIPY
    jmp .flips
.r60:
    cmp edx, 0x60                   ; new[i] = old[i+1]
    jne .flips
    xchg r8, r9
    xchg r9, r10
    xchg r10, r11
.flips:
    test ecx, GBH_F_TILE_FLIPX      ; 0<->1, 2<->3
    jz .fy
    xchg r8, r9
    xchg r10, r11
.fy:
    test ecx, GBH_F_TILE_FLIPY      ; 0<->3, 1<->2
    jz .store
    xchg r8, r11
    xchg r9, r10
.store:
    mov [rax + 0x00 + GbhVertex.u], r8
    mov [rax + 0x20 + GbhVertex.u], r9
    mov [rax + 0x40 + GbhVertex.u], r10
    mov [rax + 0x60 + GbhVertex.u], r11
    mov [rdi], ecx                  ; DrawQuad sees the adjusted flags
gbh_DrawQuad:                  ; (flags, GbhTexture*, GbhVertex v[4], u8 brightness)
    mov edx, 4
    jmp draw_prim
gbh_DrawTriangle:               ; (flags, GbhTexture*, GbhVertex v[3], u8 brightness)
    mov edx, 3

; draw_prim(rdi = args, edx = vertex count): renderer-api.md §2.3 -> SDL_RenderGeometry.
; Locals: 4 SDL_Vertex {x, y, r, g, b, a, u, v} (float) = 128 bytes at [rsp].
draw_prim:
    HENTER 128
    mov r14d, edx
    cmp qword [r_renderer], 0
    je .out
    mov r12d, ARG(2)                ; vertices
    mov eax, [r12 + GbhVertex.z]
    test eax, eax                   ; z <= 0 (float sign/zero as int): culled
    jle .out
    xor r13d, r13d                  ; SDL texture (0 = untextured)
    mov edi, ARG(1)
    test edi, edi
    jz .verts
    call tex_get
    test rax, rax
    jz .out
    mov r13, rax
    mov rdi, r13
    mov esi, SDL_BLENDMODE_BLEND    ; also does the alpha test of index 0
    mov eax, ARG(0)
    and eax, GBH_F_ALPHA_MASK
    cmp eax, GBH_F_ADDITIVE
    jne .blend
    mov esi, SDL_BLENDMODE_ADD
.blend:
    call [r_SDL_SetTextureBlendMode]
    mov rdi, r13
    mov esi, SDL_SCALEMODE_LINEAR
    test ARG(0), GBH_F_NO_FILTER | GBH_F_SPRITE_RECT
    jz .scale
    mov esi, SDL_SCALEMODE_NEAREST
.scale:
    call [r_SDL_SetTextureScaleMode]
.verts:
    xorps xmm4, xmm4                ; 1/w, 1/h (UVs come in texels)
    xorps xmm5, xmm5
    xorps xmm6, xmm6                ; w, h
    xorps xmm7, xmm7
    mov ecx, ARG(1)
    test ecx, ecx
    jz .noinv
    movzx eax, word [rcx + GbhTexture.width]
    cvtsi2ss xmm6, eax
    movzx eax, word [rcx + GbhTexture.height]
    cvtsi2ss xmm7, eax
    movss xmm4, [f_one]
    divss xmm4, xmm6
    movss xmm5, [f_one]
    divss xmm5, xmm7
.noinv:
    movzx eax, byte [rbx + 12]      ; brightness -> grey diffuse
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_inv255]
    xor r8d, r8d
.v:
    cmp r8d, r14d
    jae .vdone
    mov eax, r8d
    shl eax, 5
    lea rsi, [r12 + rax]
    lea rdi, [rsp + rax]
    mov edx, [rsi + GbhVertex.x]
    mov [rdi], edx
    mov edx, [rsi + GbhVertex.y]
    mov [rdi + 4], edx
    test ARG(0), GBH_F_VERTEX_COLOUR
    jnz .vcol
    movss [rdi + 8], xmm0
    movss [rdi + 12], xmm0
    movss [rdi + 16], xmm0
    mov dword [rdi + 20], 0x3f800000
    jmp .uv
.vcol:
    mov edx, [rsi + GbhVertex.diffuse]
    mov eax, edx
    shr eax, 16
    movzx eax, al
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_inv255]
    movss [rdi + 8], xmm1
    movzx eax, dh
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_inv255]
    movss [rdi + 12], xmm1
    movzx eax, dl
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_inv255]
    movss [rdi + 16], xmm1
    mov dword [rdi + 20], 0x3f800000
    test ARG(0), GBH_F_ALPHA_MASK   ; opaque mode ignores diffuse alpha
    jz .uv
    shr edx, 24
    cvtsi2ss xmm1, edx
    mulss xmm1, [f_inv255]
    movss [rdi + 20], xmm1
.uv:
    movss xmm1, [rsi + GbhVertex.u]
    mulss xmm1, xmm4
    movss [rdi + 24], xmm1
    movss xmm1, [rsi + GbhVertex.v]
    mulss xmm1, xmm5
    movss [rdi + 28], xmm1
    inc r8d
    jmp .v
.vdone:
    test ARG(0), GBH_F_LIGHTING     ; and ambient != 1.0, as the original
    jz .lit
    cmp dword [r_ambient], 0x3f800000
    je .lit
    mov rdi, rsp
    mov esi, r14d
    movzx edx, byte [rbx + 12]
    call apply_lights
.lit:
    ; GBH_F_SPRITE_RECT: only v[0].x/y/z are valid; build a w x h quad, whole texture
    test ARG(0), GBH_F_SPRITE_RECT
    jz .draw
    cmp r14d, 4
    jne .draw
    test r13, r13
    jz .draw
    movss xmm1, [rsp]               ; x0
    movss xmm2, [rsp + 4]           ; y0
    movaps xmm8, xmm1
    addss xmm8, xmm6                ; x1
    movaps xmm9, xmm2
    addss xmm9, xmm7                ; y1
    xor eax, eax
    mov edx, 0x3f800000
    mov [rsp + 24], eax
    mov [rsp + 28], eax
    movss [rsp + 32], xmm8
    movss [rsp + 36], xmm2
    mov [rsp + 56], edx
    mov [rsp + 60], eax
    movss [rsp + 64], xmm8
    movss [rsp + 68], xmm9
    mov [rsp + 88], edx
    mov [rsp + 92], edx
    movss [rsp + 96], xmm1
    movss [rsp + 100], xmm9
    mov [rsp + 120], eax
    mov [rsp + 124], edx
    movups xmm1, [rsp + 8]          ; v[0]'s colour for all four
    movups [rsp + 40], xmm1
    movups [rsp + 72], xmm1
    movups [rsp + 104], xmm1
.draw:
    mov rdi, [r_renderer]
    mov rsi, r13
    mov rdx, rsp
    mov ecx, r14d
    lea r8, [quad_idx]
    mov r9d, 6
    cmp r14d, 4
    je .call
    xor r8d, r8d
    xor r9d, r9d
.call:
    call [r_SDL_RenderGeometry]
    inc dword [r_quads]
    mov ecx, [r_globals]
    test ecx, ecx
    jz .out
    inc dword [rcx + GbhGlobals.polys_drawn]
.out:
    HRET

; gbh_DrawFlatRect(GbhVertex v[4], u32 argb): untextured quad, alpha-blended by argb's alpha
gbh_DrawFlatRect:
    HENTER 128
    cmp qword [r_renderer], 0
    je .out
    mov r12d, ARG(0)
    mov edx, ARG(1)
    mov eax, edx
    shr eax, 16
    movzx eax, al
    cvtsi2ss xmm0, eax
    mulss xmm0, [f_inv255]
    movzx eax, dh
    cvtsi2ss xmm1, eax
    mulss xmm1, [f_inv255]
    movzx eax, dl
    cvtsi2ss xmm2, eax
    mulss xmm2, [f_inv255]
    shr edx, 24
    cvtsi2ss xmm3, edx
    mulss xmm3, [f_inv255]
    xor r8d, r8d
.v:
    mov eax, r8d
    shl eax, 5
    lea rsi, [r12 + rax]
    lea rdi, [rsp + rax]
    mov edx, [rsi + GbhVertex.x]
    mov [rdi], edx
    mov edx, [rsi + GbhVertex.y]
    mov [rdi + 4], edx
    movss [rdi + 8], xmm0
    movss [rdi + 12], xmm1
    movss [rdi + 16], xmm2
    movss [rdi + 20], xmm3
    mov qword [rdi + 24], 0
    inc r8d
    cmp r8d, 4
    jb .v
    mov rdi, [r_renderer]
    mov esi, SDL_BLENDMODE_BLEND
    call [r_SDL_SetRenderDrawBlendMode]
    mov rdi, [r_renderer]
    xor esi, esi
    mov rdx, rsp
    mov ecx, 4
    lea r8, [quad_idx]
    mov r9d, 6
    call [r_SDL_RenderGeometry]
    mov rdi, [r_renderer]
    mov esi, SDL_BLENDMODE_NONE
    call [r_SDL_SetRenderDrawBlendMode]
    inc dword [r_quads]
.out:
    HRET

; ---- images (frontend backgrounds) --------------------------------------------
gbh_InitImageTable:             ; (count) -> 0 / -1
    push rbx
    mov ebx, [rdi]
    call free_images
    mov eax, -1
    cmp ebx, MAX_IMG
    ja .out
    mov [img_count], ebx
    xor eax, eax
.out:
    pop rbx
    ret

gbh_FreeImageTable:             ; -> 0
    sub rsp, 8
    call free_images
    mov dword [img_count], 0
    add rsp, 8
    xor eax, eax
    ret

free_images:
    push rbx
    xor ebx, ebx
.l:
    cmp ebx, MAX_IMG
    jae .out
    lea rax, [img_tex]
    mov rdi, [rax + rbx*8]
    test rdi, rdi
    jz .n
    mov qword [rax + rbx*8], 0
    call [r_SDL_DestroyTexture]
.n:
    inc ebx
    jmp .l
.out:
    pop rbx
    ret

; gbh_LoadImage(void *tga) -> slot, -1 table full, -2 not a 16-bit type-2 TGA, -3 no renderer
gbh_LoadImage:
    HENTER
    mov r12d, ARG(0)
    cmp qword [r_renderer], 0
    je .no_dev
    xor r13d, r13d                  ; free slot
.slot:
    cmp r13d, [img_count]
    jae .full
    lea rax, [img_tex]
    cmp qword [rax + r13*8], 0
    je .have_slot
    inc r13d
    jmp .slot
.have_slot:
    cmp byte [r12 + 2], 2           ; uncompressed true-colour
    jne .bad
    cmp byte [r12 + 16], 16
    jne .bad
    movzx r14d, word [r12 + 12]     ; width
    movzx ebx, word [r12 + 14]      ; height (rbx no longer needed for args)
    test r14d, r14d
    jz .bad
    test ebx, ebx
    jz .bad
    mov eax, r14d
    imul eax, ebx
    cmp eax, CONV_SIZE / 2
    ja .bad
    ; pixel data: header 18 + id length + colour map
    movzx esi, byte [r12]
    lea esi, [r12 + rsi + 18]
    cmp byte [r12 + 1], 0
    je .rows
    movzx eax, word [r12 + 5]       ; colour map length
    movzx ecx, byte [r12 + 7]       ; entry bits
    add ecx, 7
    shr ecx, 3
    imul eax, ecx
    add esi, eax
.rows:
    ; copy rows into conv_buf top-down (bottom-up unless descriptor bit 5)
    xor r9d, r9d
.row:
    cmp r9d, ebx
    jae .upload
    mov eax, r9d                    ; destination row
    test byte [r12 + 17], 0x20
    jnz .td
    mov eax, ebx
    dec eax
    sub eax, r9d
.td:
    imul eax, r14d
    lea rdi, [conv_buf]
    lea rdi, [rdi + rax*2]
    mov ecx, r14d
    rep movsw                       ; esi advances through the source rows
    inc r9d
    jmp .row
.upload:
    mov edi, SDL_PIXELFORMAT_XRGB1555
    mov esi, SDL_TEXTUREACCESS_STATIC
    mov edx, r14d
    mov ecx, ebx
    call r_texture
    test rax, rax
    jz .no_dev
    lea rcx, [img_tex]
    mov [rcx + r13*8], rax
    lea rcx, [img_w]
    mov [rcx + r13*4], r14d
    lea rcx, [img_h]
    mov [rcx + r13*4], ebx
    mov rdi, rax
    xor esi, esi
    lea rdx, [conv_buf]
    lea ecx, [r14*2]
    call [r_SDL_UpdateTexture]
    lea rdi, [fmt_gbh_image]
    mov esi, r13d
    mov edx, r14d
    mov ecx, ebx
    xor eax, eax
    call _printf
    mov eax, r13d
    HRET
.full:
    mov eax, GBH_IMG_BAD_HANDLE
    HRET
.bad:
    lea rdi, [fmt_gbh_badimg]
    mov esi, r12d
    xor eax, eax
    call _printf
    mov eax, GBH_IMG_BAD_RECT
    HRET
.no_dev:
    mov eax, GBH_IMG_OFFSCREEN
    HRET

; gbh_BlitImage(idx, sl, st, sr, sb, dx, dy) -> 0, -1 bad handle, -2 bad rect
gbh_BlitImage:
    HENTER 32
    mov r12d, ARG(0)
    cmp r12d, [img_count]
    jae .bad_handle
    lea rax, [img_tex]
    mov r13, [rax + r12*8]
    test r13, r13
    jz .bad_handle
    cmp qword [r_renderer], 0
    je .bad_handle
    mov eax, ARG(1)                 ; 0 <= sl < sr <= w, 0 <= st < sb <= h
    test eax, eax
    js .bad_rect
    cmp eax, ARG(3)
    jge .bad_rect
    mov eax, ARG(2)
    test eax, eax
    js .bad_rect
    cmp eax, ARG(4)
    jge .bad_rect
    lea rax, [img_w]
    mov eax, [rax + r12*4]
    cmp ARG(3), eax
    jg .bad_rect
    lea rax, [img_h]
    mov eax, [rax + r12*4]
    cmp ARG(4), eax
    jg .bad_rect
    cvtsi2ss xmm0, ARG(1)           ; src {sl, st, w, h} at [rsp], dst at [rsp+16]
    movss [rsp], xmm0
    cvtsi2ss xmm0, ARG(2)
    movss [rsp + 4], xmm0
    mov eax, ARG(3)
    sub eax, ARG(1)
    cvtsi2ss xmm0, eax
    movss [rsp + 8], xmm0
    movss [rsp + 24], xmm0
    mov eax, ARG(4)
    sub eax, ARG(2)
    cvtsi2ss xmm0, eax
    movss [rsp + 12], xmm0
    movss [rsp + 28], xmm0
    cvtsi2ss xmm0, ARG(5)
    movss [rsp + 16], xmm0
    cvtsi2ss xmm0, ARG(6)
    movss [rsp + 20], xmm0
    mov rdi, [r_renderer]
    mov rsi, r13
    mov rdx, rsp
    lea rcx, [rsp + 16]
    call [r_SDL_RenderTexture]
    inc dword [r_blits]
    xor eax, eax
    HRET
.bad_handle:
    mov eax, GBH_IMG_BAD_HANDLE
    HRET
.bad_rect:
    mov eax, GBH_IMG_BAD_RECT
    HRET

; ---- shim tables ------------------------------------------------------------
section .data
align 8
shimtab_dmavideo:
    dq s_dmavideo
    SHIM "Vid_CheckMode", 16, vid_CheckMode
    SHIM "Vid_ClearScreen", 32, vid_ClearScreen
    SHIM "Vid_CloseScreen", 4, vid_CloseScreen
    SHIM "Vid_DisableWrites", 4, vid_FreeSurface
    SHIM "Vid_EnableWrites", 4, vid_lock_quiet
    SHIM "Vid_FindDevice", 8, vid_FindDevice
    SHIM "Vid_FindFirstMode", 8, vid_FindFirstMode
    SHIM "Vid_FindMode", 8, vid_FindMode
    SHIM "Vid_FindNextMode", 4, vid_FindNextMode
    SHIM "Vid_FlipBuffers", 4, vid_FlipBuffers
    SHIM "Vid_FreeSurface", 4, vid_FreeSurface
    SHIM "Vid_GetSurface", 4, vid_GetSurface
    SHIM "Vid_GetVersion", 0, h_silent
    SHIM "Vid_GrabSurface", 4, vid_GetSurface
    SHIM "Vid_InitDLL", 8, vid_InitDLL
    SHIM "Vid_Init_SYS", 8, vid_Init_SYS
    SHIM "Vid_ReleaseSurface", 4, vid_FreeSurface
    SHIM "Vid_SetDevice", 8, vid_SetDevice
    SHIM "Vid_SetGamma", 16, vid_SetGamma
    SHIM "Vid_SetMode", 12, vid_SetMode
    SHIM "Vid_ShutDown_SYS", 4, vid_ShutDown_SYS
    SHIM "Vid_WindowProc", 20, h_ret0
    dq 0
shimtab_d3ddll:
    dq s_d3ddll
    SHIM "ConvertColourBank", 4, h_ret0
    SHIM "DrawLine", 20, h_ret0
    SHIM "MakeScreenTable", 12, h_ret0
    SHIM "SetShadeTableA", 20, h_ret0
    SHIM "gbh_AddLight", 4, gbh_AddLight
    SHIM "gbh_AssignPalette", 8, gbh_AssignPalette
    SHIM "gbh_BeginLevel", 0, h_ret0
    SHIM "gbh_BeginScene", 0, gbh_BeginScene
    SHIM "gbh_BlitBuffer", 24, h_ret0
    SHIM "gbh_BlitImage", 28, gbh_BlitImage
    SHIM "gbh_CloseDLL", 0, h_ret0
    SHIM "gbh_CloseScreen", 4, vid_CloseScreen
    SHIM "gbh_Convert16BitGraphic", 8, h_silent
    SHIM "gbh_ConvertColour", 12, h_silent
    SHIM "gbh_DrawFlatRect", 8, gbh_DrawFlatRect
    SHIM "gbh_DrawQuad", 16, gbh_DrawQuad
    SHIM "gbh_DrawQuadClipped", 20, h_silent
    SHIM "gbh_DrawTile", 16, gbh_DrawTile
    SHIM "gbh_DrawTilePart", 16, gbh_DrawTile
    SHIM "gbh_DrawTriangle", 16, gbh_DrawTriangle
    SHIM "gbh_EndLevel", 0, h_ret0
    SHIM "gbh_EndScene", 0, gbh_EndScene
    SHIM "gbh_FreeImageTable", 0, gbh_FreeImageTable
    SHIM "gbh_FreePalette", 4, gbh_FreePalette
    SHIM "gbh_FreeTexture", 4, gbh_FreeTexture
    SHIM "gbh_GetGlobals", 0, gbh_GetGlobals
    SHIM "gbh_GetUsedCache", 4, h_ret0
    SHIM "gbh_Init", 4, gbh_Init
    SHIM "gbh_InitDLL", 4, gbh_InitDLL
    SHIM "gbh_InitImageTable", 4, gbh_InitImageTable
    SHIM "gbh_LoadImage", 4, gbh_LoadImage
    SHIM "gbh_LockTexture", 4, gbh_LockTexture
    SHIM "gbh_Plot", 16, h_ret0
    SHIM "gbh_PrintBitmap", 4, h_silent
    SHIM "gbh_RegisterPalette", 8, gbh_RegisterPalette
    SHIM "gbh_RegisterTexture", 20, gbh_RegisterTexture
    SHIM "gbh_ResetLights", 0, gbh_ResetLights
    SHIM "gbh_SetAmbient", 4, gbh_SetAmbient
    SHIM "gbh_SetCamera", 16, gbh_SetCamera
    SHIM "gbh_SetColourDepth", 0, h_ret0
    SHIM "gbh_SetWindow", 16, gbh_SetWindow
    SHIM "gbh_UnlockTexture", 4, gbh_UnlockTexture
    dq 0

align 4
quad_idx:   dd 0, 1, 2, 0, 2, 3     ; D3D triangle fan of 4 as two triangles
f_one:      dd 1.0
f_eight:    dd 8.0
f_inv255:   dd 0x3b808081           ; 1/255
grey_pal:
%assign i 0
%rep 256
    dd 0xFF000000 | (i << 16) | (i << 8) | i
%assign i i + 1
%endrep

section .rodata
s_dmavideo:     db "dmavideo", 0
s_d3ddll:       db "d3ddll", 0
s_vid_devname:  db "SDL3 renderer", 0
s_createtex:    db "SDL_CreateTexture", 0
s_createrend:   db "SDL_CreateRenderer", 0
s_readpixels:   db "SDL_RenderReadPixels", 0
fmt_r_sdlerr:   db "  [vid] %s failed: %s", 10, 0
fmt_vid_init:   db "  [vid] Vid_Init_SYS -> ctx 0x%x (1 device, mode 1 = 640x480x16 RGB565)", 10, 0
fmt_vid_renderer: db "  [vid] SDL renderer '%s', letterboxed into the window", 10, 0
fmt_vid_buffers: db "  [vid] back buffer %dx%d ARGB8888 target + RGB565 CPU buffer", 10, 0
fmt_vid_setmode: db "  [vid] Vid_SetMode(mode %d, hwnd 0x%x) -> game view %dx%d, back buffer %dx%d", 10, 0
fmt_vid_present: db "  [vid] presenting %dx%d of the back buffer (flip %u)", 10, 0
fmt_vid_flip:   db "  [vid] flip %u: %u quads, %u blits, %u texture uploads so far, %u textures registered", 10, 0
fmt_vid_shot:   db "  [vid] back buffer saved to %s (frame %u)", 10, 0
fmt_vid_exit:   db "  [vid] --frames: %u frames presented, exiting", 10, 0
msg_gbh_init:   db "  [gbh] gbh_Init: SDL_Renderer backend", 0
fmt_gbh_badpal: db "  [gbh] gbh_RegisterPalette: index %d out of range, ignored", 10, 0
fmt_gbh_image:  db "  [gbh] gbh_LoadImage -> slot %d (%dx%d)", 10, 0
fmt_gbh_badimg: db "  [gbh] gbh_LoadImage(0x%x): not a 16-bit uncompressed TGA", 10, 0
msg_lights_full: db "  [gbh] gbh_AddLight: more than MAX_LIGHTS lights in a frame, extra ones dropped", 0
msg_tc_full:    db "renderer: texture cache full", 0

section .bss
alignb 8
%unmacro RFN 1
%macro RFN 1
r_%1: resq 1
%endmacro
RFNS
sdl_lib:        resq 1
r_renderer:     resq 1
r_target:       resq 1
r_fbtex:        resq 1
r_tw:           resd 1          ; back buffer / CPU buffer size
r_th:           resd 1
r_pitch:        resd 1          ; CPU buffer pitch (r_tw * 2)
r_gw:           resd 1          ; gameplay view size (window_width/height when windowed)
r_gh:           resd 1
r_pw:           resd 1          ; size the window target presents now (0 = not set yet)
r_ph:           resd 1
r_shot_path:    resq 1          ; --shot=PATH
r_exit_frame:   resd 1          ; --frames=N
r_frames:       resd 1
r_quads:        resd 1
r_blits:        resd 1
r_tex_builds:   resd 1
r_texs:         resd 1
n_lights:       resd 1
r_camera:       resd 4
lights_warned:  resb 1
alignb 16
lights:         resb L_SIZE * MAX_LIGHTS
alignb 8
r_pals:         resd 1
r_cpu_fb:       resd 1
r_ctx:          resd 1
r_globals:      resd 1
r_vid_hmodule:  resd 1
r_vid_slots:    resd 1
r_find_bpp:     resd 1
r_ambient:      resd 1
r_cull:         resd 4
r_fb_touched:   resb 1
r_relock:       resb 1
alignb 8
tc_used:        resd 1
tc_free:        resd 1
img_count:      resd 1
img_w:          resd MAX_IMG
img_h:          resd MAX_IMG
img_tex:        resq MAX_IMG
pal_ptr:        resq MAX_PAL
pal_gen:        resd MAX_PAL
alignb 16
tex_cache:      resb TCE_SIZE * MAX_TEX
conv_buf:       resb CONV_SIZE
section .text
