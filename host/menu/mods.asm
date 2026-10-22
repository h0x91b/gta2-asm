; menu/mods.asm — the K menu's Mods page: switches for gameplay mods (C32, docs/c32.md).
; The value row's {change, format} pair points straight at 64-bit host C functions
; (SysV, the same contract as a NASM dm_x_change / dm_x_fmt).

section .data
    DM_PAGE  dmp_mods, dmp_root, 125, "Mods"
    DM_ITEM  dmp_mods, 10, DM_VALUE, "Car entry bonus: ", dmv_carbonus  ; c/c32_host.c
align 8
dmv_carbonus: dq _c32_carbonus_change, _c32_carbonus_fmt
section .text
