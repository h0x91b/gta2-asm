; debug_roadblocks.asm — "Place roadblock" / "Remove roadblocks" on the debug menu's Player
; page (K): a real police roadblock (cars across the road, barriers, cops behind them)
; built by the game's own code on the nearest road tile ahead of the player, kept until
; "Remove roadblocks", up to RB_SLOTS at once, at any wanted level.
;
; How the game does it (Ghidra, gta2-segments.fixed.exe, decompiled 2026-10-21):
; - PoliceManager (pointer at 0x66B7A0) has only roadblocks[2] at +0x664 (PoliceRoadblock, 0xA4,
;   re/gta2_types.h). PoliceManager_TryCreateRoadblockAt 0x4AEE70, thiscall(tileX, tileY,
;   dir), ret 0xC: picks the crew kind from copLevel +0x654 (3, 4 police, 5 FBI, 6 army ->
;   g_crewSpawnKind 0x66B798), z = FindMaxZ at the tile, then PoliceRoadblock_Create
;   0x4ADB70 on roadblocks[0] (else [1]) with orientation 3 for dir 1/2 (road along y: it
;   scans x for the road's width) or 2 otherwise (road along x). Create walks the road's
;   ground type (block +0xB & 3, 1 = road) across up to 12 tiles, checks the box for
;   obstacles, then alternates barrier pairs + a guard (PoliceManager_SpawnRoadblockGuard
;   0x4A9B40: police or FBI only) and cars (CarManager_SpawnCarOnGround, category
;   ROADBLOCK, driverClass 4) lane by lane; active = 1, lifeTimer = 100.
; - What removes one: PoliceRoadblock_Update 0x4AD6C0, called by PoliceManager_Update
;   0x4AEF70 for those two slots only, counts lifeTimer down, then once no car, barrier or
;   guard has been on screen for 0xC9 ticks and the player is far enough, calls
;   PoliceRoadblock_Remove 0x4ABD70. Nothing else in the police code removes them; the
;   cars themselves are not recycled (Car_CanBeRecycled 0x424030 refuses driverClass 4).
; - So ours live in our own slots (low memory, one PoliceRoadblock_Ctor 0x4AC040 each)
;   that the game never updates: no timer, no despawn, no tie to the wanted level. Each
;   slot has a 16-byte header in front whose first dword plays PoliceManager.copLevel, so
;   TryCreateRoadblockAt runs on `slot - 0x664` (it reads nothing else of the manager)
;   and does the crew pick and the z of the original. Once per gameplay frame
;   rb_frame drops car pointers whose driverClass is no longer 4 and guards that left the
;   game or are no longer ROAD_BLOCK_GUARD (their slots get reused), as Update does, so
;   Remove only touches what is still ours. A new Game* (another level) forgets them.
;
; Placement: from the player (or their car) along its rotation, every half block from 1
; to 12 blocks ahead, else ring by ring around them out to 16 tiles (the nearest road
; first), the first tile whose block one level below the player's z is road
; (MapBlocks_GetBlock 0x4653C0 on g_MapBlocks 0x662C08, ground = block +0xB & 3) and at
; least RB_GAP tiles from another of ours: Create's obstacle box does not see cars, so
; without the gap three roadblocks stacked up on neighbouring tiles (measured). The
; road's direction comes from its green arrows (block +0xA: bits 0-1 left/right, 2-3
; up/down, docs/formats/lessons.md); a junction or an unmarked tile falls back to the
; player's heading. When Create refuses (an obstacle, a road wider than 12) the search
; goes on.
;
; Test build: NASMFLAGS=-DRB_TRACE logs the player's position every 50 frames (for
; --keys walks).

RB_SLOTS     equ 8
RB_HDR       equ 0x10               ; header: fake PoliceManager.copLevel at slot - RB_HDR,
RB_HTX       equ -0xc               ;   then the tile rb_place built the roadblock on
RB_HTY       equ -0x8
RB_GAP       equ 4                  ; tiles kept between two of ours (Create does not see cars)
RB_STRIDE    equ RB_HDR + 0xa4
RB_ACTIVE    equ 0x0                ; PoliceRoadblock (re/gta2_types.h)
RB_CARS      equ 0x10               ; Car*[6]
RB_GUARDS    equ 0x88               ; Ped*[6]
RB_RECT      equ 0xa0               ; collisionRect (Ctor's operator_new; kept)
RB_FAKE_MGR  equ 0x664              ; PoliceManager.roadblocks
CAR_DRVCLASS equ 0x7c
PED_OCC      equ 0x240
OCC_RB_GUARD equ 37                 ; ROAD_BLOCK_GUARD (docs/re/gangs-and-peds.md)
MAPBLOCKS    equ 0x662C08
RB_REQ_PLACE equ 1
RB_REQ_CLEAR equ 2

section .text

; rb_frame: from hk_DrawUI, once per gameplay frame: requests from the menu, housekeeping
rb_frame:
    push rbx
    push r12
    push r13
    cmp qword [rb_mem], 0
    je .req
    mov eax, [abs 0x5EB4FC]         ; Game*
    cmp eax, [rb_game]
    je .req
    mov [rb_game], eax
    call rb_forget
.req:
    movzx ebx, byte [rb_req]
    mov byte [rb_req], 0
    cmp ebx, RB_REQ_PLACE
    jne .r2
    call rb_place
.r2:
    cmp ebx, RB_REQ_CLEAR
    jne .prune
    call rb_clear
.prune:
    cmp qword [rb_mem], 0
    je .out
    xor ebx, ebx
.slot:
    mov eax, ebx
    call rb_slot
    mov r12, rax
    cmp byte [r12 + RB_ACTIVE], 0
    je .next
    xor r13d, r13d
.car:
    mov eax, [r12 + RB_CARS + r13*4]
    test eax, eax
    jz .car_next
    cmp dword [rax + CAR_DRVCLASS], 4
    je .car_next
    mov dword [r12 + RB_CARS + r13*4], 0
.car_next:
    inc r13d
    cmp r13d, 6
    jb .car
    xor r13d, r13d
.guard:
    mov eax, [r12 + RB_GUARDS + r13*4]
    test eax, eax
    jz .guard_next
    cmp dword [rax + PED_OCC], OCC_RB_GUARD
    jne .drop
    mov edi, 0x433B40               ; Ped_IsAttachedToGame, fastcall(Ped* ecx)
    mov esi, eax
    call dm_call_car
    test al, al
    jnz .guard_next
.drop:
    mov dword [r12 + RB_GUARDS + r13*4], 0
.guard_next:
    inc r13d
    cmp r13d, 6
    jb .guard
.next:
    inc ebx
    cmp ebx, RB_SLOTS
    jb .slot
.out:
%ifdef RB_TRACE
    mov eax, [r_frames]             ; test build: where the player is, every 50 frames
    xor edx, edx
    mov ecx, 50
    div ecx
    test edx, edx
    jnz .notrace
    call dm_player_ped
    test eax, eax
    jz .notrace
    lea rdi, [fmt_rb_trace]
    mov esi, [r_frames]
    mov edx, [rax + PED_POS]
    sar edx, 10
    mov ecx, [rax + PED_POS + 4]
    sar ecx, 10
    movzx r8d, word [rax + PED_ROT]
    xor eax, eax
    call _printf
.notrace:
%endif
    pop r13
    pop r12
    pop rbx
    ret

; rax = rb_slot(eax = index): the PoliceRoadblock of that slot
rb_slot:
    imul eax, eax, RB_STRIDE
    add rax, [rb_mem]
    add rax, RB_HDR
    ret

; eax = rb_count(): active slots
rb_count:
    xor eax, eax
    mov rcx, [rb_mem]
    test rcx, rcx
    jz .out
    add rcx, RB_HDR
    mov edx, RB_SLOTS
.c:
    cmp byte [rcx + RB_ACTIVE], 0
    je .n
    inc eax
.n:
    add rcx, RB_STRIDE
    dec edx
    jnz .c
.out:
    ret

; rb_ensure: the slots, each through PoliceRoadblock_Ctor (allocates its collisionRect)
rb_ensure:
    push rbx
    push r12
    sub rsp, 8
    cmp qword [rb_mem], 0
    jne .out
    mov edi, RB_SLOTS * RB_STRIDE
    mov esi, 16
    call low_alloc
    mov [rb_mem], rax
    mov rdi, rax
    mov ecx, RB_SLOTS * RB_STRIDE
    xor eax, eax
    rep stosb
    mov eax, [abs 0x5EB4FC]
    mov [rb_game], eax
    xor ebx, ebx
.c:
    mov eax, ebx
    call rb_slot
    mov edi, 0x4AC040               ; PoliceRoadblock_Ctor, thiscall, no arguments
    mov esi, eax
    call dm_call_car
    inc ebx
    cmp ebx, RB_SLOTS
    jb .c
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; rb_forget: another level — the old cars, peds and objects are gone, keep only the rects
rb_forget:
    xor edx, edx
.c:
    mov eax, edx
    call rb_slot
    mov rdi, rax
    mov ecx, RB_RECT
    xor eax, eax
    rep stosb
    inc edx
    cmp edx, RB_SLOTS
    jb .c
    ret

; rb_place: the next free slot, on the first road tile ahead of the player, else on the
; nearest road tile around them (rings out to RB_RING)
RB_STEPS equ 24                     ; half blocks ahead
RB_RING  equ 16
rb_place:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    call rb_ensure
    lea r15, [s_rb_full]
    xor ebx, ebx
.free:
    mov eax, ebx
    call rb_slot
    cmp byte [rax + RB_ACTIVE], 0
    je .got
    inc ebx
    cmp ebx, RB_SLOTS
    jb .free
    jmp .toast
.got:
    mov [rb_cur], rax
    lea r15, [s_dm_noplayer2]
    call dm_player_ped
    test eax, eax
    jz .toast
    lea rcx, [rax + PED_POS]        ; x, y, z
    movzx edx, word [rax + PED_ROT]
    mov eax, [rax + PED_CAR]
    test eax, eax
    jz .pos
    mov eax, [rax + CAR_SPRITE]     ; in a car: its sprite (rotation +0, position +0x14)
    test eax, eax
    jz .toast
    lea rcx, [rax + 0x14]
    movzx edx, word [rax]
.pos:
    mov eax, [rcx]
    mov [rb_px], eax
    mov eax, [rcx + 4]
    mov [rb_py], eax
    mov eax, [rcx + 8]
    sar eax, 14
    dec eax
    mov [rb_z], eax                 ; block level under the player
    mov [rb_rot], edx
    ; half a block along (sin a, cos a), the convention dm_spawn_car uses
    mov [rsp], edx
    fild dword [rsp]
    fmul qword [f_dm_rot2rad]
    fsincos                         ; st0 = cos, st1 = sin
    fimul dword [i_rb_half]
    fistp dword [rb_sdy]
    fimul dword [i_rb_half]
    fistp dword [rb_sdx]
    lea r15, [s_rb_noroad]
    mov r13d, 2
.step:                              ; straight ahead
    mov edi, [rb_sdx]
    imul edi, r13d
    add edi, [rb_px]
    sar edi, 14
    mov esi, [rb_sdy]
    imul esi, r13d
    add esi, [rb_py]
    sar esi, 14
    call rb_try
    test eax, eax
    jnz .placed
    inc r13d
    cmp r13d, RB_STEPS
    jbe .step
    mov r12d, 1                     ; ring radius
.ring:
    mov r13d, r12d
    neg r13d                        ; dy
.ry:
    mov r14d, r12d
    neg r14d                        ; dx
.rx:
    mov eax, r14d                   ; only the ring's border
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, r12d
    je .cell
    mov eax, r13d
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, r12d
    jne .rnext
.cell:
    mov edi, [rb_px]
    sar edi, 14
    add edi, r14d
    mov esi, [rb_py]
    sar esi, 14
    add esi, r13d
    call rb_try
    test eax, eax
    jnz .placed
.rnext:
    inc r14d
    cmp r14d, r12d
    jle .rx
    inc r13d
    cmp r13d, r12d
    jle .ry
    inc r12d
    cmp r12d, RB_RING
    jbe .ring
    lea rdi, [fmt_rb_nolog]
    mov esi, [rb_px]
    mov edx, [rb_py]
    mov ecx, [rb_z]
    mov r8d, [rb_rot]
    xor eax, eax
    call _printf
    jmp .toast
.placed:
    mov rax, [rb_cur]               ; log: tile, dir, first car's position, cops
    xor ecx, ecx
    mov [rsp], rcx
    mov [rsp + 8], rcx
    mov [rsp + 16], rcx
    mov ecx, [rax + RB_CARS]
    test ecx, ecx
    jz .log
    mov ecx, [rcx + CAR_SPRITE]
    test ecx, ecx
    jz .log
    mov edx, [rcx + 0x14]
    mov [rsp], rdx
    mov edx, [rcx + 0x18]
    mov [rsp + 8], rdx
    mov edx, [rcx + 0x1c]
    mov [rsp + 16], rdx
.log:
    xor r8d, r8d                    ; cars, guards
    xor r9d, r9d
    xor ecx, ecx
.cnt:
    cmp dword [rax + RB_CARS + rcx*4], 0
    setne dl
    movzx edx, dl
    add r8d, edx
    cmp dword [rax + RB_GUARDS + rcx*4], 0
    setne dl
    movzx edx, dl
    add r9d, edx
    inc ecx
    cmp ecx, 6
    jb .cnt
    lea rdi, [fmt_rb_log]
    mov esi, [rb_tx]
    mov edx, [rb_ty]
    mov ecx, [rb_dir]
    xor eax, eax
    call _printf
    call rb_count
    lea rdi, [rb_toast_buf]
    mov esi, 40
    lea rdx, [fmt_rb_placed]
    mov ecx, eax
    xor eax, eax
    call _snprintf
    lea r15, [rb_toast_buf]
.toast:
    mov [dm_toast], r15
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax = rb_try(edi = tile x, esi = tile y): 1 when a roadblock now stands in [rb_cur]
; around that tile (road at level [rb_z]; the direction from its arrows or the heading)
rb_try:
    push rbx
    sub rsp, 16
    xor ebx, ebx
    cmp edi, 255
    ja .out
    cmp esi, 255
    ja .out
    mov eax, [rb_z]
    cmp eax, 7
    ja .out
    mov [rb_tx], edi
    mov [rb_ty], esi
    xor ecx, ecx                    ; not within RB_GAP of one of ours
.near:
    mov eax, ecx
    call rb_slot
    cmp byte [rax + RB_ACTIVE], 0
    je .far
    mov edx, [rax + RB_HTX]
    sub edx, edi
    add edx, RB_GAP
    cmp edx, 2 * RB_GAP
    ja .far
    mov edx, [rax + RB_HTY]
    sub edx, esi
    add edx, RB_GAP
    cmp edx, 2 * RB_GAP
    jbe .out
.far:
    inc ecx
    cmp ecx, RB_SLOTS
    jb .near
    mov eax, [rb_z]
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], eax
    mov edi, 0x4653C0               ; MapBlocks_GetBlock, thiscall(x, y, z) -> block or 0
    mov rsi, rsp
    mov edx, 3
    xor ecx, ecx
    mov r8d, [abs MAPBLOCKS]
    xor r9d, r9d
    call call32
    mov eax, eax                    ; edx:eax back, only eax is the pointer
    test eax, eax
    jz .out
    movzx ecx, byte [rax + 0xb]
    and ecx, 3
    cmp ecx, 1                      ; road
    jne .out
    movzx ecx, byte [rax + 0xa]     ; green arrows
    mov edx, 1                      ; dir 1: road along y
    test ecx, 0xc
    jz .horiz
    test ecx, 3
    jz .dir
    jmp .heading
.horiz:
    mov edx, 3                      ; dir 3: road along x
    test ecx, 3
    jnz .dir
.heading:                           ; junction or no arrows: the way the player faces
    mov eax, [rb_sdx]
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, eax                    ; |dx|
    mov eax, [rb_sdy]
    cdq
    xor eax, edx
    sub eax, edx                    ; |dy|
    mov edx, 1
    cmp eax, ecx
    jge .dir
    mov edx, 3
.dir:
    mov [rb_dir], edx
    mov r8, [rb_cur]
    movzx eax, byte [rb_kind]
    lea rcx, [rb_kind_cop]
    movzx eax, byte [rcx + rax]
    mov [r8 - RB_HDR], eax          ; fake PoliceManager.copLevel
    mov eax, [rb_tx]
    mov [rsp], eax
    mov eax, [rb_ty]
    mov [rsp + 4], eax
    mov [rsp + 8], edx
    mov edi, 0x4AEE70               ; PoliceManager_TryCreateRoadblockAt
    mov rsi, rsp
    mov edx, 3
    xor ecx, ecx
    sub r8, RB_FAKE_MGR
    xor r9d, r9d
    call call32
    mov rax, [rb_cur]
    cmp byte [rax + RB_ACTIVE], 0
    setne bl
    mov ecx, [rb_tx]
    mov [rax + RB_HTX], ecx
    mov ecx, [rb_ty]
    mov [rax + RB_HTY], ecx
.out:
    mov eax, ebx
    add rsp, 16
    pop rbx
    ret

; rb_clear: PoliceRoadblock_Remove on every active slot, as the game ends its own ones
rb_clear:
    push rbx
    push r12
    sub rsp, 8
    xor r12d, r12d
    cmp qword [rb_mem], 0
    je .toast
    xor ebx, ebx
.c:
    mov eax, ebx
    call rb_slot
    cmp byte [rax + RB_ACTIVE], 0
    je .n
    inc r12d
    mov edi, 0x4ABD70               ; PoliceRoadblock_Remove, thiscall, no arguments
    mov esi, eax
    call dm_call_car
.n:
    inc ebx
    cmp ebx, RB_SLOTS
    jb .c
.toast:
    lea rdi, [fmt_rb_removelog]
    mov esi, r12d
    xor eax, eax
    call _printf
    lea rdi, [rb_toast_buf]
    mov esi, 40
    lea rdx, [fmt_rb_removed]
    mov ecx, r12d
    xor eax, eax
    call _snprintf
    lea rax, [rb_toast_buf]
    mov [dm_toast], rax
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 8
    pop r12
    pop rbx
    ret

; menu items (DM_VALUE): RETURN places / removes, LEFT / RIGHT pick police, FBI or army
dm_rbplace_change:
    test esi, esi
    jnz .kind
    mov byte [rb_req], RB_REQ_PLACE
    ret
.kind:
    movzx eax, byte [rb_kind]
    add eax, esi
    jns .hi
    mov eax, RB_NKINDS - 1
.hi:
    cmp eax, RB_NKINDS
    jb .set
    xor eax, eax
.set:
    mov [rb_kind], al
    ret

dm_rbplace_fmt:
    movzx eax, byte [rb_kind]
    lea rcx, [rb_kind_names]
    mov rsi, [rcx + rax*8]
    jmp _strcpy

dm_rbclear_change:
    test esi, esi
    jnz .out
    mov byte [rb_req], RB_REQ_CLEAR
.out:
    ret

dm_rbclear_fmt:
    push rbx
    mov rbx, rdi
    call rb_count
    mov rdi, rbx
    mov esi, 32
    lea rdx, [fmt_dm_int]
    mov ecx, eax
    xor eax, eax
    call _snprintf
    pop rbx
    ret

section .data
align 8
rb_kind_names: dq s_rb_police, s_rb_fbi, s_rb_army
RB_NKINDS equ ($ - rb_kind_names) / 8
rb_kind_cop:   db 3, 5, 6           ; copLevel TryCreateRoadblockAt turns into that crew
align 4
i_rb_half:     dd 0x2000            ; half a block

section .rodata
s_rb_police:   db "police", 0
s_rb_fbi:      db "FBI", 0
s_rb_army:     db "army", 0
s_rb_full:     db "All roadblocks in use", 0
s_rb_noroad:   db "No room for a roadblock ahead", 0
fmt_rb_placed: db "Roadblock placed, %d up", 0
fmt_rb_removed: db "Removed %d roadblocks", 0
fmt_rb_log:    db "menu: roadblock at tile %d,%d dir %d: %d cars, %d cops; first car at %d,%d,%d", 10, 0
fmt_rb_nolog:  db "menu: no road for a roadblock near %d,%d level %d rot %d", 10, 0
fmt_rb_trace:  db "rb: frame %u player at %d,%d /16 rot %d", 10, 0
fmt_rb_removelog: db "menu: removed %d roadblocks", 10, 0

section .bss
alignb 8
rb_mem:        resq 1               ; RB_SLOTS x (header + PoliceRoadblock), low memory
rb_game:       resd 1               ; Game* the slots belong to
rb_req:        resb 1               ; RB_REQ_* for rb_frame
rb_kind:       resb 1               ; index into rb_kind_names
rb_toast_buf:  resb 48
alignb 8
rb_cur:        resq 1               ; the slot rb_place fills
rb_px:         resd 1               ; the player, SCR_f
rb_py:         resd 1
rb_z:          resd 1               ; block level under the player
rb_rot:        resd 1
rb_sdx:        resd 1               ; half a block ahead, SCR_f
rb_sdy:        resd 1
rb_tx:         resd 1               ; the last tile tried and its dir
rb_ty:         resd 1
rb_dir:        resd 1
section .text
