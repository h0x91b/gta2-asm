; w32_mss32.asm — the mss32.dll (Miles Sound System 6) import table. The handlers are
; 64-bit host C (host/c/audio.c, docs/win32-shims.md "Audio"): each is an import
; handler uint64_t f(const uint32_t *args), called by host_dispatch like any NASM shim;
; the stdcall argument bytes here are what common32 pops (docs/host-c.md, "Import
; shims in C").

extern _ail_startup, _ail_shutdown, _ail_set_preference, _ail_waveOutOpen
extern _ail_waveOutClose, _ail_mem_alloc_lock, _ail_mem_free_lock, _ail_set_digital_master_volume
extern _ail_digital_handle_release, _ail_digital_handle_reacquire, _ail_delay, _ail_enumerate_3D_providers
extern _ail_allocate_sample_handle, _ail_release_sample_handle, _ail_init_sample, _ail_set_sample_type
extern _ail_set_sample_address, _ail_set_sample_playback_rate, _ail_set_sample_volume, _ail_set_sample_pan
extern _ail_set_sample_loop_count, _ail_set_sample_loop_block, _ail_start_sample, _ail_end_sample
extern _ail_sample_status, _ail_open_stream, _ail_close_stream, _ail_start_stream
extern _ail_stream_status, _ail_set_stream_loop_count, _ail_set_stream_volume, _ail_stream_volume
extern _ail_set_stream_playback_rate, _ail_stream_playback_rate, _ail_stream_ms_position, _ail_set_stream_ms_position

section .data
align 8
shimtab_mss32:
    dq s_mss32
    SHIM "_AIL_startup@0",                     0, _ail_startup
    SHIM "_AIL_shutdown@0",                    0, _ail_shutdown
    SHIM "_AIL_set_preference@8",              8, _ail_set_preference
    SHIM "_AIL_waveOutOpen@16",               16, _ail_waveOutOpen
    SHIM "_AIL_waveOutClose@4",                4, _ail_waveOutClose
    SHIM "_AIL_mem_alloc_lock@4",              4, _ail_mem_alloc_lock
    SHIM "_AIL_mem_free_lock@4",               4, _ail_mem_free_lock
    SHIM "_AIL_set_digital_master_volume@8",   8, _ail_set_digital_master_volume
    SHIM "_AIL_digital_handle_release@4",      4, _ail_digital_handle_release
    SHIM "_AIL_digital_handle_reacquire@4",    4, _ail_digital_handle_reacquire
    SHIM "_AIL_delay@4",                       4, _ail_delay
    SHIM "_AIL_enumerate_3D_providers@12",    12, _ail_enumerate_3D_providers
    SHIM "_AIL_allocate_sample_handle@4",      4, _ail_allocate_sample_handle
    SHIM "_AIL_release_sample_handle@4",       4, _ail_release_sample_handle
    SHIM "_AIL_init_sample@4",                 4, _ail_init_sample
    SHIM "_AIL_set_sample_type@12",           12, _ail_set_sample_type
    SHIM "_AIL_set_sample_address@12",        12, _ail_set_sample_address
    SHIM "_AIL_set_sample_playback_rate@8",    8, _ail_set_sample_playback_rate
    SHIM "_AIL_set_sample_volume@8",           8, _ail_set_sample_volume
    SHIM "_AIL_set_sample_pan@8",              8, _ail_set_sample_pan
    SHIM "_AIL_set_sample_loop_count@8",       8, _ail_set_sample_loop_count
    SHIM "_AIL_set_sample_loop_block@12",     12, _ail_set_sample_loop_block
    SHIM "_AIL_start_sample@4",                4, _ail_start_sample
    SHIM "_AIL_end_sample@4",                  4, _ail_end_sample
    SHIM "_AIL_sample_status@4",               4, _ail_sample_status
    SHIM "_AIL_open_stream@12",               12, _ail_open_stream
    SHIM "_AIL_close_stream@4",                4, _ail_close_stream
    SHIM "_AIL_start_stream@4",                4, _ail_start_stream
    SHIM "_AIL_stream_status@4",               4, _ail_stream_status
    SHIM "_AIL_set_stream_loop_count@8",       8, _ail_set_stream_loop_count
    SHIM "_AIL_set_stream_volume@8",           8, _ail_set_stream_volume
    SHIM "_AIL_stream_volume@4",               4, _ail_stream_volume
    SHIM "_AIL_set_stream_playback_rate@8",    8, _ail_set_stream_playback_rate
    SHIM "_AIL_stream_playback_rate@4",        4, _ail_stream_playback_rate
    SHIM "_AIL_stream_ms_position@12",        12, _ail_stream_ms_position
    SHIM "_AIL_set_stream_ms_position@8",      8, _ail_set_stream_ms_position
    dq 0                            ; the 3D sample API stays on the silent default
section .text
