; w32_misc.asm — the small DLLs: WINMM, VERSION, ole32, SHELL32, DINPUT8, DPLAYX,
; mss32 (Miles audio), binkw32 (Bink video).

section .text

E_FAIL               equ 0x80004005
REGDB_E_CLASSNOTREG  equ 0x80040154
DIERR_NOTINITIALIZED equ 0x80070015

; CoCreateInstance(clsid, outer, ctx, iid, ppv): no COM servers exist here
ole_CoCreateInstance:
    HENTER
    mov eax, ARG(4)
    test eax, eax
    jz .log
    mov dword [rax], 0
.log:
    mov r12d, ARG(0)
    lea rdi, [fmt_cocreate]
    mov esi, [r12]
    movzx edx, word [r12 + 4]
    movzx ecx, word [r12 + 6]
    mov r8d, [rbx - 4]
    xor eax, eax
    call _printf
    mov eax, REGDB_E_CLASSNOTREG
    HRET

; generic "logged failure" for COM-style factories: (..., out-pointer at ARG n)
%macro COM_FAIL 3                   ; label, out-pointer arg index, message
%1:
    HENTER
    mov eax, ARG(%2)
    test eax, eax
    jz %%log
    mov dword [rax], 0
%%log:
    lea rdi, [%%msg]
    mov esi, [rbx - 4]
    xor eax, eax
    call _printf
    mov eax, E_FAIL
    HRET
section .rodata
%%msg: db "  [w32] ", %3, " (from 0x%x)", 10, 0
section .text
%endmacro
    COM_FAIL dpl_DirectPlayCreate, 1, "DirectPlayCreate: no DirectPlay -> E_FAIL"
    COM_FAIL dpl_DirectPlayLobbyCreateW, 1, "DirectPlayLobbyCreateW: no DirectPlay -> E_FAIL"

shl_ShellExecuteA:          ; (hwnd, op, file, params, dir, show) -> <= 32 = error
    HENTER
    lea rdi, [fmt_shellexec]
    mov esi, ARG(1)
    mov edx, ARG(2)
    test esi, esi
    jnz .p
    lea rsi, [s_empty_str]
.p:
    xor eax, eax
    call _printf
    mov eax, 2                      ; SE_ERR_FNF
    HRET

; Our port's version, shown at the bottom of the main menu as "v<major>.<minor>".
; GetGameVersion (0x4D0920, re/functions.csv) reads VS_FIXEDFILEINFO of GTA2.EXE
; and takes major = HIWORD(dwProductVersionMS), minor = LOWORD(dwProductVersionMS);
; the menu prints them with "v%d.%d" (0x5738F4), so minor 5 reads "v23.5", not
; "v23.05". Vanilla's own resource says 11.44. Bump these two to re-version.
GTA2_VERSION_MAJOR equ 23
GTA2_VERSION_MINOR equ 31

VS_FFI_SIZE equ 0x34                ; sizeof(VS_FIXEDFILEINFO)

ver_GetFileVersionInfoSizeA:    ; (file, handle*) -> size of our fake version block
    HENTER
    lea rdi, [fmt_verinfo]
    mov esi, ARG(0)
    mov edx, GTA2_VERSION_MAJOR
    mov ecx, GTA2_VERSION_MINOR
    xor eax, eax
    call _printf
    mov eax, ARG(1)
    test eax, eax
    jz .r
    mov dword [rax], 0
.r:
    mov eax, VS_FFI_SIZE
    HRET

; (file, handle, len, data): the block is just a VS_FIXEDFILEINFO
ver_GetFileVersionInfoA:
    HENTER
    mov edi, ARG(3)
    test edi, edi
    jz .fail
    mov ecx, ARG(2)
    cmp ecx, VS_FFI_SIZE
    jb .fail
    lea rsi, [ver_fixedinfo]
    mov ecx, VS_FFI_SIZE
    rep movsb
    mov eax, 1
    HRET
.fail:
    mov dword [last_error], ERROR_INSUFFICIENT_BUFFER
    xor eax, eax
    HRET

; (block, subblock, buffer**, len*): only the root "\\" (VS_FIXEDFILEINFO) exists
ver_VerQueryValueA:
    HENTER
    mov eax, ARG(1)
    cmp word [rax], 0x005C          ; "\\" = backslash, NUL
    jne .fail
    mov eax, ARG(2)
    mov ecx, ARG(0)
    mov [rax], ecx
    mov eax, ARG(3)
    test eax, eax
    jz .ok
    mov dword [rax], VS_FFI_SIZE
.ok:
    mov eax, 1
    HRET
.fail:
    mov eax, ARG(2)
    mov dword [rax], 0
    xor eax, eax
    HRET

section .data
align 8
shimtab_winmm:
    dq s_winmm
    SHIM "timeGetTime", 0, k32_GetTickCount
    dq 0
shimtab_version:
    dq s_version
    SHIM "GetFileVersionInfoSizeA", 8, ver_GetFileVersionInfoSizeA
    SHIM "GetFileVersionInfoA", 16, ver_GetFileVersionInfoA
    SHIM "VerQueryValueA", 16, ver_VerQueryValueA
    dq 0
shimtab_ole32:
    dq s_ole32
    SHIM "CoInitialize", 4, h_ret0
    SHIM "CoUninitialize", 0, h_ret0
    SHIM "CoCreateInstance", 20, ole_CoCreateInstance
    dq 0
shimtab_shell32:
    dq s_shell32
    SHIM "ShellExecuteA", 24, shl_ShellExecuteA
    dq 0
shimtab_dplayx:
    dq s_dplayx
    SHIM "DirectPlayCreate", 12, dpl_DirectPlayCreate
    SHIM "DirectPlayLobbyCreateW", 20, dpl_DirectPlayLobbyCreateW
    dq 0
shimtab_mss32:
    dq s_mss32
    dq 0
shimtab_binkw32:
    dq s_binkw32
    dq 0
section .rodata
s_winmm:   db "WINMM", 0
s_version: db "VERSION", 0
s_ole32:   db "ole32", 0
s_shell32: db "SHELL32", 0
s_dinput8: db "DINPUT8", 0
s_dplayx:  db "DPLAYX", 0
fmt_cocreate: db "  [w32] CoCreateInstance({%08x-%04x-%04x-...}): no COM servers -> REGDB_E_CLASSNOTREG (from 0x%x)", 10, 0
fmt_shellexec: db "  [w32] ShellExecuteA(%s, %s): not supported -> error", 10, 0
fmt_verinfo: db "  [w32] GetFileVersionInfoSizeA(%s): fake VS_FIXEDFILEINFO, version %d.%d", 10, 0
align 4
ver_fixedinfo:                      ; VS_FIXEDFILEINFO
    dd 0xFEEF04BD, 0x00010000       ; dwSignature, dwStrucVersion
    dd (GTA2_VERSION_MAJOR << 16) | GTA2_VERSION_MINOR, 0   ; dwFileVersionMS/LS
    dd (GTA2_VERSION_MAJOR << 16) | GTA2_VERSION_MINOR, 0   ; dwProductVersionMS/LS
    dd 0x3F, 0                      ; dwFileFlagsMask, dwFileFlags
    dd 0x00040004, 1, 0             ; dwFileOS (NT_WINDOWS32), dwFileType (APP), dwFileSubtype
    dd 0, 0                         ; dwFileDateMS/LS
section .text
