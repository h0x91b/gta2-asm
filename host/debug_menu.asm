; debug_menu.asm — the NASM glue of the K menu (in-game debug menu). The menu itself is
; 64-bit host C (host/c/menu/, docs/debug-menu.md); this keeps what has to be NASM:
;
; - the DrawUI / pause-overlay call hooks (CALLHOOK handlers, w32_hooks.asm),
; - entry points with the register contracts the NASM callers were written against
;   (dbgmenu_key for input_key, dm_player_ped, dm_call_car), each a thin shim into C,
; - dm_cb, through which C calls functions that may be NASM (DM_FRAME hooks, DM_VALUE
;   change / format, DM_ACTION, low_alloc, input_release_all),
; - the record macros (DM_ITEM, DM_FRAME, DMVALUE) and constants the not-yet-ported
;   feature modules (debug_paths/roads/roadblocks/emergency.asm, player_move.asm) use to
;   register their rows and frame hooks. The records have the layout of host/c/menu/dm.h
;   (struct dm_item, struct dm_frame) and land in the same linker sets as the C ones.

DM_ACTION  equ 0                    ; item kinds (dm.h): data = fn, run on the game's side
DM_FLAG    equ 2                    ; data = a byte toggled 0 / 1
DM_VALUE   equ 6                    ; data = {change(rdi = item, esi = dir), format(rdi = text end)}
DM_TOAST_FRAMES equ 120

; shared game offsets the feature modules use (gta2-seuko-mod src/game/gta2.h @25b1985,
; re/gta2_types.h)
PED_CAR      equ 0x16c
PED_GAMEOBJ  equ 0x168              ; PedGameObject*, sprite at +0x80
PED_OCC      equ 0x240
CAR_SPRITE   equ 0x50
CAR_ID       equ 0x6c
; MainCamera, WindowedWidth: gta2-seuko-mod src/game/memory.h @25b1985
UI_CAMERA  equ 0x5E3CC4             ; Camera* (main), uiScale at +0xa8
WINDOW_W   equ 0x673578

; DM_ITEM page, order, kind, "label", data: one row of a page (struct dm_item)
%macro DM_ITEM 5
[section __DATA,__dm_items data align=8]
    dq %1
    dd %2, %3
    dq %%l, %5
[section .rodata]
%%l: db %4, 0
__SECT__
%endmacro
; DM_FRAME order, fn: fn() once per gameplay frame on the game's side, before the HUD,
; lowest order first, whether the menu is open or not (struct dm_frame)
%macro DM_FRAME 2
[section __DATA,__dm_frame data align=8]
    dd %1, 0
    dq %2
__SECT__
%endmacro
; DMVALUE name: a DM_VALUE item's {change, format} pair, dmv_name
%macro DMVALUE 1
align 8
dmv_%1: dq dm_%1_change, dm_%1_fmt
%endmacro

; host/c/menu: pages and data under their NASM names (dm.h)
extern dmp_root, dmp_player, dmp_vehicle, dmp_spawn, dmp_flags
extern dm_toast, dm_toast_left, dm_paused
extern dm_model, dm_spawnable, dm_last_car, dm_last_car_id
extern s_dm_noplayer2, fmt_dm_int
extern _dm_key, _dm_on_drawui, _dm_player_pair

section .text

; eax = dbgmenu_key(edi = DIK, esi = down): called first by input_key; 1 = consumed
; (dm_key, core.c)
dbgmenu_key:
    push rbp
    mov rbp, rsp
    and rsp, -16
    call _dm_key
    leave
    ret

; eax = dm_player_ped(): the player's Ped*, or 0; ecx = the Player*. Every other register
; is kept (the NASM callers rely on it).
dm_player_ped:
    push rbp
    mov rbp, rsp
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    and rsp, -16
    call _dm_player_pair            ; rax = Ped*, rdx = Player*
    mov ecx, edx
    lea rsp, [rbp - 56]
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbp
    ret

; dm_call_car(edi = fastcall function taking only ecx = car, esi = car)
dm_call_car:
    sub rsp, 8
    mov r8d, esi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r9d, r9d
    call call32
    add rsp, 8
    ret

; rax = dm_cb(rdi = fn, rsi = a, rdx = b): fn(a, b) with rbx, rbp, r12-r15 kept and the
; stack aligned whatever fn does with them, so C can call a NASM callback written for a
; NASM caller
dm_cb:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    and rsp, -16
    mov rax, rdi
    mov rdi, rsi
    mov rsi, rdx
    call rax
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; DrawUI(this) @0x4CA440, fastcall, no stack arguments: the HUD, called at 0x45A61F once
; per gameplay frame (ecx = [0x672F40]). dm_on_drawui (core.c) runs the DM_FRAME hooks and
; the deferred menu actions, the original, then the menu.
hk_DrawUI:
    HENTER
    mov edi, [abs G_ECX]
    call _dm_on_drawui
    HRET

; Hud_PauseOverlay_Draw @0x4C9FA0, stdcall(void), called by DrawUI at 0x4CA4F9 while the
; game is paused (re/comments.csv): skipped while the pause is the menu's (core.c
; dm_pause_sync)
hk_PauseOverlay:
    HENTER
    cmp byte [dm_paused], 0
    jne .out
    mov edi, 0x4C9FA0
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
.out:
    HRET

section .data
align 8
f_dm_rot2rad:  dq 0x3F71DF46A2529D39 ; 2*pi / 1440 (Sprite.rotation units; debug_paths, roadblocks)
section .text
