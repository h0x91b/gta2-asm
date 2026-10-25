/* sprite_probe.c — the host half of the HD-sprite RE probe (c32/sprite_probe.c,
 * docs/re/sprites-hd.md). While gta2ctl has it on, every textured gbh_DrawQuad issued
 * inside Sprite_Draw is paired with the sprite key the C32 detour published: key ->
 * (texture size, hash of its 8-bit pixels and palette id). A key that ever comes with
 * other pixels is a conflict. Peds also record (graphicType, anim, animFrame, walkSubMode,
 * armed) -> sprite id, to check H3's frame table live. gta2ctl `sprites` reads it all.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "game.h"
#include "ctl.h"
#include "../c32/c32_abi.h"

void *c32_find(const char *name);       /* c32_host.c */

#define PASS_SHADOW 0
#define PASS_BODY   1
#define PASS_LIGHT  2                   /* the second non-shadow quad of a car */
#define F_SHADOW    0x2180              /* Sprite_Draw's shadow quad flags (H3) */

#define MAX_KEYS 16384                  /* open addressing, power of two */
#define MAX_PEDK 4096
#define MAX_CONFLICTS 16
#define PED_BLOCK 158                   /* frames per graphicType (H3) */

struct key {
    uint16_t type, id, kind, remap;
    uint32_t deltas;
    uint8_t shrink, pass, owner, used;
};
struct kent {
    struct key k;
    uint32_t w, h, hash, count, conflicts;
};
struct pkey {                           /* a ped's animation state */
    uint8_t graphic, anim, frame, walk, armed, used;
};
struct pent {
    struct pkey k;
    uint16_t id, id2;                   /* first sprite id seen, another one (0xFFFF none) */
    uint32_t count;
};
struct conflict {
    struct key k;
    uint32_t w0, h0, hash0, w1, h1, hash1;
};

uint8_t sp_enabled;                     /* renderer_gbh.c tests it before calling sp_quad */
static uint8_t *c32_on;
static const struct c32_sprite_tag *tag;
static struct kent keys[MAX_KEYS];
static struct pent pkeys[MAX_PEDK];
static struct conflict conflicts[MAX_CONFLICTS];
static uint32_t n_keys, n_pkeys, n_conflicts, n_conflict_draws, n_full, n_pfull;
static uint32_t n_tagged, n_untagged, n_sprites, n_ped_block_bad, last_seq, quad_in_draw;
static uint32_t start_frame;
static uint8_t ped_off_seen[3][PED_BLOCK];

static uint32_t fnv(uint32_t h, const void *p, size_t n)
{
    const uint8_t *s = p;
    while (n--)
        h = (h ^ *s++) * 16777619u;
    return h;
}

static uint32_t key_hash(const struct key *k)
{
    struct key c = *k;
    c.used = 0;
    return fnv(2166136261u, &c, sizeof c);
}

static void reset(void)
{
    memset(keys, 0, sizeof keys);
    memset(pkeys, 0, sizeof pkeys);
    memset(ped_off_seen, 0, sizeof ped_off_seen);
    n_keys = n_pkeys = n_conflicts = n_conflict_draws = n_full = n_pfull = 0;
    n_tagged = n_untagged = n_sprites = n_ped_block_bad = quad_in_draw = 0;
    start_frame = r_frames;
}

static int bind(void)
{
    if (!c32_on) {
        c32_on = c32_find("sp_on");
        tag = c32_find("sp_tag");
    }
    return c32_on && tag;
}

static void ped_record(const struct c32_sprite_tag *t)
{
    struct pkey k = { t->graphic, t->anim, t->anim_frame, t->walk_sub, t->armed, 1 };
    uint32_t base = t->graphic == 2 ? 2 * PED_BLOCK : t->graphic == 0 ? 0 : PED_BLOCK;
    if (t->id < base || t->id >= base + PED_BLOCK)
        n_ped_block_bad++;
    else
        ped_off_seen[base / PED_BLOCK][t->id - base] = 1;
    uint32_t i = fnv(2166136261u, &k, sizeof k) & (MAX_PEDK - 1);
    for (uint32_t probe = 0; probe < MAX_PEDK; probe++, i = (i + 1) & (MAX_PEDK - 1)) {
        struct pent *e = &pkeys[i];
        if (!e->k.used) {
            if (n_pkeys >= MAX_PEDK / 2) {
                n_pfull++;
                return;
            }
            e->k = k;
            e->id = t->id;
            e->id2 = 0xFFFF;
            e->count = 1;
            n_pkeys++;
            return;
        }
        if (!memcmp(&e->k, &k, sizeof k)) {
            e->count++;
            if (t->id != e->id && e->id2 == 0xFFFF)
                e->id2 = t->id;
            return;
        }
    }
}

/* every gbh_DrawQuad with a texture: pixels = 8 bpp, pitch 256 */
void sp_quad(uint32_t flags, gptr tex, uint32_t w, uint32_t h, gptr pixels, uint32_t pal)
{
    if (!bind() || !tag->active) {
        n_untagged++;
        return;
    }
    const struct c32_sprite_tag *t = tag;
    if (t->seq != last_seq) {           /* the first quad of this Sprite_Draw */
        last_seq = t->seq;
        quad_in_draw = 0;
        n_sprites++;
        if (t->owner == SP_OWNER_PED && t->type == 3)
            ped_record(t);
    }
    n_tagged++;
    struct key k = { t->type, t->id, t->kind, t->remap, t->deltas, t->shrink, 0, t->owner, 1 };
    if (flags == F_SHADOW)
        k.pass = PASS_SHADOW;
    else
        k.pass = quad_in_draw++ ? PASS_LIGHT : PASS_BODY;
    if (k.pass == PASS_SHADOW)
        k.pass = PASS_BODY;             /* same texture as the body (H3): check it as one */
    uint32_t hash = 2166136261u;
    for (uint32_t y = 0; y < h && y < 256; y++)
        hash = fnv(hash, (const void *)(uintptr_t)(pixels + 256 * y), w > 256 ? 256 : w);
    hash = fnv(hash, &pal, sizeof pal);
    (void)tex;
    uint32_t i = key_hash(&k) & (MAX_KEYS - 1);
    for (uint32_t probe = 0; probe < MAX_KEYS; probe++, i = (i + 1) & (MAX_KEYS - 1)) {
        struct kent *e = &keys[i];
        if (!e->k.used) {
            if (n_keys >= MAX_KEYS / 2) {
                n_full++;
                return;
            }
            *e = (struct kent){ .k = k, .w = w, .h = h, .hash = hash, .count = 1 };
            n_keys++;
            return;
        }
        if (memcmp(&e->k, &k, sizeof k))
            continue;
        e->count++;
        if (e->hash != hash || e->w != w || e->h != h) {
            n_conflict_draws++;
            if (!e->conflicts++ && n_conflicts < MAX_CONFLICTS)
                conflicts[n_conflicts++] = (struct conflict){ k, e->w, e->h, e->hash, w, h, hash };
        }
        return;
    }
}

static void key_json(jbuf *b, const struct key *k)
{
    jb_printf(b, "\"type\":%u,\"id\":%u,\"kind\":%u,\"remap\":%u,\"deltas\":\"0x%x\",\"shrink\":%u,"
              "\"pass\":\"%s\",\"owner\":\"%s\"", k->type, k->id, k->kind, k->remap, k->deltas,
              k->shrink, k->pass == PASS_LIGHT ? "light" : "body",
              k->owner == SP_OWNER_CAR ? "car" : k->owner == SP_OWNER_PED ? "ped" : "other");
}

/* gta2ctl sprites on|off|reset|summary|keys [TYPE [N]]|peds [N] (docs/gta2ctl.md) */
const char *sp_ctl(jbuf *b, int argc, char **argv)
{
    const char *sub = argc >= 2 ? argv[1] : "summary";
    int keys_cmd = !strcmp(sub, "keys");
    int type = keys_cmd && argc >= 3 ? atoi(argv[2]) : 0;
    int n = argc >= 3 + keys_cmd ? atoi(argv[2 + keys_cmd]) : 50;
    if (n < 1 || n > 400)
        n = 50;
    if (!bind())
        return "sprites: the C32 image has no sprite probe";
    if (!strcmp(sub, "on") || !strcmp(sub, "off")) {
        sp_enabled = *c32_on = !strcmp(sub, "on");
        if (sp_enabled)
            reset();
        jb_printf(b, ",\"sprites\":%s", sp_enabled ? "true" : "false");
        return 0;
    }
    if (!strcmp(sub, "reset")) {
        reset();
        return 0;
    }
    if (keys_cmd) {
        int out = 0;
        jb_printf(b, ",\"keys\":[");
        for (uint32_t i = 0; i < MAX_KEYS && out < n; i++) {
            const struct kent *e = &keys[i];
            if (!e->k.used || (type && e->k.type != type))
                continue;
            jb_printf(b, "%s{", out++ ? "," : "");
            key_json(b, &e->k);
            jb_printf(b, ",\"w\":%u,\"h\":%u,\"hash\":\"0x%08x\",\"draws\":%u,\"conflicts\":%u}",
                      e->w, e->h, e->hash, e->count, e->conflicts);
            if (b->len > sizeof b->buf - 512)
                break;
        }
        jb_printf(b, "]");
        return 0;
    }
    if (!strcmp(sub, "peds")) {
        int out = 0;
        jb_printf(b, ",\"peds\":[");
        for (uint32_t i = 0; i < MAX_PEDK && out < n; i++) {
            const struct pent *e = &pkeys[i];
            if (!e->k.used)
                continue;
            jb_printf(b, "%s{\"graphic\":%u,\"anim\":%u,\"frame\":%u,\"walk\":%u,\"armed\":%u,"
                      "\"id\":%u,\"id2\":%d,\"draws\":%u}", out++ ? "," : "", e->k.graphic,
                      e->k.anim, e->k.frame, e->k.walk, e->k.armed, e->id,
                      e->id2 == 0xFFFF ? -1 : e->id2, e->count);
            if (b->len > sizeof b->buf - 512)
                break;
        }
        jb_printf(b, "]");
        return 0;
    }
    if (strcmp(sub, "summary"))
        return "usage: sprites on|off|reset|summary|keys [TYPE [N]]|peds [N]";
    uint32_t per_type[16] = { 0 }, multi_id = 0;
    for (uint32_t i = 0; i < MAX_KEYS; i++)
        if (keys[i].k.used)
            per_type[keys[i].k.type & 15]++;
    for (uint32_t i = 0; i < MAX_PEDK; i++)
        if (pkeys[i].k.used && pkeys[i].id2 != 0xFFFF)
            multi_id++;
    jb_printf(b, ",\"on\":%s,\"frames\":%u,\"sprites\":%u,\"quads_tagged\":%u,\"quads_untagged\":%u,"
              "\"keys\":%u,\"keys_dropped\":%u,\"conflict_keys\":%u,\"conflict_draws\":%u,"
              "\"ped_states\":%u,\"ped_states_multi_id\":%u,\"ped_id_outside_block\":%u,"
              "\"keys_per_type\":{", sp_enabled ? "true" : "false", r_frames - start_frame,
              n_sprites, n_tagged, n_untagged, n_keys, n_full, n_conflicts, n_conflict_draws,
              n_pkeys, multi_id, n_ped_block_bad);
    int first = 1;
    for (int ty = 0; ty < 16; ty++)
        if (per_type[ty]) {
            jb_printf(b, "%s\"%d\":%u", first ? "" : ",", ty, per_type[ty]);
            first = 0;
        }
    jb_printf(b, "},\"ped_offsets_seen\":[");
    for (int g = 0; g < 3; g++) {
        jb_printf(b, "%s\"", g ? "," : "");
        for (int o = 0; o < PED_BLOCK; o++)
            jb_printf(b, "%c", ped_off_seen[g][o] ? '#' : '.');
        jb_printf(b, "\"");
    }
    jb_printf(b, "],\"conflicts\":[");
    for (uint32_t i = 0; i < n_conflicts; i++) {
        const struct conflict *c = &conflicts[i];
        jb_printf(b, "%s{", i ? "," : "");
        key_json(b, &c->k);
        jb_printf(b, ",\"first\":\"%ux%u 0x%08x\",\"then\":\"%ux%u 0x%08x\"}", c->w0, c->h0,
                  c->hash0, c->w1, c->h1, c->hash1);
    }
    jb_printf(b, "]");
    return 0;
}
