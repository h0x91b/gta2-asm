; mods.asm — call hooks whose logic lives in host C modules (host/c/, docs/host-c.md).
; Hook table entries: w32_hooks.asm.

section .text

; Car_OnDriverEnter(Car* this, Ped*) @0x427A20, thiscall, ret 4: a ped has become the car's
; driver. Call-hooked at both of its callers, 0x43F279 (Ped_UpdatePosition, the end of an
; enter-car animation, driver branch) and 0x4A63A3 (Player_TakeControlOfCar). We run the
; original, then c_on_driver_enter(car, ped, call site) in c/car_bonus.c decides whether
; it was the local player and pays the bonus. Own disassembly; names from re/functions.csv.
hk_DriverEnter:
    HENTER
    mov r12d, [abs G_ECX]           ; Car* (read before any call32)
    mov r13d, [rbx]                 ; Ped*
    mov r14d, [rbx - 4]             ; the game's return address = call site + 5
    mov edi, 0x427A20
    mov rsi, rbx
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    mov edi, r12d                   ; SysV: rdi, rsi, rdx; rsp is 16-aligned (HENTER)
    mov esi, r13d
    lea edx, [r14 - 5]
    call _c_on_driver_enter
    HRET
