; w32_vfs.asm — the game's files: read-only data.pak + a writable overlay directory.
;
; data.pak is a plain zip of the old gta2/ folder with every entry Stored (method 0,
; tools/mkpak.sh), so a file is one contiguous byte range: no decompression code. At
; startup the End of Central Directory and the central directory are read once into a
; table name -> (data offset, size); the data offset comes from each LOCAL header
; (offset + 30 + name len + extra len). Anything that is not a Stored, unencrypted,
; non-zip64 entry stops the loader with an error.
;
; The overlay (~/Library/Application Support/gta2-resurrected/) is the host's current
; directory, so win_path resolves game paths against it. Lookup order: overlay file,
; then pak entry (case-insensitive, '/' separators, as win_path produced it). Every
; write goes to the overlay; a pak-only file opened for writing is copied out first.

PAK_ENT_SIZE equ 24                 ; {name* 0, data offset 8, u32 size 16, u32 flags 20}
PAK_DIR      equ 1                  ; flags: directory entry ("name/", stored stripped)
EOCD_MAX     equ 65557              ; 22-byte EOCD + the longest zip comment
VFS_REFUSED  equ -3                 ; vfs_resolve: path outside C:\GTA2
VFS_NONE     equ -2                 ;   neither overlay nor pak (path_out: where to create)
VFS_OVERLAY  equ -1                 ;   overlay file/dir (path_out, stat_buf filled)

extern _strndup, _mkdir, _fmemopen

section .text

; vfs_open_pak(rdi = path to data.pak): open and index it; exits 1 on any problem.
vfs_open_pak:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                     ; local file header (30 bytes)
    mov [pak_path], rdi
    xor esi, esi                    ; O_RDONLY
    xor eax, eax
    call _open
    test eax, eax
    js .no_open
    mov [pak_fd], eax
    mov edi, eax
    xor esi, esi
    mov edx, SEEK_END
    call _lseek
    mov r12, rax                    ; file size
    mov [pak_fd_size], rax
    mov r13, rax                    ; tail = min(size, EOCD_MAX)
    cmp r13, EOCD_MAX
    jbe .tail
    mov r13d, EOCD_MAX
.tail:
    cmp r13, 22
    jb .bad_zip
    mov rdi, r13
    call _malloc
    mov r14, rax
    mov edi, [pak_fd]
    mov rsi, r14
    mov rdx, r13
    mov rcx, r12
    sub rcx, r13
    call _pread
    cmp rax, r13
    jne .bad_zip
    lea rcx, [r13 - 22]             ; EOCD: last "PK\5\6" in the tail
.eocd:
    cmp dword [r14 + rcx], 0x06054B50
    je .eocd_found
    dec rcx
    jns .eocd
    jmp .bad_zip
.eocd_found:
    movzx eax, word [r14 + rcx + 10]
    mov [pak_count], eax
    mov r15d, [r14 + rcx + 12]      ; central directory size
    mov ebx, [r14 + rcx + 16]       ; and offset
    mov rdi, r14
    call _free
    lea rax, [rbx + r15]
    cmp rax, r12
    ja .bad_zip
    mov rdi, r15
    call _malloc
    mov r14, rax
    mov edi, [pak_fd]
    mov rsi, r14
    mov rdx, r15
    mov rcx, rbx
    call _pread
    cmp rax, r15
    jne .bad_zip
    add r15, r14                    ; r15 = end of the central directory
    imul edi, [pak_count], PAK_ENT_SIZE
    add edi, PAK_ENT_SIZE
    call _malloc
    mov [pak_ents], rax
    mov rbx, rax                    ; rbx = table entry
    mov r12, r14                    ; r12 = central directory record
    xor r13d, r13d                  ; r13 = index
.entry:
    cmp r13d, [pak_count]
    jae .indexed
    lea rax, [r12 + 46]
    cmp rax, r15
    ja .bad_zip
    cmp dword [r12], 0x02014B50
    jne .bad_zip
    lea rdi, [r12 + 46]
    movzx esi, word [r12 + 28]
    call _strndup
    mov [rbx], rax
    test word [r12 + 8], 1          ; encrypted
    jnz .not_stored
    cmp word [r12 + 10], 0          ; method 0 = Stored
    jne .not_stored
    mov eax, [r12 + 20]             ; compressed == uncompressed, not zip64
    cmp eax, [r12 + 24]
    jne .not_stored
    cmp eax, -1
    je .not_stored
    mov [rbx + 16], eax
    mov dword [rbx + 20], 0
    mov edi, [pak_fd]               ; local header: its own name/extra lengths
    mov rsi, rsp
    mov edx, 30
    mov ecx, [r12 + 42]
    call _pread
    cmp rax, 30
    jne .bad_zip
    cmp dword [rsp], 0x04034B50
    jne .bad_zip
    movzx eax, word [rsp + 26]
    movzx ecx, word [rsp + 28]
    add eax, ecx
    add eax, 30
    mov ecx, [r12 + 42]
    add rax, rcx
    mov [rbx + 8], rax
    mov edx, [rbx + 16]             ; data must lie inside the file
    add rdx, rax
    cmp rdx, [pak_fd_size]
    ja .bad_zip
    mov rdi, [rbx]                  ; "dir/" -> "dir" + PAK_DIR
    call _strlen
    test eax, eax
    jz .next
    mov rdi, [rbx]
    cmp byte [rdi + rax - 1], '/'
    jne .next
    mov byte [rdi + rax - 1], 0
    mov dword [rbx + 20], PAK_DIR
.next:
    movzx eax, word [r12 + 28]      ; next record: 46 + name + extra + comment
    movzx ecx, word [r12 + 30]
    add eax, ecx
    movzx ecx, word [r12 + 32]
    add eax, ecx
    lea r12, [r12 + rax + 46]
    add rbx, PAK_ENT_SIZE
    inc r13d
    jmp .entry
.indexed:
    mov rdi, r14
    call _free
    lea rdi, [fmt_pak]
    mov rsi, [pak_path]
    mov edx, [pak_count]
    xor eax, eax
    call _printf
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.no_open:
    lea rdi, [fmt_no_pak]
    mov rsi, [pak_path]
    xor eax, eax
    call _printf
    mov edi, 1
    call _exit
.not_stored:
    lea rdi, [fmt_pak_method]
    mov rsi, [pak_path]
    mov rdx, [rbx]
    movzx ecx, word [r12 + 10]
    xor eax, eax
    call _printf
    mov edi, 1
    call _exit
.bad_zip:
    lea rdi, [fmt_pak_bad]
    mov rsi, [pak_path]
    xor eax, eax
    call _printf
    mov edi, 1
    call _exit

; eax = vfs_find(rdi = path relative to the game root) -> pak index, -1 if absent
vfs_find:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov rbx, [pak_ents]
    xor r13d, r13d
.scan:
    cmp r13d, [pak_count]
    jae .none
    mov rdi, [rbx]
    mov rsi, r12
    call _strcasecmp
    test eax, eax
    jz .hit
    add rbx, PAK_ENT_SIZE
    inc r13d
    jmp .scan
.hit:
    mov eax, r13d
    jmp .out
.none:
    mov eax, -1
.out:
    pop r13
    pop r12
    pop rbx
    ret

; eax = vfs_is_dir(rdi = relative path): 1 if the pak has it as a directory (an explicit
; "dir/" entry or any entry below it; "." is the root), else 0
vfs_is_dir:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    mov eax, 1
    cmp word [r12], '.'
    je .out
    call _strlen
    mov r14, rax
    mov rbx, [pak_ents]
    xor r13d, r13d
.scan:
    xor eax, eax
    cmp r13d, [pak_count]
    jae .out
    mov rdi, [rbx]
    mov rsi, r12
    mov rdx, r14
    call _strncasecmp
    test eax, eax
    jnz .skip
    mov rax, [rbx]
    movzx eax, byte [rax + r14]
    cmp al, '/'
    je .yes
    test al, al
    jnz .skip
    test dword [rbx + 20], PAK_DIR
    jnz .yes
.skip:
    add rbx, PAK_ENT_SIZE
    inc r13d
    jmp .scan
.yes:
    mov eax, 1
.out:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rax = vfs_read_at(edi = pak index, rsi = buf, rdx = n, rcx = position): bytes read,
; clipped to the entry (0 at or past its end), -1 on an I/O error
vfs_read_at:
    sub rsp, 8
    imul eax, edi, PAK_ENT_SIZE
    add rax, [pak_ents]
    mov r8d, [rax + 16]
    cmp rcx, r8
    jae .eof
    sub r8, rcx
    cmp rdx, r8
    cmova rdx, r8
    add rcx, [rax + 8]
    mov edi, [pak_fd]
    call _pread
    add rsp, 8
    ret
.eof:
    xor eax, eax
    add rsp, 8
    ret

; eax = vfs_resolve(rdi = game path): VFS_REFUSED / VFS_NONE / VFS_OVERLAY (path_out is
; the overlay path, stat_buf its stat) or a pak index (path_out = its relative name)
vfs_resolve:
    sub rsp, 8
    call win_path
    test rax, rax
    jz .refused
    mov rdi, rax
    lea rsi, [stat_buf]
    call _stat
    test eax, eax
    jz .overlay
    lea rdi, [path_out]
    call vfs_find
    cmp eax, -1
    jne .r
    mov eax, VFS_NONE
    jmp .r
.overlay:
    mov eax, VFS_OVERLAY
    jmp .r
.refused:
    mov eax, VFS_REFUSED
.r:
    add rsp, 8
    ret

; rax = vfs_load(rdi = game path) -> whole file in a malloc'ed buffer (+16 zero bytes of
; slack), rdx = its size; rax = 0 if it is in neither the overlay nor the pak
vfs_load:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi
    call vfs_resolve
    mov r14d, eax
    cmp eax, VFS_NONE
    jle .none
    cmp eax, VFS_OVERLAY
    je .size_host
    imul eax, eax, PAK_ENT_SIZE
    add rax, [pak_ents]
    mov r13d, [rax + 16]
    jmp .alloc
.size_host:
    mov r13, [stat_buf + ST_SIZE]
.alloc:
    lea rdi, [r13 + 16]
    call _malloc
    mov rbx, rax
    lea rdi, [rbx + r13]
    xor esi, esi
    mov edx, 16
    call _memset
    cmp r14d, VFS_OVERLAY
    je .read_host
    mov edi, r14d
    mov rsi, rbx
    mov rdx, r13
    xor ecx, ecx
    call vfs_read_at
    cmp rax, r13
    jne .bad
    lea rdi, [fmt_load_pak]
    jmp .ok
.read_host:
    lea rdi, [path_out]
    xor esi, esi
    xor eax, eax
    call _open
    test eax, eax
    js .bad
    mov r12d, eax
    mov edi, eax
    mov rsi, rbx
    mov rdx, r13
    xor ecx, ecx
    call _pread
    mov r14, rax
    mov edi, r12d
    call _close
    cmp r14, r13
    jne .bad
    lea rdi, [fmt_load_ovl]
.ok:
    mov rsi, r15
    mov rdx, r13
    xor eax, eax
    call _printf
    mov rax, rbx
    mov rdx, r13
    jmp .out
.bad:
    mov rdi, rbx
    call _free
.none:
    xor eax, eax
    xor edx, edx
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; mkdir_parents(rdi = path): create every directory named before a '/' in it
mkdir_parents:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    mov rbx, rdi
.scan:
    inc rbx
    movzx eax, byte [rbx]
    test al, al
    jz .done
    cmp al, '/'
    jne .scan
    mov byte [rbx], 0
    mov rdi, r12
    mov esi, 0755o
    call _mkdir                     ; EEXIST is fine
    mov byte [rbx], '/'
    jmp .scan
.done:
    add rsp, 8
    pop r12
    pop rbx
    ret

; eax = vfs_copy_out(edi = pak index, rsi = overlay path): 1 ok, 0 failed
vfs_copy_out:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, rsi
    mov rdi, rsi
    call mkdir_parents
    imul eax, r12d, PAK_ENT_SIZE
    add rax, [pak_ents]
    mov r14d, [rax + 16]
    lea rdi, [r14 + 1]
    call _malloc
    mov rbx, rax
    mov edi, r12d
    mov rsi, rbx
    mov rdx, r14
    xor ecx, ecx
    call vfs_read_at
    cmp rax, r14
    jne .fail
    mov rdi, r13
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644o
    xor eax, eax
    call _open
    test eax, eax
    js .fail
    mov r15d, eax
    mov edi, eax
    mov rsi, rbx
    mov rdx, r14
    call _write
    mov r12, rax
    mov edi, r15d
    call _close
    cmp r12, r14
    jne .fail
    lea rdi, [fmt_copy_out]
    mov rsi, r13
    mov edx, r14d
    xor eax, eax
    call _printf
    mov r12d, 1
    jmp .out
.fail:
    xor r12d, r12d
.out:
    mov rdi, rbx
    call _free
    mov eax, r12d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; enter_overlay_dir: mkdir -p + chdir ~/Library/Application Support/gta2-resurrected/
enter_overlay_dir:
    sub rsp, 8
    lea rdi, [s_home]
    call _getenv
    test rax, rax
    jz .bad
    lea rdi, [overlay_dir]
    mov esi, PATH_MAX_W
    lea rdx, [fmt_overlay_dir]
    mov rcx, rax
    xor eax, eax
    call _snprintf
    lea rdi, [overlay_dir]
    call mkdir_parents
    lea rdi, [overlay_dir]
    call _chdir
    test eax, eax
    jnz .bad
    lea rdi, [fmt_overlay]
    lea rsi, [overlay_dir]
    xor eax, eax
    call _printf
    add rsp, 8
    ret
.bad:
    lea rdi, [msg_overlay]
    call fail

section .rodata
s_home:          db "HOME", 0
fmt_overlay_dir: db "%s/Library/Application Support/gta2-resurrected/", 0
fmt_overlay:     db "overlay: %s (writes land here, its files win over the pak; seen by the game as C:\GTA2)", 10, 0
msg_overlay:     db "create/enter the overlay directory", 0
fmt_pak:         db "pak: %s, %u entries, all Stored", 10, 0
fmt_no_pak:      db "loader: FAIL: cannot open %s (build it with tools/mkpak.sh)", 10, 0
fmt_pak_bad:     db "loader: FAIL: %s is not a zip this loader understands (rebuild it with tools/mkpak.sh)", 10, 0
fmt_pak_method:  db "loader: FAIL: %s: entry %s is not Stored (method %u); rebuild it with tools/mkpak.sh (zip -0)", 10, 0
fmt_load_pak:    db "  [vfs] %s -> pak (%u bytes)", 10, 0
fmt_load_ovl:    db "  [vfs] %s -> overlay (%u bytes)", 10, 0
fmt_copy_out:    db "  [vfs] copied the pak's %s to the overlay (%u bytes) before writing", 10, 0

section .bss
alignb 8
pak_path:    resq 1
pak_ents:    resq 1
pak_fd_size: resq 1
pak_fd:      resd 1
pak_count:   resd 1
overlay_dir: resb PATH_MAX_W
section .text
