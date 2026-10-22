/* audio.c — mss32.dll (Miles Sound System 6) on SDL3 audio: the 2D digital sample API,
 * file streams (audio_wav.c) and the driver calls gta2.exe makes. Design and gaps:
 * docs/win32-shims.md, "Audio".
 *
 * How the game uses it (sample manager object at 0x66C950, code 0x4B5F70..0x4B73E0,
 * own analysis of vanilla 11.44): AIL_startup, AIL_waveOutOpen(&drv, 0, -1, 22050 Hz
 * 16-bit stereo), one 8-bit sample (+0x98) and 16 16-bit signed mono samples (+0x58),
 * AIL_mem_alloc_lock(0x5D1420) for the sound bank. Banks are data\audio\<name>.RAW
 * (raw PCM) + .SDT (0x140 entries of 24 bytes: offset, size, rate, ...) read by the
 * game itself; it points samples into the bank with AIL_set_sample_address. Music is
 * AIL_open_stream on data\gtaudio\%d[A].WAV, voices on data\audio\vocals\*.wav.
 * 3D (AIL_enumerate_3D_providers) answers "no providers", so the game stays on 2D.
 *
 * The AIL_* exports are import handlers (docs/host-c.md, "Import shims in C"):
 * uint64_t f(const uint32_t *args), args[0] = the first stdcall argument, listed with
 * their argument bytes in shimtab_mss32 (w32_mss32.asm).
 *
 * Threading: none. Mixing runs on the game's own thread, inside audio_pump (called by
 * pump_sdl each frame and by AIL_delay); it tops an SDL_AudioStream up to MIX_TARGET
 * frames. SDL's device thread only drains that stream (SDL locks it internally), so no
 * game or shim state is ever touched from another thread. Without a device the mixer
 * runs on the wall clock, so --audio-dump works headless too.
 */
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "game.h"
#include "audio.h"

#define SDL_INIT_AUDIO     0x10
#define SDL_AUDIO_S16LE    0x8010
#define SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK 0xFFFFFFFFu

#define MIX_CHUNK   256         /* frames per mixing step */
#define MIX_TARGET  2048        /* frames kept queued for the device (~93 ms) */
#define MIX_MAX     16384       /* most frames one pump may mix (after a long stall) */
#define MAX_SECONDS 7200        /* per-second dump statistics */

#define AUD_DRV     0x00A0D000u /* HDIGDRIVER token (never dereferenced by the game) */
#define AUD_HBASE   0x00A10000u /* HSAMPLE/HSTREAM = AUD_HBASE + 16 * voice index */
#define MAX_VOICES  64
#define N_PREFS     64

/* ---- the NASM host ------------------------------------------------------------------ */

extern void *sdl_lib NASM(sdl_lib);                     /* w32_user32.asm: dlopen'ed SDL3 */
void focus_poll(void) NASM(focus_poll);                 /* w32_user32.asm: -> audio_focus */
uint32_t heap_alloc(uint32_t size, uint32_t flags) NASM(heap_alloc);   /* w32_core.asm */
uint32_t heap_free(uint32_t ptr) NASM(heap_free);
_Noreturn void fail(const char *msg) NASM(fail);        /* loader.asm: FAIL + exit */

uint8_t aud_bg_audio;           /* --bg-audio (loader.asm's flag table): never mute */

/* ---- SDL3 audio, resolved by name ------------------------------------------------------ */

typedef struct { int format, channels, freq; } SDL_AudioSpec;
typedef struct SDL_AudioStream SDL_AudioStream;

static struct {
    _Bool (*InitSubSystem)(uint32_t flags);
    SDL_AudioStream *(*OpenAudioDeviceStream)(uint32_t dev, const SDL_AudioSpec *spec,
                                              void *cb, void *userdata);
    _Bool (*ResumeAudioStreamDevice)(SDL_AudioStream *s);
    _Bool (*PauseAudioStreamDevice)(SDL_AudioStream *s);
    _Bool (*PutAudioStreamData)(SDL_AudioStream *s, const void *buf, int len);
    int (*GetAudioStreamQueued)(SDL_AudioStream *s);
    const char *(*GetCurrentAudioDriver)(void);
    _Bool (*SetAudioStreamGain)(SDL_AudioStream *s, float gain);
    const char *(*GetError)(void);
} sdl;

/* ---- state ------------------------------------------------------------------------------ */

static struct voice voices[MAX_VOICES];
static uint32_t prefs[N_PREFS];
static uint32_t master;
static SDL_AudioStream *stream;         /* 0 = no device */
static uint8_t aud_open, paused, muted, focus_known, dev_tried;
                                        /* paused: the game's AIL_digital_handle_release;
                                           muted: window unfocused (audio_focus) */
static uint64_t last_ns, credit_ns;     /* wall-clock mode */
static int64_t acc[MIX_CHUNK * 2];      /* L,R accumulators */
static int16_t out[MIX_CHUNK * 2];

/* --audio-dump and its statistics */
static const char *dump_path;
static FILE *dump_file;
static uint64_t mixed;                  /* frames mixed so far */
static uint32_t starts, streams_opened, stream_misses;
static char last_miss[256];
static uint32_t sec_frames, sec_peak, nsec;
static uint64_t sec_sq;
static uint32_t peaks[MAX_SECONDS], rms[MAX_SECONDS];

static const uint8_t wav_header[44] = {
    'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ',
    16, 0, 0, 0, 1, 0, 2, 0,                            /* PCM, stereo */
    MIX_RATE & 0xFF, MIX_RATE >> 8, 0, 0,
    (MIX_RATE * 4) & 0xFF, (MIX_RATE * 4) >> 8 & 0xFF, (MIX_RATE * 4) >> 16, 0,
    4, 0, 16, 0, 'd', 'a', 't', 'a', 0, 0, 0, 0
};

static void aud_atexit(void);

/* ---- setup / helpers --------------------------------------------------------------------- */

static void *sym(const char *name)
{
    void *p = dlsym(sdl_lib, name);
    if (!p)
        fail("SDL3 is missing a function the loader needs");
    return p;
}

void setup_audio(void)
{
    sdl.InitSubSystem = sym("SDL_InitSubSystem");
    sdl.OpenAudioDeviceStream = sym("SDL_OpenAudioDeviceStream");
    sdl.ResumeAudioStreamDevice = sym("SDL_ResumeAudioStreamDevice");
    sdl.PauseAudioStreamDevice = sym("SDL_PauseAudioStreamDevice");
    sdl.PutAudioStreamData = sym("SDL_PutAudioStreamData");
    sdl.GetAudioStreamQueued = sym("SDL_GetAudioStreamQueued");
    sdl.GetCurrentAudioDriver = sym("SDL_GetCurrentAudioDriver");
    sdl.SetAudioStreamGain = sym("SDL_SetAudioStreamGain");
    sdl.GetError = sym("SDL_GetError");
    master = 127;
    prefs[2] = 127;                                     /* DIG_DEFAULT_VOLUME */
    if (dump_path)
        atexit(aud_atexit);
}

/* --audio-dump=PATH (loader.asm's argument loop): also write the mixed output as WAV.
 * A placeholder header now, the real one at exit. An unwritable path is ignored. */
void audio_dump_open(const char *path)
{
    static const uint8_t zero[44];
    dump_path = path;
    dump_file = fopen(path, "wb");
    if (dump_file)
        fwrite(zero, 1, sizeof zero, dump_file);
}

/* the voice of a live handle, 0 if it is none */
static struct voice *aud_voice(uint32_t h)
{
    uint32_t i = h - AUD_HBASE;
    if (h < AUD_HBASE || (i & 15) || (i >>= 4) >= MAX_VOICES || !voices[i].status)
        return 0;
    return &voices[i];
}

/* AIL_init_sample defaults: 8-bit mono 11025 Hz, played once */
static void aud_init_voice(struct voice *v)
{
    v->status = SMP_DONE;
    v->fmt = 0;
    v->sign = 0;
    v->rate = 11025;
    v->vol = prefs[2];
    v->pan = 64;
    v->loops = 1;
    v->left = 1;
    v->lstart = 0;
    v->lend = 0xFFFFFFFFu;
    v->pos = 0;
}

/* a free voice for kind (0 sample, 1 stream) -> its handle, 0 if all are in use */
static uint32_t aud_new_voice(uint32_t kind)
{
    for (uint32_t i = 0; i < MAX_VOICES; i++) {
        struct voice *v = &voices[i];
        if (v->status)
            continue;
        v->kind = kind;
        v->data = 0;
        v->buf = 0;
        v->len = 0;
        aud_init_voice(v);
        return AUD_HBASE + 16 * i;
    }
    return 0;
}

static void aud_free_voice(struct voice *v)
{
    v->status = 0;
    free(v->buf);
    v->buf = 0;
}

/* play from the start (AIL_start_sample / AIL_start_stream) */
static void aud_start(struct voice *v)
{
    v->pos = 0;
    v->left = v->loops;
    v->status = SMP_PLAYING;
}

static uint32_t aud_bpf(const struct voice *v)         /* bytes per frame */
{
    return 1u << (v->fmt & 1) << (v->fmt >> 1 & 1);
}

/* ---- the mixer ----------------------------------------------------------------------- */

static int32_t conv8(const struct voice *v, uint8_t b)  /* 8-bit -> 16-bit sample */
{
    return v->sign ? (int8_t)b * 256 : ((int32_t)b - 128) * 256;
}

/* vol * pan side * master, scaled so 127^3 = 32768 (>> 15 later); side = 2 * (pan
 * distance from the far edge), clamped to 127, so pan 64 is both sides full */
static int64_t side_gain(const struct voice *v, uint32_t side)
{
    side *= 2;
    if (side > 127)
        side = 127;
    return (int64_t)(((uint64_t)(uint32_t)(side * v->vol * master) << 15) / 2048383);
}

/* add the voice into acc; nearest-sample resampling in 16.16 */
static void mix_voice(struct voice *v, uint32_t frames)
{
    uint32_t bpf = aud_bpf(v);
    uint32_t end = v->len / bpf;                        /* loop end or the data's end */
    if (v->lend != 0xFFFFFFFFu && v->lend < v->len)
        end = v->lend / bpf;
    uint32_t lstart = v->lstart / bpf;
    uint64_t step = ((uint64_t)(v->rate ? v->rate : MIX_RATE) << 16) / MIX_RATE;
    int64_t gl = side_gain(v, 127 - v->pan), gr = side_gain(v, v->pan);
    uint64_t pos = v->pos;
    for (uint32_t i = 0; i < frames; ) {
        uint32_t fr = (uint32_t)(pos >> 16);
        if (fr >= end) {                                /* past the end: loop or finish */
            if (v->left == 1 || end <= lstart) {        /* last play, or empty loop block */
                v->status = SMP_DONE;
                break;
            }
            if (v->left)
                v->left--;
            pos -= (uint64_t)(end - lstart) << 16;
            continue;
        }
        const uint8_t *p = v->data + fr * bpf;
        int32_t l, r;
        switch (v->fmt) {
        case 1:  l = r = (int16_t)(p[0] | p[1] << 8); break;
        case 2:  l = conv8(v, p[0]); r = conv8(v, p[1]); break;
        case 3:  l = (int16_t)(p[0] | p[1] << 8); r = (int16_t)(p[2] | p[3] << 8); break;
        default: l = r = conv8(v, p[0]); break;
        }
        acc[2 * i] += l * gl;
        acc[2 * i + 1] += r * gr;
        pos += step;
        i++;
    }
    v->pos = pos;
}

/* store the finished second's peak and rms */
static void close_second(void)
{
    if (nsec < MAX_SECONDS) {
        peaks[nsec] = sec_peak;
        rms[nsec] = (uint32_t)(int32_t)sqrt((double)(int64_t)sec_sq / (double)(sec_frames * 2));
        nsec++;
    }
    sec_frames = 0;
    sec_peak = 0;
    sec_sq = 0;
}

/* mix every playing voice (frames <= MIX_CHUNK), hand the result to SDL and the dump,
 * update the per-second statistics */
static void mix_chunk(uint32_t frames)
{
    memset(acc, 0, sizeof acc);
    if (!paused)
        for (int i = 0; i < MAX_VOICES; i++)
            if (voices[i].status == SMP_PLAYING && voices[i].data)
                mix_voice(&voices[i], frames);
    for (uint32_t k = 0; k < frames * 2; k++) {         /* >> 15, clip to int16 */
        int64_t s = acc[k] >> 15;
        if (s > 32767) s = 32767;
        if (s < -32768) s = -32768;
        out[k] = (int16_t)s;
        uint32_t a = (uint32_t)(s < 0 ? -s : s);
        if (a > sec_peak)
            sec_peak = a;
        sec_sq += (uint64_t)(s * s);
        if ((k & 1) && ++sec_frames >= MIX_RATE)
            close_second();
    }
    if (stream)
        sdl.PutAudioStreamData(stream, out, (int)frames * 4);
    if (dump_file)
        fwrite(out, 4, frames, dump_file);
    mixed += frames;
}

/* top the output up. Called by pump_sdl (every frame) and AIL_delay. */
void audio_pump(void)
{
    if (!aud_open)
        return;
    int64_t n;
    if (stream) {
        int q = sdl.GetAudioStreamQueued(stream);
        n = MIX_TARGET - (int64_t)((uint32_t)(q < 0 ? 0 : q) >> 2);
        if (n <= 0 || paused)
            return;
    } else {                                            /* no device: frames due on the wall clock */
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), prev = last_ns;
        last_ns = now;
        if (!prev)
            n = MIX_TARGET;                             /* first pump: prefill */
        else {
            uint64_t el = now - prev + credit_ns;
            uint64_t due = el * MIX_RATE / 1000000000u;
            credit_ns = el - due * 1000000000u / MIX_RATE;
            if (paused)
                return;
            n = (int64_t)due;
        }
    }
    if (n > MIX_MAX)
        n = MIX_MAX;
    while (n > 0) {
        uint32_t c = n > MIX_CHUNK ? MIX_CHUNK : (uint32_t)n;
        n -= c;
        mix_chunk(c);
    }
}

/* device stream gain 0 while muted, 1 otherwise */
static void apply_gain(void)
{
    if (stream)
        sdl.SetAudioStreamGain(stream, muted ? 0.0f : 1.0f);
}

/* SDL audio subsystem + a 22050 Hz stereo s16 device stream (once) */
static void open_device(void)
{
    if (dev_tried)
        return;
    dev_tried = 1;
    SDL_AudioSpec spec = { SDL_AUDIO_S16LE, 2, MIX_RATE };
    if (!sdl.InitSubSystem(SDL_INIT_AUDIO)
        || !(stream = sdl.OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, 0, 0))) {
        printf("  [aud] no SDL audio device (%s): mixing on the wall clock, silent\n", sdl.GetError());
        return;
    }
    sdl.ResumeAudioStreamDevice(stream);
    focus_poll();                       /* initial mute state before anything is mixed */
    apply_gain();                       /* (AIL_delay mixes without an SDL pump) */
    const char *drv = sdl.GetCurrentAudioDriver();
    printf("  [aud] SDL audio device stream open (driver %s)\n", drv ? drv : "");
}

/* audio_focus(1 gained / 0 lost): mute the output while the window is not focused
 * (unless --bg-audio). Only the device stream's gain changes: the mixer keeps running on
 * the device clock, so samples and streams advance and end exactly as if audible and the
 * game sees no difference. Independent of the game's own AIL_digital_handle_release
 * (WM_KILLFOCUS, which the host never sends). Called on every SDL pump with the window's
 * polled focus flag (focus_poll), so the first call sets the initial state: a window
 * that never got focus starts muted. */
void audio_focus(int gained)
{
    if (aud_bg_audio)
        return;
    uint8_t m = !gained;
    if (focus_known && muted == m)
        return;
    muted = m;
    printf(m ? "  [aud] window %s unfocused: output muted (mixer keeps running; --bg-audio keeps it audible)\n"
             : "  [aud] window %s focused: output unmuted\n",
           focus_known ? "now" : "initially");
    focus_known = 1;
    apply_gain();
}

/* finish the --audio-dump WAV and print its per-second levels */
static void aud_atexit(void)
{
    if (!dump_file)
        return;
    if (sec_frames)
        close_second();                                 /* the last, partial second */
    uint8_t h[44];                                      /* the RIFF header, real sizes */
    uint32_t bytes = (uint32_t)mixed * 4, riff = bytes + 36;
    memcpy(h, wav_header, sizeof h);
    memcpy(h + 4, &riff, 4);
    memcpy(h + 40, &bytes, 4);
    fseek(dump_file, 0, SEEK_SET);
    fwrite(h, 1, sizeof h, dump_file);
    fclose(dump_file);
    dump_file = 0;
    printf("  [aud] --audio-dump %s: %u ms (%llu frames, 22050 Hz stereo s16), %u sample starts, %u streams opened, %u missing\n",
           dump_path, (uint32_t)(mixed * 1000 / MIX_RATE), (unsigned long long)mixed,
           starts, streams_opened, stream_misses);
    for (uint32_t i = 0; i < nsec; i++)
        printf("  [aud]   second %3u: peak %5u (%3u%%)  rms %5u\n",
               i, peaks[i], peaks[i] * 100 / 32767, rms[i]);
}

/* ---- AIL_* exports ------------------------------------------------------------------------ */

#define VOICE(h) struct voice *v = aud_voice(h); if (!v) return 0

/* release every voice (AIL_shutdown / AIL_waveOutClose) */
static void close_all(void)
{
    for (int i = 0; i < MAX_VOICES; i++)
        if (voices[i].status)
            aud_free_voice(&voices[i]);
    aud_open = 0;
}

uint64_t ail_startup(const uint32_t *a) { (void)a; return 1; }
uint64_t ail_shutdown(const uint32_t *a) { (void)a; close_all(); return 0; }
uint64_t ail_waveOutClose(const uint32_t *a) { (void)a; close_all(); return 0; }

/* (number, value) -> previous value */
uint64_t ail_set_preference(const uint32_t *a)
{
    if (a[0] >= N_PREFS)
        return 0;
    uint32_t old = prefs[a[0]];
    prefs[a[0]] = a[1];
    return old;
}

/* AIL_waveOutOpen(HDIGDRIVER* drv, LPHWAVEOUT* hwo, int device, LPWAVEFORMAT fmt) -> 0 ok */
uint64_t ail_waveOutOpen(const uint32_t *a)
{
    uint32_t ch = 0, rate = 0, bits = 0;
    if (a[3]) {
        ch = rd16(a[3] + 2);
        rate = rd32(a[3] + 4);
        bits = rd16(a[3] + 14);
    }
    printf("  [aud] AIL_waveOutOpen(%d ch, %d Hz, %d bit): mixing 22050 Hz stereo s16 on the game thread\n",
           ch, rate, bits);
    open_device();
    aud_open = 1;
    wr32(a[0], AUD_DRV);
    if (a[1])
        wr32(a[1], 0);
    return 0;
}

uint64_t ail_mem_alloc_lock(const uint32_t *a) { return heap_alloc(a[0], 0); }  /* low memory */
uint64_t ail_mem_free_lock(const uint32_t *a) { return heap_free(a[0]); }

uint64_t ail_set_digital_master_volume(const uint32_t *a)    /* (drv, 0..127) */
{
    master = a[1];
    return 0;
}

uint64_t ail_digital_handle_release(const uint32_t *a)       /* (drv): focus lost -> pause */
{
    (void)a;
    paused = 1;
    if (stream)
        sdl.PauseAudioStreamDevice(stream);
    return 1;
}

uint64_t ail_digital_handle_reacquire(const uint32_t *a)
{
    (void)a;
    paused = 0;
    last_ns = 0;                        /* wall-clock mode: do not catch up the pause */
    if (stream)
        sdl.ResumeAudioStreamDevice(stream);
    return 1;
}

uint64_t ail_delay(const uint32_t *a)                        /* (60 Hz ticks): sleep, keep the output fed */
{
    for (uint32_t t = a[0]; t; t--) {
        audio_pump();
        usleep(16667);
    }
    audio_pump();
    return 0;
}

/* (HPROENUM* next, HPROVIDER* dest, char** name) -> 0: no providers */
uint64_t ail_enumerate_3D_providers(const uint32_t *a) { (void)a; return 0; }

uint64_t ail_allocate_sample_handle(const uint32_t *a) { (void)a; return aud_new_voice(0); }

uint64_t ail_release_sample_handle(const uint32_t *a)
{
    VOICE(a[0]);
    aud_free_voice(v);
    return 0;
}

uint64_t ail_init_sample(const uint32_t *a)
{
    VOICE(a[0]);
    aud_init_voice(v);
    return 0;
}

uint64_t ail_set_sample_type(const uint32_t *a)              /* (S, format, flags) */
{
    VOICE(a[0]);
    v->fmt = a[1] & 3;
    v->sign = a[2] & 1;
    return 0;
}

uint64_t ail_set_sample_address(const uint32_t *a)           /* (S, start, len) */
{
    VOICE(a[0]);
    v->data = (const uint8_t *)(uintptr_t)a[1];
    v->len = a[2];
    v->pos = 0;
    return 0;
}

#define SET_FIELD(name, field) \
    uint64_t name(const uint32_t *a) { VOICE(a[0]); v->field = a[1]; return 0; }
SET_FIELD(ail_set_sample_playback_rate, rate)
SET_FIELD(ail_set_sample_volume, vol)
SET_FIELD(ail_set_sample_pan, pan)
SET_FIELD(ail_set_sample_loop_count, loops)
SET_FIELD(ail_set_stream_playback_rate, rate)
SET_FIELD(ail_set_stream_volume, vol)
SET_FIELD(ail_set_stream_loop_count, loops)

#define GET_FIELD(name, field) \
    uint64_t name(const uint32_t *a) { VOICE(a[0]); return v->field; }
GET_FIELD(ail_sample_status, status)
GET_FIELD(ail_stream_status, status)
GET_FIELD(ail_stream_volume, vol)
GET_FIELD(ail_stream_playback_rate, rate)

uint64_t ail_set_sample_loop_block(const uint32_t *a)        /* (S, start offset, end offset or -1) */
{
    VOICE(a[0]);
    v->lstart = a[1];
    v->lend = a[2];
    return 0;
}

uint64_t ail_start_sample(const uint32_t *a)
{
    VOICE(a[0]);
    aud_start(v);
    if (starts < 48)                                    /* log the first few */
        printf("  [aud] start_sample 0x%x: data 0x%llx len %u rate %u vol %u pan %u\n",
               a[0], (unsigned long long)(uintptr_t)v->data, v->len, v->rate, v->vol, v->pan);
    starts++;
    return 0;
}

uint64_t ail_end_sample(const uint32_t *a)
{
    VOICE(a[0]);
    v->status = SMP_DONE;
    return 0;
}

/* AIL_open_stream(drv, filename, stream_mem) -> HSTREAM, 0 if the file cannot be played */
uint64_t ail_open_stream(const uint32_t *a)
{
    const char *name = (const char *)(uintptr_t)a[1];
    uint32_t h = aud_new_voice(1);
    if (!h)
        return 0;
    struct voice *v = aud_voice(h);
    if (!aud_load_wav(name, v)) {
        aud_free_voice(v);
        stream_misses++;
        if (strcmp(last_miss, name)) {                  /* the menu retries every frame: log a name once */
            strncpy(last_miss, name, 255);
            printf("  [aud] open_stream(%s): missing or unsupported file -> 0 (logged once while it repeats)\n", name);
        }
        return 0;
    }
    v->status = SMP_STOPPED;
    streams_opened++;
    uint64_t ms = (uint64_t)v->len * 1000, per = (uint32_t)(aud_bpf(v) * v->rate);
    if (per)
        ms /= per;
    printf("  [aud] open_stream(%s): %u Hz fmt %u, %u ms -> 0x%x\n",
           name, v->rate, v->fmt, (uint32_t)ms, h);
    return h;
}

uint64_t ail_start_stream(const uint32_t *a)
{
    VOICE(a[0]);
    aud_start(v);
    return 0;
}

uint64_t ail_close_stream(const uint32_t *a)
{
    VOICE(a[0]);
    aud_free_voice(v);
    return 0;
}

/* AIL_stream_ms_position(S, S32* total_ms, S32* current_ms) */
uint64_t ail_stream_ms_position(const uint32_t *a)
{
    VOICE(a[0]);
    if (!v->rate)
        return 0;
    uint64_t total = (uint64_t)(v->len / aud_bpf(v)) * 1000 / v->rate;
    if (a[1])
        wr32(a[1], (uint32_t)total);
    if (a[2])
        wr32(a[2], (uint32_t)((v->pos >> 16) * 1000 / v->rate));
    return 0;
}

uint64_t ail_set_stream_ms_position(const uint32_t *a)       /* (S, ms) */
{
    VOICE(a[0]);
    v->pos = ((uint64_t)a[1] * v->rate / 1000) << 16;
    return 0;
}
