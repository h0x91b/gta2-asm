/* audio.h — what audio.c (mss32 on SDL3) and audio_wav.c (WAV / IMA ADPCM) share.
 * Design and gaps: docs/win32-shims.md, "Audio". */
#ifndef AUDIO_H
#define AUDIO_H

#include <stdint.h>

#define MIX_RATE    22050       /* what the game asks waveOutOpen for (0x5622) */

/* MSS sample/stream status values */
#define SMP_FREE    1
#define SMP_DONE    2
#define SMP_PLAYING 4
#define SMP_STOPPED 8

/* One per HSAMPLE or HSTREAM (host memory). */
struct voice {
    uint32_t status;            /* 0 = unused, else SMP_* */
    uint32_t kind;              /* 0 sample, 1 stream */
    const uint8_t *data;        /* PCM: game memory for samples, host buffer for streams */
    uint32_t len;               /* bytes */
    uint32_t fmt;               /* bit 0 = 16-bit, bit 1 = stereo (MSS DIG_F_*) */
    uint32_t sign;              /* DIG_PCM_SIGN: 8-bit data is signed */
    uint32_t rate;
    uint32_t vol;               /* 0..127 */
    uint32_t pan;               /* 0..127, 64 = centre */
    uint32_t loops;             /* loop count: 0 = forever, 1 = once, n = n times */
    uint32_t lstart;            /* loop block, byte offsets; end -1 = end of data */
    uint32_t lend;
    uint32_t left;              /* plays left in the current start (0 = forever) */
    uint64_t pos;               /* frame position << 16 */
    void *buf;                  /* stream: malloc'd buffer to free */
};

/* Fill data/len/fmt/rate/buf from a WAV (PCM 8/16-bit, or IMA ADPCM decoded to 16-bit
 * up front). 1 ok, 0 unreadable or unsupported. */
int aud_load_wav(const char *path, struct voice *v);

#endif
