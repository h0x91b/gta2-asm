; c_bridge.asm — the symbols shared between the NASM host and host/c/*.c (docs/host-c.md).
;
; NASM labels are file-local in Mach-O unless declared `global`; the C side binds to
; these with `extern T name NASM(name);` (host/c/game.h), so they keep their NASM names.
; C symbols carry Mach-O's leading underscore: NASM calls them as `_c_name`, like libc.
; Calls into C use the SysV x86-64 ABI: integer args in rdi, rsi, rdx, rcx, r8, r9,
; rsp 16-byte aligned at the `call`, rax/rcx/rdx/rsi/rdi/r8-r11 clobbered,
; rbx/rbp/r12-r15 kept. Every HENTER handler already has that alignment.

global call32                       ; loader.asm: C -> 32-bit game code (game.h)
global r_frames                     ; w32_renderer.asm: presented frames

extern _c_on_driver_enter           ; c/car_bonus.c
extern _c_cfg_mods
extern _c_carbonus_change
extern _c_carbonus_fmt
