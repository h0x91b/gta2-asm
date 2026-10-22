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


; host/c/config.c (config.yaml): called by loader.asm (--config=) and after the registry
; seed (w32_advapi32.asm); it reads and writes these
extern _cfg_set_path, _config_apply
extern cam_zoom_cfg                 ; camera.zoom (w32_hooks.asm), C storage, NASM name
ZOOM_AUTO   equ -1                  ; cam_zoom_cfg: auto, else percent ZOOM_MIN..ZOOM_MAX
ZOOM_MIN    equ 25                  ;   (the same numbers as in config.c)
ZOOM_MAX    equ 400
global reg_key_add, reg_val_find, reg_val_set   ; w32_advapi32.asm: the in-memory registry
global fail                         ; loader.asm
global key_table                    ; w32_dinput.asm: key names as in --keys
global pm_strafe_on, pm_mouse_on, pm_key_left, pm_key_right, pm_mouse_sens, pm_report
