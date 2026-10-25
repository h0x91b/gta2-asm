/* text_probe.c — RE probe for the Russian glyph hooks (docs/re/fonts-localization.md option 2):
 * detours on the three functions the plan hooks, recording who calls them with which values,
 * and an optional glyph swap (every use of glyph offset A draws and measures glyph B) to see on
 * screen whether they are the only seam. gta2ctl `text` (host/c/text_probe.c) drives it; off it
 * costs one byte test per call.
 *
 * Seams (Seq 27, disassembly):
 *   StyleData_GetFontGlyphSpriteId 0x4BF550, thiscall(StyleData*, font, glyph), RET 8:
 *     fontBases[font] + glyph, glyph = code - 0x21 (gxt.md §6)
 *   StyleData_GetFontGlyphWidth 0x4BF570, thiscall(StyleData*, ushort *font, ushort *code), RET 8:
 *     16 / 32 for the kanji fonts, else the width of sprite fontBases[*font] + *code - 0x21 (the
 *     char code itself, not the glyph offset: index [base + code] * 8 - 0x108, Seq 27 R1)
 *   LocaleSettings_ToUpperChar 0x4C21A0, thiscall(LocaleSettings*, code), RET 4: per-language
 */
#include "c32.h"

typedef uint32_t (G2_THISCALL *glyph_id_fn)(void *self, uint32_t font, uint32_t glyph);
typedef uint32_t (G2_THISCALL *glyph_w_fn)(void *self, uint16_t *font, uint16_t *code);
typedef uint32_t (G2_THISCALL *upper_fn)(void *self, uint32_t code);
static glyph_id_fn GetFontGlyphSpriteId;
static glyph_w_fn GetFontGlyphWidth;
static upper_fn ToUpperChar;

/* host/c/text_probe.c reads these by name (same layout there) */
#define TP_SITES 128
struct tp_site {
    uint32_t ret;                       /* caller's return address */
    uint16_t fn, font;                  /* 1 glyph id, 2 width, 3 upper; font (0 for upper) */
    uint16_t lo, hi;                    /* range seen: glyph offset (glyph id), char code (others) */
    uint32_t count;
};
uint8_t tp_on;
uint16_t tp_swap_from = 0xFFFF, tp_swap_to;     /* glyph offsets; 0xFFFF = no swap */
uint32_t tp_n, tp_dropped;
struct tp_site tp_sites[TP_SITES];
C32_EXPORT(tp_on);
C32_EXPORT(tp_swap_from);
C32_EXPORT(tp_swap_to);
C32_EXPORT(tp_n);
C32_EXPORT(tp_dropped);
C32_EXPORT(tp_sites);

static void record(uint32_t ret, unsigned fn, unsigned font, unsigned v)
{
    for (uint32_t i = 0; i < tp_n; i++) {
        struct tp_site *s = &tp_sites[i];
        if (s->ret == ret && s->fn == fn && s->font == font) {
            if (v < s->lo)
                s->lo = (uint16_t)v;
            if (v > s->hi)
                s->hi = (uint16_t)v;
            s->count++;
            return;
        }
    }
    if (tp_n >= TP_SITES) {
        tp_dropped++;
        return;
    }
    tp_sites[tp_n++] = (struct tp_site){ ret, (uint16_t)fn, (uint16_t)font, (uint16_t)v,
                                         (uint16_t)v, 1 };
}

static uint32_t G2_THISCALL hk_glyph_id(void *self, uint32_t font, uint32_t glyph)
{
    if (tp_on) {
        record((uint32_t)__builtin_return_address(0), 1, font & 0xFFFF, glyph & 0xFFFF);
        if ((glyph & 0xFFFF) == tp_swap_from)
            glyph = tp_swap_to;
    }
    return GetFontGlyphSpriteId(self, font, glyph);
}

static uint32_t G2_THISCALL hk_glyph_w(void *self, uint16_t *font, uint16_t *code)
{
    if (tp_on) {
        record((uint32_t)__builtin_return_address(0), 2, *font, *code);
        if (tp_swap_from != 0xFFFF && *code == tp_swap_from + 0x21) {
            uint16_t c = (uint16_t)(tp_swap_to + 0x21);
            return GetFontGlyphWidth(self, font, &c);
        }
    }
    return GetFontGlyphWidth(self, font, code);
}

static uint32_t G2_THISCALL hk_upper(void *self, uint32_t code)
{
    if (tp_on)
        record((uint32_t)__builtin_return_address(0), 3, 0, code & 0xFFFF);
    return ToUpperChar(self, code);
}

static void text_probe_init(void)
{
    static const uint8_t id[] = { 0x8B, 0x44, 0x24, 0x04, 0x8B, 0x49, 0x1C };   /* mov eax,[esp+4]; mov ecx,[ecx+1Ch] */
    static const uint8_t w[] = { 0x8B, 0x44, 0x24, 0x04, 0x66, 0x8B, 0x00 };    /* mov eax,[esp+4]; mov ax,[eax] */
    static const uint8_t up[] = { 0x0F, 0xBE, 0x41, 0x10, 0x8D, 0x48, 0x9B };   /* movsx eax,[ecx+10h]; lea ecx,[eax-65h] */
    GetFontGlyphSpriteId = (glyph_id_fn)c32_detour(0x4BF550, id, sizeof id, (void *)hk_glyph_id);
    GetFontGlyphWidth = (glyph_w_fn)c32_detour(0x4BF570, w, sizeof w, (void *)hk_glyph_w);
    ToUpperChar = (upper_fn)c32_detour(0x4C21A0, up, sizeof up, (void *)hk_upper);
}
C32_INIT(text_probe_init);
