; debug_roads.asm — "Road network" on the debug menu's Debug flags page (K): the
; navigation data the game drives and walks by, over the world, every gameplay frame.
; LEFT / RIGHT / RETURN cycle off -> cars -> peds -> all.
;
; cars:
; - every road tile's green arrows (block +0xa, low nibble: 1 left, 2 right, 4 up, 8 down;
;   TrafficSpawner_TrySpawnSide 0x4B34E0 and CarPhysics_ApplySteeringAssist 0x4A17C0 read
;   them, re/comments.csv) as white ticks: what ambient traffic actually follows, since it
;   never routes (RoadNetwork_FindRoute 0x40E030 serves drive orders only);
; - the RGEN graph, RoadNetwork* 0x5D351C (0xCC68): segments hSegments +0xa830 / vSegments
;   +0xb938 (count +0xcc62 / +0xcc64, RoadSegment 8 B: junction1, junction2, minX, minY,
;   maxX, maxY) outlined grey; junctions +8 (RoadJunction 16 B: 4 links, arrowKind +8,
;   minX..maxY +0xc, ids 1.. until minX == 0, as RoadNetwork_ShowJunctionIds 0x40D120 walks
;   them) outlined yellow, their id on top once a tile is DR_LABEL_TILE units or more;
;   each link (u16: junction id bits 0-8, RoadLink_GetJunctionId 0x40CE90; length 9-14,
;   0x40CEA0; open bit 15, RoadLink_IsOpen 0x40CED0, SWITCH_ROAD clears it) a line from its
;   junction to the target, shifted a quarter tile to the right of travel, so the two ways
;   of a road do not overlap, with a bigger dot near the target end: blue open, red closed;
; - traffic lights: TrafficLights* 0x6721CC (junctions[100], count u16 +0x190, phase
;   +0x192). A TrafficJunction (32 B) holds 4 lamp objects and 4 glow Lights at +0x10..
;   +0x1c (Light: position +4/+8/+0xc, rgb +0x10; Light_Init 0x469010, Light_SetColor
;   0x476B00). TrafficJunction_ApplyPhase 0x4C3A10 sets the lamp frame and the glow colour
;   together (0xff00 green, 0xff8000 amber, 0xff0000 red), so each glow is drawn in its
;   own live rgb (own decompilation, 2026-10-21);
; - routes: a car with a drive order route (CarAI +0x28 routeSlot >= 1, routes at
;   RoadNetwork +0x2218, 256 u16 junction ids per slot, 0-terminated; routeStep +0x56 is
;   the current entry, CarAI_FollowRoute 0x430320 / RoadNetwork_StoreRoute 0x40CC10) gets a
;   line from the car through the junctions still ahead, in a hue from its id.
; Cars: CarPool* 0x5E4CA0, in-use list at +4 through Car +0x4c (CarPool_UpdateAll
; 0x42A2D0), ai +0x5c, sprite +0x50 (position +0x14, debug_menu.asm), id +0x6c.
;
; peds: there is no ped graph. Dummies wander by heading, keep to the top block of a
; column whose ground type is pavement (block +0xb & 3 == 2; MapBlocks_FindPavementTopBlock
; 0x466910, the ambient spawner's test) and cross only from a curb next to road
; (Ped_StartCrossingRoadIfAtCurb 0x43B7C0); peds with an objective get on-demand tile
; paths from PedPathfinder 0x66A7E4 (those are "Ped paths"). So this draws the walkable
; pavement tiles, filled green, with their border to non-pavement outlined.
;
; Map access is the game's own layout (MapBlocks_GetBlock 0x42A850): map = *g_MapBlocks
; 0x662C08; column index = u32 map[y*256 + x]; column = colWords +0x40008 + index*4 (byte
; height, byte offset, then u32 block ids for z = offset..height-1); block = blocks
; +0x4000c + id*12. Only tiles inside the player camera's world rect (Camera +0x20 left,
; right, top, bottom, SCR_f) plus one around are scanned, and only junctions, segments,
; links and lights overlapping it are projected; a junction's screen point is computed
; once per frame (dr_jstamp). Map and graph are read live rather than cached: a column
; walk is a few loads, and live reads stay right after SWITCH_ROAD or CHANGE_BLOCK.
; Drawing reuses debug_paths.asm (dp_project, dp_line, dp_mark, dp_box, dp_label, dp_hue).

G_MAPBLOCKS   equ 0x662C08
G_ROADNET     equ 0x5D351C
G_TLIGHTS     equ 0x6721CC
G_CARPOOL     equ 0x5E4CA0
RN_JUNCS      equ 8
RN_ROUTES     equ 0x2218
RN_HSEG       equ 0xa830
RN_VSEG       equ 0xb938
RN_HCOUNT     equ 0xcc62
RN_VCOUNT     equ 0xcc64
RN_MAXJ       equ 545
TL_COUNT      equ 0x190
TL_PHASE      equ 0x192
CAR_NEXT      equ 0x4c
CAR_AI        equ 0x5c
AI_ROUTESLOT  equ 0x28
AI_ROUTESTEP  equ 0x56
DR_MAXCARS    equ 400
DR_STATS_FRAMES equ 300
DR_LABEL_TILE equ 24                ; label junctions once a tile is this many 640x480 units

DR_ROADS equ 1                      ; dr_mode bits
DR_PEDS  equ 2

section .text

; ---- menu item: DM_VALUE "Road network: off / cars / peds / all"
dm_roads_change:
    mov eax, esi
    test eax, eax
    jnz .d
    mov eax, 1                      ; RETURN: next
.d:
    add al, [dr_mode]
    and al, 3
    mov [dr_mode], al
    ret

dm_roads_fmt:
    movzx eax, byte [dr_mode]
    lea rcx, [dr_mode_names]
    mov rsi, [rcx + rax*8]
    jmp _strcpy

; ---- per frame (DM_FRAME), on the game's side before the HUD, while the overlay is on
dr_frame:
    cmp byte [dr_mode], 0
    jne dr_draw
    ret

dr_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 40
    call dp_setup
    test eax, eax
    jz .out
%ifdef DR_TEST
    ; test only: at frame DR_TEST the player is moved to tile (DR_TX, DR_TY) by
    ; Ped_Teleport 0x435C80, fastcall(Ped*, edx; SCR_f x, y), ret 8 (Ghidra; seuko-mod
    ; TeleportPed), so a junction with lights can be shot without walking there
    cmp dword [r_frames], DR_TEST
    jne .notest
    call dm_player_ped
    test eax, eax
    jz .notest
    mov dword [rsp], (DR_TX << 14) | 0x2000
    mov dword [rsp + 4], (DR_TY << 14) | 0x2000
    mov r8d, eax
    mov edi, 0x435C80
    mov rsi, rsp
    mov edx, 2
    xor ecx, ecx
    xor r9d, r9d
    call call32
.notest:
%endif
    inc dword [dr_stamp]
    xor eax, eax
    mov [dr_npave], eax
    mov [dr_narrow], eax
    mov [dr_nj], eax
    mov [dr_nlink], eax
    mov [dr_nlight], eax
    mov [dr_nroute], eax
    mov eax, [dp_cam]               ; the view in tiles, one around
    mov ecx, [rax + 0x20]
    sar ecx, 14
    dec ecx
    mov [dr_x0], ecx
    mov ecx, [rax + 0x24]
    sar ecx, 14
    inc ecx
    mov [dr_x1], ecx
    mov ecx, [rax + 0x28]
    sar ecx, 14
    dec ecx
    mov [dr_y0], ecx
    mov ecx, [rax + 0x2c]
    sar ecx, 14
    inc ecx
    mov [dr_y1], ecx
    lea rdi, [dr_x0]
    call dr_clamp
    lea rdi, [dr_x1]
    call dr_clamp
    lea rdi, [dr_y0]
    call dr_clamp
    lea rdi, [dr_y1]
    call dr_clamp
    mov edi, [dr_x0]                ; a tile's width on screen, at the view centre, z 2
    add edi, [dr_x1]
    shl edi, 13
    mov esi, [dr_y0]
    add esi, [dr_y1]
    shl esi, 13
    mov edx, 0x8000
    mov [rsp], edi
    mov [rsp + 4], esi
    call dp_project
    mov ebx, eax
    mov edi, [rsp]
    add edi, 0x4000
    mov esi, [rsp + 4]
    mov edx, 0x8000
    call dp_project
    sub eax, ebx
    jg .tw
    mov eax, 1
.tw:
    mov [dr_tilepx], eax
    shl eax, 14
    xor edx, edx
    mov ecx, [dp_scale]
    test ecx, ecx
    jz .out
    div ecx
    mov [dr_tileu], eax             ; a tile in 640x480 units
    mov eax, [dp_scale]
    shr eax, 15                     ; line width: half a unit, at least 1 px
    jnz .lw
    mov eax, 1
.lw:
    mov [dr_lw], eax
    test byte [dr_mode], DR_PEDS
    jz .cars
    call dr_pavement
.cars:
    test byte [dr_mode], DR_ROADS
    jz .stats
    call dr_arrows
    call dr_segments
    call dr_junctions
    call dr_lights
    call dr_routes
.stats:
    mov eax, [r_frames]
    sub eax, [dr_stats_frame]
    cmp eax, DR_STATS_FRAMES
    jb .out
    mov eax, [r_frames]
    mov [dr_stats_frame], eax
    xor eax, eax
    mov ecx, [abs G_TLIGHTS]
    test ecx, ecx
    jz .ph
    movzx eax, byte [rcx + TL_PHASE]
.ph:
    push rax                        ; (alignment)
    push rax                        ; light phase
    mov eax, [dr_nroute]
    push rax
    mov eax, [dr_nlight]
    push rax
    mov eax, [dr_nlink]
    push rax
    mov eax, [dr_nj]
    push rax
    mov eax, [dr_narrow]
    push rax
    mov eax, [dr_npave]
    push rax
    lea rdi, [fmt_dr_stats]
    mov esi, [dr_x0]
    mov edx, [dr_x1]
    mov ecx, [dr_y0]
    mov r8d, [dr_y1]
    mov r9d, [dr_tileu]
    xor eax, eax
    call _printf
    add rsp, 64
.out:
    add rsp, 40
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dr_clamp(rdi = int*): into 0..255
dr_clamp:
    mov eax, [rdi]
    test eax, eax
    jns .lo
    xor eax, eax
.lo:
    cmp eax, 255
    jle .hi
    mov eax, 255
.hi:
    mov [rdi], eax
    ret

; rax = dr_top(edi = x, esi = y tile, 0..255): the topmost block of the column that is not
; air (ground type != 0), edx = the z its top surface is at; rax = 0 if none
dr_top:
    mov eax, [abs G_MAPBLOCKS]
    test eax, eax
    jz .none
    mov eax, [rax]
    test eax, eax
    jz .none
    mov ecx, esi
    shl ecx, 8
    add ecx, edi
    mov ecx, [rax + rcx*4]          ; column index
    mov edx, [rax + 0x40008]
    lea rdx, [rdx + rcx*4]          ; column
    mov r8d, [rax + 0x4000c]        ; blocks
    movzx ecx, byte [rdx]           ; height
    movzx r9d, byte [rdx + 1]       ; offset
.z:
    dec ecx
    cmp ecx, r9d
    jl .none
    mov eax, ecx
    sub eax, r9d
    mov eax, [rdx + rax*4 + 4]
    lea eax, [rax + rax*2]
    lea rax, [r8 + rax*4]
    test byte [rax + 0xb], 3
    jz .z
    lea edx, [rcx + 1]
    ret
.none:
    xor eax, eax
    ret

; eax = dr_ground(edi = x, esi = y): ground type of the column's top block, 0 if none or
; off the map
dr_ground:
    cmp edi, 255
    ja .no
    cmp esi, 255
    ja .no
    call dr_top
    test rax, rax
    jz .no
    movzx eax, byte [rax + 0xb]
    and eax, 3
    ret
.no:
    xor eax, eax
    ret

; eax = dr_rect_visible(edi = minX, esi = minY, edx = maxX, ecx = maxY tiles, inclusive)
dr_rect_visible:
    xor eax, eax
    cmp edx, [dr_x0]
    jl .out
    cmp edi, [dr_x1]
    jg .out
    cmp ecx, [dr_y0]
    jl .out
    cmp esi, [dr_y1]
    jg .out
    inc eax
.out:
    ret

; ---- peds: pavement tiles, filled, with their border to anything else
dr_pavement:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 8
    mov r13d, [dr_y0]
.y:
    cmp r13d, [dr_y1]
    jg .out
    mov r12d, [dr_x0]
.x:
    cmp r12d, [dr_x1]
    jg .ny
    mov edi, r12d
    mov esi, r13d
    call dr_top
    test rax, rax
    jz .nx
    movzx ecx, byte [rax + 0xb]
    and ecx, 3
    cmp ecx, 2
    jne .nx
    inc dword [dr_npave]
    shl edx, 14
    mov ebp, edx                    ; z
    mov edi, r12d
    shl edi, 14
    mov esi, r13d
    shl esi, 14
    call dp_project
    mov ebx, eax                    ; x1, y1
    mov r14d, edx
    lea edi, [r12 + 1]
    shl edi, 14
    lea esi, [r13 + 1]
    shl esi, 14
    mov edx, ebp
    call dp_project
    mov r15d, eax                   ; x2, y2
    mov ebp, edx
    mov edi, ebx
    mov esi, r14d
    mov edx, r15d
    mov ecx, ebp
    mov r8d, DR_PAVE
    call dp_box
    lea edi, [r12 - 1]
    mov esi, r13d
    call dr_ground
    cmp eax, 2
    je .e1
    mov edi, ebx
    mov esi, r14d
    mov edx, ebx
    add edx, [dr_lw]
    mov ecx, ebp
    mov r8d, DR_PAVE_EDGE
    call dp_box
.e1:
    lea edi, [r12 + 1]
    mov esi, r13d
    call dr_ground
    cmp eax, 2
    je .e2
    mov edi, r15d
    sub edi, [dr_lw]
    mov esi, r14d
    mov edx, r15d
    mov ecx, ebp
    mov r8d, DR_PAVE_EDGE
    call dp_box
.e2:
    mov edi, r12d
    lea esi, [r13 - 1]
    call dr_ground
    cmp eax, 2
    je .e3
    mov edi, ebx
    mov esi, r14d
    mov edx, r15d
    mov ecx, r14d
    add ecx, [dr_lw]
    mov r8d, DR_PAVE_EDGE
    call dp_box
.e3:
    mov edi, r12d
    lea esi, [r13 + 1]
    call dr_ground
    cmp eax, 2
    je .nx
    mov edi, ebx
    mov esi, ebp
    sub esi, [dr_lw]
    mov edx, r15d
    mov ecx, ebp
    mov r8d, DR_PAVE_EDGE
    call dp_box
.nx:
    inc r12d
    jmp .x
.ny:
    inc r13d
    jmp .y
.out:
    add rsp, 8
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- cars: the green arrows of every road tile on screen
dr_arrows:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 24
    mov r13d, [dr_y0]
.y:
    cmp r13d, [dr_y1]
    jg .out
    mov r12d, [dr_x0]
.x:
    cmp r12d, [dr_x1]
    jg .ny
    mov edi, r12d
    mov esi, r13d
    call dr_top
    test rax, rax
    jz .nx
    movzx ecx, byte [rax + 0xb]
    and ecx, 3
    cmp ecx, 1                      ; road
    jne .nx
    movzx r14d, byte [rax + 0xa]
    and r14d, 0x0F
    jz .nx
    inc dword [dr_narrow]
    shl edx, 14
    mov ebp, edx                    ; z
    mov edi, r12d
    shl edi, 14
    or edi, 0x2000
    mov esi, r13d
    shl esi, 14
    or esi, 0x2000
    mov [rsp], edi
    mov [rsp + 4], esi
    call dp_project
    mov [rsp + 8], eax              ; the centre on screen
    mov [rsp + 12], edx
    xor r15d, r15d                  ; bit 0..3
.bit:
    cmp r15d, 4
    jae .nx
    bt r14d, r15d
    jnc .nbit
    lea rcx, [dr_dirs]
    movsx edi, byte [rcx + r15*2]
    movsx esi, byte [rcx + r15*2 + 1]
    imul edi, edi, 0x1400           ; head 0.3125 tile on, tail half that back
    imul esi, esi, 0x1400
    add edi, [rsp]
    add esi, [rsp + 4]
    mov edx, ebp
    call dp_project
    mov ebx, eax                    ; head
    mov [rsp + 16], edx
    mov edi, [rsp + 8]              ; tail = centre - (head - centre) / 2
    sub edi, eax
    sar edi, 1
    add edi, [rsp + 8]
    mov esi, [rsp + 12]
    sub esi, edx
    sar esi, 1
    add esi, [rsp + 12]
    mov edx, ebx                    ; axis-aligned: one solid box from tail to head
    mov ecx, [rsp + 16]
    cmp edi, edx
    jle .sx
    xchg edi, edx
.sx:
    cmp esi, ecx
    jle .sy
    xchg esi, ecx
.sy:
    mov eax, [dr_lw]
    add edx, eax
    add ecx, eax
    sub edi, eax
    sub esi, eax
    mov r8d, DR_ARROW
    call dp_box
    mov edi, ebx
    mov esi, [rsp + 16]
    mov edx, 2
    mov ecx, DR_ARROW
    call dp_mark
.nbit:
    inc r15d
    jmp .bit
.nx:
    inc r12d
    jmp .x
.ny:
    inc r13d
    jmp .y
.out:
    add rsp, 24
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dr_outline(rdi = &{minX, minY, maxX, maxY} bytes, esi = argb): the tiles' rectangle
; outlined at the height of the road under its centre
dr_outline:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 8
    mov rbx, rdi
    mov r15d, esi
    movzx edi, byte [rbx]
    movzx eax, byte [rbx + 2]
    add edi, eax
    shr edi, 1
    movzx esi, byte [rbx + 1]
    movzx eax, byte [rbx + 3]
    add esi, eax
    shr esi, 1
    call dr_top
    test rax, rax
    jnz .z
    mov edx, 2
.z:
    shl edx, 14
    mov ebp, edx
    movzx edi, byte [rbx]
    shl edi, 14
    movzx esi, byte [rbx + 1]
    shl esi, 14
    call dp_project
    mov r12d, eax
    mov r13d, edx
    movzx edi, byte [rbx + 2]
    inc edi
    shl edi, 14
    movzx esi, byte [rbx + 3]
    inc esi
    shl esi, 14
    mov edx, ebp
    call dp_project
    mov r14d, eax
    mov ebp, edx
    mov edi, r12d                   ; left
    mov esi, r13d
    lea edx, [r12 + 0]
    add edx, [dr_lw]
    mov ecx, ebp
    mov r8d, r15d
    call dp_box
    mov edi, r14d                   ; right
    sub edi, [dr_lw]
    mov esi, r13d
    mov edx, r14d
    mov ecx, ebp
    mov r8d, r15d
    call dp_box
    mov edi, r12d                   ; top
    mov esi, r13d
    mov edx, r14d
    mov ecx, r13d
    add ecx, [dr_lw]
    mov r8d, r15d
    call dp_box
    mov edi, r12d                   ; bottom
    mov esi, ebp
    sub esi, [dr_lw]
    mov edx, r14d
    mov ecx, ebp
    mov r8d, r15d
    call dp_box
    add rsp, 8
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- cars: h and v segments
dr_segments:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov eax, [abs G_ROADNET]
    test eax, eax
    jz .out
    mov r14d, eax
    xor r13d, r13d                  ; 0 = h, 1 = v
.list:
    cmp r13d, 2
    jae .out
    lea ebx, [r14 + RN_HSEG + 4]    ; the rect of segment 0
    movzx r12d, word [r14 + RN_HCOUNT]
    test r13d, r13d
    jz .n
    lea ebx, [r14 + RN_VSEG + 4]
    movzx r12d, word [r14 + RN_VCOUNT]
.n:
    cmp r12d, RN_MAXJ
    jbe .seg
    mov r12d, RN_MAXJ
.seg:
    test r12d, r12d
    jz .nlist
    movzx edi, byte [rbx]
    movzx esi, byte [rbx + 1]
    movzx edx, byte [rbx + 2]
    movzx ecx, byte [rbx + 3]
    call dr_rect_visible
    test eax, eax
    jz .nseg
    mov edi, ebx
    mov esi, DR_SEG
    call dr_outline
.nseg:
    add ebx, 8
    dec r12d
    jmp .seg
.nlist:
    inc r13d
    jmp .list
.out:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax = dr_junc(edi = id): RoadJunction*, 0 if out of range / unused
dr_junc:
    xor eax, eax
    test edi, edi
    jz .out
    cmp edi, RN_MAXJ
    jae .out
    mov eax, [abs G_ROADNET]
    test eax, eax
    jz .out
    shl edi, 4
    lea eax, [rax + rdi + RN_JUNCS]
    cmp byte [rax + 0xc], 0
    jne .out
    xor eax, eax
.out:
    ret

; eax, edx = dr_jproj(edi = junction id): its centre on screen (memo per frame); ecx = 0
; when the id is no junction
dr_jproj:
    push rbx
    mov ebx, edi
    call dr_junc
    test eax, eax
    jz .no
    lea rcx, [dr_jstamp]
    mov edx, [dr_stamp]
    cmp [rcx + rbx*4], edx
    je .memo
    mov [rcx + rbx*4], edx
    push r12
    push r13
    mov r12d, eax
    movzx edi, byte [r12 + 0xc]
    movzx eax, byte [r12 + 0xe]
    add edi, eax
    shr edi, 1
    movzx esi, byte [r12 + 0xd]
    movzx eax, byte [r12 + 0xf]
    add esi, eax
    shr esi, 1
    call dr_top
    test rax, rax
    jnz .z
    mov edx, 2
.z:
    shl edx, 14
    movzx edi, byte [r12 + 0xc]     ; (min + max + 1) / 2 tiles
    movzx eax, byte [r12 + 0xe]
    lea edi, [rdi + rax + 1]
    shl edi, 13
    movzx esi, byte [r12 + 0xd]
    movzx eax, byte [r12 + 0xf]
    lea esi, [rsi + rax + 1]
    shl esi, 13
    call dp_project
    lea rcx, [dr_jx]
    mov [rcx + rbx*4], eax
    lea rcx, [dr_jy]
    mov [rcx + rbx*4], edx
    pop r13
    pop r12
.memo:
    lea rcx, [dr_jx]
    mov eax, [rcx + rbx*4]
    lea rcx, [dr_jy]
    mov edx, [rcx + rbx*4]
    mov ecx, 1
    pop rbx
    ret
.no:
    xor ecx, ecx
    pop rbx
    ret

; ---- cars: junctions, their links, their ids
dr_junctions:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 40
    mov r12d, 1                     ; id
.j:
    cmp r12d, RN_MAXJ
    jae .out
    mov edi, r12d
    call dr_junc
    test eax, eax
    jz .out                         ; minX == 0: past the last one
    mov ebx, eax
    xor r13d, r13d                  ; link 0..3
.link:
    cmp r13d, 4
    jae .rect
    movzx r14d, word [rbx + r13*2]
    mov edi, r14d
    and edi, 0x1ff
    jz .nlink
    call dr_junc
    test eax, eax
    jz .nlink
    movzx edi, byte [rbx + 0xc]     ; the box over both junctions must meet the view
    movzx ecx, byte [rax + 0xc]
    cmp edi, ecx
    cmova edi, ecx
    movzx esi, byte [rbx + 0xd]
    movzx ecx, byte [rax + 0xd]
    cmp esi, ecx
    cmova esi, ecx
    movzx edx, byte [rbx + 0xe]
    movzx ecx, byte [rax + 0xe]
    cmp edx, ecx
    cmovb edx, ecx
    movzx r8d, byte [rbx + 0xf]
    movzx ecx, byte [rax + 0xf]
    cmp r8d, ecx
    cmovb r8d, ecx
    mov ecx, r8d
    call dr_rect_visible
    test eax, eax
    jz .nlink
    inc dword [dr_nlink]
    mov edi, r12d
    call dr_jproj
    mov [rsp], eax                  ; from
    mov [rsp + 4], edx
    mov edi, r14d
    and edi, 0x1ff
    call dr_jproj
    mov [rsp + 8], eax              ; to
    mov [rsp + 12], edx
    mov ecx, [dr_tilepx]            ; a quarter tile to the right of travel:
    sar ecx, 2                      ; screen (dx, dy) -> (-sgn dy, sgn dx)
    sub eax, [rsp]
    sub edx, [rsp + 4]
    xor edi, edi
    xor esi, esi
    test edx, edx
    jz .ox
    mov edi, ecx
    jns .oxn
    jmp .ox
.oxn:
    neg edi
.ox:
    test eax, eax
    jz .oy
    mov esi, ecx
    jns .oy
    neg esi
.oy:
    add [rsp], edi
    add [rsp + 8], edi
    add [rsp + 4], esi
    add [rsp + 12], esi
    mov r8d, DR_LINK_OPEN
    test r14d, 0x8000
    jnz .col
    mov r8d, DR_LINK_SHUT
.col:
    mov [rsp + 16], r8d
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call dp_line
    mov eax, [rsp + 8]              ; the head: 1.5 tiles before the target, or
    sub eax, [rsp]                  ; 80% along a short link
    mov ecx, [rsp + 12]
    sub ecx, [rsp + 4]
    mov [rsp + 20], eax             ; dx
    mov [rsp + 24], ecx             ; dy
    cdq
    xor eax, edx
    sub eax, edx
    mov r8d, eax
    mov eax, ecx
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, r8d
    cmovl eax, r8d                  ; len = max(|dx|, |dy|)
    mov r8d, [dr_tilepx]
    lea r9d, [r8 + r8]
    cmp eax, r9d
    jle .short
    mov r9d, eax                    ; head = to - d * 1.5 tile / len
    lea r8d, [r8 + r8*2]
    sar r8d, 1
    mov eax, [rsp + 20]
    imul eax, r8d
    cdq
    idiv r9d
    mov edi, [rsp + 8]
    sub edi, eax
    mov eax, [rsp + 24]
    imul eax, r8d
    cdq
    idiv r9d
    mov esi, [rsp + 12]
    sub esi, eax
    jmp .head
.short:
    mov eax, [rsp + 20]
    imul eax, eax, 4
    cdq
    mov ecx, 5
    idiv ecx
    add eax, [rsp]
    mov edi, eax
    mov eax, [rsp + 24]
    imul eax, eax, 4
    cdq
    mov ecx, 5
    idiv ecx
    add eax, [rsp + 4]
    mov esi, eax
.head:
    mov edx, 2
    mov ecx, [rsp + 16]
    call dp_mark
.nlink:
    inc r13d
    jmp .link
.rect:
    movzx edi, byte [rbx + 0xc]
    movzx esi, byte [rbx + 0xd]
    movzx edx, byte [rbx + 0xe]
    movzx ecx, byte [rbx + 0xf]
    call dr_rect_visible
    test eax, eax
    jz .nj
    inc dword [dr_nj]
    lea edi, [rbx + 0xc]
    mov esi, DR_JUNC
    call dr_outline
    cmp dword [dr_tileu], DR_LABEL_TILE ; ids only when zoomed in enough to read them
    jb .nj
    mov edi, r12d
    call dr_jproj
    mov edi, eax
    mov esi, edx
    mov edx, r12d
    mov ecx, DR_JUNC
    call dp_label
.nj:
    inc r12d
    jmp .j
.out:
    add rsp, 40
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- cars: every traffic light glow, in its own colour
dr_lights:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 8
    mov eax, [abs G_TLIGHTS]
    test eax, eax
    jz .out
    mov r14d, eax
    movzx r12d, word [r14 + TL_COUNT]
    cmp r12d, 100
    jbe .j
    mov r12d, 100
.j:
    dec r12d
    js .out
    mov eax, [r14 + r12*4]
    test eax, eax
    jz .j
    mov r13d, eax
    xor ebx, ebx
.l:
    cmp ebx, 4
    jae .j
    mov eax, [r13 + 0x10 + rbx*4]   ; glow Light*
    test eax, eax
    jz .nl
    mov edi, [rax + 4]
    mov esi, [rax + 8]
    mov ecx, edi
    sar ecx, 14
    cmp ecx, [dr_x0]
    jl .nl
    cmp ecx, [dr_x1]
    jg .nl
    mov ecx, esi
    sar ecx, 14
    cmp ecx, [dr_y0]
    jl .nl
    cmp ecx, [dr_y1]
    jg .nl
    inc dword [dr_nlight]
    mov ecx, [rax + 0x10]
    and ecx, 0xFFFFFF
    or ecx, 0xFF000000
    mov [rsp], ecx
    mov edx, [rax + 0xc]
    call dp_project
    mov r15d, eax
    mov ebp, edx
    mov edi, eax
    mov esi, edx
    mov edx, 6
    mov ecx, DR_LAMP_RIM
    call dp_mark
    mov edi, r15d
    mov esi, ebp
    mov edx, 5
    mov ecx, [rsp]
    call dp_mark
.nl:
    inc ebx
    jmp .l
.out:
    add rsp, 8
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- cars: drive-order routes
dr_routes:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 24
    mov eax, [abs G_ROADNET]
    test eax, eax
    jz .out
    mov eax, [abs G_CARPOOL]
    test eax, eax
    jz .out
    mov ebx, [rax + 4]
    mov r15d, DR_MAXCARS
.car:
    test ebx, ebx
    jz .out
    dec r15d
    js .out
    mov eax, [rbx + CAR_AI]
    test eax, eax
    jz .next
    movsx r12d, byte [rax + AI_ROUTESLOT]
    cmp r12d, 1
    jl .next
    cmp r12d, 50
    jge .next
    movzx r13d, word [rax + AI_ROUTESTEP]
    mov eax, [rbx + CAR_SPRITE]
    test eax, eax
    jz .next
    inc dword [dr_nroute]
    mov edi, [rax + 0x14]
    mov esi, [rax + 0x18]
    mov edx, [rax + 0x1c]
    call dp_project
    mov [rsp], eax                  ; previous point
    mov [rsp + 4], edx
    mov [rsp + 12], eax
    mov [rsp + 16], edx
    mov eax, [rbx + CAR_ID]
    call dp_hue
    mov [rsp + 8], eax
    mov r14d, 1                     ; label: 1 = the next junction
.wp:
    cmp r13d, 256
    jae .self
    mov eax, [abs G_ROADNET]
    mov ecx, r12d
    shl ecx, 8
    add ecx, r13d
    movzx edi, word [rax + RN_ROUTES + rcx*2]
    test edi, edi
    jz .self
    mov ebp, edi
    call dr_jproj
    test ecx, ecx
    jz .self
    push rax
    push rdx
    mov ecx, edx
    mov edx, eax
    mov edi, [rsp + 16]
    mov esi, [rsp + 20]
    mov r8d, [rsp + 24]
    call dp_line
    pop rdx
    pop rax
    mov [rsp], eax
    mov [rsp + 4], edx
    mov edi, eax
    mov esi, edx
    mov edx, 2
    mov ecx, [rsp + 8]
    call dp_mark
    cmp r14d, 9                     ; the first few steps numbered
    ja .nolab
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, r14d
    mov ecx, [rsp + 8]
    call dp_label
.nolab:
    inc r14d
    inc r13d
    jmp .wp
.self:
    mov edi, [rsp + 12]
    mov esi, [rsp + 16]
    mov edx, 3
    mov ecx, [rsp + 8]
    call dp_mark
.next:
    mov ebx, [rbx + CAR_NEXT]
    jmp .car
.out:
    add rsp, 24
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .data
    DM_ITEM  dmp_flags, 100, DM_VALUE, "Road network: ", dmv_roads
    DMVALUE roads
    DM_FRAME 50, dr_frame
DR_PAVE      equ 0x4020C040         ; pavement fill
DR_PAVE_EDGE equ 0xFF40FF60
DR_ARROW     equ 0xD0FFFFFF
DR_SEG       equ 0xA0909090
DR_JUNC      equ 0xFFFFD020
DR_LINK_OPEN equ 0xFF40A0FF
DR_LINK_SHUT equ 0xFFFF3030
DR_LAMP_RIM  equ 0xFF000000
; arrow bits 1 left, 2 right, 4 up, 8 down as (dx, dy) tiles
dr_dirs: db -1,0, 1,0, 0,-1, 0,1
align 8
dr_mode_names: dq s_dr_off, s_dr_cars, s_dr_peds, s_dr_all

section .rodata
s_dr_off:  db "off", 0
s_dr_cars: db "cars", 0
s_dr_peds: db "peds", 0
s_dr_all:  db "cars + peds", 0
fmt_dr_stats: db "roads: view x %d..%d y %d..%d, tile %d units; %d pavement, %d arrow tiles, %d junctions, %d links, %d lights, %d routes, light phase %d", 10, 0

section .bss
alignb 8
dr_mode:       resb 1               ; 0 off, DR_ROADS | DR_PEDS
alignb 4
dr_stamp:      resd 1
dr_x0:         resd 1               ; the view, tiles, inclusive
dr_x1:         resd 1
dr_y0:         resd 1
dr_y1:         resd 1
dr_tilepx:     resd 1
dr_tileu:      resd 1
dr_lw:         resd 1
dr_npave:      resd 1
dr_narrow:     resd 1
dr_nj:         resd 1
dr_nlink:      resd 1
dr_nlight:     resd 1
dr_nroute:     resd 1
dr_stats_frame: resd 1
dr_jstamp:     resd RN_MAXJ
dr_jx:         resd RN_MAXJ
dr_jy:         resd RN_MAXJ
section .text
