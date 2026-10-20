; w32_hooks.asm — patches to the game's own code where an OS probe is cheaper to
; answer than to emulate. Each hook overwrites a function entry with `jmp stub`,
; where the stub is an ordinary import slot (DLL name "gta2.exe"), so hooked
; functions go through host_dispatch and show up in --trace like imports.
; The first bytes of every target are checked first: a different exe is refused.

section .text

; install_hooks: before protect_image (.text is still writable)
install_hooks:
    push rbx
    push r12
    push r13
    lea rbx, [hooks]
.next:
    mov r12d, [rbx + HK_VA]
    test r12d, r12d
    jz .done
    mov rax, [r12]                  ; original bytes still there?
    cmp rax, [rbx + HK_ORIG]
    jne .mismatch
    lea rdi, [s_gta2exe]
    mov rsi, [rbx + HK_NAME]
    xor edx, edx
    call new_slot                   ; binds through shimtab_gta2 by name
    mov byte [r12], 0xE9            ; jmp rel32 stub
    lea ecx, [r12 + 5]
    sub eax, ecx
    mov [r12 + 1], eax
    lea rdi, [fmt_hook]
    mov esi, r12d
    mov rdx, [rbx + HK_NAME]
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
.done:
    pop r13
    pop r12
    pop rbx
    ret

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

section .data
align 8
HK_VA   equ 0
HK_NAME equ 8
HK_ORIG equ 16
HK_SIZE equ 24
; HOOK va, "name", first 8 original bytes (little-endian qword)
%macro HOOK 3
    dq %1, %%n, %3
section .rodata
%%n: db %2, 0
section .data
%endmacro
hooks:
    HOOK 0x4031C0, "GetDXVersion", 0x8D5700000114EC81   ; sub esp,0x114; push edi; lea
    dq 0

shimtab_gta2:
    dq s_gta2exe
    SHIM "GetDXVersion", 8, hk_GetDXVersion
    dq 0

section .rodata
fmt_hook:     db "hook: 0x%x %s -> host", 10, 0
fmt_hook_bad: db "hook: 0x%x %s: original bytes differ (not vanilla 11.44 gta2.exe?)", 10, 0
msg_hook:     db "cannot install hooks", 0
section .text
