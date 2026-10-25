/* text_probe.c — gta2ctl `text`: the host side of the glyph-hook RE probe (c32/text_probe.c,
 * docs/re/fonts-localization.md). Switches the C32 detours on and off, sets the glyph swap and
 * dumps the call sites they recorded.
 */
#include <stdlib.h>
#include <string.h>
#include "game.h"
#include "ctl.h"

void *c32_find(const char *name);       /* c32_host.c */

struct tp_site {                        /* = c32/text_probe.c */
    uint32_t ret;
    uint16_t fn, font, lo, hi;
    uint32_t count;
};

static const char *fn_name[] = { "?", "glyph_id", "glyph_width", "to_upper" };

/* gta2ctl text on|off|summary|swap FROM TO|noswap (docs/gta2ctl.md) */
const char *tp_ctl(jbuf *b, int argc, char **argv)
{
    uint8_t *on = c32_find("tp_on");
    uint16_t *from = c32_find("tp_swap_from"), *to = c32_find("tp_swap_to");
    uint32_t *n = c32_find("tp_n"), *dropped = c32_find("tp_dropped");
    const struct tp_site *sites = c32_find("tp_sites");
    const char *sub = argc >= 2 ? argv[1] : "summary";
    if (!on || !from || !to || !n || !dropped || !sites)
        return "text: the C32 image has no text probe";
    if (!strcmp(sub, "on") || !strcmp(sub, "off")) {
        *on = !strcmp(sub, "on");
        if (*on)
            *n = *dropped = 0;
    } else if (!strcmp(sub, "swap")) {
        if (argc < 4)
            return "usage: text swap FROM TO (glyph offsets = char code - 0x21)";
        *to = (uint16_t)strtoul(argv[3], 0, 0);
        *from = (uint16_t)strtoul(argv[2], 0, 0);
    } else if (!strcmp(sub, "noswap")) {
        *from = 0xFFFF;
    } else if (strcmp(sub, "summary")) {
        return "usage: text on|off|summary|swap FROM TO|noswap";
    }
    jb_printf(b, ",\"on\":%s,\"swap\":", *on ? "true" : "false");
    if (*from == 0xFFFF)
        jb_printf(b, "null");
    else
        jb_printf(b, "[%u,%u]", *from, *to);
    jb_printf(b, ",\"dropped\":%u,\"sites\":[", *dropped);
    for (uint32_t i = 0; i < *n && i < 128; i++) {
        const struct tp_site *s = &sites[i];
        jb_printf(b, "%s{\"fn\":\"%s\",\"ret\":\"0x%x\",\"font\":%u,\"lo\":\"0x%x\",\"hi\":\"0x%x\","
                  "\"count\":%u}", i ? "," : "", s->fn < 4 ? fn_name[s->fn] : "?", s->ret, s->font,
                  s->lo, s->hi, s->count);
        if (b->len > sizeof b->buf - 256)
            break;
    }
    jb_printf(b, "]");
    return 0;
}
