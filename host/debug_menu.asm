; debug_menu.asm — the core of our in-game debug menu (the "K menu"): K opens it in
; gameplay, drawn with the game's own font (DrawGTAText) and sprites (DrawSprite2D) over
; the HUD from the DrawUI call hook (w32_hooks.asm). Design, keys and the "how to add a
; page" recipe: docs/debug-menu.md.
;
;   K / ESC          open / close (ESC does not reach the game while the menu is open)
;   UP / DOWN        select (wraps); PAGE UP / PAGE DOWN 10 rows; HOME / END
;   LEFT / RIGHT     change the value; RETURN activates; BACKSPACE back to the parent page
;
; While the menu is open every key press goes to it, not to the game; keys held when it
; opens are released, so the player stops. Key releases always reach the game.
;
; Nothing here lists the menu's content. Every module declares its own pages and rows
; with DM_PAGE / DM_ITEM and its per-frame work with DM_FRAME; the macros put fixed-size
; records into the Mach-O sections __DATA,__dm_pages / __dm_items / __dm_frame, which the
; linker concatenates across the whole build (bounds: section$start$… / section$end$…).
; dm_build turns them into a sorted row list per page once, on the first gameplay frame.
; Files in host/menu/ are included by build.sh (menu_modules.inc), so a new page is a new
; file and nothing else. This file keeps the root page, the shared player / car helpers
; and the drawing components (dm_text_at, dm_rect, dm_sprite, dm_gxt).
;
; Layout is in 640x480 units, scaled by the main camera's uiScale like the game's HUD.
; Text: DrawGTAText @0x4CC100, stdcall(wchar_t* str, SCR_f x, SCR_f y, short font,
; SCR_f scale, PALETTE_BASE* pal, int remap, int invisibility, SCR_f ?), ret 0x24; the
; default font id is at 0x672F24. Box: DrawFlatRect2D @0x474110, stdcall(float x1, y1,
; x2, y2, u32 argb), ret 0x14. Calls and addresses from gta2-seuko-mod by izawartka
; (https://github.com/izawartka/gta2-seuko-mod), src/game/functions.h, memory.h,
; src/modules/ui/components/text.cpp @25b1985.

DIK_ESCAPE equ 0x01
DIK_BACK   equ 0x0E
DIK_RETURN equ 0x1C
DIK_K      equ 0x25
DIK_NUMPADENTER equ 0x9C
DIK_HOME   equ 0xC7
DIK_UP     equ 0xC8
DIK_PRIOR  equ 0xC9
DIK_LEFT   equ 0xCB
DIK_RIGHT  equ 0xCD
DIK_END    equ 0xCF
DIK_DOWN   equ 0xD0
DIK_NEXT   equ 0xD1

DM_ACTION  equ 0                    ; item kinds; data = fn, run on the game's side (dm_defer)
DM_FLAG    equ 2                    ; data = a byte toggled 0 / 1
DM_CLOSE   equ 3
DM_PAGE    equ 4                    ; data = page to open (emitted by DM_PAGE)
DM_BACK    equ 5
DM_VALUE   equ 6                    ; data = {change(esi = dir), format(rdi = text end)}

DM_X       equ 16                   ; 640x480 layout
DM_Y       equ 104                  ; below the HUD bars
DM_LINE    equ 17
DM_PAD     equ 6
DM_VISIBLE equ 16                   ; rows shown at once, more scroll
DM_PANE_GAP equ 12                  ; the preview pane starts this far right of the list box
DM_TEXT_SCALE equ 0x3000            ; 0.75 (SCR_f, 14 fraction bits)
DM_LINES   equ 48                   ; low line buffers per frame
DM_WCHARS  equ 64
DM_LOWHDR  equ 256                  ; dm_low: palette kinds +0, GXT key +16, measured text +128, then the lines
DM_MEASURE equ 128
DM_W_MIN   equ 150                  ; the list box grows with its widest line
DM_TOAST_FRAMES equ 120
DM_DEFER_MAX equ 8

; MainCamera, DefaultFontId, WindowedWidth: gta2-seuko-mod src/game/memory.h @25b1985
UI_CAMERA  equ 0x5E3CC4             ; Camera* (main), uiScale at +0xa8
GAME       equ 0x5EB4FC             ; Game*: +0 gameStatus (1 run, 2 paused), +0x23 pause allowed, +0x38 Player
FONT_ID    equ 0x672F24
WINDOW_W   equ 0x673578
; g_StyleData (StyleData*: +0x14 spriteBases, +0x20 sprite entries, +0x5c AllCarsInfo) and
; g_LocaleSettings: re/globals.csv; layouts re/gta2_types.h, confirmed by Seq 27
; (report seq49-car-sprite-remap.md)
STYLE_DATA equ 0x670684
LOCALE     equ 0x671550

; ---- records. A page (DPG_SIZE) is static data plus its runtime row list; an item
; (DI_SIZE) is one row; a frame hook (DF_SIZE) one per-frame function.
DPG_TITLE  equ 0
DPG_PARENT equ 8                    ; 0 = the root
DPG_DRAW   equ 16                   ; draw(rdi = page): extra content, the preview pane
DPG_KEY    equ 24                   ; key(edi = DIK) -> eax = 1 consumed
DPG_ROWS   equ 32                   ; rows() -> eax = dynamic rows before the items
DPG_ROWFMT equ 40                   ; rowfmt(edi = row, rsi = 128-byte buffer)
DPG_ROWCHG equ 48                   ; rowchange(edi = row, esi = -1 / +1 / 0 RETURN)
DPG_ITEMS  equ 56                   ; runtime: item pointers, sorted, Back / Close last
DPG_NITEMS equ 64
DPG_SEL    equ 68
DPG_TOP    equ 72
DPG_ORDER  equ 76
DPG_SIZE   equ 80
DI_PAGE    equ 0
DI_ORDER   equ 8
DI_KIND    equ 12
DI_LABEL   equ 16
DI_DATA    equ 24
DI_SIZE    equ 32
DF_ORDER   equ 0
DF_FN      equ 8
DF_SIZE    equ 16

; DM_PAGE name, parent, order, "Title"[, draw, key, rows, rowfmt, rowchange]: a page, and
; its link row "Title..." on the parent at that order (none for the root, parent 0)
%macro DM_PAGE 4-9 0, 0, 0, 0, 0
[section __DATA,__dm_pages data align=8]
%1: dq %%t, %2, %5, %6, %7, %8, %9, 0
    dd 0, 0, 0, %3
%ifnidn %2, 0
[section __DATA,__dm_items data align=8]
    dq %2
    dd %3, DM_PAGE
    dq %%l, %1
%endif
[section .rodata]
%%t: db %4, 0
%%l: db %4, "...", 0
__SECT__
%endmacro
; DM_ITEM page, order, kind, "label", data: one row of a page
%macro DM_ITEM 5
[section __DATA,__dm_items data align=8]
    dq %1
    dd %2, %3
    dq %%l, %5
[section .rodata]
%%l: db %4, 0
__SECT__
%endmacro
; DM_FRAME order, fn: fn() once per gameplay frame on the game's side, before the HUD,
; lowest order first, whether the menu is open or not
%macro DM_FRAME 2
[section __DATA,__dm_frame data align=8]
    dd %1, 0
    dq %2
__SECT__
%endmacro
; DMVALUE name: a DM_VALUE item's {change, format} pair, dmv_name
%macro DMVALUE 1
align 8
dmv_%1: dq dm_%1_change, dm_%1_fmt
%endmacro

extern section$start$__DATA$__dm_pages
extern section$end$__DATA$__dm_pages
extern section$start$__DATA$__dm_items
extern section$end$__DATA$__dm_items
extern section$start$__DATA$__dm_frame
extern section$end$__DATA$__dm_frame

section .text

; eax = dbgmenu_key(edi = DIK, esi = down): called first by input_key; 1 = consumed
dbgmenu_key:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    call dm_in_gameplay
    test eax, eax
    jnz .game
    mov byte [dm_open], 0           ; left gameplay with the menu open
    jmp .pass
.game:
    test r12d, r12d
    jz .pass                        ; releases always reach the game
    cmp byte [dm_open], 0
    jne .menu
    cmp ebx, DIK_K
    jne .pass
    cmp byte [dm_built], 0
    je .pass
    mov byte [dm_open], 1
    call input_release_all          ; the player stops; ups pass through us
    jmp .eat
.menu:
    cmp ebx, DIK_K
    je .close
    cmp ebx, DIK_ESCAPE
    je .close
    mov r13, [dm_page]
    mov rax, [r13 + DPG_KEY]
    test rax, rax
    jz .generic
    mov edi, ebx
    call rax
    test eax, eax
    jnz .eat
.generic:
    call dm_total                   ; eax = rows
    mov ecx, eax
    mov eax, [r13 + DPG_SEL]
    cmp ebx, DIK_UP
    je .up
    cmp ebx, DIK_DOWN
    je .down
    cmp ebx, DIK_PRIOR
    je .pgup
    cmp ebx, DIK_NEXT
    je .pgdn
    cmp ebx, DIK_HOME
    je .home
    cmp ebx, DIK_END
    je .end
    cmp ebx, DIK_BACK
    je .back
    cmp ebx, DIK_LEFT
    je .left
    cmp ebx, DIK_RIGHT
    je .right
    cmp ebx, DIK_RETURN
    je .enter
    cmp ebx, DIK_NUMPADENTER
    je .enter
    jmp .eat
.close:
    mov byte [dm_open], 0
    jmp .eat
.up:
    dec eax
    jns .sel
    lea eax, [rcx - 1]
    jmp .sel
.down:
    inc eax
    cmp eax, ecx
    jb .sel
    xor eax, eax
    jmp .sel
.pgup:
    sub eax, 10
    jns .sel
.home:
    xor eax, eax
    jmp .sel
.pgdn:
    add eax, 10
    cmp eax, ecx
    jb .sel
.end:
    lea eax, [rcx - 1]
.sel:
    mov [r13 + DPG_SEL], eax
    jmp .eat
.back:
    call dm_back
    jmp .eat
.left:
    mov esi, -1
    jmp .change
.right:
    mov esi, 1
    jmp .change
.enter:
    xor esi, esi
.change:
    call dm_activate
.eat:
    mov eax, 1
    jmp .out
.pass:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; eax = dm_in_gameplay(): the game drew its HUD (DrawUI) within the last few frames
dm_in_gameplay:
    xor eax, eax
    cmp byte [dm_ui_seen], 0
    je .out
    mov ecx, [r_frames]
    sub ecx, [dm_ui_frame]
    cmp ecx, 3
    setb al
.out:
    ret

; eax = dm_dyn(): the current page's dynamic rows (0 without a rows callback)
dm_dyn:
    sub rsp, 8
    xor eax, eax
    mov rcx, [dm_page]
    mov rcx, [rcx + DPG_ROWS]
    test rcx, rcx
    jz .out
    call rcx
.out:
    add rsp, 8
    ret

; eax = dm_total(): rows of the current page, dynamic + items (Back / Close included)
dm_total:
    sub rsp, 8
    call dm_dyn
    mov rcx, [dm_page]
    add eax, [rcx + DPG_NITEMS]
    add rsp, 8
    ret

; dm_back: to the parent page (its selection is still on the link we came by); the root
; closes the menu
dm_back:
    mov rax, [dm_page]
    mov rax, [rax + DPG_PARENT]
    test rax, rax
    jz .close
    mov [dm_page], rax
    ret
.close:
    mov byte [dm_open], 0
    ret

; dm_activate(esi = -1 left / +1 right / 0 RETURN) on the selected row
dm_activate:
    push rbx
    push r12
    sub rsp, 8
    mov r12d, esi
    call dm_dyn
    mov rcx, [dm_page]
    mov edi, [rcx + DPG_SEL]
    cmp edi, eax
    jae .item
    mov rax, [rcx + DPG_ROWCHG]     ; a dynamic row
    test rax, rax
    jz .out
    mov esi, r12d
    call rax
    jmp .out
.item:
    sub edi, eax
    cmp edi, [rcx + DPG_NITEMS]
    jae .out
    mov rax, [rcx + DPG_ITEMS]
    mov rcx, [rax + rdi*8]
    mov esi, r12d
    call dm_change
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; dm_change(rcx = item, esi = -1 left / +1 right / 0 RETURN)
dm_change:
    mov eax, [rcx + DI_KIND]
    cmp eax, DM_CLOSE
    je .close
    cmp eax, DM_ACTION
    je .action
    cmp eax, DM_PAGE
    je .page
    cmp eax, DM_BACK
    je dm_back
    cmp eax, DM_VALUE
    je .value
    mov rdx, [rcx + DI_DATA]        ; DM_FLAG: any key toggles
    xor byte [rdx], 1
    and byte [rdx], 1
    ret
.close:
    mov byte [dm_open], 0
    ret
.page:
    test esi, esi
    jnz .out
    mov rax, [rcx + DI_DATA]
    mov [dm_page], rax
    ret
.value:
    mov rax, [rcx + DI_DATA]
    jmp [rax]                       ; change(esi = dir)
.action:
    test esi, esi
    jnz .out
    mov rdi, [rcx + DI_DATA]
    jmp dm_defer
.out:
    ret

; dm_defer(rdi = fn): fn() runs on the game's side of this frame, in hk_DrawUI (calls into
; the game are not made from the input handler)
dm_defer:
    mov eax, [dm_defer_n]
    cmp eax, DM_DEFER_MAX
    jae .out
    lea rcx, [dm_defer_q]
    mov [rcx + rax*8], rdi
    inc dword [dm_defer_n]
.out:
    ret

; dm_toast_set(rax = string): show it at the bottom for DM_TOAST_FRAMES
dm_toast_set:
    mov [dm_toast], rax
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    ret

; dm_build: every page gets its items (sorted by order, link order on ties) plus Back or
; Close; the frame hooks get sorted by order. Once, on the first gameplay frame.
dm_build:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [rel section$start$__DATA$__dm_pages]
.page:
    lea rax, [rel section$end$__DATA$__dm_pages]
    cmp rbx, rax
    jae .frames
    xor r12d, r12d                  ; items on this page
    lea r13, [rel section$start$__DATA$__dm_items]
.count:
    lea rax, [rel section$end$__DATA$__dm_items]
    cmp r13, rax
    jae .alloc
    cmp [r13 + DI_PAGE], rbx
    jne .cn
    inc r12d
.cn:
    add r13, DI_SIZE
    jmp .count
.alloc:
    lea edi, [r12*8 + 8]
    call _malloc
    mov r14, rax
    mov [rbx + DPG_ITEMS], rax
    xor r15d, r15d
    lea r13, [rel section$start$__DATA$__dm_items]
.fill:
    lea rax, [rel section$end$__DATA$__dm_items]
    cmp r13, rax
    jae .filled
    cmp [r13 + DI_PAGE], rbx
    jne .fn
    mov ecx, r15d                   ; insertion sort by order
    mov edx, [r13 + DI_ORDER]
.ins:
    test ecx, ecx
    jz .put
    mov rax, [r14 + rcx*8 - 8]
    cmp [rax + DI_ORDER], edx
    jle .put
    mov [r14 + rcx*8], rax
    dec ecx
    jmp .ins
.put:
    mov [r14 + rcx*8], r13
    inc r15d
.fn:
    add r13, DI_SIZE
    jmp .fill
.filled:
    lea rax, [dmi_back]
    lea rcx, [dmi_close]
    cmp qword [rbx + DPG_PARENT], 0
    cmove rax, rcx
    mov [r14 + r15*8], rax
    inc r15d
    mov [rbx + DPG_NITEMS], r15d
    add rbx, DPG_SIZE
    jmp .page
.frames:                            ; insertion sort of the 16-byte frame records in place
    lea rbx, [rel section$start$__DATA$__dm_frame]
    mov r12, rbx
.fo:
    add r12, DF_SIZE
    lea rax, [rel section$end$__DATA$__dm_frame]
    cmp r12, rax
    jae .done
    mov r13d, [r12 + DF_ORDER]
    mov r14, [r12 + DF_FN]
    mov rcx, r12
.fi:
    cmp rcx, rbx
    jbe .fput
    cmp [rcx - DF_SIZE + DF_ORDER], r13d
    jle .fput
    mov eax, [rcx - DF_SIZE + DF_ORDER]
    mov [rcx + DF_ORDER], eax
    mov rax, [rcx - DF_SIZE + DF_FN]
    mov [rcx + DF_FN], rax
    sub rcx, DF_SIZE
    jmp .fi
.fput:
    mov [rcx + DF_ORDER], r13d
    mov [rcx + DF_FN], r14
    jmp .fo
.done:
    lea rax, [dmp_root]
    mov [dm_page], rax
    mov byte [dm_built], 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; DrawUI(this) @0x4CA440, fastcall, no stack arguments: the HUD, called at 0x45A61F once
; per gameplay frame (ecx = [0x672F40]). The modules' DM_FRAME hooks and the deferred menu
; actions run first (so their overlays sit under the HUD), then the original, then the menu.
; Hook site from gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/events/draw-ui.cpp @25b1985.
hk_DrawUI:
    HENTER 16
    mov r12d, [abs G_ECX]
    mov eax, [r_frames]
    mov [dm_ui_frame], eax
    mov byte [dm_ui_seen], 1
    cmp byte [dm_built], 0
    jne .frames
    call dm_build
.frames:
    lea r13, [rel section$start$__DATA$__dm_frame]
.f:
    lea rax, [rel section$end$__DATA$__dm_frame]
    cmp r13, rax
    jae .deferred
    call [r13 + DF_FN]
    add r13, DF_SIZE
    jmp .f
.deferred:
    xor r13d, r13d
.d:
    cmp r13d, [dm_defer_n]          ; a deferred fn may queue another
    jae .ddone
    lea rax, [dm_defer_q]
    call [rax + r13*8]
    inc r13d
    jmp .d
.ddone:
    mov dword [dm_defer_n], 0
    mov edi, 0x4CA440
    mov rsi, rbx
    xor edx, edx
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    call dm_draw
    HRET

; dm_draw: the menu (when open) and the toast line, in 640x480 units times uiScale. The
; current page shows DM_VISIBLE rows around the selection with a scroll bar when it has
; more, then its draw callback (the preview pane).
dm_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov eax, [abs UI_CAMERA]
    test eax, eax
    jz .out
    mov eax, [rax + 0xa8]           ; uiScale
    mov [dm_scale], eax
    cmp qword [dm_low], 0
    jne .have_low
    mov edi, DM_LOWHDR + DM_LINES * DM_WCHARS * 2
    mov esi, 16
    call low_alloc
    mov [dm_low], rax
.have_low:
    mov dword [dm_line_no], 0
    cmp byte [dm_open], 0
    je .toast
    mov r15, [dm_page]
    call dm_dyn
    mov [dm_dyn_rows], eax
    add eax, [r15 + DPG_NITEMS]
    mov r14d, eax                   ; rows
    mov eax, [r15 + DPG_SEL]        ; keep the selection and the window in range
    cmp eax, r14d
    jb .s1
    lea eax, [r14 - 1]
    mov [r15 + DPG_SEL], eax
.s1:
    mov ecx, [r15 + DPG_TOP]
    cmp eax, ecx
    jae .s2
    mov ecx, eax
.s2:
    lea edx, [rcx + DM_VISIBLE - 1]
    cmp eax, edx
    jbe .s3
    lea ecx, [rax - DM_VISIBLE + 1]
.s3:
    lea edx, [rcx + DM_VISIBLE]
    cmp edx, r14d
    jbe .s4
    mov ecx, r14d
    sub ecx, DM_VISIBLE
    jns .s4
    xor ecx, ecx
.s4:
    mov [r15 + DPG_TOP], ecx
    mov ebx, r14d                   ; visible rows
    cmp ebx, DM_VISIBLE
    jbe .measure
    mov ebx, DM_VISIBLE
.measure:                           ; the box fits the title and the visible rows
    mov rdi, [r15 + DPG_TITLE]
    call dm_text_w
    mov [rsp + 24], eax
    mov r12d, [r15 + DPG_TOP]
    lea r13d, [r12 + rbx]
.mrow:
    cmp r12d, r13d
    jae .mdone
    mov edi, r12d
    call dm_row_label
    lea rdi, [dm_buf]
    call dm_text_w
    cmp eax, [rsp + 24]
    jbe .mnext
    mov [rsp + 24], eax
.mnext:
    inc r12d
    jmp .mrow
.mdone:
    mov eax, [rsp + 24]
    add eax, DM_PAD
    cmp eax, DM_W_MIN
    jge .mw
    mov eax, DM_W_MIN
.mw:
    cmp r14d, DM_VISIBLE
    jbe .mbar
    add eax, 6                      ; room for the scroll bar
.mbar:
    add eax, DM_X
    mov [dm_box_x2], eax
    add eax, DM_PANE_GAP + DM_PAD
    mov [dm_pane_x], eax
.box:                               ; DM_X..dm_box_x2, title + rows + half a line
    lea eax, [rbx + 1]
    imul eax, eax, DM_LINE
    add eax, DM_Y + DM_LINE / 2 + DM_PAD
    mov [rsp + 16], eax             ; box bottom
    mov edi, DM_X - DM_PAD
    mov esi, DM_Y - DM_PAD
    mov edx, [dm_box_x2]
    mov ecx, eax
    mov r8d, 0x80000000
    call dm_rect
    mov rdi, [r15 + DPG_TITLE]
    mov esi, DM_Y
    xor edx, edx
    call dm_text
    mov r12d, [r15 + DPG_TOP]       ; row
    mov r13d, DM_Y + DM_LINE + DM_LINE / 2
    add ebx, r12d                   ; end row
.row:
    cmp r12d, ebx
    jae .bar
    mov edi, r12d
    call dm_row_label
    lea rdi, [dm_buf]
    mov esi, r13d
    xor edx, edx
    cmp r12d, [r15 + DPG_SEL]
    jne .p
    mov edx, 1
.p:
    call dm_text
    inc r12d
    add r13d, DM_LINE
    jmp .row
.bar:                               ; scroll bar: track and thumb at the box's right edge
    cmp r14d, DM_VISIBLE
    jbe .extra
    mov edi, [dm_box_x2]
    lea edx, [rdi - 1]
    sub edi, 4
    mov esi, DM_Y + DM_LINE
    mov ecx, [rsp + 16]
    sub ecx, DM_PAD
    mov r8d, 0x60FFFFFF
    call dm_rect
    mov eax, [rsp + 16]             ; track height h = bottom - pad - top
    sub eax, DM_PAD + DM_Y + DM_LINE
    mov [rsp + 20], eax
    imul eax, [r15 + DPG_TOP]
    xor edx, edx
    div r14d
    lea esi, [rax + DM_Y + DM_LINE] ; thumb top = top + h * first / rows
    mov eax, [rsp + 20]
    imul eax, eax, DM_VISIBLE
    xor edx, edx
    div r14d
    lea ecx, [rsi + rax]            ; thumb bottom = + h * visible / rows
    mov edi, [dm_box_x2]
    lea edx, [rdi - 1]
    sub edi, 4
    mov r8d, 0xE0FFFFFF
    call dm_rect
.extra:
    mov rax, [r15 + DPG_DRAW]
    test rax, rax
    jz .toast
    mov rdi, r15
    call rax
.toast:
    cmp dword [dm_toast_left], 0
    je .out
    dec dword [dm_toast_left]
    mov rdi, [dm_toast]
    mov esi, 480 - 3 * DM_LINE
    mov edx, 1
    call dm_text
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dm_row_label(edi = row of the current page): its text into dm_buf
dm_row_label:
    push rbx
    push r12
    sub rsp, 8
    mov rcx, [dm_page]
    cmp edi, [dm_dyn_rows]
    jae .item
    mov byte [dm_buf], 0
    mov rax, [rcx + DPG_ROWFMT]
    test rax, rax
    jz .out
    lea rsi, [dm_buf]
    call rax
    jmp .out
.item:
    sub edi, [dm_dyn_rows]
    mov rax, [rcx + DPG_ITEMS]
    mov rbx, [rax + rdi*8]
    lea rdi, [dm_buf]
    mov rsi, [rbx + DI_LABEL]
    call _strcpy
    mov eax, [rbx + DI_KIND]
    cmp eax, DM_VALUE
    je .value
    cmp eax, DM_FLAG
    jne .out
    lea rdi, [dm_buf]
    lea rsi, [s_dm_on]
    lea rax, [s_dm_off]
    mov rcx, [rbx + DI_DATA]
    cmp byte [rcx], 0
    cmove rsi, rax
    call _strcat
    jmp .out
.value:
    lea rdi, [dm_buf]
    call _strlen
    lea rdi, [dm_buf]
    add rdi, rax
    mov rax, [rbx + DI_DATA]
    call [rax + 8]                  ; format(rdi = text end)
.out:
    add rsp, 8
    pop r12
    pop rbx
    ret

; dm_rect(edi = x1, esi = y1, edx = x2, ecx = y2 in 640x480 units, r8d = argb)
dm_rect:
    push rbx
    sub rsp, 32
    mov [rsp + 16], r8d
    mov ebx, ecx
    mov [rsp + 20], edx
    mov [rsp + 24], esi
    cvtsi2ss xmm1, dword [dm_scale]
    mulss xmm1, [f_dm_inv16384]
    cvtsi2ss xmm0, edi
    mulss xmm0, xmm1
    movss [rsp], xmm0
    cvtsi2ss xmm0, dword [rsp + 24]
    mulss xmm0, xmm1
    movss [rsp + 4], xmm0
    cvtsi2ss xmm0, dword [rsp + 20]
    mulss xmm0, xmm1
    movss [rsp + 8], xmm0
    cvtsi2ss xmm0, ebx
    mulss xmm0, xmm1
    movss [rsp + 12], xmm0
    mov edi, 0x474110
    mov rsi, rsp
    mov edx, 5
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    add rsp, 32
    pop rbx
    ret

; dm_text(rdi = ASCII string, esi = y in 640x480 units, edx = 1 highlighted) at DM_X
dm_text:
    mov ecx, edx
    mov edx, esi
    mov esi, DM_X
    ; fall through
; dm_text_at(rdi = ASCII string, esi = x, edx = y in 640x480 units, ecx = 1 highlighted).
; Each call gets its own low line buffer (UTF-16), in case the game keeps the pointer.
dm_text_at:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 56
    mov r14d, esi
    mov r12d, edx
    mov r13d, ecx
    mov eax, [dm_line_no]
    cmp eax, DM_LINES
    jae .out
    inc dword [dm_line_no]
    imul eax, eax, DM_WCHARS * 2
    mov rbx, [dm_low]
    add rbx, DM_LOWHDR
    add rbx, rax
    xor ecx, ecx
.w:
    movzx eax, byte [rdi + rcx]
    mov [rbx + rcx*2], ax
    test eax, eax
    jz .wd
    inc ecx
    cmp ecx, DM_WCHARS - 1
    jb .w
    mov word [rbx + rcx*2], 0
.wd:
    mov rax, [dm_low]
    mov dword [rax], 2              ; PALETTE_BASE_SPRITE
    mov dword [rax + 4], 8          ; PALETTE_BASE_FONT_REMAP
    mov [rsp], ebx                  ; str
    mov eax, r14d
    imul eax, [dm_scale]
    mov [rsp + 4], eax              ; x
    mov eax, r12d
    imul eax, [dm_scale]
    mov [rsp + 8], eax              ; y
    movzx eax, word [abs FONT_ID]
    mov [rsp + 12], eax             ; font
    mov eax, [dm_scale]
    imul eax, eax, DM_TEXT_SCALE
    sar eax, 14
    mov [rsp + 16], eax             ; scale
    mov rax, [dm_low]
    mov [rsp + 20], eax             ; &PALETTE_BASE_SPRITE
    mov dword [rsp + 24], 0         ; remap
    test r13d, r13d
    jz .plain
    add dword [rsp + 20], 4         ; highlighted: font remap
    mov eax, [dm_hl_remap]
    mov [rsp + 24], eax
.plain:
    mov dword [rsp + 28], 0         ; SPRITE_INVISIBILITY_VISIBLE
    mov dword [rsp + 32], 1
    mov edi, 0x4CC100
    lea rsi, [rsp]
    mov edx, 9
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
.out:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dm_pane(esi = y1, ecx = y2, edx = width): the preview pane box right of the list box;
; its content starts at x = [dm_pane_x]
dm_pane:
    mov edi, [dm_pane_x]
    add edx, edi
    sub edi, DM_PAD
    sub esi, DM_PAD
    mov r8d, 0x80000000
    jmp dm_rect

; eax = dm_text_w(rdi = ASCII string): its width in 640x480 units at the menu's text size.
; GetGTATextWidth @0x4CB0C0, stdcall(wchar_t* text, short font) -> glyph pixels at scale
; 1.0 (re/functions.csv + its Ghidra comment; own decompile)
dm_text_w:
    push rbx
    sub rsp, 16
    xor eax, eax
    mov rbx, [dm_low]
    test rbx, rbx
    jz .out
    xor ecx, ecx
.w:
    movzx eax, byte [rdi + rcx]
    mov [rbx + DM_MEASURE + rcx*2], ax
    test eax, eax
    jz .call
    inc ecx
    cmp ecx, DM_WCHARS - 1
    jb .w
    mov word [rbx + DM_MEASURE + rcx*2], 0
.call:
    lea eax, [rbx + DM_MEASURE]
    mov [rsp], eax
    movzx eax, word [abs FONT_ID]
    mov [rsp + 4], eax
    mov edi, 0x4CB0C0
    mov rsi, rsp
    mov edx, 2
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    imul eax, eax, DM_TEXT_SCALE
    shr eax, 14
.out:
    add rsp, 16
    pop rbx
    ret

; DMSPRITE, the argument block of dm_sprite (dwords)
DS_TYPE   equ 0                     ; SPRITE_TYPE: 2 car, 3 ped, 4 code obj, 5 map obj, 6 user, 7 font
DS_ID     equ 4                     ; relative to the type's sprite base (CarInfo.spriteIndex for cars)
DS_PAL    equ 8                     ; palette kind: 2 none, 3 car, 4 ped, 5 code obj, 6 map obj, 7 user, 8 font remap
DS_REMAP  equ 12                    ; index within that palette base
DS_X      equ 16                    ; centre, 640x480 units
DS_Y      equ 20
DS_BOX    equ 24                    ; fit the sprite's diagonal into this many units (0: use DS_SCALE)
DS_SCALE  equ 28                    ; percent of the HUD's 1:1 size, when DS_BOX = 0
DS_ROT    equ 32                    ; 1440 units per turn (Sprite.rotation)
DS_SIZE   equ 36

; dm_sprite(rdi = DMSPRITE*): any style sprite with any remap, scaled and rotated, through
; the game's DrawSprite2D @0x4CBA50, stdcall(SPRITE_TYPE type, id, SCR_f x, y, Ang16 rot,
; SCR_f scale, int* paletteKind, int remap, a9, a10, byte a11), ret 0x2C: x, y = centre in
; screen pixels, quad = w, h * scale / 2. The HUD's wrapper Hud_DrawSprite2DScaled
; @0x4C71B0 passes scale = uiScale (1:1 in 640x480 units) and a11 = 0, as we do. Own
; disassembly, confirmed by Seq 27 (seq49-car-sprite-remap.md). w, h from the style's
; sprite entries (StyleData +0x14 spriteBases[type - 2] + id, +0x20 entries: w +4, h +5;
; GetSpriteIndex @0x4BF2A0). eax = 0 when there is no such sprite.
dm_sprite:
    push rbx
    sub rsp, 48
    mov rbx, rdi
    xor eax, eax
    mov edx, [abs STYLE_DATA]
    test edx, edx
    jz .out
    mov ecx, [rbx + DS_TYPE]
    sub ecx, 2
    cmp ecx, 5
    ja .out
    mov r8d, [rdx + 0x14]           ; spriteBases
    test r8d, r8d
    jz .out
    movzx r8d, word [r8 + rcx*2]
    add r8d, [rbx + DS_ID]
    movzx ecx, word [rdx + 4]       ; spriteCount
    cmp r8d, ecx
    jae .out
    mov edx, [rdx + 0x20]           ; sprite entries
    test edx, edx
    jz .out
    movzx eax, byte [rdx + r8*8 + 4] ; w
    movzx ecx, byte [rdx + r8*8 + 5] ; h
    cmp dword [rbx + DS_BOX], 0
    jne .fit
    mov eax, [rbx + DS_SCALE]       ; k = percent * 16384 / 100
    shl eax, 14
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r9d, eax
    jmp .k
.fit:
    imul eax, eax                   ; k = box * 16384 / sqrt(w^2 + h^2)
    imul ecx, ecx
    add eax, ecx
    jz .out
    cvtsi2sd xmm0, eax
    sqrtsd xmm0, xmm0
    mov eax, [rbx + DS_BOX]
    shl eax, 14
    cvtsi2sd xmm1, eax
    divsd xmm1, xmm0
    cvttsd2si r9d, xmm1
.k:
    mov eax, [rbx + DS_TYPE]
    mov [rsp], eax
    mov eax, [rbx + DS_ID]
    mov [rsp + 4], eax
    mov eax, [rbx + DS_X]
    imul eax, [dm_scale]
    mov [rsp + 8], eax
    mov eax, [rbx + DS_Y]
    imul eax, [dm_scale]
    mov [rsp + 12], eax
    mov eax, [rbx + DS_ROT]
    mov [rsp + 16], eax
    mov eax, [dm_scale]             ; scale = uiScale * k
    imul eax, r9d
    sar eax, 14
    mov [rsp + 20], eax
    mov rax, [dm_low]
    mov ecx, [rbx + DS_PAL]
    mov [rax + 8], ecx
    add eax, 8
    mov [rsp + 24], eax             ; int* paletteKind (low memory)
    mov eax, [rbx + DS_REMAP]
    mov [rsp + 28], eax
    mov dword [rsp + 32], 0
    mov dword [rsp + 36], 0
    mov dword [rsp + 40], 0
    mov edi, 0x4CBA50
    mov rsi, rsp
    mov edx, 11
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
    mov eax, 1
.out:
    add rsp, 48
    pop rbx
    ret

; eax = dm_sprite_wh(edi = SPRITE_TYPE, esi = id): w | h << 8 of a style sprite, 0 if none
dm_sprite_wh:
    xor eax, eax
    mov edx, [abs STYLE_DATA]
    test edx, edx
    jz .out
    lea ecx, [rdi - 2]
    cmp ecx, 5
    ja .out
    mov r8d, [rdx + 0x14]
    test r8d, r8d
    jz .out
    movzx r8d, word [r8 + rcx*2]
    add r8d, esi
    movzx ecx, word [rdx + 4]
    cmp r8d, ecx
    jae .out
    mov edx, [rdx + 0x20]
    test edx, edx
    jz .out
    movzx eax, word [rdx + r8*8 + 4]
.out:
    ret

; eax = dm_car_info(edi = model): the style's CarInfo* for that model, or 0 when this
; level's style has no such car (g_StyleData +0x5c AllCarsInfo.cars[256]; GetCarInfoById
; @0x4BF1F0, re/functions.csv; CarInfo: +1 spriteIndex, +2 w, +3 h, +4 num_remaps,
; +5 passengers, +7 rating, +0xe remap[num_remaps], re/gta2_types.h)
dm_car_info:
    xor eax, eax
    cmp edi, 255
    ja .out
    mov edx, [abs STYLE_DATA]
    test edx, edx
    jz .out
    mov edx, [rdx + 0x5c]
    test edx, edx
    jz .out
    mov eax, [rdx + rdi*4]
.out:
    ret

; eax = dm_gxt(rdi = ASCII key, rsi = out, edx = out size): the game's text for the key
; as ASCII (others become '?'), eax = its length. Gxt_FindTextW @0x4C2120,
; thiscall(LocaleSettings* = [0x671550], char* key) -> wchar_t* (re/functions.csv; used
; the same way by GetCarModelName @0x41F700 with "car%d")
dm_gxt:
    push rbx
    push r12
    push r13
    sub rsp, 16
    mov r12, rsi
    mov r13d, edx
    mov byte [rsi], 0
    xor eax, eax
    mov r8d, [abs LOCALE]
    test r8d, r8d
    jz .out
    mov rbx, [dm_low]
    test rbx, rbx
    jz .out
    xor ecx, ecx
.k:
    mov al, [rdi + rcx]
    mov [rbx + 16 + rcx], al
    test al, al
    jz .call
    inc ecx
    cmp ecx, 15
    jb .k
    mov byte [rbx + 16 + rcx], 0
.call:
    lea eax, [rbx + 16]
    mov [rsp], eax
    mov edi, 0x4C2120
    mov rsi, rsp
    mov edx, 1
    xor ecx, ecx
    xor r9d, r9d
    call call32
    mov edx, eax
    xor eax, eax
    test edx, edx
    jz .out
    dec r13d
.c:
    cmp eax, r13d
    jae .end
    movzx ecx, word [rdx + rax*2]
    test ecx, ecx
    jz .end
    cmp ecx, 0x80
    jb .put
    mov ecx, '?'
.put:
    mov [r12 + rax], cl
    inc eax
    jmp .c
.end:
    mov byte [r12 + rax], 0
.out:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; ---- the root page: actions on the player and the camera zoom
section .data
    DM_PAGE  dmp_root, 0, 0, "Debug menu  (K)"
    DM_ITEM  dmp_root, 10, DM_ACTION, "Quick save", dm_quick_save
    DM_ITEM  dmp_root, 20, DM_ACTION, "Get all weapons", dm_all_weapons
    DM_ITEM  dmp_root, 30, DM_ACTION, "Add $100000", dm_add_money
    DM_ITEM  dmp_root, 40, DM_VALUE,  "Camera zoom: ", dmv_zoom
    DMVALUE zoom
    DM_FRAME 0, dm_track_car
    DM_FRAME -100, dm_pause_sync
section .text

; dm_pause_sync (DM_FRAME, first): the game pauses while the menu is open. Open: a running
; game (Game +0 gameStatus 1) that allows pausing (+0x23 = 1, ToggleGamePause @0x45BAA0's
; own test) goes to 2 (GAME_PAUSED): Game_StepByStatus then only runs Game_TickPaused
; (cameras), while DrawUI, and so this hook and the menu, still run. Closed: UnpauseGame
; @0x45BA60 thiscall(Game*) puts 1 back, flushes DirectInput and clears the player's input.
; A pause the player made on their own is left alone. hk_PauseOverlay hides the game's "pause"
; screen meanwhile. Names and fields: re/functions.csv, re/gta2_types.h; own decompile.
dm_pause_sync:
    sub rsp, 8
    mov eax, [abs GAME]
    test eax, eax
    jz .out
    cmp byte [dm_open], 0
    je .closed
    cmp byte [dm_paused], 0
    jne .out
    cmp dword [rax], 1
    jne .out
    cmp byte [rax + 0x23], 1
    jne .out
    mov dword [rax], 2
    mov byte [dm_paused], 1
    lea rdi, [fmt_dm_paused]
    mov esi, [r_frames]
    xor eax, eax
    call _printf
    jmp .out
.closed:
    cmp byte [dm_paused], 0
    je .out
    mov byte [dm_paused], 0
    cmp dword [rax], 2
    jne .out
    mov r8d, eax
    mov edi, 0x45BA60
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r9d, r9d
    call call32
    lea rdi, [fmt_dm_resumed]
    mov esi, [r_frames]
    mov eax, [abs GAME]
    mov edx, [rax]
    xor eax, eax
    call _printf
.out:
    add rsp, 8
    ret

; Hud_PauseOverlay_Draw @0x4C9FA0, stdcall(void), called by DrawUI at 0x4CA4F9 while the
; game is paused (re/comments.csv): skipped while the pause is ours
hk_PauseOverlay:
    HENTER
    cmp byte [dm_paused], 0
    jne .out
    mov edi, 0x4C9FA0
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call call32
.out:
    HRET

; camera zoom: LEFT / RIGHT 5% steps, RETURN back to the game's own (100%)
dm_zoom_change:
    mov eax, [cam_zoom_pct]
    test eax, eax
    jnz .z
    mov eax, 100
.z:
    test esi, esi
    jnz .zstep
    mov eax, 100                    ; RETURN: back to the game's own zoom
    jmp .zset
.zstep:
    imul esi, esi, 5
    add eax, esi
    cmp eax, ZOOM_MIN
    jge .zmin
    mov eax, ZOOM_MIN
.zmin:
    cmp eax, ZOOM_MAX
    jle .zset
    mov eax, ZOOM_MAX
.zset:
    mov [cam_zoom_pct], eax
    ret

dm_zoom_fmt:
    mov ecx, [cam_zoom_pct]
    test ecx, ecx
    jnz .p
    mov ecx, 100
.p:
    mov esi, 32
    lea rdx, [fmt_dm_zoom]
    xor eax, eax
    jmp _snprintf

; dm_quick_save: save the game where the player stands (seuko-mod
; src/modules/modmenu/utils/save-game.cpp): refused during a mission; SaveGame
; @0x47EF40 thiscall(S15_Script* = [0x6644BC]; char* file = Menu 0x5EC070 +0x300),
; ret 4. The player's position.y (Ped +0x1ac +4) is moved 1.0 back around the call as
; seuko does. Game* 0x5EB4FC +0x38 = current Player, Player +0x2c4 = Ped,
; S15 +0x344 = mission flag pointer.
; From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/modules/modmenu/utils/save-game.cpp @25b1985 — SaveGame 0x47EF40.
dm_quick_save:
    push rbx
    push r12
    push r13
    sub rsp, 16
    lea r13, [s_dm_noplayer]
    mov eax, [abs 0x5EB4FC]
    test eax, eax
    jz .toast
    mov eax, [rax + 0x38]
    test eax, eax
    jz .toast
    mov ebx, [rax + 0x2c4]          ; Ped*
    test ebx, ebx
    jz .toast
    lea r13, [s_dm_nosave]
    mov r12d, [abs 0x6644BC]        ; S15_Script*
    test r12d, r12d
    jz .toast
    mov eax, [r12 + 0x344]
    test eax, eax
    jz .toast
    lea r13, [s_dm_mission]
    cmp byte [rax], 0
    jne .toast
    sub dword [rbx + 0x1b0], 0x4000
    mov dword [rsp], 0x5EC070 + 0x300
    mov edi, 0x47EF40
    mov rsi, rsp
    mov edx, 1
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    add dword [rbx + 0x1b0], 0x4000
    lea r13, [s_dm_saved]
    lea rdi, [fmt_dm_saved]
    mov esi, 0x5EC070 + 0x300
    xor eax, eax
    call _printf
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; eax = dm_player_ped(): the player's Ped* (Game* 0x5EB4FC +0x38 = Player, +0x2c4), or 0;
; ecx = the Player*
dm_player_ped:
    xor eax, eax
    xor ecx, ecx
    mov edx, [abs 0x5EB4FC]
    test edx, edx
    jz .out
    mov ecx, [rdx + 0x38]
    test ecx, ecx
    jz .out
    mov eax, [rcx + 0x2c4]
.out:
    ret

; dm_all_weapons: AddWeapon @0x43E4B0, fastcall(Ped* ecx, edx = 0; weapon, ammo), ret 8,
; for weapons 0..14 with 99 ammo (seuko-mod src/modules/modmenu/utils/get-all-weapons.cpp)
; From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/game/functions.h, get-all-weapons.cpp @25b1985 — AddWeapon 0x43E4B0.
dm_all_weapons:
    push rbx
    push r12
    push r13
    sub rsp, 16
    lea r13, [s_dm_noplayer2]
    call dm_player_ped
    test eax, eax
    jz .toast
    mov r12d, eax
    xor ebx, ebx
.w:
    mov [rsp], ebx
    mov dword [rsp + 4], 99
    mov edi, 0x43E4B0
    mov rsi, rsp
    mov edx, 2
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    inc ebx
    cmp ebx, 15
    jb .w
    lea r13, [s_dm_weapons]
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; dm_add_money: Player +0x2d4 = animatedMoney (SaveSlotAnimatedValue: value +0, max +0x30;
; seuko-mod src/modules/modmenu/menus/player-stats-menu.cpp), += DM_MONEY up to max
; From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/modules/modmenu/menus/player-stats-menu.cpp @25b1985 — Player +0x2d4.
DM_MONEY equ 100000
dm_add_money:
    lea rax, [s_dm_noplayer2]
    call dm_player_ped
    test ecx, ecx
    jz .toast
    mov eax, [rcx + 0x2d4]
    add eax, DM_MONEY
    mov edx, [rcx + 0x2d4 + 0x30]
    test edx, edx
    jle .set                        ; no max set
    cmp eax, edx
    jbe .set
    mov eax, edx
.set:
    mov [rcx + 0x2d4], eax
    lea rax, [s_dm_money]
.toast:
    mov [dm_toast], rax
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    ret

; ---- Player page. Ped fields (gta2-seuko-mod src/game/gta2.h @25b1985): copValue +0x20a

; ---- shared Ped / Car helpers (used by the pages in menu/ and by the feature modules).
; Ped fields (gta2-seuko-mod src/game/gta2.h @25b1985): copValue +0x20a, remap +0x244,
; graphicType +0x26c, currentCar +0x16c, GameObject +0x168 (sprite at +0x80).
PED_COPVALUE equ 0x20a
PED_REMAP    equ 0x244
PED_GTYPE    equ 0x26c
PED_CAR      equ 0x16c
PED_GAMEOBJ  equ 0x168              ; GameObject*, sprite at +0x80

; Car fields (seuko-mod src/game/gta2.h): deltasBitstate +0x8 (bits 0-4 broken lights and
; windscreen), lastCar +0x4c, sprite +0x50 (the body, a Sprite: rotation +0
; ushort, position +0x14, remap +0x24, paletteBase +0x34), id +0x6c, carDamage +0x74,
; physicsBitmask +0x78, carModel +0x84, fireState +0x8c, engineState +0x9c (3 = on),
; lightsBitstate +0xa4 (1 brake lights, 2 lights).
CAR_DELTAS   equ 0x8
CAR_SPRITE   equ 0x50
CAR_ID       equ 0x6c
CAR_DAMAGE   equ 0x74
CAR_PHYSICS  equ 0x78
CAR_MODEL    equ 0x84
CAR_FIRE     equ 0x8c
CAR_ENGINE   equ 0x9c
CAR_LIGHTS   equ 0xa4
CAR_INVINCIBLE equ 0x708            ; NO_COLLISION_DAMAGE | BULLET-, ROCKET-, FLAMEPROOF

; dm_track_car (DM_FRAME): remember the car the player is in, for "the last car"
dm_track_car:
    call dm_player_ped
    test eax, eax
    jz .out
    mov edx, [rax + PED_CAR]
    test edx, edx
    jz .out
    mov [dm_last_car], edx
    mov ecx, [rdx + CAR_ID]
    mov [dm_last_car_id], ecx
.out:
    ret

; eax = dm_car(): the car the player is in, else the last one while its id still matches
; (cars live in a fixed array, so a destroyed car's slot is reused with a new id), or 0;
; edx = 1 when the player is in it
dm_car:
    call dm_player_ped
    test eax, eax
    jz .last
    mov eax, [rax + PED_CAR]
    test eax, eax
    jz .last
    mov edx, 1
    ret
.last:
    xor edx, edx
    mov eax, [dm_last_car]
    test eax, eax
    jz .out
    mov ecx, [rax + CAR_ID]
    cmp ecx, [dm_last_car_id]
    jne .gone
    cmp dword [rax + CAR_SPRITE], 0
    jne .out
.gone:
    xor eax, eax
    mov [dm_last_car], eax
.out:
    ret

; dm_call_car(edi = fastcall function taking only ecx = car, esi = car)
dm_call_car:
    sub rsp, 8
    mov r8d, esi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r9d, r9d
    call call32
    add rsp, 8
    ret

; dm_spawn_car: SpawnCar @0x426AC0, fastcall(TrafficManager* ecx = [0x5E4CA4], edx = 0;
; SCR_f x, y, z, int rotation, CAR_MODEL4 model, int scale = [0x5E4D4C]) -> Car*, at
; DM_SPAWN_DIST in front of the player, facing the same way (the player's sprite:
; Ped +0x168 GameObject, +0x80 Sprite); the model is dm_spawnable[dm_model]. Refused in
; a car. eax = the Car*, or 0.
; From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
; src/game/functions.h, memory.h, src/modules/modmenu/utils/spawn-car.cpp @25b1985 —
; SpawnCar 0x426AC0, TrafficManager 0x5E4CA4, CarsScale 0x5E4D4C.
DM_SPAWN_DIST equ 0x6000            ; 1.5 blocks
dm_spawn_car:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov dword [dm_spawned], 0
    lea r13, [s_dm_noplayer2]
    call dm_player_ped
    test eax, eax
    jz .toast
    lea r13, [s_dm_incar]
    cmp dword [rax + PED_CAR], 0
    jne .toast
    lea r13, [s_dm_nospawn]
    mov eax, [rax + PED_GAMEOBJ]
    test eax, eax
    jz .toast
    mov ebx, [rax + 0x80]           ; Sprite*
    test ebx, ebx
    jz .toast
    mov r12d, [abs 0x5E4CA4]        ; TrafficManager*
    test r12d, r12d
    jz .toast
    ; offset = DM_SPAWN_DIST * (sx * sin a, sy * cos a), a = rotation * 2pi / 1440
    movzx eax, word [rbx]
    mov [rsp + 24], eax
    fild dword [rsp + 24]
    fmul qword [f_dm_rot2rad]
    fsincos                         ; st0 = cos, st1 = sin
    fimul dword [i_dm_spawn_dist]
    fistp dword [rsp + 24]          ; cos * d
    fimul dword [i_dm_spawn_dist]
    fistp dword [rsp + 28]          ; sin * d
    mov eax, [rbx + 0x14]
    mov ecx, [rbx + 0x18]
    mov edx, [dm_spawn_sx]
    imul edx, [rsp + 28]
    add eax, edx
    mov edx, [dm_spawn_sy]
    imul edx, [rsp + 24]
    add ecx, edx
    mov [rsp], eax                  ; x
    mov [rsp + 4], ecx              ; y
    mov eax, [rbx + 0x1c]
    mov [rsp + 8], eax              ; z
    movzx eax, word [rbx]
    mov [rsp + 12], eax             ; rotation
    mov eax, [dm_model]
    lea rcx, [dm_spawnable]
    movzx eax, byte [rcx + rax]
    mov [rsp + 16], eax             ; model
    mov eax, [abs 0x5E4D4C]
    mov [rsp + 20], eax             ; scale
    mov edi, 0x426AC0
    mov rsi, rsp
    mov edx, 6
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    test eax, eax
    jz .toast
    mov [dm_spawned], eax
    mov [dm_last_car], eax
    mov ecx, [rax + CAR_ID]
    mov [dm_last_car_id], ecx
    lea rdi, [fmt_dm_spawned]
    mov esi, [rsp + 16]
    mov edx, [rbx + 0x14]
    mov ecx, [rbx + 0x18]
    movzx r8d, word [rbx]
    mov r9d, [rsp]
    mov eax, [rsp + 4]
    mov [rsp + 24], eax
    xor eax, eax
    sub rsp, 8
    push qword [rsp + 32]
    call _printf
    add rsp, 16
    lea r13, [s_dm_spawned]
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
    mov eax, [dm_spawned]
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

section .data
align 8
dm_page: dq 0                       ; the current page (dmp_root once built)
; Back / Close, appended to every page by dm_build (not in the linker set)
dmi_back:  dq 0
    dd 0x7FFFFFFF, DM_BACK
    dq s_dm_back, 0
dmi_close: dq 0
    dd 0x7FFFFFFF, DM_CLOSE
    dq s_dm_close, 0
dm_spawn_sx:   dd 1                 ; front = (sin, cos) of Sprite.rotation (user-checked in play)
dm_spawn_sy:   dd 1
i_dm_spawn_dist: dd DM_SPAWN_DIST
align 8
f_dm_rot2rad:  dq 0x3F71DF46A2529D39 ; 2*pi / 1440 (Sprite.rotation units)
align 8
; CAR_MODEL4 names by id (seuko-mod src/game/gta2.h)
dm_car_names:
    dq s_dm_car0
    dq s_dm_car1
    dq s_dm_car2
    dq s_dm_car3
    dq s_dm_car4
    dq s_dm_car5
    dq s_dm_car6
    dq s_dm_car7
    dq s_dm_car8
    dq s_dm_car9
    dq s_dm_car10
    dq s_dm_car11
    dq s_dm_car12
    dq s_dm_car13
    dq s_dm_car14
    dq s_dm_car15
    dq s_dm_car16
    dq s_dm_car17
    dq s_dm_car18
    dq s_dm_car19
    dq s_dm_car20
    dq s_dm_car21
    dq s_dm_car22
    dq s_dm_car23
    dq s_dm_car24
    dq s_dm_car25
    dq s_dm_car26
    dq s_dm_car27
    dq s_dm_car28
    dq s_dm_car29
    dq s_dm_car30
    dq s_dm_car31
    dq s_dm_car32
    dq s_dm_car33
    dq s_dm_car34
    dq s_dm_car35
    dq s_dm_car36
    dq s_dm_car37
    dq s_dm_car38
    dq s_dm_car39
    dq s_dm_car40
    dq s_dm_car41
    dq s_dm_car42
    dq s_dm_car43
    dq s_dm_car44
    dq s_dm_car45
    dq s_dm_car46
    dq s_dm_car47
    dq s_dm_car48
    dq s_dm_car49
    dq s_dm_car50
    dq s_dm_car51
    dq s_dm_car52
    dq s_dm_car53
    dq s_dm_car54
    dq s_dm_car55
    dq s_dm_car56
    dq s_dm_car57
    dq s_dm_car58
    dq s_dm_car59
    dq s_dm_car60
    dq s_dm_car61
    dq s_dm_car62
    dq s_dm_car63
    dq s_dm_car64
    dq s_dm_car65
    dq s_dm_car66
    dq s_dm_car67
    dq s_dm_car68
    dq s_dm_car69
    dq s_dm_car70
    dq s_dm_car71
    dq s_dm_car72
    dq s_dm_car73
    dq s_dm_car74
    dq s_dm_car75
    dq s_dm_car76
    dq s_dm_car77
    dq s_dm_car78
    dq s_dm_car79
    dq s_dm_car80
    dq s_dm_car81
    dq s_dm_car82
    dq s_dm_car83
    dq s_dm_car84
    dq s_dm_car85
    dq s_dm_car86
DM_NCARNAMES equ ($ - dm_car_names) / 8
; models SpawnCar accepts (seuko-mod src/game/utils/lists-utils.cpp)
dm_spawnable:
    db 0, 1, 2, 3, 4, 5, 7, 8, 10, 11, 12, 13, 14, 84, 16, 17
    db 18, 19, 21, 22, 23, 24, 25, 26, 85, 27, 28, 29, 30, 31, 86, 32
    db 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 45, 46, 47, 48, 49
    db 50, 51, 52, 53, 54, 55, 56, 57, 58, 62, 63, 64, 65, 66, 67, 68
    db 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83
DM_NSPAWNABLE equ $ - dm_spawnable

section .rodata
s_dm_car0: db "ALFA", 0
s_dm_car1: db "ALLARD", 0
s_dm_car2: db "AMDB4", 0
s_dm_car3: db "APC", 0
s_dm_car4: db "BANKVAN", 0
s_dm_car5: db "BMW", 0
s_dm_car6: db "BOXCAR", 0
s_dm_car7: db "BOXTRUCK", 0
s_dm_car8: db "BUG", 0
s_dm_car9: db "CAR9", 0
s_dm_car10: db "BUICK", 0
s_dm_car11: db "BUS", 0
s_dm_car12: db "COPCAR", 0
s_dm_car13: db "DART", 0
s_dm_car14: db "EDSEL", 0
s_dm_car15: db "CAR15", 0
s_dm_car16: db "FIAT", 0
s_dm_car17: db "FIRETRUCK", 0
s_dm_car18: db "GRAHAM", 0
s_dm_car19: db "GT24640", 0
s_dm_car20: db "CAR20", 0
s_dm_car21: db "GTRUCK", 0
s_dm_car22: db "GUNJEEP", 0
s_dm_car23: db "HOTDOG", 0
s_dm_car24: db "HOTDOG_D1", 0
s_dm_car25: db "HOTDOG_D2", 0
s_dm_car26: db "HOTDOG_D3", 0
s_dm_car27: db "ICECREAM", 0
s_dm_car28: db "ISETLIMO", 0
s_dm_car29: db "ISETTA", 0
s_dm_car30: db "JEEP", 0
s_dm_car31: db "JEFFREY", 0
s_dm_car32: db "LIMO", 0
s_dm_car33: db "LIMO2", 0
s_dm_car34: db "MEDICAR", 0
s_dm_car35: db "MERC", 0
s_dm_car36: db "MESSER", 0
s_dm_car37: db "MIURA", 0
s_dm_car38: db "MONSTER", 0
s_dm_car39: db "MORGAN", 0
s_dm_car40: db "MORRIS", 0
s_dm_car41: db "PICKUP", 0
s_dm_car42: db "RTYPE", 0
s_dm_car43: db "CAR43", 0
s_dm_car44: db "SPIDER", 0
s_dm_car45: db "SPRITE", 0
s_dm_car46: db "STINGRAY", 0
s_dm_car47: db "STRATOS", 0
s_dm_car48: db "STRATOSB", 0
s_dm_car49: db "STRIPETB", 0
s_dm_car50: db "STYPE", 0
s_dm_car51: db "STYPECAB", 0
s_dm_car52: db "SWATVAN", 0
s_dm_car53: db "T2000GT", 0
s_dm_car54: db "TANK", 0
s_dm_car55: db "TANKER", 0
s_dm_car56: db "TAXI", 0
s_dm_car57: db "TBIRD", 0
s_dm_car58: db "TOWTRUCK", 0
s_dm_car59: db "TRAIN", 0
s_dm_car60: db "TRAINCAB", 0
s_dm_car61: db "TRAINFB", 0
s_dm_car62: db "TRANCEAM", 0
s_dm_car63: db "TRUKCAB1", 0
s_dm_car64: db "TRUKCAB2", 0
s_dm_car65: db "TRUKCONT", 0
s_dm_car66: db "TRUKTRNS", 0
s_dm_car67: db "TVVAN", 0
s_dm_car68: db "VAN", 0
s_dm_car69: db "VESPA", 0
s_dm_car70: db "VTYPE", 0
s_dm_car71: db "WBTWIN", 0
s_dm_car72: db "WRECK0", 0
s_dm_car73: db "WRECK1", 0
s_dm_car74: db "WRECK2", 0
s_dm_car75: db "WRECK3", 0
s_dm_car76: db "WRECK4", 0
s_dm_car77: db "WRECK5", 0
s_dm_car78: db "WRECK6", 0
s_dm_car79: db "WRECK7", 0
s_dm_car80: db "WRECK8", 0
s_dm_car81: db "WRECK9", 0
s_dm_car82: db "XK120", 0
s_dm_car83: db "ZCX5", 0
s_dm_car84: db "EDSELFBI", 0
s_dm_car85: db "HOTDOG_D4", 0
s_dm_car86: db "KRSNABUS", 0
section .data
dm_hl_remap: dd 2                   ; font remap of the selected line: green (measured)
f_dm_inv16384: dd 0x38800000        ; 1/16384

section .rodata
s_dm_on:       db "on", 0
s_dm_off:      db "off", 0
s_dm_back:     db "Back", 0
s_dm_close:    db "Close", 0
fmt_dm_zoom:   db "%d%%", 0
s_dm_saved:    db "Game saved", 0
s_dm_mission:  db "Cannot save during a mission", 0
s_dm_noplayer: db "Cannot save: no player", 0
s_dm_nosave:   db "Cannot save here", 0
s_dm_noplayer2: db "No player", 0
s_dm_weapons:  db "Got all weapons", 0
s_dm_money:    db "Got $100000", 0     ; the font has no "+"
fmt_dm_int:    db "%d", 0
s_dm_dash:     db "-", 0
s_dm_default:  db "default", 0
s_dm_nocar:    db "No car", 0
s_dm_incar:    db "Get out of the car first", 0
s_dm_nospawn:  db "Cannot spawn here", 0
s_dm_spawned:  db "Car spawned", 0
fmt_dm_spawned: db "menu: spawned car model %d; player at %d,%d rot %d -> car at %d,%d", 10, 0
fmt_dm_saved:  db "menu: quick save -> %s", 10, 0
fmt_dm_paused: db "menu: frame %d, game paused", 10, 0
fmt_dm_resumed: db "menu: frame %d, game resumed (gameStatus %d)", 10, 0

section .bss
dm_open:       resb 1
dm_paused:     resb 1               ; the game is paused by us (dm_pause_sync)
dm_ui_seen:    resb 1
dm_built:      resb 1
alignb 8
dm_low:        resq 1               ; low memory: palette kinds, GXT key, line buffers
dm_toast:      resq 1
dm_defer_q:    resq DM_DEFER_MAX
dm_defer_n:    resd 1
dm_ui_frame:   resd 1
dm_scale:      resd 1
dm_line_no:    resd 1
dm_toast_left: resd 1
dm_dyn_rows:   resd 1
dm_box_x2:     resd 1               ; the list box's right edge, this frame
dm_pane_x:     resd 1               ; where a page's preview pane content starts
dm_model:      resd 1               ; index into dm_spawnable: the model dm_spawn_car makes
dm_spawned:    resd 1
dm_last_car:   resd 1
dm_last_car_id: resd 1
dm_buf:        resb 128
section .text
