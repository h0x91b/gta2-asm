/* player.c — the K menu's Player page: wanted level and its lock, skin (ped remap) and
 * body (graphicType). Police roadblocks (roadblocks.c) and the ambulance / fire truck calls
 * (emergency.c) register their rows here from their own files; their game logic is C32
 * (host/c32/roadblocks.c, host/c32/emergency.c).
 * Ped fields (gta2-seuko-mod src/game/gta2.h @25b1985): copValue +0x20a (short; 1..6 stars
 * from 600/1600/3000/5000/8000/12000, src/game/utils/cop-value-utils.cpp), remap +0x244
 * (byte, PED_REMAP, 255 = default), graphicType +0x26c (0 dummy, 1 gang, 2 emergency). A
 * lock or a chosen skin is re-applied every frame (pl_tick), as seuko's per-tick watches do
 * (src/modules/modmenu/cheats/player-appearance.cpp). */
#include <stdio.h>
#include <string.h>
#include "dm.h"

/* copValue at the start of each wanted level (seuko-mod cop-value-utils.cpp) */
static const int16_t cop_values[7] = { 0, 600, 1600, 3000, 5000, 8000, 12000 };

/* PED_REMAP names (seuko-mod src/game/gta2.h), the rest show as "Ped N" */
static const char *const remap_names[] = {
    "Blue cop", "Green cop", "Red cop", "Yellow cop", "Khaki cop", "Redneck 1", "Redneck 2",
    "Scientist", "Zaibatsu", "Krishna", "Russian", "Loony", "Elvis", "Yakuza", "Fireman",
    "Car thief", "Medic", "Mugger", "Dummy 1", "Dummy 2", "Dummy 3", "Dummy 4", "Prisoner",
    "Hulk 1", "Hulk 2", "Player", "Naked",
};
#define NREMAPNAMES (int)(sizeof remap_names / sizeof *remap_names)
static const char *const body_names[] = { "game", "dummy", "gang", "emergency" };

static int skin_idx = -1;               /* -1 the game's own, 0 = 255 (PED_REMAP_DEFAULT), 1..53 = remap 0..52 */
static int skin = -1;                   /* the remap pl_tick applies, -1 none */
static int body = -1;                   /* -1 the game's own, 0..2 */
static int skin_orig, body_orig;
static uint8_t wanted_lock;
static int16_t wanted_val;

/* pl_tick (DM_FRAME): the wanted lock, a chosen skin and body */
static void pl_tick(void)
{
    Ped *ped = dm_player_ped();
    if (!ped)
        return;
    if (wanted_lock)
        ped->wantedPoints = wanted_val;
    if (skin >= 0)
        ped->remap = (uint8_t)skin;
    if (body >= 0)
        ped->graphicType = (uint32_t)body;
}
DM_FRAME(5, pl_tick);

/* the player's wanted level 0..6, -1 without a player */
static int stars(void)
{
    Ped *ped = dm_player_ped();
    if (!ped)
        return -1;
    int s = 0;
    while (s < 6 && ped->wantedPoints >= cop_values[s + 1])
        s++;
    return s;
}

static void wanted_change(const struct dm_item *it, int dir)
{
    (void)it;
    int s = stars();
    if (s < 0)
        return;
    s = dir ? s + dir : 0;              /* RETURN: no wanted level */
    if (s < 0)
        s = 0;
    if (s > 6)
        s = 6;
    dm_player_ped()->wantedPoints = wanted_val = cop_values[s];
}

static void wanted_fmt(char *end)
{
    int s = stars();
    if (s < 0)
        snprintf(end, 32, "-");
    else
        snprintf(end, 32, "%d", s);
}

static void wlock_change(const struct dm_item *it, int dir)
{
    (void)it;
    (void)dir;
    wanted_lock ^= 1;
    Ped *ped = dm_player_ped();
    if (ped)
        wanted_val = ped->wantedPoints;
}

static void wlock_fmt(char *end)
{
    strcpy(end, wanted_lock ? "on" : "off");
}

/* skin (seuko-mod lists-utils.cpp GetAvailablePedRemaps) */
static void skin_change(const struct dm_item *it, int dir)
{
    (void)it;
    int i = dir ? skin_idx + dir : -1;  /* RETURN: back to the game's own */
    if (i < -1)
        i = 53;
    if (i > 53)
        i = -1;
    int old = skin_idx;
    skin_idx = i;
    skin = i == 0 ? 255 : i < 0 ? -1 : i - 1;
    Ped *ped = dm_player_ped();
    if (old < 0) {                      /* leaving the game's own: remember it */
        if (i >= 0 && ped)
            skin_orig = ped->remap;
    } else if (i < 0 && ped) {          /* back to the game's own: restore it once */
        ped->remap = (uint8_t)skin_orig;
    }
}

static void skin_fmt(char *end)
{
    if (skin < 0)
        strcpy(end, "game");
    else if (skin == 255)
        strcpy(end, "default");
    else
        snprintf(end, 40, "%d %s", skin, skin < NREMAPNAMES ? remap_names[skin] : "Ped");
}

/* body (graphicType) */
static void body_change(const struct dm_item *it, int dir)
{
    (void)it;
    int b = dir ? body + dir : -1;
    if (b < -1)
        b = 2;
    if (b > 2)
        b = -1;
    int old = body;
    body = b;
    Ped *ped = dm_player_ped();
    if (old < 0) {
        if (ped)
            body_orig = (int)ped->graphicType;
    } else if (body == -1 && ped) {
        ped->graphicType = (uint32_t)body_orig;
    }
}

static void body_fmt(char *end)
{
    strcpy(end, body_names[body + 1]);
}

DM_VALUE_FNS(wanted);
DM_VALUE_FNS(wlock);
DM_VALUE_FNS(skin);
DM_VALUE_FNS(body);

DM_PAGE(dmp_player, dmp_root, 100, "Player");
DM_ITEM(dmp_player, 10, DM_VALUE, "Wanted level: ", &dmv_wanted);
DM_ITEM(dmp_player, 20, DM_VALUE, "Lock wanted: ", &dmv_wlock);
DM_ITEM(dmp_player, 30, DM_VALUE, "Skin: ", &dmv_skin);
DM_ITEM(dmp_player, 40, DM_VALUE, "Body: ", &dmv_body);
