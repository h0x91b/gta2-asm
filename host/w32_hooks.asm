; w32_hooks.asm — patches to the game's own code. Four kinds, one table (`hooks`):
;
;   HOOK va, "name", qword        function entry -> `jmp stub`: the whole function is ours
;   CALLHOOK va, "name", target   an `E8 call target` at va is retargeted to our stub
;   JMPHOOK va, "name", {bytes}   mid-function: the bytes (whole instructions, >= 5,
;                                 no relative branches) move to a trampoline that calls
;                                 our stub with the game's registers, then runs them
;   PATCH va, "name", {old}, {new} plain byte replacement
;
; Every stub is an ordinary import slot (DLL name "gta2.exe", bound by name through
; shimtab_gta2), so hooks go through host_dispatch and show up in --trace like imports.
; The expected original bytes are checked first: a different exe is refused.
;
; Handlers: HOOK/CALLHOOK ones get the game's stack arguments as any import handler
; (rdi = args) and the game's eax/ecx/edx at the call in G_EAX/G_ECX/G_EDX (thiscall
; `this` is G_ECX). A CALLHOOK handler that wants the original calls it with call32.
; A JMPHOOK handler is stdcall(regs*): ARG(0) points at the game's registers in the
; R_* layout below (pushfd over pushad); changing them changes the game's registers
; (except R_ESP). It returns 0 to run the displaced bytes and continue, or a VA to
; resume at instead (skipping them).

R_EFL equ 0
R_EDI equ 4
R_ESI equ 8
R_EBP equ 12
R_ESP equ 16                        ; esp before pushad; read-only
R_EBX equ 20
R_EDX equ 24
R_ECX equ 28
R_EAX equ 32

TRAMPS      equ LOW_BASE + 0x10000  ; JMPHOOK trampolines, TRAMP_SIZE bytes each
TRAMP_SIZE  equ 64
MAX_TRAMPS  equ 0x10000 / TRAMP_SIZE
JMP_MAX     equ 16                  ; displaced bytes per JMPHOOK

HK_ENTRY equ 0
HK_CALL  equ 1
HK_JMP   equ 2
HK_PATCH equ 3

section .text

; install_hooks: before protect_image (.text is still writable)
install_hooks:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [hooks]
.next:
    mov r12d, [rbx + HK_VA]
    test r12d, r12d
    jz .done
    mov rdi, r12                    ; original bytes still there?
    mov rsi, [rbx + HK_ORIG]
    mov edx, [rbx + HK_LEN]
    call _memcmp
    test eax, eax
    jnz .mismatch
    mov eax, [rbx + HK_KIND]
    cmp eax, HK_PATCH
    je .patch
    lea rdi, [s_gta2exe]
    mov rsi, [rbx + HK_NAME]
    xor edx, edx
    call new_slot
    mov r13d, eax                   ; stub
    mov eax, [rbx + HK_KIND]
    cmp eax, HK_CALL
    je .call
    cmp eax, HK_JMP
    je .jmp
    mov byte [r12], 0xE9            ; HK_ENTRY: jmp rel32 stub
    lea ecx, [r12 + 5]
    mov eax, r13d
    sub eax, ecx
    mov [r12 + 1], eax
    jmp .log

.call:                              ; orig = E8 + rel32 to HK_ARG, checked above
    lea ecx, [r12 + 5]
    mov eax, r13d
    sub eax, ecx
    mov [r12 + 1], eax
    jmp .log

.jmp:
    mov ecx, [n_tramps]
    cmp ecx, MAX_TRAMPS
    jae .full
    inc dword [n_tramps]
    imul r14d, ecx, TRAMP_SIZE
    add r14d, TRAMPS                ; r14 = trampoline
    lea rsi, [tramp_tmpl]
    mov rdi, r14
    mov edx, tramp_tmpl_end - tramp_tmpl
    call _memcpy
    lea ecx, [r14 + TT_CALL + 5]    ; call stub
    mov eax, r13d
    sub eax, ecx
    mov [r14 + TT_CALL + 1], eax
    lea eax, [r14 + TT_CODE]
    mov [r14 + TT_DEFAULT + 1], eax ; mov eax, displaced code
    lea eax, [r14 + TT_RESUME]
    mov [r14 + TT_STORE + 1], eax   ; mov [resume], eax
    mov [r14 + TT_JMP + 2], eax     ; jmp [resume]
    lea rdi, [r14 + TT_CODE]        ; the displaced instructions...
    mov rsi, r12
    mov r15d, [rbx + HK_LEN]
    mov edx, r15d
    call _memcpy
    lea rdi, [r14 + TT_CODE + r15]  ; ...then jmp back past them
    mov byte [rdi], 0xE9
    lea eax, [r12 + r15]
    lea ecx, [rdi + 5]
    sub eax, ecx
    mov [rdi + 1], eax
    mov byte [r12], 0xE9            ; site: jmp trampoline, rest nop
    lea ecx, [r12 + 5]
    mov eax, r14d
    sub eax, ecx
    mov [r12 + 1], eax
    lea rdi, [r12 + 5]
    mov esi, 0x90
    lea edx, [r15 - 5]
    call _memset
    jmp .log

.patch:
    mov rdi, r12
    mov rsi, [rbx + HK_ARG]
    mov edx, [rbx + HK_LEN]
    call _memcpy
.log:
    lea rdi, [fmt_hook]
    mov esi, r12d
    mov rdx, [rbx + HK_NAME]
    mov eax, [rbx + HK_KIND]
    lea rcx, [hook_kinds]
    mov rcx, [rcx + rax*8]
    xor eax, eax
    call _printf
    add rbx, HK_SIZE
    jmp .next
.mismatch:
    lea rdi, [fmt_hook_bad]
    mov esi, r12d
    mov rdx, [rbx + HK_NAME]
    xor eax, eax
    call _printf
    lea rdi, [msg_hook]
    call fail
.full:
    lea rdi, [msg_tramps]
    call fail
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; JMPHOOK trampoline template (32-bit code, patched per hook by install_hooks)
bits 32
tramp_tmpl:
    pushad
    pushfd
    push esp                        ; regs*
TT_CALL equ $ - tramp_tmpl
    call $ + 5                      ; -> stub (stdcall 4)
    test eax, eax
    jnz .store
TT_DEFAULT equ $ - tramp_tmpl
    mov eax, strict dword 0         ; -> TT_CODE
.store:
TT_STORE equ $ - tramp_tmpl
    mov [0x11111111], eax          ; -> TT_RESUME
    popfd
    popad
TT_JMP equ $ - tramp_tmpl
    jmp [0x11111111]                 ; -> TT_RESUME
TT_RESUME equ $ - tramp_tmpl
    dd 0
TT_CODE equ $ - tramp_tmpl
tramp_tmpl_end:
bits 64
%if TT_CODE + JMP_MAX + 5 > TRAMP_SIZE
  %error "JMPHOOK trampoline does not fit TRAMP_SIZE"
%endif

; GetDXVersion(DWORD* version, DWORD* platform) @0x4031C0, stdcall 8 — Microsoft's
; DirectX SDK sample (Ghidra: "LoadDirectInputFuncs"). It creates DirectDraw objects
; and surfaces only to find out the DirectX version; WinMain (0x4D11DB) refuses
; anything below 0x601. We answer DirectX 8.1 on the NT platform.
hk_GetDXVersion:
    mov eax, [rdi]
    mov dword [rax], 0x801
    mov eax, [rdi + 4]
    mov dword [rax], 2              ; VER_PLATFORM_WIN32_NT
    xor eax, eax
    ret

; CameraPosApply @0x41F3E9 (JMPHOOK), inside the camera update: copies cameraPosTarget
; (camera+0x10) into cameraPosTarget2 (camera+0), which cameraPos then follows.
; esi = Camera*, edx = camera+0x10.
; Hook site from gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/events/camera-pos-apply.cpp @25b1985.
hk_CameraPosApply:
    HENTER
    mov eax, [rbx]                  ; regs*
    inc dword [n_cam_apply]
    cmp dword [n_cam_apply], 1
    jne .out
    lea rdi, [fmt_first_hit]
    lea rsi, [s_cam_apply]
    mov edx, [rax + R_ESI]
    xor eax, eax
    call _printf
.out:
    xor eax, eax
    HRET

; ScaleScrf @0x401BD0, thiscall(ecx = SCR_f* factor; out*, int* scalar), ret 8: out =
; factor * scalar. At 0x4BE394 the factor is the main camera's uiScale (0x5E3CC4 +0xa8)
; and the result a sprite shadow's offset (CALLHOOK; for now it only calls the original).
; Hook site from gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/events/scale-shadow.cpp @25b1985.
hk_ScaleShadow:
    HENTER
    mov r12d, [abs G_ECX]
    mov r13d, [abs G_EDX]
    inc dword [n_shadow]
    cmp dword [n_shadow], 1
    jne .call
    lea rdi, [fmt_first_hit]
    lea rsi, [s_shadow]
    mov edx, r12d
    xor eax, eax
    call _printf
.call:
    mov edi, 0x401BD0
    mov rsi, rbx
    mov edx, 2
    xor ecx, ecx
    mov r8d, r12d
    mov r9d, r13d
    call call32
    HRET

section .data
align 8
HK_VA   equ 0
HK_NAME equ 8
HK_ORIG equ 16                      ; expected bytes at va
HK_LEN  equ 24                      ; their count
HK_KIND equ 28
HK_ARG  equ 32                      ; PATCH: new bytes; CALL: original target
HK_SIZE equ 40
; HOOK va, "name", first 8 original bytes (little-endian qword)
%macro HOOK 3
    dq %1, %%n, %%o
    dd 8, HK_ENTRY
    dq 0
section .rodata
%%n: db %2, 0
%%o: dq %3
section .data
%endmacro
; CALLHOOK va, "name", target of the original `call`
%macro CALLHOOK 3
    dq %1, %%n, %%o
    dd 5, HK_CALL
    dq %3
section .rodata
%%n: db %2, 0
%%o: db 0xE8
    dd (%3) - ((%1) + 5)
section .data
%endmacro
; JMPHOOK va, "name", {displaced bytes}
%macro JMPHOOK 3
    dq %1, %%n, %%o
    dd %%e - %%o, HK_JMP
    dq 0
section .rodata
%%n: db %2, 0
%%o: db %3
%%e:
%if %%e - %%o < 5 || %%e - %%o > JMP_MAX
  %error "JMPHOOK needs 5..JMP_MAX displaced bytes"
%endif
section .data
%endmacro
; PATCH va, "name", {original bytes}, {new bytes} (same count)
%macro PATCH 4
    dq %1, %%n, %%o
    dd %%e - %%o, HK_PATCH
    dq %%w
section .rodata
%%n: db %2, 0
%%o: db %3
%%e:
%%w: db %4
%if $ - %%w != %%e - %%o
  %error "PATCH: original and new byte counts differ"
%endif
section .data
%endmacro
hooks:
    HOOK 0x4031C0, "GetDXVersion", 0x8D5700000114EC81   ; sub esp,0x114; push edi; lea
    JMPHOOK 0x41F3E9, "CameraPosApply", {0x8B,0x02, 0x89,0x06, 0x8B,0x4A,0x04}
    CALLHOOK 0x4BE394, "ScaleShadow", 0x401BD0
    dq 0

shimtab_gta2:
    dq s_gta2exe
    SHIM "GetDXVersion", 8, hk_GetDXVersion
    SHIM "CameraPosApply", 4, hk_CameraPosApply
    SHIM "ScaleShadow", 8, hk_ScaleShadow
    dq 0

hook_kinds: dq s_hk_entry, s_hk_call, s_hk_jmp, s_hk_patch

section .rodata
s_hk_entry:   db "entry", 0
s_hk_call:    db "call", 0
s_hk_jmp:     db "jmp", 0
s_hk_patch:   db "patch", 0
fmt_hook:     db "hook: 0x%x %s (%s)", 10, 0
fmt_hook_bad: db "hook: 0x%x %s: original bytes differ (not vanilla 11.44 gta2.exe?)", 10, 0
msg_hook:     db "cannot install hooks", 0
msg_tramps:   db "too many JMPHOOK trampolines", 0
fmt_first_hit: db "hook: %s first hit (0x%x)", 10, 0
s_cam_apply:  db "CameraPosApply", 0
s_shadow:     db "ScaleShadow", 0

section .bss
n_tramps: resd 1
n_cam_apply: resd 1
n_shadow: resd 1
section .text
