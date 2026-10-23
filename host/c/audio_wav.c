/* audio_wav.c — WAV files for mss32 streams (AIL_open_stream): PCM 8/16-bit as is, IMA
 * ADPCM decoded to s16 up front (the files are small). Read through the VFS (overlay,
 * then data.pak), like every other game file. */
#include <stdlib.h>
#include <string.h>

#include "game.h"
#include "audio.h"
#include "vfs.h"                    /* vfs_load: a whole game file, overlay then pak */


static const int8_t ima_index[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8
};
static const uint16_t ima_steps[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
    253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
    1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
    3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
    12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

/* One IMA ADPCM block, Microsoft layout: per-channel 4-byte headers (predictor, step
 * index), then 4-byte runs of 8 nibbles per channel, low nibble first. */
static void ima_block(const uint8_t *blk, int16_t *out, uint32_t ch, uint32_t samples)
{
    for (uint32_t c = 0; c < ch; c++) {
        int32_t pred = (int16_t)le16(blk + c * 4);
        uint32_t idx = blk[c * 4 + 2];
        if (idx > 88)
            idx = 88;
        out[c] = (int16_t)pred;
        for (uint32_t s = 1; s < samples; s++) {
            uint32_t k = s - 1;
            uint32_t nib = blk[4 * ((k >> 3) * ch + c) + 4 * ch + ((k & 7) >> 1)];
            if (k & 1)
                nib >>= 4;
            nib &= 15;
            uint32_t step = ima_steps[idx];
            int32_t diff = step >> 3;
            if (nib & 4) diff += step;
            if (nib & 2) diff += step >> 1;
            if (nib & 1) diff += step >> 2;
            pred += (nib & 8) ? -diff : diff;
            if (pred > 32767) pred = 32767;
            if (pred < -32768) pred = -32768;
            int32_t ni = (int32_t)idx + ima_index[nib];
            idx = ni < 0 ? 0 : ni > 88 ? 88 : (uint32_t)ni;
            out[s * ch + c] = (int16_t)pred;
        }
    }
}

int aud_load_wav(const char *path, struct voice *v)
{
    struct vfs_file f = vfs_load(path);
    uint8_t *b = f.data;
    if (!b)
        return 0;
    if (f.size < 12 || memcmp(b, "RIFF", 4) || memcmp(b + 8, "WAVE", 4))
        goto bad;
    /* walk the chunks (word-aligned); the data chunk is clamped to the file */
    const uint8_t *fmt = 0, *data = 0;
    uint32_t dsize = 0;
    for (uint64_t c = 12; c + 8 <= f.size; ) {
        uint64_t csz = le32(b + c + 4);
        if (!memcmp(b + c, "fmt ", 4))
            fmt = b + c + 8;
        if (!memcmp(b + c, "data", 4)) {
            data = b + c + 8;
            if (csz > f.size - c - 8)
                csz = f.size - c - 8;
            dsize = (uint32_t)csz;
        }
        c = (c + csz + 9) & ~(uint64_t)1;
    }
    if (!fmt || !data)
        goto bad;
    uint32_t ch = le16(fmt + 2);
    if (ch < 1 || ch > 2)
        goto bad;
    v->rate = le32(fmt + 4);
    uint32_t tag = le16(fmt), bits = le16(fmt + 14);
    if (tag == 1) {                                     /* PCM */
        if (bits != 8 && bits != 16)
            goto bad;
        v->fmt = (bits == 16) | (ch == 2 ? 2 : 0);
        v->sign = 0;                                    /* 8-bit WAV is unsigned */
        v->data = data;
        v->len = dsize;
        v->buf = b;
        return 1;
    }
    if (tag != 0x11 || bits != 4)                       /* IMA ADPCM */
        goto bad;
    uint32_t align = le16(fmt + 12), hdr = ch * 4;
    if (align <= hdr)
        goto bad;
    /* worst case output: every block full -> (blocks + 1) * spb * ch * 2 */
    uint32_t spb = (align - hdr) * 2 / ch + 1;
    int16_t *out = malloc((uint64_t)((dsize / align + 1) * spb * ch) * 2), *w = out;
    for (uint32_t left = dsize; left > hdr; ) {
        uint32_t n = left < align ? left : align;
        uint32_t samples = (n - hdr) * 2 / ch + 1;
        ima_block(data, w, ch, samples);
        w += samples * ch;
        data += n;
        left -= n;
    }
    free(b);
    v->data = (const uint8_t *)out;
    v->buf = out;
    v->len = (uint32_t)((uint8_t *)w - (uint8_t *)out);
    v->fmt = ch == 2 ? 3 : 1;
    return 1;
bad:
    free(b);
    return 0;
}
