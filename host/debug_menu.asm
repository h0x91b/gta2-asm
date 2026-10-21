; debug_menu.asm — our in-game debug menu: K opens it in gameplay, drawn with the game's
; own font (DrawGTAText) over the HUD from the DrawUI call hook (w32_hooks.asm).
;
;   K / ESC          open / close (ESC does not reach the game while the menu is open)
;   UP / DOWN        select, RETURN or LEFT / RIGHT change the item
;
; While the menu is open every key press goes to it, not to the game; keys held when it
; opens are released, so the player stops. Key releases always reach the game.
; Items: quick save (seuko-mod #37), all weapons, +$100000, camera zoom (camera.zoom, live), a few of the game's
; debug flags (written straight into their bytes, which HiddenDebugFlags 0x451930 filled
; from the registry at startup; the game reads them as it goes).
;
; Layout is in 640x480 units, scaled by the main camera's uiScale like the game's HUD.
; Text: DrawGTAText @0x4CC100, stdcall(wchar_t* str, SCR_f x, SCR_f y, short font,
; SCR_f scale, PALETTE_BASE* pal, int remap, int invisibility, SCR_f ?), ret 0x24; the
; default font id is at 0x672F24. Box: DrawFlatRect2D @0x474110, stdcall(float x1, y1,
; x2, y2, u32 argb), ret 0x14. Calls and addresses from gta2-seuko-mod by izawartka
; (https://github.com/izawartka/gta2-seuko-mod), src/game/functions.h, memory.h,
; src/modules/ui/components/text.cpp @25b1985.

DIK_ESCAPE equ 0x01
DIK_RETURN equ 0x1C
DIK_K      equ 0x25
DIK_NUMPADENTER equ 0x9C
DIK_UP     equ 0xC8
DIK_LEFT   equ 0xCB
DIK_RIGHT  equ 0xCD
DIK_DOWN   equ 0xD0

DM_ACTION  equ 0                    ; item kinds
DM_ZOOM    equ 1
DM_FLAG    equ 2                    ; data = address of the game's debug flag byte
DM_CLOSE   equ 3
DMA_SAVE    equ 1                   ; DM_ACTION data: what hk_DrawUI does
DMA_WEAPONS equ 2
DMA_MONEY   equ 3

DM_X       equ 16                   ; 640x480 layout
DM_Y       equ 104                  ; below the HUD bars
DM_W       equ 200                  ; fits "Show camera info: off"
DM_LINE    equ 17
DM_PAD     equ 6
DM_TEXT_SCALE equ 0x3000            ; 0.75 (SCR_f, 14 fraction bits)
DM_LINES   equ 24                   ; low line buffers
DM_WCHARS  equ 64
DM_TOAST_FRAMES equ 120

UI_CAMERA  equ 0x5E3CC4             ; Camera* (main), uiScale at +0xa8
FONT_ID    equ 0x672F24
WINDOW_W   equ 0x673578

section .text

; eax = dbgmenu_key(edi = DIK, esi = down): called first by input_key; 1 = consumed
dbgmenu_key:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    mov r12d, esi
    call dm_in_gameplay
    test eax, eax
    jnz .game
    mov byte [dm_open], 0           ; left gameplay with the menu open
    jmp .pass
.game:
    test r12d, r12d
    jz .pass                        ; releases always reach the game
    cmp byte [dm_open], 0
    jne .menu
    cmp ebx, DIK_K
    jne .pass
    mov byte [dm_open], 1
    call input_release_all          ; the player stops; ups pass through us
    jmp .eat
.menu:
    cmp ebx, DIK_K
    je .close
    cmp ebx, DIK_ESCAPE
    je .close
    cmp ebx, DIK_UP
    je .up
    cmp ebx, DIK_DOWN
    je .down
    cmp ebx, DIK_LEFT
    je .left
    cmp ebx, DIK_RIGHT
    je .right
    cmp ebx, DIK_RETURN
    je .enter
    cmp ebx, DIK_NUMPADENTER
    je .enter
    jmp .eat
.close:
    mov byte [dm_open], 0
    jmp .eat
.up:
    mov eax, [dm_sel]
    dec eax
    jns .sel
    mov eax, DM_NITEMS - 1
    jmp .sel
.down:
    mov eax, [dm_sel]
    inc eax
    cmp eax, DM_NITEMS
    jb .sel
    xor eax, eax
.sel:
    mov [dm_sel], eax
    jmp .eat
.left:
    mov esi, -1
    jmp .change
.right:
    mov esi, 1
    jmp .change
.enter:
    xor esi, esi
.change:
    mov edi, [dm_sel]
    call dm_change
.eat:
    mov eax, 1
    jmp .out
.pass:
    xor eax, eax
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; eax = dm_in_gameplay(): the game drew its HUD (DrawUI) within the last few frames
dm_in_gameplay:
    xor eax, eax
    cmp byte [dm_ui_seen], 0
    je .out
    mov ecx, [r_frames]
    sub ecx, [dm_ui_frame]
    cmp ecx, 3
    setb al
.out:
    ret

; dm_change(edi = item, esi = -1 left / +1 right / 0 enter)
dm_change:
    imul eax, edi, DMI_SIZE
    lea rcx, [dm_items]
    add rcx, rax
    mov eax, [rcx + DMI_KIND]
    cmp eax, DM_CLOSE
    je .close
    cmp eax, DM_ACTION
    je .action
    cmp eax, DM_ZOOM
    je .zoom
    mov rdx, [rcx + DMI_DATA]       ; DM_FLAG: any key toggles
    xor byte [rdx], 1
    and byte [rdx], 1
    ret
.close:
    mov byte [dm_open], 0
    ret
.action:
    test esi, esi
    jnz .out
    mov eax, [rcx + DMI_DATA]
    mov [dm_action_req], al         ; done on the game's side, in hk_DrawUI
.out:
    ret
.zoom:
    mov eax, [cam_zoom_pct]
    test eax, eax
    jnz .z
    mov eax, 100
.z:
    test esi, esi
    jnz .zstep
    mov eax, 100                    ; RETURN: back to the game's own zoom
    jmp .zset
.zstep:
    imul esi, esi, 5
    add eax, esi
    cmp eax, ZOOM_MIN
    jge .zmin
    mov eax, ZOOM_MIN
.zmin:
    cmp eax, ZOOM_MAX
    jle .zset
    mov eax, ZOOM_MAX
.zset:
    mov [cam_zoom_pct], eax
    ret

; DrawUI(this) @0x4CA440, fastcall, no stack arguments: the HUD, called at 0x45A61F once
; per gameplay frame (ecx = [0x672F40]). We run the original, then draw the menu on top.
; Hook site from gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/events/draw-ui.cpp @25b1985.
hk_DrawUI:
    HENTER 16
    mov r12d, [abs G_ECX]
    mov eax, [r_frames]
    mov [dm_ui_frame], eax
    mov byte [dm_ui_seen], 1
    movzx r13d, byte [dm_action_req]
    mov byte [dm_action_req], 0
    cmp r13d, DMA_SAVE
    jne .a1
    call dm_quick_save
.a1:
    cmp r13d, DMA_WEAPONS
    jne .a2
    call dm_all_weapons
.a2:
    cmp r13d, DMA_MONEY
    jne .draw
    call dm_add_money
.draw:
    mov edi, 0x4CA440
    mov rsi, rbx
    xor edx, edx
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    call dm_draw
    HRET

; dm_quick_save: save the game where the player stands (seuko-mod
; src/modules/modmenu/utils/save-game.cpp): refused during a mission; SaveGame
; @0x47EF40 thiscall(S15_Script* = [0x6644BC]; char* file = Menu 0x5EC070 +0x300),
; ret 4. The player's position.y (Ped +0x1ac +4) is moved 1.0 back around the call as
; seuko does. Game* 0x5EB4FC +0x38 = current Player, Player +0x2c4 = Ped,
; S15 +0x344 = mission flag pointer.
dm_quick_save:
    push rbx
    push r12
    push r13
    sub rsp, 16
    lea r13, [s_dm_noplayer]
    mov eax, [abs 0x5EB4FC]
    test eax, eax
    jz .toast
    mov eax, [rax + 0x38]
    test eax, eax
    jz .toast
    mov ebx, [rax + 0x2c4]          ; Ped*
    test ebx, ebx
    jz .toast
    lea r13, [s_dm_nosave]
    mov r12d, [abs 0x6644BC]        ; S15_Script*
    test r12d, r12d
    jz .toast
    mov eax, [r12 + 0x344]
    test eax, eax
    jz .toast
    lea r13, [s_dm_mission]
    cmp byte [rax], 0
    jne .toast
    sub dword [rbx + 0x1b0], 0x4000
    mov dword [rsp], 0x5EC070 + 0x300
    mov edi, 0x47EF40
    mov rsi, rsp
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    add dword [rbx + 0x1b0], 0x4000
    lea r13, [s_dm_saved]
    lea rdi, [fmt_dm_saved]
    mov esi, 0x5EC070 + 0x300
    xor eax, eax
    call _printf
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; eax = dm_player_ped(): the player's Ped* (Game* 0x5EB4FC +0x38 = Player, +0x2c4), or 0;
; ecx = the Player*
dm_player_ped:
    xor eax, eax
    xor ecx, ecx
    mov edx, [abs 0x5EB4FC]
    test edx, edx
    jz .out
    mov ecx, [rdx + 0x38]
    test ecx, ecx
    jz .out
    mov eax, [rcx + 0x2c4]
.out:
    ret

; dm_all_weapons: AddWeapon @0x43E4B0, fastcall(Ped* ecx, edx = 0; weapon, ammo), ret 8,
; for weapons 0..14 with 99 ammo (seuko-mod src/modules/modmenu/utils/get-all-weapons.cpp)
dm_all_weapons:
    push rbx
    push r12
    push r13
    sub rsp, 16
    lea r13, [s_dm_noplayer2]
    call dm_player_ped
    test eax, eax
    jz .toast
    mov r12d, eax
    xor ebx, ebx
.w:
    mov [rsp], ebx
    mov dword [rsp + 4], 99
    mov edi, 0x43E4B0
    mov rsi, rsp
    mov edx, 2
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    inc ebx
    cmp ebx, 15
    jb .w
    lea r13, [s_dm_weapons]
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; dm_add_money: Player +0x2d4 = animatedMoney (SaveSlotAnimatedValue: value +0, max +0x30;
; seuko-mod src/modules/modmenu/menus/player-stats-menu.cpp), += DM_MONEY up to max
DM_MONEY equ 100000
dm_add_money:
    lea rax, [s_dm_noplayer2]
    call dm_player_ped
    test ecx, ecx
    jz .toast
    mov eax, [rcx + 0x2d4]
    add eax, DM_MONEY
    mov edx, [rcx + 0x2d4 + 0x30]
    test edx, edx
    jle .set                        ; no max set
    cmp eax, edx
    jbe .set
    mov eax, edx
.set:
    mov [rcx + 0x2d4], eax
    lea rax, [s_dm_money]
.toast:
    mov [dm_toast], rax
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    ret

; dm_draw: the menu (when open) and the toast line, in 640x480 units times uiScale
dm_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov eax, [abs UI_CAMERA]
    test eax, eax
    jz .out
    mov eax, [rax + 0xa8]           ; uiScale
    mov [dm_scale], eax
    cmp qword [dm_low], 0
    jne .have_low
    mov edi, DM_LINES * DM_WCHARS * 2 + 16
    mov esi, 16
    call low_alloc
    mov [dm_low], rax
.have_low:
    mov dword [dm_line_no], 0
    cmp byte [dm_open], 0
    je .toast
    ; box: DM_X..DM_X+DM_W, DM_Y..DM_Y + 2*pad + (title + items + 1) lines
    mov eax, DM_NITEMS + 1
    imul eax, eax, DM_LINE
    add eax, DM_Y + DM_LINE / 2 + DM_PAD
    mov edi, DM_X - DM_PAD
    mov esi, DM_Y - DM_PAD
    mov edx, DM_X + DM_W
    mov ecx, eax
    mov r8d, 0x80000000
    call dm_rect
    lea rdi, [s_dm_title]
    mov esi, DM_Y
    xor edx, edx
    call dm_text
    xor r12d, r12d                  ; item index
    mov r13d, DM_Y + DM_LINE + DM_LINE / 2
.item:
    cmp r12d, DM_NITEMS
    jae .toast
    imul eax, r12d, DMI_SIZE
    lea r14, [dm_items]
    add r14, rax
    lea rdi, [dm_buf]               ; "> " marker for the selection
    lea rsi, [s_dm_sel]
    lea rax, [s_dm_nosel]
    cmp r12d, [dm_sel]
    cmovne rsi, rax
    call _strcpy
    lea rdi, [dm_buf]
    mov rsi, [r14 + DMI_LABEL]
    call _strcat
    mov eax, [r14 + DMI_KIND]
    cmp eax, DM_ZOOM
    je .zoom
    cmp eax, DM_FLAG
    jne .print
    lea rdi, [dm_buf]
    lea rsi, [s_dm_on]
    lea rax, [s_dm_off]
    mov rcx, [r14 + DMI_DATA]
    cmp byte [rcx], 0
    cmove rsi, rax
    call _strcat
    jmp .print
.zoom:
    lea rdi, [dm_buf]
    call _strlen
    lea rdi, [dm_buf]
    add rdi, rax
    mov esi, 32
    lea rdx, [fmt_dm_zoom]
    mov ecx, [cam_zoom_pct]
    test ecx, ecx
    jnz .zp
    mov ecx, 100
.zp:
    xor eax, eax
    call _snprintf
.print:
    lea rdi, [dm_buf]
    mov esi, r13d
    xor edx, edx
    cmp r12d, [dm_sel]
    jne .p
    mov edx, 1
.p:
    call dm_text
    inc r12d
    add r13d, DM_LINE
    jmp .item
.toast:
    cmp dword [dm_toast_left], 0
    je .out
    dec dword [dm_toast_left]
    mov rdi, [dm_toast]
    mov esi, 480 - 3 * DM_LINE
    mov edx, 1
    call dm_text
.out:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dm_rect(edi = x1, esi = y1, edx = x2, ecx = y2 in 640x480 units, r8d = argb)
dm_rect:
    push rbx
    sub rsp, 32
    mov [rsp + 16], r8d
    mov ebx, ecx
    mov [rsp + 20], edx
    mov [rsp + 24], esi
    cvtsi2ss xmm1, dword [dm_scale]
    mulss xmm1, [f_dm_inv16384]
    cvtsi2ss xmm0, edi
    mulss xmm0, xmm1
    movss [rsp], xmm0
    cvtsi2ss xmm0, dword [rsp + 24]
    mulss xmm0, xmm1
    movss [rsp + 4], xmm0
    cvtsi2ss xmm0, dword [rsp + 20]
    mulss xmm0, xmm1
    movss [rsp + 8], xmm0
    cvtsi2ss xmm0, ebx
    mulss xmm0, xmm1
    movss [rsp + 12], xmm0
    mov edi, 0x474110
    mov rsi, rsp
    mov edx, 5
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    add rsp, 32
    pop rbx
    ret

; dm_text(rdi = ASCII string, esi = y in 640x480 units, edx = 1 highlighted) at DM_X.
; Each call gets its own low line buffer (UTF-16), in case the game keeps the pointer.
dm_text:
    push rbx
    push r12
    push r13
    sub rsp, 48
    mov r12d, esi
    mov r13d, edx
    mov eax, [dm_line_no]
    cmp eax, DM_LINES
    jae .out
    inc dword [dm_line_no]
    imul eax, eax, DM_WCHARS * 2
    mov rbx, [dm_low]
    add rbx, 16                     ; [dm_low] = PALETTE_BASE values
    add rbx, rax
    xor ecx, ecx
.w:
    movzx eax, byte [rdi + rcx]
    mov [rbx + rcx*2], ax
    test eax, eax
    jz .wd
    inc ecx
    cmp ecx, DM_WCHARS - 1
    jb .w
    mov word [rbx + rcx*2], 0
.wd:
    mov rax, [dm_low]
    mov dword [rax], 2              ; PALETTE_BASE_SPRITE
    mov dword [rax + 4], 8          ; PALETTE_BASE_FONT_REMAP
    mov [rsp], ebx                  ; str
    mov eax, DM_X
    imul eax, [dm_scale]
    mov [rsp + 4], eax              ; x
    mov eax, r12d
    imul eax, [dm_scale]
    mov [rsp + 8], eax              ; y
    movzx eax, word [abs FONT_ID]
    mov [rsp + 12], eax             ; font
    mov eax, [dm_scale]
    imul eax, eax, DM_TEXT_SCALE
    sar eax, 14
    mov [rsp + 16], eax             ; scale
    mov rax, [dm_low]
    mov [rsp + 20], eax             ; &PALETTE_BASE_SPRITE
    mov dword [rsp + 24], 0         ; remap
    test r13d, r13d
    jz .plain
    add dword [rsp + 20], 4         ; highlighted: font remap
    mov eax, [dm_hl_remap]
    mov [rsp + 24], eax
.plain:
    mov dword [rsp + 28], 0         ; SPRITE_INVISIBILITY_VISIBLE
    mov dword [rsp + 32], 1
    mov edi, 0x4CC100
    lea rsi, [rsp]
    mov edx, 9
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
.out:
    add rsp, 48
    pop r13
    pop r12
    pop rbx
    ret

section .data
align 8
DMI_KIND  equ 0
DMI_LABEL equ 8
DMI_DATA  equ 16
DMI_SIZE  equ 24
; DMITEM kind, "label", data
%macro DMITEM 3
    dq %1, %%l, %3
section .rodata
%%l: db %2, 0
section .data
%endmacro
; flag addresses: HiddenDebugFlags 0x451930 (each RegGet result is stored with
; `mov [addr], al`; own disassembly, 74 of 74 flags; matches seuko-mod's Cheats @0x5EAD51)
dm_items:
    DMITEM DM_ACTION, "Quick save", DMA_SAVE
    DMITEM DM_ACTION, "Get all weapons", DMA_WEAPONS
    DMITEM DM_ACTION, "Add $100000", DMA_MONEY
    DMITEM DM_ZOOM,   "Camera zoom: ", 0
    DMITEM DM_FLAG,   "Show FPS: ", 0x5EAD79                  ; do_show_timing
    DMITEM DM_FLAG,   "Show camera info: ", 0x5EAD82          ; do_show_camera
    DMITEM DM_FLAG,   "Show counters: ", 0x5EAD95             ; do_show_counters
    DMITEM DM_FLAG,   "Show all arrows: ", 0x5EADB2           ; show_all_arrows
    DMITEM DM_FLAG,   "Invulnerable: ", 0x5EAD71              ; do_invulnerable
    DMITEM DM_FLAG,   "Infinite lives: ", 0x5EAD61            ; do_infinite_lives
    DMITEM DM_FLAG,   "Keep weapons: ", 0x5EAD9E  ; keep_weapons_after_death
    DMITEM DM_FLAG,   "Free shopping: ", 0x5EAD84             ; do_free_shopping
    DMITEM DM_FLAG,   "No police: ", 0x5EAD5E                 ; skip_police
    DMITEM DM_CLOSE,  "Close", 0
DM_NITEMS equ ($ - dm_items) / DMI_SIZE

dm_hl_remap: dd 2                   ; font remap of the selected line: green (measured)
f_dm_inv16384: dd 0x38800000        ; 1/16384

section .rodata
s_dm_title:    db "Debug menu  (K)", 0
s_dm_sel:      db 0                ; the GTA font has no ">": colour marks the selection
s_dm_nosel:    db 0
s_dm_on:       db "on", 0
s_dm_off:      db "off", 0
fmt_dm_zoom:   db "%d%%", 0
s_dm_saved:    db "Game saved", 0
s_dm_mission:  db "Cannot save during a mission", 0
s_dm_noplayer: db "Cannot save: no player", 0
s_dm_nosave:   db "Cannot save here", 0
s_dm_noplayer2: db "No player", 0
s_dm_weapons:  db "Got all weapons", 0
s_dm_money:    db "Got $100000", 0     ; the font has no "+"
fmt_dm_saved:  db "menu: quick save -> %s", 10, 0

section .bss
dm_open:       resb 1
dm_ui_seen:    resb 1
dm_action_req: resb 1               ; DMA_* to run in hk_DrawUI, 0 = none
alignb 8
dm_low:        resq 1               ; low memory: 2 PALETTE_BASE dwords, then line buffers
dm_toast:      resq 1
dm_sel:        resd 1
dm_ui_frame:   resd 1
dm_scale:      resd 1
dm_line_no:    resd 1
dm_toast_left: resd 1
dm_buf:        resb 128
section .text
