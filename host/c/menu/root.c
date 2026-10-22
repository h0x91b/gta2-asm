/* root.c — the K menu's root page: actions on the player and the camera zoom. The other
 * root rows come from their own files: Ped paths (debug_paths.asm), Mouse turning and
 * Strafe (player_move.asm), and the page links (each page's DM_PAGE). */
#include <stdio.h>
#include "dm.h"

#define ZOOM_MIN 25                     /* config.asm */
#define ZOOM_MAX 400

struct dm_page dmp_root DM_SECT("__dm_pages") = { .title = "Debug menu  (K)" };

/* dm_quick_save: save the game where the player stands (seuko-mod
 * src/modules/modmenu/utils/save-game.cpp): refused during a mission; SaveGame @0x47EF40
 * thiscall(S15_Script* = [0x6644BC]; char* file = Menu 0x5EC070 +0x300), ret 4. The
 * player's position.y is moved 1.0 back around the call as seuko does. S15 +0x344 = mission
 * flag pointer.
 * From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 * src/modules/modmenu/utils/save-game.cpp @25b1985 — SaveGame 0x47EF40. */
#define SAVE_FILE (0x5EC070 + 0x300)
static void dm_quick_save(void)
{
    const char *toast = "Cannot save: no player";
    Ped *ped = dm_player_ped();
    gptr script = rd32(0x6644BC);
    if (!ped)
        goto out;
    toast = "Cannot save here";
    if (!script || !rd32(script + 0x344))
        goto out;
    toast = "Cannot save during a mission";
    if (rd8(rd32(script + 0x344)))
        goto out;
    ped->position.y -= 0x4000;
    game_thiscall(0x47EF40, script, 1, SAVE_FILE);
    ped->position.y += 0x4000;
    toast = "Game saved";
    printf("menu: quick save -> %s\n", (const char *)(uintptr_t)SAVE_FILE);
out:
    dm_toast_set(toast);
}

/* dm_all_weapons: AddWeapon @0x43E4B0, fastcall(Ped* ecx, edx = 0; weapon, ammo), ret 8,
 * for weapons 0..14 with 99 ammo.
 * From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 * src/game/functions.h, get-all-weapons.cpp @25b1985 — AddWeapon 0x43E4B0. */
static void dm_all_weapons(void)
{
    Ped *ped = dm_player_ped();
    if (!ped) {
        dm_toast_set(s_dm_noplayer2);
        return;
    }
    for (uint32_t w = 0; w < 15; w++)
        game_fastcall(0x43E4B0, (gptr)(uintptr_t)ped, 0, 2, w, 99);
    dm_toast_set("Got all weapons");
}

/* dm_add_money: Player +0x2d4 animated money (value, max +0x30), += DM_MONEY up to max.
 * From gta2-seuko-mod by izawartka (https://github.com/izawartka/gta2-seuko-mod),
 * src/modules/modmenu/menus/player-stats-menu.cpp @25b1985 — Player +0x2d4. */
#define DM_MONEY 100000
static void dm_add_money(void)
{
    Player *pl = dm_player();
    if (!pl) {
        dm_toast_set(s_dm_noplayer2);
        return;
    }
    AnimatedValue *m = &pl->score.money;
    uint32_t v = (uint32_t)m->value + DM_MONEY;
    if (m->max > 0 && v > (uint32_t)m->max)     /* max <= 0: none set */
        v = (uint32_t)m->max;
    m->value = (int)v;
    dm_toast_set("Got $100000");        /* the font has no "+" */
}

/* camera zoom (cam_zoom_pct, w32_hooks.asm): LEFT / RIGHT 5% steps, RETURN back to the
 * game's own (100%) */
static void zoom_change(const struct dm_item *it, int dir)
{
    (void)it;
    int z = cam_zoom_pct ? cam_zoom_pct : 100;
    if (!dir)
        z = 100;
    else
        z += dir * 5;
    if (z < ZOOM_MIN)
        z = ZOOM_MIN;
    if (z > ZOOM_MAX)
        z = ZOOM_MAX;
    cam_zoom_pct = z;
}

static void zoom_fmt(char *end)
{
    snprintf(end, 32, "%d%%", cam_zoom_pct ? cam_zoom_pct : 100);
}
DM_VALUE_FNS(zoom);

DM_ITEM(dmp_root, 10, DM_ACTION, "Quick save", dm_quick_save);
DM_ITEM(dmp_root, 20, DM_ACTION, "Get all weapons", dm_all_weapons);
DM_ITEM(dmp_root, 30, DM_ACTION, "Add $100000", dm_add_money);
DM_ITEM(dmp_root, 40, DM_VALUE, "Camera zoom: ", &dmv_zoom);
