; player_move.asm — two on-foot controls the original game never had: strafing (sideways
; steps, Q / E by default) and smooth mouse turning. Both go through the game's own walker,
; so walls, cars and peds stop a strafing player exactly as they stop a walking one.
; Settings: the `controls:` section of config.yaml (c/config.c, config.example.yaml).
; Analysis: docs/re/ped-movement-collision.md §6.
;
; Strafe. All on-foot collision is inline in PedGameObject_StateWalk 0x49A560 and keyed off
; the heading (PedGameObject+0x40, Ang16, 1440 per turn): the probe, the tile-edge tests, the
; wall slide and the sprite obstacles all run along it. The game walks BACKWARDS by turning
; the heading 180° for one move and restoring it at the end (0x49AA8E saves it in the local
; [esp+0x24] and clears the flag [esp+0x11]; 0x49B0A5 restores it when the flag is clear), so
; the sprite keeps facing forward. We do the same with ±90° (±45° together with forward or
; back) in a JMPHOOK at 0x49AC76, the point where the walker would otherwise save the
; unmodified heading. The walker only moves when Player.moveSpeed (+0xC) is nonzero, so a
; pure strafe reports "forward" (+1.0) from the MoveOnFoot call hook.
;   Directions: x = sin(h), y = cos(h); the left key makes the heading grow, so the ped's
;   left is heading + 360 and its right heading − 360 (checked in a run, see docs).
;
; Mouse. Player.turnRate (+8) is the per-tick heading delta the walker adds (0x49A98F) and the
; player has no other target heading, so mouse turning writes it after Player_MoveOnFoot:
; the game's own value (the arrow keys still work) plus the mouse delta of that tick. The
; game ramps turnRate from its previous value, so ours is put back before each call.
; SDL relative mode is switched on while the player walks with mouse turning enabled
; (mouse_capture_on, w32_dinput.asm); focus loss releases it, and so does switching it off.
; Both features are also toggles on the debug menu's main page (debug_menu.asm).
;
; Prior art, both only turned the ped by pressing virtual left/right keys (turn speed capped
; by turnRate) and neither strafed: gta2-seuko-mod by izawartka
; (https://github.com/izawartka/gta2-seuko-mod), src/modules/modmenu/cheats/mouse-control/
; and src/events/keyboard-state-update.cpp @25b1985; h0x91b/gta2-resurection
; (https://github.com/h0x91b/gta2-resurection), mod-mouse-rotation.lua @87e1d98;
; h0x91b/gta2-mouse (https://github.com/h0x91b/gta2-mouse), MainWindow.cpp @6c5351b wrote
; PedGameObject+0x40 directly, which the walker overwrites every tick.

ANG_TURN    equ 1440                ; Ang16 units per full turn
ANG_90      equ 360
ANG_45      equ 180
MOVE_FWD    equ 0x4000              ; Player.moveSpeed +1.0 (Q14)
PL_TURNRATE equ 0x08                ; Player fields (docs/re/ped-movement-collision.md §1)
PL_MOVESPD  equ 0x0C
PL_KEYFWD   equ 0x78
PL_KEYBACK  equ 0x79
PED_GOBJ    equ 0x168               ; Ped: PedGameObject*, current car
PED_CAR     equ 0x16C
GO_HEADING  equ 0x40                ; PedGameObject fields
GO_FLAGS    equ 0x58                ; bit 3: walking backwards
WALK_FLAG   equ 0x11                ; StateWalk locals at 0x49AC76: heading not changed yet
WALK_SAVED  equ 0x24                ;   the heading to restore at 0x49B0A5
MOUSE_MAX   equ 720                 ; at most half a turn per tick
MOUSE_GAP   equ 3                   ; frames without a call = the delta is stale, dropped
SENS_MIN    equ 10
SENS_MAX    equ 1000

section .text

; Player_MoveOnFoot(Player* this, Ped*) @0x4A5C50, thiscall, ret 4, called at 0x4A7901 by
; Player_HandleControls when the player is on foot. It turns the keys into Player.turnRate
; and Player.moveSpeed; the ped moves later in the same tick (Ped_Update → StateWalk).
hk_MoveOnFoot:
    HENTER
    mov r12d, [abs G_ECX]           ; Player*
    mov r13d, [rbx]                 ; Ped*
    cmp byte [pm_mouse_on], 0
    je .call
    mov ax, [pm_game_turn]          ; the game ramps from its own last value
    mov [r12 + PL_TURNRATE], ax
.call:
    mov edi, 0x4A5C50
    mov rsi, rbx
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    mov ax, [r12 + PL_TURNRATE]
    mov [pm_game_turn], ax
    mov word [pm_offset], 0
    mov dword [pm_gobj], 0
    mov r14d, [r13 + PED_GOBJ]
    test r14d, r14d
    jz .out
    cmp dword [r13 + PED_CAR], 0
    jne .out
    mov [pm_gobj], r14d
    cmp byte [pm_strafe_on], 0
    je .mouse
    lea rcx, [di_keys]
    xor eax, eax
    movzx edx, byte [pm_key_left]
    cmp byte [rcx + rdx], 0
    je .right
    inc eax
.right:
    movzx edx, byte [pm_key_right]
    cmp byte [rcx + rdx], 0
    je .side
    dec eax
.side:
    test eax, eax                   ; +1 left, -1 right, 0 none or both
    jz .mouse
    cmp byte [r12 + PL_KEYFWD], 0   ; forward wins over back, as in Player_MoveOnFoot
    jne .diag_fwd
    cmp byte [r12 + PL_KEYBACK], 0
    jne .diag_back
    imul eax, ANG_90
    cmp dword [r12 + PL_MOVESPD], 0
    jne .store
    mov dword [r12 + PL_MOVESPD], MOVE_FWD
    jmp .store
.diag_fwd:
    imul eax, ANG_45
    jmp .store
.diag_back:                         ; the walker already turned the heading by 180°
    imul eax, -ANG_45
.store:
    mov [pm_offset], ax
.mouse:
    cmp byte [pm_mouse_on], 0
    jne .mouse_on
    cmp byte [pm_captured], 0       ; switched off (debug menu): give the cursor back,
    je .out                         ; but only if we took it (full screen takes it too)
    mov byte [pm_captured], 0
    call mouse_capture_off
    jmp .out
.mouse_on:
    cmp byte [have_focus], 0
    je .out
    mov byte [pm_captured], 1
    call mouse_capture_on
    lea rdi, [mouse_dx]
    call take_axis                  ; whole pixels since the last tick
    mov ecx, [r_frames]
    mov edx, ecx
    xchg edx, [pm_mouse_frame]
    sub ecx, edx
    cmp ecx, MOUSE_GAP
    ja .out                         ; first tick after a menu or a car: drop the backlog
    imul eax, [pm_mouse_sens]       ; 100% = 2 units (0.5°) per pixel
    cdq
    mov ecx, 50
    idiv ecx
    neg eax                         ; mouse right = turn right = heading down
    cmp eax, MOUSE_MAX
    jle .lo
    mov eax, MOUSE_MAX
.lo:
    cmp eax, -MOUSE_MAX
    jge .add
    mov eax, -MOUSE_MAX
.add:
    movsx ecx, word [pm_game_turn]
    add eax, ecx
    call pm_wrap
    mov [r12 + PL_TURNRATE], ax
.out:
    mov edi, r12d                   ; gta2ctl goto / face steer last (host/c/ctl_game.c)
    mov esi, r13d
    call _ctl_on_foot
    HRET

; JMPHOOK 0x49AC76 in PedGameObject_StateWalk (esi = PedGameObject*), before the walker saves
; the heading it will restore: for the player's PedGameObject with a strafe offset this tick,
; save the facing ourselves, clear the "unchanged" flag and turn the heading for this move.
; If the walker has already turned it (backward walk, bit 3), the offset goes on top; any
; other turn of its own (stepping around an obstacle) wins and this tick does not strafe.
hk_WalkHeading:
    HENTER
    movsx ecx, word [pm_offset]
    test ecx, ecx
    jz .done
    mov eax, [rbx]                  ; regs*
    mov esi, [rax + R_ESI]
    cmp esi, [pm_gobj]              ; every walking ped comes through here
    jne .done
    mov word [pm_offset], 0
    mov edi, [rax + R_ESP]          ; the walker's esp
    cmp byte [rdi + WALK_FLAG], 0
    jne .fresh
    test byte [rsi + GO_FLAGS], 8
    jz .done
    jmp .turn
.fresh:
    mov ax, [rsi + GO_HEADING]
    mov [rdi + WALK_SAVED], ax
    mov byte [rdi + WALK_FLAG], 0
.turn:
    movsx eax, word [rsi + GO_HEADING]
    add eax, ecx
    call pm_wrap
    mov [rsi + GO_HEADING], ax
.done:
    xor eax, eax                    ; run the displaced bytes, continue
    HRET

; eax = pm_wrap(eax): to 0..ANG_TURN-1, for any |eax| < 4 turns
pm_wrap:
    add eax, 4 * ANG_TURN
    xor edx, edx
    mov ecx, ANG_TURN
    div ecx
    mov eax, edx
    ret

; pm_report: one line after the config, so a run log says what is active
pm_report:
    sub rsp, 8
    movzx edi, byte [pm_key_left]
    call dik_str
    mov rdx, rax
    push rdx
    movzx edi, byte [pm_key_right]
    call dik_str
    pop rdx
    mov rcx, rax
    lea rdi, [fmt_pm]
    lea rsi, [s_pm_off]
    lea rax, [s_pm_on]
    cmp byte [pm_strafe_on], 0
    cmovne rsi, rax
    lea r8, [s_pm_off]
    cmp byte [pm_mouse_on], 0
    cmovne r8, rax
    mov r9d, [pm_mouse_sens]
    xor eax, eax
    call _printf
    add rsp, 8
    ret

section .data
    DM_ITEM  dmp_root, 60, DM_FLAG, "Mouse turning: ", pm_mouse_on
    DM_ITEM  dmp_root, 70, DM_FLAG, "Strafe (Q/E): ", pm_strafe_on

section .rodata
s_pm_on:      db "on", 0
s_pm_off:     db "off", 0
fmt_pm:       db "controls: strafe %s (%s / %s), mouse turning %s (%d%%)", 10, 0

section .bss
; the controls: section of config.yaml, parsed by host/c/config.c, which also sets the
; defaults (strafe on, Q / E, mouse turning off, 100%) before main
pm_strafe_on:   resb 1              ; controls.strafe
pm_mouse_on:    resb 1              ; controls.mouse_turn
pm_key_left:    resb 1              ; DIK, controls.strafe_left
pm_key_right:   resb 1              ; DIK, controls.strafe_right
pm_mouse_sens:  resd 1              ; controls.mouse_sensitivity, percent
alignb 4
pm_gobj:        resd 1              ; the player's PedGameObject this tick, 0 = not on foot
pm_mouse_frame: resd 1              ; r_frames at the last MoveOnFoot call
pm_offset:      resw 1              ; heading offset for this tick's move, 0 = none
pm_game_turn:   resw 1              ; turnRate as the game computed it
pm_captured:    resb 1              ; relative mouse mode switched on by us
section .text
