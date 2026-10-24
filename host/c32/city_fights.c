/* city_fights.c — mod: the city fights without the player. Cops attack gang members, gang
 * members attack cops, and more armed gang members walk the streets so rival gangs meet.
 *
 * Seams (RE: docs/re/gangs-and-peds.md §4, §6; Ghidra gta-2-recovered, own disassembly):
 * - Ped_ShouldReactToPed(Ped* observer, Ped* candidate) @0x4371D0, thiscall, ret 4: THE
 *   hostility predicate, al = 1 "observer attacks candidate" (callers: the area / line-of-
 *   sight threat scans, Ped_ThreatSearchCandidateFilter 0x4B9A10). Vanilla cops attack only a
 *   non-player that is attacking (flags & 0x800) or has task KILL_CHAR_ON_FOOT; gang members
 *   attack cops only with highRespectFlag (respect > 79). Rival gangs already hate each other
 *   (GangRespect.hostileToGang, init 1, no writer). Detoured at its entry: the original runs
 *   first; only a "no" is widened.
 * - DummyPedManager_SpawnAmbientPed @0x4404F0, stdcall(4 args), ret 0x10: an armed gang
 *   member only while g_ArmedGangPedCount (u8 @0x5E5BD4) < 4, and the gang band only while
 *   < 8; that is 4 for the whole city, so rivals rarely meet. Around the call the counter is
 *   lowered by up to ARMED_EXTRA and put back, so it stays exact (the spawn only adds 1, the
 *   makeAllCharsMuggers branch takes it back) and the cap becomes 4 + ARMED_EXTRA.
 * - Raiders: armed members only spawn in their own gang's zone (the zone at the spawn tile
 *   names the gang), so rivals meet only at zone borders. A mid-function hook at 0x440825 in
 *   that function (`mov ecx, [esi+0x17C]`, the gang read for Gang_PickWeaponByRespect, right
 *   after `ped->gang = gang` and the gang's remap) makes one armed member in RAID_ONE_IN a
 *   member of another gang of the level: its colours, its weapon, and a fight with the local
 *   gang as soon as they see each other.
 *
 * Off by default, and off = the vanilla result: both detours return what the original
 * returned. config.yaml `mods: city_fights: on` or K menu → Mods → "City fights" (host side:
 * c32_host.c).
 */
#include "c32.h"

C32_OFFSET(Ped, id, 0x200);
C32_OFFSET(Ped, group, 0x164);
C32_OFFSET(Ped, gang, 0x17C);
C32_OFFSET(Ped, pedClass, 0x238);
C32_OFFSET(Ped, occupation, 0x240);
C32_OFFSET(Ped, threatSearch, 0x288);
C32_OFFSET(Ped, remap, 0x244);
C32_OFFSET(GangRespect, present, 0x0);
C32_OFFSET(GangRespect, pedRemap, 0x101);
C32_OFFSET(Ped, attackersThisTick, 0x262);
C32_OFFSET(Ped, attackersLastTick, 0x263);

#define ARMED_GANG_COUNT ((volatile uint8_t *)0x5E5BD4)   /* g_ArmedGangPedCount, re/globals.csv */
#define ARMED_EXTRA 8                   /* armed gang members on top of the game's 4 */
#define RAID_ONE_IN 3                   /* one armed gang member in 3 is a raider */
#define GANGS ((GangRespectContainer *const *)0x5EB898)   /* g_GangRespect, re/globals.csv */
#define MAX_ATTACKERS 4                 /* the game's own cap for gang observers (0x4371D0) */

/* `test [ecx+0x21C], 0x2000000; jz; mov eax, [ecx+0x168]; ...`: the first check of the
 * predicate (an invisible ped with a sprite is never a target) */
GAME_FN(uint32_t, G2_FASTCALL, Ped_IsInvisibleWithSprite, 0x433DA0, (Ped *self));

typedef uint32_t (G2_THISCALL *should_react_fn)(Ped *self, Ped *cand);
static should_react_fn Ped_ShouldReactToPed;
typedef void (G2_STDCALL *spawn_ambient_fn)(int x, uint32_t y, int z, uint32_t rot);
static spawn_ambient_fn DummyPedManager_SpawnAmbientPed;

uint8_t city_fights;                    /* 0 = vanilla; set by the host */
C32_EXPORT(city_fights);

/* counters for the log line, exported for the host / debugging */
struct cf_stats { uint32_t cop_vs_gang, gang_vs_cop, extra_armed, raiders; };
struct cf_stats cf_stats;
C32_EXPORT(cf_stats);

/* the cop-like occupations of the predicate's two switches: POLICE, SWAT, FBI,
 * ARMY_IN_VEHICLE, POLICE_ON_FOOT, 30, ARMY_ON_FOOT, ROAD_BLOCK_GUARD */
static int is_cop(const Ped *p)
{
    switch (p->occupation) {
    case 24: case 25: case 26: case 27: case 29: case 30: case 31: case 37:
        return 1;
    }
    return 0;
}

static int player_centric(const Ped *p)
{
    /* threat search 3..6: AREA / LINE_OF_SIGHT _PLAYER_THREAT_ONLY / _PLAYER_ONLY */
    return p->threatSearch >= 3 && p->threatSearch <= 6;
}

/* one log line per new (observer, victim) pair: the predicate runs for every candidate of
 * every scan, so a plain log would flood; the last 16 pairs are remembered */
static void cf_note(const char *what, const Ped *self, const Ped *cand)
{
    static struct { const Ped *self, *cand; } seen[16];
    static unsigned next;
    for (unsigned i = 0; i < 16; i++)
        if (seen[i].self == self && seen[i].cand == cand)
            return;
    seen[next].self = self;
    seen[next].cand = cand;
    next = (next + 1) % 16;
    c32_log("city_fights: %s: ped %d (occ %d) attacks ped %d (occ %d)", what, self->id,
            (int)self->occupation, cand->id, (int)cand->occupation);
}

static uint32_t G2_THISCALL hk_should_react(Ped *self, Ped *cand)
{
    uint32_t r = Ped_ShouldReactToPed(self, cand);
    if (!city_fights || !cand || self == cand)
        return r;
    if (r & 0xFF) {
        if (self->gang && cand->gang && self->gang != cand->gang)
            cf_note("gang vs gang", self, cand);    /* native (hostileToGang), logged only */
        return r;
    }
    if (Ped_IsInvisibleWithSprite(cand) & 0xFF)
        return r;
    if (player_centric(self) || cand->pedClass == PED_CLASS_PLAYER)
        return r;                       /* the player is the game's business */
    if (self->group && self->group == cand->group)
        return r;
    if (cand->attackersLastTick >= MAX_ATTACKERS || cand->attackersThisTick >= MAX_ATTACKERS)
        return r;                       /* one victim does not take the whole precinct */
    if (!self->gang && is_cop(self) && cand->gang) {
        cf_stats.cop_vs_gang++;
        cf_note("cop vs gang", self, cand);
        return (r & ~0xFFu) | 1;
    }
    if (self->gang && !cand->gang && is_cop(cand)) {
        cf_stats.gang_vs_cop++;
        cf_note("gang vs cop", self, cand);
        return (r & ~0xFFu) | 1;
    }
    return r;
}

static void G2_STDCALL hk_spawn_ambient(int x, uint32_t y, int z, uint32_t rot)
{
    if (!city_fights) {
        DummyPedManager_SpawnAmbientPed(x, y, z, rot);
        return;
    }
    uint8_t before = *ARMED_GANG_COUNT;
    uint8_t lend = before < ARMED_EXTRA ? before : ARMED_EXTRA;
    *ARMED_GANG_COUNT = (uint8_t)(before - lend);
    DummyPedManager_SpawnAmbientPed(x, y, z, rot);
    uint8_t after = (uint8_t)(*ARMED_GANG_COUNT + lend);
    *ARMED_GANG_COUNT = after;
    if (after > before && before >= 4) {
        cf_stats.extra_armed++;
        c32_log("city_fights: armed gang member #%u (cap %u)", after, 4 + ARMED_EXTRA);
    }
}

/* our own generator: the game's Random_S16 would shift the level's random stream */
static uint32_t cf_rand(void)
{
    static uint32_t x = 0x9E3779B9u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

/* mid-hook at 0x440825, esi = the new armed gang member, ped->gang = the zone's gang */
static void hk_armed_gang_spawn(struct c32_regs *r)
{
    Ped *ped = (Ped *)r->esi;
    GangRespectContainer *gangs = *GANGS;
    if (!city_fights || !gangs || !ped->gang || cf_rand() % RAID_ONE_IN)
        return;
    GangRespect *rival[10];
    int n = 0;
    for (int i = 0; i < 10; i++)
        if (gangs->gang[i].present && &gangs->gang[i] != ped->gang)
            rival[n++] = &gangs->gang[i];
    if (!n)
        return;
    GangRespect *home = ped->gang, *g = rival[cf_rand() % n];
    ped->gang = g;                      /* the displaced `mov ecx, [esi+0x17C]` reads it */
    ped->remap = g->pedRemap;           /* Ped_SetRemap 0x433B90 is this one store */
    cf_stats.raiders++;
    c32_log("city_fights: ped %d raids %.4s turf as a %.4s member", ped->id,
            home->gangName, g->gangName);
}

static void city_fights_init(void)
{
    /* sub esp, 0xC; push esi; mov esi, [esp+0x14] */
    static const uint8_t react[] = { 0x83, 0xEC, 0x0C, 0x56, 0x8B, 0x74, 0x24, 0x14 };
    /* sub esp, 0x18; push ebx; push ebp; push esi */
    static const uint8_t spawn[] = { 0x83, 0xEC, 0x18, 0x53, 0x55, 0x56 };
    Ped_ShouldReactToPed = (should_react_fn)c32_detour(0x4371D0, react, sizeof react,
                                                       (void *)hk_should_react);
    DummyPedManager_SpawnAmbientPed = (spawn_ambient_fn)c32_detour(0x4404F0, spawn,
                                                                   sizeof spawn,
                                                                   (void *)hk_spawn_ambient);
    static const uint8_t armed[] = { 0x8B, 0x8E, 0x7C, 0x01, 0x00, 0x00 }; /* mov ecx,[esi+0x17C] */
    c32_midhook(0x440825, armed, sizeof armed, hk_armed_gang_spawn);
}
C32_INIT(city_fights_init);
