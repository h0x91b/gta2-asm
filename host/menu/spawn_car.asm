; menu/spawn_car.asm — Spawn > Car: every car model of the current level's style that
; SpawnCar accepts, named from the GXT, with a remap picker and a live, rotating preview
; of the car in that remap. Built through the recipe in docs/debug-menu.md: one DM_PAGE
; with dynamic rows (sc_rows / sc_rowfmt / sc_rowchange) and a draw callback (sc_draw)
; that uses the shared dm_sprite component.
;
;   UP / DOWN       model           LEFT / RIGHT   remap: random (the game's pick on spawn),
;   RETURN          spawn it 1.5 blocks in front     none (the sprite's own colours), or
;                   of the player with that remap     each of the model's own remaps
;
; Facts (re/ + Seq 27 report seq49-car-sprite-remap.md): CarInfo (dm_car_info) +1
; spriteIndex = id relative to the car sprite base, +4 num_remaps, +0xe remap[] = indices
; into the car-remap palette base (palette kind 3); the remap lives on the car's body
; (Car +0x50, a Sprite): Sprite_SetRemap @0x4B9B00 thiscall(Sprite*, ushort remap)
; sets +0x24 and the render state +0x34, Sprite_SetNoRemapState @0x420700
; fastcall(Sprite*) restores the sprite's colours. Car_ApplyRemap @0x421FD0 is not
; used: it skips models with num_remaps <= 1 (Car_NeedsRemapChange @0x421F40).

SC_REMAP_RANDOM equ -1              ; sc_remap: -1 random, 0 none, i = CarInfo.remap[i - 1]
SC_PANE_H  equ 268
SC_BOX     equ 150                  ; preview: the car's diagonal fits this many units
SC_SPIN    equ 3                    ; preview rotation per frame (1440 per turn)

section .data
    DM_PAGE  dmp_spawn_car, dmp_spawn, 10, "Car", sc_draw, 0, sc_rows, sc_rowfmt, sc_rowchange
sc_remap:  dd 0
section .text

; eax = sc_rows(): the spawnable models this style has, into sc_idx (dm_spawnable indices)
sc_rows:
    push rbx
    push r12
    sub rsp, 8
    xor ebx, ebx
    xor r12d, r12d
.l:
    cmp ebx, DM_NSPAWNABLE
    jae .d
    lea rax, [dm_spawnable]
    movzx edi, byte [rax + rbx]
    call dm_car_info
    test eax, eax
    jz .n
    lea rax, [sc_idx]
    mov [rax + r12], bl
    inc r12d
.n:
    inc ebx
    jmp .l
.d:
    mov [sc_n], r12d
    call sc_sort
    mov eax, [sc_n]
    add rsp, 8
    pop r12
    pop rbx
    ret

; sc_sort: sc_idx by CarInfo.rating, highest first (99 "not recycled": tanks, cops, buses;
; then 21..23 good, 11..13 average, 1..3 bad: DMA's GTA2 Style Format, docs/formats/specs/),
; stable, so ties keep the model order
sc_sort:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r14, [sc_idx]
    lea r15, [sc_key]
    xor ebx, ebx
.k:                                 ; sc_key[i] = rating of sc_idx[i]
    cmp ebx, [sc_n]
    jae .sort
    mov edi, ebx
    call sc_model
    mov edi, eax
    call dm_car_info
    movzx eax, byte [rax + 7]
    mov [r15 + rbx], al
    inc ebx
    jmp .k
.sort:
    mov ebx, 1
.o:
    cmp ebx, [sc_n]
    jae .out
    movzx r12d, byte [r14 + rbx]
    movzx r13d, byte [r15 + rbx]
    mov ecx, ebx
.i:
    test ecx, ecx
    jz .put
    movzx eax, byte [r15 + rcx - 1]
    cmp eax, r13d
    jae .put
    mov [r15 + rcx], al
    mov al, [r14 + rcx - 1]
    mov [r14 + rcx], al
    dec ecx
    jmp .i
.put:
    mov [r14 + rcx], r12b
    mov [r15 + rcx], r13b
    inc ebx
    jmp .o
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rsi = sc_class(eax = rating): its class name
sc_class:
    lea rsi, [s_sc_special]
    cmp eax, 99
    je .out
    lea rsi, [s_sc_good]
    cmp eax, 21
    jae .out
    lea rsi, [s_sc_average]
    cmp eax, 11
    jae .out
    lea rsi, [s_sc_bad]
.out:
    ret

; eax = sc_model(edi = row): its CAR_MODEL4 id
sc_model:
    lea rax, [sc_idx]
    movzx eax, byte [rax + rdi]
    lea rcx, [dm_spawnable]
    movzx eax, byte [rcx + rax]
    ret

; sc_name(edi = model, rsi = buffer of 64): the GXT name ("car%d"), else our CAR_MODEL4 name
sc_name:
    push rbx
    push r12
    sub rsp, 24
    mov ebx, edi
    mov r12, rsi
    mov rdi, rsp
    mov esi, 16
    lea rdx, [fmt_sc_key]
    mov ecx, ebx
    xor eax, eax
    call _snprintf
    mov rdi, rsp
    mov rsi, r12
    mov edx, 40
    call dm_gxt
    test eax, eax
    jz .ours
    cmp byte [r12], ' '             ; e.gxt has " " for the unused models
    jne .out
.ours:
    lea rcx, [dm_car_names]
    mov rsi, [rcx + rbx*8]
    mov rdi, r12
    call _strcpy
.out:
    add rsp, 24
    pop r12
    pop rbx
    ret

sc_rowfmt:
    push rbx
    mov rbx, rsi
    call sc_model
    mov edi, eax
    mov rsi, rbx
    call sc_name
    pop rbx
    ret

; eax = sc_remap_for(edi = model): sc_remap clamped to that model's remaps; edx = CarInfo*
sc_remap_for:
    sub rsp, 8
    call dm_car_info
    mov edx, eax
    mov eax, [sc_remap]
    test edx, edx
    jz .out
    movzx ecx, byte [rdx + 4]       ; num_remaps
    cmp eax, ecx
    jle .out
    mov eax, ecx
.out:
    add rsp, 8
    ret

; sc_rowchange(edi = row, esi = dir): LEFT / RIGHT the remap, RETURN spawns
sc_rowchange:
    push rbx
    push r12
    sub rsp, 8
    mov r12d, esi
    call sc_model
    mov ebx, eax
    mov edi, eax
    call sc_remap_for
    test r12d, r12d
    jz .spawn
    test edx, edx
    jz .out
    movzx ecx, byte [rdx + 4]
    add eax, r12d                   ; wrap over -1 .. num_remaps
    cmp eax, SC_REMAP_RANDOM
    jge .hi
    mov eax, ecx
.hi:
    cmp eax, ecx
    jle .set
    mov eax, SC_REMAP_RANDOM
.set:
    mov [sc_remap], eax
    jmp .out
.spawn:                             ; resolve the remap now, spawn on the game's side
    mov ecx, -2                     ; none
    test eax, eax
    jz .r
    mov ecx, -1                     ; random: leave the game's pick
    js .r
    movzx ecx, byte [rdx + 0xe + rax - 1]
.r:
    mov [sc_spawn_remap], ecx
    lea rcx, [sc_idx]               ; the selected row's model, as a dm_spawnable index
    mov rdx, [dm_page]
    mov edi, [rdx + DPG_SEL]
    movzx eax, byte [rcx + rdi]
    mov [dm_model], eax
    lea rdi, [sc_spawn]
    call dm_defer
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; sc_spawn (deferred): dm_spawn_car, then the remap on the new car's body
sc_spawn:
    push rbx
    sub rsp, 16
    call dm_spawn_car
    test eax, eax
    jz .out
    mov ebx, [rax + CAR_SPRITE]
    test ebx, ebx
    jz .out
    mov eax, [sc_spawn_remap]
    cmp eax, -1
    je .log
    cmp eax, -2
    jne .remap
    mov edi, 0x420700               ; Sprite_SetNoRemapState
    mov esi, ebx
    call dm_call_car
    jmp .log
.remap:
    mov [rsp], eax
    mov edi, 0x4B9B00               ; Sprite_SetRemap
    mov rsi, rsp
    mov edx, 1
    xor ecx, ecx
    mov r8d, ebx
    xor r9d, r9d
    call call32
.log:
    lea rdi, [fmt_sc_spawned]
    mov esi, [sc_spawn_remap]
    movsx edx, word [rbx + 0x24]
    mov ecx, [rbx + 0x34]
    xor eax, eax
    call _printf
.out:
    add rsp, 16
    pop rbx
    ret

; sc_draw(rdi = page): the preview pane for the selected model. The text lines are built
; first and measured (dm_text_w), so the pane fits the widest of them and the preview.
; Frame: [rsp] DMSPRITE, +40 remap choice, +44 pane width, +64 SC_NLINES lines of 64 bytes.
SC_NLINES equ 6
SC_LINE   equ 64
sc_draw:
    push rbx
    push r12
    push r13
    sub rsp, 64 + SC_NLINES * SC_LINE
    mov r12, rdi
    call dm_dyn
    mov edi, [r12 + DPG_SEL]
    cmp edi, eax
    jae .out                        ; on Back
    call sc_model
    mov r13d, eax
    mov edi, eax
    call dm_car_info
    test eax, eax
    jz .out
    mov rbx, rax
    mov edi, r13d                   ; line 0: the name
    lea rsi, [rsp + 64]
    call sc_name
    mov edi, r13d
    call sc_remap_for
    mov [rsp + 40], eax
    mov dword [rsp + DS_PAL], 2     ; none / random: the sprite's own colours
    mov dword [rsp + DS_REMAP], 0
    test eax, eax
    jle .l1
    mov dword [rsp + DS_PAL], 3     ; car remap
    movzx ecx, byte [rbx + 0xe + rax - 1]
    mov [rsp + DS_REMAP], ecx
.l1:                                ; line 1: "Remap: random / none / i of n (palette p)"
    lea rdi, [rsp + 64 + SC_LINE]
    mov esi, SC_LINE
    mov eax, [rsp + 40]
    lea rdx, [s_sc_random]
    test eax, eax
    js .t1
    lea rdx, [s_sc_none]
    jz .t1
    lea rdx, [fmt_sc_remap]
    mov ecx, eax
    movzx r8d, byte [rbx + 4]
    mov r9d, [rsp + DS_REMAP]
.t1:
    xor eax, eax
    call _snprintf
    lea rdi, [rsp + 64 + 2 * SC_LINE] ; line 2: "Model 12  32x64"
    mov esi, SC_LINE
    lea rdx, [fmt_sc_model]
    mov ecx, r13d
    movzx r8d, byte [rbx + 2]
    movzx r9d, byte [rbx + 3]
    xor eax, eax
    call _snprintf
    movzx eax, byte [rbx + 7]       ; line 3: "Seats 4  Rating 21 good"
    call sc_class
    mov r9, rsi
    lea rdi, [rsp + 64 + 3 * SC_LINE]
    mov esi, SC_LINE
    lea rdx, [fmt_sc_seats]
    movzx ecx, byte [rbx + 5]       ; passengers, plus the driver
    inc ecx
    movzx r8d, byte [rbx + 7]
    xor eax, eax
    call _snprintf
    lea rdi, [rsp + 64 + 4 * SC_LINE] ; lines 4, 5: the keys
    lea rsi, [s_sc_hint1]
    call _strcpy
    lea rdi, [rsp + 64 + 5 * SC_LINE]
    lea rsi, [s_sc_hint2]
    call _strcpy
    mov dword [rsp + 44], SC_BOX    ; width: the preview or the widest line
    xor r12d, r12d
.m:
    cmp r12d, SC_NLINES
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
    mov ecx, DM_Y + SC_PANE_H
    mov edx, [rsp + 44]
    call dm_pane
    lea rdi, [rsp + 64]
    mov esi, [dm_pane_x]
    mov edx, DM_Y
    mov ecx, 1
    call dm_text_at
    mov dword [rsp + DS_TYPE], 2    ; SPRITE_TYPE_CAR
    movzx eax, byte [rbx + 1]
    mov [rsp + DS_ID], eax
    mov eax, [rsp + 44]
    shr eax, 1
    add eax, [dm_pane_x]
    mov [rsp + DS_X], eax
    mov dword [rsp + DS_Y], DM_Y + 18 + SC_BOX / 2 + 4
    mov dword [rsp + DS_BOX], SC_BOX
    mov eax, [r_frames]
    imul eax, eax, SC_SPIN
    xor edx, edx
    mov ecx, 1440
    div ecx
    mov [rsp + DS_ROT], edx
    mov rdi, rsp
    call dm_sprite
    mov r12d, 1                     ; lines 1..5 at the bottom, a gap before the keys
    mov r13d, DM_Y + SC_PANE_H - 5 * DM_LINE - DM_LINE / 2
.t:
    cmp r12d, SC_NLINES
    jae .out
    cmp r12d, 4
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
    add rsp, 64 + SC_NLINES * SC_LINE
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
fmt_sc_key:     db "car%d", 0
fmt_sc_remap:   db "Remap: %d of %d (%d)", 0
fmt_sc_model:   db "Model %d  %dx%d", 0
fmt_sc_seats:   db "Seats %d  Rating %d %s", 0
s_sc_special:   db "special", 0
s_sc_good:      db "good", 0
s_sc_average:   db "average", 0
s_sc_bad:       db "bad", 0
s_sc_random:    db "Remap: random", 0
s_sc_none:      db "Remap: none", 0
s_sc_hint1:     db "Left Right: remap", 0
s_sc_hint2:     db "Return: spawn", 0
fmt_sc_spawned: db "menu: spawn car remap choice %d -> body remap %d palette kind %d", 10, 0

section .bss
sc_n:           resd 1
sc_spawn_remap: resd 1
sc_idx:         resb 256
sc_key:         resb 256
section .text
