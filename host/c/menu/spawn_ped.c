/* spawn_ped.c — Spawn > Ped: every ped remap (look) of the style, named, with the role it
 * naturally has on this level (a gang of the level, police, emergency, special, civilian),
 * a role picker and a live, walking and turning preview of the ped in that remap and body.
 * Built through the recipe in docs/debug-menu.md, like spawn_car.c: one DM_PAGE with dynamic
 * rows (sp_rows / sp_rowfmt / sp_rowchange), a key callback (sp_key) and a draw callback
 * (sp_draw); the spawn itself is km_spawn_ped (spawn.h).
 *
 *   UP / DOWN       look (remap)      LEFT / RIGHT   role: auto (the look's own) or any of
 *   B               behaviour:                       civilian, gang member, cop, SWAT, FBI,
 *                   normal / hostile / follows you   army, medic, fireman, Elvis, mugger, ...
 *   RETURN          spawn it 1 block in front of the player
 *
 * Rows are sorted: the level's gangs first, then police, emergency and special roles, named
 * looks, plain civilians. A role is an occupation, a body (graphicType), a class, threat
 * search / reaction and a weapon (sp_roles).
 *
 * Facts (cite): PED_REMAP 0..52 names = seuko-mod enum (re/gta2_types.h); the style has 474
 * ped sprites = 3 bodies x 158 frames (bun tools/formats/cli.ts sty data/wil.sty --summary),
 * frame = graphicType * 158 + anim (PedGameObject_UpdateAnimFrame @0x497DF0,
 * docs/re/gangs-and-peds.md), frames 0..7 are the walk cycle (rendered from the style);
 * the emergency body is drawn for remaps 0..4 only (other remaps leave its green pixels).
 * Gangs: g_GangRespect @0x5EB898 -> 10 x GangRespect 0x144: +0 present, +2 gangName,
 * +0x101 pedRemap (docs/re/gangs-and-peds.md §1). Occupations: OCUPATION (Ped +0x240) and
 * the ambient spawner's remap per role (§4, §5). Ped: +0x244 remap, +0x26C graphicType
 * (seuko-mod gta2.h), +0x17C gang (ADD_CHAR_TO_GANG, §2).
 */
#include <stdio.h>
#include <string.h>
#include "dm.h"
#include "../spawn.h"

#define SP_NREMAP  53
#define SP_PANE_H  268
#define SP_SCALE   450                  /* preview: percent of the HUD's 1:1 size (a ped is ~16x20) */
#define SP_SPIN    2                    /* preview rotation per frame (1440 per turn) */
#define SP_WALK    5                    /* frames per walk-cycle step */
#define SP_DIST    0x4000               /* spawn 1 block in front */
#define SP_BODY    158                  /* ped frames per body (graphicType) */
#define SP_NLINES  8
#define SP_LINE    64
#define GANGS      0x5EB898             /* GangRespectContainer* */

/* game functions, calling conventions from the disassembly (Seq 27 seq51_answer.md) */
#define PED_POOL        0x5E5BBC        /* PedManager* (g_PedManager): +0 freeListHead */
#define PED_SPAWN       0x43DB40        /* Ped_Spawn stdcall(SCR_f x, y, z, PED_REMAP, Ang16 rot) -> Ped* */
#define PED_SETCLASS    0x403920        /* Ped_SetPedClass thiscall(Ped*; class) */
#define PED_SETOCC      0x403970        /* Ped_SetOccupation thiscall(Ped*; OCUPATION) */
#define PED_SETWEAPON   0x43D830        /* Ped_SetWeapon fastcall(Ped*, edx; WEAPON_INDEX) */
#define GANG_WEAPON     0x45DB70        /* Gang_PickWeaponByRespect fastcall(GangRespect*) -> weapon */
#define PED_SETOBJ      0x43BBC0        /* Ped_SetObjective thiscall(Ped*; objective, short timer) */
#define PED_SETTARGET   0x403AC0        /* Ped_SetObjTargetPed thiscall(Ped*; Ped*) */
#define PEDGROUP_CREATE 0x440350        /* PedGroupCreate fastcall(Ped* leader, edx; byte members) */
#define PEDGROUP_ADD    0x404C90        /* PedGroupAddPed fastcall(PedGroup*, edx = 0; Ped*) */

/* Roles: occupation, body (graphicType 0 dummy, 1 gang, 2 emergency), pedClass (3 ambient,
 * 4 special AI, 5 mission, 6 car driver), threat search (0 none, 1 line of sight, 2 area),
 * threat reaction (1 as emergency, 2 normal, 3 run away), weapon (-1 none, -2 the gang's pick
 * by respect, else WEAPON_INDEX: 0 pistol, 1 SMG), name. Each copies the game's own spawn
 * site where it has one (Seq 27 seq51_answer.md §3/§5: SetupFootCop 0x4AA710,
 * SpawnRoadblockGuard 0x4A9B40 FBI, SpawnParamedicCrew 0x473170, SpawnElvisGroup 0x43D640,
 * Car_CreateGangDriverPed 0x43DC60, DummyPedManager_SpawnAmbientPed 0x4404F0); the others
 * are ours. Classes 3 / 4 / 6 despawn off screen like the game's own (40 / 100 ticks). */
struct sp_role { int32_t occ, body, cls, search, react, weapon; const char *name; };
static const struct sp_role sp_roles[] = {
    { 0, 0, 0, 0, 0, -1, "auto" },
    { 3, 0, 3, 2, 3, -1, "Civilian" },
    { 19, 1, 4, 1, 2, -2, "Gang member" },
    { 29, 2, 3, 1, 1, 0, "Cop" },
    { 25, 2, 4, 1, 1, 1, "SWAT" },
    { 26, 1, 4, 1, 1, 1, "FBI" },
    { 31, 2, 3, 1, 1, 1, "Army" },
    { 23, 0, 4, 0, 1, -1, "Medic" },
    { 38, 0, 4, 0, 1, -1, "Fireman" },
    { 22, 1, 4, 2, 3, -1, "Elvis" },
    { 15, 0, 4, 2, 3, -1, "Mugger" },
    { 16, 0, 6, 2, 3, -1, "Car thief" },
    { 14, 1, 4, 1, 2, 0, "Psycho" },
    { 18, 1, 4, 1, 2, 0, "Criminal" },
    { 43, 0, 5, 2, 3, -1, "Stand still bloke" },
};
#define SP_NROLES (int)(sizeof sp_roles / sizeof *sp_roles)
#define SP_ROLE_GANG 2

/* the natural role of each remap (without a gang of the level using it): 0..3 police,
 * 4 khaki = army (FBI/army crews, §5), 5..11 rednecks, scientist, zaibatsu, krishna,
 * russian, loony; 12 Elvis, 13 yakuza, 14 fireman, 15 car thief, 16 medic, 17 mugger */
static const uint8_t sp_natural[SP_NREMAP] = {
    3, 3, 3, 3, 6, 1, 1, 1, 1, 1, 1, 1, 9, 1, 8, 11, 7, 10,
    [18 ... SP_NREMAP - 1] = 1,
};
/* the sort class of each remap: 0 level gang (set at run time), 1 police, 2 emergency or
 * special role, 3 named look, 4 plain civilian (18..21 the ambient dummies; 22 prisoner,
 * 23/24 hulks, 25 player, 26 naked are named looks) */
static const uint8_t sp_class0[SP_NREMAP] = {
    1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 3, 3, 2, 3, 2, 2, 2, 2,
    4, 4, 4, 4, 3, 3, 3, 3, 3,
    [27 ... SP_NREMAP - 1] = 4,
};
static const char *const sp_names[] = {
    "Blue police", "Green police", "Red police", "Yellow police", "Khaki police",
    "Redneck, red head", "Redneck, blond", "Scientist", "Zaibatsu", "Krishna", "Russian",
    "Loony", "Elvis", "Yakuza", "Fireman", "Green shorts", "Medic", "Mugger", "Blue dummy",
    "Light blue dummy", "T-shirt and shorts", "Shirt and trousers", "Prisoner", "Hulk 1",
    "Hulk 2", "Player", "Naked",
};
#define SP_NNAMED (int)(sizeof sp_names / sizeof *sp_names)
static const char *const sp_bodies[] = { "dummy", "gang", "emergency" };
static const char *const sp_behaves[] = { "normal", "hostile", "follows you" };

static int sp_role;                     /* 0 auto, else an sp_roles index */
static int sp_behave;                   /* 0 normal, 1 hostile, 2 follows the player */
static int sp_spawn_remap, sp_spawn_role, sp_spawn_behave;
static uint8_t sp_idx[SP_NREMAP];

/* the level's GangRespect whose members wear that remap, or 0 */
static GangRespect *sp_gang(int remap)
{
    GangRespect *g = GP(GangRespect, rd32(GANGS));
    for (int i = 0; g && i < 10; i++, g++)
        if (g->present && g->pedRemap == remap)
            return g;
    return 0;
}

/* the level's first gang, or 0 */
static GangRespect *sp_any_gang(void)
{
    GangRespect *g = GP(GangRespect, rd32(GANGS));
    for (int i = 0; g && i < 10; i++, g++)
        if (g->present)
            return g;
    return 0;
}

/* SP_ROLE_GANG if a gang of the level wears it, else the remap's own role */
static int sp_natural_role(int remap)
{
    return sp_gang(remap) ? SP_ROLE_GANG : sp_natural[remap];
}

/* the gang a gang-member role joins (the one wearing that remap, else the level's first) */
static GangRespect *sp_role_gang(int remap, int role)
{
    if (role != SP_ROLE_GANG)
        return 0;
    GangRespect *g = sp_gang(remap);
    return g ? g : sp_any_gang();
}

/* all the remaps, by class (stable) */
static int sp_rows(void)
{
    uint8_t cls[SP_NREMAP];
    for (int i = 0; i < SP_NREMAP; i++) {
        sp_idx[i] = (uint8_t)i;
        cls[i] = sp_gang(i) ? 0 : sp_class0[i];
    }
    for (int i = 1; i < SP_NREMAP; i++) {
        uint8_t idx = sp_idx[i], c = cls[i];
        int j = i;
        for (; j > 0 && cls[j - 1] > c; j--) {
            cls[j] = cls[j - 1];
            sp_idx[j] = sp_idx[j - 1];
        }
        sp_idx[j] = idx;
        cls[j] = c;
    }
    return SP_NREMAP;
}

/* "Yakuza (yakuzagang)", "Remap 31 (civilian)" into a buffer of 64 */
static void sp_name(int remap, char *buf)
{
    if (remap < SP_NNAMED)
        strcpy(buf, sp_names[remap]);
    else
        snprintf(buf, 64, "Remap %d", remap);
    GangRespect *g = sp_gang(remap);
    size_t n = strlen(buf);
    if (g) {
        if (n < 63)
            snprintf(buf + n, 63 - n, " (%s)", g->gangName);
    } else if (remap >= SP_NNAMED) {    /* an unnamed look: say what it is */
        strcpy(buf + n, " (civilian)");
    }
}

static void sp_rowfmt(int row, char *buf)
{
    sp_name(sp_idx[row], buf);
}

/* B cycles the behaviour */
static int sp_key(int dik)
{
    if (dik != DIK_B)
        return 0;
    sp_behave = (sp_behave + 1) % 3;
    return 1;
}

/* LEFT / RIGHT the role, RETURN spawns (everything resolved now, the spawn on the game's
 * side) */
static void sp_spawn(void);
static void sp_rowchange(int row, int dir)
{
    if (dir) {
        int r = sp_role + dir;
        sp_role = r < 0 ? SP_NROLES - 1 : r >= SP_NROLES ? 0 : r;
        return;
    }
    sp_spawn_remap = sp_idx[row];
    sp_spawn_role = sp_role ? sp_role : sp_natural_role(sp_spawn_remap);
    sp_spawn_behave = sp_behave;
    dm_defer(sp_spawn);
}

/* hostile / follower: rax = the toast. Hostile = SET_CHAR_OBJECTIVE KILL_CHAR_ON_FOOT on
 * the player (handler 0x47A1E0): Ped_SetObjective, then the target (Ped_SetObjective clears
 * it). Follower = the player's group (ADD_EXISTING_CHAR_TO_GROUP, 0x47BAC0):
 * PedGroupCreate(player, 0) when he has none, then PedGroupAddPed; the group AI makes
 * members follow (Seq 27 seq51_answer.md §4). */
static const char *sp_behaviour(gptr ped, int behave)
{
    Ped *pl = dm_player_ped();
    gptr plv = (gptr)(uintptr_t)pl;
    if (!pl)
        return "Ped spawned";
    if (behave == 1) {
        game_thiscall(PED_SETOBJ, ped, 2, 20, 9999);    /* KILL_CHAR_ON_FOOT */
        game_thiscall(PED_SETTARGET, ped, 1, plv);
        return "Ped spawned, hostile";
    }
    if (behave != 2)
        return "Ped spawned";
    if (!pl->group) {
        game_fastcall(PEDGROUP_CREATE, plv, 0, 1, 0);
        if (!pl->group)
            return "Ped spawned, no group for you";
    }
    if (GP(PedGroup, pl->group)->membersCount >= 7)
        return "Ped spawned, your group is full";
    game_fastcall(PEDGROUP_ADD, pl->group, 0, 1, ped);
    return "Ped spawned, follows you";
}

/* the CREATE_CHAR recipe (Script_Decl_CHAR_DATA_SET 0x477560, Seq 27 seq51_answer.md §1):
 * Ped_Spawn, then class, occupation, body, threat search / reaction, gang, weapon as the
 * role says, then the behaviour */
uint32_t km_spawn_ped(int remap, int role, int behave, int32_t x, int32_t y, int32_t z, int rot)
{
    if (role <= 0 || role >= SP_NROLES)
        role = sp_natural_role(remap);
    km_spawn_why = "No free ped";       /* Ped_Spawn pops the ped pool with no empty check */
    gptr pool = rd32(PED_POOL);
    if (!pool || !rd32(pool))           /* freeListHead */
        return 0;
    gptr ped = game_stdcall(PED_SPAWN, 5, (uint32_t)x, (uint32_t)y, (uint32_t)z,
                            (uint32_t)remap, (uint32_t)rot);
    km_spawn_why = "No free ped sprite";    /* the game leaks that ped */
    if (!ped)
        return 0;
    const struct sp_role *rl = &sp_roles[role];
    Ped *p = GP(Ped, ped);
    game_thiscall(PED_SETCLASS, ped, 1, (uint32_t)rl->cls);
    game_thiscall(PED_SETOCC, ped, 1, (uint32_t)rl->occ);
    p->graphicType = (uint32_t)rl->body;
    p->threatSearch = (uint32_t)rl->search;
    p->threatReaction = (uint32_t)rl->react;
    GangRespect *g = sp_role_gang(remap, role);
    gptr gv = (gptr)(uintptr_t)g;
    if (g)
        p->gang = gv;
    if (rl->weapon == -2 && g)
        game_fastcall(PED_SETWEAPON, ped, 0, 1, game_fastcall(GANG_WEAPON, gv, 0, 0));
    else if (rl->weapon >= 0)
        game_fastcall(PED_SETWEAPON, ped, 0, 1, (uint32_t)rl->weapon);
    km_spawn_why = sp_behaviour(ped, behave);
    return ped;
}

/* sp_spawn (deferred): km_spawn_ped 1 block in front of the player */
static void sp_spawn(void)
{
    int32_t pos[4];
    if (!km_spawn_pos(pos, SP_DIST)) {
        dm_toast_set(km_spawn_why);
        return;
    }
    gptr ped = km_spawn_ped(sp_spawn_remap, sp_spawn_role, sp_spawn_behave,
                            pos[0], pos[1], pos[2], pos[3]);
    if (ped) {
        Ped *p = GP(Ped, ped);
        printf("menu: spawn ped %#x remap %d occupation %d class %d body %d\n", ped,
               sp_spawn_remap, p->occupation, p->pedClass, p->graphicType);
    }
    dm_toast_set(km_spawn_why);
}

/* the preview pane for the selected look, lines measured first like sc_draw */
static void sp_draw(struct dm_page *page)
{
    if ((uint32_t)page->sel >= (uint32_t)dm_dyn())
        return;                         /* on Back */
    int remap = sp_idx[page->sel];
    char l[SP_NLINES][SP_LINE];
    sp_name(remap, l[0]);
    int role = sp_role ? sp_role : sp_natural_role(remap);
    const struct sp_role *rl = &sp_roles[role];
    snprintf(l[1], SP_LINE, "Role: %s%s", sp_role ? "" : "auto, ", rl->name);
    snprintf(l[2], SP_LINE, "Remap %d  Occupation %d", remap, rl->occ);
    GangRespect *g = sp_role_gang(remap, role);
    if (g)
        snprintf(l[3], SP_LINE, "Body %s  Gang %.20s", sp_bodies[rl->body], g->gangName);
    else
        snprintf(l[3], SP_LINE, "Body %s", sp_bodies[rl->body]);
    snprintf(l[4], SP_LINE, "Behaviour: %s", sp_behaves[sp_behave]);
    strcpy(l[5], "Left Right: role");
    strcpy(l[6], "B: behaviour");
    strcpy(l[7], "Return: spawn");
    uint32_t w = 120;                   /* width: the preview or the widest line */
    for (int i = 0; i < SP_NLINES; i++) {
        uint32_t lw = (uint32_t)dm_text_w(l[i]);
        if (lw > w)
            w = lw;
    }
    dm_pane(DM_Y, DM_Y + SP_PANE_H, (int)w);
    dm_text_at(l[0], dm_pane_x, DM_Y, 1);
    struct dm_sprite ds = {
        .type = 3,                      /* SPRITE_TYPE_PED, frame = body * 158 + walk step */
        .id = (int32_t)((r_frames / SP_WALK & 7) + (uint32_t)(rl->body * SP_BODY)),
        .pal = 4,                       /* ped remap */
        .remap = remap,
        .x = (int32_t)(w / 2) + dm_pane_x,
        .y = DM_Y + 18 + 60,
        .scale = SP_SCALE,
        .rot = (int32_t)(r_frames * SP_SPIN % 1440),
    };
    dm_sprite(&ds);
    int y = DM_Y + SP_PANE_H - 7 * DM_LINE - DM_LINE / 2;  /* lines 1..7 at the bottom, */
    for (int i = 1; i < SP_NLINES; i++, y += DM_LINE) {    /* a gap before the keys */
        if (i == 5)
            y += DM_LINE / 2;
        dm_text_at(l[i], dm_pane_x, y, 0);
    }
}

DM_PAGE_EXTERN(dmp_spawn);
DM_PAGE(dmp_spawn_ped, dmp_spawn, 20, "Ped", .draw = sp_draw, .key = sp_key,
        .rows = sp_rows, .rowfmt = sp_rowfmt, .rowchange = sp_rowchange);
