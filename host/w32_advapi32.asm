; w32_advapi32.asm — ADVAPI32 shims: the registry as an in-memory store, seeded at
; startup from gta2_install.reg (REGEDIT4 text, overlay or data.pak), then adjusted by
; config.yaml (c/config.c: the debug section). Nothing is ever read from or written to a
; real registry or any system-wide file; writes stay in memory for the life of the
; process (not persisted yet).
;
; Keys are full paths ("HKEY_CURRENT_USER\Software\DMA Design Ltd\GTA2\screen"),
; compared case-insensitively. HKEY = REG_HKEY_BASE + 4*key index; the predefined
; roots 0x80000000.. map to their names.

REG_HKEY_BASE equ 0x00C00000
MAX_REG_KEYS  equ 256
MAX_REG_VALS  equ 1024
REG_LINE      equ 8192
; value record (host memory): {u32 key, u32 type, u32 size, u32 live, char* name, u8* data}
RV_KEY  equ 0
RV_TYPE equ 4
RV_SIZE equ 8
RV_LIVE equ 12
RV_NAME equ 16
RV_DATA equ 24
RV_SIZEOF equ 32

extern _fgets, _strcat, _strtoul

section .text

; eax = reg_key_find(rdi = full path) -> index or -1
reg_key_find:
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor ebx, ebx
.scan:
    cmp ebx, [reg_nkeys]
    jae .none
    lea rax, [reg_keys]
    mov rdi, [rax + rbx*8]
    mov rsi, r12
    call _strcasecmp
    test eax, eax
    jz .found
    inc ebx
    jmp .scan
.found:
    mov eax, ebx
    jmp .out
.none:
    mov eax, -1
.out:
    pop r13
    pop r12
    pop rbx
    ret

; eax = reg_key_add(rdi = full path) -> index of the existing or new key, -1 if full
reg_key_add:
    push rbx
    mov rbx, rdi
    call reg_key_find
    test eax, eax
    jns .out
    mov eax, [reg_nkeys]
    cmp eax, MAX_REG_KEYS
    jae .full
    mov rdi, rbx
    call _strdup
    mov ecx, [reg_nkeys]
    lea rdx, [reg_keys]
    mov [rdx + rcx*8], rax
    mov eax, ecx
    inc dword [reg_nkeys]
    jmp .out
.full:
    mov eax, -1
.out:
    pop rbx
    ret

; rax = reg_val_find(edi = key, rsi = name) -> record pointer or 0
reg_val_find:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    lea rbx, [reg_vals]
    xor ecx, ecx
.scan:
    cmp ecx, [reg_nvals]
    jae .none
    cmp dword [rbx + RV_LIVE], 0
    je .next
    cmp [rbx + RV_KEY], r12d
    jne .next
    push rcx
    sub rsp, 8
    mov rdi, [rbx + RV_NAME]
    mov rsi, r13
    call _strcasecmp
    add rsp, 8
    pop rcx
    test eax, eax
    jz .found
.next:
    add rbx, RV_SIZEOF
    inc ecx
    jmp .scan
.found:
    mov rax, rbx
    jmp .out
.none:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; reg_val_set(edi = key, rsi = name, edx = type, rcx = data, r8d = size)
reg_val_set:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
    mov r15, rcx
    mov ebx, r8d
    call reg_val_find
    test rax, rax
    jnz .have
    mov eax, [reg_nvals]
    cmp eax, MAX_REG_VALS
    jae .out
    inc dword [reg_nvals]
    shl eax, 5
    lea rcx, [reg_vals]
    add rax, rcx
    mov [rax + RV_KEY], r12d
    mov dword [rax + RV_LIVE], 1
    push rax
    sub rsp, 8
    mov rdi, r13
    call _strdup
    mov rcx, rax
    add rsp, 8
    pop rax
    mov [rax + RV_NAME], rcx
    mov qword [rax + RV_DATA], 0
.have:
    mov r13, rax
    mov [r13 + RV_TYPE], r14d
    mov [r13 + RV_SIZE], ebx
    mov rdi, [r13 + RV_DATA]
    call _free
    lea edi, [rbx + 1]
    call _malloc
    mov [r13 + RV_DATA], rax
    mov rdi, rax
    mov rsi, r15
    mov edx, ebx
    call _memcpy
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; reg_window_override: replaces screen\window_width/height for this run with 1280x960, or
; with --window=WxH (the install seeds 960x720). Windowed play (start_mode 0) sizes the
; window and lays the game view out for that size, and the renderer's gameplay back buffer
; follows it (docs/renderer-sdl.md, "Resolution").
reg_window_override:
    push rbx
    lea rdi, [s_reg_screen]
    call reg_key_find
    cmp eax, -1
    jne .have
    lea rdi, [s_reg_screen]
    call reg_key_add
.have:
    mov ebx, eax
    mov eax, [reg_win_w]
    mov [reg_data], eax
    mov edi, ebx
    lea rsi, [s_reg_ww]
    mov edx, 4
    lea rcx, [reg_data]
    mov r8d, 4
    call reg_val_set
    mov eax, [reg_win_h]
    mov [reg_data], eax
    mov edi, ebx
    lea rsi, [s_reg_wh]
    mov edx, 4
    lea rcx, [reg_data]
    mov r8d, 4
    call reg_val_set
    lea rdi, [fmt_reg_screen]
    mov esi, [reg_win_w]
    mov edx, [reg_win_h]
    xor eax, eax
    call _printf
    pop rbx
    ret

; rax = reg_path(edi = HKEY, rsi = subkey or 0) -> full path in reg_pathbuf, or 0
reg_path:
    push rbx
    push r12
    push r13
    mov r12, rsi
    lea rbx, [reg_root_names]
    mov eax, edi
    sub eax, 0x80000000
    cmp eax, 3
    jbe .root
    mov eax, edi
    sub eax, REG_HKEY_BASE
    jb .bad
    shr eax, 2
    cmp eax, [reg_nkeys]
    jae .bad
    lea rcx, [reg_keys]
    mov rsi, [rcx + rax*8]
    jmp .base
.root:
    mov rsi, [rbx + rax*8]
.base:
    lea rdi, [reg_pathbuf]
    call _strcpy
    test r12, r12
    jz .done
.skip_sep:
    cmp byte [r12], '\'
    jne .sub
    inc r12
    jmp .skip_sep
.sub:
    cmp byte [r12], 0
    je .done
    lea rdi, [reg_pathbuf]
    lea rsi, [s_backslash]
    call _strcat
    lea rdi, [reg_pathbuf]
    mov rsi, r12
    call _strcat
    lea rdi, [reg_pathbuf]          ; drop trailing backslashes
    call _strlen
    lea rcx, [reg_pathbuf]
.trim:
    test eax, eax
    jz .done
    cmp byte [rcx + rax - 1], '\'
    jne .done
    dec eax
    mov byte [rcx + rax], 0
    jmp .trim
.done:
    lea rax, [reg_pathbuf]
    jmp .out
.bad:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; eax = reg_hkey_index(edi = HKEY) -> key index or -1 (roots have no values)
reg_hkey_index:
    mov eax, edi
    sub eax, REG_HKEY_BASE
    jb .bad
    shr eax, 2
    cmp eax, [reg_nkeys]
    jae .bad
    ret
.bad:
    mov eax, -1
    ret

; ---- .reg parser ----------------------------------------------------------
; rax = reg_unquote(rdi = pointer at the opening quote, rsi = out) -> pointer after
; the closing quote; handles \\ and \" escapes.
reg_unquote:
    inc rdi
.c:
    movzx eax, byte [rdi]
    test al, al
    jz .end
    cmp al, '"'
    je .close
    cmp al, '\'
    jne .put
    cmp byte [rdi + 1], 0
    je .put
    inc rdi
    movzx eax, byte [rdi]
.put:
    mov [rsi], al
    inc rsi
    inc rdi
    jmp .c
.close:
    inc rdi
.end:
    mov byte [rsi], 0
    mov rax, rdi
    ret

; strip trailing CR/LF/blanks of reg_line (rdi = string)
reg_rstrip:
    push rbx
    mov rbx, rdi
    call _strlen
.t:
    test eax, eax
    jz .r
    movzx ecx, byte [rbx + rax - 1]
    cmp cl, ' '
    ja .r
    dec eax
    mov byte [rbx + rax], 0
    jmp .t
.r:
    pop rbx
    ret

setup_registry:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [s_regfile]
    call vfs_load                   ; overlay or pak
    test rax, rax
    jz .no_file
    mov [reg_file_buf], rax
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [s_mode_r]
    call _fmemopen
    mov r15, rax
    mov r14d, -1                    ; current key
.line:
    lea rdi, [reg_line]
    mov esi, REG_LINE
    mov rdx, r15
    call _fgets
    test rax, rax
    jz .eof
    lea rdi, [reg_line]
    call reg_rstrip
.cont:                              ; join "\" continuation lines
    lea rdi, [reg_line]
    call _strlen
    test eax, eax
    jz .parse
    lea rcx, [reg_line]
    cmp byte [rcx + rax - 1], '\'
    jne .parse
    mov byte [rcx + rax - 1], 0
    lea rdi, [reg_tmp]
    mov esi, REG_LINE / 2
    mov rdx, r15
    call _fgets
    test rax, rax
    jz .parse
    lea rdi, [reg_tmp]
    call reg_rstrip
    lea rsi, [reg_tmp]
.lead:
    cmp byte [rsi], ' '
    jne .append
    inc rsi
    jmp .lead
.append:
    lea rdi, [reg_line]
    call _strcat
    jmp .cont
.parse:
    lea rbx, [reg_line]
    movzx eax, byte [rbx]
    cmp al, '['
    je .key
    test r14d, r14d
    js .line
    cmp al, '@'
    je .default_name
    cmp al, '"'
    jne .line
    mov rdi, rbx
    lea rsi, [reg_name]
    call reg_unquote
    mov rbx, rax
    jmp .eq
.default_name:
    mov byte [reg_name], 0
    inc rbx
.eq:
    cmp byte [rbx], '='
    jne .line
    inc rbx
    cmp byte [rbx], '"'
    je .string
    mov rdi, rbx
    lea rsi, [s_dword]
    mov edx, 6
    call _strncmp
    test eax, eax
    jz .dword
    mov rdi, rbx
    lea rsi, [s_hexc]
    mov edx, 4
    call _strncmp
    test eax, eax
    jz .binary
    mov rdi, rbx
    lea rsi, [s_hexp]
    mov edx, 4
    call _strncmp
    test eax, eax
    jnz .line
    lea rdi, [rbx + 4]              ; hex(N): typed bytes
    lea rsi, [reg_end]
    mov edx, 16
    call _strtoul
    mov r13d, eax
    mov rbx, [reg_end]
    add rbx, 2                      ; "):"
    jmp .bytes
.binary:
    mov r13d, 3                     ; REG_BINARY
    add rbx, 4
.bytes:
    xor r12d, r12d
.byte:
    cmp byte [rbx], 0
    je .store
    mov rdi, rbx
    lea rsi, [reg_end]
    mov edx, 16
    call _strtoul
    cmp [reg_end], rbx
    je .store
    lea rcx, [reg_data]
    mov [rcx + r12], al
    inc r12d
    mov rbx, [reg_end]
    cmp byte [rbx], ','
    jne .byte
    inc rbx
    cmp r12d, REG_LINE
    jb .byte
    jmp .store
.dword:
    lea rdi, [rbx + 6]
    xor esi, esi
    mov edx, 16
    call _strtoul
    mov [reg_data], eax
    mov r13d, 4                     ; REG_DWORD
    mov r12d, 4
    jmp .store
.string:
    mov rdi, rbx
    lea rsi, [reg_data]
    call reg_unquote
    lea rdi, [reg_data]
    call _strlen
    lea r12d, [rax + 1]
    mov r13d, 1                     ; REG_SZ
.store:
    mov edi, r14d
    lea rsi, [reg_name]
    mov edx, r13d
    lea rcx, [reg_data]
    mov r8d, r12d
    call reg_val_set
    jmp .line
.key:
    lea rdi, [rbx + 1]
    mov esi, ']'
    call _strchr
    test rax, rax
    jz .line
    mov byte [rax], 0
    lea rdi, [rbx + 1]
    call reg_key_add
    mov r14d, eax
    jmp .line
.eof:
    mov rdi, r15
    call _fclose
    mov rdi, [reg_file_buf]
    call _free
    lea rdi, [fmt_reg_loaded]
    lea rsi, [s_regfile]
    mov edx, [reg_nkeys]
    mov ecx, [reg_nvals]
    xor eax, eax
    call _printf
    call reg_window_override
    call _config_apply
    jmp .out
.no_file:
    lea rdi, [fmt_reg_none]
    lea rsi, [s_regfile]
    xor eax, eax
    call _printf
    call reg_window_override
    call _config_apply
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- shims ----------------------------------------------------------------
ERROR_SUCCESS equ 0

adv_RegOpenKeyExA:          ; (hKey, subKey, options, sam, phkResult)
    HENTER
    mov edi, ARG(0)
    mov esi, ARG(1)
    call reg_path
    test rax, rax
    jz .missing
    mov r12, rax
    mov rdi, rax
    call reg_key_find
    test eax, eax
    js .missing
    lea eax, [REG_HKEY_BASE + rax*4]
    mov ecx, ARG(4)
    mov [rcx], eax
    cmp byte [trace], 0
    je .ok
    lea rdi, [fmt_reg_open]
    mov rsi, r12
    mov edx, eax
    xor eax, eax
    call _printf
.ok:
    xor eax, eax
    HRET
.missing:
    lea rdi, [fmt_reg_nokey]
    lea rsi, [reg_pathbuf]
    xor eax, eax
    call _printf
    mov eax, ERROR_FILE_NOT_FOUND
    HRET

adv_RegCreateKeyExA:        ; (hKey, subKey, 0, class, options, sam, sec, phk, disp*)
    HENTER
    mov edi, ARG(0)
    mov esi, ARG(1)
    call reg_path
    test rax, rax
    jz .bad
    mov r12, rax
    mov rdi, rax
    call reg_key_find
    mov r13d, 2                     ; REG_OPENED_EXISTING_KEY
    test eax, eax
    jns .have
    mov r13d, 1                     ; REG_CREATED_NEW_KEY
    mov rdi, r12
    call reg_key_add
    test eax, eax
    js .bad
.have:
    lea eax, [REG_HKEY_BASE + rax*4]
    mov ecx, ARG(7)
    mov [rcx], eax
    mov ecx, ARG(8)
    test ecx, ecx
    jz .ok
    mov [rcx], r13d
.ok:
    xor eax, eax
    HRET
.bad:
    mov eax, ERROR_FILE_NOT_FOUND
    HRET

adv_RegQueryValueExA:       ; (hKey, name, reserved, type*, data*, cbData*)
    HENTER
    mov edi, ARG(0)
    call reg_hkey_index
    test eax, eax
    js .missing
    mov edi, eax
    mov esi, ARG(1)
    test esi, esi
    jnz .find
    lea rsi, [s_empty_str]
.find:
    call reg_val_find
    test rax, rax
    jz .missing
    mov r12, rax
    mov eax, ARG(3)
    test eax, eax
    jz .no_type
    mov ecx, [r12 + RV_TYPE]
    mov [rax], ecx
.no_type:
    mov r13d, [r12 + RV_SIZE]
    mov r14d, ARG(5)                ; cbData*
    mov eax, ARG(4)
    test eax, eax
    jz .size_only
    test r14d, r14d
    jz .more
    cmp [r14], r13d
    jb .more
    mov edi, eax
    mov rsi, [r12 + RV_DATA]
    mov edx, r13d
    call _memcpy
.size_only:
    test r14d, r14d
    jz .ok
    mov [r14], r13d
.ok:
    xor eax, eax
    HRET
.more:
    test r14d, r14d
    jz .m
    mov [r14], r13d
.m:
    mov eax, ERROR_MORE_DATA
    HRET
.missing:
    cmp byte [trace], 0
    je .m2
    lea rdi, [fmt_reg_noval]
    mov esi, ARG(1)
    xor eax, eax
    call _printf
.m2:
    mov eax, ERROR_FILE_NOT_FOUND
    HRET

adv_RegSetValueExA:         ; (hKey, name, reserved, type, data, cb)
    HENTER
    mov edi, ARG(0)
    call reg_hkey_index
    test eax, eax
    js .bad
    mov edi, eax
    mov esi, ARG(1)
    test esi, esi
    jnz .set
    lea rsi, [s_empty_str]
.set:
    mov edx, ARG(3)
    mov ecx, ARG(4)
    mov r8d, ARG(5)
    call reg_val_set
    xor eax, eax
    HRET
.bad:
    mov eax, ERROR_INVALID_HANDLE
    HRET

adv_RegDeleteValueA:        ; (hKey, name)
    HENTER
    mov edi, ARG(0)
    call reg_hkey_index
    test eax, eax
    js .missing
    mov edi, eax
    mov esi, ARG(1)
    test esi, esi
    jnz .find
    lea rsi, [s_empty_str]
.find:
    call reg_val_find
    test rax, rax
    jz .missing
    mov dword [rax + RV_LIVE], 0
    xor eax, eax
    HRET
.missing:
    mov eax, ERROR_FILE_NOT_FOUND
    HRET

adv_RegCloseKey:
    xor eax, eax
    ret

adv_GetUserNameA:           ; (buf, size*)
    HENTER
    mov r12d, ARG(1)
    cmp dword [r12], 7
    jb .small
    mov edi, ARG(0)
    lea rsi, [s_username]
    call _strcpy
    mov dword [r12], 7              ; including the NUL
    mov eax, 1
    HRET
.small:
    mov dword [r12], 7
    mov dword [last_error], ERROR_INSUFFICIENT_BUFFER
    xor eax, eax
    HRET

section .data
align 8
reg_root_names:
    dq s_hkcr, s_hkcu, s_hklm, s_hku

shimtab_advapi32:
    dq s_advapi32
    SHIM "RegOpenKeyExA", 20, adv_RegOpenKeyExA
    SHIM "RegCreateKeyExA", 36, adv_RegCreateKeyExA
    SHIM "RegQueryValueExA", 24, adv_RegQueryValueExA
    SHIM "RegSetValueExA", 24, adv_RegSetValueExA
    SHIM "RegDeleteValueA", 8, adv_RegDeleteValueA
    SHIM "RegCloseKey", 4, adv_RegCloseKey
    SHIM "GetUserNameA", 8, adv_GetUserNameA
    SHIM "IsTextUnicode", 12, h_ret0
    dq 0

section .rodata
s_advapi32:  db "ADVAPI32", 0
s_hkcr:      db "HKEY_CLASSES_ROOT", 0
s_hkcu:      db "HKEY_CURRENT_USER", 0
s_hklm:      db "HKEY_LOCAL_MACHINE", 0
s_hku:       db "HKEY_USERS", 0
s_backslash: db "\", 0
s_regfile:   db "gta2_install.reg", 0
s_reg_screen: db "HKEY_CURRENT_USER\Software\DMA Design Ltd\GTA2\screen", 0
s_reg_ww:    db "window_width", 0
s_reg_wh:    db "window_height", 0
fmt_reg_screen: db "registry: screen\window_width/height = %dx%d", 10, 0
s_mode_r:    db "r", 0
s_dword:     db "dword:", 0
s_hexc:      db "hex:", 0
s_hexp:      db "hex(", 0
s_username:  db "Player", 0
fmt_reg_loaded: db "registry: %s -> %d keys, %d values (in memory only)", 10, 0
fmt_reg_none: db "registry: %s not found, starting empty", 10, 0
fmt_reg_open: db "  [w32] RegOpenKeyExA(%s) -> 0x%x", 10, 0
fmt_reg_nokey: db "  [w32] registry key not found: %s", 10, 0
fmt_reg_noval: db "  [w32] registry value not found: %s", 10, 0

section .data
reg_win_w:   dd 1280             ; window size for the run; --window=WxH overrides
reg_win_h:   dd 960

section .bss
alignb 8
reg_file_buf: resq 1
reg_nkeys:   resd 1
reg_nvals:   resd 1
reg_end:     resq 1
reg_keys:    resq MAX_REG_KEYS
reg_vals:    resb RV_SIZEOF * MAX_REG_VALS
reg_pathbuf: resb 2048
reg_name:    resb 1024
reg_line:    resb REG_LINE
reg_tmp:     resb REG_LINE / 2
reg_data:    resb REG_LINE
section .text
