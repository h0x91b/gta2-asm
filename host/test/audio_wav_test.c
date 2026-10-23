/* audio_wav_test.c — host test of the mss32 stream loader (host/c/audio_wav.c), without
 * the loader: vfs_load is a stub that hands out the synthetic WAV under test. Checks the
 * chunk walk (odd-sized chunk padding, a data chunk longer than the file), PCM formats and
 * the IMA ADPCM decoder (nibble order, stereo interleave, a short last block) against
 * values worked out by hand from the IMA tables. `host/build.sh --test`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../c/game.h"
#include "../c/audio.h"

/* ---- stub ------------------------------------------------------------------------------ */

static const uint8_t *file;
static size_t file_len;

struct vfs_file { uint8_t *data; uint64_t size; };
struct vfs_file vfs_load(const char *path) NASM(vfs_load);
struct vfs_file vfs_load(const char *path)
{
    (void)path;
    struct vfs_file f = { 0, 0 };
    if (!file)
        return f;
    f.data = calloc(1, file_len + 16);          /* +16 bytes of slack, like c/vfs.c */
    memcpy(f.data, file, file_len);
    f.size = file_len;
    return f;
}

/* ---- WAV builder ------------------------------------------------------------------------ */

static uint8_t wav[256];
static size_t wl;

static void put16(uint32_t v) { wav[wl++] = v & 0xFF; wav[wl++] = v >> 8 & 0xFF; }
static void put32(uint32_t v) { put16(v & 0xFFFF); put16(v >> 16); }
static void tag(const char *t) { memcpy(wav + wl, t, 4); wl += 4; }

/* RIFF/WAVE + fmt (16 bytes) + an odd 3-byte LIST chunk (padded) + data header */
static void begin(uint32_t fmt_tag, uint32_t ch, uint32_t rate, uint32_t align, uint32_t bits,
                  uint32_t data_size)
{
    wl = 0;
    tag("RIFF"); put32(0); tag("WAVE");
    tag("fmt "); put32(16);
    put16(fmt_tag); put16(ch); put32(rate); put32(rate * align); put16(align); put16(bits);
    tag("LIST"); put32(3); wav[wl++] = 'a'; wav[wl++] = 'b'; wav[wl++] = 'c'; wav[wl++] = 0;
    tag("data"); put32(data_size);
}

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static int load(struct voice *v)
{
    memset(v, 0, sizeof *v);
    file = wav;
    file_len = wl;
    return aud_load_wav("data\\test.wav", v);
}

int main(void)
{
    struct voice v;

    /* PCM s16 stereo, data chunk claims more than the file has -> clamped */
    begin(1, 2, 22050, 4, 16, 1000);
    for (int i = 0; i < 4; i++)
        put32(0x00010000u * (uint32_t)i + (uint32_t)i);
    check(load(&v) == 1, "pcm16 stereo loads");
    check(v.fmt == 3 && v.rate == 22050 && v.sign == 0, "pcm16 stereo fmt/rate");
    check(v.len == 16, "data chunk clamped to the file");
    check(v.data == (uint8_t *)v.buf + (wl - 16), "pcm data points into the file buffer");
    free(v.buf);

    /* PCM u8 mono */
    begin(1, 1, 11025, 1, 8, 3);
    wav[wl++] = 0x80; wav[wl++] = 0xFF; wav[wl++] = 0x00;
    check(load(&v) == 1 && v.fmt == 0 && v.len == 3 && v.rate == 11025, "pcm8 mono");
    free(v.buf);

    /* rejected: float, 3 channels, 24-bit PCM, not RIFF, no file */
    begin(3, 1, 22050, 4, 32, 0);
    check(load(&v) == 0, "float rejected");
    begin(1, 3, 22050, 6, 16, 0);
    check(load(&v) == 0, "3 channels rejected");
    begin(1, 1, 22050, 3, 24, 0);
    check(load(&v) == 0, "24-bit rejected");
    begin(1, 1, 22050, 2, 16, 0);
    memcpy(wav, "RIFX", 4);
    check(load(&v) == 0, "not RIFF rejected");
    file = 0;
    check(aud_load_wav("missing.wav", &v) == 0, "missing file");

    /* IMA ADPCM stereo, block align 16 (9 samples per block) + a 12-byte last block (5).
     * Left: predictor 0, index 0, first data byte 0x97 = nibbles 7 then 9, then zeros:
     *   7: diff 0+7+3+1 = 11 -> 11, index 8;  9: step 16, diff 2+4 = 6 -> 5, index 7;
     *   0: steps 14,13,12,11,10,9 each add 1 -> 6 7 8 9 10 11.
     * Right: predictor 100, index 0, zeros: step 7, diff 0 -> 100 throughout. */
    begin(0x11, 2, 22050, 16, 4, 28);
    static const uint8_t blk[16] = { 0, 0, 0, 0, 100, 0, 0, 0, 0x97, 0, 0, 0, 0, 0, 0, 0 };
    memcpy(wav + wl, blk, 16); wl += 16;
    memcpy(wav + wl, blk, 12); wl += 12;   /* last block: 4 data bytes = the left run only;
                                              the right one is read from the +16 slack (zeros),
                                              as in the NASM original */
    check(load(&v) == 1, "ima stereo loads");
    check(v.fmt == 3 && v.rate == 22050 && v.data == v.buf, "ima -> s16 stereo, own buffer");
    check(v.len == (9 + 5) * 2 * 2, "ima length: 9 + 5 frames");
    static const int16_t want_l[14] = { 0, 11, 5, 6, 7, 8, 9, 10, 11, 0, 11, 5, 6, 7 };
    const int16_t *s = (const int16_t *)v.data;
    int ok = v.len == sizeof want_l * 2;
    for (int i = 0; ok && i < 14; i++) {
        if (s[2 * i] != want_l[i] || s[2 * i + 1] != 100) {
            printf("  frame %d: got %d,%d want %d,100\n", i, s[2 * i], s[2 * i + 1], want_l[i]);
            ok = 0;
        }
    }
    check(ok, "ima samples");
    free(v.buf);

    printf("audio_wav_test: %s (%d failure(s))\n", failures ? "FAIL" : "PASS", failures);
    return failures != 0;
}
