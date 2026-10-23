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
global r_save_shot                  ; w32_renderer.asm: --shot's BMP writer (gta2ctl shot)
global r_shot_path
global key_table                    ; w32_dinput.asm: --keys names (gta2ctl key)
global input_push_key
global input_mouse_motion           ; w32_dinput.asm (gta2ctl mouse)
global have_focus

extern _ctl_autopilot_ticks
extern _ctl_autopilot_ped           ; host/c/ctl_game.c: the player driven by drive_to, or 0
extern _ctl_arg, _ctl_init, _ctl_frame, _ctl_exit, _ctl_brief_text, _ctl_find_route   ; host/c/ctl.c (docs/gta2ctl.md)
; host/c/menu (the K menu, docs/debug-menu.md); its own externs are in debug_menu.asm
global dm_cb                        ; debug_menu.asm: C -> a callback that may be NASM
global cam_zoom_pct                 ; w32_hooks.asm: the camera zoom the menu changes
global input_release_all           ; w32_dinput.asm
global low_alloc                    ; w32_core.asm: memory below 4 GB


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
global di_keys                      ; w32_dinput.asm: keyboard state (c32_host.c)
global mouse_dx, take_axis, mouse_capture_on, mouse_capture_off, dik_str ; w32_dinput.asm:
                                    ; the mouse for c32_host.c (on-foot mouse turning)

; mss32 on SDL3 audio (c/audio.c, audio_wav.c); its import table is w32_mss32.asm
extern _setup_audio, _audio_dump_open, _audio_pump, _audio_focus, _aud_bg_audio
global sdl_lib                      ; w32_user32.asm: the dlopen'ed SDL3
global focus_poll                   ; w32_user32.asm: polls the window focus -> _audio_focus
global vfs_load                     ; w32_vfs.asm: a whole game file (overlay, then pak)
global heap_alloc, heap_free        ; w32_core.asm: low-memory heap (AIL_mem_alloc_lock)
