; w32_core.asm — Win32 shim infrastructure, %include'd by loader.asm (one NASM unit).
;
; Every import slot (static IAT entries and GetProcAddress results) is a 32-bit stub
; that ends in host_dispatch, which calls imp_handler[slot](rdi = args, esi = slot) on
; the host stack and pops imp_pop[slot] argument bytes for the caller (stdcall).
;
; Handlers are ordinary SysV functions. `rdi` points at the first 32-bit argument on
; the game's stack (the caller's return address is at [rdi-4]). They return eax
; (edx:eax for 64-bit results). Anything handed to the game must live below 4 GB:
; use low_alloc/heap_alloc/low_strdup, never host .data/.bss or malloc.
;
; Shim tables: one per DLL, listed in shim_tables. bind_slot looks a slot's
; (DLL, name) up there; unknown names keep host_unimpl ("unimplemented import ...",
; exit 3), except decorated mss32/binkw32 names (`_Foo@N`), which get h_silent:
; return 0, pop N bytes, log the first call.

extern _strcasecmp, _strncasecmp, _strlen, _strcpy, _strrchr, _atoi, _strtol, _strdup
extern _memcmp, _putchar
extern _usleep, _getpid, _clock_gettime_nsec_np, _write, _read, _fflush
; x86_64 macOS: the 64-bit-inode struct stat / struct dirent layouts we use need the
; $INODE64 symbol variants (the plain names are the legacy 32-bit-inode ABI).
extern _stat$INODE64, _opendir$INODE64, _readdir$INODE64
%define _stat _stat$INODE64
%define _opendir _opendir$INODE64
%define _readdir _readdir$INODE64
extern _closedir, _chdir, _getcwd, _time, _gmtime_r
extern _strncmp, _snprintf, _strncpy, _strchr, _fopen, _fgets, _fclose, _strtoul

; ---- handler frame -------------------------------------------------------
; HENTER [locals]: saves rbp/rbx/r12-r14 (keeps rsp 16-aligned), rbx = args.
; Locals (a multiple of 16 bytes) start at [rsp]. HRET restores and returns.
%macro HENTER 0-1 0
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
  %if %1
    sub rsp, %1
  %endif
    mov rbx, rdi
%endmacro
%macro HRET 0
    lea rsp, [rbp - 32]
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
%endmacro
%define ARG(n) dword [rbx + 4*(n)]

; SHIM "Name", stdcall argument bytes, handler — one table entry (24 bytes)
%macro SHIM 3
    dq %%n, %3
    dd %2, 0
section .rodata
%%n: db %1, 0
section .data
%endmacro
SHIM_SIZE   equ 24
SH_NAME     equ 0
SH_HANDLER  equ 8
SH_POP      equ 16

; ---- low memory arena (heap, VirtualAlloc, strings handed to the game) ----
ARENA_BASE  equ 0x20000000
ARENA_SIZE  equ 0x40000000          ; 1 GB, lazily backed by the kernel
HEAP_HANDLE equ 0x00DE0000          ; token returned by HeapCreate/GetProcessHeap
HEAP_MAGIC  equ 0x50414548          ; 'HEAP'
FREE_MAGIC  equ 0x45455246          ; 'FREE'
HEAP_ZERO_MEMORY equ 0x08
HEAP_REALLOC_IN_PLACE_ONLY equ 0x10

ERROR_FILE_NOT_FOUND equ 2
ERROR_PATH_NOT_FOUND equ 3
ERROR_INVALID_HANDLE equ 6
ERROR_NO_MORE_FILES  equ 18
ERROR_MOD_NOT_FOUND  equ 126
ERROR_PROC_NOT_FOUND equ 127
ERROR_ALREADY_EXISTS equ 183
ERROR_MORE_DATA      equ 234

section .text

; bind_slot(edi = slot index): choose imp_handler/imp_pop for a fresh slot.
bind_slot:
    push rbx
    push r12
    push r13
    mov ebx, edi
    lea rax, [imp_handler]
    lea rcx, [host_unimpl]
    mov [rax + rbx*8], rcx
    lea rax, [imp_pop]
    mov dword [rax + rbx*4], 0
    lea rax, [imp_name]
    mov r13, [rax + rbx*8]
    test r13, r13
    jz .done
    lea rax, [imp_dll]
    mov r12, [rax + rbx*8]
    mov rdi, r12
    mov rsi, r13
    call find_shim
    test rax, rax
    jz .decorated
    mov rcx, [rax + SH_HANDLER]
    mov edx, [rax + SH_POP]
    jmp .set
.decorated:                     ; mss32/binkw32 `_Name@N`: silent zero, pop N
    lea rdi, [s_mss32]
    mov rsi, r12
    call dll_eq
    test eax, eax
    jnz .is_audio
    lea rdi, [s_binkw32]
    mov rsi, r12
    call dll_eq
    test eax, eax
    jz .done
.is_audio:
    mov rdi, r13
    mov esi, '@'
    call _strrchr
    test rax, rax
    jz .done
    lea rdi, [rax + 1]
    call _atoi
    mov edx, eax
    lea rcx, [h_silent]
.set:
    lea rax, [imp_handler]
    mov [rax + rbx*8], rcx
    lea rax, [imp_pop]
    mov [rax + rbx*4], edx
.done:
    pop r13
    pop r12
    pop rbx
    ret

; rax = find_shim(rdi = DLL name as imported, rsi = function name) -> entry or 0
find_shim:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    lea r14, [shim_tables]
.table:
    mov rbx, [r14]
    test rbx, rbx
    jz .none
    add r14, 8
    mov rdi, [rbx]              ; table DLL name (no extension)
    mov rsi, r12
    call dll_eq
    test eax, eax
    jz .table
    add rbx, 8
.entry:
    mov rdi, [rbx + SH_NAME]
    test rdi, rdi
    jz .table
    mov rsi, r13
    call _strcmp
    test eax, eax
    jz .found
    add rbx, SHIM_SIZE
    jmp .entry
.found:
    mov rax, rbx
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

; eax = dll_eq(rdi = name without extension, rsi = DLL name as given): case-insensitive,
; the given name may carry ".dll" (any case).
dll_eq:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    call _strlen
    mov rbx, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, rbx
    call _strncasecmp
    test eax, eax
    jnz .no
    cmp byte [r13 + rbx], 0
    je .yes
    lea rdi, [r13 + rbx]
    lea rsi, [s_dotdll]
    call _strcasecmp
    test eax, eax
    jnz .no
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; trace_call(rdi = 32-bit frame [index, ret, args...], rsi = result): one log line.
trace_call:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r15, rsi
    mov r12d, [rbx + 8]         ; slot
    lea rax, [imp_dll]
    mov rsi, [rax + r12*8]
    lea rax, [imp_name]
    mov rdx, [rax + r12*8]
    test rdx, rdx
    jnz .named
    lea rdx, [s_ordinal]
.named:
    lea rdi, [fmt_tr_head]
    xor eax, eax
    call _printf
    lea rax, [imp_pop]
    mov r13d, [rax + r12*4]
    shr r13d, 2
    cmp r13d, 6
    jbe .n_ok
    mov r13d, 6
.n_ok:
    xor r14d, r14d
.arg:
    cmp r14d, r13d
    jae .tail
    lea rdi, [fmt_tr_arg]
    lea rsi, [s_comma]
    lea rax, [s_empty_str]
    test r14d, r14d
    cmovz rsi, rax
    mov edx, [rbx + 16 + r14*4]
    xor eax, eax
    call _printf
    inc r14d
    jmp .arg
.tail:
    lea rdi, [fmt_tr_tail]
    mov esi, r15d
    mov edx, [rbx + 12]
    xor eax, eax
    call _printf
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_silent: default for decorated audio/video imports. Returns 0, logs the first call.
h_silent:
    HENTER
    mov r12d, esi
    lea rax, [imp_flags]
    cmp byte [rax + r12], 0
    jne .quiet
    mov byte [rax + r12], 1
    lea rax, [imp_dll]
    mov rsi, [rax + r12*8]
    lea rax, [imp_name]
    mov rdx, [rax + r12*8]
    mov ecx, [rbx - 4]
    lea rdi, [fmt_silent]
    xor eax, eax
    call _printf
.quiet:
    xor eax, eax
    HRET

; h_ret0 / h_ret1: shims whose whole job is to report failure / success.
h_ret0:
    xor eax, eax
    ret
h_ret1:
    mov eax, 1
    ret
; h_ret_arg0: returns its first argument (SetHandleCount and friends)
h_ret_arg0:
    mov eax, [rdi]
    ret

; ---- low arena -----------------------------------------------------------
setup_arena:
    sub rsp, 8
    mov edi, ARENA_BASE
    mov esi, ARENA_SIZE
    mov edx, PROT_R | PROT_W
    mov ecx, MAP_ANONPRIV               ; hint + verify, like the image
    mov r8d, -1
    xor r9d, r9d
    call _mmap
    cmp rax, ARENA_BASE
    jne .bad
    mov dword [arena_brk], ARENA_BASE
    mov dword [arena_end], ARENA_BASE + ARENA_SIZE
    add rsp, 8
    ret
.bad:
    lea rdi, [msg_arena]
    call fail

; rax = low_alloc(edi = size, esi = alignment, power of two): zeroed (fresh mmap) memory
; below 4 GB. Never freed; heap_free recycles heap blocks on top of it.
low_alloc:
    mov eax, [arena_brk]
    lea ecx, [esi - 1]
    add eax, ecx
    not ecx
    and eax, ecx
    mov edx, eax
    add rdx, rdi
    cmp edx, [arena_end]        ; rdx may exceed 32 bits only past the arena end
    ja .full
    mov [arena_brk], edx
    ret
.full:
    lea rdi, [msg_arena_full]
    call fail

; rax = low_strdup(rdi = host string): copy into the arena
low_strdup:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    call _strlen
    lea edi, [rax + 1]
    mov esi, 4
    call low_alloc
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call _strcpy
    mov rax, rbx
    add rsp, 8
    pop r12
    pop rbx
    ret

; rax = heap_alloc(edi = size, esi = flags). Power-of-two size classes with a 16-byte
; header {u32 size, u32 class, u32 magic, u32 next-free}; freed blocks go on per-class
; free lists. Wasteful (up to 2x) but simple and never moves.
heap_alloc:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r13d, esi
    lea eax, [rbx + 16]
    mov ecx, 5                  ; smallest block: 32 bytes
.cls:
    mov edx, 1
    shl edx, cl
    cmp edx, eax
    jae .have_cls
    inc ecx
    cmp ecx, 30
    jbe .cls
    xor eax, eax                ; > 1 GB: refuse
    jmp .out
.have_cls:
    mov r12d, ecx
    lea rdx, [heap_free_lists]
    mov eax, [rdx + r12*4]
    test eax, eax
    jz .fresh
    mov ecx, [rax + 12]         ; pop the free list
    mov [rdx + r12*4], ecx
    test r13d, HEAP_ZERO_MEMORY
    jz .header
    push rax
    sub rsp, 8
    lea rdi, [rax + 16]
    xor esi, esi
    mov edx, ebx
    call _memset
    add rsp, 8
    pop rax
    jmp .header
.fresh:
    mov edi, 1
    mov ecx, r12d
    shl edi, cl
    mov esi, 16
    call low_alloc
.header:
    mov [rax], ebx
    mov [rax + 4], r12d
    mov dword [rax + 8], HEAP_MAGIC
    mov dword [rax + 12], 0
    add eax, 16
.out:
    pop r13
    pop r12
    pop rbx
    ret

; eax = heap_free(edi = pointer): 1 ok, 0 not ours / double free (logged)
heap_free:
    test edi, edi
    jz .ok
    lea eax, [rdi - 16]
    cmp dword [rax + 8], HEAP_MAGIC
    jne .bad
    mov dword [rax + 8], FREE_MAGIC
    mov ecx, [rax + 4]
    lea rdx, [heap_free_lists]
    mov esi, [rdx + rcx*4]
    mov [rax + 12], esi
    mov [rdx + rcx*4], eax
.ok:
    mov eax, 1
    ret
.bad:
    sub rsp, 8
    mov esi, edi
    lea rdi, [fmt_bad_free]
    xor eax, eax
    call _printf
    add rsp, 8
    xor eax, eax
    ret

; rax = heap_realloc(edi = pointer, esi = new size, edx = flags)
heap_realloc:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    test ebx, ebx
    jnz .have
    mov edi, r12d
    mov esi, r13d
    call heap_alloc
    jmp .out
.have:
    lea eax, [rbx - 16]
    cmp dword [rax + 8], HEAP_MAGIC
    jne .fail
    mov r14d, [rax]             ; old size
    mov ecx, [rax + 4]
    mov edx, 1
    shl edx, cl
    sub edx, 16
    cmp r12d, edx
    ja .move
    mov [rax], r12d             ; fits in place
    cmp r12d, r14d
    jbe .same
    test r13d, HEAP_ZERO_MEMORY
    jz .same
    lea edi, [rbx + r14]
    xor esi, esi
    mov edx, r12d
    sub edx, r14d
    call _memset
.same:
    mov eax, ebx
    jmp .out
.move:
    test r13d, HEAP_REALLOC_IN_PLACE_ONLY
    jnz .fail
    mov edi, r12d
    mov esi, r13d
    call heap_alloc
    test eax, eax
    jz .out
    mov r12d, eax
    mov edi, eax
    mov esi, ebx
    mov edx, r14d
    call _memcpy
    mov edi, ebx
    call heap_free
    mov eax, r12d
    jmp .out
.fail:
    xor eax, eax
.out:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- handle table --------------------------------------------------------
; HANDLE = HANDLE_BASE + 4*i. Entry: {u32 type, u32 fd, u64 extra}.
HANDLE_BASE equ 0x1000
MAX_HANDLES equ 512
HT_FREE     equ 0
HT_STD      equ 1
HT_FILE     equ 2
HT_FIND     equ 3
HT_EVENT    equ 4
HT_MUTEX    equ 5
HT_PROCESS  equ 6
HT_PAK      equ 7                 ; data.pak file: fd = pak index, extra = position

; eax = handle_new(edi = type, esi = fd, rdx = extra), 0 if the table is full
handle_new:
    lea r8, [handles]
    xor ecx, ecx
.scan:
    cmp ecx, MAX_HANDLES
    jae .full
    mov eax, ecx
    shl eax, 4
    cmp dword [r8 + rax], HT_FREE
    je .take
    inc ecx
    jmp .scan
.take:
    mov [r8 + rax], edi
    mov [r8 + rax + 4], esi
    mov [r8 + rax + 8], rdx
    lea eax, [HANDLE_BASE + rcx*4]
    ret
.full:
    xor eax, eax
    ret

; rax = handle_get(edi = HANDLE) -> entry pointer, or 0 if not a live handle
handle_get:
    mov eax, edi
    sub eax, HANDLE_BASE
    jb .no
    test eax, 3
    jnz .no
    shr eax, 2
    cmp eax, MAX_HANDLES
    jae .no
    shl eax, 4
    lea rcx, [handles]
    add rax, rcx
    cmp dword [rax], HT_FREE
    je .no
    ret
.no:
    xor eax, eax
    ret

; ---- modules -------------------------------------------------------------
; Fake HMODULEs: system DLLs (every shim table) get MOD_BASE + k*0x10000; plugin DLLs
; that exist in the game directory are added by LoadLibraryA. Nothing is mapped there.
MOD_BASE    equ 0x7F000000
MAX_MODULES equ 64

; seed the module table from shim_tables
setup_modules:
    push rbx
    lea rbx, [shim_tables]
.next:
    mov rax, [rbx]
    test rax, rax
    jz .done
    mov rdi, [rax]
    call module_find            ; several tables may share one DLL
    test eax, eax
    jnz .skip
    mov rax, [rbx]
    mov rdi, [rax]
    xor esi, esi
    call module_add
.skip:
    add rbx, 8
    jmp .next
.done:
    pop rbx
    ret

; eax = module_add(rdi = host name string (kept), esi = kind 0 system / 1 plugin) -> HMODULE
module_add:
    mov ecx, [n_modules]
    cmp ecx, MAX_MODULES
    jae .full
    lea rax, [mod_name]
    mov [rax + rcx*8], rdi
    lea rax, [mod_kind]
    mov [rax + rcx*4], esi
    inc dword [n_modules]
    mov eax, ecx
    shl eax, 16
    add eax, MOD_BASE
    ret
.full:
    lea rdi, [msg_modules]
    call fail

; eax = module_find(rdi = DLL name as given, path allowed) -> HMODULE or 0
module_find:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov esi, '\'
    call _strrchr               ; strip any directory part
    test rax, rax
    jz .base
    lea r12, [rax + 1]
.base:
    xor ebx, ebx
.scan:
    cmp ebx, [n_modules]
    jae .none
    lea rax, [mod_name]
    mov rdi, [rax + rbx*8]
    mov rsi, r12
    call dll_eq
    test eax, eax
    jnz .found
    lea rax, [mod_name]
    mov rdi, [rax + rbx*8]
    mov rsi, r12
    call _strcasecmp
    test eax, eax
    jz .found
    inc ebx
    jmp .scan
.found:
    mov eax, ebx
    shl eax, 16
    add eax, MOD_BASE
    jmp .out
.none:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; rax = module_name(edi = HMODULE) -> host name string or 0
module_name:
    mov eax, edi
    sub eax, MOD_BASE
    jb .no
    test eax, 0xFFFF
    jnz .no
    shr eax, 16
    cmp eax, [n_modules]
    jae .no
    lea rcx, [mod_name]
    mov rax, [rcx + rax*8]
    ret
.no:
    xor eax, eax
    ret

section .rodata
s_mss32:     db "mss32", 0
s_binkw32:   db "binkw32", 0
s_dotdll:    db ".dll", 0
s_ordinal:   db "#ordinal", 0
s_comma:     db ", ", 0
s_empty_str: db 0
fmt_tr_head: db "  [w32] %s!%s(", 0
fmt_tr_arg:  db "%s0x%x", 0
fmt_tr_tail: db ") = 0x%x   <- 0x%x", 10, 0
fmt_silent:  db "  [w32] silent stub %s!%s -> 0 (first call from 0x%x)", 10, 0
fmt_bad_free: db "  [w32] heap: free/realloc of a pointer we did not allocate: 0x%x", 10, 0
msg_arena:   db "mmap of the low arena did not get exactly ARENA_BASE", 0
msg_arena_full: db "low arena exhausted", 0
msg_modules: db "module table full", 0

section .bss
alignb 8
imp_handler:  resq MAX_IMPORTS
imp_pop:      resd MAX_IMPORTS
imp_flags:    resb MAX_IMPORTS
arena_brk:    resd 1
arena_end:    resd 1
heap_free_lists: resd 32
last_error:   resd 1
handles:      resb 16 * MAX_HANDLES
n_modules:    resd 1
mod_kind:     resd MAX_MODULES
mod_name:     resq MAX_MODULES
section .text
