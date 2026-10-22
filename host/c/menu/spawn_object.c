/* spawn_object.c — Spawn > Object: every world object type the current level can create at
 * run time (the game's own prefab table, so the style's map objects are in it), grouped
 * (street furniture, weapon / car weapon / power-up pickups, explosives, phones, other),
 * with a remap picker and a live, animated preview. Built through the recipe in
 * docs/debug-menu.md like spawn_car.c: one DM_PAGE with dynamic rows, a key callback for
 * PAGE UP / PAGE DOWN and a draw callback with dm_pane / dm_sprite; the spawn itself is
 * km_spawn_object (spawn.h).
 *
 *   UP / DOWN       object          LEFT / RIGHT   remap: the prefab's own colours, or each
 *   PAGE UP / DOWN  previous / next                  remap of its palette (code / map obj)
 *                   group           RETURN         spawn it 1.5 blocks in front of the player
 *
 * Facts (re/gta2_types.h ObjectPrefab, docs/re/objects-and-weapons.md, own decompile):
 * g_ObjectPrefabsContainer @0x665B40 -> +0x87F4 ObjectPrefab* byId[300] (ObjectPrefabs_Get
 * @0x488170). ObjectPrefab +0x1C remap, +0x1E defaultSpriteId (relative to the type's
 * sprite base), +0x28 sprite type (4 code obj, 5 map obj; ObjectPrefab_ApplyToPosition
 * @0x4883A0 hands it to Sprite_SetCollisionKind), +0x30 palette kind, +0x34 kind, +0x40
 * gridKind (4 = obstacles grid: solid), +0x44 impactMode (2 = pushed away), +0x48
 * explosiveClass, +0x64 ticks per frame, +0x6C frame count. The style's map objects are
 * added by ObjectPrefabs_InitFromStyle @0x488450 (id = the OBJI model).
 * Spawn = the script's own path (Script_Decl_OBJ_DATA_SET @0x476EA0, the CREATE_OBJ_*
 * handler Script_Op_CREATE_OBJ @0x478A80 calls it): types 200..244 (pickups) through
 * Object_NewPhysicsObjUnlessBlocked @0x485480, all others through SpawnObject @0x4852E0;
 * both thiscall(ObjectSpawner* = [0x665788]; type, SCR_f x, y, z, Ang16 rot), ret 0x14,
 * -> WorldObject* or 0, and both insert the body into its collision grid
 * (Object_InsertIntoGrid @0x482630). ObjectSpawner_CreateObject @0x484E00 gives weapon
 * pickups their default ammo. The remap goes on WorldObject +4 Sprite with
 * Sprite_SetRemap @0x4B9B00 (palette kind from the sprite type, like a car's).
 */
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "dm.h"
#include "../spawn.h"

#define SO_PANE_H  300
#define SO_BOX     120                  /* preview: the sprite's diagonal fits this many units */
#define SO_ZOOM    4                    /* ...but at most 4x its 1:1 size */
#define SO_NTYPES  300                  /* ObjectPrefabsContainer.byId[] */
#define SO_PREFABS 0x665B40             /* g_ObjectPrefabsContainer (re/globals.csv) */
#define SO_SPAWNER 0x665788             /* g_ObjectSpawner (re/globals.csv) */
#define STYLE_DATA 0x670684
#define SPAWN_DIST 0x6000               /* 1.5 blocks */
#define SO_NLINES  8
#define SO_LINE    64

/* groups, in list order */
enum { SO_G_STREET, SO_G_WEAPON, SO_G_CARWPN, SO_G_POWERUP, SO_G_PICKUP, SO_G_EXPLO,
       SO_G_PHONE, SO_G_OTHER };
static const char *const so_gnames[] = {
    "Street", "Weapon", "Car weapon", "Power-up", "Pickup", "Explosive", "Phone", "Other",
};
static const char *const so_knames[] = {
    "Static", "Static, notify", "Animated", "Physics", "Physics, animated", "Particles",
    "Collectable", "Collectable, physics", "Collectable, animated", "Collectable, phys anim",
    "Car shop", "Light", "Logic", "Kind ?",
};

/* never offered: projectiles and their probe clones (docs/re/objects-and-weapons.md
 * sections 2 and 6), crane and crusher parts (they belong to a Crane / Crusher), the
 * bonus token (ObjectSpawner_CreateObject counts it against the level's 50 token flags),
 * the bonus letters (GXT "na"; Ped_PickUp 0x43E550 would hand them to AddWeapon as weapons
 * 11..14 / 24..27) and the ringing / in-call phones (touching one answers it through the
 * mission script, PedGameObject_TryAnswerPhone 0x4930C0) - Seq 27 seq52_prep.md */
static const uint16_t so_skip[] = {
    0x80, 0x8A, 0x9A, 0x9F, 0xB7, 0xC0, 0xC1, 0xC2, 0xC3, 0xC6, 0xC7, 0xFB, 0xFE,
    0x109, 0x115,
    0x86, 0x87, 0x88, 0x8C, 0x8E, 0xFC, 0x104, 0x105, 0x106, 0x107, 0x10A,
    211, 212, 213, 214, 224, 225, 226, 227, 241, 242, 243, 244,
    164, 177, 179, 181, 184, 185, 186, 187, 188, 189, 190, 191,
    0,
};
/* explosive without an explosiveClass: they blow up by their own logic */
static const uint16_t so_explosive[] = { 10, 132, 182, 247, 0 };   /* MINE, CAR_BOMB, GRENADE, BOMB */

/* OBJECT_TYPE names (re/gta2_types.h, from seuko-mod's enum), made readable: COLLECT_nn_
 * dropped, words capitalised */
static const struct { uint16_t type; const char *name; } so_names[] = {
    { 1, "Bin Lid" },
    { 2, "Bollard" },
    { 3, "Cone" },
    { 4, "Boxes" },
    { 5, "Blaster" },
    { 6, "Rubbish" },
    { 7, "Bin" },
    { 8, "Animating Oil" },
    { 9, "Oil" },
    { 10, "Mine" },
    { 11, "Bush" },
    { 12, "Crate" },
    { 13, "Football" },
    { 14, "Hard Box" },
    { 15, "News Dispenser" },
    { 16, "Oil Drum" },
    { 17, "Tyre" },
    { 18, "Hydrant Lid" },
    { 19, "Hydrant" },
    { 20, "Hydrant Unlid" },
    { 21, "Roadblock" },
    { 22, "Bench" },
    { 23, "Package" },
    { 25, "Tower" },
    { 43, "Moving Package" },
    { 44, "Dead Package" },
    { 45, "Moving Bench" },
    { 46, "Dead Bench" },
    { 47, "Moving Roadblock" },
    { 48, "Dead Roadblock" },
    { 49, "Moving Hydrant Lid" },
    { 50, "Animating Crate" },
    { 51, "Dead Crate" },
    { 52, "Dead Boxes" },
    { 53, "Dead Cone" },
    { 54, "Dead Blaster" },
    { 55, "Dead Bush" },
    { 56, "Moving Football" },
    { 57, "Moving Hard Box" },
    { 58, "Dead Hard Box" },
    { 59, "Moving News Dispenser" },
    { 60, "Dead News Dispenser" },
    { 61, "Moving Oil Drum" },
    { 62, "Dead Oil Drum" },
    { 63, "Moving Tyre" },
    { 65, "Moving S-Uzi" },
    { 66, "Moving Rocket Launcher" },
    { 67, "Moving Electrogun" },
    { 68, "Moving Molotov Cocktail" },
    { 69, "Moving Grenade" },
    { 70, "Moving Shotgun" },
    { 71, "Moving Electro Baton" },
    { 72, "Moving Flamethrower" },
    { 73, "Moving Silenced S-Uzi" },
    { 74, "Moving Dual Pistol" },
    { 75, "Moving Letter L" },
    { 76, "Moving Letter M" },
    { 77, "Moving Letter N" },
    { 78, "Moving Letter O" },
    { 79, "Moving Vehicle Bomb" },
    { 80, "Moving Vehicle Oil Slick" },
    { 81, "Moving Vehicle Mine" },
    { 82, "Moving Vehicle Machine Gun" },
    { 83, "Moving Tank Cannon" },
    { 84, "Moving Water Cannon" },
    { 85, "Moving Vehicle Flamethrower" },
    { 86, "Moving Jeep Turret" },
    { 87, "Moving Instant Vehicle Bomb" },
    { 88, "Moving Letter J" },
    { 89, "Moving Letter K" },
    { 90, "Moving Letter L" },
    { 91, "Moving Letter M" },
    { 92, "Moving Multiplier +1" },
    { 93, "Moving Life +1" },
    { 94, "Moving Health" },
    { 95, "Moving Armor" },
    { 96, "Moving Jail Free Card" },
    { 97, "Moving Cop Bribe" },
    { 98, "Moving Invulnerability" },
    { 99, "Moving Double Damage" },
    { 100, "Moving Fast Reload" },
    { 101, "Moving Electro Fingers" },
    { 102, "Moving Respect" },
    { 103, "Moving Invisibility" },
    { 104, "Moving Instant Gang" },
    { 105, "Moving Letter N" },
    { 106, "Moving Letter O" },
    { 107, "Moving Letter P" },
    { 108, "Moving Letter Q" },
    { 109, "Small Arrow" },
    { 110, "Vehicle Cone" },
    { 111, "Blood Spark" },
    { 112, "White Dot" },
    { 113, "Particle System" },
    { 114, "Firejet" },
    { 116, "Small Brown Skid" },
    { 117, "Small Grey Skid" },
    { 118, "Small Red Skid" },
    { 119, "Medium Brown Skid" },
    { 120, "Medium Grey Skid" },
    { 121, "Medium Red Skid" },
    { 122, "Car Crossing" },
    { 123, "Moving Bush" },
    { 124, "Big White Skid" },
    { 125, "Medium White Skid" },
    { 126, "Small White Skid" },
    { 128, "Rocket" },
    { 129, "Bus Stop Marker" },
    { 130, "Car Shop" },
    { 131, "Busy Car Shop" },
    { 132, "Car Bomb" },
    { 134, "Crane Wire" },
    { 135, "Crane Base" },
    { 136, "Crane Head A" },
    { 138, "Molotov Moving" },
    { 139, "Conveyor Belt" },
    { 140, "Crane Part A" },
    { 141, "Conveyor Belt End" },
    { 142, "Car Crusher" },
    { 144, "Huge Red Skid" },
    { 145, "Huge White Skid" },
    { 146, "Huge Brown Skid" },
    { 147, "Huge Grey Skid" },
    { 148, "Tank Top" },
    { 149, "Antenna" },
    { 151, "Animating Rubbish" },
    { 152, "Dead Rubbish" },
    { 154, "Flamethrower Flame" },
    { 155, "Moving Cone" },
    { 156, "Moving Blaster" },
    { 157, "Moving Bin" },
    { 158, "Moving Bin Lid" },
    { 161, "Save Point" },
    { 163, "Phone" },
    { 164, "Phone Ringing" },
    { 170, "Traffic Light Casing" },
    { 174, "Phone Dead" },
    { 175, "Briefcase" },
    { 176, "Red Phone" },
    { 177, "Red Phone Ringing" },
    { 178, "Yellow Phone" },
    { 179, "Yellow Phone Ringing" },
    { 180, "Green Phone" },
    { 181, "Green Phone Ringing" },
    { 182, "Grenade" },
    { 183, "Moving Grenade" },
    { 184, "Phone Call End" },
    { 185, "Phone Call" },
    { 186, "Red Phone Call End" },
    { 187, "Red Phone Call" },
    { 188, "Yellow Phone Call End" },
    { 189, "Yellow Phone Call" },
    { 190, "Green Phone Call End" },
    { 191, "Green Phone Call" },
    { 192, "Shot" },
    { 194, "Flaming Bullet" },
    { 197, "Fire" },
    { 198, "Water Bullet" },
    { 200, "Pistol" },
    { 201, "S-Uzi" },
    { 202, "Rocket Launcher" },
    { 203, "Electrogun" },
    { 204, "Molotov Cocktail" },
    { 205, "Grenade" },
    { 206, "Shotgun" },
    { 207, "Electro Baton" },
    { 208, "Flamethrower" },
    { 209, "Silenced S-Uzi" },
    { 210, "Dual Pistol" },
    { 211, "Letter L" },
    { 212, "Letter M" },
    { 213, "Letter N" },
    { 214, "Letter O" },
    { 215, "Vehicle Bomb" },
    { 216, "Vehicle Oil Slick" },
    { 217, "Vehicle Mine" },
    { 218, "Vehicle Machine Gun" },
    { 219, "Tank Cannon" },
    { 220, "Water Cannon" },
    { 221, "Vehicle Flamethrower" },
    { 222, "Jeep Turret" },
    { 223, "Instant Vehicle Bomb" },
    { 224, "Letter J" },
    { 225, "Letter K" },
    { 226, "Letter L" },
    { 227, "Letter M" },
    { 228, "Multiplier Up" },
    { 229, "Extra Life" },
    { 230, "Health" },
    { 231, "Armor" },
    { 232, "Jail Free Card" },
    { 233, "Cop Bribe" },
    { 234, "Invulnerability" },
    { 235, "Double Damage" },
    { 236, "Fast Reload" },
    { 237, "Electro Fingers" },
    { 238, "Respect" },
    { 239, "Invisibility" },
    { 240, "Instant Gang" },
    { 241, "Letter N" },
    { 242, "Letter O" },
    { 243, "Letter P" },
    { 244, "Letter Q" },
    { 247, "Bomb" },
    { 248, "Gun Jeep Turret" },
    { 249, "Big Brown Skid" },
    { 250, "Big Grey Skid" },
    { 252, "Crane Part B" },
    { 253, "Big Red Skid" },
    { 254, "Bullet" },
    { 255, "Traffic Light" },
    { 256, "Red Footprints" },
    { 257, "Blood" },
    { 258, "Crossing" },
    { 259, "Spark" },
    { 260, "Crane Part C" },
    { 261, "Crane Part D" },
    { 262, "Crane Part E" },
    { 263, "Crane Head B" },
    { 265, "Pistol Bullet" },
    { 266, "Bonus Token" },
    { 277, "Tasser Bullet" },
    { 279, "Sound Instant" },
    { 280, "Invisible Target" },
    { 281, "Power Generator" },
    { 282, "Power Generator Dead" },
    { 283, "Invisible Destructible" },
    { 284, "Generator Light" },
    { 285, "Invisible Dead" },
    { 286, "Kill Frenzy" },
    { 287, "Gang Decal Loonies" },
    { 288, "Gang Decal Yakuza" },
    { 289, "Gang Decal Zaibatsu" },
    { 290, "Gang Decal Rednecks" },
    { 291, "Gang Decal Scientists" },
    { 292, "Gang Decal Krishna" },
    { 293, "Gang Decal Russian" },
    { 294, "Tunnel Blocker" },
    { 295, "Remote" },
};
#define SO_NNAMES (int)(sizeof so_names / sizeof *so_names)

static int so_remap = -1;               /* -1 the prefab's own colours, i = remap i of its palette */
static int so_n, so_spawn_type, so_spawn_remap;
static uint32_t so_list[SO_NTYPES];     /* group << 16 | type */

static ObjectPrefab *so_prefab(int type)
{
    gptr c = rd32(SO_PREFABS);
    if ((uint32_t)type >= SO_NTYPES || !c)
        return 0;
    return GP(ObjectPrefab, rd32(c + 0x87F4 + 4 * (uint32_t)type));
}

static int so_in(const uint16_t *list, int type)
{
    for (; *list; list++)
        if (*list == type)
            return 1;
    return 0;
}

/* its SO_G_*, or -1 when it is not offered: no sprite, a particle system / car shop /
 * light / logic object, a projectile, or a moving pickup clone (64..108, the thrown
 * copies of 200..244) */
static int so_group(int t, const ObjectPrefab *p)
{
    uint32_t kind = p->kind, st = p->defaultSpriteType;
    if (kind == 5 || kind >= 10 || !p->frameCount || st < 4 || st > 5)
        return -1;
    if (t >= 64 && t <= 108)
        return -1;
    if (kind >= 3 && kind <= 4 && p->initialSpeed)  /* physics kinds with a launch speed: projectiles */
        return -1;
    if (so_in(so_skip, t))
        return -1;
    if (t >= 200 && t <= 244) {
        if (t <= 210)
            return SO_G_WEAPON;
        if (t >= 215 && t <= 223)
            return SO_G_CARWPN;
        if (t >= 228 && t <= 240)
            return SO_G_POWERUP;
        return SO_G_PICKUP;
    }
    if (p->explosiveClass || so_in(so_explosive, t))
        return SO_G_EXPLO;
    /* 163..191 but the traffic light casings 170..173 and the briefcase 175 */
    if (t >= 163 && t <= 191 && (t < 170 || t == 174 || t >= 176))
        return SO_G_PHONE;
    return st == 5 ? SO_G_STREET : SO_G_OTHER;  /* a map object of the style */
}

/* the offered types, by group, then type */
static int so_rows(void)
{
    int n = 0;
    for (int t = 1; t < SO_NTYPES; t++) {
        ObjectPrefab *p = so_prefab(t);
        int g = p ? so_group(t, p) : -1;
        if (g >= 0)
            so_list[n++] = (uint32_t)g << 16 | (uint32_t)t;
    }
    for (int i = 1; i < n; i++) {       /* insertion sort, the keys are unique */
        uint32_t k = so_list[i];
        int c = i;
        for (; c > 0 && so_list[c - 1] > k; c--)
            so_list[c] = so_list[c - 1];
        so_list[c] = k;
    }
    return so_n = n;
}

/* our name into a buffer of 64: the game's own text for pickups (key c%02d,
 * Hud_Pickup_Show 0x4C69F0, Seq 27) unless it has a '+', which the menu font lacks; else
 * OBJECT_TYPE, else "Map object N" / "Object N" */
static void so_name(int t, char *buf)
{
    if (t >= 200 && t <= 244) {
        char key[16];
        snprintf(key, sizeof key, "c%02d", t - 200);
        if (dm_gxt(key, buf, 40) && !strchr(buf, '+'))
            return;
    }
    for (int i = 0; i < SO_NNAMES; i++)
        if (so_names[i].type == t) {
            strcpy(buf, so_names[i].name);
            return;
        }
    ObjectPrefab *p = so_prefab(t);
    snprintf(buf, 64, p && p->defaultSpriteType == 5 ? "Map object %d" : "Object %d", t);
}

/* "Group: name" */
static void so_rowfmt(int row, char *buf)
{
    strcpy(buf, so_gnames[so_list[row] >> 16]);
    strcat(buf, ": ");
    so_name((uint16_t)so_list[row], buf + strlen(buf));
}

/* remaps of its palette (StyleData +0x10 paletteCounts: +8 code obj, +0xA map obj), 0 if none */
static int so_nremaps(int t)
{
    ObjectPrefab *p = so_prefab(t);
    StyleData *st = GP(StyleData, rd32(STYLE_DATA));
    if (!p || !st || !st->paletteCounts)
        return 0;
    return rd16(st->paletteCounts + 2 * p->defaultSpriteType);  /* type 4 -> +8, 5 -> +0xA */
}

/* so_remap clamped to its remaps (-1 = own colours) */
static int so_remap_for(int t)
{
    return so_remap < so_nremaps(t) ? so_remap : -1;
}

static void so_spawn(void);

/* LEFT / RIGHT the remap, RETURN spawns */
static void so_rowchange(int row, int dir)
{
    int t = (uint16_t)so_list[row];
    int r = so_remap_for(t);
    if (!dir) {
        so_spawn_remap = r;
        so_spawn_type = t;
        dm_defer(so_spawn);
        return;
    }
    int n = so_nremaps(t);
    r += dir;                           /* wrap over -1 .. n - 1 */
    if (r < -1)
        r = n - 1;
    if (r >= n)
        r = -1;
    so_remap = r;
}

/* PAGE UP / PAGE DOWN jump to the previous / next group */
static int so_key(int dik)
{
    if (dik != DIK_PRIOR && dik != DIK_NEXT)
        return 0;
    int sel = dm_page->sel;
    if ((uint32_t)sel >= (uint32_t)so_n)
        return 0;                       /* on Back: the generic keys */
#define SO_G(i) (so_list[i] >> 16)
    uint32_t g = SO_G(sel);
    if (dik == DIK_NEXT) {
        do
            sel++;
        while (sel < so_n && SO_G(sel) == g);
        if (sel >= so_n)
            sel = 0;
    } else if (sel) {                   /* first row of this group, else of the one before */
        if (SO_G(sel - 1) != g)
            g = SO_G(sel - 1);
        do
            sel--;
        while (sel && SO_G(sel - 1) == g);
    }
#undef SO_G
    dm_page->sel = sel;
    return 1;
}

uint32_t km_spawn_object(int type, int remap, int32_t x, int32_t y, int32_t z, int rot)
{
    gptr fn = type >= 200 && type <= 244 ? 0x485480 : 0x4852E0;
    gptr obj = game_thiscall(fn, rd32(SO_SPAWNER), 5, (uint32_t)type, (uint32_t)x,
                             (uint32_t)y, (uint32_t)z, (uint32_t)rot);
    km_spawn_why = "Blocked here";
    if (!obj)
        return 0;
    gptr spr = GP(WorldObject, obj)->position;
    if (remap >= 0 && spr)
        game_thiscall(0x4B9B00, spr, 1, (uint32_t)remap);   /* Sprite_SetRemap */
    km_spawn_why = "Object spawned";
    return obj;
}

/* so_spawn (deferred): km_spawn_object 1.5 blocks in front of the player */
static void so_spawn(void)
{
    int32_t pos[4];
    gptr obj = 0;
    if (km_spawn_pos(pos, SPAWN_DIST))
        obj = km_spawn_object(so_spawn_type, so_spawn_remap, pos[0], pos[1], pos[2], pos[3]);
    if (obj)
        printf("menu: spawn object type %d -> WorldObject 0x%x at x 0x%x y 0x%x, remap %d\n",
               so_spawn_type, obj, pos[0], pos[1], so_spawn_remap);
    dm_toast_set(km_spawn_why);
}

/* the preview pane for the selected object, lines measured first like sc_draw */
static void so_draw(struct dm_page *page)
{
    if ((uint32_t)page->sel >= (uint32_t)dm_dyn())
        return;                         /* on Back */
    uint32_t e = so_list[page->sel];
    int t = (uint16_t)e;
    ObjectPrefab *p = so_prefab(t);
    if (!p)
        return;
    char l[SO_NLINES][SO_LINE];
    so_name(t, l[0]);
    snprintf(l[1], SO_LINE, "%s  type %d (0x%X)", so_gnames[e >> 16], t, t);
    uint32_t wh = dm_sprite_wh((int)p->defaultSpriteType, (uint16_t)p->defaultSpriteId);
    snprintf(l[2], SO_LINE, "%s sprite %d  %dx%d  %d fr",
             p->defaultSpriteType == 5 ? "Map obj" : "Code obj", (uint16_t)p->defaultSpriteId,
             wh & 0xFF, wh >> 8 & 0xFF, p->frameCount);
    strcpy(l[3], so_knames[p->kind > 12 ? 13 : p->kind]);  /* the kind and its flags */
    if (p->gridKind == 4)               /* obstacles grid */
        strcat(l[3], ", solid");
    if (p->impactMode == 2)
        strcat(l[3], ", pushable");
    if (p->explosiveClass)
        strcat(l[3], ", explosive");
    int r = so_remap_for(t), n = so_nremaps(t);
    if (!n)
        snprintf(l[4], SO_LINE, "No remaps");
    else if (r < 0)
        snprintf(l[4], SO_LINE, "Remap: own colours");
    else
        snprintf(l[4], SO_LINE, "Remap: %d of %d", r + 1, n);
    strcpy(l[5], "Left Right: remap");
    strcpy(l[6], "PgUp PgDn: group");
    strcpy(l[7], "Return: spawn");
    uint32_t w = SO_BOX;                /* width: the preview or the widest line */
    for (int i = 0; i < SO_NLINES; i++) {
        uint32_t lw = (uint32_t)dm_text_w(l[i]);
        if (lw > w)
            w = lw;
    }
    dm_pane(DM_Y, DM_Y + SO_PANE_H, (int)w);
    dm_text_at(l[0], dm_pane_x, DM_Y, 1);

    uint32_t frame = 0;                 /* only the animated kinds 2, 4, 8, 9 cycle their frames */
    if (p->kind <= 31 && (0x314u >> p->kind & 1)) {
        uint32_t tpf = p->ticksPerFrame ? p->ticksPerFrame : 1;
        frame = r_frames / (2 * tpf) % p->frameCount;  /* (frames / (2 * ticks per frame)) % count */
    }
    struct dm_sprite ds = {
        .type = (int32_t)p->defaultSpriteType,
        .id = (uint16_t)p->defaultSpriteId + (int32_t)frame,
        .pal = (int32_t)p->paletteBase,
        /* palette kind 2 ignores the prefab's remap, like ObjectPrefab_ApplyToPosition */
        .remap = p->paletteBase == 2 ? 0 : p->remap,
        .x = (int32_t)(w / 2) + dm_pane_x,
        .y = DM_Y + 18 + SO_BOX / 2 + 4,
    };
    if (r >= 0) {
        ds.remap = r;
        ds.pal = ds.type + 1;           /* 4 code obj -> palette kind 5, 5 map obj -> 6 */
    }
    uint32_t sw = wh & 0xFF, sh = wh >> 8 & 0xFF;   /* box = min(SO_BOX, SO_ZOOM x the diagonal) */
    uint32_t box = (uint32_t)(int32_t)sqrt((double)(sw * sw + sh * sh)) * SO_ZOOM;
    ds.box = (int32_t)(box > SO_BOX ? SO_BOX : box);
    dm_sprite(&ds);
    int y = DM_Y + SO_PANE_H - 7 * DM_LINE - DM_LINE / 2;  /* lines 1..7 at the bottom, */
    for (int i = 1; i < SO_NLINES; i++, y += DM_LINE) {    /* a gap before the keys */
        if (i == 5)
            y += DM_LINE / 2;
        dm_text_at(l[i], dm_pane_x, y, 0);
    }
}

DM_PAGE_EXTERN(dmp_spawn);
DM_PAGE(dmp_spawn_obj, dmp_spawn, 30, "Object", .draw = so_draw, .key = so_key,
        .rows = so_rows, .rowfmt = so_rowfmt, .rowchange = so_rowchange);
