; config.asm — the user's settings: config.yaml in the overlay dir, or --config=PATH.
;
; The format is a small, line-based subset of YAML (there is no YAML library on the host
; side, and a full parser is not worth it for flat settings):
;   # comment                  at the start of a line or after a blank
;   section:                   a top-level key without a value opens a section
;     key: value               an indented key belongs to the last section
; Values are booleans: true/false, yes/no, on/off, 1/0. Indent with spaces only. Lists,
; quotes, flow syntax and multi-line values are errors (with the line number); unknown
; sections and keys are reported and skipped. config.example.yaml lists every key.
;
; Sections:
;   debug  the game's own debug flags. HiddenDebugFlags (0x451930, called once from
;          WinMain2 at 0x4D121A) reads them from HKCU\SOFTWARE\DMA Design Ltd\GTA2\Debug
;          through RegGet (0x4B53B0), which reports a flag as set when the value merely
;          EXISTS (MOV BL,1 on RegQueryValueExA == 0; the data is never looked at). So
;          `true` creates the value and `false` deletes it from our in-memory registry
;          (gta2_install.reg already seeds do_blood and do_debug_keys). The exception,
;          show_player_names, is read by value with default 1
;          (GetSettingBooleanWithDefaultValue 0x4B5AE0) and is written as dword 0/1.
;          Applied before the game starts: a change needs a restart.

CFG_LINE    equ 1024
CFG_PATH    equ 1024
CF_EXISTS   equ 0                   ; flag kinds: set = value exists
CF_VALUE    equ 1                   ;             set = dword value != 0

section .text

; cfg_set_path(rdi = --config= argument): remember it as an absolute path, because the
; loader chdirs into the overlay dir before the config is read
cfg_set_path:
    push rbx
    mov rbx, rdi
    mov byte [cfg_explicit], 1
    cmp byte [rbx], '/'
    je .abs
    lea rdi, [cfg_abs]
    mov esi, CFG_PATH
    call _getcwd
    test rax, rax
    jz .abs                         ; no cwd: keep it relative
    lea rdi, [cfg_abs]
    lea rsi, [s_slash]
    call _strcat
    lea rdi, [cfg_abs]
    mov rsi, rbx
    call _strcat
    lea rbx, [cfg_abs]
.abs:
    mov [cfg_path], rbx
    pop rbx
    ret

; config_apply: read the config and apply it; runs after the registry seed
config_apply:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rdi, [cfg_path]
    test rdi, rdi
    jnz .open
    lea rdi, [s_cfg_default]
    mov [cfg_path], rdi
.open:
    lea rsi, [s_mode_r]
    call _fopen
    test rax, rax
    jnz .opened
    cmp byte [cfg_explicit], 0
    jne .missing
    lea rdi, [fmt_cfg_none]
    mov rsi, [cfg_path]
    xor eax, eax
    call _printf
    jmp .out
.missing:
    lea rdi, [cfg_msg]
    mov esi, CFG_LINE
    lea rdx, [fmt_cfg_missing]
    mov rcx, [cfg_path]
    xor eax, eax
    call _snprintf
    lea rdi, [cfg_msg]
    call fail
.opened:
    mov r15, rax
    xor r14d, r14d                  ; line number
    mov r13d, -1                    ; section: -1 none yet, 0 skipped, 1 debug
    mov dword [cfg_nset], 0
.line:
    lea rdi, [cfg_line]
    mov esi, CFG_LINE
    mov rdx, r15
    call _fgets
    test rax, rax
    jz .eof
    inc r14d
    lea rdi, [cfg_line]             ; cut a comment: '#' at column 0 or after a blank
    xor ecx, ecx
.cm:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .cm_done
    cmp al, '#'
    jne .cm_next
    test ecx, ecx
    jz .cut
    movzx edx, byte [rdi + rcx - 1]
    cmp dl, ' '
    je .cut
    cmp dl, 9
    jne .cm_next
.cut:
    mov byte [rdi + rcx], 0
    jmp .cm_done
.cm_next:
    inc ecx
    jmp .cm
.cm_done:
    lea rdi, [cfg_line]
    call reg_rstrip                 ; also drops CR/LF
    cmp byte [cfg_line], 0
    je .line
    lea rbx, [cfg_line]
    xor r12d, r12d                  ; indent
.ind:
    movzx eax, byte [rbx + r12]
    cmp al, ' '
    jne .ind_done
    inc r12d
    jmp .ind
.ind_done:
    cmp al, 9
    je .err_tab
    add rbx, r12                    ; rbx = key
    cmp al, '-'
    je .err_syntax
    cmp al, '"'
    je .err_syntax
    cmp al, 0x27                    ; '
    je .err_syntax
    cmp al, '{'
    je .err_syntax
    cmp al, '['
    je .err_syntax
    mov rdi, rbx
    mov esi, ':'
    call _strchr
    test rax, rax
    jz .err_colon
    mov byte [rax], 0
    inc rax
.vs:                                ; value = after ':' and blanks
    cmp byte [rax], ' '
    jne .vs_done
    inc rax
    jmp .vs
.vs_done:
    mov [cfg_val], rax
    mov rdi, rbx
    call reg_rstrip
    cmp byte [rbx], 0
    je .err_colon
    test r12d, r12d
    jnz .entry
    mov rax, [cfg_val]              ; top level: a section header
    cmp byte [rax], 0
    jne .err_toplevel
    mov rdi, rbx
    lea rsi, [s_cfg_debug]
    call _strcmp
    test eax, eax
    jnz .skip_section
    mov r13d, 1
    jmp .line
.skip_section:
    lea rdi, [fmt_cfg_skip_section]
    mov rsi, [cfg_path]
    mov edx, r14d
    mov rcx, rbx
    xor eax, eax
    call _printf
    xor r13d, r13d
    jmp .line
.entry:
    test r13d, r13d
    js .err_nosection
    jz .line                        ; inside a skipped section
    mov rdi, [cfg_val]
    call cfg_bool
    test eax, eax
    js .err_bool
    mov r12d, eax                   ; r12d = on/off from here on
    mov rdi, rbx
    call cfg_flag_find
    test rax, rax
    jz .unknown_flag
    mov rdi, rax
    mov esi, r12d
    call cfg_debug_set
    inc dword [cfg_nset]
    jmp .line
.unknown_flag:
    lea rdi, [fmt_cfg_skip_flag]
    mov rsi, [cfg_path]
    mov edx, r14d
    mov rcx, rbx
    xor eax, eax
    call _printf
    jmp .line
.eof:
    mov rdi, r15
    call _fclose
    lea rdi, [fmt_cfg_loaded]
    mov rsi, [cfg_path]
    mov edx, [cfg_nset]
    xor eax, eax
    call _printf
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.err_tab:
    lea r9, [msg_cfg_tab]
    jmp .err
.err_syntax:
    lea r9, [msg_cfg_syntax]
    jmp .err
.err_colon:
    lea r9, [msg_cfg_colon]
    jmp .err
.err_toplevel:
    lea r9, [msg_cfg_toplevel]
    jmp .err
.err_nosection:
    lea r9, [msg_cfg_nosection]
    jmp .err
.err_bool:
    lea r9, [msg_cfg_bool]
.err:
    lea rdi, [cfg_msg]
    mov esi, CFG_LINE
    lea rdx, [fmt_cfg_err]
    mov rcx, [cfg_path]
    mov r8d, r14d
    xor eax, eax
    call _snprintf
    lea rdi, [cfg_msg]
    call fail

; eax = cfg_bool(rdi = value) -> 1, 0, or -1 if it is not a boolean
cfg_bool:
    push rbx
    push r12
    push r13
    mov r12, rdi
    lea rbx, [cfg_bools]
.next:
    mov rsi, [rbx]
    test rsi, rsi
    jz .bad
    mov rdi, r12
    call _strcasecmp
    test eax, eax
    jz .hit
    add rbx, 16
    jmp .next
.hit:
    mov eax, [rbx + 8]
    jmp .out
.bad:
    mov eax, -1
.out:
    pop r13
    pop r12
    pop rbx
    ret

; rax = cfg_flag_find(rdi = name) -> {name, kind} entry of cfg_flags, or 0
cfg_flag_find:
    push rbx
    push r12
    push r13
    mov r12, rdi
    lea rbx, [cfg_flags]
.next:
    mov rsi, [rbx]
    test rsi, rsi
    jz .none
    mov rdi, r12
    call _strcasecmp
    test eax, eax
    jz .hit
    add rbx, 16
    jmp .next
.hit:
    mov rax, rbx
    jmp .out
.none:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; cfg_debug_set(rdi = cfg_flags entry, esi = on): put the flag into the registry; logs
; what is set and what was actually removed (not every absent `false`)
cfg_debug_set:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [s_reg_debug]
    call reg_key_add
    test eax, eax
    js .out
    mov r13d, eax
    cmp qword [rbx + 8], CF_VALUE
    je .by_value
    test r12d, r12d
    jz .delete
    mov dword [cfg_dword], 1
    jmp .write
.by_value:
    mov [cfg_dword], r12d
.write:
    mov edi, r13d
    mov rsi, [rbx]
    mov edx, 4                      ; REG_DWORD
    lea rcx, [cfg_dword]
    mov r8d, 4
    call reg_val_set
    jmp .log
.delete:
    mov edi, r13d
    mov rsi, [rbx]
    call reg_val_find
    test rax, rax
    jz .out                         ; already absent: nothing to report
    mov dword [rax + RV_LIVE], 0
.log:
    lea rdi, [fmt_cfg_flag]
    mov rsi, [rbx]
    lea rdx, [s_cfg_off]
    lea rcx, [s_cfg_on]
    test r12d, r12d
    cmovnz rdx, rcx
    xor eax, eax
    call _printf
.out:
    pop r13
    pop r12
    pop rbx
    ret

%macro CFLAG 1-2 CF_EXISTS
    dq %%n, %2
section .rodata
%%n: db %1, 0
section .data
%endmacro

%macro CBOOL 2
    dq %%n, %2
section .rodata
%%n: db %1, 0
section .data
%endmacro

section .data
align 8
cfg_bools:
    CBOOL "true", 1
    CBOOL "yes", 1
    CBOOL "on", 1
    CBOOL "1", 1
    CBOOL "false", 0
    CBOOL "no", 0
    CBOOL "off", 0
    CBOOL "0", 0
    dq 0, 0

; every name HiddenDebugFlags (0x451930) reads with RegGet, in its order, plus
; show_player_names; do_3d_sound is left out (another key, via 0x4B5000)
cfg_flags:
    CFLAG "play_replay"
    CFLAG "do_test"
    CFLAG "skip_mission"
    CFLAG "show_cycle"
    CFLAG "do_brian_test"
    CFLAG "do_iain_test"
    CFLAG "skip_tiles"
    CFLAG "do_show_counters"
    CFLAG "do_show_camera"
    CFLAG "do_show_input"
    CFLAG "do_show_timing"
    CFLAG "do_show_collision_box"
    CFLAG "do_show_physics"
    CFLAG "do_show_imaginary"
    CFLAG "skip_user"
    CFLAG "skip_traffic_lights"
    CFLAG "skip_recycling"
    CFLAG "log_collisions"
    CFLAG "do_show_traffic_lights_info"
    CFLAG "do_show_ids"
    CFLAG "limit_recycling"
    CFLAG "no_annoying_chars"
    CFLAG "skip_slopes"
    CFLAG "skip_left"
    CFLAG "skip_right"
    CFLAG "skip_top"
    CFLAG "skip_bottom"
    CFLAG "skip_lid"
    CFLAG "log_routefinder"
    CFLAG "do_mike"
    CFLAG "skip_particles"
    CFLAG "show_hidden_faces"
    CFLAG "get_all_weapons"
    CFLAG "do_exit_after_replay"
    CFLAG "dont_get_car_back"
    CFLAG "do_show_instruments"
    CFLAG "skip_ambulance"
    CFLAG "skip_police"
    CFLAG "skip_frontend"
    CFLAG "do_invulnerable"
    CFLAG "show_all_arrows"
    CFLAG "do_show_horn"
    CFLAG "keep_weapons_after_death"
    CFLAG "skip_skidmarks"
    CFLAG "do_show_junc_ids"
    CFLAG "do_corner_window"
    CFLAG "do_infinite_lives"
    CFLAG "do_load_savegame"
    CFLAG "skip_audio"
    CFLAG "do_debug_keys"
    CFLAG "log_random"
    CFLAG "log_random_extra"
    CFLAG "log_input"
    CFLAG "log_directinput"
    CFLAG "ignore_replay_header"
    CFLAG "skip_trains"
    CFLAG "skip_buses"
    CFLAG "skip_quit_confirm"
    CFLAG "do_sync_check"
    CFLAG "skip_fire_engines"
    CFLAG "show_brief_number"
    CFLAG "skip_window_check"
    CFLAG "skip_replay_sync_check"
    CFLAG "do_show_object_ids"
    CFLAG "do_kill_phones_on_answer"
    CFLAG "do_miss_logging"
    CFLAG "do_text_id_test"
    CFLAG "do_police_1"
    CFLAG "do_police_2"
    CFLAG "do_police_3"
    CFLAG "skip_draw"
    CFLAG "do_free_shopping"
    CFLAG "skip_dummies"
    CFLAG "do_blood"
    CFLAG "show_player_names", CF_VALUE
    dq 0, 0

cfg_path:     dq 0                  ; config file; 0 = s_cfg_default in the overlay dir

section .rodata
s_cfg_default: db "config.yaml", 0
s_cfg_debug:  db "debug", 0
s_reg_debug:  db "HKEY_CURRENT_USER\SOFTWARE\DMA Design Ltd\GTA2\Debug", 0
s_slash:      db "/", 0
s_cfg_on:     db "on", 0
s_cfg_off:    db "off", 0
fmt_cfg_none: db "config: %s not found (optional), defaults", 10, 0
fmt_cfg_missing: db "config: cannot open %s", 0
fmt_cfg_loaded: db "config: %s -> %d setting(s) applied", 10, 0
fmt_cfg_flag: db "config: debug.%s = %s", 10, 0
fmt_cfg_skip_section: db "config: %s:%d: unknown section '%s', skipped", 10, 0
fmt_cfg_skip_flag: db "config: %s:%d: unknown debug flag '%s', skipped", 10, 0
fmt_cfg_err:  db "config: %s:%d: %s", 0
msg_cfg_tab:  db "tabs are not allowed in indentation, use spaces", 0
msg_cfg_syntax: db "only 'key: value' lines are supported (no lists, quotes or {} [])", 0
msg_cfg_colon: db "expected 'key: value' or 'section:'", 0
msg_cfg_toplevel: db "a top-level key must be a section header ('debug:'), not 'key: value'", 0
msg_cfg_nosection: db "indented key before any section header", 0
msg_cfg_bool: db "expected true or false (also yes/no, on/off, 1/0)", 0

section .bss
cfg_explicit: resb 1                ; --config= given: a missing file is an error
alignb 8
cfg_val:      resq 1
cfg_nset:     resd 1
cfg_dword:    resd 1
cfg_abs:      resb CFG_PATH
cfg_line:     resb CFG_LINE
cfg_msg:      resb CFG_LINE
section .text
