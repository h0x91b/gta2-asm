/* sprite_probe.c — RE probe for HD sprites (docs/re/sprites-hd.md): while Sprite_Draw runs,
 * publish which sprite it is drawing, so the host's gbh_DrawQuad can pair that key with the
 * texture it is handed (host/c/sprite_probe.c, gta2ctl `sprites`). Off unless gta2ctl turns
 * it on; when off the detour costs one byte test per sprite.
 *
 * Seam: Sprite_Draw(Sprite* this) @0x4BE060, thiscall, plain `ret`, only caller
 * LayerDrawQueue_DrawInOrder (Seq 27 H3, disassembly). It issues all of a sprite's
 * gbh_DrawQuad calls itself: shadow (flags 0x2180), body, and for cars a light overlay
 * (0x80). The key read at entry: Sprite.spriteType +0x30, spriteId +0x22 (category
 * relative), paletteKind +0x34, remap +0x24, shrink +0x38; for cars Car.deltasBitstate
 * (+8, the delta mask Sprite_Draw hands the car sprite cache); for peds the PedGameObject
 * animation state that H3 says picks the frame (PedGameObject_UpdateAnimFrame 0x497DF0).
 * This is the prototype of the HD hook: if every key always comes with the same pixels,
 * the key alone can select an HD texture.
 */
#include "c32.h"

C32_OFFSET(Sprite, spriteId, 0x22);
C32_OFFSET(Sprite, remap, 0x24);
C32_OFFSET(Sprite, spriteType, 0x30);
C32_OFFSET(Sprite, paletteKind, 0x34);
C32_OFFSET(Car, deltasBitstate, 0x08);
C32_OFFSET(PedGameObject, walkSubMode, 0x10);
C32_OFFSET(PedGameObject, animFrame, 0x68);
C32_OFFSET(PedGameObject, anim, 0x6C);
C32_OFFSET(Ped, selectedWeapon, 0x170);
C32_OFFSET(Ped, remap, 0x244);
C32_OFFSET(Ped, graphicType, 0x26C);

#define SPRITE_SHRINK 0x38              /* byte, crop in px per side (H3); unnamed in re/ yet */

GAME_FN(Car *, G2_FASTCALL, Sprite_GetOwnerCar, 0x40FEB0, (Sprite *s));
GAME_FN(PedGameObject *, G2_FASTCALL, Sprite_GetOwnerSpriteIfPed, 0x40FEA0, (Sprite *s));

typedef void (G2_THISCALL *sprite_draw_fn)(Sprite *self);
static sprite_draw_fn Sprite_Draw;      /* the original */

/* host/c/sprite_probe.c reads both by name (same layout there) */
uint8_t sp_on;
struct c32_sprite_tag sp_tag;
C32_EXPORT(sp_on);
C32_EXPORT(sp_tag);

static void G2_THISCALL hk_sprite_draw(Sprite *s)
{
    if (!sp_on) {
        Sprite_Draw(s);
        return;
    }
    struct c32_sprite_tag t = { 0 };
    t.sprite = (uint32_t)s;
    t.type = (uint16_t)s->spriteType;
    t.id = (uint16_t)s->spriteId;
    t.kind = (uint16_t)s->paletteKind;
    t.remap = (uint16_t)s->remap;
    t.shrink = ((const uint8_t *)s)[SPRITE_SHRINK];
    Car *car = Sprite_GetOwnerCar(s);
    PedGameObject *go = car ? 0 : Sprite_GetOwnerSpriteIfPed(s);
    if (car) {
        t.owner = SP_OWNER_CAR;
        t.deltas = (uint32_t)car->deltasBitstate;
    } else if (go) {
        Ped *ped = go->ped;
        t.owner = SP_OWNER_PED;
        t.anim = (uint8_t)go->anim;
        t.anim_frame = go->animFrame;
        t.walk_sub = (uint8_t)go->walkSubMode;
        if (ped) {
            t.graphic = (uint8_t)ped->graphicType;
            t.ped_remap = (uint8_t)ped->remap;
            t.armed = ped->selectedWeapon != 0;
        }
    }
    t.seq = sp_tag.seq + 1;
    t.active = 1;
    sp_tag = t;
    Sprite_Draw(s);
    sp_tag.active = 0;
}

static void sprite_probe_init(void)
{
    static const uint8_t orig[] = { 0x81, 0xEC, 0xA4, 0x00, 0x00, 0x00 };   /* sub esp, 0xA4 */
    Sprite_Draw = (sprite_draw_fn)c32_detour(0x4BE060, orig, sizeof orig, (void *)hk_sprite_draw);
}
C32_INIT(sprite_probe_init);
