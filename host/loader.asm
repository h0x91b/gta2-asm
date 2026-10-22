; gta2-resurrected — PE loader + first calls into original gta2.exe code.
;
; x86-64 Mach-O (macho64), runs under Rosetta 2. Separate binary from the SDL hello
; window (host/main.asm); same link flags, no SDL.
;
;   ./loader [data.pak]           map gta2.ebin from the pak, stub every import, call
;                                 original functions through a 32-bit LDT code segment
;                                 and check the results; exit 0 when every check passes
;   ./loader [data.pak] --entry   same, then jump to the real PE entry point and run the
;                                 game through the Win32 shims
;   --config=PATH                 settings file instead of config.yaml in the overlay dir
;                                 (config.asm; see config.example.yaml)
;
; Exit codes: 0 ok, 1 load/setup failure, 2 a function check failed,
;             3 the game called an unimplemented import, 4 SIGSEGV/SIGBUS.
;
; How it works (see spike/ for the proof of each mechanism):
;   1. gta2.ebin is read from data.pak (w32_vfs.asm) into a malloc buffer and validated (MZ, PE, i386, PE32,
;      ImageBase 0x3F0000 — there are no relocations, so no other base is possible).
;   2. SizeOfImage is mmap'ed at 0x3F0000 (hint + verify, never blind MAP_FIXED), the
;      headers and every section are copied to ImageBase+VA (raw bytes up to the
;      page-aligned VirtualSize, as Windows does), the rest of each section's pages
;      (BSS) is zeroed explicitly.
;   3. Every IAT slot gets its own 10-byte 32-bit stub `push index; jmp common32`;
;      common32 far-calls a 64-bit thunk that prints "unimplemented import DLL!Name"
;      and exits 3.
;   4. Sections are then mprotect'ed from their PE characteristics (.text RX, .rdata
;      R, .data RW, .rsrc R, headers R). Our own low region (thunks, stubs, TEB, 32-bit
;      stack) is RWX.
;   5. call32 enters 32-bit code with a far return (o64 retf) to an LDT code selector,
;      with eax/ecx/edx and stack arguments set up, and comes back with edx:eax.
;
; Addresses of the original functions come from re/functions.csv (Ghidra export,
; 1:1 vanilla 11.44 VAs); their behaviour was read from the disassembly (ndisasm).
;
; ABI: System V AMD64 on the host side, every libc call with rsp 16-byte aligned,
; variadic calls with al = 0.

default rel

extern _printf, _puts, _mmap, _mprotect, _i386_set_ldt, ___error, _setvbuf, _exit
extern _sigaction, _open, _close, _pread, _lseek, _malloc, _memcpy, _memset, _strcmp, ___stdoutp

; ---- PE layout (winnt.h) ------------------------------------------------
IMAGE_BASE      equ 0x3F0000        ; gta2.exe ImageBase; no relocs, so exact
PE_MACHINE_I386 equ 0x14C
PE_MAGIC_PE32   equ 0x10B
OPT             equ 24              ; IMAGE_NT_HEADERS.OptionalHeader
OPT_ENTRY       equ OPT + 16
OPT_IMAGEBASE   equ OPT + 28
OPT_SECTALIGN   equ OPT + 32
OPT_SIZEOFIMAGE equ OPT + 56
OPT_SIZEOFHDRS  equ OPT + 60
OPT_NUMDIRS     equ OPT + 92
OPT_DIR_IMPORT  equ OPT + 96 + 8*1
SCN_EXECUTE     equ 0x20000000
SCN_READ        equ 0x40000000
SCN_WRITE       equ 0x80000000

; ---- our low memory (32-bit code can only reach the low 4 GB) -------------
LOW_BASE    equ 0x10000000
LOW_SIZE    equ 0x1000000           ; 16 MB: thunks, stubs, TEB, 8 MB 32-bit stack
CODE32      equ LOW_BASE + 0x0000   ; blob32 copied here
THUNK64     equ LOW_BASE + 0x1000   ; blob64 copied here
CTX         equ LOW_BASE + 0x2000   ; call32 context (single-threaded, not re-entrant)
SAVED_RSP   equ CTX + 0x00          ; host rsp at call32 entry
CONT        equ CTX + 0x08          ; host continuation address
HOST_DISPATCH equ CTX + 0x10        ; 64-bit host_dispatch, reached from dispatch64
FAR_RET     equ CTX + 0x18          ; m16:32 -> THUNK64:ret64 (64-bit CS)
FAR_DISPATCH equ CTX + 0x20         ; m16:32 -> THUNK64:dispatch64 (64-bit CS)
C_TARGET    equ CTX + 0x28          ; 32-bit function to call
C_EAX       equ CTX + 0x2C          ; register arguments for it
C_ECX       equ CTX + 0x30
C_EDX       equ CTX + 0x34
C_FS        equ CTX + 0x38          ; TEB selector, loaded into fs on every entry
POP_BYTES   equ CTX + 0x3C          ; stdcall argument bytes common32 pops for the caller
ESP32_TOP   equ CTX + 0x40          ; where call32 builds its 32-bit frame (nests below the
                                    ; game's esp while an import handler runs)
G_EAX       equ CTX + 0x44          ; the game's eax/ecx/edx when it entered a stub
G_ECX       equ CTX + 0x48          ; (host_dispatch; read them before any call32)
G_EDX       equ CTX + 0x4C
TEB         equ LOW_BASE + 0x3000   ; fake NT_TIB, base of the FS descriptor
STUBS       equ LOW_BASE + 0x4000   ; import stubs, STUB_SIZE bytes each
STUB_SIZE   equ 10
MAX_IMPORTS equ 1024                ; 0x2800 bytes of stubs: fits below STRS
STRS        equ LOW_BASE + 0x8000   ; test strings (strs blob copied here)
STACK32_LO  equ LOW_BASE + 0x800000
STACK32_TOP equ LOW_BASE + LOW_SIZE - 16

LDT_CODE    equ 16                  ; Rosetta aborts on LDT_AUTO_ALLOC: pick indices
LDT_TEB     equ 17

%define A32(l) (CODE32 + (l) - blob32)
%define A64(l) (THUNK64 + (l) - blob64)
%define S32(l) (STRS + (l) - strs)

PROT_R      equ 1
PROT_W      equ 2
PROT_X      equ 4
MAP_ANONPRIV equ 0x1002             ; MAP_ANON | MAP_PRIVATE
; SDL3 is NOT linked: dyld would load its frameworks into the low 4 GB (mmap at
; 0x3F0000 then fails). Low regions are mapped first, SDL is dlopen'ed afterwards
; (w32_user32.asm). A fixed zerofill segment would also work, but CrowdStrike Falcon
; on the dev machine SIGKILLs + deletes binaries with one (measured 2026-10-20).
SEEK_END    equ 2

EXIT_LOAD   equ 1
EXIT_CHECK  equ 2
EXIT_UNIMPL equ 3
EXIT_CRASH  equ 4
SIGBUS      equ 10
SIGSEGV     equ 11
SA_SIGINFO  equ 0x40

section .text

; ========================================================================
; 32-bit blob (copied to CODE32)
; ========================================================================
bits 32
blob32:
tramp32:                    ; entered by o64 retf from call32; args already on the stack
    mov fs, [C_FS]
    mov eax, [C_EAX]
    mov ecx, [C_ECX]
    mov edx, [C_EDX]
    call [C_TARGET]         ; cdecl/stdcall/fastcall all fine: esp is not trusted after
    jmp far [FAR_RET]       ; edx:eax back to the host

common32:                   ; every import stub jumps here with its index pushed:
    call far [FAR_DISPATCH] ; [esp]=index [esp+4]=caller ret [esp+8]=args; edx:eax back
    mov fs, [C_FS]
    add esp, 4              ; drop the index
    pop ecx                 ; caller's return address (ecx is volatile in every Win32 ABI)
    add esp, [POP_BYTES]    ; stdcall: callee pops its arguments (0 for cdecl)
    jmp ecx
blob32_end:

; ========================================================================
; 64-bit blob (copied to THUNK64: 32-bit far pointers only reach the low 4 GB)
; ========================================================================
bits 64
blob64:
ret64:
    mov rsp, [abs SAVED_RSP]
    jmp [abs CONT]

dispatch64:                 ; [esp]=eip32 [esp+4]=cs [esp+8]=import index [esp+12]=caller ret
    mov esp, esp            ; upper rsp is undefined after compat mode
    jmp [abs HOST_DISPATCH]
blob64_end:

; ========================================================================
; host code
; ========================================================================

; uint64 call32(edi = target, rsi = dword args[], edx = nargs,
;               ecx = eax in, r8d = ecx in, r9d = edx in) -> edx:eax. Not re-entrant.
call32:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push qword [abs SAVED_RSP]  ; re-entrant: a handler may call back into 32-bit code
    sub rsp, 8
    mov [abs C_TARGET], edi
    mov [abs C_EAX], ecx
    mov [abs C_ECX], r8d
    mov [abs C_EDX], r9d
    mov [abs SAVED_RSP], rsp
    lea rax, [.back]
    mov [abs CONT], rax
    mov eax, [abs ESP32_TOP]    ; STACK32_TOP, or just below the game's esp when nested
    mov rsp, rax
    mov ecx, edx
.push_arg:                      ; args[nargs-1] first, so args[0] ends up at [esp]
    test ecx, ecx
    jz .enter
    dec ecx
    mov eax, [rsi + rcx*4]
    sub rsp, 4
    mov [rsp], eax
    jmp .push_arg
.enter:
    movzx eax, word [sel32]
    push rax
    push A32(tramp32)
    o64 retf                    ; pops rip + cs (8 bytes each) -> 32-bit mode
.back:
    shl rdx, 32
    mov eax, eax
    or rax, rdx
    add rsp, 8
    pop qword [abs SAVED_RSP]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; host_dispatch: reached from dispatch64 in 64-bit mode, rsp = the game's esp:
;   [rsp]=eip32 [rsp+4]=cs32 [rsp+8]=slot index [rsp+12]=caller ret [rsp+16]=args.
; Switches to the host stack (below the innermost call32 frame), calls
; imp_handler[index](rdi = args, esi = index) and far-returns edx:eax to common32
; with POP_BYTES = imp_pop[index]. Saves the game's esi/edi (SysV clobbers them;
; ebx/ebp are callee-saved on both sides).
host_dispatch:
    mov [abs G_EAX], eax
    mov [abs G_ECX], ecx
    mov [abs G_EDX], edx
    mov r10, rsp
    mov rsp, [abs SAVED_RSP]
    push rbp
    mov rbp, rsp
    push r10
    push rsi
    push rdi
    push qword [abs ESP32_TOP]
    push rbx
    push r12
    and rsp, -16
    lea rax, [r10 - 16]         ; nested call32 frames go below the game's frame
    and eax, -16
    mov [abs ESP32_TOP], eax
    mov esi, [r10 + 8]
    lea rdi, [r10 + 16]
    lea rax, [imp_handler]
    call [rax + rsi*8]
    cmp byte [trace], 0
    je .no_trace
    mov rdi, [rbp - 8]          ; r10
    mov rsi, rax
    mov rbx, rax                ; game's rbx/r12 are saved in the frame
    mov r12, rdx
    call trace_call
    mov rax, rbx
    mov rdx, r12
.no_trace:
    lea rsp, [rbp - 48]
    pop r12
    pop rbx
    pop qword [abs ESP32_TOP]
    pop rdi
    pop rsi
    pop r10
    pop rbp
    mov ecx, [r10 + 8]
    lea r11, [imp_pop]
    mov ecx, [r11 + rcx*4]
    mov [abs POP_BYTES], ecx
    mov rsp, r10
    retf                        ; 32-bit operand size: pops eip32 + cs

; noreturn host_unimpl(rdi = args, esi = slot index): the default import handler.
host_unimpl:
    and rsp, -16
    mov ebx, esi
    mov r12d, [rdi - 4]         ; caller's return address
    lea rax, [imp_dll]
    mov rsi, [rax + rbx*8]
    lea rax, [imp_name]
    mov rdx, [rax + rbx*8]
    test rdx, rdx
    jz .by_ordinal
    lea rdi, [fmt_unimpl]
    mov ecx, r12d
    xor eax, eax
    call _printf
    jmp .out
.by_ordinal:
    lea rax, [imp_ord]
    mov edx, [rax + rbx*4]
    lea rdi, [fmt_unimpl_ord]
    mov ecx, r12d
    xor eax, eax
    call _printf
.out:
    call hold_window
    mov edi, EXIT_UNIMPL
    call _exit

; crash_handler(sig, siginfo*, ucontext*): report where it died (32- or 64-bit) and exit.
crash_handler:
    and rsp, -16
    mov rbx, [rdx + 48]         ; uc_mcontext -> x86 mcontext64 (es 16 bytes, then ss)
    lea rdi, [fmt_crash]
    mov rdx, [rsi + 24]         ; si_addr
    mov esi, [rsi]              ; si_signo
    mov rcx, [rbx + 16 + 128]   ; rip
    mov r8,  [rbx + 16 + 144]   ; cs (0x2b = 64-bit host, code32 selector = game code)
    mov r9,  [rbx + 16 + 56]    ; rsp
    xor eax, eax
    call _printf
    mov edi, EXIT_CRASH
    call _exit

; void fail(rdi = message) — print "loader: FAIL: <msg>" and exit EXIT_LOAD
fail:
    and rsp, -16
    mov rsi, rdi
    lea rdi, [fmt_fail]
    xor eax, eax
    call _printf
    mov edi, EXIT_LOAD
    call _exit

; Open data.pak (rdi = path) and read its gta2.ebin into a malloc'ed buffer -> [file],
; [file_size]
read_image:
    push rbx
    push r12
    push r13
    call vfs_open_pak
    lea rdi, [s_image]
    call vfs_find
    cmp eax, -1
    je .no_image
    mov ebx, eax
    imul eax, eax, PAK_ENT_SIZE
    add rax, [pak_ents]
    mov r12, rax
    mov r13d, [rax + 16]
    mov [file_size], r13
    mov rdi, r13
    call _malloc
    test rax, rax
    jz .bad_read
    mov [file], rax
    mov edi, ebx
    mov rsi, rax
    mov rdx, r13
    xor ecx, ecx
    call vfs_read_at
    cmp rax, r13
    jne .bad_read
    lea rdi, [fmt_file]
    mov rsi, [pak_path]
    mov rdx, r13
    mov rcx, [r12 + 8]
    xor eax, eax
    call _printf
    pop r13
    pop r12
    pop rbx
    ret
.no_image:
    lea rdi, [msg_no_image]
    call fail
.bad_read:
    lea rdi, [msg_read]
    call fail

; Validate headers, map the image, copy sections, zero BSS tails.
map_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, [file]
    mov r15, [file_size]
    cmp r15, 0x40
    jb .bad
    cmp word [rbx], 'MZ'
    jne .bad
    mov eax, [rbx + 0x3c]       ; e_lfanew
    lea rcx, [rax + OPT_DIR_IMPORT + 8]
    cmp rcx, r15
    ja .bad
    lea r12, [rbx + rax]        ; r12 = NT headers (in the file buffer)
    mov [nt], r12
    cmp dword [r12], 'PE'       ; "PE\0\0"
    jne .bad
    cmp word [r12 + 4], PE_MACHINE_I386
    jne .bad
    cmp word [r12 + OPT], PE_MAGIC_PE32
    jne .bad
    cmp dword [r12 + OPT_NUMDIRS], 2
    jb .bad
    lea rdi, [fmt_pe]
    mov esi, [r12 + OPT_IMAGEBASE]
    mov edx, [r12 + OPT_SIZEOFIMAGE]
    mov ecx, [r12 + OPT_ENTRY]
    add ecx, esi
    movzx r8d, word [r12 + 6]
    xor eax, eax
    call _printf
    cmp dword [r12 + OPT_IMAGEBASE], IMAGE_BASE
    jne .bad_base
    cmp dword [r12 + OPT_SECTALIGN], 0x1000
    jne .bad

    ; reserve the image: hint + verify (MAP_FIXED could silently replace a mapping)
    mov edi, IMAGE_BASE
    mov esi, [r12 + OPT_SIZEOFIMAGE]
    mov edx, PROT_R | PROT_W
    mov ecx, MAP_ANONPRIV
    mov r8d, -1
    xor r9d, r9d
    call _mmap
    cmp rax, IMAGE_BASE
    jne .bad_mmap

    mov edi, IMAGE_BASE         ; headers
    mov rsi, rbx
    mov edx, [r12 + OPT_SIZEOFHDRS]
    cmp rdx, r15
    ja .bad
    call _memcpy

    movzx r13d, word [r12 + 6]  ; NumberOfSections
    movzx eax, word [r12 + 20]  ; SizeOfOptionalHeader
    lea r14, [r12 + OPT + rax]  ; first IMAGE_SECTION_HEADER
.section:
    ; vsize = VirtualSize ?: SizeOfRawData; copy = min(raw, align_up(vsize)) like the
    ; Windows loader: the 11.44 patch keeps code in .text's raw slack past VirtualSize
    ; (entry jumps to 0x56DCDA, VirtualSize ends at 0x56DBC0). tail = rest of the pages.
    mov eax, [r14 + 8]          ; VirtualSize
    test eax, eax
    jnz .have_vsize
    mov eax, [r14 + 16]
.have_vsize:
    mov [cur_vsize], eax
    add eax, 0xFFF
    and eax, ~0xFFF
    mov ecx, [r14 + 16]         ; SizeOfRawData
    cmp ecx, eax
    cmova ecx, eax
    mov [cur_copy], ecx
    mov edx, [r14 + 20]         ; PointerToRawData
    add rdx, rcx
    cmp rdx, r15
    ja .bad
    mov edx, [r14 + 12]         ; VirtualAddress
    add edx, eax
    cmp edx, [r12 + OPT_SIZEOFIMAGE]
    ja .bad
    mov edi, [r14 + 12]
    add edi, IMAGE_BASE
    mov esi, [r14 + 20]
    add rsi, rbx
    mov edx, [cur_copy]
    call _memcpy
    mov edi, [r14 + 12]         ; zero the BSS tail up to the next page (the
    add edi, IMAGE_BASE         ; next section starts page-aligned)
    add edi, [cur_copy]
    mov edx, [cur_vsize]
    add edx, 0xFFF
    and edx, ~0xFFF
    sub edx, [cur_copy]
    mov [cur_tail], edx
    xor esi, esi
    call _memset
    lea rdi, [fmt_sec]
    mov rsi, r14                ; name, %.8s
    mov edx, [r14 + 12]
    add edx, IMAGE_BASE
    mov ecx, edx
    add ecx, [cur_vsize]
    mov r8d, [cur_copy]
    mov r9d, [cur_tail]
    xor eax, eax
    call _printf
    add r14, 40
    dec r13d
    jnz .section
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad:
    lea rdi, [msg_bad_pe]
    call fail
.bad_base:
    lea rdi, [msg_bad_base]
    call fail
.bad_mmap:
    lea rdi, [msg_bad_mmap]
    call fail

; Walk the import directory of the mapped image; point every IAT slot at a stub.
patch_imports:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rax, [nt]
    mov ebx, [rax + OPT_DIR_IMPORT]
    test ebx, ebx
    jz .done
    add ebx, IMAGE_BASE         ; rbx = IMAGE_IMPORT_DESCRIPTOR
.dll:
    mov eax, [rbx + 12]         ; Name
    test eax, eax
    jz .done
    lea r12, [rax + IMAGE_BASE] ; r12 = DLL name
    mov r13d, [rbx + 0]         ; OriginalFirstThunk (names), else FirstThunk
    test r13d, r13d
    jnz .have_int
    mov r13d, [rbx + 16]
.have_int:
    add r13d, IMAGE_BASE
    mov r14d, [rbx + 16]        ; FirstThunk = IAT
    add r14d, IMAGE_BASE
    xor r15d, r15d              ; imports in this DLL
.thunk:
    mov eax, [r13 + r15*4]
    test eax, eax
    jz .dll_done
    mov rdi, r12
    xor edx, edx
    test eax, eax
    js .ordinal                 ; IMAGE_ORDINAL_FLAG32
    lea rsi, [rax + IMAGE_BASE + 2]   ; IMAGE_IMPORT_BY_NAME.Name (skip Hint)
    jmp .slot
.ordinal:
    xor esi, esi
    movzx edx, ax
.slot:
    call new_slot               ; eax = stub address
    mov [r14 + r15*4], eax      ; IAT slot -> stub
    inc r15d
    jmp .thunk
.dll_done:
    lea rdi, [fmt_dll]
    mov rsi, r12
    mov edx, r15d
    mov ecx, r14d
    xor eax, eax
    call _printf
    inc dword [n_dlls]
    add rbx, 20
    jmp .dll
.done:
    lea rdi, [fmt_imports]
    mov esi, [n_dlls]
    mov edx, [n_imports]
    mov ecx, STUBS
    xor eax, eax
    call _printf
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax = new_slot(rdi = DLL name, rsi = function name or 0, edx = ordinal): allocate the
; next import slot, write its 32-bit stub `push index; jmp common32` and bind it to a
; handler (bind_slot). Returns the stub's 32-bit address. Strings must stay alive.
new_slot:
    push rbx
    mov ecx, [n_imports]
    cmp ecx, MAX_IMPORTS
    jae .too_many
    mov ebx, ecx
    lea rax, [imp_dll]
    mov [rax + rbx*8], rdi
    lea rax, [imp_name]
    mov [rax + rbx*8], rsi
    lea rax, [imp_ord]
    mov [rax + rbx*4], edx
    imul edi, ebx, STUB_SIZE
    add edi, STUBS
    mov byte [rdi], 0x68        ; push imm32 index
    mov [rdi + 1], ebx
    mov byte [rdi + 5], 0xE9    ; jmp rel32 common32
    mov eax, A32(common32)
    lea edx, [rdi + 10]
    sub eax, edx
    mov [rdi + 6], eax
    inc dword [n_imports]
    mov edi, ebx
    call bind_slot
    imul eax, ebx, STUB_SIZE
    add eax, STUBS
    pop rbx
    ret
.too_many:
    lea rdi, [msg_too_many]
    call fail

; mprotect headers + every section from its characteristics.
protect_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, [nt]
    mov edi, IMAGE_BASE
    mov esi, 0x1000
    mov edx, PROT_R
    call _mprotect
    test eax, eax
    jnz .bad
    movzx r13d, word [r12 + 6]
    movzx eax, word [r12 + 20]
    lea r14, [r12 + OPT + rax]
.section:
    mov eax, [r14 + 36]         ; Characteristics
    xor ebx, ebx
    test eax, SCN_READ
    jz .no_r
    or ebx, PROT_R
.no_r:
    test eax, SCN_WRITE
    jz .no_w
    or ebx, PROT_W
.no_w:
    test eax, SCN_EXECUTE
    jz .no_x
    or ebx, PROT_X
.no_x:
    mov esi, [r14 + 8]
    test esi, esi
    jnz .have_vsize
    mov esi, [r14 + 16]
.have_vsize:
    add esi, 0xFFF
    and esi, ~0xFFF
    mov edi, [r14 + 12]
    add edi, IMAGE_BASE
    mov edx, ebx
    call _mprotect
    test eax, eax
    jnz .bad
    lea rdi, [fmt_prot]
    mov rsi, r14
    lea rax, [prot_names]
    lea rdx, [rax + rbx*4]
    xor eax, eax
    call _printf
    add r14, 40
    dec r13d
    jnz .section
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad:
    lea rdi, [msg_mprotect]
    call fail

; Low region, blobs, TEB, LDT code + TEB descriptors.
setup_low:
    push rbx
    mov edi, LOW_BASE
    mov esi, LOW_SIZE
    mov edx, PROT_R | PROT_W | PROT_X
    mov ecx, MAP_ANONPRIV
    mov r8d, -1
    xor r9d, r9d
    call _mmap
    cmp rax, LOW_BASE
    jne .bad_mmap
    mov edi, CODE32
    lea rsi, [blob32]
    mov edx, blob32_end - blob32
    call _memcpy
    mov edi, THUNK64
    lea rsi, [blob64]
    mov edx, blob64_end - blob64
    call _memcpy
    mov edi, STRS
    lea rsi, [strs]
    mov edx, strs_end - strs
    call _memcpy

    mov ax, cs
    mov [sel64], ax
    mov dword [abs FAR_RET], A64(ret64)
    mov [abs FAR_RET + 4], ax
    mov dword [abs FAR_DISPATCH], A64(dispatch64)
    mov [abs FAR_DISPATCH + 4], ax
    lea rax, [host_dispatch]
    mov [abs HOST_DISPATCH], rax
    mov dword [abs ESP32_TOP], STACK32_TOP

    mov dword [abs TEB + 0x00], -1          ; ExceptionList: end of SEH chain
    mov dword [abs TEB + 0x04], STACK32_TOP ; StackBase
    mov dword [abs TEB + 0x08], STACK32_LO  ; StackLimit
    mov dword [abs TEB + 0x18], TEB         ; Self

    ; one descriptor per call: Rosetta aborts on num_sels > 1
    mov edi, LDT_TEB
    lea rsi, [desc_teb]
    mov edx, 1
    call _i386_set_ldt
    cmp eax, LDT_TEB
    jne .bad_ldt
    mov edi, LDT_CODE
    lea rsi, [desc_code]
    mov edx, 1
    call _i386_set_ldt
    cmp eax, LDT_CODE
    jne .bad_ldt
    mov word [sel32], LDT_CODE << 3 | 7     ; TI=1 (LDT), RPL=3
    mov word [abs C_FS], LDT_TEB << 3 | 7
    lea rdi, [fmt_low]
    mov esi, LOW_BASE
    mov edx, LOW_BASE + LOW_SIZE
    movzx ecx, word [sel32]
    movzx r8d, word [abs C_FS]
    mov r9d, TEB
    xor eax, eax
    call _printf
    pop rbx
    ret
.bad_mmap:
    lea rdi, [msg_low_mmap]
    call fail
.bad_ldt:
    lea rdi, [msg_ldt]
    call fail

; Run every entry of the tests table; returns eax = number of failures.
run_tests:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [tests]
    xor r12d, r12d              ; failures
    xor r13d, r13d              ; total
.next:
    lea rax, [tests_end]
    cmp rbx, rax
    jae .done
    mov edi, [rbx + TC_TARGET]
    lea rsi, [rbx + TC_ARGS]
    mov edx, [rbx + TC_NARGS]
    mov ecx, [rbx + TC_EAX]
    mov r8d, [rbx + TC_ECX]
    mov r9d, [rbx + TC_EDX]
    call call32
    and rax, [rbx + TC_MASK]
    mov r14, rax
    lea r15, [str_pass]
    cmp rax, [rbx + TC_EXPECT]
    je .print
    lea r15, [str_fail]
    inc r12d
.print:
    inc r13d
    lea rdi, [fmt_test]
    mov rsi, r15
    mov edx, [rbx + TC_TARGET]
    mov rcx, [rbx + TC_NAME]
    mov r8, r14
    mov r9, [rbx + TC_EXPECT]
    xor eax, eax
    call _printf
    add rbx, TC_SIZE
    jmp .next
.done:
    lea rdi, [fmt_summary]
    mov esi, r13d
    sub esi, r12d
    mov edx, r13d
    xor eax, eax
    call _printf
    mov eax, r12d
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
    mov rbx, rsi                ; argv
    mov r12d, edi               ; argc

    mov rax, [rel ___stdoutp wrt ..gotpcrel]
    mov rdi, [rax]
    xor esi, esi
    mov edx, 2                  ; _IONBF: output survives _exit/crash
    xor ecx, ecx
    call _setvbuf

    lea rax, [default_exe]
    mov [exe_path], rax
.arg:                           ; [data.pak] [--entry] [--trace], any order
    dec r12d
    jle .args_done
    add rbx, 8
    mov rdi, [rbx]
    lea rsi, [arg_entry]
    call _strcmp
    test eax, eax
    jnz .not_entry
    mov byte [run_entry], 1
    jmp .arg
.not_entry:
    mov rdi, [rbx]
    lea rsi, [arg_trace]
    call _strcmp
    test eax, eax
    jnz .not_trace
    mov byte [trace], 1
    jmp .arg
.not_trace:
    mov rdi, [rbx]
    lea rsi, [arg_hold]
    call _strcmp
    test eax, eax
    jnz .not_hold
    mov byte [hold], 1
    jmp .arg
.not_hold:
    mov rdi, [rbx]                  ; --frames=N: exit after N presented frames
    lea rsi, [arg_frames]
    mov edx, 9
    call _strncmp
    test eax, eax
    jnz .not_frames
    mov rdi, [rbx]
    add rdi, 9
    call _atoi
    mov [r_exit_frame], eax
    jmp .arg
.not_frames:
    mov rdi, [rbx]                  ; --shot=PATH: save the last frame (with --frames) as BMP
    lea rsi, [arg_shot]
    mov edx, 7
    call _strncmp
    test eax, eax
    jnz .not_shot
    mov rax, [rbx]
    add rax, 7
    mov [r_shot_path], rax
    jmp .arg
.not_shot:
    mov rdi, [rbx]                  ; --keys=FRAME:KEY,...: scripted key taps
    lea rsi, [arg_keys]
    mov edx, 7
    call _strncmp
    test eax, eax
    jnz .not_keys
    mov rax, [rbx]
    add rax, 7
    mov [keys_arg], rax
    jmp .arg
.not_keys:
    mov rdi, [rbx]                  ; --window=WxH: screen\window_width/height for this run
    lea rsi, [arg_window]
    mov edx, 9
    call _strncmp
    test eax, eax
    jnz .not_window
    mov rdi, [rbx]
    add rdi, 9
    lea rsi, [win_arg_end]
    mov edx, 10
    call _strtol
    mov [reg_win_w], eax
    mov rdi, [win_arg_end]
    movzx ecx, byte [rdi]
    or ecx, 0x20
    cmp ecx, 'x'
    jne .bad_window
    inc rdi
    xor esi, esi
    mov edx, 10
    call _strtol
    mov [reg_win_h], eax
    mov ecx, [reg_win_w]
    cmp ecx, 320
    jl .bad_window
    cmp eax, 240
    jl .bad_window
    cmp ecx, 4096
    jg .bad_window
    cmp eax, 4096
    jg .bad_window
    jmp .arg
.bad_window:
    lea rdi, [msg_bad_window]
    call fail
.not_window:
    mov rdi, [rbx]                  ; --audio-dump=PATH: also write the mixed output as WAV
    lea rsi, [arg_audio_dump]
    mov edx, 13
    call _strncmp
    test eax, eax
    jnz .not_dump
    mov rax, [rbx]
    add rax, 13
    mov [aud_dump_path], rax
    mov rdi, rax
    lea rsi, [s_wb]
    call _fopen
    mov [aud_dump_file], rax
    test rax, rax
    jz .arg
    sub rsp, 64                     ; placeholder header, rewritten at exit
    mov rdi, rsp
    xor esi, esi
    mov edx, 64
    call _memset
    mov rdi, rsp
    mov esi, 1
    mov edx, 44
    mov rcx, [aud_dump_file]
    call _fwrite
    add rsp, 64
    jmp .arg
.not_dump:
    mov rdi, [rbx]                  ; --config=PATH: settings file instead of config.yaml
    lea rsi, [arg_config]
    mov edx, 9
    call _strncmp
    test eax, eax
    jnz .not_config
    mov rdi, [rbx]
    add rdi, 9
    call cfg_set_path
    jmp .arg
.not_config:
    lea rdi, [arg_options]          ; flags that only set a byte
.opt:
    mov rsi, [rdi]
    test rsi, rsi
    jz .not_opt
    push rdi
    sub rsp, 8
    mov rdi, [rbx]
    call _strcmp
    add rsp, 8
    pop rdi
    test eax, eax
    jz .set_opt
    add rdi, 16
    jmp .opt
.set_opt:
    mov rax, [rdi + 8]
    mov byte [rax], 1
    jmp .arg
.not_opt:
    mov rax, [rbx]
    mov [exe_path], rax
    jmp .arg
.args_done:

    lea rax, [crash_handler]
    mov [sa_handler], rax
    mov dword [sa_flags], SA_SIGINFO
    mov edi, SIGSEGV
    lea rsi, [sa_handler]
    xor edx, edx
    call _sigaction
    mov edi, SIGBUS
    lea rsi, [sa_handler]
    xor edx, edx
    call _sigaction

    mov rdi, [exe_path]
    call read_image
    call enter_overlay_dir      ; the game's relative paths resolve against the overlay
    call map_image
    call setup_low
    call setup_arena
    call setup_modules
    call patch_imports
    call install_hooks
    call protect_image
    call setup_kernel32
    call setup_user32
    call setup_renderer
    call setup_audio
    call setup_input
    call setup_registry
    mov al, [trace]
    or [trace_input], al            ; --trace implies --trace-input

    lea rdi, [msg_calls]
    call _puts
    call run_tests
    test eax, eax
    jnz .checks_failed

    mov al, [input_selftest]
    or [input_test_on], al
    cmp byte [input_test_on], 0
    je .no_input_test
    call input_test                 ; --input-test / --input-selftest
    mov edi, eax
    call _exit
.no_input_test:
    cmp byte [run_entry], 0
    je .ok
    mov rax, [nt]
    mov edi, [rax + OPT_ENTRY]
    add edi, IMAGE_BASE
    mov r12d, edi
    lea rdi, [fmt_entry]
    mov esi, r12d
    xor eax, eax
    call _printf
    mov edi, r12d
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32                 ; returns only if the game never touches an import
    lea rdi, [fmt_entry_ret]
    mov esi, eax
    xor eax, eax
    call _printf
.ok:
    lea rdi, [msg_ok]
    call _puts
    xor edi, edi
    call _exit
.checks_failed:
    mov edi, EXIT_CHECK
    call _exit

section .data
align 8
desc_code:  ; flat 4 GB, 32-bit (D=1), page granular, DPL3, present, code exec/read
    dq 0x00CFFA000000FFFF
desc_teb:   ; base TEB, limit 0xFFF bytes, 32-bit, DPL3, present, data read/write
    dq 0x0FFF | ((TEB & 0xFFFF) << 16) | (((TEB >> 16) & 0xFF) << 32) | (0xF2 << 40) | (0x40 << 48) | ((TEB >> 24) << 56)

; ---- function checks -----------------------------------------------------
; Expected values were derived by hand from the disassembly (and, for __alldiv,
; computed independently with Python's integers); nothing here is produced by
; running the game code.
TC_NAME     equ 0
TC_TARGET   equ 8
TC_EAX      equ 12
TC_ECX      equ 16
TC_EDX      equ 20
TC_NARGS    equ 24
TC_ARGS     equ 28
TC_EXPECT   equ 48
TC_MASK     equ 56
TC_SIZE     equ 64

; TCASE label, target, eax, ecx, edx, nargs, a0, a1, a2, a3, expect, mask
%macro TCASE 12
    dq %%name
    dd %2, %3, %4, %5, %6, %7, %8, %9, %10, 0
    dq %11, %12
section .rodata
%%name: db %1, 0
section .data
%endmacro

M8  equ 0xFF
M32 equ 0xFFFFFFFF
M64 equ -1

align 8
tests:
    ; IsCarGun(WEAPON_INDEX id) @0x433820, stdcall:
    ;   cmp [esp+4], 0xF ; setge al ; ret 4  ->  al = (int)id >= 15 (upper eax: garbage)
    TCASE "IsCarGun(14)                   [stdcall]", 0x433820, 0,0,0, 1, 14,0,0,0,  0, M8
    TCASE "IsCarGun(15)                   [stdcall]", 0x433820, 0,0,0, 1, 15,0,0,0,  1, M8
    TCASE "IsCarGun(-1)  signed compare   [stdcall]", 0x433820, 0,0,0, 1, -1,0,0,0,  0, M8
    ; getUpgradeType @0x420760, argument in al (Ghidra's stdcall label is wrong):
    ;   i = (al & 0xFF) - 0xFA; i > 4 (unsigned) -> 0xF; else jump table @0x420790
    ;   = {0x420782: 0x12, 0x42077C: 0x10, 0x420776: 0x11, 0x420788: 0xF, 0x420788: 0xF}
    TCASE "getUpgradeType(al=0xFA)        [reg al]",  0x420760, 0xFA,0,0, 0, 0,0,0,0, 0x12, M32
    TCASE "getUpgradeType(al=0xFB)        [reg al]",  0x420760, 0xFB,0,0, 0, 0,0,0,0, 0x10, M32
    TCASE "getUpgradeType(al=0xFC)        [reg al]",  0x420760, 0xFC,0,0, 0, 0,0,0,0, 0x11, M32
    TCASE "getUpgradeType(al=0xFD)        [reg al]",  0x420760, 0xFD,0,0, 0, 0,0,0,0, 0x0F, M32
    TCASE "getUpgradeType(eax=0x1205)     [reg al]",  0x420760, 0x1205,0,0, 0, 0,0,0,0, 0x0F, M32
    ; __alldiv(int64 a, int64 b) @0x4D6260, MSVC CRT, stdcall (ret 0x10), edx:eax = a / b
    ; truncating toward zero; args are a.lo, a.hi, b.lo, b.hi
    TCASE "__alldiv(1000000000000, 7)     [CRT]",     0x4D6260, 0,0,0, 4, 0xD4A51000,0xE8,7,0, 142857142857, M64
    TCASE "__alldiv(-1000000000000, 7)    [CRT]",     0x4D6260, 0,0,0, 4, 0x2B5AF000,0xFFFFFF17,7,0, -142857142857, M64
    TCASE "__alldiv(123456789012345678, 9876543210)", 0x4D6260, 0,0,0, 4, 0xA630F34E,0x01B69B4B,0x4CB016EA,2, 12499999, M64
    TCASE "__alldiv(-(2^63-1), -3)        [CRT]",     0x4D6260, 0,0,0, 4, 1,0x80000000,0xFFFFFFFD,0xFFFFFFFF, 0x2AAAAAAAAAAAAAAA, M64
    ; _strlen(char *) @0x4D8960, MSVC CRT, cdecl; strings live below 4 GB (STRS)
    TCASE 'strlen("")                     [CRT]',     0x4D8960, 0,0,0, 1, S32(s_empty),0,0,0, 0, M32
    TCASE 'strlen("GTA2") unaligned       [CRT]',     0x4D8960, 0,0,0, 1, S32(s_gta2),0,0,0, 4, M32
    TCASE 'strlen(48-char string)         [CRT]',     0x4D8960, 0,0,0, 1, S32(s_long),0,0,0, 48, M32
tests_end:

strs:                       ; copied to STRS; offsets 0, 1, 6 -> aligned, unaligned, unaligned
s_empty:    db 0
s_gta2:     db "GTA2", 0
s_long:     db "Anywhere City: Downtown, Residential, Industrial", 0
strs_end:

default_exe: db "data.pak", 0        ; the game folder as a Stored zip (w32_vfs.asm)
arg_entry:   db "--entry", 0
arg_trace:   db "--trace", 0
arg_hold:    db "--hold", 0
arg_frames:  db "--frames=", 0
arg_shot:    db "--shot=", 0
arg_keys:    db "--keys=", 0
arg_window:  db "--window=", 0
msg_bad_window: db "--window=WxH: expected e.g. --window=1280x720 (320x240 .. 4096x4096)", 0
arg_audio_dump: db "--audio-dump=", 0
arg_config:  db "--config=", 0
s_wb:        db "wb", 0
s_opt_trace_input: db "--trace-input", 0
s_opt_input_test: db "--input-test", 0
s_opt_input_selftest: db "--input-selftest", 0
s_opt_bg_audio: db "--bg-audio", 0
align 8
arg_options:                        ; {name, byte flag}
    dq s_opt_trace_input, trace_input
    dq s_opt_input_test, input_test_on
    dq s_opt_input_selftest, input_selftest
    dq s_opt_bg_audio, aud_bg_audio
    dq 0
prot_names:  db "---", 0, "r--", 0, "-w-", 0, "rw-", 0, "--x", 0, "r-x", 0, "-wx", 0, "rwx", 0
str_pass:    db "PASS", 0
str_fail:    db "FAIL", 0

fmt_file:    db "loader: read gta2.ebin from %s (%lld bytes at offset 0x%llx)", 10, 0
fmt_pe:      db "PE32 i386: ImageBase=0x%x SizeOfImage=0x%x entry=0x%x sections=%d", 10, 0
fmt_sec:     db "  map %-8.8s 0x%06x-0x%06x (VirtualSize end)  copied 0x%06x raw, zeroed tail 0x%06x", 10, 0
fmt_low:     db "low region 0x%x-0x%x (rwx: thunks, stubs, TEB, 32-bit stack); code32 sel 0x%x, fs sel 0x%x -> TEB 0x%x", 10, 0
fmt_dll:     db "  %-14s %3d imports, IAT 0x%x", 10, 0
fmt_imports: db "imports: %d DLLs, %d IAT slots patched with stubs at 0x%x", 10, 0
fmt_prot:    db "  protect %-8.8s %s", 10, 0
fmt_test:    db "  [%s] 0x%06x %s -> 0x%llx (expected 0x%llx)", 10, 0
fmt_summary: db "functions: %d/%d checks passed", 10, 0
fmt_entry:   db "--entry: jumping to the PE entry point 0x%x", 10, 0
fmt_entry_ret: db "entry point returned 0x%x without touching an import (?)", 10, 0
fmt_unimpl:  db "unimplemented import %s!%s (called from 0x%x)", 10, 0
fmt_unimpl_ord: db "unimplemented import %s!#%u (called from 0x%x)", 10, 0
fmt_crash:   db "loader: signal %d, addr %p, rip 0x%llx cs 0x%llx rsp 0x%llx", 10, 0
fmt_fail:    db "loader: FAIL: %s", 10, 0
msg_calls:   db "calling original gta2.exe functions in 32-bit mode:", 0
msg_ok:      db "ALL OK", 0
s_image:     db "gta2.ebin", 0
msg_no_image: db "data.pak has no gta2.ebin", 0
msg_read:    db "read", 0
msg_bad_pe:  db "not a PE32 i386 image this loader understands", 0
msg_bad_base: db "ImageBase is not 0x3F0000 (no relocations: cannot rebase)", 0
msg_bad_mmap: db "mmap at 0x3F0000 did not get exactly that address", 0
msg_low_mmap: db "mmap of the low region did not get exactly LOW_BASE", 0
msg_ldt:     db "i386_set_ldt", 0
msg_too_many: db "more imports than MAX_IMPORTS", 0
msg_mprotect: db "mprotect", 0

align 8
sel32:       dw 0
sel64:       dw 0
run_entry:   db 0
trace:       db 0
hold:        db 0                   ; --hold: keep the SDL window up 5 s when we stop

section .text
%include "w32_core.asm"
%include "c_bridge.asm"            ; symbols shared with host/c/*.c
%include "w32_kernel32.asm"
%include "w32_files.asm"
%include "w32_vfs.asm"
%include "w32_locale.asm"
%include "w32_user32.asm"
%include "w32_advapi32.asm"
%include "config.asm"
%include "w32_misc.asm"
%include "w32_dinput.asm"
%include "w32_hooks.asm"
%include "debug_menu.asm"
%include "menu_modules.inc"        ; host/menu/*.asm, generated by build.sh
%include "debug_paths.asm"
%include "debug_roads.asm"
%include "player_move.asm"
%include "mods.asm"
%include "debug_roadblocks.asm"
%include "debug_emergency.asm"
%include "w32_renderer.asm"
%include "w32_audio.asm"
%include "w32_tables.asm"

section .rodata

section .bss
alignb 8
file:        resq 1
file_size:   resq 1
nt:          resq 1
exe_path:    resq 1
win_arg_end: resq 1                 ; --window: strtol end pointer
sa_handler:  resq 1                 ; struct sigaction (macOS): handler, mask, flags
sa_mask:     resd 1
sa_flags:    resd 1
cur_vsize:   resd 1
cur_copy:    resd 1
cur_tail:    resd 1
n_imports:   resd 1
n_dlls:      resd 1
imp_dll:     resq MAX_IMPORTS
imp_name:    resq MAX_IMPORTS
imp_ord:     resd MAX_IMPORTS
