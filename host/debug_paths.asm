; debug_paths.asm — "Ped paths" in the debug menu (K): every gameplay frame, for each
; live ped on foot, a dotted line from the ped (green) to the next waypoint of its path
; (yellow) and on to the one after it (orange). A ped with no path left but a moveTarget
; gets a cyan line to that instead, and one with neither a grey tick one block along its
; rotation (+0x12c, the convention dm_spawn_car uses; checked against the player walking
; north). Measured in Downtown (2026-10-21): the wandering dummies have neither — no
; pathCursor, moveTarget -1.0, objective 0 — so they only get the tick; paths are planned
; for peds with an objective (go to, chase, enter a car: the 16 callers of
; Ped_MoveTowardTarget). Drawn from hk_DrawUI before the HUD, so the HUD and the menu
; stay on top; with the toggle off nothing here runs. Once every DP_STATS_FRAMES while
; on, a "paths:" line counts the peds.
;
; Test build: NASMFLAGS=-DDP_TEST=F sends every ped after the player on foot at frame F
; (PedSetObjective), so paths show up without a mission.
;
; Ped fields (re/gta2_types.h, Ghidra; relayed from the Ped naming pass): path[100] at
; +0 = S3Bytes map cells (x, y, z block coordinates), ended by a (0,0,0) triple;
; pathCursor +0x18c = the current one (Ped_MoveTowardTarget 0x4380D0 steps it by 3);
; position +0x1ac, moveTarget +0x1c4 (SCR_Vector3, -1.0 = none), nextPed +0x160,
; lifeState +0x234 (99 = alive), currentCar +0x16c. Peds: PedManager* 0x5E5BBC, the
; in-use list starts at +4 and goes through nextPed (PedManager_UpdateAll 0x445960).
;
; World -> screen is the game's own WorldPointToScreen @0x40CFC0, fastcall(Camera* ecx,
; edx; SCR_f x, y, z, SCR_f* outX, SCR_f* outY), ret 0x14, on the player's camera
; (Game 0x5EB4FC +0x38 = Player, +0x14c), the way the debug view ShowJunctionIds
; 0x40D120 labels junctions (own disassembly). It reads the camera as the frame drew it,
; so the camera.zoom factor is already in. Its result is in 640x480 units; times the
; main camera's uiScale gives back-buffer pixels, the space DrawFlatRect2D draws in.
; A cell becomes a world point as cell * 1.0 (0x40CE30 there), +0.5 for the centre.

PED_NEXT    equ 0x160
PED_PATHCUR equ 0x18c
PED_POS     equ 0x1ac
PED_MOVETGT equ 0x1c4
PED_ROT     equ 0x12c               ; short, 1440 = full turn
PED_LIFE    equ 0x234
PED_PATHEND equ 0x12c               ; path[100], 3 bytes each
PED_ALIVE   equ 99
PEDMGR      equ 0x5E5BBC
SCR_NONE    equ -0x4000             ; -1.0
WINDOW_H    equ 0x6732E8
DP_MAXPEDS  equ 400                 ; the pool has 200; a broken list cannot hang us
DP_MAXDOTS  equ 256                 ; per segment
DP_STATS_FRAMES equ 300

section .text

dm_draw_paths:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov eax, [abs 0x5EB4FC]
    test eax, eax
    jz .out
    mov eax, [rax + 0x38]           ; Player*
    test eax, eax
    jz .out
    add eax, 0x14c
    mov [dp_cam], eax
    mov eax, [abs UI_CAMERA]
    test eax, eax
    jz .out
    mov eax, [rax + 0xa8]           ; uiScale
    mov [dp_scale], eax
    cmp qword [dp_low], 0
    jne .low
    mov edi, 16
    mov esi, 16
    call low_alloc
    mov [dp_low], rax
.low:
    xor eax, eax
    mov [dp_n], eax
    mov [dp_live], eax
    mov [dp_onpath], eax
    mov [dp_target], eax
    mov eax, [abs PEDMGR]
    test eax, eax
    jz .stats
    mov ebx, [rax + 4]              ; first ped in use
    mov r15d, DP_MAXPEDS
.ped:
    test ebx, ebx
    jz .stats
    dec r15d
    js .stats
    inc dword [dp_n]
    cmp byte [rbx + PED_LIFE], PED_ALIVE
    jne .next
    cmp dword [rbx + PED_CAR], 0
    jne .next
    inc dword [dp_live]
%ifdef DP_TEST
    ; test only: at frame DP_TEST every ped is sent after the player on foot
    ; (PedSetObjective 0x43BBC0 fastcall(Ped*, edx; objective, timer), ret 8; then
    ; objectiveTargetPed +0x148, which it clears), so the game plans real paths
    cmp dword [r_frames], DP_TEST
    jne .notest
    call dm_player_ped
    cmp eax, ebx
    je .notest
    mov [rsp + 8], eax
    mov dword [rsp], 16             ; PED_OBJECTIVE_GO_TO_CHAR_ON_FOOT
    mov dword [rsp + 4], 9999
    mov edi, 0x43BBC0
    mov rsi, rsp
    mov edx, 2
    xor ecx, ecx
    mov r8d, ebx
    xor r9d, r9d
    call call32
    mov eax, [rsp + 8]
    mov [rbx + 0x148], eax
.notest:
%endif
    mov edi, [rbx + PED_POS]
    mov esi, [rbx + PED_POS + 4]
    mov edx, [rbx + PED_POS + 8]
    call dp_project
    mov r12d, eax                   ; previous point, on screen
    mov r13d, edx
    mov [dp_pedx], eax
    mov [dp_pedy], edx
    xor r14d, r14d                  ; waypoint 0, 1
.wp:
    cmp r14d, 2
    jae .wpdone
    mov eax, [rbx + PED_PATHCUR]
    lea eax, [rax + r14*2]
    add eax, r14d                   ; cursor + 3k
    mov ecx, eax
    sub ecx, ebx
    cmp ecx, PED_PATHEND - 3        ; unsigned: also catches a null / foreign cursor
    ja .wpdone
    movzx edi, byte [rax]
    movzx esi, byte [rax + 1]
    movzx edx, byte [rax + 2]
    mov ecx, edi
    or ecx, esi
    or ecx, edx
    jz .wpdone                      ; (0,0,0): end of the path
    shl edi, 14
    or edi, 0x2000
    shl esi, 14
    or esi, 0x2000
    shl edx, 14
    call dp_project
    mov [rsp], eax
    mov [rsp + 4], edx
    lea rcx, [dp_colors]
    mov r8d, [rcx + r14*4]
    mov edi, r12d
    mov esi, r13d
    mov ecx, edx
    mov edx, eax
    call dp_line
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov r12d, edi
    mov r13d, esi
    mov edx, 3
    sub edx, r14d                   ; marker half size: 3, then 2 (640x480 units)
    lea rcx, [dp_colors]
    mov ecx, [rcx + r14*4]
    call dp_mark
    inc r14d
    jmp .wp
.wpdone:
    test r14d, r14d
    jz .target
    inc dword [dp_onpath]
    jmp .self
.target:                            ; no path: the moveTarget, if any
    mov edi, [rbx + PED_MOVETGT]
    mov esi, [rbx + PED_MOVETGT + 4]
    mov edx, [rbx + PED_MOVETGT + 8]
    cmp edi, SCR_NONE
    je .heading
    cmp edi, [rbx + PED_POS]
    jne .t
    cmp esi, [rbx + PED_POS + 4]
    je .heading
.t:
    inc dword [dp_target]
    call dp_project
    mov r12d, eax
    mov r13d, edx
    mov edi, [dp_pedx]
    mov esi, [dp_pedy]
    mov edx, eax
    mov ecx, r13d
    mov r8d, DP_CYAN
    call dp_line
    mov edi, r12d
    mov esi, r13d
    mov edx, 2
    mov ecx, DP_CYAN
    call dp_mark
    jmp .self
.heading:                           ; neither (a wandering ped): where it faces
    movsx eax, word [rbx + PED_ROT]
    mov [rsp + 8], eax
    fild dword [rsp + 8]
    fmul qword [f_dm_rot2rad]
    fsincos                         ; st0 = cos, st1 = sin
    fimul dword [dp_head_len]
    fistp dword [rsp + 8]           ; cos * len
    fimul dword [dp_head_len]
    fistp dword [rsp + 12]          ; sin * len
    mov edi, [rbx + PED_POS]
    add edi, [rsp + 12]
    mov esi, [rbx + PED_POS + 4]
    add esi, [rsp + 8]
    mov edx, [rbx + PED_POS + 8]
    call dp_project
    mov r12d, eax
    mov r13d, edx
    mov edi, [dp_pedx]
    mov esi, [dp_pedy]
    mov edx, eax
    mov ecx, r13d
    mov r8d, DP_GREY
    call dp_line
    mov edi, r12d
    mov esi, r13d
    mov edx, 1
    mov ecx, DP_GREY
    call dp_mark
.self:
    mov edi, [dp_pedx]
    mov esi, [dp_pedy]
    mov edx, 2
    mov ecx, DP_GREEN
    call dp_mark
.next:
    mov ebx, [rbx + PED_NEXT]
    jmp .ped
.stats:
    mov eax, [r_frames]
    sub eax, [dp_stats_frame]
    cmp eax, DP_STATS_FRAMES
    jb .out
    mov eax, [r_frames]
    mov [dp_stats_frame], eax
    lea rdi, [fmt_dp_stats]
    mov esi, [dp_n]
    mov edx, [dp_live]
    mov ecx, [dp_onpath]
    mov r8d, [dp_target]
    mov r9d, [cam_zoom_pct]
    xor eax, eax
    call _printf
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax, edx = dp_project(edi = x, esi = y, edx = z, SCR_f world): back-buffer pixels
dp_project:
    sub rsp, 24
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov rax, [dp_low]
    mov [rsp + 12], eax             ; &outX
    add eax, 4
    mov [rsp + 16], eax             ; &outY
    mov edi, 0x40CFC0
    mov rsi, rsp
    mov edx, 5
    xor ecx, ecx
    mov r8d, [dp_cam]
    xor r9d, r9d
    call call32
    mov rcx, [dp_low]
    movsxd rdx, dword [dp_scale]
    movsxd rax, dword [rcx]
    imul rax, rdx
    sar rax, 28                     ; SCR_f * SCR_f -> int
    movsxd r8, dword [rcx + 4]
    imul r8, rdx
    sar r8, 28
    mov edx, r8d
    add rsp, 24
    ret

; dp_line(edi = x0, esi = y0, edx = x1, ecx = y1 pixels, r8d = argb): dots between the
; two points, every 4 units (640x480), endpoints excluded
dp_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 24
    mov [rsp], edi
    mov [rsp + 4], esi
    mov r12d, edx
    sub r12d, edi                   ; dx
    mov r13d, ecx
    sub r13d, esi                   ; dy
    mov [rsp + 8], r8d
    mov eax, r12d                   ; n = max(|dx|, |dy|) / spacing
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, eax
    mov eax, r13d
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, [dp_scale]
    shr ecx, 12                     ; 4 units in pixels
    jnz .sp
    mov ecx, 1
.sp:
    xor edx, edx
    div ecx
    mov r14d, eax
    cmp r14d, 2
    jb .out
    cmp r14d, DP_MAXDOTS
    jbe .n
    mov r14d, DP_MAXDOTS
.n:
    mov r15d, 1
.dot:
    cmp r15d, r14d
    jae .out
    mov eax, r12d
    imul eax, r15d
    cdq
    idiv r14d
    mov ebx, eax
    add ebx, [rsp]
    mov eax, r13d
    imul eax, r15d
    cdq
    idiv r14d
    mov ebp, eax
    add ebp, [rsp + 4]
    mov edi, ebx
    mov esi, ebp
    mov edx, [dp_scale]
    shr edx, 15                     ; half a unit: 1 px at 2x
    jnz .h
    mov edx, 1
.h:
    mov ecx, [rsp + 8]
    call dp_rect
    inc r15d
    jmp .dot
.out:
    add rsp, 24
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dp_mark(edi = x, esi = y pixels, edx = half size in 640x480 units, ecx = argb)
dp_mark:
    imul edx, [dp_scale]
    shr edx, 14
    jmp dp_rect

; dp_rect(edi = x, esi = y, edx = half size, ecx = argb; pixels): a square, skipped
; when it is off the back buffer
dp_rect:
    mov eax, edi
    add eax, edx
    js .out
    mov eax, esi
    add eax, edx
    js .out
    mov eax, edi
    sub eax, edx
    cmp eax, [abs WINDOW_W]
    jge .out
    mov eax, esi
    sub eax, edx
    cmp eax, [abs WINDOW_H]
    jge .out
    sub rsp, 40
    mov [rsp + 16], ecx
    lea eax, [rdi + rdx]
    cvtsi2ss xmm0, eax
    movss [rsp + 8], xmm0           ; x2
    lea eax, [rsi + rdx]
    cvtsi2ss xmm0, eax
    movss [rsp + 12], xmm0          ; y2
    sub edi, edx
    cvtsi2ss xmm0, edi
    movss [rsp], xmm0               ; x1
    sub esi, edx
    cvtsi2ss xmm0, esi
    movss [rsp + 4], xmm0           ; y1
    mov edi, 0x474110               ; DrawFlatRect2D
    mov rsi, rsp
    mov edx, 5
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    add rsp, 40
.out:
    ret

section .data
DP_GREEN equ 0xFF20FF20
DP_CYAN  equ 0xFF20E0FF
DP_GREY  equ 0xC0C0C0C0
dp_head_len: dd 0x4000              ; heading tick: 1 block
dp_colors: dd 0xFFFFFF00, 0xFFFF8000 ; waypoint 0 yellow, 1 orange

section .rodata
fmt_dp_stats: db "paths: %d peds listed, %d alive on foot, %d on a path, %d moveTarget only (zoom %d%%)", 10, 0

section .bss
alignb 8
dp_low:        resq 1               ; low memory: WorldPointToScreen's outX, outY
dp_cam:        resd 1
dp_scale:      resd 1
dp_pedx:       resd 1
dp_pedy:       resd 1
dp_n:          resd 1
dp_live:       resd 1
dp_onpath:     resd 1
dp_target:     resd 1
dp_stats_frame: resd 1
section .text
