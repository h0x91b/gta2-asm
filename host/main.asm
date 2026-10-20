; gta2-resurrected host — seed: SDL3 "hello window" in pure NASM.
;
; x86-64 Mach-O (macho64), runs under Rosetta 2. Opens a 640x480 window, draws a
; little top-down "city block" (roads, buildings, a park) and a yellow car that
; drives along the road, every frame via SDL_Renderer. Quits with exit code 0 on
; window close, SDL_EVENT_QUIT or Esc.
;
;   ./host           run until closed
;   ./host <N>       quit by itself after N frames (smoke tests / screenshots)
;
; ABI: System V AMD64. All SDL calls are made with rsp 16-byte aligned; variadic
; calls (SDL_Log) set al = 0 (no vector args).

default rel

; SDL3 constants (SDL3/SDL_init.h, SDL_events.h, SDL_keycode.h, 3.4.14)
SDL_INIT_VIDEO                   equ 0x20
SDL_EVENT_QUIT                   equ 0x100
SDL_EVENT_WINDOW_CLOSE_REQUESTED equ 0x210     ; SDL_EVENT_WINDOW_SHOWN (0x202) + 14
SDL_EVENT_KEY_DOWN               equ 0x300
SDLK_ESCAPE                      equ 0x1B
KEYEVENT_KEY                     equ 28        ; offsetof(SDL_KeyboardEvent, key)
SDL_EVENT_SIZE                   equ 128       ; sizeof(SDL_Event)

WIN_W   equ 640
WIN_H   equ 480
CAR_W   equ 40
CAR_H   equ 24
CAR_Y   equ 228                                 ; centred in the horizontal road

extern _SDL_Init, _SDL_Quit, _SDL_GetError, _SDL_Log
extern _SDL_CreateWindow, _SDL_DestroyWindow
extern _SDL_CreateRenderer, _SDL_DestroyRenderer, _SDL_SetRenderVSync
extern _SDL_SetRenderDrawColor, _SDL_RenderClear, _SDL_RenderFillRect
extern _SDL_RenderPresent, _SDL_PollEvent, _SDL_Delay
extern _atoi

global _main

section .text

; int main(int argc, char **argv)
_main:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; scene table cursor / scratch
    push    r12                         ; SDL_Window*
    push    r13                         ; SDL_Renderer*
    push    r14                         ; frame counter
    push    r15                         ; frame limit (0 = run until closed)
    sub     rsp, SDL_EVENT_SIZE + 8     ; SDL_Event at [rsp]; 5 pushes + 136 keeps rsp 16-aligned

    xor     r15d, r15d
    cmp     edi, 2
    jl      .no_limit
    mov     rdi, [rsi + 8]              ; argv[1]
    call    _atoi
    mov     r15d, eax
.no_limit:

    mov     edi, SDL_INIT_VIDEO
    call    _SDL_Init
    test    al, al
    jz      .fail_init

    lea     rdi, [title]
    mov     esi, WIN_W
    mov     edx, WIN_H
    xor     ecx, ecx                    ; SDL_WindowFlags (Uint64) = 0
    call    _SDL_CreateWindow
    test    rax, rax
    jz      .fail_window
    mov     r12, rax

    mov     rdi, r12
    xor     esi, esi                    ; name = NULL: let SDL pick (Metal on macOS)
    call    _SDL_CreateRenderer
    test    rax, rax
    jz      .fail_renderer
    mov     r13, rax

    mov     rdi, r13
    mov     esi, 1
    call    _SDL_SetRenderVSync
    mov     [vsync_ok], al              ; without vsync we pace with SDL_Delay

    xor     r14d, r14d

.frame:
    ; ---- drain events ----
.poll:
    mov     rdi, rsp
    call    _SDL_PollEvent
    test    al, al
    jz      .draw
    mov     eax, [rsp]                  ; event.type
    cmp     eax, SDL_EVENT_QUIT
    je      .quit
    cmp     eax, SDL_EVENT_WINDOW_CLOSE_REQUESTED
    je      .quit
    cmp     eax, SDL_EVENT_KEY_DOWN
    jne     .poll
    cmp     dword [rsp + KEYEVENT_KEY], SDLK_ESCAPE
    je      .quit
    jmp     .poll

.draw:
    ; background: asphalt-dark blue
    mov     rdi, r13
    mov     esi, 22
    mov     edx, 26
    mov     ecx, 38
    mov     r8d, 255
    call    _SDL_SetRenderDrawColor
    mov     rdi, r13
    call    _SDL_RenderClear

    ; static scene: table of {u8 r,g,b,a; SDL_FRect}
    lea     rbx, [scene]
.scene_loop:
    lea     rax, [scene_end]
    cmp     rbx, rax
    jae     .car
    mov     rdi, r13
    movzx   esi, byte [rbx]
    movzx   edx, byte [rbx + 1]
    movzx   ecx, byte [rbx + 2]
    movzx   r8d, byte [rbx + 3]
    call    _SDL_SetRenderDrawColor
    mov     rdi, r13
    lea     rsi, [rbx + 4]
    call    _SDL_RenderFillRect
    add     rbx, SCENE_ENTRY
    jmp     .scene_loop

.car:
    ; car.x = (frame * 3) mod (WIN_W + CAR_W) - CAR_W: drives in from the left edge
    mov     eax, r14d
    lea     eax, [rax + rax*2]
    xor     edx, edx
    mov     ecx, WIN_W + CAR_W
    div     ecx
    sub     edx, CAR_W
    cvtsi2ss xmm0, edx
    movss   [car_rect], xmm0

    mov     rdi, r13
    mov     esi, 250
    mov     edx, 210
    mov     ecx, 40
    mov     r8d, 255
    call    _SDL_SetRenderDrawColor
    mov     rdi, r13
    lea     rsi, [car_rect]
    call    _SDL_RenderFillRect

    mov     rdi, r13
    call    _SDL_RenderPresent

    cmp     byte [vsync_ok], 0
    jne     .paced
    mov     edi, 16
    call    _SDL_Delay
.paced:

    inc     r14d
    test    r15d, r15d
    jz      .frame
    cmp     r14d, r15d
    jb      .frame

.quit:
    xor     ebx, ebx                    ; exit code 0
    mov     rdi, r13
    call    _SDL_DestroyRenderer
.destroy_window:
    mov     rdi, r12
    call    _SDL_DestroyWindow
.sdl_quit:
    call    _SDL_Quit
.exit:
    mov     eax, ebx
    add     rsp, SDL_EVENT_SIZE + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; Error paths: log "<what>: <SDL_GetError()>", unwind what exists, exit 1.
.fail_init:
    lea     rbx, [msg_init]
    call    .log_error
    mov     ebx, 1
    jmp     .exit
.fail_window:
    lea     rbx, [msg_window]
    call    .log_error
    mov     ebx, 1
    jmp     .sdl_quit
.fail_renderer:
    lea     rbx, [msg_renderer]
    call    .log_error
    mov     ebx, 1
    jmp     .destroy_window

; rbx = message prefix. Entered by call (rsp ≡ 8 mod 16), so realign first.
.log_error:
    sub     rsp, 8
    call    _SDL_GetError
    lea     rdi, [fmt_error]
    mov     rsi, rbx
    mov     rdx, rax
    xor     eax, eax                    ; variadic: no vector registers used
    call    _SDL_Log
    add     rsp, 8
    ret

section .data

title       db "GTA2 Resurrected", 0
fmt_error   db "%s: %s", 0
msg_init    db "SDL_Init failed", 0
msg_window  db "SDL_CreateWindow failed", 0
msg_renderer db "SDL_CreateRenderer failed", 0

vsync_ok    db 0

align 4
; SDL_FRect {x, y, w, h}; x is rewritten every frame
car_rect    dd 0.0, 228.0, 40.0, 24.0             ; y/w/h = CAR_Y, CAR_W, CAR_H

; Static scene, painted in order. Each entry: r, g, b, a, then SDL_FRect.
%macro RECT 8
    db %1, %2, %3, %4
    dd %{5}.0, %{6}.0, %{7}.0, %{8}.0
%endmacro
SCENE_ENTRY equ 20

scene:
    ; buildings, four blocks around the crossroads
    RECT 120,  66,  52, 255,   24,  24, 248, 168
    RECT  70,  90, 130, 255,  368,  24, 248, 168
    RECT  50, 130,  60, 255,   24, 288, 248, 168     ; park
    RECT 140, 140, 150, 255,  368, 288, 248, 168
    ; roof details
    RECT 160,  96,  76, 255,   56,  56,  80,  56
    RECT 100, 124, 170, 255,  400,  56, 184,  40
    RECT  34, 100,  44, 255,   80, 330,  60,  60     ; trees
    RECT  34, 100,  44, 255,  170, 370,  60,  60
    RECT 180, 180, 190, 255,  420, 330, 140,  80
    ; roads
    RECT  60,  60,  66, 255,    0, 208, 640,  64
    RECT  60,  60,  66, 255,  288,   0,  64, 480
    ; lane markings
    RECT 230, 230, 230, 255,   16, 238,  48,   4
    RECT 230, 230, 230, 255,  112, 238,  48,   4
    RECT 230, 230, 230, 255,  208, 238,  48,   4
    RECT 230, 230, 230, 255,  384, 238,  48,   4
    RECT 230, 230, 230, 255,  480, 238,  48,   4
    RECT 230, 230, 230, 255,  576, 238,  48,   4
scene_end:
