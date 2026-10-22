; menu/spawn_object.asm — Spawn > Object: every world object type the current level can
; create at run time (the game's own prefab table, so the style's map objects are in it),
; grouped (street furniture, weapon / car weapon / power-up pickups, explosives, phones,
; other), with a remap picker and a live, animated preview. Built through the recipe in
; docs/debug-menu.md like menu/spawn_car.asm: one DM_PAGE with dynamic rows, a key
; callback for PAGE UP / PAGE DOWN and a draw callback with dm_pane / dm_sprite.
;
;   UP / DOWN       object          LEFT / RIGHT   remap: the prefab's own colours, or each
;   PAGE UP / DOWN  previous / next                  remap of its palette (code / map obj)
;                   group           RETURN         spawn it 1.5 blocks in front of the player
;
; Facts (re/gta2_types.h ObjectPrefab, docs/re/objects-and-weapons.md, own decompile):
; g_ObjectPrefabsContainer @0x665B40 -> +0x87F4 ObjectPrefab* byId[300] (ObjectPrefabs_Get
; @0x488170). ObjectPrefab +0x1C remap, +0x1E defaultSpriteId (relative to the type's
; sprite base), +0x28 sprite type (4 code obj, 5 map obj; ObjectPrefab_ApplyToPosition
; @0x4883A0 hands it to Sprite_SetCollisionKind), +0x30 palette kind, +0x34 kind, +0x40
; gridKind (4 = obstacles grid: solid), +0x44 impactMode (2 = pushed away), +0x48
; explosiveClass, +0x64 ticks per frame, +0x6C frame count. The style's map objects are
; added by ObjectPrefabs_InitFromStyle @0x488450 (id = the OBJI model).
; Spawn = the script's own path (Script_Decl_OBJ_DATA_SET @0x476EA0, the CREATE_OBJ_*
; handler Script_Op_CREATE_OBJ @0x478A80 calls it): types 200..244 (pickups) through
; Object_NewPhysicsObjUnlessBlocked @0x485480, all others through SpawnObject @0x4852E0;
; both thiscall(ObjectSpawner* = [0x665788]; type, SCR_f x, y, z, Ang16 rot), ret 0x14,
; -> WorldObject* or 0, and both insert the body into its collision grid
; (Object_InsertIntoGrid @0x482630). ObjectSpawner_CreateObject @0x484E00 gives weapon
; pickups their default ammo. The remap goes on WorldObject +4 Sprite with
; Sprite_SetRemap @0x4B9B00 (palette kind from the sprite type, like a car's).

SO_PANE_H  equ 300
SO_BOX     equ 120                  ; preview: the sprite's diagonal fits this many units
SO_ZOOM    equ 4                    ; ...but at most 4x its 1:1 size
SO_NTYPES  equ 300                  ; ObjectPrefabsContainer.byId[]
SO_PREFABS equ 0x665B40             ; g_ObjectPrefabsContainer (re/globals.csv)
SO_SPAWNER equ 0x665788             ; g_ObjectSpawner (re/globals.csv)

; groups, in list order
SO_G_STREET  equ 0
SO_G_WEAPON  equ 1
SO_G_CARWPN  equ 2
SO_G_POWERUP equ 3
SO_G_PICKUP  equ 4
SO_G_EXPLO   equ 5
SO_G_PHONE   equ 6
SO_G_OTHER   equ 7

section .data
    DM_PAGE  dmp_spawn_obj, dmp_spawn, 30, "Object", so_draw, so_key, so_rows, so_rowfmt, so_rowchange
so_remap:  dd -1                    ; -1 the prefab's own colours, i = remap i of its palette
section .text

; eax = so_prefab(edi = type): its ObjectPrefab*, or 0
so_prefab:
    xor eax, eax
    cmp edi, SO_NTYPES
    jae .out
    mov ecx, [abs SO_PREFABS]
    test ecx, ecx
    jz .out
    mov eax, [rcx + 0x87F4 + rdi*4]
.out:
    ret

; eax = so_group(edi = type, rsi = prefab): its SO_G_*, or -1 when it is not offered:
; no sprite, a particle system / car shop / light / logic object, a projectile, or a
; moving pickup clone (64..108, the thrown copies of 200..244)
so_group:
    mov eax, -1
    mov ecx, [rsi + 0x34]           ; kind
    cmp ecx, 5
    je .out
    cmp ecx, 10
    jae .out
    cmp byte [rsi + 0x6C], 0        ; frames
    je .out
    mov edx, [rsi + 0x28]
    cmp edx, 4
    jb .out
    cmp edx, 5
    ja .out
    cmp edi, 64
    jb .proj
    cmp edi, 108
    jbe .out
.proj:
    cmp ecx, 3                      ; physics kinds with a launch speed: projectiles
    jb .list
    cmp ecx, 4
    ja .list
    cmp dword [rsi + 0x10], 0
    jne .out
.list:
    lea r8, [so_skip]
.l:
    movzx ecx, word [r8]
    test ecx, ecx
    jz .pick
    cmp ecx, edi
    je .out
    add r8, 2
    jmp .l
.pick:
    cmp edi, 200
    jb .explo
    cmp edi, 244
    ja .explo
    mov eax, SO_G_WEAPON
    cmp edi, 210
    jbe .out
    mov eax, SO_G_CARWPN
    cmp edi, 215
    jb .pickup
    cmp edi, 223
    jbe .out
    mov eax, SO_G_POWERUP
    cmp edi, 228
    jb .pickup
    cmp edi, 240
    jbe .out
.pickup:
    mov eax, SO_G_PICKUP
    ret
.explo:
    mov eax, SO_G_EXPLO
    cmp dword [rsi + 0x48], 0       ; explosiveClass
    jne .out
    lea r8, [so_explosive]
.e:
    movzx ecx, word [r8]
    test ecx, ecx
    jz .phone
    cmp ecx, edi
    je .out
    add r8, 2
    jmp .e
.phone:                             ; 163..191 but the traffic light casings 170..173
    mov eax, SO_G_PHONE              ; and the briefcase 175
    cmp edi, 163
    jb .street
    cmp edi, 191
    ja .street
    cmp edi, 170
    jb .out
    cmp edi, 174
    je .out
    cmp edi, 176
    jae .out
.street:
    mov eax, SO_G_STREET
    cmp edx, 5                      ; a map object of the style
    je .out
    mov eax, SO_G_OTHER
.out:
    ret

; eax = so_rows(): the offered types, into so_list (group << 16 | type), by group, then type
so_rows:
    push rbx
    push r12
    push r13
    xor ebx, ebx
    xor r12d, r12d
    lea r13, [so_list]
.l:
    inc ebx
    cmp ebx, SO_NTYPES
    jae .sort
    mov edi, ebx
    call so_prefab
    test eax, eax
    jz .l
    mov edi, ebx
    mov esi, eax
    call so_group
    test eax, eax
    js .l
    shl eax, 16
    or eax, ebx
    mov [r13 + r12*4], eax
    inc r12d
    jmp .l
.sort:                              ; insertion sort, the keys are unique
    mov [so_n], r12d
    mov ebx, 1
.o:
    cmp ebx, r12d
    jae .out
    mov eax, [r13 + rbx*4]
    mov ecx, ebx
.i:
    test ecx, ecx
    jz .put
    mov edx, [r13 + rcx*4 - 4]
    cmp edx, eax
    jbe .put
    mov [r13 + rcx*4], edx
    dec ecx
    jmp .i
.put:
    mov [r13 + rcx*4], eax
    inc ebx
    jmp .o
.out:
    mov eax, r12d
    pop r13
    pop r12
    pop rbx
    ret

; so_name(edi = type, rsi = buffer of 64): our name (OBJECT_TYPE, re/gta2_types.h), else
; "Map object N" / "Object N"
so_name:
    push rbx
    push r12
    sub rsp, 24
    mov ebx, edi
    mov r12, rsi
    cmp ebx, 200                    ; pickups: the game's own text, key c%02d
    jb .ours                        ; (Hud_Pickup_Show 0x4C69F0, Seq 27)
    cmp ebx, 244
    ja .ours
    mov rdi, rsp
    mov esi, 16
    lea rdx, [fmt_so_gxt]
    lea ecx, [rbx - 200]
    xor eax, eax
    call _snprintf
    mov rdi, rsp
    mov rsi, r12
    mov edx, 40
    call dm_gxt
    test eax, eax
    jz .ours
    mov rdi, r12
    mov esi, '+'                    ; not in the menu font: our name instead
    call _strchr
    test rax, rax
    jz .out
.ours:
    lea rsi, [so_names]
.l:
    movzx eax, word [rsi]
    test eax, eax
    jz .none
    add rsi, 2
    cmp eax, ebx
    je .copy
.skip:
    lodsb
    test al, al
    jnz .skip
    jmp .l
.copy:
    mov rdi, r12
    call _strcpy
    jmp .out
.none:
    mov edi, ebx
    call so_prefab
    lea rdx, [fmt_so_obj]
    test eax, eax
    jz .f
    cmp dword [rax + 0x28], 5
    jne .f
    lea rdx, [fmt_so_mapobj]
.f:
    mov rdi, r12
    mov esi, 64
    mov ecx, ebx
    xor eax, eax
    call _snprintf
.out:
    add rsp, 24
    pop r12
    pop rbx
    ret

; so_rowfmt(edi = row, rsi = buffer): "Group: name"
so_rowfmt:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rsi
    lea rax, [so_list]
    mov ebx, [rax + rdi*4]
    mov eax, ebx
    shr eax, 16
    lea rcx, [so_gnames]
    mov rsi, [rcx + rax*8]
    mov rdi, r12
    call _strcpy
    mov rdi, r12
    call _strlen
    lea rsi, [r12 + rax]
    mov byte [rsi], ':'
    mov byte [rsi + 1], ' '
    add rsi, 2
    movzx edi, bx
    call so_name
    add rsp, 8
    pop r12
    pop rbx
    ret

; eax = so_nremaps(edi = type): remaps of its palette (StyleData +0x10 paletteCounts:
; +8 code obj, +0xA map obj), 0 if none
so_nremaps:
    sub rsp, 8
    call so_prefab
    test eax, eax
    jz .out
    mov ecx, [rax + 0x28]
    xor eax, eax
    mov edx, [abs STYLE_DATA]
    test edx, edx
    jz .out
    mov edx, [rdx + 0x10]
    test edx, edx
    jz .out
    lea ecx, [rcx*2]                ; type 4 -> +8, 5 -> +0xA
    movzx eax, word [rdx + rcx]
.out:
    add rsp, 8
    ret

; eax = so_remap_for(edi = type): so_remap clamped to its remaps (-1 = own colours)
so_remap_for:
    sub rsp, 8
    call so_nremaps
    mov ecx, eax
    mov eax, [so_remap]
    cmp eax, ecx
    jl .out
    mov eax, -1
.out:
    add rsp, 8
    ret

; so_rowchange(edi = row, esi = dir): LEFT / RIGHT the remap, RETURN spawns
so_rowchange:
    push rbx
    push r12
    sub rsp, 8
    mov r12d, esi
    lea rax, [so_list]
    movzx ebx, word [rax + rdi*4]
    mov edi, ebx
    call so_remap_for
    test r12d, r12d
    jz .spawn
    mov [rsp], eax
    mov edi, ebx
    call so_nremaps
    mov ecx, eax
    mov eax, [rsp]
    add eax, r12d                   ; wrap over -1 .. n - 1
    cmp eax, -1
    jge .hi
    lea eax, [rcx - 1]
.hi:
    cmp eax, ecx
    jl .set
    mov eax, -1
.set:
    mov [so_remap], eax
    jmp .out
.spawn:
    mov [so_spawn_remap], eax
    mov [so_spawn_type], ebx
    lea rdi, [so_spawn]
    call dm_defer
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; eax = so_key(edi = DIK): PAGE UP / PAGE DOWN jump to the previous / next group
so_key:
    xor eax, eax
    cmp edi, DIK_PRIOR
    je .go
    cmp edi, DIK_NEXT
    jne .out
.go:
    mov r8, [dm_page]
    mov ecx, [r8 + DPG_SEL]
    cmp ecx, [so_n]
    jae .out                        ; on Back: the generic keys
    lea r9, [so_list]
    movzx edx, word [r9 + rcx*4 + 2] ; the current group
    cmp edi, DIK_NEXT
    je .next
    test ecx, ecx                   ; first row of this group, else of the one before
    jz .set
    movzx eax, word [r9 + rcx*4 - 2]
    cmp eax, edx
    jne .prev
.first:
    dec ecx
    jz .set
    movzx eax, word [r9 + rcx*4 - 2]
    cmp eax, edx
    je .first
    jmp .set
.prev:
    mov edx, eax
    jmp .first
.next:
    inc ecx
    cmp ecx, [so_n]
    jae .wrap
    movzx eax, word [r9 + rcx*4 + 2]
    cmp eax, edx
    je .next
    jmp .set
.wrap:
    xor ecx, ecx
.set:
    mov [r8 + DPG_SEL], ecx
    mov eax, 1
.out:
    ret

; so_spawn (deferred): the script's spawn call at dm_spawn_pos, then the remap
so_spawn:
    push rbx
    push r12
    sub rsp, 40
    lea rdi, [rsp + 4]              ; [rsp] type, x, y, z, rotation
    mov esi, DM_SPAWN_DIST
    call dm_spawn_pos
    test eax, eax
    jz .toast_rdx
    mov eax, [so_spawn_type]
    mov [rsp], eax
    mov edi, 0x4852E0               ; SpawnObject
    cmp eax, 200
    jb .call
    cmp eax, 244
    ja .call
    mov edi, 0x485480               ; Object_NewPhysicsObjUnlessBlocked
.call:
    mov rsi, rsp
    mov edx, 5
    xor ecx, ecx
    mov r8d, [abs SO_SPAWNER]
    xor r9d, r9d
    call call32
    lea rdx, [s_so_blocked]
    test eax, eax
    jz .toast_rdx
    mov ebx, eax                    ; WorldObject*
    mov r12d, [rbx + 4]             ; its Sprite*
    mov eax, [so_spawn_remap]
    test eax, eax
    js .log
    test r12d, r12d
    jz .log
    mov [rsp + 32], eax
    mov edi, 0x4B9B00               ; Sprite_SetRemap
    lea rsi, [rsp + 32]
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
.log:
    lea rdi, [fmt_so_spawned]
    mov esi, [rsp]
    mov edx, ebx
    mov ecx, [rsp + 4]
    mov r8d, [rsp + 8]
    mov r9d, [so_spawn_remap]
    xor eax, eax
    call _printf
    lea rdx, [s_so_spawned]
.toast_rdx:
    mov rax, rdx
    call dm_toast_set
    add rsp, 40
    pop r12
    pop rbx
    ret

; so_draw(rdi = page): the preview pane for the selected object, lines measured first
; like sc_draw. Frame: [rsp] DMSPRITE, +40 remap choice, +44 pane width, +48 type,
; +64 SO_NLINES lines of SO_LINE bytes.
SO_NLINES equ 8
SO_LINE   equ 64
so_draw:
    push rbx
    push r12
    push r13
    sub rsp, 64 + SO_NLINES * SO_LINE
    mov r12, rdi
    call dm_dyn
    mov edi, [r12 + DPG_SEL]
    cmp edi, eax
    jae .out                        ; on Back
    lea rax, [so_list]
    mov r13d, [rax + rdi*4]         ; group << 16 | type
    movzx edi, r13w
    mov [rsp + 48], edi
    call so_prefab
    test eax, eax
    jz .out
    mov rbx, rax
    mov edi, [rsp + 48]             ; line 0: the name
    lea rsi, [rsp + 64]
    call so_name
    lea rdi, [rsp + 64 + SO_LINE]   ; line 1: "Weapon  type 200 (0xC8)"
    mov esi, SO_LINE
    lea rdx, [fmt_so_type]
    mov eax, r13d
    shr eax, 16
    lea rcx, [so_gnames]
    mov rcx, [rcx + rax*8]
    mov r8d, [rsp + 48]
    mov r9d, r8d
    xor eax, eax
    call _snprintf
    mov edi, [rbx + 0x28]           ; line 2: "Code obj 551+12  16x16"
    movzx esi, word [rbx + 0x1E]
    call dm_sprite_wh
    lea rdi, [rsp + 64 + 2 * SO_LINE]
    mov esi, SO_LINE
    lea rdx, [fmt_so_sprite]
    lea rcx, [s_so_codeobj]
    cmp dword [rbx + 0x28], 5
    jne .t2
    lea rcx, [s_so_mapobj]
.t2:
    movzx r8d, word [rbx + 0x1E]
    movzx r9d, al
    movzx eax, ah
    sub rsp, 16
    mov [rsp], eax                  ; h
    movzx eax, byte [rbx + 0x6C]
    mov [rsp + 8], eax              ; frames
    xor eax, eax
    call _snprintf
    add rsp, 16
    lea rdi, [rsp + 64 + 3 * SO_LINE] ; line 3: the kind and its flags
    mov eax, [rbx + 0x34]
    cmp eax, 12
    jbe .k
    mov eax, 13
.k:
    lea rcx, [so_knames]
    mov rsi, [rcx + rax*8]
    call _strcpy
    lea rdi, [rsp + 64 + 3 * SO_LINE]
    lea rsi, [s_so_solid]
    cmp dword [rbx + 0x40], 4       ; obstacles grid
    jne .f1
    call _strcat
.f1:
    lea rdi, [rsp + 64 + 3 * SO_LINE]
    lea rsi, [s_so_pushable]
    cmp dword [rbx + 0x44], 2
    jne .f2
    call _strcat
.f2:
    lea rdi, [rsp + 64 + 3 * SO_LINE]
    lea rsi, [s_so_explosive]
    cmp dword [rbx + 0x48], 0
    je .f3
    call _strcat
.f3:
    mov edi, [rsp + 48]             ; line 4: "Remap: own / i of n"
    call so_remap_for
    mov [rsp + 40], eax
    mov edi, [rsp + 48]
    call so_nremaps
    lea rdi, [rsp + 64 + 4 * SO_LINE]
    mov esi, SO_LINE
    lea rdx, [s_so_own]
    mov ecx, [rsp + 40]
    test ecx, ecx
    js .t4
    lea rdx, [fmt_so_remap]
    inc ecx
    mov r8d, eax
.t4:
    test eax, eax
    jnz .t4c
    lea rdx, [s_so_noremap]
.t4c:
    xor eax, eax
    call _snprintf
    lea rdi, [rsp + 64 + 5 * SO_LINE] ; lines 5..7: the keys
    lea rsi, [s_so_hint1]
    call _strcpy
    lea rdi, [rsp + 64 + 6 * SO_LINE]
    lea rsi, [s_so_hint2]
    call _strcpy
    lea rdi, [rsp + 64 + 7 * SO_LINE]
    lea rsi, [s_so_hint3]
    call _strcpy
    mov dword [rsp + 44], SO_BOX    ; width: the preview or the widest line
    xor r12d, r12d
.m:
    cmp r12d, SO_NLINES
    jae .box
    mov eax, r12d
    shl eax, 6
    lea rdi, [rsp + 64 + rax]
    call dm_text_w
    cmp eax, [rsp + 44]
    jbe .mn
    mov [rsp + 44], eax
.mn:
    inc r12d
    jmp .m
.box:
    mov esi, DM_Y
    mov ecx, DM_Y + SO_PANE_H
    mov edx, [rsp + 44]
    call dm_pane
    lea rdi, [rsp + 64]
    mov esi, [dm_pane_x]
    mov edx, DM_Y
    mov ecx, 1
    call dm_text_at
    mov eax, [rbx + 0x28]           ; the sprite: type, animated frame, palette, remap
    mov [rsp + DS_TYPE], eax
    xor edx, edx
    mov eax, [rbx + 0x34]           ; only the animated kinds 2, 4, 8, 9 cycle their frames
    cmp eax, 31
    ja .frame
    mov ecx, 0x314
    bt ecx, eax
    jnc .frame
    movzx ecx, byte [rbx + 0x64]    ; frame = (frames / (2 * ticks per frame)) % count
    test ecx, ecx
    jnz .tpf
    inc ecx
.tpf:
    add ecx, ecx
    mov eax, [r_frames]
    xor edx, edx
    div ecx
    movzx ecx, byte [rbx + 0x6C]
    xor edx, edx
    div ecx
.frame:
    movzx eax, word [rbx + 0x1E]
    add eax, edx
    mov [rsp + DS_ID], eax
    mov eax, [rbx + 0x30]
    mov [rsp + DS_PAL], eax
    xor eax, eax                    ; palette kind 2 ignores the prefab's remap,
    cmp dword [rbx + 0x30], 2       ; like ObjectPrefab_ApplyToPosition 0x4883A0
    je .r0
    movsx eax, word [rbx + 0x1C]
.r0:
    mov [rsp + DS_REMAP], eax
    mov eax, [rsp + 40]
    test eax, eax
    js .own
    mov [rsp + DS_REMAP], eax
    mov eax, [rbx + 0x28]           ; 4 code obj -> palette kind 5, 5 map obj -> 6
    inc eax
    mov [rsp + DS_PAL], eax
.own:
    mov eax, [rsp + 44]
    shr eax, 1
    add eax, [dm_pane_x]
    mov [rsp + DS_X], eax
    mov dword [rsp + DS_Y], DM_Y + 18 + SO_BOX / 2 + 4
    mov edi, [rbx + 0x28]           ; box = min(SO_BOX, SO_ZOOM x the diagonal)
    movzx esi, word [rbx + 0x1E]
    call dm_sprite_wh
    movzx ecx, al
    movzx eax, ah
    imul ecx, ecx
    imul eax, eax
    add eax, ecx
    cvtsi2sd xmm0, eax
    sqrtsd xmm0, xmm0
    cvttsd2si eax, xmm0
    imul eax, eax, SO_ZOOM
    cmp eax, SO_BOX
    jbe .bx
    mov eax, SO_BOX
.bx:
    mov [rsp + DS_BOX], eax
    mov dword [rsp + DS_ROT], 0
    mov rdi, rsp
    call dm_sprite
    mov r12d, 1                     ; lines 1..7 at the bottom, a gap before the keys
    mov r13d, DM_Y + SO_PANE_H - 7 * DM_LINE - DM_LINE / 2
.t:
    cmp r12d, SO_NLINES
    jae .out
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
    jmp .t
.out:
    add rsp, 64 + SO_NLINES * SO_LINE
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
fmt_so_gxt:     db "c%02d", 0
fmt_so_obj:     db "Object %d", 0
fmt_so_mapobj:  db "Map object %d", 0
fmt_so_type:    db "%s  type %d (0x%X)", 0
fmt_so_sprite:  db "%s sprite %d  %dx%d  %d fr", 0
fmt_so_remap:   db "Remap: %d of %d", 0
fmt_so_spawned: db "menu: spawn object type %d -> WorldObject 0x%x at x 0x%x y 0x%x, remap %d", 10, 0
s_so_codeobj:   db "Code obj", 0
s_so_mapobj:    db "Map obj", 0
s_so_solid:     db ", solid", 0
s_so_pushable:  db ", pushable", 0
s_so_explosive: db ", explosive", 0
s_so_own:       db "Remap: own colours", 0
s_so_noremap:   db "No remaps", 0
s_so_hint1:     db "Left Right: remap", 0
s_so_hint2:     db "PgUp PgDn: group", 0
s_so_hint3:     db "Return: spawn", 0
s_so_spawned:   db "Object spawned", 0
s_so_blocked:   db "Blocked here", 0
s_so_g0:        db "Street", 0
s_so_g1:        db "Weapon", 0
s_so_g2:        db "Car weapon", 0
s_so_g3:        db "Power-up", 0
s_so_g4:        db "Pickup", 0
s_so_g5:        db "Explosive", 0
s_so_g6:        db "Phone", 0
s_so_g7:        db "Other", 0
s_so_k0:        db "Static", 0
s_so_k1:        db "Static, notify", 0
s_so_k2:        db "Animated", 0
s_so_k3:        db "Physics", 0
s_so_k4:        db "Physics, animated", 0
s_so_k5:        db "Particles", 0
s_so_k6:        db "Collectable", 0
s_so_k7:        db "Collectable, physics", 0
s_so_k8:        db "Collectable, animated", 0
s_so_k9:        db "Collectable, phys anim", 0
s_so_k10:       db "Car shop", 0
s_so_k11:       db "Light", 0
s_so_k12:       db "Logic", 0
s_so_k13:       db "Kind ?", 0
align 8
so_gnames: dq s_so_g0, s_so_g1, s_so_g2, s_so_g3, s_so_g4, s_so_g5, s_so_g6, s_so_g7
so_knames: dq s_so_k0, s_so_k1, s_so_k2, s_so_k3, s_so_k4, s_so_k5, s_so_k6, s_so_k7
           dq s_so_k8, s_so_k9, s_so_k10, s_so_k11, s_so_k12, s_so_k13
; never offered: projectiles and their probe clones (docs/re/objects-and-weapons.md
; sections 2 and 6), crane and crusher parts (they belong to a Crane / Crusher), the
; bonus token (ObjectSpawner_CreateObject counts it against the level's 50 token flags),
; the bonus letters (GXT "na"; Ped_PickUp 0x43E550 would hand them to AddWeapon as weapons
; 11..14 / 24..27) and the ringing / in-call phones (touching one answers it through the
; mission script, PedGameObject_TryAnswerPhone 0x4930C0) - Seq 27 seq52_prep.md
so_skip:
    dw 0x80, 0x8A, 0x9A, 0x9F, 0xB7, 0xC0, 0xC1, 0xC2, 0xC3, 0xC6, 0xC7, 0xFB, 0xFE
    dw 0x109, 0x115
    dw 0x86, 0x87, 0x88, 0x8C, 0x8E, 0xFC, 0x104, 0x105, 0x106, 0x107, 0x10A
    dw 211, 212, 213, 214, 224, 225, 226, 227, 241, 242, 243, 244
    dw 164, 177, 179, 181, 184, 185, 186, 187, 188, 189, 190, 191
    dw 0
; explosive without an explosiveClass: they blow up by their own logic
so_explosive:
    dw 10, 132, 182, 247            ; MINE, CAR_BOMB, GRENADE, BOMB
    dw 0
; OBJECT_TYPE names (re/gta2_types.h, from seuko-mod's enum), made readable:
; COLLECT_nn_ dropped, words capitalised. Records: dw type, db name, 0; dw 0 ends.
%macro OC_NAME 2
    dw %1
    db %2, 0
%endmacro
so_names:
    OC_NAME 1, "Bin Lid"
    OC_NAME 2, "Bollard"
    OC_NAME 3, "Cone"
    OC_NAME 4, "Boxes"
    OC_NAME 5, "Blaster"
    OC_NAME 6, "Rubbish"
    OC_NAME 7, "Bin"
    OC_NAME 8, "Animating Oil"
    OC_NAME 9, "Oil"
    OC_NAME 10, "Mine"
    OC_NAME 11, "Bush"
    OC_NAME 12, "Crate"
    OC_NAME 13, "Football"
    OC_NAME 14, "Hard Box"
    OC_NAME 15, "News Dispenser"
    OC_NAME 16, "Oil Drum"
    OC_NAME 17, "Tyre"
    OC_NAME 18, "Hydrant Lid"
    OC_NAME 19, "Hydrant"
    OC_NAME 20, "Hydrant Unlid"
    OC_NAME 21, "Roadblock"
    OC_NAME 22, "Bench"
    OC_NAME 23, "Package"
    OC_NAME 25, "Tower"
    OC_NAME 43, "Moving Package"
    OC_NAME 44, "Dead Package"
    OC_NAME 45, "Moving Bench"
    OC_NAME 46, "Dead Bench"
    OC_NAME 47, "Moving Roadblock"
    OC_NAME 48, "Dead Roadblock"
    OC_NAME 49, "Moving Hydrant Lid"
    OC_NAME 50, "Animating Crate"
    OC_NAME 51, "Dead Crate"
    OC_NAME 52, "Dead Boxes"
    OC_NAME 53, "Dead Cone"
    OC_NAME 54, "Dead Blaster"
    OC_NAME 55, "Dead Bush"
    OC_NAME 56, "Moving Football"
    OC_NAME 57, "Moving Hard Box"
    OC_NAME 58, "Dead Hard Box"
    OC_NAME 59, "Moving News Dispenser"
    OC_NAME 60, "Dead News Dispenser"
    OC_NAME 61, "Moving Oil Drum"
    OC_NAME 62, "Dead Oil Drum"
    OC_NAME 63, "Moving Tyre"
    OC_NAME 65, "Moving S-Uzi"
    OC_NAME 66, "Moving Rocket Launcher"
    OC_NAME 67, "Moving Electrogun"
    OC_NAME 68, "Moving Molotov Cocktail"
    OC_NAME 69, "Moving Grenade"
    OC_NAME 70, "Moving Shotgun"
    OC_NAME 71, "Moving Electro Baton"
    OC_NAME 72, "Moving Flamethrower"
    OC_NAME 73, "Moving Silenced S-Uzi"
    OC_NAME 74, "Moving Dual Pistol"
    OC_NAME 75, "Moving Letter L"
    OC_NAME 76, "Moving Letter M"
    OC_NAME 77, "Moving Letter N"
    OC_NAME 78, "Moving Letter O"
    OC_NAME 79, "Moving Vehicle Bomb"
    OC_NAME 80, "Moving Vehicle Oil Slick"
    OC_NAME 81, "Moving Vehicle Mine"
    OC_NAME 82, "Moving Vehicle Machine Gun"
    OC_NAME 83, "Moving Tank Cannon"
    OC_NAME 84, "Moving Water Cannon"
    OC_NAME 85, "Moving Vehicle Flamethrower"
    OC_NAME 86, "Moving Jeep Turret"
    OC_NAME 87, "Moving Instant Vehicle Bomb"
    OC_NAME 88, "Moving Letter J"
    OC_NAME 89, "Moving Letter K"
    OC_NAME 90, "Moving Letter L"
    OC_NAME 91, "Moving Letter M"
    OC_NAME 92, "Moving Multiplier +1"
    OC_NAME 93, "Moving Life +1"
    OC_NAME 94, "Moving Health"
    OC_NAME 95, "Moving Armor"
    OC_NAME 96, "Moving Jail Free Card"
    OC_NAME 97, "Moving Cop Bribe"
    OC_NAME 98, "Moving Invulnerability"
    OC_NAME 99, "Moving Double Damage"
    OC_NAME 100, "Moving Fast Reload"
    OC_NAME 101, "Moving Electro Fingers"
    OC_NAME 102, "Moving Respect"
    OC_NAME 103, "Moving Invisibility"
    OC_NAME 104, "Moving Instant Gang"
    OC_NAME 105, "Moving Letter N"
    OC_NAME 106, "Moving Letter O"
    OC_NAME 107, "Moving Letter P"
    OC_NAME 108, "Moving Letter Q"
    OC_NAME 109, "Small Arrow"
    OC_NAME 110, "Vehicle Cone"
    OC_NAME 111, "Blood Spark"
    OC_NAME 112, "White Dot"
    OC_NAME 113, "Particle System"
    OC_NAME 114, "Firejet"
    OC_NAME 116, "Small Brown Skid"
    OC_NAME 117, "Small Grey Skid"
    OC_NAME 118, "Small Red Skid"
    OC_NAME 119, "Medium Brown Skid"
    OC_NAME 120, "Medium Grey Skid"
    OC_NAME 121, "Medium Red Skid"
    OC_NAME 122, "Car Crossing"
    OC_NAME 123, "Moving Bush"
    OC_NAME 124, "Big White Skid"
    OC_NAME 125, "Medium White Skid"
    OC_NAME 126, "Small White Skid"
    OC_NAME 128, "Rocket"
    OC_NAME 129, "Bus Stop Marker"
    OC_NAME 130, "Car Shop"
    OC_NAME 131, "Busy Car Shop"
    OC_NAME 132, "Car Bomb"
    OC_NAME 134, "Crane Wire"
    OC_NAME 135, "Crane Base"
    OC_NAME 136, "Crane Head A"
    OC_NAME 138, "Molotov Moving"
    OC_NAME 139, "Conveyor Belt"
    OC_NAME 140, "Crane Part A"
    OC_NAME 141, "Conveyor Belt End"
    OC_NAME 142, "Car Crusher"
    OC_NAME 144, "Huge Red Skid"
    OC_NAME 145, "Huge White Skid"
    OC_NAME 146, "Huge Brown Skid"
    OC_NAME 147, "Huge Grey Skid"
    OC_NAME 148, "Tank Top"
    OC_NAME 149, "Antenna"
    OC_NAME 151, "Animating Rubbish"
    OC_NAME 152, "Dead Rubbish"
    OC_NAME 154, "Flamethrower Flame"
    OC_NAME 155, "Moving Cone"
    OC_NAME 156, "Moving Blaster"
    OC_NAME 157, "Moving Bin"
    OC_NAME 158, "Moving Bin Lid"
    OC_NAME 161, "Save Point"
    OC_NAME 163, "Phone"
    OC_NAME 164, "Phone Ringing"
    OC_NAME 170, "Traffic Light Casing"
    OC_NAME 174, "Phone Dead"
    OC_NAME 175, "Briefcase"
    OC_NAME 176, "Red Phone"
    OC_NAME 177, "Red Phone Ringing"
    OC_NAME 178, "Yellow Phone"
    OC_NAME 179, "Yellow Phone Ringing"
    OC_NAME 180, "Green Phone"
    OC_NAME 181, "Green Phone Ringing"
    OC_NAME 182, "Grenade"
    OC_NAME 183, "Moving Grenade"
    OC_NAME 184, "Phone Call End"
    OC_NAME 185, "Phone Call"
    OC_NAME 186, "Red Phone Call End"
    OC_NAME 187, "Red Phone Call"
    OC_NAME 188, "Yellow Phone Call End"
    OC_NAME 189, "Yellow Phone Call"
    OC_NAME 190, "Green Phone Call End"
    OC_NAME 191, "Green Phone Call"
    OC_NAME 192, "Shot"
    OC_NAME 194, "Flaming Bullet"
    OC_NAME 197, "Fire"
    OC_NAME 198, "Water Bullet"
    OC_NAME 200, "Pistol"
    OC_NAME 201, "S-Uzi"
    OC_NAME 202, "Rocket Launcher"
    OC_NAME 203, "Electrogun"
    OC_NAME 204, "Molotov Cocktail"
    OC_NAME 205, "Grenade"
    OC_NAME 206, "Shotgun"
    OC_NAME 207, "Electro Baton"
    OC_NAME 208, "Flamethrower"
    OC_NAME 209, "Silenced S-Uzi"
    OC_NAME 210, "Dual Pistol"
    OC_NAME 211, "Letter L"
    OC_NAME 212, "Letter M"
    OC_NAME 213, "Letter N"
    OC_NAME 214, "Letter O"
    OC_NAME 215, "Vehicle Bomb"
    OC_NAME 216, "Vehicle Oil Slick"
    OC_NAME 217, "Vehicle Mine"
    OC_NAME 218, "Vehicle Machine Gun"
    OC_NAME 219, "Tank Cannon"
    OC_NAME 220, "Water Cannon"
    OC_NAME 221, "Vehicle Flamethrower"
    OC_NAME 222, "Jeep Turret"
    OC_NAME 223, "Instant Vehicle Bomb"
    OC_NAME 224, "Letter J"
    OC_NAME 225, "Letter K"
    OC_NAME 226, "Letter L"
    OC_NAME 227, "Letter M"
    OC_NAME 228, "Multiplier Up"
    OC_NAME 229, "Extra Life"
    OC_NAME 230, "Health"
    OC_NAME 231, "Armor"
    OC_NAME 232, "Jail Free Card"
    OC_NAME 233, "Cop Bribe"
    OC_NAME 234, "Invulnerability"
    OC_NAME 235, "Double Damage"
    OC_NAME 236, "Fast Reload"
    OC_NAME 237, "Electro Fingers"
    OC_NAME 238, "Respect"
    OC_NAME 239, "Invisibility"
    OC_NAME 240, "Instant Gang"
    OC_NAME 241, "Letter N"
    OC_NAME 242, "Letter O"
    OC_NAME 243, "Letter P"
    OC_NAME 244, "Letter Q"
    OC_NAME 247, "Bomb"
    OC_NAME 248, "Gun Jeep Turret"
    OC_NAME 249, "Big Brown Skid"
    OC_NAME 250, "Big Grey Skid"
    OC_NAME 252, "Crane Part B"
    OC_NAME 253, "Big Red Skid"
    OC_NAME 254, "Bullet"
    OC_NAME 255, "Traffic Light"
    OC_NAME 256, "Red Footprints"
    OC_NAME 257, "Blood"
    OC_NAME 258, "Crossing"
    OC_NAME 259, "Spark"
    OC_NAME 260, "Crane Part C"
    OC_NAME 261, "Crane Part D"
    OC_NAME 262, "Crane Part E"
    OC_NAME 263, "Crane Head B"
    OC_NAME 265, "Pistol Bullet"
    OC_NAME 266, "Bonus Token"
    OC_NAME 277, "Tasser Bullet"
    OC_NAME 279, "Sound Instant"
    OC_NAME 280, "Invisible Target"
    OC_NAME 281, "Power Generator"
    OC_NAME 282, "Power Generator Dead"
    OC_NAME 283, "Invisible Destructible"
    OC_NAME 284, "Generator Light"
    OC_NAME 285, "Invisible Dead"
    OC_NAME 286, "Kill Frenzy"
    OC_NAME 287, "Gang Decal Loonies"
    OC_NAME 288, "Gang Decal Yakuza"
    OC_NAME 289, "Gang Decal Zaibatsu"
    OC_NAME 290, "Gang Decal Rednecks"
    OC_NAME 291, "Gang Decal Scientists"
    OC_NAME 292, "Gang Decal Krishna"
    OC_NAME 293, "Gang Decal Russian"
    OC_NAME 294, "Tunnel Blocker"
    OC_NAME 295, "Remote"
    dw 0

section .bss
so_n:           resd 1
so_spawn_type:  resd 1
so_spawn_remap: resd 1
so_list:        resd SO_NTYPES
section .text
