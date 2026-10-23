; w32_kernel32.asm — KERNEL32 shims: process, modules, heap, memory, time, misc.
; Files live in c/files.c + c/vfs.c (table: w32_files.asm), locale/strings in w32_locale.asm. See docs/win32-shims.md.

VIRT_EXE_PATH equ 0                 ; (documentation) the game sees itself as C:\GTA2\gta2.exe

section .text

; setup_kernel32: strings the game reads through pointers (must be in low memory)
setup_kernel32:
    sub rsp, 8
    lea rdi, [s_cmdline]
    call low_strdup
    mov [low_cmdline], eax
    lea rdi, [s_exe_path]
    call low_strdup
    mov [low_exe_path], eax
    mov edi, env_block_end - env_block      ; environment block (double-NUL terminated)
    mov esi, 4
    call low_alloc
    mov [low_env], eax
    mov edi, eax
    lea rsi, [env_block]
    mov edx, env_block_end - env_block
    call _memcpy
    mov edi, (env_block_end - env_block) * 2 ; same block as UTF-16
    mov esi, 4
    call low_alloc
    mov [low_envw], eax
    xor ecx, ecx
    lea rsi, [env_block]
.w:
    movzx edx, byte [rsi + rcx]
    mov [rax + rcx*2], dx
    inc ecx
    cmp ecx, env_block_end - env_block
    jb .w
    ; std handles 0/1/2 -> first three handle slots
    mov edi, HT_STD
    xor esi, esi
    xor edx, edx
    call handle_new
    mov [std_handles], eax
    mov edi, HT_STD
    mov esi, 1
    xor edx, edx
    call handle_new
    mov [std_handles + 4], eax
    mov edi, HT_STD
    mov esi, 2
    xor edx, edx
    call handle_new
    mov [std_handles + 8], eax
    add rsp, 8
    ret

; ---- process -------------------------------------------------------------
k32_GetVersion:                     ; Windows XP SP3: 5.1, build 2600, NT platform
    mov eax, 0x0A280105
    ret

k32_GetVersionExA:                  ; (OSVERSIONINFOA*) -> TRUE
    HENTER
    mov r12d, ARG(0)
    mov dword [r12 + 4], 5          ; dwMajorVersion
    mov dword [r12 + 8], 1          ; dwMinorVersion
    mov dword [r12 + 12], 2600      ; dwBuildNumber
    mov dword [r12 + 16], 2         ; VER_PLATFORM_WIN32_NT
    lea rdi, [r12 + 20]             ; szCSDVersion[128]
    lea rsi, [s_csd]
    call _strcpy
    cmp dword [r12], 156            ; OSVERSIONINFOEXA
    jb .done
    mov word [r12 + 148], 3         ; wServicePackMajor
    mov word [r12 + 150], 0
    mov word [r12 + 152], 0         ; wSuiteMask
    mov byte [r12 + 154], 1         ; wProductType = VER_NT_WORKSTATION
.done:
    mov eax, 1
    HRET

k32_GetStartupInfoA:                ; (STARTUPINFOA*): all zero, cb = 68
    HENTER
    mov r12d, ARG(0)
    mov edi, r12d
    xor esi, esi
    mov edx, 68
    call _memset
    mov dword [r12], 68
    HRET

k32_GetCommandLineA:
    mov eax, [low_cmdline]
    ret

k32_GetEnvironmentStrings:
    mov eax, [low_env]
    ret
k32_GetEnvironmentStringsW:
    mov eax, [low_envw]
    ret

k32_GetCurrentProcess:
    mov eax, -1                     ; pseudo handle
    ret
k32_GetCurrentProcessId:
    sub rsp, 8
    call _getpid
    add rsp, 8
    ret
k32_GetCurrentThreadId:
    sub rsp, 8
    call _getpid
    add rsp, 8
    add eax, 4
    ret

k32_GetLastError:
    mov eax, [last_error]
    ret

k32_SetUnhandledExceptionFilter:    ; returns the previous filter
    mov eax, [rdi]
    xchg eax, [unhandled_filter]
    ret

k32_UnhandledExceptionFilter:       ; reached only on a crash the game did not handle
    HENTER
    lea rdi, [msg_unhandled]
    call _puts
    mov eax, 1                      ; EXCEPTION_EXECUTE_HANDLER
    HRET

k32_ExitProcess:                    ; (code) noreturn
    HENTER
    lea rdi, [fmt_exit]
    mov esi, ARG(0)
    mov edx, [rbx - 4]
    xor eax, eax
    call _printf
    mov edi, ARG(0)
    call _exit

k32_TerminateProcess:               ; (hProcess, code)
    HENTER
    lea rdi, [fmt_exit]
    mov esi, ARG(1)
    mov edx, [rbx - 4]
    xor eax, eax
    call _printf
    mov edi, ARG(1)
    call _exit

k32_OutputDebugStringA:             ; (str): to our stdout
    HENTER
    lea rdi, [fmt_ods]
    mov esi, ARG(0)
    xor eax, eax
    call _printf
    HRET

k32_IsBadPtr:                       ; IsBadReadPtr/IsBadWritePtr/IsBadCodePtr: "good"
    xor eax, eax
    ret

k32_GetSystemInfo:                  ; (SYSTEM_INFO*), 36 bytes
    HENTER
    mov r12d, ARG(0)
    mov edi, r12d
    xor esi, esi
    mov edx, 36
    call _memset
    mov dword [r12 + 4], 0x1000     ; dwPageSize
    mov dword [r12 + 8], 0x10000    ; lpMinimumApplicationAddress
    mov dword [r12 + 12], 0x7FFEFFFF ; lpMaximumApplicationAddress
    mov dword [r12 + 16], 1         ; dwActiveProcessorMask
    mov dword [r12 + 20], 1         ; dwNumberOfProcessors (single-threaded host)
    mov dword [r12 + 24], 586       ; PROCESSOR_INTEL_PENTIUM
    mov dword [r12 + 28], 0x10000   ; dwAllocationGranularity
    mov word [r12 + 32], 6          ; wProcessorLevel
    HRET

; ---- modules -------------------------------------------------------------
k32_GetModuleHandleA:               ; (name) -> HMODULE; NULL = gta2.exe itself
    HENTER
    mov edi, ARG(0)
    test edi, edi
    jz .self
    lea rsi, [s_gta2exe]
    call _strcasecmp
    test eax, eax
    jz .self
    mov edi, ARG(0)
    call module_find
    test eax, eax
    jnz .out
    mov dword [last_error], ERROR_MOD_NOT_FOUND
    jmp .out
.self:
    mov eax, IMAGE_BASE
.out:
    HRET

k32_GetModuleFileNameA:             ; (hModule, buf, size) -> length
    HENTER
    mov r12d, ARG(1)
    mov r13d, ARG(2)
    mov edi, [low_exe_path]
    call _strlen
    mov r14d, eax
    cmp r14d, r13d
    jb .fits
    lea r14d, [r13 - 1]
.fits:
    mov edi, r12d
    mov esi, [low_exe_path]
    mov edx, r14d
    call _memcpy
    mov byte [r12 + r14], 0
    mov eax, r14d
    HRET

k32_LoadLibraryA:                   ; (name) -> HMODULE
    HENTER 16
    mov edi, ARG(0)
    call module_find
    test eax, eax
    jnz .log
    ; not a system DLL: a fake plugin module if the file is in the game directory
    mov edi, ARG(0)
    call vfs_resolve            ; overlay or pak
    cmp eax, VFS_NONE
    jle .missing
    mov edi, ARG(0)
    mov esi, '\'
    call _strrchr
    lea rdi, [rax + 1]
    test rax, rax
    jnz .dup
    mov edi, ARG(0)
.dup:
    call _strdup
    mov rdi, rax
    mov esi, 1
    call module_add
.log:
    mov r12d, eax
    lea rdi, [fmt_loadlib]
    mov esi, ARG(0)
    mov edx, r12d
    xor eax, eax
    call _printf
    mov eax, r12d
    HRET
.missing:
    lea rdi, [fmt_loadlib_no]
    mov esi, ARG(0)
    xor eax, eax
    call _printf
    mov dword [last_error], ERROR_MOD_NOT_FOUND
    xor eax, eax
    HRET

k32_FreeLibrary:
    mov eax, 1
    ret

k32_GetProcAddress:                 ; (hModule, name or ordinal) -> stub address
    HENTER
    mov edi, ARG(0)
    call module_name
    test rax, rax
    jz .bad_module
    mov r12, rax                    ; DLL name (host string, lives forever)
    mov r13d, ARG(1)
    cmp r13d, 0x10000
    jb .ordinal
    ; reuse a slot already handed out for this (DLL, name)
    xor r14d, r14d
.scan:
    cmp r14d, [n_imports]
    jae .new
    lea rax, [imp_dll]
    cmp [rax + r14*8], r12
    jne .skip
    lea rax, [imp_name]
    mov rdi, [rax + r14*8]
    test rdi, rdi
    jz .skip
    mov esi, r13d
    call _strcmp
    test eax, eax
    jz .reuse
.skip:
    inc r14d
    jmp .scan
.reuse:
    imul eax, r14d, STUB_SIZE
    add eax, STUBS
    HRET
.new:
    mov edi, r13d
    call _strdup
    mov rdi, r12
    mov rsi, rax
    xor edx, edx
    call new_slot
    mov r14d, eax
    ; log it, flagging names nothing implements yet
    mov eax, [n_imports]
    dec eax
    lea rcx, [imp_handler]
    lea rdx, [host_unimpl]
    lea r8, [s_shim]
    lea r9, [s_unimpl_tag]
    cmp [rcx + rax*8], rdx
    cmove r8, r9
    lea rdi, [fmt_getproc]
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    xor eax, eax
    call _printf
    mov eax, r14d
    HRET
.ordinal:
    mov rdi, r12
    xor esi, esi
    mov edx, r13d
    call new_slot
    HRET
.bad_module:
    lea rdi, [fmt_getproc_bad]
    mov esi, ARG(0)
    mov edx, ARG(1)
    xor eax, eax
    call _printf
    mov dword [last_error], ERROR_PROC_NOT_FOUND
    xor eax, eax
    HRET

; ---- heap ----------------------------------------------------------------
k32_GetProcessHeap:
k32_HeapCreate:                     ; (options, initial, max): every heap is the arena
    mov eax, HEAP_HANDLE
    ret
k32_HeapDestroy:
    mov eax, 1
    ret
k32_HeapAlloc:                      ; (heap, flags, size)
    sub rsp, 8
    mov esi, [rdi + 4]
    mov edi, [rdi + 8]
    call heap_alloc
    add rsp, 8
    ret
k32_HeapFree:                       ; (heap, flags, ptr)
    sub rsp, 8
    mov edi, [rdi + 8]
    call heap_free
    add rsp, 8
    ret
k32_HeapReAlloc:                    ; (heap, flags, ptr, size)
    sub rsp, 8
    mov edx, [rdi + 4]
    mov esi, [rdi + 12]
    mov edi, [rdi + 8]
    call heap_realloc
    add rsp, 8
    ret
k32_HeapSize:                       ; (heap, flags, ptr)
    mov eax, [rdi + 8]
    cmp dword [rax - 16 + 8], HEAP_MAGIC
    jne .bad
    mov eax, [rax - 16]
    ret
.bad:
    mov eax, -1
    ret

; ---- virtual memory --------------------------------------------------------
MEM_COMMIT  equ 0x1000
MEM_RESERVE equ 0x2000

k32_VirtualAlloc:                   ; (addr, size, type, protect)
    HENTER
    mov eax, ARG(0)
    test eax, eax
    jnz .at
    mov edi, ARG(1)
    add edi, 0xFFF
    and edi, ~0xFFF
    mov esi, 0x10000
    call low_alloc
    jmp .out
.at:                                ; commit inside an earlier reservation: the arena
    cmp eax, ARENA_BASE             ; is already read-write
    jb .fail
    cmp eax, [arena_brk]
    jae .fail
    and eax, ~0xFFF
    jmp .out
.fail:
    lea rdi, [fmt_valloc_fail]
    mov esi, ARG(0)
    mov edx, ARG(1)
    mov ecx, ARG(2)
    xor eax, eax
    call _printf
    xor eax, eax
.out:
    HRET

k32_VirtualFree:                    ; memory stays in the arena (never returned)
    mov eax, 1
    ret

k32_VirtualProtect:                 ; (addr, size, new, old*): no-op, old = PAGE_READWRITE
    mov eax, [rdi + 12]
    test eax, eax
    jz .r
    mov dword [rax], 4
.r:
    mov eax, 1
    ret

k32_VirtualQuery:                   ; (addr, MEMORY_BASIC_INFORMATION*, len) -> 28
    HENTER
    mov r12d, ARG(1)
    mov eax, ARG(0)
    and eax, ~0xFFF
    mov [r12], eax                  ; BaseAddress
    mov [r12 + 4], eax              ; AllocationBase
    mov dword [r12 + 8], 4          ; AllocationProtect = PAGE_READWRITE
    mov dword [r12 + 12], 0x1000    ; RegionSize
    mov dword [r12 + 16], MEM_COMMIT
    mov dword [r12 + 20], 4         ; Protect
    mov dword [r12 + 24], 0x20000   ; MEM_PRIVATE
    mov eax, 28
    HRET

k32_LocalFree:                      ; (hMem) -> NULL on success
    sub rsp, 8
    mov edi, [rdi]
    call heap_free
    add rsp, 8
    xor eax, eax
    ret

; ---- time ----------------------------------------------------------------
CLOCK_MONOTONIC_RAW equ 4
CLOCK_REALTIME      equ 0

; rax = monotonic nanoseconds
now_ns:
    sub rsp, 8
    mov edi, CLOCK_MONOTONIC_RAW
    call _clock_gettime_nsec_np
    add rsp, 8
    ret

k32_GetTickCount:                   ; ms, monotonic (also WINMM!timeGetTime)
    sub rsp, 8
    call now_ns
    xor edx, edx
    mov ecx, 1000000
    div rcx
    add rsp, 8
    ret

k32_QueryPerformanceCounter:        ; (LARGE_INTEGER*): ns ticks, see QueryPerformanceFrequency
    push rbx
    mov ebx, [rdi]
    call now_ns
    mov [rbx], rax
    mov eax, 1
    pop rbx
    ret

k32_QueryPerformanceFrequency:      ; (LARGE_INTEGER*) = 1e9
    mov eax, [rdi]
    mov qword [rax], 1000000000
    mov eax, 1
    ret

k32_GetSystemTimeAsFileTime:        ; (FILETIME*): 100 ns since 1601-01-01 UTC
    push rbx
    mov ebx, [rdi]
    mov edi, CLOCK_REALTIME
    call _clock_gettime_nsec_np
    xor edx, edx
    mov ecx, 100
    div rcx
    mov rcx, 116444736000000000
    add rax, rcx
    mov [rbx], rax
    pop rbx
    ret

k32_FileTimeToLocalFileTime:        ; (in, out): local time = UTC
    mov eax, [rdi]
    mov rax, [rax]
    mov ecx, [rdi + 4]
    mov [rcx], rax
    mov eax, 1
    ret

k32_FileTimeToSystemTime:           ; (FILETIME*, SYSTEMTIME*) via gmtime_r
    HENTER 64                       ; struct tm at [rsp]
    mov eax, ARG(0)
    mov rax, [rax]
    mov rcx, 116444736000000000
    sub rax, rcx
    xor edx, edx
    mov ecx, 10000000
    div rcx                         ; rax = unix seconds, rdx = 100 ns remainder
    mov r13, rdx
    mov [rsp + 56], rax
    lea rdi, [rsp + 56]
    mov rsi, rsp
    call _gmtime_r
    mov r12d, ARG(1)
    mov eax, [rsp + 20]             ; tm_year
    add eax, 1900
    mov [r12], ax                   ; wYear
    mov eax, [rsp + 16]             ; tm_mon
    inc eax
    mov [r12 + 2], ax               ; wMonth
    mov eax, [rsp + 24]             ; tm_wday
    mov [r12 + 4], ax
    mov eax, [rsp + 12]             ; tm_mday
    mov [r12 + 6], ax
    mov eax, [rsp + 8]
    mov [r12 + 8], ax               ; wHour
    mov eax, [rsp + 4]
    mov [r12 + 10], ax              ; wMinute
    mov eax, [rsp]
    mov [r12 + 12], ax              ; wSecond
    mov rax, r13
    xor edx, edx
    mov ecx, 10000
    div rcx
    mov [r12 + 14], ax              ; wMilliseconds
    mov eax, 1
    HRET

k32_GetTimeZoneInformation:         ; (TIME_ZONE_INFORMATION*): UTC, 172 bytes
    HENTER
    mov edi, ARG(0)
    xor esi, esi
    mov edx, 172
    call _memset
    xor eax, eax                    ; TIME_ZONE_ID_UNKNOWN
    HRET

k32_Sleep:                          ; (ms)
    sub rsp, 8
    mov eax, [rdi]
    imul edi, eax, 1000
    call _usleep
    add rsp, 8
    ret

; ---- sync objects (single-threaded: they only need to exist) ----------------
k32_CreateEventA:                   ; (attrs, manual, initial, name)
    sub rsp, 8
    mov edi, HT_EVENT
    xor esi, esi
    xor edx, edx
    call handle_new
    add rsp, 8
    ret
k32_CreateMutexA:                   ; (attrs, owner, name)
    sub rsp, 8
    mov dword [last_error], 0       ; not ERROR_ALREADY_EXISTS: we are the only instance
    mov edi, HT_MUTEX
    xor esi, esi
    xor edx, edx
    call handle_new
    add rsp, 8
    ret
k32_OpenMutexA:                     ; (access, inherit, name): no other instance runs
    mov dword [last_error], ERROR_FILE_NOT_FOUND
    xor eax, eax
    ret

k32_CloseHandle:                    ; (h)
    HENTER
    mov edi, ARG(0)
    call handle_get
    test rax, rax
    jz .bad
    mov r12, rax
    cmp dword [r12], HT_FILE
    jne .free
    mov edi, [r12 + 4]
    call _close
.free:
    mov dword [r12], HT_FREE
    mov eax, 1
    HRET
.bad:
    mov dword [last_error], ERROR_INVALID_HANDLE
    xor eax, eax
    HRET

k32_lstrlenA:
    sub rsp, 8
    mov edi, [rdi]
    xor eax, eax
    test edi, edi
    jz .r
    call _strlen
.r:
    add rsp, 8
    ret

k32_IsProcessorFeaturePresent:      ; (feature): MMX 3, SSE 6, SSE2 10, RDTSC 8, CX8 2
    mov eax, [rdi]
    cmp eax, 31
    ja .no
    mov ecx, (1 << 2) | (1 << 3) | (1 << 6) | (1 << 8) | (1 << 10)
    bt ecx, eax
    setc al
    movzx eax, al
    ret
.no:
    xor eax, eax
    ret

k32_FormatMessageA:                 ; produce no text: callers fall back to the code
    xor eax, eax
    ret

section .data
align 8
shimtab_kernel32:
    dq s_kernel32
    SHIM "GetVersion", 0, k32_GetVersion
    SHIM "GetVersionExA", 4, k32_GetVersionExA
    SHIM "GetStartupInfoA", 4, k32_GetStartupInfoA
    SHIM "GetCommandLineA", 0, k32_GetCommandLineA
    SHIM "GetEnvironmentStrings", 0, k32_GetEnvironmentStrings
    SHIM "GetEnvironmentStringsA", 0, k32_GetEnvironmentStrings
    SHIM "GetEnvironmentStringsW", 0, k32_GetEnvironmentStringsW
    SHIM "FreeEnvironmentStringsA", 4, h_ret1
    SHIM "FreeEnvironmentStringsW", 4, h_ret1
    SHIM "GetCurrentProcess", 0, k32_GetCurrentProcess
    SHIM "GetCurrentProcessId", 0, k32_GetCurrentProcessId
    SHIM "GetCurrentThreadId", 0, k32_GetCurrentThreadId
    SHIM "GetLastError", 0, k32_GetLastError
    SHIM "SetUnhandledExceptionFilter", 4, k32_SetUnhandledExceptionFilter
    SHIM "UnhandledExceptionFilter", 4, k32_UnhandledExceptionFilter
    SHIM "ExitProcess", 4, k32_ExitProcess
    SHIM "TerminateProcess", 8, k32_TerminateProcess
    SHIM "OutputDebugStringA", 4, k32_OutputDebugStringA
    SHIM "IsBadReadPtr", 8, k32_IsBadPtr
    SHIM "IsBadWritePtr", 8, k32_IsBadPtr
    SHIM "IsBadCodePtr", 4, k32_IsBadPtr
    SHIM "GetSystemInfo", 4, k32_GetSystemInfo
    SHIM "GetModuleHandleA", 4, k32_GetModuleHandleA
    SHIM "GetModuleFileNameA", 12, k32_GetModuleFileNameA
    SHIM "LoadLibraryA", 4, k32_LoadLibraryA
    SHIM "FreeLibrary", 4, k32_FreeLibrary
    SHIM "GetProcAddress", 8, k32_GetProcAddress
    SHIM "GetProcessHeap", 0, k32_GetProcessHeap
    SHIM "HeapCreate", 12, k32_HeapCreate
    SHIM "HeapDestroy", 4, k32_HeapDestroy
    SHIM "HeapAlloc", 12, k32_HeapAlloc
    SHIM "HeapFree", 12, k32_HeapFree
    SHIM "HeapReAlloc", 16, k32_HeapReAlloc
    SHIM "HeapSize", 12, k32_HeapSize
    SHIM "VirtualAlloc", 16, k32_VirtualAlloc
    SHIM "VirtualFree", 12, k32_VirtualFree
    SHIM "VirtualProtect", 16, k32_VirtualProtect
    SHIM "VirtualQuery", 12, k32_VirtualQuery
    SHIM "LocalFree", 4, k32_LocalFree
    SHIM "GetTickCount", 0, k32_GetTickCount
    SHIM "QueryPerformanceCounter", 4, k32_QueryPerformanceCounter
    SHIM "QueryPerformanceFrequency", 4, k32_QueryPerformanceFrequency
    SHIM "GetSystemTimeAsFileTime", 4, k32_GetSystemTimeAsFileTime
    SHIM "FileTimeToLocalFileTime", 8, k32_FileTimeToLocalFileTime
    SHIM "FileTimeToSystemTime", 8, k32_FileTimeToSystemTime
    SHIM "GetTimeZoneInformation", 4, k32_GetTimeZoneInformation
    SHIM "Sleep", 4, k32_Sleep
    SHIM "CreateEventA", 16, k32_CreateEventA
    SHIM "CreateMutexA", 12, k32_CreateMutexA
    SHIM "OpenMutexA", 12, k32_OpenMutexA
    SHIM "ReleaseMutex", 4, h_ret1
    SHIM "CloseHandle", 4, k32_CloseHandle
    SHIM "lstrlenA", 4, k32_lstrlenA
    SHIM "FormatMessageA", 28, k32_FormatMessageA
    SHIM "IsProcessorFeaturePresent", 4, k32_IsProcessorFeaturePresent
    SHIM "SetHandleCount", 4, h_ret_arg0
    SHIM "SetConsoleCtrlHandler", 8, h_ret1
    SHIM "SetEnvironmentVariableA", 8, h_ret1
    SHIM "SetStdHandle", 8, h_ret1
    dq 0

section .rodata
s_kernel32:  db "KERNEL32", 0
s_gta2exe:   db "gta2.exe", 0
s_cmdline:   db '"C:\GTA2\gta2.exe"', 0
s_exe_path:  db "C:\GTA2\gta2.exe", 0
s_csd:       db "Service Pack 3", 0
s_shim:      db "shim", 0
s_unimpl_tag: db "UNIMPLEMENTED", 0
env_block:   db "PATH=C:\WINDOWS\system32;C:\WINDOWS", 0
             db "SystemRoot=C:\WINDOWS", 0
             db "TEMP=C:\GTA2\temp", 0
             db "windir=C:\WINDOWS", 0, 0
env_block_end:
fmt_exit:    db "  [w32] ExitProcess(%d) from 0x%x", 10, 0
fmt_ods:     db "  [ods] %s", 0
fmt_loadlib: db "  [w32] LoadLibraryA(%s) -> 0x%x", 10, 0
fmt_loadlib_no: db "  [w32] LoadLibraryA(%s) -> NULL (not found)", 10, 0
fmt_getproc: db "  [w32] GetProcAddress(%s, %s) -> 0x%x (%s)", 10, 0
fmt_getproc_bad: db "  [w32] GetProcAddress(0x%x, 0x%x): unknown module -> NULL", 10, 0
fmt_valloc_fail: db "  [w32] VirtualAlloc(0x%x, 0x%x, 0x%x): address outside the arena -> NULL", 10, 0
msg_unhandled: db "  [w32] UnhandledExceptionFilter called (unhandled SEH exception)", 0

section .bss
alignb 4
low_cmdline:  resd 1
low_exe_path: resd 1
low_env:      resd 1
low_envw:     resd 1
std_handles:  resd 3
unhandled_filter: resd 1
section .text
