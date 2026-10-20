; w32_dinput.asm — COM object helper + a silent DirectInput 8.
;
; COM: an interface is a shim table whose entries are its methods in vtable order
; (names "Interface::Method"). com_new builds the vtable once (each method a normal
; import slot, so it shows up in --trace and unimplemented ones stop the run) and
; allocates the object in low memory: {u32 vtbl, u32 refcount, u32 kind, ...}.
;
; DirectInput: IDirectInput8A::CreateDevice hands out devices whose methods succeed;
; GetDeviceState reports nothing pressed and GetDeviceData no buffered events.
; Real input (SDL keyboard state -> DIK_* array) is later work.

DI_OK          equ 0
E_NOINTERFACE  equ 0x80004002
COM_VTBL       equ 0
COM_REFS       equ 4
COM_KIND       equ 8

section .text

; eax = com_new(rdi = interface shim table, esi = object size)
com_new:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi
    mov eax, [rbx + 8 + SH_POP + 4]  ; the first entry's spare dword caches the vtable
    test eax, eax
    jnz .have_vtbl
    xor r13d, r13d                  ; count methods
.count:
    imul eax, r13d, SHIM_SIZE
    cmp qword [rbx + 8 + rax + SH_NAME], 0
    je .counted
    inc r13d
    jmp .count
.counted:
    lea edi, [r13*4]
    mov esi, 16
    call low_alloc
    mov r14d, eax                   ; vtable
    xor r15d, r15d
.method:
    cmp r15d, r13d
    jae .built
    imul eax, r15d, SHIM_SIZE
    mov rdi, [rbx]
    mov rsi, [rbx + 8 + rax + SH_NAME]
    xor edx, edx
    call new_slot
    mov [r14 + r15*4], eax
    inc r15d
    jmp .method
.built:
    mov [rbx + 8 + SH_POP + 4], r14d
    mov eax, r14d
.have_vtbl:
    mov r13d, eax
    mov edi, r12d
    mov esi, 16
    call low_alloc
    mov [rax + COM_VTBL], r13d
    mov dword [rax + COM_REFS], 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

com_AddRef:                 ; (this)
    mov eax, [rdi]
    inc dword [rax + COM_REFS]
    mov eax, [rax + COM_REFS]
    ret
com_Release:                ; (this): objects are never freed (low arena)
    mov eax, [rdi]
    dec dword [rax + COM_REFS]
    mov eax, [rax + COM_REFS]
    ret
com_QueryInterface:         ; (this, riid, ppv): only what we created exists
    mov eax, [rdi + 8]
    test eax, eax
    jz .r
    mov dword [rax], 0
.r:
    mov eax, E_NOINTERFACE
    ret

; com_ok: method that succeeds doing nothing; logs its first call
com_ok:
    jmp h_silent

; DirectInput8Create(hinst, version, riid, ppvOut, outer)
di_DirectInput8Create:
    HENTER
    lea rdi, [shimtab_idirectinput8]
    mov esi, 16
    call com_new
    mov ecx, ARG(3)
    mov [rcx], eax
    mov r12d, eax
    lea rdi, [fmt_di_create]
    mov esi, ARG(1)
    mov edx, r12d
    xor eax, eax
    call _printf
    xor eax, eax
    HRET

; IDirectInput8A::CreateDevice(this, rguid, lplpDevice, outer)
di_CreateDevice:
    HENTER
    lea rdi, [shimtab_idirectinputdevice8]
    mov esi, 16
    call com_new
    mov r12d, eax
    mov ecx, ARG(1)
    mov ecx, [rcx]                  ; GUID.Data1: 6F1D2B61 keyboard, 6F1D2B60 mouse
    mov [r12 + COM_KIND], ecx
    mov ecx, ARG(2)
    mov [rcx], r12d
    lea rdi, [fmt_di_device]
    mov rsi, [s_di_kind_other_ptr]
    mov eax, [r12 + COM_KIND]
    lea rcx, [s_di_kbd]
    cmp eax, 0x6F1D2B61
    cmove rsi, rcx
    lea rcx, [s_di_mouse]
    cmp eax, 0x6F1D2B60
    cmove rsi, rcx
    mov edx, r12d
    xor eax, eax
    call _printf
    xor eax, eax
    HRET

; IDirectInputDevice8A::GetDeviceState(this, cbData, lpvData): nothing pressed
di_GetDeviceState:
    HENTER
    mov edi, ARG(2)
    xor esi, esi
    mov edx, ARG(1)
    call _memset
    xor eax, eax
    HRET

; IDirectInputDevice8A::GetDeviceData(this, cbObjectData, rgdod, pdwInOut, flags)
di_GetDeviceData:
    mov eax, [rdi + 12]
    test eax, eax
    jz .r
    mov dword [rax], 0              ; no buffered events
.r:
    xor eax, eax
    ret

; IDirectInputDevice8A::GetCapabilities(this, DIDEVCAPS*): zeroed apart from dwSize
di_GetCapabilities:
    HENTER
    mov r12d, ARG(1)
    mov r13d, [r12]
    mov edi, r12d
    xor esi, esi
    mov edx, r13d
    call _memset
    mov [r12], r13d
    xor eax, eax
    HRET

section .data
align 8
shimtab_dinput8:
    dq s_dinput8
    SHIM "DirectInput8Create", 20, di_DirectInput8Create
    dq 0

shimtab_idirectinput8:
    dq s_dinput8
    SHIM "IDirectInput8A::QueryInterface", 12, com_QueryInterface
    SHIM "IDirectInput8A::AddRef", 4, com_AddRef
    SHIM "IDirectInput8A::Release", 4, com_Release
    SHIM "IDirectInput8A::CreateDevice", 16, di_CreateDevice
    SHIM "IDirectInput8A::EnumDevices", 20, com_ok          ; no devices enumerated
    SHIM "IDirectInput8A::GetDeviceStatus", 8, com_ok
    SHIM "IDirectInput8A::RunControlPanel", 12, com_ok
    SHIM "IDirectInput8A::Initialize", 12, com_ok
    SHIM "IDirectInput8A::FindDevice", 16, host_unimpl
    SHIM "IDirectInput8A::EnumDevicesBySemantics", 24, com_ok
    SHIM "IDirectInput8A::ConfigureDevices", 20, host_unimpl
    dq 0

shimtab_idirectinputdevice8:
    dq s_dinput8
    SHIM "IDirectInputDevice8A::QueryInterface", 12, com_QueryInterface
    SHIM "IDirectInputDevice8A::AddRef", 4, com_AddRef
    SHIM "IDirectInputDevice8A::Release", 4, com_Release
    SHIM "IDirectInputDevice8A::GetCapabilities", 8, di_GetCapabilities
    SHIM "IDirectInputDevice8A::EnumObjects", 16, com_ok
    SHIM "IDirectInputDevice8A::GetProperty", 12, com_ok
    SHIM "IDirectInputDevice8A::SetProperty", 12, com_ok
    SHIM "IDirectInputDevice8A::Acquire", 4, com_ok
    SHIM "IDirectInputDevice8A::Unacquire", 4, com_ok
    SHIM "IDirectInputDevice8A::GetDeviceState", 12, di_GetDeviceState
    SHIM "IDirectInputDevice8A::GetDeviceData", 20, di_GetDeviceData
    SHIM "IDirectInputDevice8A::SetDataFormat", 8, com_ok
    SHIM "IDirectInputDevice8A::SetEventNotification", 8, com_ok
    SHIM "IDirectInputDevice8A::SetCooperativeLevel", 12, com_ok
    SHIM "IDirectInputDevice8A::GetObjectInfo", 16, host_unimpl
    SHIM "IDirectInputDevice8A::GetDeviceInfo", 8, host_unimpl
    SHIM "IDirectInputDevice8A::RunControlPanel", 12, com_ok
    SHIM "IDirectInputDevice8A::Initialize", 16, com_ok
    SHIM "IDirectInputDevice8A::CreateEffect", 20, host_unimpl
    SHIM "IDirectInputDevice8A::EnumEffects", 16, com_ok
    SHIM "IDirectInputDevice8A::GetEffectInfo", 12, host_unimpl
    SHIM "IDirectInputDevice8A::GetForceFeedbackState", 8, host_unimpl
    SHIM "IDirectInputDevice8A::SendForceFeedbackCommand", 8, com_ok
    SHIM "IDirectInputDevice8A::EnumCreatedEffectObjects", 16, com_ok
    SHIM "IDirectInputDevice8A::Escape", 8, host_unimpl
    SHIM "IDirectInputDevice8A::Poll", 4, com_ok
    SHIM "IDirectInputDevice8A::SendDeviceData", 20, com_ok
    SHIM "IDirectInputDevice8A::EnumEffectsInFile", 20, com_ok
    SHIM "IDirectInputDevice8A::WriteEffectToFile", 20, host_unimpl
    SHIM "IDirectInputDevice8A::BuildActionMap", 16, host_unimpl
    SHIM "IDirectInputDevice8A::SetActionMap", 16, host_unimpl
    SHIM "IDirectInputDevice8A::GetImageInfo", 8, host_unimpl
    dq 0

s_di_kind_other_ptr: dq s_di_other

section .rodata
s_di_kbd:    db "keyboard", 0
s_di_mouse:  db "mouse", 0
s_di_other:  db "other", 0
fmt_di_create: db "  [w32] DirectInput8Create(version 0x%x) -> IDirectInput8A 0x%x (silent: no input yet)", 10, 0
fmt_di_device: db "  [w32] IDirectInput8A::CreateDevice(%s) -> 0x%x", 10, 0
section .text
