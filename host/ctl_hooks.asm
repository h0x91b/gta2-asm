; ctl_hooks.asm — the game hooks gta2ctl (docs/gta2ctl.md) needs beyond on-foot steering
; (which runs from c32/player_move.c). They lived in player_move.asm until it moved to C32
; (Seq 62) and are unchanged; their CALLHOOK rows are in w32_hooks.asm.
;
; gta2ctl drive_to (host/c/ctl_game.c) lets the car AI drive the player's car. Two gates
; keep the AI off a player's car (Seq 27, 2026-10-22): Car_Update 0x429E50 runs
; CarAI_PreUpdate only when Ped_GetPedClass(driver) != 2 (PLAYER), and Player_DriveCar
; writes the keys' controls every tick. While _ctl_autopilot_ped is set:
; CALLHOOK 0x429EDC Ped_GetPedClass 0x420B70 (fastcall ecx = the car's driver) reports 3
; for that ped, and CALLHOOK 0x4A78F3 skips Player_DriveCar 0x4A4C40 (thiscall Player*,
; Car*, ret 4) in Player_HandleControls.
; gta2ctl sms (host/c/ctl_game.c): the brief's Gxt_FindTextW_thunk 0x4C23A0 (thiscall ECX =
; g_LocaleSettings, key) calls in Hud_Brief_PrepareCurrentText answer our own text for the
; key "ctlsms" (ctl_brief_text), any other key goes to the game.
hk_BriefText:
    HENTER
    mov r12d, [abs G_ECX]
    mov edi, [rbx]
    call _ctl_brief_text
    test eax, eax
    jnz .out
    mov edi, 0x4C23A0
    mov rsi, rbx
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
.out:
    HRET

hk_CarDriverClass:
    HENTER
    mov r12d, [abs G_ECX]
    mov edi, 0x420B70
    mov rsi, rbx
    xor edx, edx
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    test r12d, r12d
    jz .out
    cmp r12d, [rel _ctl_autopilot_ped]
    jne .out
    inc dword [rel _ctl_autopilot_ticks]
    mov eax, 3                      ; an ordinary driver class
.out:
    HRET

hk_DriveCar:
    HENTER
    mov r12d, [abs G_ECX]
    cmp dword [rel _ctl_autopilot_ped], 0
    jne .out
    mov edi, 0x4A4C40
    mov rsi, rbx
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
.out:
    HRET


section .text
