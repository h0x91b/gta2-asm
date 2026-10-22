; menu/spawn_ped.asm — Spawn > Ped: every ped remap (look) of the style, named, with the
; role it naturally has on this level (a gang of the level, police, emergency, special,
; civilian), a role picker and a live, walking and turning preview of the ped in that
; remap and body. Built through the recipe in docs/debug-menu.md, like menu/spawn_car.asm:
; one DM_PAGE with dynamic rows (sp_rows / sp_rowfmt / sp_rowchange), a key callback
; (sp_key) and a draw callback (sp_draw) on the shared dm_pane / dm_sprite / dm_text_at.
;
;   UP / DOWN       look (remap)      LEFT / RIGHT   role: auto (the look's own) or any of
;   B               behaviour:                       civilian, gang member, cop, SWAT, FBI,
;                   normal / hostile / follows you   army, medic, fireman, Elvis, mugger, ...
;   RETURN          spawn it 1 block in front of the player
;
; Rows are sorted: the level's gangs first, then police, emergency and special roles, named
; looks, plain civilians. A role is an occupation, a body (graphicType), a class, threat
; search / reaction and a weapon (sp_roles).
;
; Facts (cite): PED_REMAP 0..52 names = seuko-mod enum (re/gta2_types.h); the style has 474
; ped sprites = 3 bodies x 158 frames (bun tools/formats/cli.ts sty data/wil.sty --summary),
; frame = graphicType * 158 + anim (PedGameObject_UpdateAnimFrame @0x497DF0,
; docs/re/gangs-and-peds.md), frames 0..7 are the walk cycle (rendered from the style);
; the emergency body is drawn for remaps 0..4 only (other remaps leave its green pixels).
; Gangs: g_GangRespect @0x5EB898 -> 10 x GangRespect 0x144: +0 present, +2 gangName,
; +0x101 pedRemap (docs/re/gangs-and-peds.md §1). Occupations: OCUPATION (Ped +0x240) and
; the ambient spawner's remap per role (§4, §5). Ped: +0x244 remap, +0x26C graphicType
; (seuko-mod gta2.h), +0x17C gang (ADD_CHAR_TO_GANG, §2).

SP_NREMAP  equ 53
SP_PANE_H  equ 268
SP_SCALE   equ 450                  ; preview: percent of the HUD's 1:1 size (a ped is ~16x20)
SP_SPIN    equ 2                    ; preview rotation per frame (1440 per turn)
SP_WALK    equ 5                    ; frames per walk-cycle step
SP_DIST    equ 0x4000               ; spawn 1 block in front
SP_BODY    equ 158                  ; ped frames per body (graphicType)
GANGS      equ 0x5EB898             ; GangRespectContainer*
GANG_SIZE  equ 0x144
GANG_NAME  equ 2
GANG_REMAP equ 0x101
PED_OCC    equ 0x240
PED_CLASS  equ 0x238
PED_GANG   equ 0x17c
PED_GROUP  equ 0x164
PED_SEARCH equ 0x288
PED_REACT  equ 0x28c
DIK_B      equ 0x30

section .data
    DM_PAGE  dmp_spawn_ped, dmp_spawn, 20, "Ped", sp_draw, sp_key, sp_rows, sp_rowfmt, sp_rowchange
sp_role:   dd 0                     ; 0 auto, else an sp_roles index
sp_behave: dd 0                     ; 0 normal, 1 hostile, 2 follows the player

; roles, 32 bytes: occupation, body (graphicType 0 dummy, 1 gang, 2 emergency), pedClass
; (3 ambient, 4 special AI, 5 mission, 6 car driver), threat search (0 none, 1 line of sight,
; 2 area), threat reaction (1 as emergency, 2 normal, 3 run away), weapon (-1 none, -2 the
; gang's pick by respect, else WEAPON_INDEX: 0 pistol, 1 SMG), name. Each copies the game's
; own spawn site where it has one (Seq 27 seq51_answer.md §3/§5: SetupFootCop 0x4AA710,
; SpawnRoadblockGuard 0x4A9B40 FBI, SpawnParamedicCrew 0x473170, SpawnElvisGroup 0x43D640,
; Car_CreateGangDriverPed 0x43DC60, DummyPedManager_SpawnAmbientPed 0x4404F0); the others
; are ours. Classes 3 / 4 / 6 despawn off screen like the game's own (40 / 100 ticks).
RL_OCC    equ 0
RL_BODY   equ 4
RL_CLASS  equ 8
RL_SEARCH equ 12
RL_REACT  equ 16
RL_WEAPON equ 20
RL_NAME   equ 24
RL_SIZE   equ 32
align 8
sp_roles:
    dd 0, 0, 0, 0, 0, -1
    dq s_sp_auto
    dd 3, 0, 3, 2, 3, -1
    dq s_sp_civilian
    dd 19, 1, 4, 1, 2, -2
    dq s_sp_gang
    dd 29, 2, 3, 1, 1, 0
    dq s_sp_cop
    dd 25, 2, 4, 1, 1, 1
    dq s_sp_swat
    dd 26, 1, 4, 1, 1, 1
    dq s_sp_fbi
    dd 31, 2, 3, 1, 1, 1
    dq s_sp_army
    dd 23, 0, 4, 0, 1, -1
    dq s_sp_medic
    dd 38, 0, 4, 0, 1, -1
    dq s_sp_fireman
    dd 22, 1, 4, 2, 3, -1
    dq s_sp_elvis
    dd 15, 0, 4, 2, 3, -1
    dq s_sp_mugger
    dd 16, 0, 6, 2, 3, -1
    dq s_sp_thief
    dd 14, 1, 4, 1, 2, 0
    dq s_sp_psycho
    dd 18, 1, 4, 1, 2, 0
    dq s_sp_criminal
    dd 43, 0, 5, 2, 3, -1
    dq s_sp_still
SP_NROLES equ ($ - sp_roles) / RL_SIZE
SP_ROLE_CIV  equ 1
SP_ROLE_GANG equ 2

; the natural role of each remap (without a gang of the level using it)
sp_natural:
    db 3, 3, 3, 3, 6                ; 0..3 police, 4 khaki = army (FBI/army crews, §5)
    db 1, 1, 1, 1, 1, 1, 1          ; 5..11 rednecks, scientist, zaibatsu, krishna, russian, loony
    db 9, 1, 8, 11, 7, 10           ; 12 Elvis, 13 yakuza, 14 fireman, 15 car thief, 16 medic, 17 mugger
    times SP_NREMAP - 18 db 1
; the sort class of each remap: 0 level gang (set at run time), 1 police, 2 emergency or
; special role, 3 named look, 4 plain civilian
sp_class0:
    db 1, 1, 1, 1, 1
    db 3, 3, 3, 3, 3, 3, 3
    db 2, 3, 2, 2, 2, 2
    db 4, 4, 4, 4                   ; 18..21 the ambient dummies
    db 3, 3, 3, 3, 3                ; 22 prisoner, 23/24 hulks, 25 player, 26 naked
    times SP_NREMAP - 27 db 4

align 8
sp_names:
    dq s_sp_r0, s_sp_r1, s_sp_r2, s_sp_r3, s_sp_r4, s_sp_r5, s_sp_r6, s_sp_r7
    dq s_sp_r8, s_sp_r9, s_sp_r10, s_sp_r11, s_sp_r12, s_sp_r13, s_sp_r14, s_sp_r15
    dq s_sp_r16, s_sp_r17, s_sp_r18, s_sp_r19, s_sp_r20, s_sp_r21, s_sp_r22, s_sp_r23
    dq s_sp_r24, s_sp_r25, s_sp_r26
SP_NNAMED equ ($ - sp_names) / 8
section .text

; eax = sp_gang(edi = remap): the level's GangRespect* whose members wear that remap, or 0
sp_gang:
    xor eax, eax
    mov edx, [abs GANGS]
    test edx, edx
    jz .out
    mov ecx, 10
.l:
    cmp byte [rdx], 0
    je .n
    movzx r8d, byte [rdx + GANG_REMAP]
    cmp r8d, edi
    jne .n
    mov eax, edx
    ret
.n:
    add edx, GANG_SIZE
    dec ecx
    jnz .l
.out:
    ret

; eax = sp_any_gang(): the level's first gang, or 0
sp_any_gang:
    xor eax, eax
    mov edx, [abs GANGS]
    test edx, edx
    jz .out
    mov ecx, 10
.l:
    cmp byte [rdx], 0
    jne .hit
    add edx, GANG_SIZE
    dec ecx
    jnz .l
    ret
.hit:
    mov eax, edx
.out:
    ret

; eax = sp_natural_role(edi = remap): SP_ROLE_GANG if a gang of the level wears it, else
; the remap's own role
sp_natural_role:
    push rbx
    mov ebx, edi
    call sp_gang
    test eax, eax
    mov eax, SP_ROLE_GANG
    jnz .out
    lea rax, [sp_natural]
    movzx eax, byte [rax + rbx]
.out:
    pop rbx
    ret

; eax = sp_role_for(edi = remap): sp_role, auto resolved
sp_role_for:
    mov eax, [sp_role]
    test eax, eax
    jnz .out
    jmp sp_natural_role
.out:
    ret

; eax = sp_rows(): all the remaps, into sp_idx, by class (stable)
sp_rows:
    push rbx
    push r12
    push r13
    lea r12, [sp_idx]
    lea r13, [sp_cls]
    xor ebx, ebx
.k:
    mov [r12 + rbx], bl
    mov edi, ebx
    call sp_gang
    test eax, eax
    jz .c
    xor eax, eax
    jmp .put
.c:
    lea rax, [sp_class0]
    movzx eax, byte [rax + rbx]
.put:
    mov [r13 + rbx], al
    inc ebx
    cmp ebx, SP_NREMAP
    jb .k
    mov ebx, 1                      ; insertion sort by class
.o:
    movzx r8d, byte [r12 + rbx]
    movzx r9d, byte [r13 + rbx]
    mov ecx, ebx
.i:
    test ecx, ecx
    jz .ins
    movzx eax, byte [r13 + rcx - 1]
    cmp eax, r9d
    jbe .ins
    mov [r13 + rcx], al
    mov al, [r12 + rcx - 1]
    mov [r12 + rcx], al
    dec ecx
    jmp .i
.ins:
    mov [r12 + rcx], r8b
    mov [r13 + rcx], r9b
    inc ebx
    cmp ebx, SP_NREMAP
    jb .o
    mov eax, SP_NREMAP
    pop r13
    pop r12
    pop rbx
    ret

; eax = sp_remap(edi = row)
sp_remap:
    lea rax, [sp_idx]
    movzx eax, byte [rax + rdi]
    ret

; sp_name(edi = remap, rsi = buffer of 64): "Yakuza (yakuzagang)", "Remap 31"
sp_name:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    mov r12, rsi
    cmp ebx, SP_NNAMED
    jae .num
    lea rcx, [sp_names]
    mov rsi, [rcx + rbx*8]
    mov rdi, r12
    call _strcpy
    jmp .gang
.num:
    mov rdi, r12
    mov esi, 64
    lea rdx, [fmt_sp_remap]
    mov ecx, ebx
    xor eax, eax
    call _snprintf
.gang:
    mov edi, ebx
    call sp_gang
    test eax, eax
    jnz .ganged
    cmp ebx, SP_NNAMED              ; an unnamed look: say what it is
    jb .out
    mov rdi, r12
    call _strlen
    lea rdi, [r12 + rax]
    lea rsi, [s_sp_civtag]
    call _strcpy
    jmp .out
.ganged:
    mov [rsp], eax
    mov rdi, r12
    call _strlen
    lea rdi, [r12 + rax]
    mov ecx, [rsp]
    add ecx, GANG_NAME
    mov esi, 63
    sub esi, eax
    jle .out
    lea rdx, [fmt_sp_ganged]
    xor eax, eax
    call _snprintf
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

sp_rowfmt:
    push rbx
    mov rbx, rsi
    call sp_remap
    mov edi, eax
    mov rsi, rbx
    call sp_name
    pop rbx
    ret

; eax = sp_key(edi = DIK): B cycles the behaviour
sp_key:
    xor eax, eax
    cmp edi, DIK_B
    jne .out
    mov eax, [sp_behave]
    inc eax
    cmp eax, 3
    jb .s
    xor eax, eax
.s:
    mov [sp_behave], eax
    mov eax, 1
.out:
    ret

; sp_rowchange(edi = row, esi = dir): LEFT / RIGHT the role, RETURN spawns
sp_rowchange:
    sub rsp, 8
    test esi, esi
    jz .spawn
    mov eax, [sp_role]
    add eax, esi
    jns .hi
    mov eax, SP_NROLES - 1
.hi:
    cmp eax, SP_NROLES
    jb .set
    xor eax, eax
.set:
    mov [sp_role], eax
    jmp .out
.spawn:                             ; resolve everything now, spawn on the game's side
    call sp_remap
    mov [sp_spawn_remap], eax
    mov edi, eax
    call sp_role_for
    mov [sp_spawn_role], eax
    mov eax, [sp_behave]
    mov [sp_spawn_behave], eax
    lea rdi, [sp_spawn]
    call dm_defer
.out:
    add rsp, 8
    ret

; eax = sp_role_gang(edi = remap, esi = role): the gang a gang-member role joins (the one
; wearing that remap, else the level's first), 0 for other roles
sp_role_gang:
    xor eax, eax
    cmp esi, SP_ROLE_GANG
    jne .out
    call sp_gang
    test eax, eax
    jnz .out
    call sp_any_gang
.out:
    ret

; eax = sp_call(edi = fn, esi = ecx (this / fastcall first arg), edx, ecx = stack args 1, 2,
; r8d = how many of them): a game thiscall / fastcall with edx unused, the callee pops
sp_call:
    sub rsp, 24
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov edx, r8d
    mov r8d, esi
    mov rsi, rsp
    xor ecx, ecx
    xor r9d, r9d
    call call32
    add rsp, 24
    ret

; sp_spawn (deferred): the CREATE_CHAR recipe (Script_Decl_CHAR_DATA_SET 0x477560, Seq 27
; seq51_answer.md §1): Ped_Spawn, then class, occupation, body, threat search / reaction,
; gang, weapon as the role says, then the behaviour
sp_spawn:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov rdi, rsp
    mov esi, SP_DIST
    call dm_spawn_point
    test eax, eax
    jz .fail
    lea rdx, [s_sp_full]            ; Ped_Spawn pops the ped pool with no empty check
    mov eax, [abs PED_POOL]
    test eax, eax
    jz .fail
    cmp dword [rax], 0              ; freeListHead
    je .fail
    mov eax, [sp_spawn_remap]       ; Ped_Spawn(x, y, z, remap, rotation)
    mov ecx, [rsp + 12]
    mov [rsp + 12], eax
    mov [rsp + 16], ecx
    mov edi, PED_SPAWN
    mov rsi, rsp
    mov edx, 5
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    lea rdx, [s_sp_nosprite]        ; no free body sprite: the game leaks that ped
    test eax, eax
    jz .fail
    mov ebx, eax
    mov [sp_last], eax
    mov eax, [sp_spawn_role]
    shl eax, 5
    lea r12, [sp_roles]
    add r12, rax
    mov edi, PED_SETCLASS
    mov esi, ebx
    mov edx, [r12 + RL_CLASS]
    mov r8d, 1
    call sp_call
    mov edi, PED_SETOCC
    mov esi, ebx
    mov edx, [r12 + RL_OCC]
    mov r8d, 1
    call sp_call
    mov eax, [r12 + RL_BODY]
    mov [rbx + PED_GTYPE], eax
    mov eax, [r12 + RL_SEARCH]
    mov [rbx + PED_SEARCH], eax
    mov eax, [r12 + RL_REACT]
    mov [rbx + PED_REACT], eax
    mov edi, [sp_spawn_remap]
    mov esi, [sp_spawn_role]
    call sp_role_gang
    mov r13d, eax
    test eax, eax
    jz .weapon
    mov [rbx + PED_GANG], eax
.weapon:
    mov edx, [r12 + RL_WEAPON]
    cmp edx, -1
    je .beh
    cmp edx, -2
    jne .give
    test r13d, r13d
    jz .beh
    mov edi, GANG_WEAPON            ; Gang_PickWeaponByRespect fastcall(GangRespect*)
    mov esi, r13d
    xor r8d, r8d
    call sp_call
    mov edx, eax
.give:
    mov edi, PED_SETWEAPON
    mov esi, ebx
    mov r8d, 1
    call sp_call
.beh:
    mov edi, ebx
    call sp_behaviour
    mov rbx, rax                    ; the toast
    mov eax, [sp_last]
    lea rdi, [fmt_sp_spawned]
    mov esi, eax
    mov edx, [sp_spawn_remap]
    mov ecx, [rax + PED_OCC]
    mov r8d, [rax + PED_CLASS]
    mov r9d, [rax + PED_GTYPE]
    xor eax, eax
    call _printf
    mov rax, rbx
    call dm_toast_set
    jmp .out
.fail:
    mov rax, rdx
    call dm_toast_set
.out:
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

; rax = sp_behaviour(edi = Ped*): hostile / follower, per sp_spawn_behave; rax = the toast
; Hostile = SET_CHAR_OBJECTIVE KILL_CHAR_ON_FOOT on the player (handler 0x47A1E0):
; PedSetObjective, then the target (PedSetObjective clears it). Follower = the player's
; group (ADD_EXISTING_CHAR_TO_GROUP, 0x47BAC0): PedGroupCreate(player, 0) when he has none,
; then PedGroupAddPed; the group AI makes members follow (Seq 27 seq51_answer.md §4).
sp_behaviour:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    call dm_player_ped
    mov r12d, eax
    lea rax, [s_sp_spawned]
    test r12d, r12d
    jz .out
    mov ecx, [sp_spawn_behave]
    cmp ecx, 1
    je .hostile
    cmp ecx, 2
    jne .out
    mov eax, [r12 + PED_GROUP]
    test eax, eax
    jnz .add
    mov edi, PEDGROUP_CREATE
    mov esi, r12d
    xor edx, edx
    mov r8d, 1
    call sp_call
    mov eax, [r12 + PED_GROUP]
    test eax, eax
    lea rax, [s_sp_nogroup]
    jz .out
    mov eax, [r12 + PED_GROUP]
.add:
    lea rcx, [s_sp_groupfull]
    cmp byte [rax + PEDGROUP_COUNT], 7
    jae .full
    mov edi, PEDGROUP_ADD
    mov esi, eax
    mov edx, ebx
    mov r8d, 1
    call sp_call
    lea rax, [s_sp_follows]
    jmp .out
.full:
    mov rax, rcx
    jmp .out
.hostile:
    mov edi, PED_SETOBJ
    mov esi, ebx
    mov edx, 20                     ; KILL_CHAR_ON_FOOT
    mov ecx, 9999
    mov r8d, 2
    call sp_call
    mov edi, PED_SETTARGET
    mov esi, ebx
    mov edx, r12d
    mov r8d, 1
    call sp_call
    lea rax, [s_sp_hostile2]
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; sp_draw(rdi = page): the preview pane for the selected look. The text lines are built
; first and measured (dm_text_w), so the pane fits the widest of them and the preview.
; Frame: [rsp] DMSPRITE, +40 remap, +44 pane width, +48 role, +64 SP_NLINES lines of 64.
SP_NLINES equ 8
SP_LINE   equ 64
sp_draw:
    push rbx
    push r12
    push r13
    sub rsp, 64 + SP_NLINES * SP_LINE
    mov r12, rdi
    call dm_dyn
    mov edi, [r12 + DPG_SEL]
    cmp edi, eax
    jae .out                        ; on Back
    call sp_remap
    mov [rsp + 40], eax
    mov edi, eax                    ; line 0: the name
    lea rsi, [rsp + 64]
    call sp_name
    mov edi, [rsp + 40]
    call sp_role_for
    mov [rsp + 48], eax
    shl eax, 5
    lea rbx, [sp_roles]
    add rbx, rax                    ; rbx = the role record
    lea rdi, [rsp + 64 + SP_LINE]   ; line 1: "Role: auto, Cop" / "Role: Cop"
    mov esi, SP_LINE
    lea rdx, [fmt_sp_role]
    lea rcx, [s_sp_fixed]
    cmp dword [sp_role], 0
    jne .r1
    lea rcx, [s_sp_auto2]
.r1:
    mov r8, [rbx + RL_NAME]
    xor eax, eax
    call _snprintf
    lea rdi, [rsp + 64 + 2 * SP_LINE] ; line 2: "Remap 13  occupation 19"
    mov esi, SP_LINE
    lea rdx, [fmt_sp_info]
    mov ecx, [rsp + 40]
    mov r8d, [rbx + RL_OCC]
    xor eax, eax
    call _snprintf
    mov edi, [rsp + 40]             ; line 3: "Body gang  Gang yakuzagang"
    mov esi, [rsp + 48]
    call sp_role_gang
    lea rdi, [rsp + 64 + 3 * SP_LINE]
    mov esi, SP_LINE
    mov ecx, [rbx + RL_BODY]
    lea rdx, [sp_bodies]
    mov rcx, [rdx + rcx*8]
    lea rdx, [fmt_sp_body]
    test eax, eax
    jz .t3
    lea r8, [rax + GANG_NAME]
    lea rdx, [fmt_sp_body_gang]
.t3:
    xor eax, eax
    call _snprintf
.l4:
    lea rdi, [rsp + 64 + 4 * SP_LINE] ; line 4: behaviour
    mov esi, SP_LINE
    lea rdx, [fmt_sp_behave]
    mov eax, [sp_behave]
    lea rcx, [sp_behaves]
    mov rcx, [rcx + rax*8]
    xor eax, eax
    call _snprintf
    lea rdi, [rsp + 64 + 5 * SP_LINE] ; lines 5..7: the keys
    lea rsi, [s_sp_hint1]
    call _strcpy
    lea rdi, [rsp + 64 + 6 * SP_LINE]
    lea rsi, [s_sp_hint2]
    call _strcpy
    lea rdi, [rsp + 64 + 7 * SP_LINE]
    lea rsi, [s_sp_hint3]
    call _strcpy
    mov dword [rsp + 44], 120       ; width: the preview or the widest line
    xor r13d, r13d
.m:
    mov eax, r13d
    shl eax, 6
    lea rdi, [rsp + 64 + rax]
    call dm_text_w
    cmp eax, [rsp + 44]
    jbe .mn
    mov [rsp + 44], eax
.mn:
    inc r13d
    cmp r13d, SP_NLINES
    jb .m
    mov esi, DM_Y
    mov ecx, DM_Y + SP_PANE_H
    mov edx, [rsp + 44]
    call dm_pane
    lea rdi, [rsp + 64]
    mov esi, [dm_pane_x]
    mov edx, DM_Y
    mov ecx, 1
    call dm_text_at
    mov dword [rsp + DS_TYPE], 3    ; SPRITE_TYPE_PED
    mov eax, [r_frames]             ; frame = body * 158 + walk step 0..7
    xor edx, edx
    mov ecx, SP_WALK
    div ecx
    and eax, 7
    imul ecx, [rbx + RL_BODY], SP_BODY
    add eax, ecx
    mov [rsp + DS_ID], eax
    mov dword [rsp + DS_PAL], 4     ; ped remap
    mov eax, [rsp + 40]
    mov [rsp + DS_REMAP], eax
    mov eax, [rsp + 44]
    shr eax, 1
    add eax, [dm_pane_x]
    mov [rsp + DS_X], eax
    mov dword [rsp + DS_Y], DM_Y + 18 + 60
    mov dword [rsp + DS_BOX], 0
    mov dword [rsp + DS_SCALE], SP_SCALE
    mov eax, [r_frames]
    imul eax, eax, SP_SPIN
    xor edx, edx
    mov ecx, 1440
    div ecx
    mov [rsp + DS_ROT], edx
    mov rdi, rsp
    call dm_sprite
    mov r12d, 1                     ; lines 1..7 at the bottom, a gap before the keys
    mov r13d, DM_Y + SP_PANE_H - 7 * DM_LINE - DM_LINE / 2
.t:
    cmp r12d, 5
    jne .tp
    add r13d, DM_LINE / 2
.tp:
    mov eax, r12d
    shl eax, 6
    lea rdi, [rsp + 64 + rax]
    mov esi, [dm_pane_x]
    mov edx, r13d
    xor ecx, ecx
    call dm_text_at
    inc r12d
    add r13d, DM_LINE
    cmp r12d, SP_NLINES
    jb .t
.out:
    add rsp, 64 + SP_NLINES * SP_LINE
    pop r13
    pop r12
    pop rbx
    ret

; game functions, calling conventions from the disassembly (Seq 27 seq51_answer.md)
PED_POOL        equ 0x5E5BBC        ; PedManager_S25*: +0 freeListHead
PED_SPAWN       equ 0x43DB40        ; Ped_Spawn stdcall(SCR_f x, y, z, PED_REMAP, Ang16 rot) -> Ped*
PED_SETCLASS    equ 0x403920        ; Ped_SetPedClass thiscall(Ped*; class)
PED_SETOCC      equ 0x403970        ; Ped_SetOccupation thiscall(Ped*; OCUPATION)
PED_SETWEAPON   equ 0x43D830        ; Ped_SetWeapon fastcall(Ped*, edx; WEAPON_INDEX)
GANG_WEAPON     equ 0x45DB70        ; Gang_PickWeaponByRespect fastcall(GangRespect*) -> weapon
PED_SETOBJ      equ 0x43BBC0        ; PedSetObjective thiscall(Ped*; objective, short timer)
PED_SETTARGET   equ 0x403AC0        ; Ped_SetObjTargetPed thiscall(Ped*; Ped*)
PEDGROUP_CREATE equ 0x440350        ; PedGroupCreate fastcall(Ped* leader, edx; byte members)
PEDGROUP_ADD    equ 0x404C90        ; PedGroupAddPed fastcall(PedGroup*, edx = 0; Ped*)
PEDGROUP_COUNT  equ 0x34            ; PedGroup.membersCount, members[8] (re/gta2_types.h)

section .data
align 8
sp_bodies:  dq s_sp_b0, s_sp_b1, s_sp_b2
sp_behaves: dq s_sp_normal, s_sp_hostile, s_sp_follow

section .rodata
fmt_sp_remap:   db "Remap %d", 0
fmt_sp_ganged:  db " (%s)", 0
fmt_sp_role:    db "Role: %s%s", 0
fmt_sp_info:    db "Remap %d  Occupation %d", 0
fmt_sp_body:    db "Body %s", 0
fmt_sp_body_gang: db "Body %s  Gang %.20s", 0
fmt_sp_behave:  db "Behaviour: %s", 0
fmt_sp_spawned: db "menu: spawn ped %#x remap %d occupation %d class %d body %d", 10, 0
s_sp_auto2:     db "auto, ", 0
s_sp_civtag:    db " (civilian)", 0
s_sp_fixed:     db 0
s_sp_b0:        db "dummy", 0
s_sp_b1:        db "gang", 0
s_sp_b2:        db "emergency", 0
s_sp_normal:    db "normal", 0
s_sp_hostile:   db "hostile", 0
s_sp_follow:    db "follows you", 0
s_sp_hint1:     db "Left Right: role", 0
s_sp_hint2:     db "B: behaviour", 0
s_sp_hint3:     db "Return: spawn", 0
s_sp_spawned:   db "Ped spawned", 0
s_sp_full:      db "No free ped", 0
s_sp_nosprite:  db "No free ped sprite", 0
s_sp_nogroup:   db "Ped spawned, no group for you", 0
s_sp_groupfull: db "Ped spawned, your group is full", 0
s_sp_follows:   db "Ped spawned, follows you", 0
s_sp_hostile2:  db "Ped spawned, hostile", 0
s_sp_auto:      db "auto", 0
s_sp_civilian:  db "Civilian", 0
s_sp_gang:      db "Gang member", 0
s_sp_cop:       db "Cop", 0
s_sp_swat:      db "SWAT", 0
s_sp_fbi:       db "FBI", 0
s_sp_army:      db "Army", 0
s_sp_medic:     db "Medic", 0
s_sp_fireman:   db "Fireman", 0
s_sp_elvis:     db "Elvis", 0
s_sp_mugger:    db "Mugger", 0
s_sp_thief:     db "Car thief", 0
s_sp_psycho:    db "Psycho", 0
s_sp_criminal:  db "Criminal", 0
s_sp_still:     db "Stand still bloke", 0
s_sp_r0:        db "Blue police", 0
s_sp_r1:        db "Green police", 0
s_sp_r2:        db "Red police", 0
s_sp_r3:        db "Yellow police", 0
s_sp_r4:        db "Khaki police", 0
s_sp_r5:        db "Redneck, red head", 0
s_sp_r6:        db "Redneck, blond", 0
s_sp_r7:        db "Scientist", 0
s_sp_r8:        db "Zaibatsu", 0
s_sp_r9:        db "Krishna", 0
s_sp_r10:       db "Russian", 0
s_sp_r11:       db "Loony", 0
s_sp_r12:       db "Elvis", 0
s_sp_r13:       db "Yakuza", 0
s_sp_r14:       db "Fireman", 0
s_sp_r15:       db "Green shorts", 0
s_sp_r16:       db "Medic", 0
s_sp_r17:       db "Mugger", 0
s_sp_r18:       db "Blue dummy", 0
s_sp_r19:       db "Light blue dummy", 0
s_sp_r20:       db "T-shirt and shorts", 0
s_sp_r21:       db "Shirt and trousers", 0
s_sp_r22:       db "Prisoner", 0
s_sp_r23:       db "Hulk 1", 0
s_sp_r24:       db "Hulk 2", 0
s_sp_r25:       db "Player", 0
s_sp_r26:       db "Naked", 0

section .bss
sp_idx:          resb SP_NREMAP
sp_cls:          resb SP_NREMAP
alignb 4
sp_spawn_remap:  resd 1
sp_spawn_role:   resd 1
sp_spawn_behave: resd 1
sp_last:         resd 1
section .text
