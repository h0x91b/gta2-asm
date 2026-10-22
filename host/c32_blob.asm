; c32_blob.asm — the C32 image (host/c32/, docs/c32.md) embedded in the loader, and the
; host services it imports. build.sh links host/c32/*.c into c32/c32.bin first; c32_load
; (c/c32_host.c) maps it at the address in its header.

global c32_blob, c32_blob_end
global new_slot                     ; loader.asm, for c32_load's service stubs

extern _c32_load                    ; c/c32_host.c
extern _c32_svc_log
extern _c32_carbonus_change
extern _c32_carbonus_fmt

section .rodata
align 16
c32_blob:
    incbin "c32/c32.bin"
c32_blob_end:

section .data
align 8
; "c32!<name>": the services an image's import table (rt.c) asks for
shimtab_c32:
    dq s_c32
    SHIM "log", 4, _c32_svc_log     ; void __stdcall log(const char *text)
    dq 0

section .rodata
s_c32: db "c32", 0
section .text
