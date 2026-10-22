; menu/vehicle.asm — the K menu's Vehicle page: the car the player is in, else the last
; one (dm_car): colour (car remap), invincibility, repair, explode. Spawning moved to
; Spawn > Car (menu/spawn_car.asm). Repair, explode and colour follow gta2-seuko-mod
; src/modules/modmenu/utils/fix-car-utils.cpp, explode-last-car.cpp @25b1985.

section .data
    DM_PAGE  dmp_vehicle, dmp_root, 110, "Vehicle"
    DM_ITEM  dmp_vehicle, 10, DM_VALUE, "", dmv_carinfo
    DM_ITEM  dmp_vehicle, 20, DM_VALUE, "Colour: ", dmv_color
    DM_ITEM  dmp_vehicle, 30, DM_VALUE, "Invincible: ", dmv_invinc
    DM_ITEM  dmp_vehicle, 40, DM_ACTION, "Repair", dm_repair_car
    DM_ITEM  dmp_vehicle, 50, DM_ACTION, "Explode", dm_explode_car
    DMVALUE carinfo
    DMVALUE color
    DMVALUE invinc
section .text

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


; dm_repair_car: windscreen and lights back, engine damage 0, fire out (TurnOnCarLights
; @0x425590, TurnOnCarBrakeLights @0x4213D0, FixCarBrokenEngine @0x421570, ExtinguishCar
; @0x4BF070, all fastcall(Car* ecx))
; From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/game/functions.h, src/modules/modmenu/utils/fix-car-utils.cpp @25b1985 — the four calls.
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
; From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/game/functions.h, src/modules/modmenu/utils/explode-last-car.cpp @25b1985 — ExplodeCar 0x426FA0.
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

section .rodata
fmt_dm_carinfo: db "Car: %s (%s)", 0
s_dm_current:  db "in it", 0
s_dm_last:     db "last", 0
s_dm_repaired: db "Car repaired", 0
s_dm_exploded: db "Boom", 0
section .text
