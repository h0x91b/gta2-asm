; menu/player.asm — the K menu's Player page: wanted level and its lock, skin (ped remap)
; and body (graphicType). Police roadblocks (debug_roadblocks.asm) and the ambulance /
; fire truck calls (debug_emergency.asm) register their rows here from their own files.
; Ped fields (gta2-seuko-mod src/game/gta2.h @25b1985): copValue +0x20a (short; 1..6 stars
; from 600/1600/3000/5000/8000/12000, src/game/utils/cop-value-utils.cpp), remap +0x244
; (byte, PED_REMAP, 255 = default), graphicType +0x26c (0 dummy, 1 gang, 2 emergency). A
; lock or a chosen skin is re-applied every frame (pl_tick), as seuko's per-tick watches do
; (src/modules/modmenu/cheats/player-appearance.cpp).

section .data
    DM_PAGE  dmp_player, dmp_root, 100, "Player"
    DM_ITEM  dmp_player, 10, DM_VALUE, "Wanted level: ", dmv_wanted
    DM_ITEM  dmp_player, 20, DM_VALUE, "Lock wanted: ", dmv_wlock
    DM_ITEM  dmp_player, 30, DM_VALUE, "Skin: ", dmv_skin
    DM_ITEM  dmp_player, 40, DM_VALUE, "Body: ", dmv_body
    DMVALUE wanted
    DMVALUE wlock
    DMVALUE skin
    DMVALUE body
    DM_FRAME 5, pl_tick
section .text

; pl_tick (DM_FRAME): the wanted lock, a chosen skin and body
pl_tick:
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
    js .out
    mov [rax + PED_GTYPE], edx
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

section .data
dm_skin_idx:   dd -1
dm_skin:       dd -1
dm_body:       dd -1
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
fmt_dm_skin:   db "%d %s", 0
s_dm_game:     db "game", 0
s_dm_ped:      db "Ped", 0
s_dm_body0:    db "dummy", 0
s_dm_body1:    db "gang", 0
s_dm_body2:    db "emergency", 0

section .bss
dm_skin_orig:  resd 1
dm_body_orig:  resd 1
dm_wanted_lock: resb 1
alignb 2
dm_wanted_val: resw 1
section .text
