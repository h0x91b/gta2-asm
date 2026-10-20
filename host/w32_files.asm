; w32_files.asm — KERNEL32 file shims on top of the game directory.
;
; Path policy: the host chdir()s into the directory holding gta2.exe, and the game is
; told it lives in C:\GTA2 (GetModuleFileNameA / GetCurrentDirectoryA). win_path maps
;   C:\GTA2\x, \GTA2\x (any case, either slash)  -> x
;   relative paths                                -> relative to the game directory
;   any other absolute path                       -> refused (not found)
; and then resolves every component case-insensitively against what is on disk
; (Windows is case-insensitive, APFS here is too by default, but nothing guarantees it).

O_RDONLY equ 0
O_WRONLY equ 1
O_RDWR   equ 2
O_CREAT  equ 0x200
O_TRUNC  equ 0x400
O_EXCL   equ 0x800
GENERIC_READ  equ 0x80000000
GENERIC_WRITE equ 0x40000000
INVALID_HANDLE equ -1
DIRENT_NAME equ 21                  ; offsetof(struct dirent, d_name), 64-bit ino
ST_MODE     equ 4                   ; struct stat (macOS x86_64): st_mode u16 at 4
ST_SIZE     equ 96                  ; st_size at 96
S_IFMT      equ 0xF000
S_IFDIR     equ 0x4000
FNM_CASEFOLD equ 0x10
PATH_MAX_W  equ 1024

extern _ftruncate, _fnmatch, _free

section .text

; rax = win_path(rdi = Windows path) -> host path (static path_out buffer), 0 if refused
win_path:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    cmp byte [rbx], 0
    je .refuse
    cmp byte [rbx + 1], ':'
    jne .no_drive
    add rbx, 2                      ; drop the drive letter (any)
    movzx eax, byte [rbx]
    cmp al, '\'
    je .absolute
    cmp al, '/'
    je .absolute
    jmp .relative                   ; "C:foo" = relative to the current dir
.no_drive:
    movzx eax, byte [rbx]
    cmp al, '\'
    je .absolute
    cmp al, '/'
    je .absolute
    jmp .relative
.absolute:                          ; must be \GTA2 or below
    lea rdi, [rbx + 1]
    lea rsi, [s_gta2dir]
    mov edx, 4
    call _strncasecmp
    test eax, eax
    jnz .refuse
    movzx eax, byte [rbx + 5]
    add rbx, 5
    test al, al
    jz .relative
    cmp al, '\'
    je .skip_sep
    cmp al, '/'
    jne .refuse
.skip_sep:
    inc rbx
.relative:
    ; copy to path_in with '/' separators
    lea r12, [path_in]
    xor ecx, ecx
.copy:
    movzx eax, byte [rbx + rcx]
    cmp al, '\'
    jne .c1
    mov al, '/'
.c1:
    mov [r12 + rcx], al
    test al, al
    jz .copied
    inc ecx
    cmp ecx, PATH_MAX_W - 1
    jb .copy
    jmp .refuse
.copied:
    ; resolve component by component into path_out
    lea r13, [path_out]
    mov byte [r13], 0
    xor r14d, r14d                  ; out length
    mov r15, r12                    ; component start
.comp:
    cmp byte [r15], '/'             ; collapse repeated separators
    jne .comp_start
    inc r15
    jmp .comp
.comp_start:
    cmp byte [r15], 0
    je .done
    mov rbx, r15                    ; find the component end
.scan:
    movzx eax, byte [rbx]
    test al, al
    jz .have_end
    cmp al, '/'
    je .have_end
    inc rbx
    jmp .scan
.have_end:
    ; append "/" (if not first) + component
    test r14d, r14d
    jz .no_sep
    mov byte [r13 + r14], '/'
    inc r14d
.no_sep:
    mov [comp_off], r14d
    mov rcx, rbx
    sub rcx, r15
    lea edx, [r14 + rcx + 1]
    cmp edx, PATH_MAX_W
    jae .refuse
    lea rdi, [r13 + r14]
    mov rsi, r15
    mov rdx, rcx
    add r14d, ecx
    call _memcpy
    mov byte [r13 + r14], 0
    ; exists as typed?
    mov rdi, r13
    lea rsi, [stat_buf]
    call _stat
    test eax, eax
    jz .next_comp
    call ci_fix_last                ; try a case-insensitive match in the parent
.next_comp:
    mov r15, rbx
    jmp .comp
.done:
    test r14d, r14d
    jnz .ok
    mov word [r13], '.'
.ok:
    mov rax, r13
    jmp .out
.refuse:
    xor eax, eax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ci_fix_last: path_out[comp_off..] is a component that does not exist as typed;
; replace it with a case-insensitive match from its parent directory, if any.
ci_fix_last:
    push rbx
    push r12
    push r13
    lea r12, [path_out]
    mov ebx, [comp_off]
    ; parent = path_out[0..comp_off-1] (or ".")
    lea rdi, [s_dot]
    test ebx, ebx
    jz .open
    mov byte [r12 + rbx - 1], 0
    mov rdi, r12
.open:
    call _opendir
    test ebx, ebx
    jz .restored
    mov byte [r12 + rbx - 1], '/'
.restored:
    test rax, rax
    jz .out
    mov r13, rax
.entry:
    mov rdi, r13
    call _readdir
    test rax, rax
    jz .close
    lea rdi, [rax + DIRENT_NAME]
    lea rsi, [r12 + rbx]
    push rdi
    sub rsp, 8
    call _strcasecmp
    add rsp, 8
    pop rsi
    test eax, eax
    jnz .entry
    lea rdi, [r12 + rbx]            ; same length, different case: overwrite
    call _strcpy
.close:
    mov rdi, r13
    call _closedir
.out:
    pop r13
    pop r12
    pop rbx
    ret

; ---- handles of open files -----------------------------------------------
; eax = fd for a file/std handle, -1 otherwise
handle_fd:
    sub rsp, 8
    call handle_get
    add rsp, 8
    test rax, rax
    jz .no
    cmp dword [rax], HT_FILE
    je .yes
    cmp dword [rax], HT_STD
    jne .no
.yes:
    mov eax, [rax + 4]
    ret
.no:
    mov eax, -1
    ret

k32_CreateFileA:    ; (name, access, share, sec, disposition, flags, template)
    HENTER
    mov edi, ARG(0)
    call win_path
    test rax, rax
    jz .not_found
    mov r12, rax
    ; access -> O_RDONLY / O_WRONLY / O_RDWR
    mov eax, ARG(1)
    xor r13d, r13d
    test eax, GENERIC_WRITE
    jz .flags_rw
    mov r13d, O_WRONLY
    test eax, GENERIC_READ
    jz .flags_rw
    mov r13d, O_RDWR
.flags_rw:
    mov eax, ARG(4)
    cmp eax, 1                      ; CREATE_NEW
    jne .d2
    or r13d, O_CREAT | O_EXCL
.d2:
    cmp eax, 2                      ; CREATE_ALWAYS
    jne .d4
    or r13d, O_CREAT | O_TRUNC
.d4:
    cmp eax, 4                      ; OPEN_ALWAYS
    jne .d5
    or r13d, O_CREAT
.d5:
    cmp eax, 5                      ; TRUNCATE_EXISTING
    jne .open
    or r13d, O_TRUNC
.open:
    mov rdi, r12
    mov esi, r13d
    mov edx, 0644o
    xor eax, eax
    call _open
    test eax, eax
    js .not_found
    mov r14d, eax
    mov edi, HT_FILE
    mov esi, r14d
    xor edx, edx
    call handle_new
    mov r13d, eax
    cmp byte [trace], 0
    je .ret
    lea rdi, [fmt_open]
    mov esi, ARG(0)
    mov rdx, r12
    mov ecx, r13d
    xor eax, eax
    call _printf
.ret:
    mov dword [last_error], 0
    mov eax, r13d
    HRET
.not_found:
    lea rdi, [fmt_open_fail]
    mov esi, ARG(0)
    xor eax, eax
    call _printf
    mov dword [last_error], ERROR_FILE_NOT_FOUND
    mov eax, INVALID_HANDLE
    HRET

k32_ReadFile:       ; (h, buf, n, read*, overlapped)
    HENTER
    mov edi, ARG(0)
    call handle_fd
    test eax, eax
    js .bad
    mov edi, eax
    mov esi, ARG(1)
    mov edx, ARG(2)
    call _read
    test rax, rax
    js .bad
    mov ecx, ARG(3)
    test ecx, ecx
    jz .ok
    mov [rcx], eax
.ok:
    mov eax, 1
    HRET
.bad:
    mov dword [last_error], ERROR_INVALID_HANDLE
    xor eax, eax
    HRET

k32_WriteFile:      ; (h, buf, n, written*, overlapped)
    HENTER
    mov edi, ARG(0)
    call handle_fd
    test eax, eax
    js .bad
    mov edi, eax
    mov esi, ARG(1)
    mov edx, ARG(2)
    call _write
    test rax, rax
    js .bad
    mov ecx, ARG(3)
    test ecx, ecx
    jz .ok
    mov [rcx], eax
.ok:
    mov eax, 1
    HRET
.bad:
    mov dword [last_error], ERROR_INVALID_HANDLE
    xor eax, eax
    HRET

k32_SetFilePointer: ; (h, lo, hi*, method) -> new low dword
    HENTER
    mov edi, ARG(0)
    call handle_fd
    test eax, eax
    js .bad
    mov edi, eax
    movsxd rsi, ARG(1)
    mov ecx, ARG(2)
    test ecx, ecx
    jz .seek
    mov esi, ARG(1)                 ; 64-bit distance = hi:lo
    mov eax, [rcx]
    shl rax, 32
    or rsi, rax
.seek:
    mov edx, ARG(3)                 ; FILE_BEGIN/CURRENT/END = SEEK_SET/CUR/END
    call _lseek
    test rax, rax
    js .bad
    mov ecx, ARG(2)
    test ecx, ecx
    jz .r
    mov rdx, rax
    shr rdx, 32
    mov [rcx], edx
.r:
    HRET
.bad:
    mov dword [last_error], ERROR_INVALID_HANDLE
    mov eax, -1
    HRET

k32_SetEndOfFile:   ; (h)
    HENTER
    mov edi, ARG(0)
    call handle_fd
    test eax, eax
    js .bad
    mov r12d, eax
    mov edi, eax
    xor esi, esi
    mov edx, 1                      ; SEEK_CUR
    call _lseek
    mov edi, r12d
    mov rsi, rax
    call _ftruncate
    mov eax, 1
    HRET
.bad:
    xor eax, eax
    HRET

k32_GetFileType:    ; (h) -> FILE_TYPE_DISK 1 / CHAR 2 / UNKNOWN 0
    sub rsp, 8
    mov edi, [rdi]
    call handle_get
    add rsp, 8
    test rax, rax
    jz .unk
    cmp dword [rax], HT_STD
    je .chr
    cmp dword [rax], HT_FILE
    jne .unk
    mov eax, 1
    ret
.chr:
    mov eax, 2
    ret
.unk:
    xor eax, eax
    ret

k32_GetStdHandle:   ; (-10 / -11 / -12)
    mov eax, [rdi]
    neg eax
    sub eax, 10
    cmp eax, 2
    ja .bad
    lea rcx, [std_handles]
    mov eax, [rcx + rax*4]
    ret
.bad:
    mov eax, INVALID_HANDLE
    ret

k32_GetFileAttributesA: ; (path) -> attributes or INVALID_FILE_ATTRIBUTES
    HENTER
    mov edi, ARG(0)
    call win_path
    test rax, rax
    jz .missing
    mov rdi, rax
    lea rsi, [stat_buf]
    call _stat
    test eax, eax
    jnz .missing
    movzx eax, word [stat_buf + ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    mov eax, 0x80                   ; FILE_ATTRIBUTE_NORMAL
    mov ecx, 0x10                   ; FILE_ATTRIBUTE_DIRECTORY
    cmove eax, ecx
    HRET
.missing:
    mov dword [last_error], ERROR_FILE_NOT_FOUND
    mov eax, -1
    HRET

; ---- directory search ------------------------------------------------------
; HT_FIND handle extra -> host block {DIR* 0, char dir[1024] 8, char pattern[260] 1032}
FIND_DIR    equ 0
FIND_PATH   equ 8
FIND_PAT    equ 1032
FIND_SIZE   equ 1296

k32_FindFirstFileA: ; (pattern, WIN32_FIND_DATAA*)
    HENTER
    mov edi, FIND_SIZE
    call _malloc
    mov r12, rax
    ; split "dir\pattern" on a host copy (the game's string may be read-only)
    lea rdi, [find_tmp]
    mov esi, ARG(0)
    mov edx, PATH_MAX_W - 1
    call _strncpy
    mov byte [find_tmp + PATH_MAX_W - 1], 0
    lea rdi, [find_tmp]
    mov esi, '\'
    call _strrchr
    mov r13, rax
    test rax, rax
    jnz .split
    lea rdi, [find_tmp]
    mov esi, '/'
    call _strrchr
    mov r13, rax
.split:
    test r13, r13
    jnz .has_dir
    mov word [r12 + FIND_PATH], '.'
    mov esi, ARG(0)
    jmp .pattern
.has_dir:
    mov byte [r13], 0
    lea rdi, [find_tmp]
    call win_path
    test rax, rax
    jz .fail
    lea rdi, [r12 + FIND_PATH]
    mov rsi, rax
    call _strcpy
    lea rsi, [r13 + 1]
.pattern:
    lea rdi, [r12 + FIND_PAT]
    mov edx, 259
    call _strncpy
    mov byte [r12 + FIND_PAT + 259], 0
    lea rdi, [r12 + FIND_PAT]       ; Windows "*.*" also matches names without a dot
    lea rsi, [s_starstar]
    call _strcmp
    test eax, eax
    jnz .opendir
    mov word [r12 + FIND_PAT], '*'
.opendir:
    lea rdi, [r12 + FIND_PATH]
    call _opendir
    test rax, rax
    jz .fail
    mov [r12 + FIND_DIR], rax
    mov rdi, r12
    mov esi, ARG(1)
    call find_next
    test eax, eax
    jz .empty
    mov edi, HT_FIND
    xor esi, esi
    mov rdx, r12
    call handle_new
    mov r13d, eax
    cmp byte [trace], 0
    je .ret
    lea rdi, [fmt_find]
    mov esi, ARG(0)
    mov edx, r13d
    xor eax, eax
    call _printf
.ret:
    mov eax, r13d
    HRET
.empty:
    mov rdi, [r12 + FIND_DIR]
    call _closedir
.fail:
    mov rdi, r12
    call _free
    lea rdi, [fmt_find_none]
    mov esi, ARG(0)
    xor eax, eax
    call _printf
    mov dword [last_error], ERROR_FILE_NOT_FOUND
    mov eax, INVALID_HANDLE
    HRET

k32_FindNextFileA:  ; (h, WIN32_FIND_DATAA*)
    HENTER
    mov edi, ARG(0)
    call handle_get
    test rax, rax
    jz .bad
    cmp dword [rax], HT_FIND
    jne .bad
    mov rdi, [rax + 8]
    mov esi, ARG(1)
    call find_next
    test eax, eax
    jnz .r
    mov dword [last_error], ERROR_NO_MORE_FILES
.r:
    HRET
.bad:
    mov dword [last_error], ERROR_INVALID_HANDLE
    xor eax, eax
    HRET

k32_FindClose:      ; (h)
    HENTER
    mov edi, ARG(0)
    call handle_get
    test rax, rax
    jz .bad
    cmp dword [rax], HT_FIND
    jne .bad
    mov r12, rax
    mov r13, [rax + 8]
    mov rdi, [r13 + FIND_DIR]
    call _closedir
    mov rdi, r13
    call _free
    mov dword [r12], HT_FREE
    mov eax, 1
    HRET
.bad:
    xor eax, eax
    HRET

; eax = find_next(rdi = find block, esi = WIN32_FIND_DATAA*): 1 = filled, 0 = no more.
; Skips "." and "..".
find_next:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi
.entry:
    mov rdi, [rbx + FIND_DIR]
    call _readdir
    test rax, rax
    jz .none
    lea r13, [rax + DIRENT_NAME]
    cmp byte [r13], '.'
    jne .match
    cmp byte [r13 + 1], 0
    je .entry
    cmp word [r13 + 1], '.'         ; ".." + NUL
    je .entry
.match:
    lea rdi, [rbx + FIND_PAT]
    mov rsi, r13
    mov edx, FNM_CASEFOLD
    call _fnmatch
    test eax, eax
    jnz .entry
    ; fill WIN32_FIND_DATAA (320 bytes)
    mov edi, r12d
    xor esi, esi
    mov edx, 320
    call _memset
    lea rdi, [r12 + 44]             ; cFileName[260]
    mov rsi, r13
    mov edx, 259
    call _strncpy
    lea rdi, [find_tmp]             ; stat dir/name for size + attributes
    mov esi, PATH_MAX_W
    lea rdx, [fmt_join]
    lea rcx, [rbx + FIND_PATH]
    mov r8, r13
    xor eax, eax
    call _snprintf
    lea rdi, [find_tmp]
    lea rsi, [stat_buf]
    call _stat
    mov dword [r12], 0x80           ; FILE_ATTRIBUTE_NORMAL
    test eax, eax
    jnz .filled
    mov rax, [stat_buf + ST_SIZE]
    mov [r12 + 32], eax             ; nFileSizeLow
    shr rax, 32
    mov [r12 + 28], eax             ; nFileSizeHigh
    movzx eax, word [stat_buf + ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .filled
    mov dword [r12], 0x10           ; FILE_ATTRIBUTE_DIRECTORY
.filled:
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- directories / paths ---------------------------------------------------
k32_GetCurrentDirectoryA:   ; (size, buf) -> length (we never leave C:\GTA2)
    HENTER
    lea rdi, [s_virt_dir]
    call _strlen
    mov r12d, eax
    cmp ARG(0), eax
    jbe .small
    mov edi, ARG(1)
    lea rsi, [s_virt_dir]
    call _strcpy
    mov eax, r12d
    HRET
.small:
    lea eax, [r12 + 1]
    HRET

k32_SetCurrentDirectoryA:   ; (path): only the game directory itself is supported
    HENTER
    lea rdi, [fmt_setcwd]
    mov esi, ARG(0)
    xor eax, eax
    call _printf
    mov edi, ARG(0)
    call win_path
    test rax, rax
    jz .fail
    cmp word [rax], '.'
    jne .fail
    mov eax, 1
    HRET
.fail:
    mov dword [last_error], ERROR_PATH_NOT_FOUND
    xor eax, eax
    HRET

k32_GetFullPathNameA:   ; (name, size, buf, filepart*) -> length
    HENTER
    mov r12d, ARG(0)
    mov edi, ARG(2)
    mov esi, ARG(1)
    cmp byte [r12 + 1], ':'
    je .abs
    lea rdx, [fmt_fullpath]         ; relative: C:\GTA2\name
    lea rcx, [s_virt_dir]
    mov r8, r12
    jmp .fmt
.abs:
    lea rdx, [fmt_str]
    mov rcx, r12
.fmt:
    xor eax, eax
    call _snprintf
    mov r12d, eax
    mov r13d, ARG(3)
    test r13d, r13d
    jz .r
    mov edi, ARG(2)
    mov esi, '\'
    call _strrchr
    lea rdx, [rax + 1]
    mov [r13], edx
.r:
    mov eax, r12d
    HRET

k32_GetDriveTypeA:
    mov eax, 3                      ; DRIVE_FIXED
    ret

; GetPrivateProfileStringA(app, key, default, buf, size, file): no INI files are
; supported yet; returns the default and logs the request.
k32_GetPrivateProfileStringA:
    HENTER
    lea rdi, [fmt_ini]
    mov esi, ARG(5)
    mov edx, ARG(0)
    mov ecx, ARG(1)
    xor eax, eax
    call _printf
    mov edi, ARG(3)
    mov esi, ARG(2)
    test esi, esi
    jnz .copy
    lea rsi, [s_empty_str]
.copy:
    mov edx, ARG(4)
    dec edx
    call _strncpy
    mov edi, ARG(3)
    mov eax, ARG(4)
    mov byte [rdi + rax - 1], 0
    call _strlen
    HRET

section .rodata
s_gta2dir:   db "GTA2", 0
s_virt_dir:  db "C:\GTA2", 0
s_dot:       db ".", 0
s_starstar:  db "*.*", 0
fmt_join:    db "%s/%s", 0
fmt_fullpath: db "%s\%s", 0
fmt_str:     db "%s", 0
fmt_open:    db "  [w32] CreateFileA(%s) -> %s, handle 0x%x", 10, 0
fmt_open_fail: db "  [w32] CreateFileA(%s) -> not found", 10, 0
fmt_find:    db "  [w32] FindFirstFileA(%s) -> 0x%x", 10, 0
fmt_find_none: db "  [w32] FindFirstFileA(%s) -> no match", 10, 0
fmt_setcwd:  db "  [w32] SetCurrentDirectoryA(%s)", 10, 0
fmt_ini:     db "  [w32] GetPrivateProfileStringA(%s, [%s] %s): no INI support, default", 10, 0

section .bss
alignb 4
comp_off:   resd 1
path_in:    resb PATH_MAX_W
path_out:   resb PATH_MAX_W
find_tmp:   resb PATH_MAX_W
section .text

section .data
align 8
shimtab_kernel32_files:
    dq s_kernel32
    SHIM "CreateFileA", 28, k32_CreateFileA
    SHIM "ReadFile", 20, k32_ReadFile
    SHIM "WriteFile", 20, k32_WriteFile
    SHIM "SetFilePointer", 16, k32_SetFilePointer
    SHIM "SetEndOfFile", 4, k32_SetEndOfFile
    SHIM "FlushFileBuffers", 4, h_ret1
    SHIM "GetFileType", 4, k32_GetFileType
    SHIM "GetStdHandle", 4, k32_GetStdHandle
    SHIM "GetFileAttributesA", 4, k32_GetFileAttributesA
    SHIM "FindFirstFileA", 8, k32_FindFirstFileA
    SHIM "FindNextFileA", 8, k32_FindNextFileA
    SHIM "FindClose", 4, k32_FindClose
    SHIM "GetCurrentDirectoryA", 8, k32_GetCurrentDirectoryA
    SHIM "SetCurrentDirectoryA", 4, k32_SetCurrentDirectoryA
    SHIM "GetFullPathNameA", 16, k32_GetFullPathNameA
    SHIM "GetDriveTypeA", 4, k32_GetDriveTypeA
    SHIM "GetPrivateProfileStringA", 24, k32_GetPrivateProfileStringA
    dq 0
section .text
