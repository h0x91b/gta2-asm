; w32_tables.asm — the list of shim tables bind_slot/find_shim search, one per DLL.
; A DLL listed here is also a "system" module: GetModuleHandleA/LoadLibraryA return a
; fake HMODULE for it and GetProcAddress resolves through its table.

section .data
align 8
shim_tables:
    dq shimtab_kernel32
    dq shimtab_kernel32_files
    dq shimtab_kernel32_locale
    dq shimtab_user32
    dq shimtab_gdi32
    dq shimtab_advapi32
    dq shimtab_winmm
    dq shimtab_version
    dq shimtab_ole32
    dq shimtab_shell32
    dq shimtab_dinput8
    dq shimtab_idirectinput8
    dq shimtab_idirectinputdevice8
    dq shimtab_dplayx
    dq shimtab_mss32
    dq shimtab_binkw32
    dq shimtab_gta2
    dq shimtab_dmavideo
    dq shimtab_d3ddll
    dq 0
section .text
