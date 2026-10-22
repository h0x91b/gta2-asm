; w32_dinput.asm — COM object helper + DirectInput 8 fed by SDL3 keyboard/mouse events.
;
; COM: an interface is a shim table whose entries are its methods in vtable order
; (names "Interface::Method"). com_new builds the vtable once (each method a normal
; import slot, so it shows up in --trace and unimplemented ones stop the run) and
; allocates the object in low memory: {u32 vtbl, u32 refcount, u32 kind, ...}.
;
; Input model (how gta2.exe reads it, see docs/win32-shims.md "Input"):
;   - pump_sdl (w32_user32.asm) turns SDL key events into input_key(DIK, down), mouse
;     events into the accumulators below, focus events into input_focus.
;   - di_keys[256] is the one keyboard state (0x80 = down) every keyboard device's
;     GetDeviceState copies out. The frontend menu reads it that way (0x452000).
;   - Every key change is also appended to kring, a ring of DIDEVICEOBJECTDATA-like
;     records with a global sequence number. Each device keeps its own read cursor
;     (DV_RSEQ), set to the ring head on Acquire, so buffered GetDeviceData (the
;     in-game reader, 0x44C0F0) sees exactly the changes since it acquired.
;   - GetDeviceState also ORs in keys pressed since this device's previous read
;     (kring records past DV_SSEQ), so a tap that starts and ends between two
;     polls is still seen once. Windows would lose it; the menu polls at frame rate.
;   - Key repeat is not a DirectInput event: SDL repeats only reach WM_KEYDOWN.
;   - Losing focus releases every held key (key-up records go into the ring) instead
;     of DIERR_INPUTLOST: the in-game reader is change-based and would keep a key held.
;   - Keys already down when a keyboard is acquired (DV_STALE) read as up through
;     GetDeviceState until they are released. InitFrontend (0x456A60) zeroes the
;     menu's previous-key bytes, so the RETURN that confirmed quitting a game, still
;     held when the frontend polls for the first time, would be a fresh press and
;     start the level again. Windows hides that behind a slow frontend load.

DI_OK              equ 0
DI_NOEFFECT        equ 1                ; S_FALSE
DI_BUFFEROVERFLOW  equ 1
DIERR_INVALIDPARAM equ 0x80070057
DIERR_NOTACQUIRED  equ 0x8007000C
DIERR_OTHERAPPHASPRIO equ 0x80070005
DIERR_NOTBUFFERED  equ 0x80040207
E_NOINTERFACE      equ 0x80004002
DIGDD_PEEK         equ 1
DISCL_EXCLUSIVE    equ 1
DISCL_FOREGROUND   equ 4
DIPROP_BUFFERSIZE  equ 1                ; MAKEDIPROP(1): a small integer, not a GUID*
GUID_SysKeyboard   equ 0x6F1D2B61       ; Data1 of the predefined device GUIDs
GUID_SysMouse      equ 0x6F1D2B60

COM_VTBL       equ 0
COM_REFS       equ 4
COM_KIND       equ 8
; device object (COM header + DirectInput state), low memory
DV_ACQ         equ 12                   ; byte: acquired
DV_COOP        equ 16                   ; SetCooperativeLevel flags
DV_FMT         equ 20                   ; SetDataFormat dwDataSize (0 = no format yet)
DV_BUFSZ       equ 24                   ; DIPROP_BUFFERSIZE (0 = unbuffered)
DV_RSEQ        equ 28                   ; next kring sequence this device reads
DV_SSEQ        equ 32                   ; kring sequence GetDeviceState has seen
DV_SHADOW      equ 36                   ; 256 bytes: last state handed out (traces)
DV_STALE       equ DV_SHADOW + 256      ; 256 bytes: down at Acquire, not yet released
DV_SIZE        equ DV_STALE + 256

KRING          equ 1024                 ; buffered key records (power of two)
KR_SIZE        equ 16                   ; {dwOfs = DIK, dwData, dwTimeStamp, dwSequence}
WHEEL_DELTA    equ 120

section .text

; eax = com_new(rdi = interface shim table, esi = object size)
com_new:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi
    mov eax, [rbx + 8 + SH_POP + 4]  ; the first entry's spare dword caches the vtable
    test eax, eax
    jnz .have_vtbl
    xor r13d, r13d                  ; count methods
.count:
    imul eax, r13d, SHIM_SIZE
    cmp qword [rbx + 8 + rax + SH_NAME], 0
    je .counted
    inc r13d
    jmp .count
.counted:
    lea edi, [r13*4]
    mov esi, 16
    call low_alloc
    mov r14d, eax                   ; vtable
    xor r15d, r15d
.method:
    cmp r15d, r13d
    jae .built
    imul eax, r15d, SHIM_SIZE
    mov rdi, [rbx]
    mov rsi, [rbx + 8 + rax + SH_NAME]
    xor edx, edx
    call new_slot
    mov [r14 + r15*4], eax
    inc r15d
    jmp .method
.built:
    mov [rbx + 8 + SH_POP + 4], r14d
    mov eax, r14d
.have_vtbl:
    mov r13d, eax
    mov edi, r12d
    mov esi, 16
    call low_alloc
    mov [rax + COM_VTBL], r13d
    mov dword [rax + COM_REFS], 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

com_AddRef:                 ; (this)
    mov eax, [rdi]
    inc dword [rax + COM_REFS]
    mov eax, [rax + COM_REFS]
    ret
com_Release:                ; (this): objects are never freed (low arena)
    mov eax, [rdi]
    dec dword [rax + COM_REFS]
    mov eax, [rax + COM_REFS]
    ret
com_QueryInterface:         ; (this, riid, ppv): only what we created exists
    mov eax, [rdi + 8]
    test eax, eax
    jz .r
    mov dword [rax], 0
.r:
    mov eax, E_NOINTERFACE
    ret

; com_ok: method that succeeds doing nothing; logs its first call
com_ok:
    jmp h_silent

; ---- host-side input state ---------------------------------------------------
; setup_input: expand key_table into the scancode -> DIK / VK lookups and DIK names
setup_input:
    lea rsi, [key_table]
.next:
    movzx eax, word [rsi]
    cmp eax, 0xFFFF
    je .done
    movzx ecx, byte [rsi + 2]       ; DIK
    movzx edx, byte [rsi + 3]       ; VK
    lea rdi, [sdl_dik]
    mov [rdi + rax], cl
    lea rdi, [sdl_vk]
    mov [rdi + rax], dl
    mov rax, [rsi + 8]
    lea rdi, [dik_name]
    mov [rdi + rcx*8], rax
    add rsi, 16
    jmp .next
.done:
    sub rsp, 8
    call parse_keys_arg
    add rsp, 8
    ret

; rax = dik_str(edi = DIK): name for traces
dik_str:
    mov eax, edi
    and eax, 0xFF
    lea rcx, [dik_name]
    mov rax, [rcx + rax*8]
    test rax, rax
    jnz .r
    lea rax, [s_dik_unknown]
.r:
    ret

; input_key(edi = DIK, esi = down): update di_keys, append a change record to kring
input_key:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    call dbgmenu_key                ; the debug menu (debug_menu.asm) may take it
    test eax, eax
    jnz .out
    mov edi, ebx
    mov esi, r12d
    and edi, 0xFF
    mov ebx, edi
    xor r12d, r12d
    test esi, esi
    jz .v
    mov r12d, 0x80
.v:
    lea rax, [di_keys]
    cmp [rax + rbx], r12b
    je .out                         ; no change (DirectInput has no key repeat)
    mov [rax + rbx], r12b
    call k32_GetTickCount
    mov ecx, [kseq]
    mov edx, ecx
    and edx, KRING - 1
    shl edx, 4
    lea r13, [kring]
    add r13, rdx
    mov [r13], ebx
    mov [r13 + 4], r12d
    mov [r13 + 8], eax
    mov [r13 + 12], ecx
    inc dword [kseq]
    cmp byte [trace_input], 0
    je .out
    mov edi, ebx
    call dik_str
    lea rdi, [fmt_in_key]
    lea rsi, [s_down]
    lea rcx, [s_up]
    test r12d, r12d
    cmovz rsi, rcx
    mov rdx, rax
    mov ecx, ebx
    mov r8d, [r13 + 12]
    xor eax, eax
    call _printf
.out:
    pop r13
    pop r12
    pop rbx
    ret

; input_release_all: every held key goes up (focus loss), mouse buttons too
input_release_all:
    push rbx
    xor ebx, ebx
.k:
    lea rax, [di_keys]
    cmp byte [rax + rbx], 0
    je .n
    mov edi, ebx
    xor esi, esi
    call input_key
.n:
    inc ebx
    cmp ebx, 256
    jb .k
    mov qword [mouse_btn], 0
    pop rbx
    ret

; input_focus(edi = 1 gained / 0 lost): SDL keyboard focus changed
WM_ACTIVATE_    equ 0x06
WM_ACTIVATEAPP_ equ 0x1C
input_focus:
    push rbx
    mov ebx, edi
    cmp [have_focus], bl
    je .out
    mov [have_focus], bl
    cmp byte [trace_input], 0
    je .t
    lea rdi, [fmt_in_focus]
    lea rsi, [s_gained]
    lea rax, [s_lost]
    test ebx, ebx
    cmovz rsi, rax
    xor eax, eax
    call _printf
.t:
    test ebx, ebx
    jnz .post
    call input_release_all
    call mouse_capture_off
.post:                              ; the frontend gates its key reads on WM_ACTIVATE
    mov edi, [main_hwnd]
    mov esi, WM_ACTIVATEAPP_
    mov edx, ebx
    xor ecx, ecx
    call post_msg
    mov edi, [main_hwnd]
    mov esi, WM_ACTIVATE_
    mov edx, ebx                    ; WA_INACTIVE 0 / WA_ACTIVE 1
    xor ecx, ecx
    call post_msg
.out:
    pop rbx
    ret

; input_mouse_motion(xmm0 = xrel, xmm1 = yrel) / input_mouse_wheel(xmm0 = y)
input_mouse_motion:
    addss xmm0, [mouse_dx]
    movss [mouse_dx], xmm0
    addss xmm1, [mouse_dy]
    movss [mouse_dy], xmm1
    ret
input_mouse_wheel:
    mov eax, WHEEL_DELTA
    cvtsi2ss xmm1, eax
    mulss xmm0, xmm1
    addss xmm0, [mouse_dz]
    movss [mouse_dz], xmm0
    ret
; input_mouse_button(edi = SDL button 1..5, esi = down)
input_mouse_button:
    dec edi
    cmp edi, 5
    jae .r
    lea rax, [sdl_button_di]        ; SDL left/middle/right/x1/x2 -> DI 0/2/1/3/4
    movzx edi, byte [rax + rdi]
    xor eax, eax
    test esi, esi
    jz .s
    mov eax, 0x80
.s:
    lea rcx, [mouse_btn]
    mov [rcx + rdi], al
.r:
    ret

; eax = take_axis(rdi = float accumulator): whole units out, the fraction stays
take_axis:
    movss xmm0, [rdi]
    cvttss2si eax, xmm0
    cvtsi2ss xmm1, eax
    subss xmm0, xmm1
    movss [rdi], xmm0
    ret

; Exclusive mouse = Windows hides and captures the cursor: SDL relative mode
mouse_capture_on:
    cmp byte [mouse_captured], 0
    jne .r
    mov edi, [main_hwnd]
    call win_get
    test rax, rax
    jz .r
    mov byte [mouse_captured], 1
    sub rsp, 8
    mov rdi, [rax + WN_SDL]
    mov esi, 1
    call [sdl_SDL_SetWindowRelativeMouseMode]
    add rsp, 8
.r:
    ret
mouse_capture_off:
    cmp byte [mouse_captured], 0
    je .r
    mov byte [mouse_captured], 0
    mov edi, [main_hwnd]
    call win_get
    test rax, rax
    jz .r
    sub rsp, 8
    mov rdi, [rax + WN_SDL]
    xor esi, esi
    call [sdl_SDL_SetWindowRelativeMouseMode]
    add rsp, 8
.r:
    ret

; ---- DirectInput8Create / IDirectInput8A ---------------------------------------
; DirectInput8Create(hinst, version, riid, ppvOut, outer)
di_DirectInput8Create:
    HENTER
    lea rdi, [shimtab_idirectinput8]
    mov esi, 16
    call com_new
    mov ecx, ARG(3)
    mov [rcx], eax
    mov r12d, eax
    lea rdi, [fmt_di_create]
    mov esi, ARG(1)
    mov edx, r12d
    xor eax, eax
    call _printf
    xor eax, eax
    HRET

; IDirectInput8A::CreateDevice(this, rguid, lplpDevice, outer)
di_CreateDevice:
    HENTER
    lea rdi, [shimtab_idirectinputdevice8]
    mov esi, DV_SIZE
    call com_new
    mov r12d, eax
    mov ecx, ARG(1)
    mov ecx, [rcx]                  ; GUID.Data1: 6F1D2B61 keyboard, 6F1D2B60 mouse
    mov [r12 + COM_KIND], ecx
    mov ecx, ARG(2)
    mov [rcx], r12d
    lea rdi, [fmt_di_device]
    mov esi, [r12 + COM_KIND]
    call kind_str
    mov rsi, rax
    mov edx, r12d
    mov ecx, [rbx - 4]
    xor eax, eax
    call _printf
    xor eax, eax
    HRET

; rax = kind_str(esi = GUID.Data1)
kind_str:
    lea rax, [s_di_other]
    lea rcx, [s_di_kbd]
    cmp esi, GUID_SysKeyboard
    cmove rax, rcx
    lea rcx, [s_di_mouse]
    cmp esi, GUID_SysMouse
    cmove rax, rcx
    ret

; ---- IDirectInputDevice8A ------------------------------------------------------
di_dev_Release:             ; (this): the last reference unacquires
    HENTER
    mov r12d, ARG(0)
    dec dword [r12 + COM_REFS]
    jnz .r
    mov edi, r12d
    call dev_unacquire
.r:
    mov eax, [r12 + COM_REFS]
    HRET

di_SetDataFormat:           ; (this, DIDATAFORMAT*): remember dwDataSize
    mov eax, [rdi]
    mov ecx, [rdi + 4]
    mov ecx, [rcx + 12]
    mov [rax + DV_FMT], ecx
    xor eax, eax
    ret

di_SetCooperativeLevel:     ; (this, hwnd, flags)
    mov eax, [rdi]
    mov ecx, [rdi + 8]
    mov [rax + DV_COOP], ecx
    xor eax, eax
    ret

di_SetProperty:             ; (this, rguidProp, DIPROPHEADER*): DIPROP_BUFFERSIZE only
    mov eax, [rdi]
    cmp dword [rdi + 4], DIPROP_BUFFERSIZE
    jne .ok
    mov ecx, [rdi + 8]
    mov ecx, [rcx + 16]             ; DIPROPDWORD.dwData
    mov [rax + DV_BUFSZ], ecx
.ok:
    xor eax, eax
    ret

di_GetProperty:             ; (this, rguidProp, DIPROPHEADER*)
    mov eax, [rdi]
    cmp dword [rdi + 4], DIPROP_BUFFERSIZE
    jne .ok
    mov ecx, [rdi + 8]
    mov eax, [rax + DV_BUFSZ]
    mov [rcx + 16], eax
.ok:
    xor eax, eax
    ret

di_Acquire:                 ; (this)
    HENTER
    mov r12d, ARG(0)
    mov eax, DI_NOEFFECT
    cmp byte [r12 + DV_ACQ], 0
    jne .r
    mov eax, DIERR_INVALIDPARAM     ; no data format yet
    cmp dword [r12 + DV_FMT], 0
    je .r
    mov eax, DIERR_OTHERAPPHASPRIO  ; foreground devices need the focus
    test dword [r12 + DV_COOP], DISCL_FOREGROUND
    jz .take
    cmp byte [have_focus], 0
    je .r
.take:
    mov byte [r12 + DV_ACQ], 1
    mov eax, [kseq]                 ; buffered data starts now
    mov [r12 + DV_RSEQ], eax
    mov [r12 + DV_SSEQ], eax
    lea rdi, [r12 + DV_SHADOW]
    xor esi, esi
    mov edx, 256
    call _memset
    cmp dword [r12 + COM_KIND], GUID_SysKeyboard
    jne .not_kbd
    lea rdi, [r12 + DV_STALE]       ; keys held now are not new presses
    lea rsi, [di_keys]
    mov edx, 256
    call _memcpy
    call trace_stale
.not_kbd:
    cmp dword [r12 + COM_KIND], GUID_SysMouse
    jne .ok
    mov qword [mouse_dx], 0         ; motion before Acquire is not reported
    mov dword [mouse_dz], 0
    test dword [r12 + DV_COOP], DISCL_EXCLUSIVE
    jz .ok
    call mouse_capture_on
.ok:
    cmp byte [trace_input], 0
    je .ok0
    lea rdi, [fmt_in_acq]
    mov esi, [r12 + COM_KIND]
    call kind_str
    mov rsi, rax
    mov edx, r12d
    mov ecx, [r12 + DV_COOP]
    mov r8d, [r12 + DV_BUFSZ]
    mov r9d, [rbx - 4]
    xor eax, eax
    call _printf
.ok0:
    xor eax, eax
.r:
    HRET

; trace_stale(r12 = keyboard device): --trace-input line per key held at Acquire
trace_stale:
    cmp byte [trace_input], 0
    je .r
    push rbx
    xor ebx, ebx
.k:
    cmp byte [r12 + DV_STALE + rbx], 0
    je .n
    mov edi, ebx
    call dik_str
    lea rdi, [fmt_in_stale]
    mov esi, r12d
    mov rdx, rax
    xor eax, eax
    call _printf
.n:
    inc ebx
    cmp ebx, 256
    jb .k
    pop rbx
.r:
    ret

di_Unacquire:               ; (this)
    sub rsp, 8
    mov edi, [rdi]
    call dev_unacquire
    add rsp, 8
    ret
; eax = dev_unacquire(edi = device): DI_OK, or DI_NOEFFECT if it was not acquired
dev_unacquire:
    mov eax, DI_NOEFFECT
    cmp byte [rdi + DV_ACQ], 0
    je .r
    mov byte [rdi + DV_ACQ], 0
    cmp dword [rdi + COM_KIND], GUID_SysMouse
    jne .ok
    sub rsp, 8
    call mouse_capture_off
    add rsp, 8
.ok:
    xor eax, eax
.r:
    ret

; IDirectInputDevice8A::GetDeviceState(this, cbData, lpvData)
di_GetDeviceState:
    HENTER
    call pump_sdl
    mov r12d, ARG(0)
    mov eax, DIERR_NOTACQUIRED
    cmp byte [r12 + DV_ACQ], 0
    je .r
    mov eax, [r12 + COM_KIND]
    cmp eax, GUID_SysKeyboard
    je .kbd
    cmp eax, GUID_SysMouse
    je .mouse
    mov edi, ARG(2)                 ; anything else: nothing to report
    xor esi, esi
    mov edx, ARG(1)
    call _memset
    xor eax, eax
    jmp .r
.kbd:
    mov eax, DIERR_INVALIDPARAM
    cmp ARG(1), 256
    jb .r
    mov r13d, ARG(2)
    mov edi, r13d
    lea rsi, [di_keys]
    mov edx, 256
    call _memcpy
    mov eax, [kseq]                 ; + taps since this device's last read
    mov ecx, eax
    sub ecx, [r12 + DV_SSEQ]
    mov edx, KRING
    cmp ecx, edx
    cmova ecx, edx
    mov [r12 + DV_SSEQ], eax
.tap:
    test ecx, ecx
    jz .taps_done
    dec eax
    dec ecx
    mov edx, eax
    and edx, KRING - 1
    shl edx, 4
    lea rsi, [kring]
    cmp dword [rsi + rdx + 4], 0
    je .tap_up
    mov edx, [rsi + rdx]            ; a key-down record: report the key down once
    mov byte [r13 + rdx], 0x80
    jmp .tap
.tap_up:
    mov edx, [rsi + rdx]            ; released since: no longer stale
    mov byte [r12 + DV_STALE + rdx], 0
    jmp .tap
.taps_done:
    xor ecx, ecx                    ; stale keys read as up while still held
    lea rsi, [di_keys]
.stale:
    cmp byte [r12 + DV_STALE + rcx], 0
    je .stale_next
    cmp byte [rsi + rcx], 0
    jne .stale_held
    mov byte [r12 + DV_STALE + rcx], 0
    jmp .stale_next
.stale_held:
    mov byte [r13 + rcx], 0
.stale_next:
    inc ecx
    cmp ecx, 256
    jb .stale
    cmp byte [trace_input], 0
    je .ok
    lea rdi, [r12 + DV_SHADOW]      ; trace only when this device's view changed
    mov esi, r13d
    mov edx, 256
    call _memcmp
    test eax, eax
    jz .ok
    lea rdi, [r12 + DV_SHADOW]
    mov esi, r13d
    mov edx, 256
    call _memcpy
    mov edi, r12d
    mov esi, [rbx - 4]
    lea rdx, [r12 + DV_SHADOW]
    call trace_kbd_state
.ok:
    xor eax, eax
    jmp .r
.mouse:                             ; DIMOUSESTATE (16) / DIMOUSESTATE2 (20)
    mov eax, DIERR_INVALIDPARAM
    mov r13d, ARG(1)
    cmp r13d, 16
    jb .r
    mov r14d, ARG(2)
    mov edi, r14d
    xor esi, esi
    mov edx, r13d
    call _memset
    lea rdi, [mouse_dx]
    call take_axis
    mov [r14], eax
    lea rdi, [mouse_dy]
    call take_axis
    mov [r14 + 4], eax
    lea rdi, [mouse_dz]
    call take_axis
    mov [r14 + 8], eax
    mov eax, [mouse_btn]
    mov [r14 + 12], eax
    cmp r13d, 20
    jb .m4
    mov eax, [mouse_btn + 4]
    mov [r14 + 16], eax
.m4:
    cmp byte [trace_input], 0
    je .ok
    mov eax, [r14]
    or eax, [r14 + 4]
    or eax, [r14 + 8]
    mov ecx, [r14 + 12]
    cmp ecx, [r12 + DV_SHADOW]
    jne .mt
    test eax, eax
    jz .ok
.mt:
    mov [r12 + DV_SHADOW], ecx
    lea rdi, [fmt_in_mouse]
    mov esi, [r14]
    mov edx, [r14 + 4]
    mov ecx, [r14 + 8]
    mov r8d, [r14 + 12]
    bswap r8d                       ; buttons 0..3 left to right
    mov r9d, [rbx - 4]
    xor eax, eax
    call _printf
    jmp .ok
.r:
    HRET

; trace_kbd_state(edi = device, esi = caller, rdx = state): one line, the keys down
trace_kbd_state:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r14, rdx
    mov r12d, edi
    mov r13d, esi
    lea rdi, [fmt_in_state]
    mov esi, r12d
    mov edx, r13d
    xor eax, eax
    call _printf
    xor ebx, ebx
    xor r13d, r13d                  ; keys listed
.k:
    test byte [r14 + rbx], 0x80
    jz .n
    inc r13d
    mov edi, ebx
    call dik_str
    lea rdi, [fmt_in_name]
    mov rsi, rax
    xor eax, eax
    call _printf
.n:
    inc ebx
    cmp ebx, 256
    jb .k
    test r13d, r13d
    jnz .nl
    lea rdi, [s_in_none]
    xor eax, eax
    call _printf
.nl:
    mov edi, 10
    call _putchar
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; IDirectInputDevice8A::GetDeviceData(this, cbObjectData, rgdod, pdwInOut, flags)
di_GetDeviceData:
    HENTER
    call pump_sdl
    mov r12d, ARG(0)
    mov eax, DIERR_NOTACQUIRED
    cmp byte [r12 + DV_ACQ], 0
    je .r
    cmp dword [r12 + COM_KIND], GUID_SysKeyboard
    je .kbd
    mov ecx, ARG(3)                 ; mouse/other: no buffered data
    mov dword [rcx], 0
    xor eax, eax
    jmp .r
.kbd:
    mov eax, DIERR_NOTBUFFERED
    mov ecx, [r12 + DV_BUFSZ]
    test ecx, ecx
    jz .r
    mov eax, KRING
    cmp ecx, eax
    cmova ecx, eax                  ; ecx = what the buffer can hold
    xor r14d, r14d                  ; result
    mov eax, [kseq]
    sub eax, [r12 + DV_RSEQ]        ; available
    cmp eax, ecx
    jbe .avail
    mov edx, [kseq]                 ; overflow: the oldest records are gone
    sub edx, ecx
    mov [r12 + DV_RSEQ], edx
    mov eax, ecx
    mov r14d, DI_BUFFEROVERFLOW
.avail:
    mov ecx, ARG(3)
    mov r13d, [rcx]                 ; requested
    cmp r13d, eax
    cmova r13d, eax                 ; r13d = delivered
    mov [rcx], r13d
    cmp ARG(2), 0
    je .advance                     ; NULL buffer: count (PEEK) or flush
    xor ecx, ecx
.copy:
    cmp ecx, r13d
    jae .advance
    push rcx
    sub rsp, 8
    mov eax, [r12 + DV_RSEQ]
    add eax, ecx
    and eax, KRING - 1
    shl eax, 4
    lea rsi, [kring]
    add rsi, rax                    ; record
    mov eax, ARG(1)
    imul eax, ecx
    add eax, ARG(2)
    mov edi, eax                    ; DIDEVICEOBJECTDATA[i]
    mov rax, [rsi]
    mov [rdi], rax
    mov rax, [rsi + 8]
    mov [rdi + 8], rax
    cmp ARG(1), 20
    jb .no_app
    mov dword [rdi + 16], 0         ; uAppData
.no_app:
    cmp byte [trace_input], 0
    je .ct
    test ARG(4), DIGDD_PEEK
    jnz .ct
    push rsi
    sub rsp, 8
    mov edi, [rsi]
    call dik_str
    mov rsi, [rsp + 8]
    lea rdi, [fmt_in_data]
    mov edx, [rsi + 12]             ; sequence
    lea rcx, [s_down]
    lea r8, [s_up]
    cmp dword [rsi + 4], 0
    cmove rcx, r8
    mov r8, rax
    mov r9d, [rsi]
    mov esi, r12d
    sub rsp, 8
    mov eax, [rbx - 4]
    push rax                        ; 7th argument: caller
    xor eax, eax
    call _printf                    ; dev, seq, down/up, name, dik, caller
    add rsp, 16
    add rsp, 8
    pop rsi
.ct:
    add rsp, 8
    pop rcx
    inc ecx
    jmp .copy
.advance:
    test ARG(4), DIGDD_PEEK
    jnz .done
    add [r12 + DV_RSEQ], r13d
.done:
    mov eax, r14d
.r:
    HRET

; IDirectInputDevice8A::GetCapabilities(this, DIDEVCAPS*): attached, type, counts
di_GetCapabilities:
    HENTER
    mov r12d, ARG(1)
    mov r13d, [r12]
    mov edi, r12d
    xor esi, esi
    mov edx, r13d
    call _memset
    mov [r12], r13d
    mov dword [r12 + 4], 1          ; DIDC_ATTACHED
    mov eax, ARG(0)
    cmp dword [rax + COM_KIND], GUID_SysMouse
    je .mouse
    mov dword [r12 + 8], 0x0413     ; DI8DEVTYPE_KEYBOARD, PCENH
    mov dword [r12 + 16], 128       ; dwButtons (keys)
    xor eax, eax
    HRET
.mouse:
    mov dword [r12 + 8], 0x0112     ; DI8DEVTYPE_MOUSE, TRADITIONAL
    mov dword [r12 + 12], 3         ; dwAxes
    mov dword [r12 + 16], 5         ; dwButtons
    xor eax, eax
    HRET

; ---- --keys=FRAME:KEY[,FRAME:KEY...] ---------------------------------------------
; Scripted key taps for end-to-end runs with the real game: at presented frame FRAME
; (counted by Vid_FlipBuffers) KEY goes down, KEYS_HOLD frames later up (FRAME:KEY:N:
; N frames later, to hold a key, e.g. walking). KEY is a DIK
; name from key_table (DOWN, RETURN, ESCAPE, A, ...), case-insensitive. The events are
; pushed into SDL's queue, so they take the same path as real keys (pump_sdl).
KEYS_MAX  equ 64
KEYS_HOLD equ 4
; parse_keys_arg: [keys_arg] -> keys_ev[] {frame, scancode, down}; bad entries -> fail
parse_keys_arg:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rdi, [keys_arg]
    test rdi, rdi
    jz .out
    call _strdup
    mov rbx, rax                    ; cursor
.entry:
    cmp byte [rbx], 0
    je .out
    mov rdi, rbx
    lea rsi, [keys_end]
    mov edx, 10
    call _strtoul
    mov r12d, eax                   ; frame
    mov rbx, [keys_end]
    cmp byte [rbx], ':'
    jne .bad
    inc rbx
    mov r13, rbx                    ; name start
.name:
    mov al, [rbx]
    test al, al
    jz .name_end
    cmp al, ','
    je .name_end
    cmp al, ':'
    je .name_end
    inc rbx
    jmp .name
.name_end:
    mov r15b, [rbx]
    mov byte [rbx], 0
    mov dword [keys_hold], KEYS_HOLD
    cmp r15b, ':'
    jne .lookup
    lea rdi, [rbx + 1]              ; FRAME:KEY:N
    lea rsi, [keys_end]
    mov edx, 10
    call _strtoul
    test eax, eax
    jz .bad
    mov [keys_hold], eax
    mov rbx, [keys_end]
    mov r15b, [rbx]
    test r15b, r15b
    jz .lookup
    cmp r15b, ','
    jne .bad
.lookup:
    lea r14, [key_table]            ; name -> SDL scancode
.find:
    movzx eax, word [r14]
    cmp eax, 0xFFFF
    je .bad
    mov rdi, [r14 + 8]
    mov rsi, r13
    call _strcasecmp
    test eax, eax
    jz .found
    add r14, 16
    jmp .find
.found:
    mov eax, [n_keys_ev]
    cmp eax, KEYS_MAX - 2
    jae .bad
    movzx ecx, word [r14]
    lea rdx, [keys_ev]
    imul eax, eax, 12
    mov [rdx + rax], r12d
    mov [rdx + rax + 4], ecx
    mov dword [rdx + rax + 8], 1
    mov r8d, r12d
    add r8d, [keys_hold]
    mov [rdx + rax + 12], r8d
    mov [rdx + rax + 16], ecx
    mov dword [rdx + rax + 20], 0
    add dword [n_keys_ev], 2
    test r15b, r15b
    jz .out
    inc rbx
    jmp .entry
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad:
    lea rdi, [msg_keys_bad]
    call fail

; input_push_key(edi = SDL scancode, esi = 1 down / 0 up): one key event into SDL's queue,
; the --keys path (gta2ctl key / keydown / keyup, host/c/ctl.c)
input_push_key:
    push rbx
    push r12
    sub rsp, 136                    ; SDL_Event (128), rsp 16-aligned
    mov ebx, edi
    mov r12d, esi
    mov rdi, rsp
    xor esi, esi
    mov edx, 128
    call _memset
    mov dword [rsp], SDL_EVENT_KEY_DOWN
    test r12d, r12d
    jnz .d
    mov dword [rsp], SDL_EVENT_KEY_UP
.d:
    mov [rsp + SDL_KEY_DOWN], r12b
    mov [rsp + SDL_KEY_SCANCODE], ebx
    mov rdi, rsp
    call [sdl_SDL_PushEvent]
    add rsp, 136
    pop r12
    pop rbx
    ret

; input_keys_frame(edi = presented frame): push the --keys events due now
input_keys_frame:
    push rbx
    push r12
    push r13
    sub rsp, 128                    ; SDL_Event
    mov r12d, edi
    xor ebx, ebx
.next:
    cmp ebx, [n_keys_ev]
    jae .out
    imul eax, ebx, 12
    lea r13, [keys_ev]
    add r13, rax
    cmp [r13], r12d
    jne .skip
    mov rdi, rsp
    xor esi, esi
    mov edx, 128
    call _memset
    mov dword [rsp], SDL_EVENT_KEY_DOWN
    mov eax, [r13 + 8]
    mov [rsp + SDL_KEY_DOWN], al
    test eax, eax
    jnz .d
    mov dword [rsp], SDL_EVENT_KEY_UP
.d:
    mov eax, [r13 + 4]
    mov [rsp + SDL_KEY_SCANCODE], eax
    lea rdi, [fmt_keys_push]
    mov esi, r12d
    lea rdx, [s_down]
    lea rcx, [s_up]
    cmp dword [r13 + 8], 0
    cmove rdx, rcx
    mov ecx, eax
    xor eax, eax
    call _printf
    mov rdi, rsp
    call [sdl_SDL_PushEvent]
.skip:
    inc ebx
    jmp .next
.out:
    add rsp, 128
    pop r13
    pop r12
    pop rbx
    ret

; ---- --input-test / --input-selftest ---------------------------------------------
; Runs the game's own input code without the rest of the game (the renderer stops a
; real run before the frontend exists):
;   1. the IAT's DirectInput8Create into the game's global IDirectInput8A* (0x5E8FA4);
;   2. dInput8 @0x453D80 (frontend2.cpp: CreateDevice keyboard, c_dfDIKeyboard,
;      coop 6, Acquire) on a zeroed FrontEnd, then FrontEnd+0x10D = 1 as InitFrontend
;      does (it is the "active" flag WM_ACTIVATE toggles);
;   3. DInput_CreateKeyboardDevice @0x44BB30 (diutil.cpp: the in-game keyboard 0x5E8F4C,
;      DIPROP_BUFFERSIZE 10000, Acquire), stdcall, 2 unused args (ret 8);
;   4. InitMouseExclusive @0x4CAD30 (mouse 0x6735A8, c_dfDIMouse, exclusive) with
;      --input-selftest only (it captures the cursor);
;   5. every ~16 ms: the frontend's key poll @0x452050 (GetDeviceState + edge
;      detection into FrontEnd+0xC9B8..0xC9BE), then GetDeviceData on 0x5E8F4C one
;      record at a time like 0x44C0F0, then the mouse state.
; --input-selftest pushes a scripted sequence of SDL events and checks the results.
; InitMouseExclusive and GameWindow (0x673D18) are named in gta2-seuko-mod by izawartka
; (https://github.com/izawartka/gta2-seuko-mod), src/game/functions.h, memory.h @25b1985;
; the rest is own analysis.
G_DINPUT        equ 0x5E8FA4            ; IDirectInput8A* (DirectInput8CreateIfEmpty)
G_GAME_KBD      equ 0x5E8F4C            ; in-game keyboard device (diutil.cpp)
G_MOUSE         equ 0x6735A8            ; exclusive mouse device
G_MAIN_HWND     equ 0x673D18            ; ptrToMainWindow
IAT_DINPUT8CREATE equ 0x56E024
IID_IDirectInput8A equ 0x576D74
FN_DINPUT8_FRONTEND equ 0x453D80
FN_DIUTIL_INIT  equ 0x44BB30
FN_MOUSE_EXCL   equ 0x4CAD30
FN_FRONTEND_KEYS equ 0x452050
FE_ACTIVE       equ 0x10D
FE_ACQ_FAILED   equ 0x10C
FE_EDGES        equ 0xC9B8                ; 7 bytes: left right up down return esc delete
FRONTEND_SIZE   equ 0x1F000

input_test:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160                    ; [rsp] call32 args, [rsp+32] SDL_Event
    mov byte [trace_input], 1
    call sdl_ensure
    lea rdi, [s_test_title]         ; a window of our own: no WndProc behind it
    mov esi, 640
    mov edx, 480
    xor ecx, ecx
    call [sdl_SDL_CreateWindow]
    test rax, rax
    jz .fail_win
    lea rcx, [windows]
    mov [rcx + WN_SDL], rax
    mov dword [rcx + WN_W], 640
    mov dword [rcx + WN_H], 480
    mov dword [rcx + WN_VIS], 1
    mov dword [rcx + WN_LIVE], 1
    mov dword [main_hwnd], HWND_BASE
    mov dword [abs G_MAIN_HWND], HWND_BASE
    mov rdi, rax
    call [sdl_SDL_RaiseWindow]
    ; 1. DirectInput8Create(hinst, 0x800, IID, &g_dinput, NULL) through the IAT
    mov dword [rsp], IMAGE_BASE
    mov dword [rsp + 4], 0x800
    mov dword [rsp + 8], IID_IDirectInput8A
    mov dword [rsp + 12], G_DINPUT
    mov dword [rsp + 16], 0
    mov edi, [abs IAT_DINPUT8CREATE]
    mov rsi, rsp
    mov edx, 5
    call call32_plain
    ; 2. the frontend's keyboard, by the frontend's own code
    mov edi, FRONTEND_SIZE
    mov esi, 16
    call low_alloc
    mov r12d, eax                   ; FrontEnd
    mov dword [rsp], 0
    mov edi, FN_DINPUT8_FRONTEND
    mov rsi, rsp
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d                   ; thiscall: ecx = this
    xor r9d, r9d
    call call32
    mov byte [r12 + FE_ACTIVE], 1
    ; 3. the in-game buffered keyboard
    mov qword [rsp], 0
    mov edi, FN_DIUTIL_INIT
    mov rsi, rsp
    mov edx, 2
    call call32_plain
    mov r13d, [abs G_GAME_KBD]
    ; 4. the exclusive mouse (selftest only: it captures the cursor)
    cmp byte [input_selftest], 0
    je .no_mouse
    mov edi, FN_MOUSE_EXCL
    mov rsi, rsp
    xor edx, edx
    call call32_plain
.no_mouse:
    lea rdi, [fmt_test_ready]
    mov esi, r12d
    mov edx, [r12 + 4]
    movzx ecx, byte [r12 + FE_ACQ_FAILED]
    mov r8d, r13d
    mov r9d, [abs G_MOUSE]
    xor eax, eax
    call _printf
    mov edi, 64                     ; DIDEVICEOBJECTDATA / DIMOUSESTATE + count
    mov esi, 16
    call low_alloc
    mov r14d, eax
    mov dword [frame], 0
    mov r15d, 900                   ; ~15 s interactive
    cmp byte [input_selftest], 0
    je .loop
    mov r15d, SCRIPT_FRAMES
.loop:
    cmp byte [input_selftest], 0
    je .no_script
    lea rdi, [rsp + 32]
    call script_step
.no_script:
    ; 5a. frontend poll (pumps SDL through GetDeviceState)
    mov edi, FN_FRONTEND_KEYS
    mov rsi, rsp
    xor edx, edx
    xor ecx, ecx
    mov r8d, r12d                   ; fastcall: ecx = FrontEnd
    xor r9d, r9d
    call call32
    xor ebx, ebx
.edge:
    cmp byte [r12 + FE_EDGES + rbx], 0
    je .edge_n
    lea rax, [menu_hits]
    inc dword [rax + rbx*4]
    lea rax, [s_edge_names]
    mov rdx, [rax + rbx*8]
    lea rdi, [fmt_test_menu]
    mov esi, [frame]
    xor eax, eax
    call _printf
.edge_n:
    inc ebx
    cmp ebx, 7
    jb .edge
    ; 5b. the in-game reader: one record per call until the buffer is empty
.data:
    test r13d, r13d
    jz .data_done
    mov dword [r14 + 32], 1         ; dwInOut
    mov [rsp], r13d
    mov dword [rsp + 4], 20
    mov [rsp + 8], r14d
    lea eax, [r14 + 32]
    mov [rsp + 12], eax
    mov dword [rsp + 16], 0
    mov eax, [r13]
    mov edi, [rax + 0x28]           ; vtable: GetDeviceData
    mov rsi, rsp
    mov edx, 5
    call call32_plain
    test eax, eax
    js .data_done
    cmp dword [r14 + 32], 0
    je .data_done
    inc dword [game_records]
    jmp .data
.data_done:
    ; 5c. the mouse
    mov eax, [abs G_MOUSE]
    test eax, eax
    jz .mouse_done
    mov [rsp], eax
    mov dword [rsp + 4], 16
    mov [rsp + 8], r14d
    mov eax, [rax]
    mov edi, [rax + 0x24]           ; vtable: GetDeviceState
    mov rsi, rsp
    mov edx, 3
    call call32_plain
    mov eax, [r14]
    add [mouse_sum_x], eax
    mov eax, [r14 + 4]
    add [mouse_sum_y], eax
    mov al, [r14 + 12]
    or [mouse_seen_btn], al
.mouse_done:
    call drain_messages             ; no WndProc: count what would have been posted
    test eax, eax
    jnz .closed
    mov edi, 16000
    call _usleep
    inc dword [frame]
    dec r15d
    jnz .loop
    jmp .end
.closed:
    lea rdi, [msg_test_closed]
    call _puts
.end:
    call mouse_capture_off
    cmp byte [input_selftest], 0
    je .summary
    call selftest_check
    jmp .out
.summary:
    lea rdi, [fmt_test_sum]
    mov esi, [game_records]
    mov edx, [msg_keydown]
    mov ecx, [msg_activate]
    xor eax, eax
    call _printf
    xor eax, eax
.out:
    add rsp, 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fail_win:
    lea rdi, [msg_sdl]
    call fail

; call32_plain(edi = target, rsi = args, edx = nargs): no register arguments
call32_plain:
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    jmp call32

; eax = drain_messages(): empty the posted queue, count by type; 1 if WM_CLOSE was seen
drain_messages:
    xor edx, edx
.next:
    mov eax, [msgq_head]
    cmp eax, [msgq_tail]
    je .done
    and eax, MSGQ_LEN - 1
    shl eax, 5
    lea rcx, [msgq]
    mov eax, [rcx + rax + 4]
    inc dword [msgq_head]
    cmp eax, WM_CLOSE
    jne .k
    mov edx, 1
.k:
    cmp eax, WM_KEYDOWN
    je .kd
    cmp eax, WM_SYSKEYDOWN
    jne .a
.kd:
    inc dword [msg_keydown]
.a:
    cmp eax, WM_ACTIVATE_
    jne .next
    inc dword [msg_activate]
    jmp .next
.done:
    mov eax, edx
    ret

; script_step(rdi = SDL_Event scratch): push this frame's scripted events
SCRIPT_FRAMES equ 80
EV_KEY   equ 1
EV_FOCUS equ 2
EV_MOVE  equ 3
EV_BTN   equ 4
script_step:
    push rbx
    push r12
    push r13
    mov r12, rdi
    lea rbx, [script]
.next:
    movzx eax, word [rbx]
    cmp eax, 0xFFFF
    je .out
    cmp eax, [frame]
    jne .skip
    mov rdi, r12
    xor esi, esi
    mov edx, 128
    call _memset
    movzx eax, byte [rbx + 2]       ; kind
    movzx ecx, byte [rbx + 3]       ; down (bit 1: repeat) / gained / button (bit 7: down)
    mov edx, [rbx + 4]              ; scancode / button / xrel bits
    cmp eax, EV_KEY
    jne .focus
    mov dword [r12], SDL_EVENT_KEY_DOWN
    test ecx, 2
    jz .kr
    mov byte [r12 + SDL_KEY_REPEAT], 1
.kr:
    and ecx, 1
    jnz .kd
    mov dword [r12], SDL_EVENT_KEY_UP
.kd:
    mov [r12 + SDL_KEY_DOWN], cl
    mov [r12 + SDL_KEY_SCANCODE], edx
    jmp .push
.focus:
    cmp eax, EV_FOCUS
    jne .move
    mov dword [r12], SDL_EVENT_WINDOW_FOCUS_LOST
    test ecx, ecx
    jz .push
    mov dword [r12], SDL_EVENT_WINDOW_FOCUS_GAINED
    jmp .push
.move:
    cmp eax, EV_MOVE
    jne .btn
    mov dword [r12], SDL_EVENT_MOUSE_MOTION
    mov [r12 + SDL_MOTION_XREL], edx
    mov eax, [rbx + 8]
    mov [r12 + SDL_MOTION_YREL], eax
    jmp .push
.btn:
    mov dword [r12], SDL_EVENT_MOUSE_BUTTON_DOWN
    test ecx, 0x80
    jnz .bd
    mov dword [r12], SDL_EVENT_MOUSE_BUTTON_UP
.bd:
    mov [r12 + SDL_BUTTON_BUTTON], dl
    shr ecx, 7
    mov [r12 + SDL_BUTTON_DOWN], cl
.push:
    mov dword [r12 + 4], SELFTEST_MARK
    mov rdi, r12
    call [sdl_SDL_PushEvent]
.skip:
    add rbx, 12
    jmp .next
.out:
    pop r13
    pop r12
    pop rbx
    ret

; eax = selftest_check(): compare the counters with what the script must produce
selftest_check:
    push rbx
    push r12
    sub rsp, 8
    xor r12d, r12d                  ; failures
    xor ebx, ebx
.edge:
    lea rax, [menu_hits]
    mov esi, [rax + rbx*4]
    lea rax, [menu_expect]
    movzx edx, byte [rax + rbx]
    lea rax, [s_edge_names]
    mov rcx, [rax + rbx*8]
    call check_line
    inc ebx
    cmp ebx, 7
    jb .edge
    lea rcx, [s_chk_records]
    mov esi, [game_records]
    mov edx, EXPECT_RECORDS
    call check_line
    lea rcx, [s_chk_keydown]
    mov esi, [msg_keydown]
    mov edx, EXPECT_KEYDOWN
    call check_line
    lea rcx, [s_chk_activate]
    mov esi, [msg_activate]
    mov edx, 2
    call check_line
    lea rcx, [s_chk_mx]
    mov esi, [mouse_sum_x]
    mov edx, 21
    call check_line
    lea rcx, [s_chk_my]
    mov esi, [mouse_sum_y]
    mov edx, -6
    call check_line
    lea rcx, [s_chk_btn]
    movzx esi, byte [mouse_seen_btn]
    mov edx, 0x80
    call check_line
    xor esi, esi                    ; nothing may stay held
    xor ecx, ecx
.held:
    lea rax, [di_keys]
    movzx edx, byte [rax + rcx]
    or esi, edx
    inc ecx
    cmp ecx, 256
    jb .held
    lea rcx, [s_chk_held]
    xor edx, edx
    call check_line
    lea rdi, [fmt_chk_sum]
    mov esi, r12d
    xor eax, eax
    call _printf
    mov eax, r12d
    add rsp, 8
    pop r12
    pop rbx
    ret
; check_line(esi = got, edx = expected, rcx = name); counts failures in r12d
check_line:
    sub rsp, 8
    lea rdi, [str_pass]
    lea rax, [str_fail]
    cmp esi, edx
    je .p
    mov rdi, rax
    inc r12d
.p:
    mov r8d, edx
    mov rdx, rcx                    ; name
    mov ecx, esi                    ; got
    mov rsi, rdi                    ; PASS/FAIL
    lea rdi, [fmt_chk]
    xor eax, eax
    call _printf
    add rsp, 8
    ret

section .data
align 8
shimtab_dinput8:
    dq s_dinput8
    SHIM "DirectInput8Create", 20, di_DirectInput8Create
    dq 0

shimtab_idirectinput8:
    dq s_dinput8
    SHIM "IDirectInput8A::QueryInterface", 12, com_QueryInterface
    SHIM "IDirectInput8A::AddRef", 4, com_AddRef
    SHIM "IDirectInput8A::Release", 4, com_Release
    SHIM "IDirectInput8A::CreateDevice", 16, di_CreateDevice
    SHIM "IDirectInput8A::EnumDevices", 20, com_ok          ; no joysticks enumerated
    SHIM "IDirectInput8A::GetDeviceStatus", 8, com_ok
    SHIM "IDirectInput8A::RunControlPanel", 12, com_ok
    SHIM "IDirectInput8A::Initialize", 12, com_ok
    SHIM "IDirectInput8A::FindDevice", 16, host_unimpl
    SHIM "IDirectInput8A::EnumDevicesBySemantics", 24, com_ok
    SHIM "IDirectInput8A::ConfigureDevices", 20, host_unimpl
    dq 0

shimtab_idirectinputdevice8:
    dq s_dinput8
    SHIM "IDirectInputDevice8A::QueryInterface", 12, com_QueryInterface
    SHIM "IDirectInputDevice8A::AddRef", 4, com_AddRef
    SHIM "IDirectInputDevice8A::Release", 4, di_dev_Release
    SHIM "IDirectInputDevice8A::GetCapabilities", 8, di_GetCapabilities
    SHIM "IDirectInputDevice8A::EnumObjects", 16, com_ok
    SHIM "IDirectInputDevice8A::GetProperty", 12, di_GetProperty
    SHIM "IDirectInputDevice8A::SetProperty", 12, di_SetProperty
    SHIM "IDirectInputDevice8A::Acquire", 4, di_Acquire
    SHIM "IDirectInputDevice8A::Unacquire", 4, di_Unacquire
    SHIM "IDirectInputDevice8A::GetDeviceState", 12, di_GetDeviceState
    SHIM "IDirectInputDevice8A::GetDeviceData", 20, di_GetDeviceData
    SHIM "IDirectInputDevice8A::SetDataFormat", 8, di_SetDataFormat
    SHIM "IDirectInputDevice8A::SetEventNotification", 8, com_ok
    SHIM "IDirectInputDevice8A::SetCooperativeLevel", 12, di_SetCooperativeLevel
    SHIM "IDirectInputDevice8A::GetObjectInfo", 16, host_unimpl
    SHIM "IDirectInputDevice8A::GetDeviceInfo", 8, host_unimpl
    SHIM "IDirectInputDevice8A::RunControlPanel", 12, com_ok
    SHIM "IDirectInputDevice8A::Initialize", 16, com_ok
    SHIM "IDirectInputDevice8A::CreateEffect", 20, host_unimpl
    SHIM "IDirectInputDevice8A::EnumEffects", 16, com_ok
    SHIM "IDirectInputDevice8A::GetEffectInfo", 12, host_unimpl
    SHIM "IDirectInputDevice8A::GetForceFeedbackState", 8, host_unimpl
    SHIM "IDirectInputDevice8A::SendForceFeedbackCommand", 8, com_ok
    SHIM "IDirectInputDevice8A::EnumCreatedEffectObjects", 16, com_ok
    SHIM "IDirectInputDevice8A::Escape", 8, host_unimpl
    SHIM "IDirectInputDevice8A::Poll", 4, com_ok
    SHIM "IDirectInputDevice8A::SendDeviceData", 20, com_ok
    SHIM "IDirectInputDevice8A::EnumEffectsInFile", 20, com_ok
    SHIM "IDirectInputDevice8A::WriteEffectToFile", 20, host_unimpl
    SHIM "IDirectInputDevice8A::BuildActionMap", 16, host_unimpl
    SHIM "IDirectInputDevice8A::SetActionMap", 16, host_unimpl
    SHIM "IDirectInputDevice8A::GetImageInfo", 8, host_unimpl
    dq 0

have_focus:     db 1                ; assume focus until SDL says otherwise
trace_input:    db 0                ; --trace-input (or --trace): log every key change
input_test_on:  db 0                ; --input-test
input_selftest: db 0                ; --input-selftest

; KEY sdl_scancode, DIK, VK, name — the whole map (SDL scancodes are USB HID usages;
; DIK = set-1 scan code, | 0x80 for E0-prefixed keys). WM_KEYDOWN's lParam scan code
; and extended bit are derived from the DIK.
%macro KEY 4
    dw %1
    db %2, %3
    dd 0
    dq %%n
section .rodata
%%n: db %4, 0
section .data
%endmacro
align 8
key_table:
    KEY  4, 0x1E, 'A', "A"
    KEY  5, 0x30, 'B', "B"
    KEY  6, 0x2E, 'C', "C"
    KEY  7, 0x20, 'D', "D"
    KEY  8, 0x12, 'E', "E"
    KEY  9, 0x21, 'F', "F"
    KEY 10, 0x22, 'G', "G"
    KEY 11, 0x23, 'H', "H"
    KEY 12, 0x17, 'I', "I"
    KEY 13, 0x24, 'J', "J"
    KEY 14, 0x25, 'K', "K"
    KEY 15, 0x26, 'L', "L"
    KEY 16, 0x32, 'M', "M"
    KEY 17, 0x31, 'N', "N"
    KEY 18, 0x18, 'O', "O"
    KEY 19, 0x19, 'P', "P"
    KEY 20, 0x10, 'Q', "Q"
    KEY 21, 0x13, 'R', "R"
    KEY 22, 0x1F, 'S', "S"
    KEY 23, 0x14, 'T', "T"
    KEY 24, 0x16, 'U', "U"
    KEY 25, 0x2F, 'V', "V"
    KEY 26, 0x11, 'W', "W"
    KEY 27, 0x2D, 'X', "X"
    KEY 28, 0x15, 'Y', "Y"
    KEY 29, 0x2C, 'Z', "Z"
    KEY 30, 0x02, '1', "1"
    KEY 31, 0x03, '2', "2"
    KEY 32, 0x04, '3', "3"
    KEY 33, 0x05, '4', "4"
    KEY 34, 0x06, '5', "5"
    KEY 35, 0x07, '6', "6"
    KEY 36, 0x08, '7', "7"
    KEY 37, 0x09, '8', "8"
    KEY 38, 0x0A, '9', "9"
    KEY 39, 0x0B, '0', "0"
    KEY 40, 0x1C, 0x0D, "RETURN"
    KEY 41, 0x01, 0x1B, "ESCAPE"
    KEY 42, 0x0E, 0x08, "BACK"
    KEY 43, 0x0F, 0x09, "TAB"
    KEY 44, 0x39, 0x20, "SPACE"
    KEY 45, 0x0C, 0xBD, "MINUS"
    KEY 46, 0x0D, 0xBB, "EQUALS"
    KEY 47, 0x1A, 0xDB, "LBRACKET"
    KEY 48, 0x1B, 0xDD, "RBRACKET"
    KEY 49, 0x2B, 0xDC, "BACKSLASH"
    KEY 50, 0x2B, 0xDC, "BACKSLASH"     ; NONUSHASH: same physical key on ISO boards
    KEY 51, 0x27, 0xBA, "SEMICOLON"
    KEY 52, 0x28, 0xDE, "APOSTROPHE"
    KEY 53, 0x29, 0xC0, "GRAVE"
    KEY 54, 0x33, 0xBC, "COMMA"
    KEY 55, 0x34, 0xBE, "PERIOD"
    KEY 56, 0x35, 0xBF, "SLASH"
    KEY 57, 0x3A, 0x14, "CAPITAL"
    KEY 58, 0x3B, 0x70, "F1"
    KEY 59, 0x3C, 0x71, "F2"
    KEY 60, 0x3D, 0x72, "F3"
    KEY 61, 0x3E, 0x73, "F4"
    KEY 62, 0x3F, 0x74, "F5"
    KEY 63, 0x40, 0x75, "F6"
    KEY 64, 0x41, 0x76, "F7"
    KEY 65, 0x42, 0x77, "F8"
    KEY 66, 0x43, 0x78, "F9"
    KEY 67, 0x44, 0x79, "F10"
    KEY 68, 0x57, 0x7A, "F11"
    KEY 69, 0x58, 0x7B, "F12"
    KEY 70, 0xB7, 0x2C, "SYSRQ"
    KEY 71, 0x46, 0x91, "SCROLL"
    KEY 72, 0xC5, 0x13, "PAUSE"
    KEY 73, 0xD2, 0x2D, "INSERT"
    KEY 74, 0xC7, 0x24, "HOME"
    KEY 75, 0xC9, 0x21, "PRIOR"
    KEY 76, 0xD3, 0x2E, "DELETE"
    KEY 77, 0xCF, 0x23, "END"
    KEY 78, 0xD1, 0x22, "NEXT"
    KEY 79, 0xCD, 0x27, "RIGHT"
    KEY 80, 0xCB, 0x25, "LEFT"
    KEY 81, 0xD0, 0x28, "DOWN"
    KEY 82, 0xC8, 0x26, "UP"
    KEY 83, 0x45, 0x90, "NUMLOCK"
    KEY 84, 0xB5, 0x6F, "DIVIDE"
    KEY 85, 0x37, 0x6A, "MULTIPLY"
    KEY 86, 0x4A, 0x6D, "SUBTRACT"
    KEY 87, 0x4E, 0x6B, "ADD"
    KEY 88, 0x9C, 0x0D, "NUMPADENTER"
    KEY 89, 0x4F, 0x61, "NUMPAD1"
    KEY 90, 0x50, 0x62, "NUMPAD2"
    KEY 91, 0x51, 0x63, "NUMPAD3"
    KEY 92, 0x4B, 0x64, "NUMPAD4"
    KEY 93, 0x4C, 0x65, "NUMPAD5"
    KEY 94, 0x4D, 0x66, "NUMPAD6"
    KEY 95, 0x47, 0x67, "NUMPAD7"
    KEY 96, 0x48, 0x68, "NUMPAD8"
    KEY 97, 0x49, 0x69, "NUMPAD9"
    KEY 98, 0x52, 0x60, "NUMPAD0"
    KEY 99, 0x53, 0x6E, "DECIMAL"
    KEY 100, 0x56, 0xE2, "OEM_102"
    KEY 101, 0xDD, 0x5D, "APPS"
    KEY 102, 0xDE, 0x00, "POWER"
    KEY 103, 0x8D, 0x00, "NUMPADEQUALS"
    KEY 104, 0x64, 0x7C, "F13"
    KEY 105, 0x65, 0x7D, "F14"
    KEY 106, 0x66, 0x7E, "F15"
    KEY 224, 0x1D, 0x11, "LCONTROL"
    KEY 225, 0x2A, 0x10, "LSHIFT"
    KEY 226, 0x38, 0x12, "LMENU"
    KEY 227, 0xDB, 0x5B, "LWIN"
    KEY 228, 0x9D, 0x11, "RCONTROL"
    KEY 229, 0x36, 0x10, "RSHIFT"
    KEY 230, 0xB8, 0x12, "RMENU"
    KEY 231, 0xDC, 0x5C, "RWIN"
    dw 0xFFFF
SDL_SCANCODES equ 512

sdl_button_di: db 0, 2, 1, 3, 4      ; SDL_BUTTON_LEFT..X2 -> rgbButtons index

; --input-selftest script: {u16 frame, u8 kind, u8 arg, u32 a, u32 b}
%macro EV 5
    dw %1
    db %2, %3
    dd %4, %5
%endmacro
SC_DOWN  equ 81
SC_UP    equ 82
SC_LEFT  equ 80
SC_RIGHT equ 79
SC_RET   equ 40
SC_ESC   equ 41
SC_DEL   equ 76
SC_A     equ 4
align 4
script:
    EV 10, EV_KEY, 1, SC_DOWN, 0
    EV 14, EV_KEY, 0, SC_DOWN, 0
    EV 18, EV_KEY, 1, SC_DOWN, 0
    EV 20, EV_KEY, 3, SC_DOWN, 0        ; auto-repeat: WM_KEYDOWN only
    EV 22, EV_KEY, 0, SC_DOWN, 0
    EV 26, EV_KEY, 1, SC_UP, 0
    EV 30, EV_KEY, 0, SC_UP, 0
    EV 34, EV_KEY, 1, SC_RET, 0
    EV 38, EV_KEY, 0, SC_RET, 0
    EV 42, EV_KEY, 1, SC_ESC, 0
    EV 46, EV_KEY, 0, SC_ESC, 0
    EV 50, EV_KEY, 1, SC_LEFT, 0
    EV 50, EV_KEY, 1, SC_RIGHT, 0
    EV 50, EV_KEY, 1, SC_A, 0
    EV 54, EV_FOCUS, 0, 0, 0            ; releases LEFT, RIGHT, A
    EV 58, EV_FOCUS, 1, 0, 0
    EV 62, EV_KEY, 1, SC_DEL, 0
    EV 66, EV_KEY, 0, SC_DEL, 0
    EV 67, EV_KEY, 1, SC_UP, 0          ; a tap shorter than one poll
    EV 67, EV_KEY, 0, SC_UP, 0
    EV 68, EV_MOVE, 0, __float32__(10.5), __float32__(-3.25)
    EV 69, EV_MOVE, 0, __float32__(10.75), __float32__(-2.75)
    EV 70, EV_BTN, 0x81, 1, 0           ; left button down
    EV 74, EV_BTN, 0x01, 1, 0           ; up
    dw 0xFFFF
; frontend edges: left right up down return esc delete
menu_expect: db 1, 1, 2, 2, 1, 1, 1
EXPECT_RECORDS equ 20                   ; 10 key presses, each down + up
EXPECT_KEYDOWN equ 11                   ; 10 presses + 1 auto-repeat

section .rodata
s_di_kbd:    db "keyboard", 0
s_di_mouse:  db "mouse", 0
s_di_other:  db "other", 0
s_dik_unknown: db "?", 0
s_down:      db "down", 0
s_up:        db "up", 0
s_gained:    db "gained", 0
s_lost:      db "lost", 0
s_in_none:   db " (none)", 0
s_test_title: db "GTA2 input test", 0
s_e_left:    db "LEFT", 0
s_e_right:   db "RIGHT", 0
s_e_up:      db "UP", 0
s_e_down:    db "DOWN", 0
s_e_ret:     db "RETURN", 0
s_e_esc:     db "ESCAPE", 0
s_e_del:     db "DELETE", 0
s_chk_records: db "in-game GetDeviceData records", 0
s_chk_keydown: db "WM_KEYDOWN/WM_SYSKEYDOWN posted", 0
s_chk_activate: db "WM_ACTIVATE posted (focus lost + gained)", 0
s_chk_mx:    db "mouse lX total", 0
s_chk_my:    db "mouse lY total", 0
s_chk_btn:   db "mouse button 0 seen", 0
s_chk_held:  db "keys still held at the end", 0
fmt_di_create: db "  [w32] DirectInput8Create(version 0x%x) -> IDirectInput8A 0x%x", 10, 0
fmt_di_device: db "  [w32] IDirectInput8A::CreateDevice(%s) -> 0x%x <- 0x%x", 10, 0
fmt_in_key:  db "  [input] SDL key %-4s -> DIK_%s (0x%02x), record #%u", 10, 0
fmt_in_focus: db "  [input] focus %s", 10, 0
fmt_in_stale: db "  [input] keyboard 0x%x acquired with DIK_%s held: reads as up until released", 10, 0
fmt_in_acq:  db "  [input] Acquire(%s 0x%x) coop 0x%x buffer %u <- 0x%x", 10, 0
fmt_in_state: db "  [input] GetDeviceState(keyboard 0x%x) <- 0x%x: held", 0
fmt_in_name: db " DIK_%s", 0
fmt_in_mouse: db "  [input] GetDeviceState(mouse) dx %d dy %d dz %d buttons %08x <- 0x%x", 10, 0
fmt_in_data: db "  [input] GetDeviceData(keyboard 0x%x) #%u %-4s DIK_%s (0x%02x) <- 0x%x", 10, 0
fmt_test_ready: db "input test: FrontEnd 0x%x, frontend keyboard 0x%x (acquire failed: %d), in-game keyboard 0x%x, mouse 0x%x", 10, 0
fmt_test_menu: db "  [menu] frame %d: frontend sees %s pressed (0x452050 edge flag)", 10, 0
fmt_test_sum: db "input test: %d in-game records, %d WM_KEYDOWN, %d WM_ACTIVATE", 10, 0
fmt_chk:     db "  [%s] %s: %d (expected %d)", 10, 0
fmt_chk_sum: db "input selftest: %d failures", 10, 0
msg_test_closed: db "input test: window closed", 0
msg_keys_bad: db "--keys=FRAME:KEY[,FRAME:KEY...]: bad entry or unknown key name (see key_table)", 0
fmt_keys_push: db "  [keys] frame %d: push SDL key %s, scancode %d", 10, 0

section .data
align 8
s_edge_names: dq s_e_left, s_e_right, s_e_up, s_e_down, s_e_ret, s_e_esc, s_e_del

section .bss
alignb 8
keys_arg:    resq 1                 ; --keys= value
keys_end:    resq 1
keys_ev:     resb 12 * KEYS_MAX
keys_hold:   resd 1
n_keys_ev:   resd 1
di_keys:     resb 256
sdl_dik:     resb SDL_SCANCODES
sdl_vk:      resb SDL_SCANCODES
dik_name:    resq 256
kring:       resb KR_SIZE * KRING
kseq:        resd 1
mouse_dx:    resd 1                 ; float accumulators since the last read
mouse_dy:    resd 1
mouse_dz:    resd 1
mouse_btn:   resb 8                 ; DI order, 0x80 = down
mouse_captured: resb 1
alignb 4
frame:       resd 1
menu_hits:   resd 7
game_records: resd 1
msg_keydown: resd 1
msg_activate: resd 1
mouse_sum_x: resd 1
mouse_sum_y: resd 1
mouse_seen_btn: resb 1
section .text
