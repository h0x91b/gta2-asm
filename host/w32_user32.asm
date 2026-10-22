; w32_user32.asm — USER32 + GDI32 shims: window classes, the real SDL3 window behind
; CreateWindowExA, a posted-message queue fed by SDL events, WndProc callbacks
; (call32 back into the game), wsprintfA, MessageBox -> log.
;
; SDL3 is dlopen'ed in setup_user32 (after the image, low region and arena are mapped;
; see loader.asm) and called through the sdl_* pointers below. One top-level window
; is the expected case; up to MAX_WINDOWS are tracked.

extern _dlopen, _dlsym, _dlerror, _getenv

RTLD_NOW        equ 2
SDL_INIT_VIDEO  equ 0x20
SDL_WINDOW_HIDDEN    equ 0x8
SDL_WINDOW_RESIZABLE equ 0x20
SDL_EVENT_QUIT  equ 0x100
SDL_EVENT_WINDOW_CLOSE_REQUESTED equ 0x210
SDL_EVENT_KEY_DOWN equ 0x300
SDL_EVENT_KEY_UP   equ 0x301
SELFTEST_MARK      equ 0x5E1F7E57   ; SDL_Event.reserved of --input-selftest events
SDL_KEY_SCANCODE   equ 24           ; offsetof(SDL_KeyboardEvent, scancode)
SDL_KEY_DOWN       equ 36           ; offsetof(SDL_KeyboardEvent, down)
SDL_KEY_REPEAT     equ 37           ; offsetof(SDL_KeyboardEvent, repeat)
SDL_EVENT_WINDOW_FOCUS_GAINED equ 0x20E
SDL_EVENT_WINDOW_FOCUS_LOST   equ 0x20F
SDL_WINDOW_HIDDEN      equ 0x8
SDL_WINDOW_MINIMIZED   equ 0x40
SDL_WINDOW_INPUT_FOCUS equ 0x200
SDL_EVENT_MOUSE_MOTION      equ 0x400
SDL_EVENT_MOUSE_BUTTON_DOWN equ 0x401
SDL_EVENT_MOUSE_BUTTON_UP   equ 0x402
SDL_EVENT_MOUSE_WHEEL       equ 0x403
SDL_MOTION_XREL    equ 36           ; SDL_MouseMotionEvent.xrel / yrel (float)
SDL_MOTION_YREL    equ 40
SDL_BUTTON_BUTTON  equ 24           ; SDL_MouseButtonEvent.button / down
SDL_BUTTON_DOWN    equ 25
SDL_WHEEL_Y        equ 28           ; SDL_MouseWheelEvent.y (float)

WM_CREATE     equ 0x01
WM_DESTROY    equ 0x02
WM_MOVE       equ 0x03
WM_SIZE       equ 0x05
WM_ACTIVATE   equ 0x06
WM_SETFOCUS   equ 0x07
WM_CLOSE      equ 0x10
WM_QUIT       equ 0x12
WM_SHOWWINDOW equ 0x18
WM_ACTIVATEAPP equ 0x1C
WM_NCCREATE   equ 0x81
WM_NCACTIVATE equ 0x86
WM_KEYDOWN    equ 0x100
WM_KEYUP      equ 0x101
WM_SYSKEYDOWN equ 0x104             ; WM_SYSKEYUP = 0x105
VK_F10        equ 0x79

HWND_BASE     equ 0x00AB0000        ; HWND = HWND_BASE + 4*i
MAX_WINDOWS   equ 8
MAX_CLASSES   equ 16
; window record: {wndproc, x, y, w, h, style, visible, userdata, exstyle} u32, SDL_Window*
WN_PROC   equ 0
WN_X      equ 4
WN_Y      equ 8
WN_W      equ 12
WN_H      equ 16
WN_STYLE  equ 20
WN_VIS    equ 24
WN_USER   equ 28
WN_EXSTYLE equ 32
WN_LIVE   equ 36
WN_SDL    equ 40
WN_SIZE   equ 48
MSGQ_LEN  equ 256                   ; posted messages (MSG = 28 bytes, stored as 32)

section .text

; ---- SDL loading ----------------------------------------------------------
%macro SDLFNS 0
    SDLFN SDL_Init
    SDLFN SDL_GetError
    SDLFN SDL_CreateWindow
    SDLFN SDL_DestroyWindow
    SDLFN SDL_ShowWindow
    SDLFN SDL_HideWindow
    SDLFN SDL_SetWindowSize
    SDLFN SDL_SetWindowPosition
    SDLFN SDL_SetWindowTitle
    SDLFN SDL_PollEvent
    SDLFN SDL_GetPrimaryDisplay
    SDLFN SDL_GetDesktopDisplayMode
    SDLFN SDL_ShowCursor
    SDLFN SDL_HideCursor
    SDLFN SDL_GetVersion
    SDLFN SDL_PushEvent
    SDLFN SDL_RaiseWindow
    SDLFN SDL_SetWindowRelativeMouseMode
    SDLFN SDL_GetWindowFlags
%endmacro

setup_user32:
    push rbx
    push r12
    sub rsp, 8
    lea rdi, [s_env_sdl]            ; $GTA2_SDL3_LIB, else ~/.local/opt/sdl3-x86_64
    call _getenv
    test rax, rax
    jnz .have_path
    lea rdi, [s_env_home]
    call _getenv
    lea rdi, [sdl_path]
    mov esi, 1024
    lea rdx, [fmt_sdl_default]
    mov rcx, rax
    xor eax, eax
    call _snprintf
    lea rax, [sdl_path]
.have_path:
    mov r12, rax
    mov rdi, rax
    mov esi, RTLD_NOW
    call _dlopen
    test rax, rax
    jz .no_lib
    mov rbx, rax
    mov [sdl_lib], rax              ; w32_renderer.asm resolves its own SDL functions
%macro SDLFN 1
    mov rdi, rbx
    lea rsi, [%%n]
    call _dlsym
    test rax, rax
    jz .no_sym
    mov [sdl_%1], rax
section .rodata
%%n: db %str(%1), 0
section .text
%endmacro
    SDLFNS
    call [sdl_SDL_GetVersion]
    mov r8d, eax                    ; major*1000000 + minor*1000 + patch
    lea rdi, [fmt_sdl_loaded]
    mov rsi, r12
    mov eax, r8d
    xor edx, edx
    mov ecx, 1000000
    div ecx
    mov esi, eax                    ; major
    mov eax, edx
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov ecx, edx                    ; patch
    mov edx, eax                    ; minor
    mov r8, r12
    xor eax, eax
    call _printf
    ; HDC / icon / cursor tokens and a CREATESTRUCTA live in low memory
    mov edi, 64
    mov esi, 16
    call low_alloc
    mov [low_createstruct], eax
    add rsp, 8
    pop r12
    pop rbx
    ret
.no_lib:
    call _dlerror
    lea rdi, [fmt_sdl_fail]
    mov rsi, rax
    xor eax, eax
    call _printf
    lea rdi, [msg_sdl]
    call fail
.no_sym:
    lea rdi, [msg_sdl_sym]
    call fail

; SDL_Init(VIDEO) on first use
sdl_ensure:
    cmp byte [sdl_inited], 0
    jne .r
    sub rsp, 8
    mov byte [sdl_inited], 1
    mov edi, SDL_INIT_VIDEO
    call [sdl_SDL_Init]
    test al, al
    jnz .ok
    call [sdl_SDL_GetError]
    lea rdi, [fmt_sdl_init_fail]
    mov rsi, rax
    xor eax, eax
    call _printf
.ok:
    add rsp, 8
.r:
    ret

; ---- window table ----------------------------------------------------------
; rax = win_get(edi = HWND) -> record or 0
win_get:
    mov eax, edi
    sub eax, HWND_BASE
    jb .no
    test eax, 3
    jnz .no
    shr eax, 2
    cmp eax, MAX_WINDOWS
    jae .no
    imul eax, eax, WN_SIZE
    lea rcx, [windows]
    add rax, rcx
    cmp dword [rax + WN_LIVE], 0
    je .no
    ret
.no:
    xor eax, eax
    ret

; eax = send_msg(edi = HWND, esi = msg, edx = wParam, ecx = lParam): call its WndProc
send_msg:
    push rbx
    sub rsp, 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    call win_get
    test rax, rax
    jz .none
    mov edi, [rax + WN_PROC]
    test edi, edi
    jz .none
    cmp byte [trace], 0
    je .call
    push rdi
    sub rsp, 8
    lea rdi, [fmt_send]
    mov esi, [rsp + 16 + 4]
    mov edx, [rsp + 16 + 8]
    mov ecx, [rsp + 16 + 12]
    mov r8d, [rsp + 16]
    xor eax, eax
    call _printf
    add rsp, 8
    pop rdi
.call:
    mov rsi, rsp
    mov edx, 4
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    jmp .out
.none:
    xor eax, eax
.out:
    add rsp, 16
    pop rbx
    ret

; post_msg(edi = HWND, esi = msg, edx = wParam, ecx = lParam): append to the queue
post_msg:
    mov eax, [msgq_tail]
    mov r8d, eax
    sub r8d, [msgq_head]
    cmp r8d, MSGQ_LEN
    jae .full
    and eax, MSGQ_LEN - 1
    shl eax, 5
    lea r8, [msgq]
    add r8, rax
    mov [r8], edi
    mov [r8 + 4], esi
    mov [r8 + 8], edx
    mov [r8 + 12], ecx
    inc dword [msgq_tail]
    mov eax, 1
    ret
.full:
    xor eax, eax
    ret

; Map SDL events: close -> WM_CLOSE; keys -> DirectInput state (input_key) and
; WM_KEYDOWN/UP (WM_SYS* with Alt or F10, like Windows); focus -> input_focus;
; mouse -> the DirectInput mouse accumulators. gta2.exe reads keys through
; DirectInput only; its WndProc handles just WM_SYSKEYDOWN (Alt+Enter, F10, Alt).
pump_sdl:
    push rbx
    push r12
    push r13
    sub rsp, 128                    ; SDL_Event (128); rsp stays 16-aligned
    call focus_poll                 ; mute state before the first mixed sample
    call _audio_pump                ; mss32 mixer (c/audio.c): top the audio output up
    cmp byte [sdl_inited], 0
    je .out
.poll:
    mov rdi, rsp
    call [sdl_SDL_PollEvent]
    test al, al
    jz .out
    mov eax, [rsp]
    cmp eax, SDL_EVENT_QUIT
    je .close
    cmp eax, SDL_EVENT_WINDOW_CLOSE_REQUESTED
    je .close
    cmp byte [input_selftest], 0    ; --input-selftest: only its own pushed events
    je .real_ok                     ; (marked in SDL_Event.reserved), not real devices
    cmp eax, SDL_EVENT_WINDOW_FOCUS_GAINED
    jb .real_ok
    cmp eax, SDL_EVENT_MOUSE_WHEEL
    ja .real_ok
    cmp dword [rsp + 4], SELFTEST_MARK
    jne .poll
.real_ok:
    cmp eax, SDL_EVENT_KEY_DOWN
    je .key
    cmp eax, SDL_EVENT_KEY_UP
    je .key
    cmp eax, SDL_EVENT_WINDOW_FOCUS_GAINED
    je .focus
    cmp eax, SDL_EVENT_WINDOW_FOCUS_LOST
    je .focus
    cmp eax, SDL_EVENT_MOUSE_MOTION
    je .motion
    cmp eax, SDL_EVENT_MOUSE_BUTTON_DOWN
    je .button
    cmp eax, SDL_EVENT_MOUSE_BUTTON_UP
    je .button
    cmp eax, SDL_EVENT_MOUSE_WHEEL
    je .wheel
    jmp .poll
.close:
    mov edi, [main_hwnd]
    mov esi, WM_CLOSE
    xor edx, edx
    xor ecx, ecx
    call post_msg
    jmp .poll
.focus:
    xor edi, edi
    cmp eax, SDL_EVENT_WINDOW_FOCUS_GAINED
    sete dil
    mov ebx, edi
    call input_focus
    mov edi, ebx
    call _audio_focus               ; mute while unfocused (c/audio.c)
    jmp .poll
.motion:
    movss xmm0, [rsp + SDL_MOTION_XREL]
    movss xmm1, [rsp + SDL_MOTION_YREL]
    call input_mouse_motion
    jmp .poll
.button:
    movzx edi, byte [rsp + SDL_BUTTON_BUTTON]
    movzx esi, byte [rsp + SDL_BUTTON_DOWN]
    call input_mouse_button
    jmp .poll
.wheel:
    movss xmm0, [rsp + SDL_WHEEL_Y]
    call input_mouse_wheel
    jmp .poll
.key:
    mov eax, [rsp + SDL_KEY_SCANCODE]
    cmp eax, SDL_SCANCODES
    jae .poll
    lea rcx, [sdl_dik]
    movzx r12d, byte [rcx + rax]    ; DIK
    lea rcx, [sdl_vk]
    movzx r13d, byte [rcx + rax]    ; VK
    test r12d, r12d
    jz .poll
    movzx ebx, byte [rsp + SDL_KEY_DOWN]
    cmp byte [rsp + SDL_KEY_REPEAT], 0
    jne .msg                        ; DirectInput has no auto-repeat
    mov edi, r12d
    mov esi, ebx
    call input_key
.msg:
    test r13d, r13d
    jz .poll
    ; lParam: repeat count 1, scan code = DIK & 0x7F, extended = DIK & 0x80,
    ; context (Alt held) bit 29, previous state bit 30, transition bit 31
    mov ecx, r12d
    and ecx, 0x7F
    shl ecx, 16
    or ecx, 1
    test r12d, 0x80
    jz .k1
    or ecx, 1 << 24
.k1:
    mov esi, WM_KEYDOWN
    lea rax, [di_keys]
    mov dl, [rax + 0x38]            ; DIK_LMENU | DIK_RMENU
    or dl, [rax + 0xB8]
    test dl, 0x80
    jz .k2
    or ecx, 1 << 29
    mov esi, WM_SYSKEYDOWN
.k2:
    cmp r13d, VK_F10
    jne .k3
    mov esi, WM_SYSKEYDOWN
.k3:
    test ebx, ebx
    jnz .k4
    or ecx, 0xC0000000
    inc esi                         ; WM_KEYUP / WM_SYSKEYUP
    jmp .k5
.k4:
    cmp byte [rsp + SDL_KEY_REPEAT], 0
    je .k5
    or ecx, 1 << 30
.k5:
    mov edi, [main_hwnd]
    mov edx, r13d
    call post_msg
    jmp .poll
.out:
    add rsp, 128
    pop r13
    pop r12
    pop rbx
    ret

; focus_poll: the main window's own SDL_WINDOW_INPUT_FOCUS flag drives the audio mute,
; not only FOCUS_GAINED/LOST: a window that never gets focus (started from a terminal
; while the user works in another app) sends neither event and would stay audible.
; Hidden or minimised counts as unfocused. audio_focus ignores repeats; the
; FOCUS_GAINED/LOST events above still apply a change within the same pump.
focus_poll:
    cmp byte [sdl_inited], 0
    je .r
    sub rsp, 8
    mov edi, [main_hwnd]
    call win_get
    test rax, rax
    jz .done
    mov rdi, [rax + WN_SDL]
    test rdi, rdi
    jz .done
    call [sdl_SDL_GetWindowFlags]
    xor edi, edi
    test eax, SDL_WINDOW_HIDDEN | SDL_WINDOW_MINIMIZED
    jnz .set
    test eax, SDL_WINDOW_INPUT_FOCUS
    setnz dil
.set:
    call _audio_focus
.done:
    add rsp, 8
.r:
    ret

; hold_window: with --hold, keep pumping SDL events for 5 s so the window can be seen
; (called on the way out, e.g. at an unimplemented import)
hold_window:
    push rbx
    cmp byte [hold], 0
    je .out
    cmp byte [sdl_inited], 0
    je .out
    lea rdi, [msg_hold]
    call _puts
    mov ebx, 250
.loop:
    call pump_sdl
    mov edi, 20000
    call _usleep
    dec ebx
    jnz .loop
.out:
    pop rbx
    ret

; ---- classes and windows -----------------------------------------------------
u32_RegisterClassA:         ; (WNDCLASSA*) -> ATOM
    HENTER
    mov r12d, ARG(0)
    mov eax, [n_classes]
    cmp eax, MAX_CLASSES
    jae .full
    mov r13d, eax
    mov edi, [r12 + 36]             ; lpszClassName
    call _strdup
    lea rcx, [class_name]
    mov [rcx + r13*8], rax
    mov eax, [r12 + 4]              ; lpfnWndProc
    lea rcx, [class_proc]
    mov [rcx + r13*4], eax
    inc dword [n_classes]
    lea rdi, [fmt_regclass]
    mov esi, [r12 + 36]
    mov edx, [r12 + 4]
    xor eax, eax
    call _printf
    lea eax, [r13 + 0xC000]
    HRET
.full:
    xor eax, eax
    HRET

; CreateWindowExA(exstyle, class, title, style, x, y, w, h, parent, menu, hinst, param)
u32_CreateWindowExA:
    HENTER
    xor r12d, r12d                  ; find the class -> wndproc
.cls:
    cmp r12d, [n_classes]
    jae .no_class
    lea rax, [class_name]
    mov rdi, [rax + r12*8]
    mov esi, ARG(1)
    call _strcasecmp
    test eax, eax
    jz .have_class
    inc r12d
    jmp .cls
.have_class:
    lea rax, [class_proc]
    mov r13d, [rax + r12*4]
    xor r12d, r12d                  ; free window slot
.slot:
    cmp r12d, MAX_WINDOWS
    jae .no_class
    imul eax, r12d, WN_SIZE
    lea r14, [windows]
    add r14, rax
    cmp dword [r14 + WN_LIVE], 0
    je .have_slot
    inc r12d
    jmp .slot
.have_slot:
    call sdl_ensure
    mov edi, ARG(2)
    test edi, edi
    jnz .title
    lea rdi, [s_empty_str]
.title:
    mov esi, ARG(6)
    mov edx, ARG(7)
    cmp esi, 0x80000000             ; CW_USEDEFAULT
    jne .wok
    mov esi, 640
    mov edx, 480
.wok:
    mov [r14 + WN_W], esi
    mov [r14 + WN_H], edx
    mov ecx, SDL_WINDOW_HIDDEN      ; shown by ShowWindow, like WS_VISIBLE-less Win32
    call [sdl_SDL_CreateWindow]
    test rax, rax
    jz .sdl_fail
    mov [r14 + WN_SDL], rax
    mov [r14 + WN_PROC], r13d
    mov eax, ARG(4)
    cmp eax, 0x80000000
    jne .x
    xor eax, eax
.x:
    mov [r14 + WN_X], eax
    mov eax, ARG(5)
    cmp eax, 0x80000000
    jne .y
    xor eax, eax
.y:
    mov [r14 + WN_Y], eax
    mov eax, ARG(3)
    mov [r14 + WN_STYLE], eax
    mov eax, ARG(0)
    mov [r14 + WN_EXSTYLE], eax
    mov dword [r14 + WN_VIS], 0
    mov dword [r14 + WN_LIVE], 1
    lea r12d, [HWND_BASE + r12*4]
    cmp dword [main_hwnd], 0
    jne .not_main
    mov [main_hwnd], r12d
.not_main:
    lea rdi, [fmt_createwin]
    mov esi, ARG(2)
    mov edx, [r14 + WN_W]
    mov ecx, [r14 + WN_H]
    mov r8d, r12d
    mov r9d, r13d
    xor eax, eax
    call _printf
    ; CREATESTRUCTA {param, hinst, menu, parent, cy, cx, y, x, style, name, class, exstyle}
    mov eax, [low_createstruct]
    mov ecx, ARG(11)
    mov [rax], ecx
    mov ecx, ARG(10)
    mov [rax + 4], ecx
    mov ecx, ARG(9)
    mov [rax + 8], ecx
    mov ecx, ARG(8)
    mov [rax + 12], ecx
    mov ecx, [r14 + WN_H]
    mov [rax + 16], ecx
    mov ecx, [r14 + WN_W]
    mov [rax + 20], ecx
    mov ecx, [r14 + WN_Y]
    mov [rax + 24], ecx
    mov ecx, [r14 + WN_X]
    mov [rax + 28], ecx
    mov ecx, ARG(3)
    mov [rax + 32], ecx
    mov ecx, ARG(2)
    mov [rax + 36], ecx
    mov ecx, ARG(1)
    mov [rax + 40], ecx
    mov ecx, ARG(0)
    mov [rax + 44], ecx
    ; creation-time messages, Win32 order (WM_NCCREATE result ignored)
    mov edi, r12d
    mov esi, WM_NCCREATE
    xor edx, edx
    mov ecx, [low_createstruct]
    call send_msg
    mov edi, r12d
    mov esi, WM_CREATE
    xor edx, edx
    mov ecx, [low_createstruct]
    call send_msg
    mov edi, r12d
    call send_size_move
    mov eax, r12d
    HRET
.no_class:
    lea rdi, [fmt_noclass]
    mov esi, ARG(1)
    xor eax, eax
    call _printf
    xor eax, eax
    HRET
.sdl_fail:
    call [sdl_SDL_GetError]
    lea rdi, [fmt_sdl_win_fail]
    mov rsi, rax
    xor eax, eax
    call _printf
    xor eax, eax
    HRET

; send_size_move(edi = HWND): WM_SIZE + WM_MOVE with the current geometry
send_size_move:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    call win_get
    test rax, rax
    jz .out
    mov r12, rax
    mov ecx, [r12 + WN_H]
    shl ecx, 16
    movzx eax, word [r12 + WN_W]
    or ecx, eax
    mov edi, ebx
    mov esi, WM_SIZE
    xor edx, edx                    ; SIZE_RESTORED
    call send_msg
    mov ecx, [r12 + WN_Y]
    shl ecx, 16
    movzx eax, word [r12 + WN_X]
    or ecx, eax
    mov edi, ebx
    mov esi, WM_MOVE
    xor edx, edx
    call send_msg
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

u32_ShowWindow:             ; (hwnd, cmd) -> previously visible
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .bad
    mov r12, rax
    mov r13d, [r12 + WN_VIS]
    mov rdi, [r12 + WN_SDL]
    cmp ARG(1), 0                   ; SW_HIDE
    je .hide
    call [sdl_SDL_ShowWindow]
    mov r14d, eax
    mov dword [r12 + WN_VIS], 1
    lea rdi, [fmt_showwin]
    mov esi, ARG(0)
    movzx edx, r14b
    xor eax, eax
    call _printf
    test r13d, r13d
    jnz .ret
    ; first show of a top-level window: it becomes the active, focused window
    mov edi, ARG(0)
    mov esi, WM_SHOWWINDOW
    mov edx, 1
    xor ecx, ecx
    call send_msg
    mov edi, ARG(0)
    mov esi, WM_ACTIVATEAPP
    mov edx, 1
    xor ecx, ecx
    call send_msg
    mov edi, ARG(0)
    mov esi, WM_NCACTIVATE
    mov edx, 1
    xor ecx, ecx
    call send_msg
    mov edi, ARG(0)
    mov esi, WM_ACTIVATE
    mov edx, 1                      ; WA_ACTIVE
    xor ecx, ecx
    call send_msg
    mov edi, ARG(0)
    mov esi, WM_SETFOCUS
    xor edx, edx
    xor ecx, ecx
    call send_msg
    jmp .ret
.hide:
    call [sdl_SDL_HideWindow]
    mov dword [r12 + WN_VIS], 0
.ret:
    mov eax, r13d
    HRET
.bad:
    xor eax, eax
    HRET

u32_GetWindowRect:          ; (hwnd, RECT*): no frame, window rect = client area at x,y
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .bad
    mov ecx, ARG(1)
    mov edx, [rax + WN_X]
    mov [rcx], edx
    add edx, [rax + WN_W]
    mov [rcx + 8], edx
    mov edx, [rax + WN_Y]
    mov [rcx + 4], edx
    add edx, [rax + WN_H]
    mov [rcx + 12], edx
    mov eax, 1
    HRET
.bad:
    xor eax, eax
    HRET

u32_GetClientRect:          ; (hwnd, RECT*)
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .bad
    mov ecx, ARG(1)
    mov qword [rcx], 0
    mov edx, [rax + WN_W]
    mov [rcx + 8], edx
    mov edx, [rax + WN_H]
    mov [rcx + 12], edx
    mov eax, 1
    HRET
.bad:
    xor eax, eax
    HRET

; SetWindowPos(hwnd, after, x, y, cx, cy, flags)
SWP_NOSIZE equ 1
SWP_NOMOVE equ 2
SWP_SHOWWINDOW equ 0x40
SWP_HIDEWINDOW equ 0x80
u32_SetWindowPos:
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .bad
    mov r12, rax
    mov r13d, ARG(6)
    test r13d, SWP_NOSIZE
    jnz .move
    mov esi, ARG(4)
    mov edx, ARG(5)
    mov [r12 + WN_W], esi
    mov [r12 + WN_H], edx
    mov rdi, [r12 + WN_SDL]
    call [sdl_SDL_SetWindowSize]
.move:
    test r13d, SWP_NOMOVE
    jnz .show
    mov esi, ARG(2)
    mov edx, ARG(3)
    mov [r12 + WN_X], esi
    mov [r12 + WN_Y], edx
    mov rdi, [r12 + WN_SDL]
    call [sdl_SDL_SetWindowPosition]
.show:
    test r13d, SWP_SHOWWINDOW
    jz .hide
    mov rdi, [r12 + WN_SDL]
    call [sdl_SDL_ShowWindow]
    mov dword [r12 + WN_VIS], 1
.hide:
    test r13d, SWP_HIDEWINDOW
    jz .msgs
    mov rdi, [r12 + WN_SDL]
    call [sdl_SDL_HideWindow]
    mov dword [r12 + WN_VIS], 0
.msgs:
    mov eax, r13d
    and eax, SWP_NOSIZE | SWP_NOMOVE
    cmp eax, SWP_NOSIZE | SWP_NOMOVE
    je .ok
    mov edi, ARG(0)
    call send_size_move
.ok:
    mov eax, 1
    HRET
.bad:
    xor eax, eax
    HRET

u32_DestroyWindow:          ; (hwnd)
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .bad
    mov r12, rax
    mov edi, ARG(0)
    mov esi, WM_DESTROY
    xor edx, edx
    xor ecx, ecx
    call send_msg
    mov rdi, [r12 + WN_SDL]
    call [sdl_SDL_DestroyWindow]
    mov dword [r12 + WN_LIVE], 0
    mov eax, ARG(0)
    cmp [main_hwnd], eax
    jne .ok
    mov dword [main_hwnd], 0
.ok:
    mov eax, 1
    HRET
.bad:
    xor eax, eax
    HRET

u32_SetWindowTextA:         ; (hwnd, text)
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .bad
    mov rdi, [rax + WN_SDL]
    mov esi, ARG(1)
    call [sdl_SDL_SetWindowTitle]
    mov eax, 1
    HRET
.bad:
    xor eax, eax
    HRET

; GetWindowLongA / SetWindowLongA(hwnd, index[, value])
GWL_WNDPROC  equ -4
GWL_STYLE    equ -16
GWL_EXSTYLE  equ -20
GWL_USERDATA equ -21
; rax = win_long_slot(rax = record, ecx = index) -> pointer to the u32, or 0
win_long_slot:
    cmp ecx, GWL_WNDPROC
    je .proc
    cmp ecx, GWL_STYLE
    je .style
    cmp ecx, GWL_EXSTYLE
    je .ex
    cmp ecx, GWL_USERDATA
    je .user
    xor eax, eax
    ret
.proc:
    add rax, WN_PROC
    ret
.style:
    add rax, WN_STYLE
    ret
.ex:
    add rax, WN_EXSTYLE
    ret
.user:
    add rax, WN_USER
    ret

u32_GetWindowLongA:
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .zero
    mov ecx, ARG(1)
    call win_long_slot
    test rax, rax
    jz .zero
    mov eax, [rax]
    HRET
.zero:
    xor eax, eax
    HRET

u32_SetWindowLongA:         ; -> previous value
    HENTER
    mov edi, ARG(0)
    call win_get
    test rax, rax
    jz .zero
    mov ecx, ARG(1)
    call win_long_slot
    test rax, rax
    jz .zero
    mov edx, ARG(2)
    xchg edx, [rax]
    mov eax, edx
    HRET
.zero:
    xor eax, eax
    HRET

u32_CallWindowProcA:        ; (proc, hwnd, msg, wParam, lParam)
    HENTER
    mov edi, ARG(0)
    lea rsi, [rbx + 4]
    mov edx, 4
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    HRET

; ---- messages ------------------------------------------------------------
; PeekMessageA(MSG*, hwnd, min, max, remove): posted queue only, filters ignored
u32_PeekMessageA:
    HENTER
    call pump_sdl
    mov eax, [msgq_head]
    cmp eax, [msgq_tail]
    je .empty
    and eax, MSGQ_LEN - 1
    shl eax, 5
    lea rsi, [msgq]
    add rsi, rax
    mov edi, ARG(0)
    mov rax, [rsi]                  ; hwnd, message
    mov [rdi], rax
    mov rax, [rsi + 8]              ; wParam, lParam
    mov [rdi + 8], rax
    push rdi
    sub rsp, 8
    call k32_GetTickCount
    add rsp, 8
    pop rdi
    mov [rdi + 16], eax             ; time
    mov qword [rdi + 20], 0         ; pt
    test ARG(4), 1                  ; PM_REMOVE
    jz .keep
    inc dword [msgq_head]
.keep:
    mov eax, 1
    HRET
.empty:
    xor eax, eax
    HRET

u32_DispatchMessageA:       ; (MSG*) -> WndProc result
    HENTER
    mov eax, ARG(0)
    mov edi, [rax]
    mov esi, [rax + 4]
    cmp esi, WM_QUIT
    je .zero
    mov edx, [rax + 8]
    mov ecx, [rax + 12]
    call send_msg
    HRET
.zero:
    xor eax, eax
    HRET

u32_PostMessageA:           ; (hwnd, msg, wParam, lParam)
    sub rsp, 8
    mov ecx, [rdi + 12]
    mov edx, [rdi + 8]
    mov esi, [rdi + 4]
    mov edi, [rdi]
    call post_msg
    add rsp, 8
    ret

u32_SendMessageA:           ; (hwnd, msg, wParam, lParam)
    sub rsp, 8
    mov ecx, [rdi + 12]
    mov edx, [rdi + 8]
    mov esi, [rdi + 4]
    mov edi, [rdi]
    call send_msg
    add rsp, 8
    ret

u32_PostQuitMessage:        ; (code)
    sub rsp, 8
    mov edx, [rdi]
    xor edi, edi
    mov esi, WM_QUIT
    xor ecx, ecx
    call post_msg
    add rsp, 8
    ret

; DefWindowProcA(hwnd, msg, wParam, lParam)
u32_DefWindowProcA:
    HENTER
    mov eax, ARG(1)
    cmp eax, WM_NCCREATE
    je .one
    cmp eax, WM_NCACTIVATE
    je .one
    cmp eax, WM_CLOSE
    jne .zero
    mov edi, ARG(0)                 ; WM_CLOSE -> DestroyWindow
    sub rsp, 16
    mov [rsp], edi
    mov rdi, rsp
    call u32_DestroyWindow
    add rsp, 16
.zero:
    xor eax, eax
    HRET
.one:
    mov eax, 1
    HRET

; ---- misc --------------------------------------------------------------------
SM_CXSCREEN equ 0
SM_CYSCREEN equ 1
u32_GetSystemMetrics:       ; (index): screen size from SDL's desktop mode
    HENTER
    mov r12d, ARG(0)
    cmp r12d, SM_CYSCREEN
    ja .other
    call sdl_ensure
    call [sdl_SDL_GetPrimaryDisplay]
    mov edi, eax
    call [sdl_SDL_GetDesktopDisplayMode]
    test rax, rax
    jz .fallback
    mov eax, [rax + 8 + r12*4]      ; SDL_DisplayMode {displayID, format, w, h, ...}
    HRET
.fallback:
    mov eax, 1024
    mov ecx, 768
    test r12d, r12d
    cmovnz eax, ecx
    HRET
.other:
    lea rdi, [fmt_metrics]
    mov esi, r12d
    xor eax, eax
    call _printf
    xor eax, eax
    HRET

u32_LoadIconA:              ; (hinst, name) -> token handle
    mov eax, 0x00EE0001
    ret
u32_LoadCursorA:
    mov eax, 0x00EE0002
    ret
u32_GetDC:                  ; (hwnd) -> HDC token
    mov eax, 0x00DC0001
    ret

u32_ShowCursor:             ; (show) -> new display counter
    sub rsp, 8
    mov eax, [rdi]
    mov ecx, -1
    test eax, eax
    jz .dec
    mov ecx, 1
.dec:
    add ecx, [cursor_count]
    mov [cursor_count], ecx
    cmp byte [sdl_inited], 0
    je .r
    test ecx, ecx
    js .hide
    call [sdl_SDL_ShowCursor]
    jmp .r
.hide:
    call [sdl_SDL_HideCursor]
.r:
    mov eax, [cursor_count]
    add rsp, 8
    ret

u32_MessageBoxA:            ; (hwnd, text, caption, type) -> IDOK
    HENTER
    lea rdi, [fmt_msgbox]
    mov esi, ARG(2)
    mov edx, ARG(1)
    test esi, esi
    jnz .c
    lea rsi, [s_empty_str]
.c:
    xor eax, eax
    call _printf
    mov eax, 1
    HRET

u32_GetKeyboardLayoutNameA: ; (buf[9]) -> "00000409" (US)
    HENTER
    mov edi, ARG(0)
    lea rsi, [s_kbd_us]
    call _strcpy
    mov eax, 1
    HRET

u32_SetTimer:               ; (hwnd, id, ms, proc) -> id; no WM_TIMER is delivered yet
    HENTER
    lea rdi, [fmt_settimer]
    mov esi, ARG(1)
    mov edx, ARG(2)
    xor eax, eax
    call _printf
    mov eax, ARG(1)
    test eax, eax
    jnz .r
    mov eax, 1
.r:
    HRET

u32_DialogBoxParamA:        ; (hinst, template, parent, proc, param): no dialogs
    HENTER
    lea rdi, [fmt_dialog]
    mov esi, ARG(1)
    xor eax, eax
    call _printf
    mov eax, -1
    HRET

; wsprintfA(buf, fmt, ...) cdecl: %[-#0 +][width][.prec][h|l]{d,i,u,x,X,c,s,%}
; Each conversion is handed to the host snprintf with its 32-bit argument.
u32_wsprintfA:
    HENTER 48                       ; [rsp] spec buffer (32 bytes)
    mov r12d, ARG(0)                ; out
    mov r13d, ARG(1)                ; format
    lea r14, [rbx + 8]              ; next vararg
    xor ebx, ebx                    ; out length (rbx is free once args are known)
.c:
    movzx eax, byte [r13]
    test al, al
    jz .end
    inc r13
    cmp al, '%'
    je .spec
.lit:
    mov [r12 + rbx], al
    inc ebx
    cmp ebx, 1023
    jb .c
    jmp .end
.spec:
    cmp byte [r13], '%'
    jne .collect
    inc r13
    jmp .lit
.collect:
    mov byte [rsp], '%'
    mov ecx, 1
.flag:
    movzx eax, byte [r13]
    test al, al
    jz .end
    cmp al, 'h'                     ; size prefixes: drop (every argument is 32-bit)
    je .skip
    cmp al, 'l'
    je .skip
    mov [rsp + rcx], al
    inc r13
    inc ecx
    cmp ecx, 30
    jae .end
    cmp al, 'a'                     ; a letter ends the spec
    jb .flag_upper
    cmp al, 'z'
    jbe .conv
    jmp .flag
.flag_upper:
    cmp al, 'X'
    je .conv
    jmp .flag
.skip:
    inc r13
    jmp .flag
.conv:
    mov byte [rsp + rcx], 0
    lea rdi, [r12 + rbx]
    mov esi, 1024
    sub esi, ebx
    mov rdx, rsp
    mov ecx, [r14]
    add r14, 4
    cmp al, 's'
    jne .fmt
    test ecx, ecx                   ; NULL %s prints "(null)" like Windows
    jnz .fmt
    lea rcx, [s_null]
.fmt:
    xor eax, eax
    call _snprintf
    test eax, eax
    js .end
    add ebx, eax
    cmp ebx, 1023
    jb .c
    mov ebx, 1023
.end:
    mov byte [r12 + rbx], 0
    mov eax, ebx
    HRET

; ---- GDI32 -----------------------------------------------------------------
gdi_GetDeviceCaps:          ; (hdc, index)
    HENTER
    mov eax, ARG(1)
    cmp eax, 12                     ; BITSPIXEL
    je .bpp
    cmp eax, 14                     ; PLANES
    je .one
    cmp eax, 8                      ; HORZRES
    je .w
    cmp eax, 10                     ; VERTRES
    je .h
    cmp eax, 116                    ; VREFRESH
    je .hz
    lea rdi, [fmt_devcaps]
    mov esi, eax
    xor eax, eax
    call _printf
    xor eax, eax
    HRET
.bpp:
    mov eax, 32
    HRET
.one:
    mov eax, 1
    HRET
.hz:
    mov eax, 60
    HRET
.w:
    sub rsp, 16
    mov dword [rsp], SM_CXSCREEN
    mov rdi, rsp
    call u32_GetSystemMetrics
    add rsp, 16
    HRET
.h:
    sub rsp, 16
    mov dword [rsp], SM_CYSCREEN
    mov rdi, rsp
    call u32_GetSystemMetrics
    add rsp, 16
    HRET

section .data
align 8
shimtab_user32:
    dq s_user32
    SHIM "RegisterClassA", 4, u32_RegisterClassA
    SHIM "CreateWindowExA", 48, u32_CreateWindowExA
    SHIM "ShowWindow", 8, u32_ShowWindow
    SHIM "UpdateWindow", 4, h_ret1
    SHIM "GetWindowRect", 8, u32_GetWindowRect
    SHIM "GetClientRect", 8, u32_GetClientRect
    SHIM "SetWindowPos", 28, u32_SetWindowPos
    SHIM "DestroyWindow", 4, u32_DestroyWindow
    SHIM "SetWindowTextA", 8, u32_SetWindowTextA
    SHIM "GetWindowLongA", 8, u32_GetWindowLongA
    SHIM "SetWindowLongA", 12, u32_SetWindowLongA
    SHIM "CallWindowProcA", 20, u32_CallWindowProcA
    SHIM "PeekMessageA", 20, u32_PeekMessageA
    SHIM "TranslateMessage", 4, h_ret0
    SHIM "DispatchMessageA", 4, u32_DispatchMessageA
    SHIM "PostMessageA", 16, u32_PostMessageA
    SHIM "SendMessageA", 16, u32_SendMessageA
    SHIM "PostQuitMessage", 4, u32_PostQuitMessage
    SHIM "DefWindowProcA", 16, u32_DefWindowProcA
    SHIM "GetSystemMetrics", 4, u32_GetSystemMetrics
    SHIM "LoadIconA", 8, u32_LoadIconA
    SHIM "LoadCursorA", 8, u32_LoadCursorA
    SHIM "GetDC", 4, u32_GetDC
    SHIM "ReleaseDC", 8, h_ret1
    SHIM "ShowCursor", 4, u32_ShowCursor
    SHIM "SetForegroundWindow", 4, h_ret1
    SHIM "MessageBoxA", 16, u32_MessageBoxA
    SHIM "GetKeyboardLayoutNameA", 4, u32_GetKeyboardLayoutNameA
    SHIM "SetTimer", 16, u32_SetTimer
    SHIM "KillTimer", 8, h_ret1
    SHIM "DialogBoxParamA", 20, u32_DialogBoxParamA
    SHIM "FindWindowExA", 16, h_ret0
    SHIM "wsprintfA", 0, u32_wsprintfA
    dq 0
shimtab_gdi32:
    dq s_gdi32
    SHIM "GetDeviceCaps", 8, gdi_GetDeviceCaps
    dq 0

section .rodata
s_user32:    db "USER32", 0
s_gdi32:     db "GDI32", 0
s_env_sdl:   db "GTA2_SDL3_LIB", 0
s_env_home:  db "HOME", 0
s_kbd_us:    db "00000409", 0
s_null:      db "(null)", 0
fmt_sdl_default: db "%s/.local/opt/sdl3-x86_64/lib/libSDL3.0.dylib", 0
fmt_sdl_loaded: db "SDL %d.%d.%d loaded from %s", 10, 0
fmt_sdl_fail: db "loader: dlopen SDL3 failed: %s (set GTA2_SDL3_LIB)", 10, 0
fmt_sdl_init_fail: db "  [w32] SDL_Init(VIDEO) failed: %s", 10, 0
fmt_sdl_win_fail: db "  [w32] SDL_CreateWindow failed: %s", 10, 0
fmt_regclass: db "  [w32] RegisterClassA(%s) wndproc 0x%x", 10, 0
fmt_createwin: db "  [w32] CreateWindowExA(%s) %dx%d -> hwnd 0x%x (SDL window), wndproc 0x%x", 10, 0
fmt_showwin: db "  [w32] ShowWindow(0x%x): SDL_ShowWindow -> %d", 10, 0
fmt_noclass: db "  [w32] CreateWindowExA: unknown class %s -> NULL", 10, 0
fmt_send:    db "  [w32]   -> WndProc(msg 0x%x, 0x%x, 0x%x) hwnd 0x%x", 10, 0
fmt_metrics: db "  [w32] GetSystemMetrics(%d): unknown -> 0", 10, 0
fmt_devcaps: db "  [w32] GetDeviceCaps(%d): unknown -> 0", 10, 0
fmt_msgbox:  db "  [MessageBox] %s: %s", 10, 0
fmt_settimer: db "  [w32] SetTimer(id %d, %d ms): no WM_TIMER delivery yet", 10, 0
fmt_dialog:  db "  [w32] DialogBoxParamA(template 0x%x): dialogs unsupported -> -1", 10, 0
msg_sdl:     db "cannot load SDL3", 0
msg_hold:    db "--hold: keeping the window up for 5 s", 0
msg_sdl_sym: db "SDL3 is missing a function the loader needs", 0
section .bss
alignb 8
%unmacro SDLFN 1
%macro SDLFN 1
sdl_%1: resq 1
%endmacro
SDLFNS
sdl_path:    resb 1024
windows:     resb WN_SIZE * MAX_WINDOWS
class_name:  resq MAX_CLASSES
class_proc:  resd MAX_CLASSES
n_classes:   resd 1
main_hwnd:   resd 1
msgq_head:   resd 1
msgq_tail:   resd 1
cursor_count: resd 1
low_createstruct: resd 1
sdl_inited:  resb 1
alignb 8
msgq:        resb 32 * MSGQ_LEN
section .text
