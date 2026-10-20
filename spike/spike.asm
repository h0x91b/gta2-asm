; Rosetta 2 + i386_set_ldt spike.
; x86-64 Mach-O host (runs under Rosetta on Apple Silicon) that:
;   1. maps RWX memory at 0x3F0000 (gta2.exe ImageBase, below 4 GB),
;   2. installs 32-bit code + data (TEB for FS) descriptors with i386_set_ldt,
;   3. far-transfers into 32-bit routines and back,
;   4. lets 32-bit code call back into a 64-bit host function,
;   5. measures transition cost and 32-bit vs 64-bit loop speed,
;   6. takes a SIGSEGV inside 32-bit code and recovers,
;   7. optionally (argv[1] = gta2.exe) maps the PE sections at their VAs
;      and reads the entry point from 32-bit code.

default rel

extern _printf, _mmap, _i386_set_ldt, ___error, _sigaction, _setvbuf
extern _clock_gettime_nsec_np, _exit, ___stdoutp, _open, _pread, _close

; ---- fixed low-memory layout -------------------------------------------
LOW_BASE    equ 0x3F0000            ; one RWX reservation for everything below
LOW_SIZE    equ 0x510000            ; .. 0x900000
IMAGE_BASE  equ 0x3F0000            ; gta2.exe ImageBase (no relocs: must be exact)
CODE32      equ 0x700000            ; blob32 copied here
THUNK64     equ 0x701000            ; blob64 copied here
SAVED_RSP   equ 0x702000            ; host rsp at call32 entry
CONT        equ 0x702008            ; host continuation address
HOSTFN      equ 0x702010            ; 64-bit host callback target
FAR_RET     equ 0x702018            ; m16:32 -> THUNK64:ret64 (64-bit CS)
FAR_CB      equ 0x702020            ; m16:32 -> THUNK64:cb64  (64-bit CS)
TEB         equ 0x703000            ; fake Win32 TEB, base of the FS descriptor
STACK32_TOP equ 0x8F0000

%define A32(l) (CODE32 + (l) - blob32)
%define A64(l) (THUNK64 + (l) - blob64)

PROT_RWX    equ 7
MAP_ANONPRIV equ 0x1002             ; MAP_ANON | MAP_PRIVATE
SIGSEGV     equ 11
SIGBUS      equ 10
SA_SIGINFO  equ 0x40
CLOCK_UPTIME_RAW equ 8
%ifndef LDT_INDEX
%define LDT_INDEX 16                ; Rosetta aborts on LDT_AUTO_ALLOC, so pick one
%endif

section .text

; ========================================================================
; 32-bit blob (copied to CODE32). Position-dependent on CODE32/THUNK64.
; ========================================================================
bits 32
blob32:
tramp32:                ; entered via retfq from host; ecx = target, cdecl args on stack
    call ecx
    jmp far [FAR_RET]   ; back to 64-bit ret64 thunk, result in eax

mode32:                 ; 40 40 = "inc eax; inc eax" in 32-bit, REX REX in 64-bit
    xor eax, eax
    db 0x40, 0x40
    ret

getcs32:
    xor eax, eax
    mov ax, cs
    ret

add32:                  ; int add32(int a, int b), uses a frame + stack
    push ebp
    mov ebp, esp
    push ebx
    mov ebx, [ebp+8]
    mov eax, [ebp+12]
    add eax, ebx
    pop ebx
    pop ebp
    ret

cb32:                   ; int cb32(int x, int y) { return host_cb(x, y) + 1; }
    push ebp
    mov ebp, esp
    push dword [ebp+12]
    push dword [ebp+8]
    call far [FAR_CB]   ; 32-bit far call into 64-bit thunk
    add esp, 8
    inc eax
    pop ebp
    ret

loop32:                 ; uint32 loop32(n): sum n..1 with some ALU work
    mov ecx, [esp+4]
    xor eax, eax
    xor edx, edx
.l: add eax, ecx
    xor edx, eax
    rol edx, 3
    dec ecx
    jnz .l
    xor eax, edx
    ret

setfs32:                ; uint32 setfs32(sel): fs = sel; return fs:[0x18] (TEB self ptr)
    mov eax, [esp+4]
    mov fs, ax
    mov eax, [fs:0x18]
    ret

getfs32:                ; uint32 getfs32(): fs:[0x18] without reloading fs
    mov eax, [fs:0x18]
    ret

peek32:                 ; uint32 peek32(addr)
    mov eax, [esp+4]
    mov eax, [eax]
    ret

fpu32:                  ; int fpu32(a, b) = (int)sqrt((double)a * b) * 1000 via x87
    push ebp
    mov ebp, esp
    sub esp, 4
    fild dword [ebp+8]
    fild dword [ebp+12]
    fmulp st1, st0
    fsqrt
    mov dword [ebp-4], 1000
    fimul dword [ebp-4]
    fistp dword [ebp-4]
    mov eax, [ebp-4]
    leave
    ret

fault32:                ; reads address 0x10 (unmapped page zero) -> SIGSEGV
    mov eax, [0x10]
    ret
blob32_end:

; ========================================================================
; 64-bit blob (copied to THUNK64, below 4 GB so 32-bit far ptrs reach it)
; ========================================================================
bits 64
blob64:
ret64:                  ; end of a call32: restore host stack, jump to continuation
    mov rsp, [abs SAVED_RSP]
    jmp [abs CONT]

cb64:                   ; 32-bit far call lands here: [rsp]=eip, [rsp+4]=cs, [rsp+8]=arg0...
    mov esp, esp        ; zero-extend: upper rsp is undefined after compat mode
    mov r12, rsp
    mov edi, [rsp+8]
    mov esi, [rsp+12]
    and rsp, -16
    call [abs HOSTFN]
    mov rsp, r12
    retf                ; 32-bit far return (CB): pops eip32 + cs32
blob64_end:

; ========================================================================
; host code
; ========================================================================

; uint32 call32(rdi = 32-bit target, esi = a, edx = b). Not re-entrant.
call32:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov [abs SAVED_RSP], rsp
    lea rax, [.back]
    mov [abs CONT], rax
    mov ecx, edi
    mov esp, STACK32_TOP
    mov [rsp-8], esi
    mov [rsp-4], edx
    sub rsp, 8
    movzx eax, word [sel32]
    push rax
    push A32(tramp32)
    o64 retf            ; pops rip + cs (8 bytes each) -> 32-bit mode
.back:
    mov eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; int host_cb(int x, int y) — called from 32-bit code via cb64
host_cb:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    cmp byte [quiet], 0
    jne .calc
    lea rdi, [fmt_cb]
    mov esi, r12d
    mov edx, r13d
    mov rcx, rsp
    xor eax, eax
    call _printf
.calc:
    mov eax, r12d
    imul eax, r13d
    pop r13
    pop r12
    pop rbx
    ret

; uint32 loop64(n) — same work as loop32, native 64-bit
loop64:
    mov ecx, edi
    xor eax, eax
    xor edx, edx
.l: add eax, ecx
    xor edx, eax
    rol edx, 3
    dec ecx
    jnz .l
    xor eax, edx
    ret

now_ns:
    sub rsp, 8
    mov edi, CLOCK_UPTIME_RAW
    call _clock_gettime_nsec_np
    add rsp, 8
    ret

; SIGSEGV handler(sig, siginfo*, ucontext*)
segv_handler:
    push rbx
    push r12
    push r13
    mov r12, rsi                ; siginfo
    mov r13, rdx                ; ucontext
    mov rbx, [r13+48]           ; uc_mcontext -> mcontext64 (es 16 bytes, then ss)
    lea rdi, [fmt_segv]
    mov esi, [r12]              ; si_signo
    mov rdx, [r12+24]           ; si_addr
    mov rcx, [rbx+16+128]       ; rip
    mov r8,  [rbx+16+144]       ; cs
    mov r9,  [rbx+16+56]        ; rsp
    xor eax, eax
    call _printf
    ; resume at ret64 in 64-bit mode with eax = 0xDEAD
    mov qword [rbx+16+0], 0xDEAD
    mov qword [rbx+16+128], A64(ret64)
    movzx eax, word [sel64]
    mov [rbx+16+144], rax
    pop r13
    pop r12
    pop rbx
    ret

; load_pe(rdi = path): pread headers + raw sections of a PE32 to IMAGE_BASE+VA.
; Only a section copy: no imports, no protections. Returns entry VA or 0.
load_pe:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi
    xor esi, esi                ; O_RDONLY
    xor eax, eax
    call _open
    test eax, eax
    js .fail
    mov ebx, eax                ; fd
    mov edi, ebx
    mov esi, IMAGE_BASE
    mov edx, 0x1000
    xor ecx, ecx
    call _pread
    mov eax, [abs IMAGE_BASE+0x3c]
    lea r12, [rax+IMAGE_BASE]   ; NT headers
    cmp dword [r12], 0x4550     ; "PE\0\0"
    jne .fail_close
    lea rdi, [fmt_pe]
    mov esi, [r12+24+28]        ; ImageBase
    mov edx, [r12+24+56]        ; SizeOfImage
    movzx ecx, word [r12+6]
    xor eax, eax
    call _printf
    cmp dword [r12+24+28], IMAGE_BASE
    jne .fail_close
    movzx r13d, word [r12+6]    ; NumberOfSections
    movzx eax, word [r12+20]    ; SizeOfOptionalHeader
    lea r14, [r12+24+rax]       ; first section header
.sec:
    mov edi, ebx
    mov esi, [r14+12]           ; VirtualAddress
    add esi, IMAGE_BASE
    mov edx, [r14+16]           ; SizeOfRawData
    mov ecx, [r14+20]           ; PointerToRawData
    call _pread
    lea rdi, [fmt_sec]
    mov rsi, r14                ; name (8 chars, %.8s)
    mov edx, [r14+12]
    add edx, IMAGE_BASE
    mov ecx, [r14+16]
    mov r8, rax
    xor eax, eax
    call _printf
    add r14, 40
    dec r13d
    jnz .sec
    mov edi, ebx
    call _close
    mov eax, [r12+24+16]        ; AddressOfEntryPoint
    add eax, IMAGE_BASE
    jmp .out
.fail_close:
    mov edi, ebx
    call _close
.fail:
    lea rdi, [fmt_pe_fail]
    mov rsi, r15
    xor eax, eax
    call _printf
    xor eax, eax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

global _main
_main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov [argc], edi
    mov [argv], rsi

    mov rax, [rel ___stdoutp wrt ..gotpcrel]
    mov rdi, [rax]
    xor esi, esi
    mov edx, 2                  ; _IONBF
    xor ecx, ecx
    call _setvbuf

    ; --- segment registers + where the host lives
    xor eax, eax
    mov ax, cs
    mov [sel64], ax
    lea rdi, [fmt_regs]
    movzx esi, ax
    mov dx, ss
    movzx edx, dx
    mov cx, ds
    movzx ecx, cx
    lea r8, [_main]
    xor eax, eax
    call _printf

    ; --- 1. low RWX mapping (hint, no MAP_FIXED: verify instead of clobbering)
    mov edi, LOW_BASE
    mov esi, LOW_SIZE
    mov edx, PROT_RWX
    mov ecx, MAP_ANONPRIV
    mov r8d, -1
    xor r9d, r9d
    call _mmap
    mov rbx, rax
    lea rdi, [fmt_mmap]
    mov rsi, rbx
    mov edx, LOW_SIZE
    xor eax, eax
    call _printf
    cmp rbx, LOW_BASE
    jne fail_mmap

    ; copy blobs
    lea rsi, [blob32]
    mov edi, CODE32
    mov ecx, blob32_end - blob32
    rep movsb
    lea rsi, [blob64]
    mov edi, THUNK64
    mov ecx, blob64_end - blob64
    rep movsb
    movzx eax, word [sel64]
    mov dword [abs FAR_RET], A64(ret64)
    mov word  [abs FAR_RET+4], ax
    mov dword [abs FAR_CB], A64(cb64)
    mov word  [abs FAR_CB+4], ax
    lea rax, [host_cb]
    mov [abs HOSTFN], rax
    mov dword [abs TEB+0x00], -1        ; SEH chain terminator
    mov dword [abs TEB+0x18], TEB       ; NT_TIB.Self

    ; --- 2. 32-bit code + TEB data descriptors via i386_set_ldt
    ; one descriptor per call: Rosetta aborts on num_sels > 1
    mov edi, LDT_INDEX + 1
    lea rsi, [desc_ldt+8]
    mov edx, 1
    call _i386_set_ldt
    mov r12d, eax
    call ___error
    mov r13d, [rax]
    lea rdi, [fmt_ldt]
    mov esi, LDT_INDEX + 1
    mov edx, r12d
    mov ecx, r13d
    xor eax, eax
    call _printf
    test r12d, r12d
    js fail_ldt
    mov edi, LDT_INDEX
    lea rsi, [desc_ldt]
    mov edx, 1
    call _i386_set_ldt
    mov r12d, eax
    call ___error
    mov r13d, [rax]
    lea rdi, [fmt_ldt]
    mov esi, LDT_INDEX
    mov edx, r12d
    mov ecx, r13d
    xor eax, eax
    call _printf
    test r12d, r12d
    js fail_ldt
    mov eax, r12d
    shl eax, 3
    or eax, 7                   ; TI=1 (LDT), RPL=3
    mov [sel32], ax
    add eax, 8
    mov [selfs], ax
    lea rdi, [fmt_sel]
    movzx esi, word [sel32]
    movzx edx, word [selfs]
    xor eax, eax
    call _printf

    ; --- mode proof
    mov edi, A32(mode32)
    call call32
    lea rdi, [fmt_mode]
    mov esi, eax
    xor eax, eax
    call _printf

    mov edi, A32(getcs32)
    call call32
    lea rdi, [fmt_cs]
    mov esi, eax
    xor eax, eax
    call _printf

    ; --- add32(2, 40)
    mov edi, A32(add32)
    mov esi, 2
    mov edx, 40
    call call32
    lea rdi, [fmt_add]
    mov esi, eax
    xor eax, eax
    call _printf

    ; --- 3. callback: cb32(6, 7) -> host_cb(6,7)+1 = 43
    mov edi, A32(cb32)
    mov esi, 6
    mov edx, 7
    call call32
    lea rdi, [fmt_cbres]
    mov esi, eax
    xor eax, eax
    call _printf

    ; --- x87 inside 32-bit code: sqrt(2*3)*1000 = 2449
    mov edi, A32(fpu32)
    mov esi, 2
    mov edx, 3
    call call32
    lea rdi, [fmt_fpu]
    mov esi, eax
    xor eax, eax
    call _printf

    ; --- FS -> TEB (what every MSVC SEH prologue needs: fs:[0], fs:[0x18])
    mov edi, A32(setfs32)
    movzx esi, word [selfs]
    call call32
    mov r12d, eax
    mov edi, A32(getfs32)
    call call32
    lea rdi, [fmt_fs]
    mov esi, r12d
    mov edx, eax
    mov ecx, TEB
    xor eax, eax
    call _printf

    ; --- perf: 1,000,000 call32(add32) round trips
    call now_ns
    mov r14, rax
    mov r12d, 1000000
.rt:
    mov edi, A32(add32)
    mov esi, r12d
    mov edx, 1
    call call32
    dec r12d
    jnz .rt
    call now_ns
    sub rax, r14
    lea rdi, [fmt_rt]
    mov rsi, rax
    xor edx, edx
    mov ecx, 1000000
    div rcx                      ; rax = ns per round trip
    mov rdx, rax
    xor eax, eax
    call _printf

    ; --- perf: 1M round trips that also call back into the host (2 transitions each way)
    mov byte [quiet], 1
    call now_ns
    mov r14, rax
    mov r12d, 1000000
.rtcb:
    mov edi, A32(cb32)
    mov esi, r12d
    mov edx, 1
    call call32
    dec r12d
    jnz .rtcb
    call now_ns
    mov byte [quiet], 0
    sub rax, r14
    lea rdi, [fmt_rtcb]
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov rsi, rax
    xor eax, eax
    call _printf

    ; --- perf: same loop, 300M iterations, 32-bit vs 64-bit
    call now_ns
    mov r14, rax
    mov edi, A32(loop32)
    mov esi, 300000000
    call call32
    mov r12d, eax
    call now_ns
    sub rax, r14
    mov r13, rax
    call now_ns
    mov r14, rax
    mov edi, 300000000
    call loop64
    mov ebx, eax
    call now_ns
    sub rax, r14
    lea rdi, [fmt_loop]
    mov esi, r12d
    mov rdx, r13
    shr rdx, 20                 ; ~ms (ns >> 20)
    mov ecx, ebx
    mov r8, rax
    shr r8, 20
    xor eax, eax
    call _printf

    ; --- 4. SIGSEGV inside 32-bit code
    lea rax, [segv_handler]
    mov [sa_handler], rax
    mov dword [sa_mask], 0
    mov dword [sa_flags], SA_SIGINFO
    mov edi, SIGSEGV
    lea rsi, [sa_handler]
    xor edx, edx
    call _sigaction
    mov edi, SIGBUS
    lea rsi, [sa_handler]
    xor edx, edx
    call _sigaction
    mov edi, A32(fault32)
    call call32
    lea rdi, [fmt_fault]
    mov esi, eax
    xor eax, eax
    call _printf

    ; prove 32-bit still works after the fault
    mov edi, A32(add32)
    mov esi, 1000
    mov edx, 337
    call call32
    lea rdi, [fmt_add]
    mov esi, eax
    xor eax, eax
    call _printf

    ; --- 5. bonus: map gta2.exe sections at 0x3F0000 and peek from 32-bit code
    cmp dword [argc], 2
    jl .done
    mov rax, [argv]
    mov rdi, [rax+8]
    call load_pe
    test eax, eax
    jz .done
    mov r12d, eax
    mov edi, A32(peek32)
    mov esi, r12d
    call call32
    lea rdi, [fmt_entry]
    mov esi, r12d
    mov edx, eax
    xor eax, eax
    call _printf

.done:
    lea rdi, [fmt_done]
    xor eax, eax
    call _printf
    xor edi, edi
    call _exit

fail_mmap:
    call ___error
    lea rdi, [fmt_fail_mmap]
    mov esi, [rax]
    xor eax, eax
    call _printf
    mov edi, 2
    call _exit
fail_ldt:
    lea rdi, [fmt_fail_ldt]
    xor eax, eax
    call _printf
    mov edi, 3
    call _exit

section .data
align 8
desc_ldt:
    ; flat 4 GB, 32-bit (D=1), page granular, DPL3, present, code exec/read
    dq 0x00CFFA000000FFFF
    ; base TEB, limit 0xFFF bytes, 32-bit, DPL3, present, data read/write
    dq 0x0FFF | ((TEB & 0xFFFF) << 16) | (((TEB >> 16) & 0xFF) << 32) | (0xF2 << 40) | (0x40 << 48) | ((TEB >> 24) << 56)
sel32:       dw 0
sel64:       dw 0
selfs:       dw 0
quiet:       db 0
align 8
argc:        dd 0, 0
argv:        dq 0
sa_handler:  dq 0
sa_mask:     dd 0
sa_flags:    dd 0

fmt_regs:  db "host: cs=0x%x ss=0x%x ds=0x%x, _main at %p", 10, 0
fmt_mmap:  db "mmap(0x3F0000, 0x%2$x, RWX) -> %1$p", 10, 0
fmt_ldt:   db "i386_set_ldt(%d, &desc, 1) -> %d (errno %d)", 10, 0
fmt_sel:   db "selectors: code32 = 0x%x, fs/TEB = 0x%x", 10, 0
fmt_mode:  db "mode32 (40 40 = inc eax x2 only in 32-bit mode) -> %d  [2 = 32-bit, 0 = 64-bit]", 10, 0
fmt_cs:    db "cs as seen from 32-bit code = 0x%x", 10, 0
fmt_add:   db "add32 -> %d", 10, 0
fmt_cb:    db "  [host_cb] called from 32-bit code: x=%d y=%d (host rsp=%p)", 10, 0
fmt_cbres: db "cb32(6,7) = host_cb(6,7)+1 -> %d", 10, 0
fmt_fpu:   db "fpu32(2,3) = x87 sqrt(2*3)*1000 -> %d", 10, 0
fmt_fs:    db "fs:[0x18] after mov fs -> 0x%x, on a later call32 -> 0x%x (TEB = 0x%x)", 10, 0
fmt_rt:    db "perf: 1M 64->32->64 round trips: %llu ns total, %llu ns each", 10, 0
fmt_rtcb:  db "perf: 1M round trips with a 32->64->32 callback inside: %llu ns each", 10, 0
fmt_loop:  db "perf: 300M-iter loop: 32-bit -> 0x%x in ~%llu ms, 64-bit -> 0x%x in ~%llu ms", 10, 0
fmt_segv:  db "  [signal %d] addr=%p rip=0x%llx cs=0x%llx rsp=0x%llx", 10, 0
fmt_fault: db "fault32 recovered, call32 returned 0x%x", 10, 0
fmt_pe:    db "PE: ImageBase=0x%x SizeOfImage=0x%x sections=%d", 10, 0
fmt_sec:   db "  %.8s -> 0x%x raw 0x%x (pread %lld)", 10, 0
fmt_entry: db "gta2.exe entry 0x%x, first dword read from 32-bit code = 0x%08x", 10, 0
fmt_pe_fail: db "PE load failed: %s", 10, 0
fmt_done:  db "ALL OK", 10, 0
fmt_fail_mmap: db "FAIL: mmap did not return 0x3F0000 (errno %d)", 10, 0
fmt_fail_ldt:  db "FAIL: i386_set_ldt", 10, 0
