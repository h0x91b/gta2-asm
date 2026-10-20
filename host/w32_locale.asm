; w32_locale.asm — KERNEL32 code page / locale / string shims. The ANSI code page is
; reported as 1252 and implemented as Latin-1 (identical except 0x80-0x9F, which GTA2's
; ASCII text never uses); there is no real locale data: one US-English locale.

ERROR_INSUFFICIENT_BUFFER equ 122
LCMAP_LOWERCASE equ 0x100
LCMAP_UPPERCASE equ 0x200
NORM_IGNORECASE equ 1

section .text

k32_GetACP:
    mov eax, 1252
    ret
k32_GetOEMCP:
    mov eax, 437
    ret

k32_GetCPInfo:                      ; (cp, CPINFO*): single-byte, default char '?'
    mov eax, [rdi + 4]
    mov dword [rax], 1              ; MaxCharSize
    mov word [rax + 4], '?'         ; DefaultChar[2]
    xor ecx, ecx
    mov [rax + 6], rcx              ; LeadByte[12]: no DBCS ranges
    mov [rax + 12], ecx
    mov [rax + 16], cx
    mov eax, 1
    ret

; ecx = cstrlen_n(rsi = string, ecx = n): n, or strlen+1 when n == -1 (bytes)
len_a:
    cmp ecx, -1
    jne .r
    xor ecx, ecx
.l:
    cmp byte [rsi + rcx], 0
    lea ecx, [rcx + 1]
    jne .l
.r:
    ret
; same for UTF-16 (count of WCHARs incl. the terminator)
len_w:
    cmp ecx, -1
    jne .r
    xor ecx, ecx
.l:
    cmp word [rsi + rcx*2], 0
    lea ecx, [rcx + 1]
    jne .l
.r:
    ret

k32_MultiByteToWideChar:            ; (cp, flags, src, srclen, dst, dstlen)
    mov esi, [rdi + 8]
    mov ecx, [rdi + 12]
    call len_a
    mov r8d, [rdi + 16]
    mov r9d, [rdi + 20]
    test r9d, r9d
    jz .size
    cmp r9d, ecx
    jb .small
    xor edx, edx
.c:
    cmp edx, ecx
    jae .size
    movzx eax, byte [rsi + rdx]
    mov [r8 + rdx*2], ax
    inc edx
    jmp .c
.size:
    mov eax, ecx
    ret
.small:
    mov dword [last_error], ERROR_INSUFFICIENT_BUFFER
    xor eax, eax
    ret

k32_WideCharToMultiByte:            ; (cp, flags, src, srclen, dst, dstlen, defchar, used*)
    mov esi, [rdi + 8]
    mov ecx, [rdi + 12]
    call len_w
    mov r8d, [rdi + 16]
    mov r9d, [rdi + 20]
    test r9d, r9d
    jz .size
    cmp r9d, ecx
    jb .small
    xor edx, edx
.c:
    cmp edx, ecx
    jae .size
    movzx eax, word [rsi + rdx*2]
    cmp eax, 0xFF
    jbe .ok
    mov eax, '?'
.ok:
    mov [r8 + rdx], al
    inc edx
    jmp .c
.size:
    mov eax, [rdi + 28]             ; lpUsedDefaultChar
    test eax, eax
    jz .r
    mov dword [rax], 0
.r:
    mov eax, ecx
    ret
.small:
    mov dword [last_error], ERROR_INSUFFICIENT_BUFFER
    xor eax, eax
    ret

; eax = ctype1(eax = Latin-1 code point) -> C1_* flags
ctype1:
    cmp eax, 0xFF
    ja .none
    lea r11, [ctype1_table]         ; callers keep their count in ecx
    movzx eax, word [r11 + rax*2]
    ret
.none:
    xor eax, eax
    ret

; GetStringTypeW(type, src, n, WORD* out); only CT_CTYPE1 has data, others are zero
k32_GetStringTypeW:
    mov r9d, [rdi]
    mov esi, [rdi + 4]
    mov ecx, [rdi + 8]
    call len_w
    mov r8d, [rdi + 12]
    xor edx, edx
.c:
    cmp edx, ecx
    jae .done
    movzx eax, word [rsi + rdx*2]
    call ctype1
    cmp r9d, 1
    je .st
    xor eax, eax
.st:
    mov [r8 + rdx*2], ax
    inc edx
    jmp .c
.done:
    mov eax, 1
    ret

; GetStringTypeA(lcid, type, src, n, WORD* out)
k32_GetStringTypeA:
    mov r9d, [rdi + 4]
    mov esi, [rdi + 8]
    mov ecx, [rdi + 12]
    call len_a
    mov r8d, [rdi + 16]
    xor edx, edx
.c:
    cmp edx, ecx
    jae .done
    movzx eax, byte [rsi + rdx]
    call ctype1
    cmp r9d, 1
    je .st
    xor eax, eax
.st:
    mov [r8 + rdx*2], ax
    inc edx
    jmp .c
.done:
    mov eax, 1
    ret

; eax = map_case(eax = char, r10d = LCMAP flags)
map_case:
    test r10d, LCMAP_LOWERCASE
    jz .up
    cmp eax, 'A'
    jb .r
    cmp eax, 'Z'
    jbe .add
    cmp eax, 0xC0                   ; Latin-1 capitals (not 0xD7)
    jb .r
    cmp eax, 0xDE
    ja .r
    cmp eax, 0xD7
    je .r
.add:
    add eax, 0x20
    ret
.up:
    test r10d, LCMAP_UPPERCASE
    jz .r
    cmp eax, 'a'
    jb .r
    cmp eax, 'z'
    jbe .sub
    cmp eax, 0xE0
    jb .r
    cmp eax, 0xFE
    ja .r
    cmp eax, 0xF7
    je .r
.sub:
    sub eax, 0x20
.r:
    ret

k32_LCMapStringA:                   ; (lcid, flags, src, n, dst, dstn)
    mov r10d, [rdi + 4]
    mov esi, [rdi + 8]
    mov ecx, [rdi + 12]
    call len_a
    mov r8d, [rdi + 16]
    mov r9d, [rdi + 20]
    test r9d, r9d
    jz .size
    cmp r9d, ecx
    jb .small
    xor edx, edx
.c:
    cmp edx, ecx
    jae .size
    movzx eax, byte [rsi + rdx]
    call map_case
    mov [r8 + rdx], al
    inc edx
    jmp .c
.size:
    mov eax, ecx
    ret
.small:
    mov dword [last_error], ERROR_INSUFFICIENT_BUFFER
    xor eax, eax
    ret

k32_LCMapStringW:                   ; (lcid, flags, src, n, dst, dstn)
    mov r10d, [rdi + 4]
    mov esi, [rdi + 8]
    mov ecx, [rdi + 12]
    call len_w
    mov r8d, [rdi + 16]
    mov r9d, [rdi + 20]
    test r9d, r9d
    jz .size
    cmp r9d, ecx
    jb .small
    xor edx, edx
.c:
    cmp edx, ecx
    jae .size
    movzx eax, word [rsi + rdx*2]
    call map_case
    mov [r8 + rdx*2], ax
    inc edx
    jmp .c
.size:
    mov eax, ecx
    ret
.small:
    mov dword [last_error], ERROR_INSUFFICIENT_BUFFER
    xor eax, eax
    ret

; CompareStringA/W(lcid, flags, s1, n1, s2, n2) -> CSTR_LESS_THAN 1 / EQUAL 2 / GREATER 3.
; Ordinal comparison (optionally case-folded); n = -1 means NUL-terminated (the
; terminator is not compared).
%macro COMPARE_STRING 2             ; len_fn, load (byte/word)
    push rbx
    mov r10d, [rdi + 4]
    and r10d, NORM_IGNORECASE
    shl r10d, 8                     ; -> LCMAP_LOWERCASE for map_case
    mov esi, [rdi + 8]
    mov ecx, [rdi + 12]
    mov r11d, ecx
    call %1
    cmp r11d, -1
    jne %%n1
    dec ecx
%%n1:
    mov r8, rsi
    mov r9d, ecx                    ; n1
    mov esi, [rdi + 16]
    mov ecx, [rdi + 20]
    mov r11d, ecx
    call %1
    cmp r11d, -1
    jne %%n2
    dec ecx
%%n2:
    xor edx, edx
%%loop:
    cmp edx, r9d
    jae %%end1
    cmp edx, ecx
    jae %%greater
  %ifidn %2, byte
    movzx eax, byte [r8 + rdx]
  %else
    movzx eax, word [r8 + rdx*2]
  %endif
    call map_case
    mov ebx, eax
  %ifidn %2, byte
    movzx eax, byte [rsi + rdx]
  %else
    movzx eax, word [rsi + rdx*2]
  %endif
    call map_case
    cmp ebx, eax
    jb %%less
    ja %%greater
    inc edx
    jmp %%loop
%%end1:
    cmp edx, ecx
    jb %%less
    mov eax, 2
    pop rbx
    ret
%%less:
    mov eax, 1
    pop rbx
    ret
%%greater:
    mov eax, 3
    pop rbx
    ret
%endmacro

k32_CompareStringA:
    COMPARE_STRING len_a, byte
k32_CompareStringW:
    COMPARE_STRING len_w, word

; GetLocaleInfoA(lcid, type, buf, n): a handful of US-English answers
k32_GetLocaleInfoA:
    HENTER
    mov eax, ARG(1)
    and eax, 0x0FFFFFFF             ; drop LOCALE_NOUSEROVERRIDE & co
    lea r12, [locale_info]
.scan:
    mov ecx, [r12]
    test ecx, ecx
    jz .unknown
    cmp ecx, eax
    je .found
    add r12, 16
    jmp .scan
.found:
    mov rdi, [r12 + 8]
    call _strlen
    lea r13d, [rax + 1]
    mov ecx, ARG(3)
    test ecx, ecx
    jz .size
    cmp ecx, r13d
    jb .small
    mov edi, ARG(2)
    mov rsi, [r12 + 8]
    call _strcpy
.size:
    mov eax, r13d
    HRET
.small:
    mov dword [last_error], ERROR_INSUFFICIENT_BUFFER
    xor eax, eax
    HRET
.unknown:
    lea rdi, [fmt_locale]
    mov esi, ARG(1)
    xor eax, eax
    call _printf
    xor eax, eax
    HRET

section .data
align 8
locale_info:                        ; {u32 LCTYPE, pad, char* value}
%macro LOCINFO 2
    dd %1, 0
    dq %%s
section .rodata
%%s: db %2, 0
section .data
%endmacro
    LOCINFO 0x0001, "0409"          ; LOCALE_ILANGUAGE
    LOCINFO 0x0003, "ENU"           ; LOCALE_SABBREVLANGNAME
    LOCINFO 0x0007, "USA"           ; LOCALE_SABBREVCTRYNAME
    LOCINFO 0x000B, "437"           ; LOCALE_IDEFAULTCODEPAGE
    LOCINFO 0x000E, "."             ; LOCALE_SDECIMAL
    LOCINFO 0x000F, ","             ; LOCALE_STHOUSAND
    LOCINFO 0x0010, "3;0"           ; LOCALE_SGROUPING
    LOCINFO 0x0014, "$"             ; LOCALE_SCURRENCY
    LOCINFO 0x0015, "."             ; LOCALE_SMONDECIMALSEP
    LOCINFO 0x0016, ","             ; LOCALE_SMONTHOUSANDSEP
    LOCINFO 0x0018, "3;0"           ; LOCALE_SMONGROUPING
    LOCINFO 0x0059, "en"            ; LOCALE_SISO639LANGNAME
    LOCINFO 0x005A, "US"            ; LOCALE_SISO3166CTRYNAME
    LOCINFO 0x1001, "English"       ; LOCALE_SENGLANGUAGE
    LOCINFO 0x1002, "United States" ; LOCALE_SENGCOUNTRY
    LOCINFO 0x1004, "1252"          ; LOCALE_IDEFAULTANSICODEPAGE
    dd 0, 0
    dq 0

shimtab_kernel32_locale:
    dq s_kernel32
    SHIM "GetACP", 0, k32_GetACP
    SHIM "GetOEMCP", 0, k32_GetOEMCP
    SHIM "GetCPInfo", 8, k32_GetCPInfo
    SHIM "MultiByteToWideChar", 24, k32_MultiByteToWideChar
    SHIM "WideCharToMultiByte", 32, k32_WideCharToMultiByte
    SHIM "GetStringTypeW", 16, k32_GetStringTypeW
    SHIM "GetStringTypeA", 20, k32_GetStringTypeA
    SHIM "LCMapStringA", 24, k32_LCMapStringA
    SHIM "LCMapStringW", 24, k32_LCMapStringW
    SHIM "CompareStringA", 24, k32_CompareStringA
    SHIM "CompareStringW", 24, k32_CompareStringW
    SHIM "GetLocaleInfoA", 16, k32_GetLocaleInfoA
    dq 0

section .rodata
fmt_locale: db "  [w32] GetLocaleInfoA(type 0x%x): no data -> 0", 10, 0
align 2
; C1_* flags for Latin-1: UPPER 1, LOWER 2, DIGIT 4, SPACE 8, PUNCT 0x10, CNTRL 0x20,
; BLANK 0x40, XDIGIT 0x80, ALPHA 0x100
ctype1_table:
%assign c 0
%rep 256
  %assign f 0
  %if c < 0x20 || (c >= 0x7F && c < 0xA0)
    %assign f 0x20
    %if c >= 9 && c <= 13
      %assign f f | 8
    %endif
    %if c == 9
      %assign f f | 0x40
    %endif
  %elif c == 0x20 || c == 0xA0
    %assign f 0x48
  %elif c >= '0' && c <= '9'
    %assign f 0x84
  %elif c >= 'A' && c <= 'Z'
    %assign f 0x101
    %if c <= 'F'
      %assign f f | 0x80
    %endif
  %elif c >= 'a' && c <= 'z'
    %assign f 0x102
    %if c <= 'f'
      %assign f f | 0x80
    %endif
  %elif c >= 0xC0 && c <= 0xDE && c != 0xD7
    %assign f 0x101
  %elif c >= 0xDF && c != 0xF7
    %assign f 0x102
  %else
    %assign f 0x10
  %endif
    dw f
  %assign c c + 1
%endrep
section .text
