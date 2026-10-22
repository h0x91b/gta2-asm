/* player_move.c — two on-foot controls the original game never had: strafing (sideways
 * steps, Q / E by default) and smooth mouse turning. Both go through the game's own walker,
 * so walls, cars and peds stop a strafing player exactly as they stop a walking one.
 * Settings: the `controls:` section of config.yaml (host/c/config.c); the keyboard, the mouse
 * and the K menu rows are host side (host/c/c32_host.c, service foot_input).
 * Analysis: docs/re/ped-movement-collision.md §6.
 *
 * Strafe. All on-foot collision is inline in PedGameObject_StateWalk 0x49A560 and keyed off
 * the heading (PedGameObject+0x40, Ang16, 1440 per turn): the probe, the tile-edge tests, the
 * wall slide and the sprite obstacles all run along it. The game walks BACKWARDS by turning
 * the heading 180° for one move and restoring it at the end (0x49AA8E saves it in the local
 * [esp+0x24] and clears the flag [esp+0x11]; 0x49B0A5 restores it when the flag is clear), so
 * the sprite keeps facing forward. We do the same with ±90° (±45° together with forward or
 * back) in a mid-function hook at 0x49AC76, the point where the walker would otherwise save
 * the unmodified heading. The walker only moves when Player.moveSpeed (+0xC) is nonzero, so a
 * pure strafe reports "forward" (+1.0) from the MoveOnFoot call hook.
 *   Directions: x = sin(h), y = cos(h); the left key makes the heading grow, so the ped's
 *   left is heading + 360 and its right heading − 360 (checked in a run, see docs).
 *
 * Mouse. Player.turnRate (+8) is the per-tick heading delta the walker adds (0x49A98F) and the
 * player has no other target heading, so mouse turning writes it after Player_MoveOnFoot:
 * the game's own value (the arrow keys still work) plus the mouse delta of that tick. The
 * game ramps turnRate from its previous value, so ours is put back before each call.
 * The host switches SDL relative mode on while the player walks with mouse turning enabled
 * and releases it on focus loss or when the switch goes off (foot_input).
 *
 * Prior art, both only turned the ped by pressing virtual left/right keys (turn speed capped
 * by turnRate) and neither strafed: gta2-seuko-mod by izawartka
 * (https://github.com/izawartka/gta2-seuko-mod), src/modules/modmenu/cheats/mouse-control/
 * and src/events/keyboard-state-update.cpp @25b1985; h0x91b/gta2-resurection
 * (https://github.com/h0x91b/gta2-resurection), mod-mouse-rotation.lua @87e1d98;
 * h0x91b/gta2-mouse (https://github.com/h0x91b/gta2-mouse), MainWindow.cpp @6c5351b wrote
 * PedGameObject+0x40 directly, which the walker overwrites every tick.
 */
#include "c32.h"

C32_OFFSET(Player, turnRate, 0x08);     /* docs/re/ped-movement-collision.md §1 */
C32_OFFSET(Player, moveSpeed, 0x0C);
C32_OFFSET(Player, keyForward, 0x78);
C32_OFFSET(Player, keyBackward, 0x79);
C32_OFFSET(Ped, gameObject, 0x168);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(PedGameObject, spriteRotation, 0x40);
C32_OFFSET(PedGameObject, bit1, 0x58);

#define ANG_TURN    1440                /* Ang16 units per full turn */
#define ANG_90      360
#define ANG_45      180
#define MOVE_FWD    0x4000              /* Player.moveSpeed +1.0 (Q14) */
#define BIT1_BACK   8                   /* PedGameObject.bit1: walking backwards */
#define WALK_FLAG   0x11                /* StateWalk locals at 0x49AC76: heading not changed yet */
#define WALK_SAVED  0x24                /*   the heading to restore at 0x49B0A5 */
#define MOUSE_MAX   720                 /* at most half a turn per tick */

typedef void (G2_THISCALL *move_on_foot_fn)(Player *self, Ped *ped);
static move_on_foot_fn Player_MoveOnFoot;       /* 0x4A5C50 */

static PedGameObject *walk_gobj;        /* the player's PedGameObject this tick, 0 = not on foot */
static short walk_offset;               /* heading offset for this tick's move, 0 = none */
static short game_turn;                 /* turnRate as the game computed it */

/* to 0..ANG_TURN-1, for any |a| < 4 turns */
static short ang_wrap(int a)
{
    return (short)((unsigned)(a + 4 * ANG_TURN) % ANG_TURN);
}

/* Player_MoveOnFoot(Player* this, Ped*) @0x4A5C50, thiscall, ret 4, called at 0x4A7901 by
 * Player_HandleControls when the player is on foot. It turns the keys into Player.turnRate
 * and Player.moveSpeed; the ped moves later in the same tick (Ped_Update → StateWalk). */
static void G2_THISCALL hk_move_on_foot(Player *pl, Ped *ped)
{
    struct c32_foot_input in;
    PedGameObject *go = ped->gameObject;
    int on_foot = go && !ped->currentCar;

    c32_foot_input(&in, on_foot);       /* keys and mouse do not change during the call */
    if (in.mouse_on)
        pl->turnRate = game_turn;       /* the game ramps from its own last value */
    Player_MoveOnFoot(pl, ped);
    game_turn = pl->turnRate;
    walk_offset = 0;
    walk_gobj = 0;
    if (on_foot) {
        walk_gobj = go;
        if (in.strafe) {                /* +1 left, -1 right */
            if (pl->keyForward)         /* forward wins over back, as in Player_MoveOnFoot */
                walk_offset = (short)(in.strafe * ANG_45);
            else if (pl->keyBackward)   /* the walker already turned the heading by 180° */
                walk_offset = (short)(in.strafe * -ANG_45);
            else {
                walk_offset = (short)(in.strafe * ANG_90);
                if (pl->moveSpeed == 0)
                    pl->moveSpeed = MOVE_FWD;
            }
        }
        if (in.mouse_ok) {
            int d = -(in.mouse_px * in.mouse_sens / 50);  /* 100% = 2 units (0.5°) per pixel; */
            if (d > MOUSE_MAX)                            /* mouse right = heading down */
                d = MOUSE_MAX;
            if (d < -MOUSE_MAX)
                d = -MOUSE_MAX;
            pl->turnRate = ang_wrap(d + game_turn);
        }
    }
    c32_ctl_on_foot(pl, ped);           /* gta2ctl goto / face steer last */
}

/* 0x49AC76 in PedGameObject_StateWalk (esi = PedGameObject*), before the walker saves the
 * heading it will restore: for the player's PedGameObject with a strafe offset this tick,
 * save the facing ourselves, clear the "unchanged" flag and turn the heading for this move.
 * If the walker has already turned it (backward walk, bit 3), the offset goes on top; any
 * other turn of its own (stepping around an obstacle) wins and this tick does not strafe. */
static void hk_walk_heading(struct c32_regs *r)
{
    PedGameObject *go = (PedGameObject *)r->esi;    /* every walking ped comes through here */
    uint8_t *locals = (uint8_t *)r->esp;            /* the walker's esp */
    if (!walk_offset || go != walk_gobj)
        return;
    int offset = walk_offset;
    walk_offset = 0;
    if (locals[WALK_FLAG]) {
        *(short *)(locals + WALK_SAVED) = go->spriteRotation;
        locals[WALK_FLAG] = 0;
    } else if (!(go->bit1 & BIT1_BACK))
        return;
    go->spriteRotation = ang_wrap(go->spriteRotation + offset);
}

static void player_move_init(void)
{
    static const uint8_t walk[] = { 0x8A, 0x44, 0x24, 0x11, 0x84, 0xC0 }; /* mov al,[esp+0x11]; test al,al */
    Player_MoveOnFoot = (move_on_foot_fn)c32_callhook(0x4A7901, 0x4A5C50, (void *)hk_move_on_foot);
    c32_midhook(0x49AC76, walk, sizeof walk, hk_walk_heading);
}
C32_INIT(player_move_init);
