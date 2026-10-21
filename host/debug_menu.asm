; debug_menu.asm — our in-game debug menu: K opens it in gameplay, drawn with the game's
; own font (DrawGTAText) over the HUD from the DrawUI call hook (w32_hooks.asm).
;
;   K / ESC          open / close (ESC does not reach the game while the menu is open)
;   UP / DOWN        select, RETURN or LEFT / RIGHT change the item
;
; While the menu is open every key press goes to it, not to the game; keys held when it
; opens are released, so the player stops. Key releases always reach the game.
; Pages: the main one (quick save, all weapons, +$100000, camera zoom) leads to Player
; (wanted level and its lock, skin), Vehicle (spawn a car; colour, repair, invincibility
; and explosion of the current or last car) and Debug flags (a few of the game's own,
; written straight into their bytes, which HiddenDebugFlags 0x451930 filled from the
; registry at startup; the game reads them as it goes). ESC goes back a page, K closes.
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
DM_PAGE    equ 4                    ; data = page (DMP_*) to open
DM_BACK    equ 5
DM_VALUE   equ 6                    ; data = {change(esi = dir), format(rdi = text end)}
DMA_SAVE    equ 1                   ; DM_ACTION data: what hk_DrawUI does
DMA_WEAPONS equ 2
DMA_MONEY   equ 3
DMA_SPAWN   equ 4
DMA_REPAIR  equ 5
DMA_EXPLODE equ 6

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
    je .esc
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
.esc:
    lea rax, [dmp_main]
    cmp [dm_page], rax
    je .close
    call dm_back
    jmp .eat
.close:
    mov byte [dm_open], 0
    jmp .eat
.up:
    mov rcx, [dm_page]
    mov eax, [dm_sel]
    dec eax
    jns .sel
    mov eax, [rcx + DMP_COUNT]
    dec eax
    jmp .sel
.down:
    mov rcx, [dm_page]
    mov eax, [dm_sel]
    inc eax
    cmp eax, [rcx + DMP_COUNT]
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

; dm_back: from a sub-page to the main page, on the item that opened it
dm_back:
    lea rax, [dmp_main]
    mov [dm_page], rax
    mov eax, [dm_main_sel]
    mov [dm_sel], eax
    ret

; dm_change(edi = item of the current page, esi = -1 left / +1 right / 0 enter)
dm_change:
    imul eax, edi, DMI_SIZE
    mov rcx, [dm_page]
    mov rcx, [rcx + DMP_ITEMS]
    add rcx, rax
    mov eax, [rcx + DMI_KIND]
    cmp eax, DM_CLOSE
    je .close
    cmp eax, DM_ACTION
    je .action
    cmp eax, DM_ZOOM
    je .zoom
    cmp eax, DM_PAGE
    je .page
    cmp eax, DM_BACK
    je dm_back
    cmp eax, DM_VALUE
    je .value
    mov rdx, [rcx + DMI_DATA]       ; DM_FLAG: any key toggles
    xor byte [rdx], 1
    and byte [rdx], 1
    ret
.close:
    mov byte [dm_open], 0
    ret
.page:
    test esi, esi
    jnz .out
    mov [dm_main_sel], edi
    mov rax, [rcx + DMI_DATA]
    mov [dm_page], rax
    mov dword [dm_sel], 0
    ret
.value:
    mov rax, [rcx + DMI_DATA]
    jmp [rax]                       ; change(esi = dir)
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
    call dm_tick
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
    jne .a3
    call dm_add_money
.a3:
    cmp r13d, DMA_SPAWN
    jne .a4
    call dm_spawn_car
.a4:
    cmp r13d, DMA_REPAIR
    jne .a5
    call dm_repair_car
.a5:
    cmp r13d, DMA_EXPLODE
    jne .draw
    call dm_explode_car
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

; ---- Player page. Ped fields (gta2-seuko-mod src/game/gta2.h @25b1985): copValue +0x20a
; (short; 1..6 stars from 600/1600/3000/5000/8000/12000, src/game/utils/cop-value-utils.cpp),
; remap +0x244 (byte, PED_REMAP, 255 = default), graphicType +0x26c (0 dummy, 1 gang,
; 2 emergency), currentCar +0x168+4. A lock or a chosen skin is re-applied every frame from
; dm_tick, as seuko's per-tick watches do (src/modules/modmenu/cheats/player-appearance.cpp).
PED_COPVALUE equ 0x20a
PED_REMAP    equ 0x244
PED_GTYPE    equ 0x26c
PED_CAR      equ 0x16c
PED_GAMEOBJ  equ 0x168              ; GameObject*, sprite at +0x80

; dm_tick: once per gameplay frame, before the HUD
dm_tick:
    call dm_player_ped
    test eax, eax
    jz .out
    cmp byte [dm_wanted_lock], 0
    je .skin
    mov dx, [dm_wanted_val]
    mov [rax + PED_COPVALUE], dx
.skin:
    mov edx, [dm_skin]
    test edx, edx
    js .body
    mov [rax + PED_REMAP], dl
.body:
    mov edx, [dm_body]
    test edx, edx
    js .car
    mov [rax + PED_GTYPE], edx
.car:
    mov edx, [rax + PED_CAR]        ; remember the car the player is in
    test edx, edx
    jz .out
    mov [dm_last_car], edx
    mov ecx, [rdx + CAR_ID]
    mov [dm_last_car_id], ecx
.out:
    ret

; eax = dm_stars(): the player's wanted level 0..6, -1 without a player
dm_stars:
    call dm_player_ped
    test eax, eax
    jz .none
    movsx edx, word [rax + PED_COPVALUE]
    xor eax, eax
.s:
    cmp eax, 6
    jae .out
    lea rcx, [dm_cop_values]
    movzx ecx, word [rcx + 2 + rax*2]
    cmp edx, ecx
    jl .out
    inc eax
    jmp .s
.none:
    mov eax, -1
.out:
    ret

dm_wanted_change:
    push rbx
    mov ebx, esi
    call dm_stars
    test eax, eax
    js .out
    add eax, ebx
    test ebx, ebx
    jnz .clamp
    xor eax, eax                    ; RETURN: no wanted level
.clamp:
    test eax, eax
    jns .c1
    xor eax, eax
.c1:
    cmp eax, 6
    jbe .set
    mov eax, 6
.set:
    lea rcx, [dm_cop_values]
    movzx ebx, word [rcx + rax*2]
    call dm_player_ped
    mov [rax + PED_COPVALUE], bx
    mov [dm_wanted_val], bx
.out:
    pop rbx
    ret

dm_wanted_fmt:
    push rbx
    mov rbx, rdi
    call dm_stars
    mov ecx, eax
    mov rdi, rbx
    mov esi, 32
    lea rdx, [fmt_dm_int]
    test ecx, ecx
    jns .p
    lea rdx, [s_dm_dash]
.p:
    xor eax, eax
    call _snprintf
    pop rbx
    ret

dm_wlock_change:
    xor byte [dm_wanted_lock], 1
    call dm_player_ped
    test eax, eax
    jz .out
    mov dx, [rax + PED_COPVALUE]
    mov [dm_wanted_val], dx
.out:
    ret

dm_wlock_fmt:
    lea rsi, [s_dm_on]
    lea rax, [s_dm_off]
    cmp byte [dm_wanted_lock], 0
    cmove rsi, rax
    jmp _strcpy

; skin: dm_skin_idx -1 = the game's own, 0 = 255 (PED_REMAP_DEFAULT), 1..53 = remap 0..52
; (seuko-mod lists-utils.cpp GetAvailablePedRemaps); dm_skin = the remap dm_tick applies
dm_skin_change:
    mov eax, [dm_skin_idx]
    add eax, esi
    test esi, esi
    jnz .w
    mov eax, -1                     ; RETURN: back to the game's own
.w:
    cmp eax, -1
    jge .hi
    mov eax, 53
.hi:
    cmp eax, 53
    jle .set
    mov eax, -1
.set:
    mov ecx, [dm_skin_idx]
    mov [dm_skin_idx], eax
    lea edx, [rax - 1]
    test eax, eax
    jnz .v
    mov edx, 255
.v:
    test eax, eax
    jns .v2
    mov edx, -1
.v2:
    mov [dm_skin], edx
    test ecx, ecx                   ; leaving the game's own: remember it
    jns .back
    test eax, eax
    js .out
    call dm_player_ped
    test eax, eax
    jz .out
    movzx ecx, byte [rax + PED_REMAP]
    mov [dm_skin_orig], ecx
    ret
.back:
    test eax, eax                   ; back to the game's own: restore it once
    jns .out
    call dm_player_ped
    test eax, eax
    jz .out
    mov ecx, [dm_skin_orig]
    mov [rax + PED_REMAP], cl
.out:
    ret

dm_skin_fmt:
    mov ecx, [dm_skin]
    test ecx, ecx
    jns .v
    lea rsi, [s_dm_game]
    jmp _strcpy
.v:
    cmp ecx, 255
    jne .n
    lea rsi, [s_dm_default]
    jmp _strcpy
.n:
    lea r8, [s_dm_ped]
    cmp ecx, DM_NREMAPNAMES
    jae .p
    lea rax, [dm_remap_names]
    mov r8, [rax + rcx*8]
.p:
    mov esi, 40
    lea rdx, [fmt_dm_skin]
    xor eax, eax
    jmp _snprintf

; body (graphicType): -1 (the game's own), 0..2
dm_body_change:
    mov eax, [dm_body]
    add eax, esi
    test esi, esi
    jnz .w
    mov eax, -1
.w:
    cmp eax, -1
    jge .hi
    mov eax, 2
.hi:
    cmp eax, 2
    jle .set
    mov eax, -1
.set:
    mov ecx, [dm_body]
    mov [dm_body], eax
    test ecx, ecx
    jns .back
    call dm_player_ped
    test eax, eax
    jz .out
    mov ecx, [rax + PED_GTYPE]
    mov [dm_body_orig], ecx
    ret
.back:
    cmp dword [dm_body], -1
    jne .out
    call dm_player_ped
    test eax, eax
    jz .out
    mov ecx, [dm_body_orig]
    mov [rax + PED_GTYPE], ecx
.out:
    ret

dm_body_fmt:
    movsxd rcx, dword [dm_body]
    lea rax, [dm_body_names]
    mov rsi, [rax + rcx*8 + 8]
    jmp _strcpy

; ---- Vehicle page. Car fields (seuko-mod src/game/gta2.h): deltasBitstate +0x8 (bits 0-4
; broken lights and windscreen), lastCar +0x4c, sprite +0x50 (Sprite: rotation +0 ushort,
; position +0x14, carColor +0x24, paletteBase +0x34), id +0x6c, carDamage +0x74,
; physicsBitmask +0x78, carModel +0x84, fireState +0x8c, engineState +0x9c (3 = on),
; lightsBitstate +0xa4 (1 brake lights, 2 lights). Repair, explode and spawn follow
; src/modules/modmenu/utils/fix-car-utils.cpp, explode-last-car.cpp, spawn-car.cpp.
CAR_DELTAS   equ 0x8
CAR_SPRITE   equ 0x50
CAR_ID       equ 0x6c
CAR_DAMAGE   equ 0x74
CAR_PHYSICS  equ 0x78
CAR_MODEL    equ 0x84
CAR_FIRE     equ 0x8c
CAR_ENGINE   equ 0x9c
CAR_LIGHTS   equ 0xa4
CAR_INVINCIBLE equ 0x708            ; NO_COLLISION_DAMAGE | BULLET-, ROCKET-, FLAMEPROOF

; eax = dm_car(): the car the player is in, else the last one while its id still matches
; (cars live in a fixed array, so a destroyed car's slot is reused with a new id), or 0;
; edx = 1 when the player is in it
dm_car:
    call dm_player_ped
    test eax, eax
    jz .last
    mov eax, [rax + PED_CAR]
    test eax, eax
    jz .last
    mov edx, 1
    ret
.last:
    xor edx, edx
    mov eax, [dm_last_car]
    test eax, eax
    jz .out
    mov ecx, [rax + CAR_ID]
    cmp ecx, [dm_last_car_id]
    jne .gone
    cmp dword [rax + CAR_SPRITE], 0
    jne .out
.gone:
    xor eax, eax
    mov [dm_last_car], eax
.out:
    ret

dm_carinfo_change:
    ret

dm_carinfo_fmt:
    push rbx
    mov rbx, rdi
    call dm_car
    test eax, eax
    jnz .car
    mov rdi, rbx
    lea rsi, [s_dm_nocar]
    call _strcpy
    jmp .out
.car:
    lea r8, [s_dm_current]
    lea rcx, [s_dm_last]
    test edx, edx
    cmovz r8, rcx
    mov eax, [rax + CAR_MODEL]
    lea rcx, [s_dm_dash]
    cmp eax, DM_NCARNAMES
    jae .p
    lea rcx, [dm_car_names]
    mov rcx, [rcx + rax*8]
.p:
    mov rdi, rbx
    mov esi, 48
    lea rdx, [fmt_dm_carinfo]
    xor eax, eax
    call _snprintf
.out:
    pop rbx
    ret

; colour: -1 = the model's own (paletteBase SPRITE, colour 0), 0..36 car remaps
; (seuko-mod src/game/utils/lists-utils.cpp GetAvailableCarRemapsWithPalette)
dm_color_change:
    push rbx
    mov ebx, esi
    call dm_car
    test eax, eax
    jz .out
    mov r8d, [rax + CAR_SPRITE]
    test r8d, r8d
    jz .out
    mov ecx, -1
    cmp dword [r8 + 0x34], 2
    je .c
    movsx ecx, word [r8 + 0x24]
.c:
    add ecx, ebx
    test ebx, ebx
    jnz .w
    mov ecx, -1
.w:
    cmp ecx, -1
    jge .hi
    mov ecx, 36
.hi:
    cmp ecx, 36
    jle .set
    mov ecx, -1
.set:
    mov dword [r8 + 0x34], 3        ; PALETTE_BASE_CAR_REMAP
    test ecx, ecx
    jns .s
    mov dword [r8 + 0x34], 2        ; PALETTE_BASE_SPRITE
    xor ecx, ecx
.s:
    mov [r8 + 0x24], cx
.out:
    pop rbx
    ret

dm_color_fmt:
    push rbx
    mov rbx, rdi
    call dm_car
    lea rsi, [s_dm_dash]
    test eax, eax
    jz .str
    mov r8d, [rax + CAR_SPRITE]
    test r8d, r8d
    jz .str
    lea rsi, [s_dm_default]
    cmp dword [r8 + 0x34], 2
    je .str
    movsx ecx, word [r8 + 0x24]
    mov rdi, rbx
    mov esi, 32
    lea rdx, [fmt_dm_int]
    xor eax, eax
    call _snprintf
    jmp .out
.str:
    mov rdi, rbx
    call _strcpy
.out:
    pop rbx
    ret

dm_invinc_change:
    call dm_car
    test eax, eax
    jz .out
    movzx ecx, word [rax + CAR_PHYSICS]
    mov edx, ecx
    and edx, CAR_INVINCIBLE
    cmp edx, CAR_INVINCIBLE
    je .off
    or ecx, CAR_INVINCIBLE
    jmp .set
.off:
    and ecx, ~CAR_INVINCIBLE
.set:
    mov [rax + CAR_PHYSICS], cx
.out:
    ret

dm_invinc_fmt:
    push rbx
    mov rbx, rdi
    call dm_car
    lea rsi, [s_dm_dash]
    test eax, eax
    jz .str
    lea rsi, [s_dm_off]
    movzx ecx, word [rax + CAR_PHYSICS]
    and ecx, CAR_INVINCIBLE
    cmp ecx, CAR_INVINCIBLE
    jne .str
    lea rsi, [s_dm_on]
.str:
    mov rdi, rbx
    call _strcpy
    pop rbx
    ret

; spawn model: index into dm_spawnable (seuko-mod lists-utils.cpp GetSpawnableCarModels)
dm_model_change:
    test esi, esi
    jnz .step
    mov byte [dm_action_req], DMA_SPAWN
    ret
.step:
    mov eax, [dm_model]
    add eax, esi
    jns .hi
    mov eax, DM_NSPAWNABLE - 1
.hi:
    cmp eax, DM_NSPAWNABLE
    jb .set
    xor eax, eax
.set:
    mov [dm_model], eax
    ret

dm_model_fmt:
    mov eax, [dm_model]
    lea rcx, [dm_spawnable]
    movzx eax, byte [rcx + rax]
    lea rcx, [dm_car_names]
    mov rsi, [rcx + rax*8]
    jmp _strcpy

dm_repair_change:
    test esi, esi
    jnz .out
    mov byte [dm_action_req], DMA_REPAIR
.out:
    ret

dm_explode_change:
    test esi, esi
    jnz .out
    mov byte [dm_action_req], DMA_EXPLODE
.out:
    ret

dm_repair_fmt:
dm_explode_fmt:
    mov byte [rdi], 0
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

; dm_spawn_car: SpawnCar @0x426AC0, fastcall(TrafficManager* ecx = [0x5E4CA4], edx = 0;
; SCR_f x, y, z, int rotation, CAR_MODEL4 model, int scale = [0x5E4D4C]) -> Car*, at
; DM_SPAWN_DIST in front of the player, facing the same way (the player's sprite:
; Ped +0x168 GameObject, +0x80 Sprite). Refused in a car.
DM_SPAWN_DIST equ 0x6000            ; 1.5 blocks
dm_spawn_car:
    push rbx
    push r12
    push r13
    sub rsp, 32
    lea r13, [s_dm_noplayer2]
    call dm_player_ped
    test eax, eax
    jz .toast
    lea r13, [s_dm_incar]
    cmp dword [rax + PED_CAR], 0
    jne .toast
    lea r13, [s_dm_nospawn]
    mov eax, [rax + PED_GAMEOBJ]
    test eax, eax
    jz .toast
    mov ebx, [rax + 0x80]           ; Sprite*
    test ebx, ebx
    jz .toast
    mov r12d, [abs 0x5E4CA4]        ; TrafficManager*
    test r12d, r12d
    jz .toast
    ; offset = DM_SPAWN_DIST * (sx * sin a, sy * cos a), a = rotation * 2pi / 1440
    movzx eax, word [rbx]
    mov [rsp + 24], eax
    fild dword [rsp + 24]
    fmul qword [f_dm_rot2rad]
    fsincos                         ; st0 = cos, st1 = sin
    fimul dword [i_dm_spawn_dist]
    fistp dword [rsp + 24]          ; cos * d
    fimul dword [i_dm_spawn_dist]
    fistp dword [rsp + 28]          ; sin * d
    mov eax, [rbx + 0x14]
    mov ecx, [rbx + 0x18]
    mov edx, [dm_spawn_sx]
    imul edx, [rsp + 28]
    add eax, edx
    mov edx, [dm_spawn_sy]
    imul edx, [rsp + 24]
    add ecx, edx
    mov [rsp], eax                  ; x
    mov [rsp + 4], ecx              ; y
    mov eax, [rbx + 0x1c]
    mov [rsp + 8], eax              ; z
    movzx eax, word [rbx]
    mov [rsp + 12], eax             ; rotation
    mov eax, [dm_model]
    lea rcx, [dm_spawnable]
    movzx eax, byte [rcx + rax]
    mov [rsp + 16], eax             ; model
    mov eax, [abs 0x5E4D4C]
    mov [rsp + 20], eax             ; scale
    mov edi, 0x426AC0
    mov rsi, rsp
    mov edx, 6
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    test eax, eax
    jz .toast
    mov [dm_last_car], eax
    mov ecx, [rax + CAR_ID]
    mov [dm_last_car_id], ecx
    lea rdi, [fmt_dm_spawned]
    mov esi, [rsp + 16]
    mov edx, [rbx + 0x14]
    mov ecx, [rbx + 0x18]
    movzx r8d, word [rbx]
    mov r9d, [rsp]
    mov eax, [rsp + 4]
    mov [rsp + 24], eax
    xor eax, eax
    sub rsp, 8
    push qword [rsp + 32]
    call _printf
    add rsp, 16
    lea r13, [s_dm_spawned]
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

; dm_repair_car: windscreen and lights back, engine damage 0, fire out (TurnOnCarLights
; @0x425590, TurnOnCarBrakeLights @0x4213D0, FixCarBrokenEngine @0x421570, ExtinguishCar
; @0x4BF070, all fastcall(Car* ecx))
dm_repair_car:
    push rbx
    lea rax, [s_dm_nocar]
    mov [dm_toast], rax
    call dm_car
    test eax, eax
    jz .toast
    mov ebx, eax
    and dword [rbx + CAR_DELTAS], ~0x1F
    mov word [rbx + CAR_DAMAGE], 0
    cmp dword [rbx + CAR_ENGINE], 3
    jne .l
    or byte [rbx + CAR_LIGHTS], 2
.l:
    test byte [rbx + CAR_LIGHTS], 2
    jz .b
    mov edi, 0x425590
    mov esi, ebx
    call dm_call_car
.b:
    test byte [rbx + CAR_LIGHTS], 1
    jz .e
    mov edi, 0x4213D0
    mov esi, ebx
    call dm_call_car
.e:
    mov edi, 0x421570
    mov esi, ebx
    call dm_call_car
    mov byte [rbx + CAR_FIRE], 0
    mov edi, 0x4BF070
    mov esi, ebx
    call dm_call_car
    lea rax, [s_dm_repaired]
    mov [dm_toast], rax
.toast:
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    pop rbx
    ret

; dm_explode_car: ExplodeCar @0x426FA0, fastcall(Car* ecx, edx = 0; EXPLOSION_SIZE), ret 4;
; carDamage >= 32001 means it already blew up
dm_explode_car:
    sub rsp, 24
    lea rax, [s_dm_nocar]
    mov [dm_toast], rax
    call dm_car
    test eax, eax
    jz .toast
    cmp word [rax + CAR_DAMAGE], 32001
    jge .toast
    mov dword [rsp], 0x13           ; EXPLOSION_SIZE_MEDIUM
    mov r8d, eax
    mov edi, 0x426FA0
    mov rsi, rsp
    mov edx, 1
    xor ecx, ecx
    xor r9d, r9d
    call call32
    lea rax, [s_dm_exploded]
    mov [dm_toast], rax
.toast:
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 24
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
    mov r15, [dm_page]
    mov eax, [r15 + DMP_COUNT]
    inc eax
    imul eax, eax, DM_LINE
    add eax, DM_Y + DM_LINE / 2 + DM_PAD
    mov edi, DM_X - DM_PAD
    mov esi, DM_Y - DM_PAD
    mov edx, DM_X + DM_W
    mov ecx, eax
    mov r8d, 0x80000000
    call dm_rect
    mov rdi, [r15 + DMP_TITLE]
    mov esi, DM_Y
    xor edx, edx
    call dm_text
    xor r12d, r12d                  ; item index
    mov r13d, DM_Y + DM_LINE + DM_LINE / 2
.item:
    cmp r12d, [r15 + DMP_COUNT]
    jae .toast
    imul eax, r12d, DMI_SIZE
    mov r14, [r15 + DMP_ITEMS]
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
    cmp eax, DM_VALUE
    je .value
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
    jmp .print
.value:
    lea rdi, [dm_buf]
    call _strlen
    lea rdi, [dm_buf]
    add rdi, rax
    mov rax, [r14 + DMI_DATA]
    call [rax + 8]                  ; format(rdi = text end)
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
DMP_TITLE equ 0
DMP_ITEMS equ 8
DMP_COUNT equ 16
; DMPAGE name, "title": a page over the items at name_items .. name_end
%macro DMPAGE 2
%1: dq %%t, %{1}_items, (%{1}_end - %{1}_items) / DMI_SIZE
section .rodata
%%t: db %2, 0
section .data
%endmacro
; DMVALUE name: a DM_VALUE item's {change, format} pair
%macro DMVALUE 1
dmv_%1: dq dm_%1_change, dm_%1_fmt
%endmacro

    DMPAGE dmp_main, "Debug menu  (K)"
    DMPAGE dmp_player, "Player"
    DMPAGE dmp_vehicle, "Vehicle"
    DMPAGE dmp_flags, "Debug flags"
    DMVALUE wanted
    DMVALUE wlock
    DMVALUE skin
    DMVALUE body
    DMVALUE carinfo
    DMVALUE model
    DMVALUE color
    DMVALUE invinc
    DMVALUE repair
    DMVALUE explode

dm_page: dq dmp_main

dmp_main_items:
    DMITEM DM_ACTION, "Quick save", DMA_SAVE
    DMITEM DM_ACTION, "Get all weapons", DMA_WEAPONS
    DMITEM DM_ACTION, "Add $100000", DMA_MONEY
    DMITEM DM_ZOOM,   "Camera zoom: ", 0
    DMITEM DM_PAGE,   "Player...", dmp_player
    DMITEM DM_PAGE,   "Vehicle...", dmp_vehicle
    DMITEM DM_PAGE,   "Debug flags...", dmp_flags
    DMITEM DM_CLOSE,  "Close", 0
dmp_main_end:

dmp_player_items:
    DMITEM DM_VALUE,  "Wanted level: ", dmv_wanted
    DMITEM DM_VALUE,  "Lock wanted: ", dmv_wlock
    DMITEM DM_VALUE,  "Skin: ", dmv_skin
    DMITEM DM_VALUE,  "Body: ", dmv_body
    DMITEM DM_BACK,   "Back", 0
dmp_player_end:

dmp_vehicle_items:
    DMITEM DM_VALUE,  "Spawn: ", dmv_model
    DMITEM DM_VALUE,  "", dmv_carinfo
    DMITEM DM_VALUE,  "Colour: ", dmv_color
    DMITEM DM_VALUE,  "Invincible: ", dmv_invinc
    DMITEM DM_VALUE,  "Repair", dmv_repair
    DMITEM DM_VALUE,  "Explode", dmv_explode
    DMITEM DM_BACK,   "Back", 0
dmp_vehicle_end:

; flag addresses: HiddenDebugFlags 0x451930 (each RegGet result is stored with
; `mov [addr], al`; own disassembly, 74 of 74 flags; matches seuko-mod's Cheats @0x5EAD51)
dmp_flags_items:
    DMITEM DM_FLAG,   "Show FPS: ", 0x5EAD79                  ; do_show_timing
    DMITEM DM_FLAG,   "Show camera info: ", 0x5EAD82          ; do_show_camera
    DMITEM DM_FLAG,   "Show counters: ", 0x5EAD95             ; do_show_counters
    DMITEM DM_FLAG,   "Show all arrows: ", 0x5EADB2           ; show_all_arrows
    DMITEM DM_FLAG,   "Invulnerable: ", 0x5EAD71              ; do_invulnerable
    DMITEM DM_FLAG,   "Infinite lives: ", 0x5EAD61            ; do_infinite_lives
    DMITEM DM_FLAG,   "Keep weapons: ", 0x5EAD9E  ; keep_weapons_after_death
    DMITEM DM_FLAG,   "Free shopping: ", 0x5EAD84             ; do_free_shopping
    DMITEM DM_FLAG,   "No police: ", 0x5EAD5E                 ; skip_police
    DMITEM DM_BACK,   "Back", 0
dmp_flags_end:

dm_skin_idx:   dd -1
dm_skin:       dd -1
dm_body:       dd -1
dm_spawn_sx:   dd -1                ; front = (-sin, -cos): rotation 0 faces north (-y), CCW; measured
dm_spawn_sy:   dd -1
i_dm_spawn_dist: dd DM_SPAWN_DIST
align 8
f_dm_rot2rad:  dq 0x3F71DF46A2529D39 ; 2*pi / 1440 (Sprite.rotation units)
; copValue at the start of each wanted level (seuko-mod cop-value-utils.cpp)
dm_cop_values: dw 0, 600, 1600, 3000, 5000, 8000, 12000

align 8
; PED_REMAP names (seuko-mod src/game/gta2.h), the rest show as "Ped N"
dm_remap_names:
    dq s_dm_remap0
    dq s_dm_remap1
    dq s_dm_remap2
    dq s_dm_remap3
    dq s_dm_remap4
    dq s_dm_remap5
    dq s_dm_remap6
    dq s_dm_remap7
    dq s_dm_remap8
    dq s_dm_remap9
    dq s_dm_remap10
    dq s_dm_remap11
    dq s_dm_remap12
    dq s_dm_remap13
    dq s_dm_remap14
    dq s_dm_remap15
    dq s_dm_remap16
    dq s_dm_remap17
    dq s_dm_remap18
    dq s_dm_remap19
    dq s_dm_remap20
    dq s_dm_remap21
    dq s_dm_remap22
    dq s_dm_remap23
    dq s_dm_remap24
    dq s_dm_remap25
    dq s_dm_remap26
DM_NREMAPNAMES equ ($ - dm_remap_names) / 8
dm_body_names: dq s_dm_game, s_dm_body0, s_dm_body1, s_dm_body2
; CAR_MODEL4 names by id (seuko-mod src/game/gta2.h)
dm_car_names:
    dq s_dm_car0
    dq s_dm_car1
    dq s_dm_car2
    dq s_dm_car3
    dq s_dm_car4
    dq s_dm_car5
    dq s_dm_car6
    dq s_dm_car7
    dq s_dm_car8
    dq s_dm_car9
    dq s_dm_car10
    dq s_dm_car11
    dq s_dm_car12
    dq s_dm_car13
    dq s_dm_car14
    dq s_dm_car15
    dq s_dm_car16
    dq s_dm_car17
    dq s_dm_car18
    dq s_dm_car19
    dq s_dm_car20
    dq s_dm_car21
    dq s_dm_car22
    dq s_dm_car23
    dq s_dm_car24
    dq s_dm_car25
    dq s_dm_car26
    dq s_dm_car27
    dq s_dm_car28
    dq s_dm_car29
    dq s_dm_car30
    dq s_dm_car31
    dq s_dm_car32
    dq s_dm_car33
    dq s_dm_car34
    dq s_dm_car35
    dq s_dm_car36
    dq s_dm_car37
    dq s_dm_car38
    dq s_dm_car39
    dq s_dm_car40
    dq s_dm_car41
    dq s_dm_car42
    dq s_dm_car43
    dq s_dm_car44
    dq s_dm_car45
    dq s_dm_car46
    dq s_dm_car47
    dq s_dm_car48
    dq s_dm_car49
    dq s_dm_car50
    dq s_dm_car51
    dq s_dm_car52
    dq s_dm_car53
    dq s_dm_car54
    dq s_dm_car55
    dq s_dm_car56
    dq s_dm_car57
    dq s_dm_car58
    dq s_dm_car59
    dq s_dm_car60
    dq s_dm_car61
    dq s_dm_car62
    dq s_dm_car63
    dq s_dm_car64
    dq s_dm_car65
    dq s_dm_car66
    dq s_dm_car67
    dq s_dm_car68
    dq s_dm_car69
    dq s_dm_car70
    dq s_dm_car71
    dq s_dm_car72
    dq s_dm_car73
    dq s_dm_car74
    dq s_dm_car75
    dq s_dm_car76
    dq s_dm_car77
    dq s_dm_car78
    dq s_dm_car79
    dq s_dm_car80
    dq s_dm_car81
    dq s_dm_car82
    dq s_dm_car83
    dq s_dm_car84
    dq s_dm_car85
    dq s_dm_car86
DM_NCARNAMES equ ($ - dm_car_names) / 8
; models SpawnCar accepts (seuko-mod src/game/utils/lists-utils.cpp)
dm_spawnable:
    db 0, 1, 2, 3, 4, 5, 7, 8, 10, 11, 12, 13, 14, 84, 16, 17
    db 18, 19, 21, 22, 23, 24, 25, 26, 85, 27, 28, 29, 30, 31, 86, 32
    db 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 45, 46, 47, 48, 49
    db 50, 51, 52, 53, 54, 55, 56, 57, 58, 62, 63, 64, 65, 66, 67, 68
    db 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83
DM_NSPAWNABLE equ $ - dm_spawnable

section .rodata
s_dm_remap0: db "Blue cop", 0
s_dm_remap1: db "Green cop", 0
s_dm_remap2: db "Red cop", 0
s_dm_remap3: db "Yellow cop", 0
s_dm_remap4: db "Khaki cop", 0
s_dm_remap5: db "Redneck 1", 0
s_dm_remap6: db "Redneck 2", 0
s_dm_remap7: db "Scientist", 0
s_dm_remap8: db "Zaibatsu", 0
s_dm_remap9: db "Krishna", 0
s_dm_remap10: db "Russian", 0
s_dm_remap11: db "Loony", 0
s_dm_remap12: db "Elvis", 0
s_dm_remap13: db "Yakuza", 0
s_dm_remap14: db "Fireman", 0
s_dm_remap15: db "Car thief", 0
s_dm_remap16: db "Medic", 0
s_dm_remap17: db "Mugger", 0
s_dm_remap18: db "Dummy 1", 0
s_dm_remap19: db "Dummy 2", 0
s_dm_remap20: db "Dummy 3", 0
s_dm_remap21: db "Dummy 4", 0
s_dm_remap22: db "Prisoner", 0
s_dm_remap23: db "Hulk 1", 0
s_dm_remap24: db "Hulk 2", 0
s_dm_remap25: db "Player", 0
s_dm_remap26: db "Naked", 0
s_dm_car0: db "ALFA", 0
s_dm_car1: db "ALLARD", 0
s_dm_car2: db "AMDB4", 0
s_dm_car3: db "APC", 0
s_dm_car4: db "BANKVAN", 0
s_dm_car5: db "BMW", 0
s_dm_car6: db "BOXCAR", 0
s_dm_car7: db "BOXTRUCK", 0
s_dm_car8: db "BUG", 0
s_dm_car9: db "CAR9", 0
s_dm_car10: db "BUICK", 0
s_dm_car11: db "BUS", 0
s_dm_car12: db "COPCAR", 0
s_dm_car13: db "DART", 0
s_dm_car14: db "EDSEL", 0
s_dm_car15: db "CAR15", 0
s_dm_car16: db "FIAT", 0
s_dm_car17: db "FIRETRUCK", 0
s_dm_car18: db "GRAHAM", 0
s_dm_car19: db "GT24640", 0
s_dm_car20: db "CAR20", 0
s_dm_car21: db "GTRUCK", 0
s_dm_car22: db "GUNJEEP", 0
s_dm_car23: db "HOTDOG", 0
s_dm_car24: db "HOTDOG_D1", 0
s_dm_car25: db "HOTDOG_D2", 0
s_dm_car26: db "HOTDOG_D3", 0
s_dm_car27: db "ICECREAM", 0
s_dm_car28: db "ISETLIMO", 0
s_dm_car29: db "ISETTA", 0
s_dm_car30: db "JEEP", 0
s_dm_car31: db "JEFFREY", 0
s_dm_car32: db "LIMO", 0
s_dm_car33: db "LIMO2", 0
s_dm_car34: db "MEDICAR", 0
s_dm_car35: db "MERC", 0
s_dm_car36: db "MESSER", 0
s_dm_car37: db "MIURA", 0
s_dm_car38: db "MONSTER", 0
s_dm_car39: db "MORGAN", 0
s_dm_car40: db "MORRIS", 0
s_dm_car41: db "PICKUP", 0
s_dm_car42: db "RTYPE", 0
s_dm_car43: db "CAR43", 0
s_dm_car44: db "SPIDER", 0
s_dm_car45: db "SPRITE", 0
s_dm_car46: db "STINGRAY", 0
s_dm_car47: db "STRATOS", 0
s_dm_car48: db "STRATOSB", 0
s_dm_car49: db "STRIPETB", 0
s_dm_car50: db "STYPE", 0
s_dm_car51: db "STYPECAB", 0
s_dm_car52: db "SWATVAN", 0
s_dm_car53: db "T2000GT", 0
s_dm_car54: db "TANK", 0
s_dm_car55: db "TANKER", 0
s_dm_car56: db "TAXI", 0
s_dm_car57: db "TBIRD", 0
s_dm_car58: db "TOWTRUCK", 0
s_dm_car59: db "TRAIN", 0
s_dm_car60: db "TRAINCAB", 0
s_dm_car61: db "TRAINFB", 0
s_dm_car62: db "TRANCEAM", 0
s_dm_car63: db "TRUKCAB1", 0
s_dm_car64: db "TRUKCAB2", 0
s_dm_car65: db "TRUKCONT", 0
s_dm_car66: db "TRUKTRNS", 0
s_dm_car67: db "TVVAN", 0
s_dm_car68: db "VAN", 0
s_dm_car69: db "VESPA", 0
s_dm_car70: db "VTYPE", 0
s_dm_car71: db "WBTWIN", 0
s_dm_car72: db "WRECK0", 0
s_dm_car73: db "WRECK1", 0
s_dm_car74: db "WRECK2", 0
s_dm_car75: db "WRECK3", 0
s_dm_car76: db "WRECK4", 0
s_dm_car77: db "WRECK5", 0
s_dm_car78: db "WRECK6", 0
s_dm_car79: db "WRECK7", 0
s_dm_car80: db "WRECK8", 0
s_dm_car81: db "WRECK9", 0
s_dm_car82: db "XK120", 0
s_dm_car83: db "ZCX5", 0
s_dm_car84: db "EDSELFBI", 0
s_dm_car85: db "HOTDOG_D4", 0
s_dm_car86: db "KRSNABUS", 0
section .data
dm_hl_remap: dd 2                   ; font remap of the selected line: green (measured)
f_dm_inv16384: dd 0x38800000        ; 1/16384

section .rodata
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
fmt_dm_int:    db "%d", 0
fmt_dm_skin:   db "%d %s", 0
fmt_dm_carinfo: db "Car: %s (%s)", 0
s_dm_dash:     db "-", 0
s_dm_game:     db "game", 0
s_dm_default:  db "default", 0
s_dm_ped:      db "Ped", 0
s_dm_body0:    db "dummy", 0
s_dm_body1:    db "gang", 0
s_dm_body2:    db "emergency", 0
s_dm_nocar:    db "No car", 0
s_dm_current:  db "in it", 0
s_dm_last:     db "last", 0
s_dm_incar:    db "Get out of the car first", 0
s_dm_nospawn:  db "Cannot spawn here", 0
s_dm_spawned:  db "Car spawned", 0
s_dm_repaired: db "Car repaired", 0
s_dm_exploded: db "Boom", 0
fmt_dm_spawned: db "menu: spawned car model %d; player at %d,%d rot %d -> car at %d,%d", 10, 0
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
dm_main_sel:   resd 1
dm_model:      resd 1
dm_skin_orig:  resd 1
dm_body_orig:  resd 1
dm_last_car:   resd 1
dm_last_car_id: resd 1
dm_wanted_lock: resb 1
alignb 2
dm_wanted_val: resw 1
dm_buf:        resb 128
section .text
