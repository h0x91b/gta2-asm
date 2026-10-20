; w32_audio.asm — mss32.dll (Miles Sound System 6) on SDL3 audio: the 2D digital
; sample API, file streams (WAV: PCM or IMA ADPCM) and the driver calls gta2.exe makes.
; Design and gaps: docs/win32-shims.md, "Audio".
;
; How the game uses it (sample manager object at 0x66C950, code 0x4B5F70..0x4B73E0,
; own analysis of vanilla 11.44): AIL_startup, AIL_waveOutOpen(&drv, 0, -1, 22050 Hz
; 16-bit stereo), one 8-bit sample (+0x98) and 16 16-bit signed mono samples (+0x58),
; AIL_mem_alloc_lock(0x5D1420) for the sound bank. Banks are data\audio\<name>.RAW
; (raw PCM) + .SDT (0x140 entries of 24 bytes: offset, size, rate, ...) read by the
; game itself; it points samples into the bank with AIL_set_sample_address. Music is
; AIL_open_stream on data\gtaudio\%d[A].WAV, voices on data\audio\vocals\*.wav.
; 3D (AIL_enumerate_3D_providers) answers "no providers", so the game stays on 2D.
;
; Threading: none. Mixing runs on the game's own thread, inside audio_pump (called by
; pump_sdl each frame and by AIL_delay); it tops an SDL_AudioStream up to MIX_TARGET
; frames. SDL's device thread only drains that stream (SDL locks it internally), so no
; game or shim state is ever touched from another thread. Without a device the mixer
; runs on the wall clock, so --audio-dump works headless too.

SDL_INIT_AUDIO     equ 0x10
SDL_AUDIO_S16LE    equ 0x8010
SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK equ 0xFFFFFFFF

MIX_RATE    equ 22050           ; what the game asks waveOutOpen for (0x5622)
MIX_CHUNK   equ 256             ; frames per mixing step
MIX_TARGET  equ 2048            ; frames kept queued for the device (~93 ms)
MIX_MAX     equ 16384           ; most frames one pump may mix (after a long stall)
MAX_SECONDS equ 7200            ; per-second dump statistics

SMP_FREE    equ 1               ; MSS sample/stream status values
SMP_DONE    equ 2
SMP_PLAYING equ 4
SMP_STOPPED equ 8

AUD_DRV     equ 0x00A0D000      ; HDIGDRIVER token (never dereferenced by the game)
AUD_HBASE   equ 0x00A10000      ; HSAMPLE/HSTREAM = AUD_HBASE + 16 * voice index
MAX_VOICES  equ 64
N_PREFS     equ 64

; voice record (host memory): one per HSAMPLE or HSTREAM
V_STATUS    equ 0               ; 0 = unused, else SMP_*
V_KIND      equ 4               ; 0 sample, 1 stream
V_DATA      equ 8               ; q: PCM (game memory for samples, host buffer for streams)
V_LEN       equ 16              ; bytes
V_FMT       equ 20              ; bit 0 = 16-bit, bit 1 = stereo (MSS DIG_F_*)
V_SIGN      equ 24              ; DIG_PCM_SIGN: 8-bit data is signed
V_RATE      equ 28
V_VOL       equ 32              ; 0..127
V_PAN       equ 36              ; 0..127, 64 = centre
V_LOOPS     equ 40              ; loop count: 0 = forever, 1 = once, n = n times
V_LSTART    equ 44              ; loop block, byte offsets; end -1 = end of data
V_LEND      equ 48
V_LEFT      equ 52              ; plays left in the current start (0 = forever)
V_POS       equ 56              ; q: frame position << 16
V_BUF       equ 64              ; q: stream: malloc'd buffer to free
V_SIZE      equ 72

extern _malloc, _fseek, _ftell, _fread, _fwrite, _atexit

section .text

; ---- setup / helpers -------------------------------------------------------------
%macro AFNS 0
    AFN SDL_InitSubSystem
    AFN SDL_OpenAudioDeviceStream
    AFN SDL_ResumeAudioStreamDevice
    AFN SDL_PauseAudioStreamDevice
    AFN SDL_PutAudioStreamData
    AFN SDL_GetAudioStreamQueued
    AFN SDL_GetCurrentAudioDriver
%endmacro

setup_audio:
    push rbx
%macro AFN 1
    mov rdi, [sdl_lib]
    lea rsi, [%%n]
    call _dlsym
    test rax, rax
    jz .no_sym
    mov [a_%1], rax
section .rodata
%%n: db %str(%1), 0
section .text
%endmacro
    AFNS
    mov dword [aud_master], 127
    mov dword [aud_prefs + 4*2], 127    ; DIG_DEFAULT_VOLUME
    cmp qword [aud_dump_path], 0
    je .done
    lea rdi, [aud_atexit]
    call _atexit
.done:
    pop rbx
    ret
.no_sym:
    lea rdi, [msg_sdl_sym]
    call fail

; rax = aud_voice(edi = handle) -> voice record, 0 if not a live handle
aud_voice:
    mov eax, edi
    sub eax, AUD_HBASE
    jb .no
    test eax, 15
    jnz .no
    shr eax, 4
    cmp eax, MAX_VOICES
    jae .no
    imul eax, eax, V_SIZE
    lea rcx, [aud_voices]
    add rax, rcx
    cmp dword [rax + V_STATUS], 0
    je .no
    ret
.no:
    xor eax, eax
    ret

; eax = aud_new_voice(edi = kind) -> handle (0 if all in use); defaults like AIL_init_sample
aud_new_voice:
    lea rax, [aud_voices]
    xor ecx, ecx
.scan:
    cmp dword [rax + V_STATUS], 0
    je .got
    add rax, V_SIZE
    inc ecx
    cmp ecx, MAX_VOICES
    jb .scan
    xor eax, eax
    ret
.got:
    mov [rax + V_KIND], edi
    mov qword [rax + V_DATA], 0
    mov qword [rax + V_BUF], 0
    mov dword [rax + V_LEN], 0
    push rcx
    mov rdi, rax
    call aud_init_voice
    pop rcx
    shl ecx, 4
    lea eax, [rcx + AUD_HBASE]
    ret

; aud_init_voice(rdi = voice): AIL_init_sample defaults (8-bit mono 11025 Hz, once)
aud_init_voice:
    mov dword [rdi + V_STATUS], SMP_DONE
    mov dword [rdi + V_FMT], 0
    mov dword [rdi + V_SIGN], 0
    mov dword [rdi + V_RATE], 11025
    mov eax, [aud_prefs + 4*2]
    mov [rdi + V_VOL], eax
    mov dword [rdi + V_PAN], 64
    mov dword [rdi + V_LOOPS], 1
    mov dword [rdi + V_LEFT], 1
    mov dword [rdi + V_LSTART], 0
    mov dword [rdi + V_LEND], -1
    mov qword [rdi + V_POS], 0
    ret

; aud_free_voice(rdi = voice): status 0, free a stream's buffer
aud_free_voice:
    push rbx
    mov rbx, rdi
    mov dword [rbx + V_STATUS], 0
    mov rdi, [rbx + V_BUF]
    test rdi, rdi
    jz .r
    call _free
    mov qword [rbx + V_BUF], 0
.r:
    pop rbx
    ret

; aud_start(rdi = voice): play from the start (AIL_start_sample / AIL_start_stream)
aud_start:
    mov qword [rdi + V_POS], 0
    mov eax, [rdi + V_LOOPS]
    mov [rdi + V_LEFT], eax
    mov dword [rdi + V_STATUS], SMP_PLAYING
    ret

; eax = aud_bpf(rdi = voice): bytes per frame
aud_bpf:
    mov ecx, [rdi + V_FMT]
    mov eax, 1
    test ecx, 1
    jz .b
    add eax, eax
.b:
    test ecx, 2
    jz .r
    add eax, eax
.r:
    ret

; ---- the mixer ----------------------------------------------------------------------
; mix_voice(rdi = voice, esi = frames): add the voice into aud_acc (int64 L,R pairs)
mix_voice:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov rbx, rdi
    mov [rsp], esi                  ; frames to mix
    call aud_bpf
    mov r14d, eax                   ; bytes per frame
    mov eax, [rbx + V_LEN]          ; end frame = loop end or the data's end
    xor edx, edx
    div r14d
    mov r12d, eax
    mov eax, [rbx + V_LEND]
    cmp eax, -1
    je .end_ok
    cmp eax, [rbx + V_LEN]
    jae .end_ok
    xor edx, edx
    div r14d
    mov r12d, eax
.end_ok:
    mov eax, [rbx + V_LSTART]
    xor edx, edx
    div r14d
    mov r13d, eax                   ; loop start frame
    mov eax, [rbx + V_RATE]         ; step = rate / MIX_RATE in 16.16
    test eax, eax
    jnz .rate
    mov eax, MIX_RATE
.rate:
    shl rax, 16
    xor edx, edx
    mov ecx, MIX_RATE
    div rcx
    mov [rsp + 8], rax              ; step
    ; gains: vol * pan side * master, scaled so 127^3 = 32768 (>> 15 later)
    mov eax, 127
    sub eax, [rbx + V_PAN]
    add eax, eax
    cmp eax, 127
    jbe .gl
    mov eax, 127
.gl:
    imul eax, [rbx + V_VOL]
    imul eax, [aud_master]
    shl rax, 15
    xor edx, edx
    mov ecx, 2048383                ; 127^3
    div rcx
    mov [rsp + 16], rax             ; left gain
    mov eax, [rbx + V_PAN]
    add eax, eax
    cmp eax, 127
    jbe .gr
    mov eax, 127
.gr:
    imul eax, [rbx + V_VOL]
    imul eax, [aud_master]
    shl rax, 15
    xor edx, edx
    mov ecx, 2048383
    div rcx
    mov [rsp + 24], rax             ; right gain
    mov r15, [rbx + V_DATA]
    mov rbp, [rbx + V_POS]
    lea r8, [aud_acc]
    xor r9d, r9d                    ; frame index
.frame:
    cmp r9d, [rsp]
    jae .save
    mov rax, rbp
    shr rax, 16
    cmp eax, r12d
    jb .fetch
    ; past the end: loop or finish
    mov ecx, [rbx + V_LEFT]
    cmp ecx, 1
    je .done
    test ecx, ecx
    jz .wrap
    dec dword [rbx + V_LEFT]
.wrap:
    mov eax, r12d
    sub eax, r13d
    jbe .done                       ; empty loop block
    shl rax, 16
    sub rbp, rax
    jmp .frame
.fetch:
    imul eax, r14d
    add rax, r15
    mov ecx, [rbx + V_FMT]
    cmp ecx, 1
    je .m16
    cmp ecx, 2
    je .s8
    cmp ecx, 3
    je .s16
    movzx r10d, byte [rax]          ; mono 8
    call .conv8
    mov r11d, r10d
    jmp .mix
.m16:
    movsx r10d, word [rax]
    mov r11d, r10d
    jmp .mix
.s8:
    movzx r11d, byte [rax + 1]
    movzx r10d, byte [rax]
    call .conv8
    xchg r10d, r11d
    call .conv8
    xchg r10d, r11d
    jmp .mix
.s16:
    movsx r10d, word [rax]
    movsx r11d, word [rax + 2]
.mix:
    movsxd r10, r10d
    movsxd r11, r11d
    imul r10, [rsp + 16]
    imul r11, [rsp + 24]
    lea rax, [r9 + r9]
    add [r8 + rax*8], r10
    add [r8 + rax*8 + 8], r11
    add rbp, [rsp + 8]
    inc r9d
    jmp .frame
.conv8:                             ; r10d = byte -> 16-bit sample
    cmp dword [rbx + V_SIGN], 0
    jne .signed8
    sub r10d, 128
    shl r10d, 8
    ret
.signed8:
    movsx r10d, r10b
    shl r10d, 8
    ret
.done:
    mov dword [rbx + V_STATUS], SMP_DONE
.save:
    mov [rbx + V_POS], rbp
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; mix_chunk(edi = frames <= MIX_CHUNK): mix every playing voice, hand the result to
; SDL and the dump, update the per-second statistics
mix_chunk:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    lea rdi, [aud_acc]
    xor esi, esi
    mov edx, MIX_CHUNK * 16
    call _memset
    cmp byte [aud_paused], 0
    jne .convert
    lea rbx, [aud_voices]
    xor r13d, r13d
.v:
    cmp dword [rbx + V_STATUS], SMP_PLAYING
    jne .next
    cmp qword [rbx + V_DATA], 0
    je .next
    mov rdi, rbx
    mov esi, r12d
    call mix_voice
.next:
    add rbx, V_SIZE
    inc r13d
    cmp r13d, MAX_VOICES
    jb .v
.convert:                           ; >> 15, clip to int16, statistics
    lea rsi, [aud_acc]
    lea rdi, [aud_out]
    lea ecx, [r12 + r12]
    xor edx, edx
.c:
    mov rax, [rsi + rdx*8]
    sar rax, 15
    cmp rax, 32767
    jle .hi
    mov eax, 32767
.hi:
    cmp rax, -32768
    jge .lo
    mov rax, -32768
.lo:
    mov [rdi + rdx*2], ax
    movsx r8d, ax                   ; |s| peak, s^2 sum
    mov r9d, r8d
    neg r9d
    cmovl r9d, r8d
    cmp r9d, [aud_sec_peak_cur]
    jbe .p
    mov [aud_sec_peak_cur], r9d
.p:
    movsxd r8, r8d
    imul r8, r8
    add [aud_sec_sq], r8
    test edx, 1
    jz .nf
    inc dword [aud_sec_frames]
    cmp dword [aud_sec_frames], MIX_RATE
    jb .nf
    call aud_close_second
.nf:
    inc edx
    cmp edx, ecx
    jb .c
    mov rdi, [aud_stream]
    test rdi, rdi
    jz .dump
    lea rsi, [aud_out]
    lea edx, [r12*4]
    call [a_SDL_PutAudioStreamData]
.dump:
    mov rcx, [aud_dump_file]
    test rcx, rcx
    jz .out
    lea rdi, [aud_out]
    mov esi, 4
    mov edx, r12d
    call _fwrite
.out:
    add [aud_mixed], r12
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; aud_close_second: store the finished second's peak and rms (keeps rcx/rdx/rsi/rdi)
aud_close_second:
    mov eax, [aud_nsec]
    cmp eax, MAX_SECONDS
    jae .reset
    lea r8, [aud_peaks]
    mov r9d, [aud_sec_peak_cur]
    mov [r8 + rax*4], r9d
    cvtsi2sd xmm0, qword [aud_sec_sq]
    mov r9d, [aud_sec_frames]
    add r9d, r9d
    cvtsi2sd xmm1, r9d
    divsd xmm0, xmm1
    sqrtsd xmm0, xmm0
    cvttsd2si r9d, xmm0
    lea r8, [aud_rms]
    mov [r8 + rax*4], r9d
    inc dword [aud_nsec]
.reset:
    mov dword [aud_sec_frames], 0
    mov dword [aud_sec_peak_cur], 0
    mov qword [aud_sec_sq], 0
    ret

; audio_pump: top the output up. Called by pump_sdl (every frame) and AIL_delay.
audio_pump:
    cmp byte [aud_open], 0
    je .r
    push rbx
    push r12
    sub rsp, 8
    mov rdi, [aud_stream]
    test rdi, rdi
    jz .clock
    call [a_SDL_GetAudioStreamQueued]
    test eax, eax
    jns .q
    xor eax, eax
.q:
    shr eax, 2                      ; bytes -> frames
    mov ebx, MIX_TARGET
    sub ebx, eax
    jle .done
    cmp byte [aud_paused], 0
    jne .done
    jmp .mix
.clock:                             ; no device: frames due on the wall clock
    mov edi, CLOCK_MONOTONIC_RAW
    call _clock_gettime_nsec_np
    mov rcx, rax
    xchg rcx, [aud_last_ns]
    test rcx, rcx
    jnz .elapsed
    mov ebx, MIX_TARGET             ; first pump: prefill
    jmp .mix
.elapsed:
    sub rax, rcx
    add rax, [aud_credit_ns]
    mov rcx, rax
    mov edx, MIX_RATE
    imul rax, rdx
    xor edx, edx
    mov r8, 1000000000
    div r8                          ; frames due
    mov rbx, rax
    imul rax, r8                    ; credit -= frames * 1e9 / rate
    xor edx, edx
    mov r8d, MIX_RATE
    div r8
    sub rcx, rax
    mov [aud_credit_ns], rcx
    cmp byte [aud_paused], 0
    jne .done
.mix:
    cmp ebx, MIX_MAX
    jbe .loop
    mov ebx, MIX_MAX
.loop:
    test ebx, ebx
    jle .done
    mov edi, ebx
    cmp edi, MIX_CHUNK
    jbe .n
    mov edi, MIX_CHUNK
.n:
    sub ebx, edi
    call mix_chunk
    jmp .loop
.done:
    add rsp, 8
    pop r12
    pop rbx
.r:
    ret

; aud_open_device: SDL audio subsystem + a 22050 Hz stereo s16 device stream
aud_open_device:
    push rbx
    sub rsp, 16
    cmp byte [aud_dev_tried], 0
    jne .out
    mov byte [aud_dev_tried], 1
    mov edi, SDL_INIT_AUDIO
    call [a_SDL_InitSubSystem]
    test al, al
    jz .fail
    mov dword [rsp], SDL_AUDIO_S16LE    ; SDL_AudioSpec {format, channels, freq}
    mov dword [rsp + 4], 2
    mov dword [rsp + 8], MIX_RATE
    mov edi, SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK
    mov rsi, rsp
    xor edx, edx
    xor ecx, ecx
    call [a_SDL_OpenAudioDeviceStream]
    test rax, rax
    jz .fail
    mov [aud_stream], rax
    mov rdi, rax
    call [a_SDL_ResumeAudioStreamDevice]
    call [a_SDL_GetCurrentAudioDriver]
    lea rdi, [fmt_aud_dev]
    mov rsi, rax
    test rsi, rsi
    jnz .p
    lea rsi, [s_empty_str]
.p:
    xor eax, eax
    call _printf
    jmp .out
.fail:
    call [sdl_SDL_GetError]
    lea rdi, [fmt_aud_nodev]
    mov rsi, rax
    xor eax, eax
    call _printf
.out:
    add rsp, 16
    pop rbx
    ret

; aud_atexit: finish the --audio-dump WAV and print its per-second levels
aud_atexit:
    push rbx
    push r12
    push r13
    sub rsp, 64
    mov rbx, [aud_dump_file]
    test rbx, rbx
    jz .out
    cmp dword [aud_sec_frames], 0
    je .hdr
    call aud_close_second           ; the last, partial second
.hdr:
    mov rdi, rbx                    ; rewrite the RIFF header with the real sizes
    xor esi, esi
    xor edx, edx
    call _fseek
    mov rax, [aud_mixed]
    shl eax, 2                      ; data bytes
    mov r12d, eax
    lea rdi, [rsp]
    lea rsi, [wav_header]
    mov ecx, 44
    rep movsb
    lea eax, [r12 + 36]
    mov [rsp + 4], eax
    mov [rsp + 40], r12d
    lea rdi, [rsp]
    mov esi, 1
    mov edx, 44
    mov rcx, rbx
    call _fwrite
    mov rdi, rbx
    call _fclose
    mov qword [aud_dump_file], 0
    mov rax, [aud_mixed]            ; duration in ms
    imul rax, rax, 1000
    xor edx, edx
    mov ecx, MIX_RATE
    div rcx
    lea rdi, [fmt_aud_dump]
    mov rsi, [aud_dump_path]
    mov edx, eax
    mov rcx, [aud_mixed]
    mov r8d, [aud_starts]
    mov r9d, [aud_streams_opened]
    sub rsp, 16
    mov eax, [aud_stream_misses]
    mov [rsp], rax
    xor eax, eax
    call _printf
    add rsp, 16
    xor r12d, r12d
.sec:
    cmp r12d, [aud_nsec]
    jae .out
    lea rax, [aud_peaks]
    mov r13d, [rax + r12*4]
    imul eax, r13d, 100             ; peak in % of full scale
    xor edx, edx
    mov ecx, 32767
    div ecx
    mov ecx, eax
    lea rax, [aud_rms]
    mov r8d, [rax + r12*4]
    lea rdi, [fmt_aud_sec]
    mov esi, r12d
    mov edx, r13d
    xor eax, eax
    call _printf
    inc r12d
    jmp .sec
.out:
    add rsp, 64
    pop r13
    pop r12
    pop rbx
    ret

; ---- WAV streams ----------------------------------------------------------------------
; eax = aud_load_wav(rdi = host path, rsi = voice): fill V_DATA/LEN/FMT/RATE from a WAV
; (PCM 8/16-bit, or IMA ADPCM decoded to 16-bit up front). 1 ok, 0 unreadable.
aud_load_wav:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov rbx, rsi
    lea rsi, [s_rb]
    call _fopen
    test rax, rax
    jz .fail0
    mov r12, rax
    mov rdi, r12
    xor esi, esi
    mov edx, 2                      ; SEEK_END
    call _fseek
    mov rdi, r12
    call _ftell
    mov r13, rax                    ; file size
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call _fseek
    lea rdi, [r13 + 16]
    call _malloc
    mov rbp, rax                    ; file bytes
    mov rdi, rbp
    mov esi, 1
    mov rdx, r13
    mov rcx, r12
    call _fread
    mov r14, rax
    mov rdi, r12
    call _fclose
    cmp r14, r13
    jne .bad
    cmp r13, 12
    jb .bad
    cmp dword [rbp], 'RIFF'
    jne .bad
    cmp dword [rbp + 8], 'WAVE'
    jne .bad
    ; walk the chunks: r14 = fmt chunk, r15 = data chunk, [rsp] = data size
    xor r14d, r14d
    xor r15d, r15d
    mov ecx, 12
.chunk:
    lea rax, [rcx + 8]
    cmp rax, r13
    ja .walked
    mov edx, [rbp + rcx + 4]        ; chunk size
    cmp dword [rbp + rcx], 'fmt '
    jne .not_fmt
    lea r14, [rbp + rcx + 8]
.not_fmt:
    cmp dword [rbp + rcx], 'data'
    jne .not_data
    lea r15, [rbp + rcx + 8]
    mov rax, r13                    ; clamp to the file
    sub rax, rcx
    sub rax, 8
    cmp rdx, rax
    jbe .dsz
    mov rdx, rax
.dsz:
    mov [rsp], edx
.not_data:
    lea rcx, [rcx + rdx + 9]
    and rcx, -2                     ; chunks are word-aligned
    jmp .chunk
.walked:
    test r14, r14
    jz .bad
    test r15, r15
    jz .bad
    movzx eax, word [r14 + 2]       ; channels
    cmp eax, 1
    jb .bad
    cmp eax, 2
    ja .bad
    mov [rsp + 4], eax
    mov eax, [r14 + 4]
    mov [rbx + V_RATE], eax
    movzx eax, word [r14]           ; format tag
    cmp eax, 1
    je .pcm
    cmp eax, 0x11
    je .ima
    jmp .bad
.pcm:
    movzx eax, word [r14 + 14]
    xor ecx, ecx
    cmp eax, 8
    je .bits
    mov ecx, 1
    cmp eax, 16
    jne .bad
.bits:
    cmp dword [rsp + 4], 2
    jne .mono
    or ecx, 2
.mono:
    mov [rbx + V_FMT], ecx
    mov dword [rbx + V_SIGN], 0     ; 8-bit WAV is unsigned
    mov [rbx + V_DATA], r15
    mov eax, [rsp]
    mov [rbx + V_LEN], eax
    mov [rbx + V_BUF], rbp
    jmp .ok
.ima:
    cmp word [r14 + 14], 4
    jne .bad
    movzx eax, word [r14 + 12]      ; block align
    mov ecx, [rsp + 4]
    shl ecx, 2
    cmp eax, ecx
    jbe .bad
    mov [rsp + 8], eax
    ; worst case output: every block full -> (blocks + 1) * spb * ch * 2
    sub eax, ecx                    ; samples per block = (align - 4ch) * 2 / ch + 1
    add eax, eax
    xor edx, edx
    div dword [rsp + 4]
    inc eax
    mov [rsp + 12], eax             ; spb
    mov eax, [rsp]
    xor edx, edx
    div dword [rsp + 8]
    inc eax
    imul eax, [rsp + 12]
    imul eax, [rsp + 4]
    lea rdi, [rax*2]
    call _malloc
    mov r12, rax                    ; output
    mov r13, rax                    ; write cursor
    mov r14d, [rsp]                 ; bytes left
.blk:
    mov ecx, [rsp + 4]
    shl ecx, 2
    cmp r14d, ecx
    jbe .ima_done
    mov eax, [rsp + 8]              ; this block's bytes
    cmp r14d, eax
    jae .full
    mov eax, r14d
.full:
    mov [rsp + 16], eax
    sub eax, ecx                    ; samples in it
    add eax, eax
    xor edx, edx
    div dword [rsp + 4]
    inc eax
    mov ecx, eax
    mov rdi, r15
    mov rsi, r13
    mov edx, [rsp + 4]
    push rcx
    sub rsp, 8
    call ima_block
    add rsp, 8
    pop rcx
    imul ecx, [rsp + 4]
    lea r13, [r13 + rcx*2]
    mov eax, [rsp + 16]
    add r15, rax
    sub r14d, eax
    jmp .blk
.ima_done:
    mov rdi, rbp
    call _free
    mov [rbx + V_DATA], r12
    mov [rbx + V_BUF], r12
    mov rax, r13
    sub rax, r12
    mov [rbx + V_LEN], eax
    mov eax, 1
    cmp dword [rsp + 4], 2
    jne .ifmt
    mov eax, 3
.ifmt:
    mov [rbx + V_FMT], eax
.ok:
    mov eax, 1
    jmp .out
.bad:
    mov rdi, rbp
    call _free
.fail0:
    xor eax, eax
.out:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ima_block(rdi = block, rsi = int16 out (interleaved), edx = channels, ecx = samples):
; one IMA ADPCM block (Microsoft layout: per-channel 4-byte headers, then 4-byte runs
; of 8 nibbles per channel, low nibble first)
ima_block:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov [rsp], edx                  ; channels
    mov [rsp + 4], ecx              ; samples
    xor r12d, r12d                  ; channel
.ch:
    cmp r12d, [rsp]
    jae .out
    movsx ebp, word [rdi + r12*4]   ; predictor
    movzx ebx, byte [rdi + r12*4 + 2]   ; step index
    cmp ebx, 88
    jbe .i0
    mov ebx, 88
.i0:
    mov [rsi + r12*2], bp
    mov r13d, 1                     ; sample number
.s:
    cmp r13d, [rsp + 4]
    jae .next_ch
    lea eax, [r13 - 1]              ; k
    mov ecx, eax
    shr ecx, 3                      ; group
    imul ecx, [rsp]
    add ecx, r12d
    shl ecx, 2                      ; 4 * (group * ch + c), past the 4 * ch headers
    mov edx, [rsp]
    lea ecx, [rcx + rdx*4]
    mov edx, eax
    and edx, 7
    shr edx, 1
    add ecx, edx
    movzx r14d, byte [rdi + rcx]
    test eax, 1
    jz .lo
    shr r14d, 4
.lo:
    and r14d, 15
    lea rax, [ima_steps]
    movzx r15d, word [rax + rbx*2]  ; step
    mov eax, r15d                   ; diff = step >> 3 (+ step, step/2, step/4)
    shr eax, 3
    test r14d, 4
    jz .b2
    add eax, r15d
.b2:
    test r14d, 2
    jz .b1
    mov edx, r15d
    shr edx, 1
    add eax, edx
.b1:
    test r14d, 1
    jz .b0
    mov edx, r15d
    shr edx, 2
    add eax, edx
.b0:
    test r14d, 8
    jz .add
    sub ebp, eax
    jmp .clamp
.add:
    add ebp, eax
.clamp:
    cmp ebp, 32767
    jle .c1
    mov ebp, 32767
.c1:
    cmp ebp, -32768
    jge .c2
    mov ebp, -32768
.c2:
    lea rax, [ima_index]
    movsx eax, byte [rax + r14]
    add ebx, eax
    jns .c3
    xor ebx, ebx
.c3:
    cmp ebx, 88
    jbe .c4
    mov ebx, 88
.c4:
    mov eax, r13d                   ; out[s * ch + c]
    imul eax, [rsp]
    add eax, r12d
    mov [rsi + rax*2], bp
    inc r13d
    jmp .s
.next_ch:
    inc r12d
    jmp .ch
.out:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ---- AIL_* exports ---------------------------------------------------------------------
%macro VOICE 1                      ; rax = voice of ARG(%1), or return 0
    mov edi, ARG(%1)
    call aud_voice
    test rax, rax
    jz .bad_handle
%endmacro

ail_startup:
    mov eax, 1
    ret

ail_shutdown:
    sub rsp, 8
    call ail_close_all
    add rsp, 8
    xor eax, eax
    ret

; release every voice (AIL_shutdown / AIL_waveOutClose)
ail_close_all:
    push rbx
    push r12
    sub rsp, 8
    lea rbx, [aud_voices]
    xor r12d, r12d
.v:
    cmp dword [rbx + V_STATUS], 0
    je .n
    mov rdi, rbx
    call aud_free_voice
.n:
    add rbx, V_SIZE
    inc r12d
    cmp r12d, MAX_VOICES
    jb .v
    mov byte [aud_open], 0
    add rsp, 8
    pop r12
    pop rbx
    ret

ail_set_preference:             ; (number, value) -> previous value
    mov ecx, [rdi]
    xor eax, eax
    cmp ecx, N_PREFS
    jae .r
    lea rdx, [aud_prefs]
    mov eax, [rdx + rcx*4]
    mov esi, [rdi + 4]
    mov [rdx + rcx*4], esi
.r:
    ret

; AIL_waveOutOpen(HDIGDRIVER* drv, LPHWAVEOUT* hwo, int device, LPWAVEFORMAT fmt) -> 0 ok
ail_waveOutOpen:
    HENTER
    mov eax, ARG(3)
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    test eax, eax
    jz .log
    movzx esi, word [rax + 2]       ; channels
    mov edx, [rax + 4]              ; rate
    movzx ecx, word [rax + 14]      ; bits
.log:
    lea rdi, [fmt_aud_open]
    xor eax, eax
    call _printf
    call aud_open_device
    mov byte [aud_open], 1
    mov eax, ARG(0)
    mov dword [rax], AUD_DRV
    mov eax, ARG(1)
    test eax, eax
    jz .ok
    mov dword [rax], 0
.ok:
    xor eax, eax
    HRET

ail_waveOutClose:
    sub rsp, 8
    call ail_close_all
    add rsp, 8
    xor eax, eax
    ret

ail_mem_alloc_lock:             ; (size) -> low memory
    mov edi, [rdi]
    xor esi, esi
    jmp heap_alloc

ail_mem_free_lock:
    mov edi, [rdi]
    jmp heap_free

ail_set_digital_master_volume:  ; (drv, 0..127)
    mov eax, [rdi + 4]
    mov [aud_master], eax
    xor eax, eax
    ret

ail_digital_handle_release:     ; (drv): focus lost -> pause the output
    sub rsp, 8
    mov byte [aud_paused], 1
    mov rdi, [aud_stream]
    test rdi, rdi
    jz .r
    call [a_SDL_PauseAudioStreamDevice]
.r:
    add rsp, 8
    mov eax, 1
    ret

ail_digital_handle_reacquire:
    sub rsp, 8
    mov byte [aud_paused], 0
    mov qword [aud_last_ns], 0      ; wall-clock mode: do not catch up the pause
    mov rdi, [aud_stream]
    test rdi, rdi
    jz .r
    call [a_SDL_ResumeAudioStreamDevice]
.r:
    add rsp, 8
    mov eax, 1
    ret

ail_delay:                      ; (60 Hz ticks): sleep, keep the output fed
    HENTER
    mov r12d, ARG(0)
.t:
    test r12d, r12d
    jz .r
    call audio_pump
    mov edi, 16667
    call _usleep
    dec r12d
    jmp .t
.r:
    call audio_pump
    xor eax, eax
    HRET

ail_enumerate_3D_providers:     ; (HPROENUM* next, HPROVIDER* dest, char** name) -> 0: none
    xor eax, eax
    ret

ail_allocate_sample_handle:     ; (drv) -> HSAMPLE
    sub rsp, 8
    xor edi, edi
    call aud_new_voice
    add rsp, 8
    ret

ail_release_sample_handle:
    HENTER
    VOICE 0
    mov rdi, rax
    call aud_free_voice
.bad_handle:
    xor eax, eax
    HRET

ail_init_sample:
    HENTER
    VOICE 0
    mov rdi, rax
    call aud_init_voice
.bad_handle:
    xor eax, eax
    HRET

ail_set_sample_type:            ; (S, format, flags)
    HENTER
    VOICE 0
    mov ecx, ARG(1)
    and ecx, 3
    mov [rax + V_FMT], ecx
    mov ecx, ARG(2)
    and ecx, 1
    mov [rax + V_SIGN], ecx
.bad_handle:
    xor eax, eax
    HRET

ail_set_sample_address:         ; (S, start, len)
    HENTER
    VOICE 0
    mov ecx, ARG(1)
    mov [rax + V_DATA], rcx
    mov ecx, ARG(2)
    mov [rax + V_LEN], ecx
    mov qword [rax + V_POS], 0
.bad_handle:
    xor eax, eax
    HRET

%macro SET_FIELD 2                  ; label, field: (S, value)
%1:
    HENTER
    VOICE 0
    mov ecx, ARG(1)
    mov [rax + %2], ecx
.bad_handle:
    xor eax, eax
    HRET
%endmacro
    SET_FIELD ail_set_sample_playback_rate, V_RATE
    SET_FIELD ail_set_sample_volume, V_VOL
    SET_FIELD ail_set_sample_pan, V_PAN
    SET_FIELD ail_set_sample_loop_count, V_LOOPS
    SET_FIELD ail_set_stream_playback_rate, V_RATE
    SET_FIELD ail_set_stream_volume, V_VOL
    SET_FIELD ail_set_stream_loop_count, V_LOOPS

%macro GET_FIELD 2                  ; label, field: (S) -> value
%1:
    HENTER
    VOICE 0
    mov eax, [rax + %2]
    HRET
.bad_handle:
    xor eax, eax
    HRET
%endmacro
    GET_FIELD ail_sample_status, V_STATUS
    GET_FIELD ail_stream_status, V_STATUS
    GET_FIELD ail_stream_volume, V_VOL
    GET_FIELD ail_stream_playback_rate, V_RATE

ail_set_sample_loop_block:      ; (S, start offset, end offset or -1)
    HENTER
    VOICE 0
    mov ecx, ARG(1)
    mov [rax + V_LSTART], ecx
    mov ecx, ARG(2)
    mov [rax + V_LEND], ecx
.bad_handle:
    xor eax, eax
    HRET

ail_start_sample:
    HENTER
    VOICE 0
    mov r12, rax
    mov rdi, rax
    call aud_start
    cmp dword [aud_starts], 48      ; log the first few
    jae .quiet
    lea rdi, [fmt_aud_start]
    mov esi, ARG(0)
    mov rdx, [r12 + V_DATA]
    mov ecx, [r12 + V_LEN]
    mov r8d, [r12 + V_RATE]
    mov r9d, [r12 + V_VOL]
    sub rsp, 16
    mov eax, [r12 + V_PAN]
    mov [rsp], rax
    xor eax, eax
    call _printf
    add rsp, 16
.quiet:
    inc dword [aud_starts]
.bad_handle:
    xor eax, eax
    HRET

ail_end_sample:
    HENTER
    VOICE 0
    mov dword [rax + V_STATUS], SMP_DONE
.bad_handle:
    xor eax, eax
    HRET

; AIL_open_stream(drv, filename, stream_mem) -> HSTREAM, 0 if the file cannot be played
ail_open_stream:
    HENTER
    mov edi, 1
    call aud_new_voice
    test eax, eax
    jz .r
    mov r12d, eax
    mov edi, eax
    call aud_voice
    mov r13, rax
    mov edi, ARG(1)
    call win_path
    test rax, rax
    jz .fail
    mov rdi, rax
    mov rsi, r13
    call aud_load_wav
    test eax, eax
    jz .fail
    mov dword [r13 + V_STATUS], SMP_STOPPED
    inc dword [aud_streams_opened]
    mov eax, [r13 + V_LEN]          ; ms = len / (rate * bpf / 1000)
    imul rax, rax, 1000
    mov rdi, r13
    push rax
    sub rsp, 8
    call aud_bpf
    add rsp, 8
    mov ecx, eax
    pop rax
    imul ecx, [r13 + V_RATE]
    xor edx, edx
    test ecx, ecx
    jz .msz
    div rcx
.msz:
    lea rdi, [fmt_aud_stream]
    mov esi, ARG(1)
    mov edx, [r13 + V_RATE]
    mov ecx, [r13 + V_FMT]
    mov r8d, eax
    mov r9d, r12d
    xor eax, eax
    call _printf
    mov eax, r12d
    HRET
.fail:
    mov rdi, r13
    call aud_free_voice
    inc dword [aud_stream_misses]
    lea rdi, [aud_last_miss]        ; the menu retries every frame: log a name once
    mov esi, ARG(1)
    call _strcmp
    test eax, eax
    jz .r
    lea rdi, [aud_last_miss]
    mov esi, ARG(1)
    mov edx, 255
    call _strncpy
    lea rdi, [fmt_aud_nostream]
    mov esi, ARG(1)
    xor eax, eax
    call _printf
.r:
    xor eax, eax
    HRET

ail_start_stream:
    HENTER
    VOICE 0
    mov rdi, rax
    call aud_start
.bad_handle:
    xor eax, eax
    HRET

ail_close_stream:
    HENTER
    VOICE 0
    mov rdi, rax
    call aud_free_voice
.bad_handle:
    xor eax, eax
    HRET

; AIL_stream_ms_position(S, S32* total_ms, S32* current_ms)
ail_stream_ms_position:
    HENTER
    VOICE 0
    mov r12, rax
    mov rdi, rax
    call aud_bpf
    mov r13d, eax
    mov eax, [r12 + V_LEN]
    xor edx, edx
    div r13d                        ; total frames
    mov ecx, [r12 + V_RATE]
    test ecx, ecx
    jz .bad_handle
    imul rax, rax, 1000
    xor edx, edx
    div rcx
    mov edx, ARG(1)
    test edx, edx
    jz .cur
    mov [rdx], eax
.cur:
    mov rax, [r12 + V_POS]
    shr rax, 16
    imul rax, rax, 1000
    xor edx, edx
    mov ecx, [r12 + V_RATE]
    div rcx
    mov edx, ARG(2)
    test edx, edx
    jz .bad_handle
    mov [rdx], eax
.bad_handle:
    xor eax, eax
    HRET

ail_set_stream_ms_position:     ; (S, ms)
    HENTER
    VOICE 0
    mov ecx, ARG(1)
    mov edx, [rax + V_RATE]
    imul rcx, rdx
    mov r8, rax
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000
    div rcx
    shl rax, 16
    mov [r8 + V_POS], rax
.bad_handle:
    xor eax, eax
    HRET

section .data
align 8
shimtab_mss32:
    dq s_mss32
    SHIM "_AIL_startup@0", 0, ail_startup
    SHIM "_AIL_shutdown@0", 0, ail_shutdown
    SHIM "_AIL_set_preference@8", 8, ail_set_preference
    SHIM "_AIL_waveOutOpen@16", 16, ail_waveOutOpen
    SHIM "_AIL_waveOutClose@4", 4, ail_waveOutClose
    SHIM "_AIL_mem_alloc_lock@4", 4, ail_mem_alloc_lock
    SHIM "_AIL_mem_free_lock@4", 4, ail_mem_free_lock
    SHIM "_AIL_set_digital_master_volume@8", 8, ail_set_digital_master_volume
    SHIM "_AIL_digital_handle_release@4", 4, ail_digital_handle_release
    SHIM "_AIL_digital_handle_reacquire@4", 4, ail_digital_handle_reacquire
    SHIM "_AIL_delay@4", 4, ail_delay
    SHIM "_AIL_enumerate_3D_providers@12", 12, ail_enumerate_3D_providers
    SHIM "_AIL_allocate_sample_handle@4", 4, ail_allocate_sample_handle
    SHIM "_AIL_release_sample_handle@4", 4, ail_release_sample_handle
    SHIM "_AIL_init_sample@4", 4, ail_init_sample
    SHIM "_AIL_set_sample_type@12", 12, ail_set_sample_type
    SHIM "_AIL_set_sample_address@12", 12, ail_set_sample_address
    SHIM "_AIL_set_sample_playback_rate@8", 8, ail_set_sample_playback_rate
    SHIM "_AIL_set_sample_volume@8", 8, ail_set_sample_volume
    SHIM "_AIL_set_sample_pan@8", 8, ail_set_sample_pan
    SHIM "_AIL_set_sample_loop_count@8", 8, ail_set_sample_loop_count
    SHIM "_AIL_set_sample_loop_block@12", 12, ail_set_sample_loop_block
    SHIM "_AIL_start_sample@4", 4, ail_start_sample
    SHIM "_AIL_end_sample@4", 4, ail_end_sample
    SHIM "_AIL_sample_status@4", 4, ail_sample_status
    SHIM "_AIL_open_stream@12", 12, ail_open_stream
    SHIM "_AIL_close_stream@4", 4, ail_close_stream
    SHIM "_AIL_start_stream@4", 4, ail_start_stream
    SHIM "_AIL_stream_status@4", 4, ail_stream_status
    SHIM "_AIL_set_stream_loop_count@8", 8, ail_set_stream_loop_count
    SHIM "_AIL_set_stream_volume@8", 8, ail_set_stream_volume
    SHIM "_AIL_stream_volume@4", 4, ail_stream_volume
    SHIM "_AIL_set_stream_playback_rate@8", 8, ail_set_stream_playback_rate
    SHIM "_AIL_stream_playback_rate@4", 4, ail_stream_playback_rate
    SHIM "_AIL_stream_ms_position@12", 12, ail_stream_ms_position
    SHIM "_AIL_set_stream_ms_position@8", 8, ail_set_stream_ms_position
    dq 0                            ; the 3D sample API stays on the silent default

section .rodata
s_rb:           db "rb", 0
fmt_aud_open:   db "  [aud] AIL_waveOutOpen(%d ch, %d Hz, %d bit): mixing 22050 Hz stereo s16 on the game thread", 10, 0
fmt_aud_dev:    db "  [aud] SDL audio device stream open (driver %s)", 10, 0
fmt_aud_nodev:  db "  [aud] no SDL audio device (%s): mixing on the wall clock, silent", 10, 0
fmt_aud_start:  db "  [aud] start_sample 0x%x: data 0x%llx len %u rate %u vol %u pan %u", 10, 0
fmt_aud_stream: db "  [aud] open_stream(%s): %u Hz fmt %u, %u ms -> 0x%x", 10, 0
fmt_aud_nostream: db "  [aud] open_stream(%s): missing or unsupported file -> 0 (logged once while it repeats)", 10, 0
fmt_aud_dump:   db "  [aud] --audio-dump %s: %u ms (%llu frames, 22050 Hz stereo s16), %u sample starts, %u streams opened, %u missing", 10, 0
fmt_aud_sec:    db "  [aud]   second %3u: peak %5u (%3u%%)  rms %5u", 10, 0
align 4
wav_header:
    db "RIFF"
    dd 0
    db "WAVEfmt "
    dd 16
    dw 1, 2                         ; PCM, stereo
    dd MIX_RATE, MIX_RATE * 4
    dw 4, 16
    db "data"
    dd 0
ima_index:
    db -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8
align 2
ima_steps:
    dw 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45
    dw 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230
    dw 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963
    dw 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327
    dw 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487
    dw 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767

section .bss
alignb 8
a_SDL_InitSubSystem:        resq 1
a_SDL_OpenAudioDeviceStream: resq 1
a_SDL_ResumeAudioStreamDevice: resq 1
a_SDL_PauseAudioStreamDevice: resq 1
a_SDL_PutAudioStreamData:   resq 1
a_SDL_GetAudioStreamQueued: resq 1
a_SDL_GetCurrentAudioDriver: resq 1
aud_stream:     resq 1          ; SDL_AudioStream*, 0 = no device
aud_dump_path:  resq 1          ; --audio-dump=PATH
aud_dump_file:  resq 1
aud_mixed:      resq 1          ; frames mixed so far
aud_last_ns:    resq 1
aud_credit_ns:  resq 1
aud_sec_sq:     resq 1
aud_acc:        resq MIX_CHUNK * 2
aud_voices:     resb V_SIZE * MAX_VOICES
aud_out:        resw MIX_CHUNK * 2
aud_prefs:      resd N_PREFS
aud_master:     resd 1
aud_starts:     resd 1
aud_streams_opened: resd 1
aud_stream_misses: resd 1
aud_last_miss:  resb 256
aud_sec_frames: resd 1
aud_sec_peak_cur: resd 1
aud_nsec:       resd 1
aud_peaks:      resd MAX_SECONDS
aud_rms:        resd MAX_SECONDS
aud_open:       resb 1
aud_paused:     resb 1
aud_dev_tried:  resb 1
section .text
