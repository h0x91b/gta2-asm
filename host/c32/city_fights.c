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
 * - Foot cops: Downtown declares police-ped ratio 0 in every MAP_ZONE, so it never has any
 *   and the cops of this mod never met a gang member in real play (docs/city-fights.md).
 *   Around the same spawn call the zone record's policePedRatio (GetDensity 0x465250) is
 *   raised to the game's default 40 and g_FootCopPedCount (0x5E5BD3, a 0/1 flag) is lent
 *   while fewer than FOOT_COPS walk; both are put back after the call.
 * - The wanted thief (wanted_thief.c): any cop attacks him, mod on or off.
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
C32_OFFSET(Ped, nextPed, 0x160);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(Ped, position, 0x1AC);
C32_OFFSET(Ped, task, 0x25C);
C32_OFFSET(Ped, taskTargetPed, 0x14C);
C32_OFFSET(PedManager, activeListHead, 0x4);

#define ARMED_GANG_COUNT ((volatile uint8_t *)0x5E5BD4)   /* g_ArmedGangPedCount, re/globals.csv */
#define ARMED_EXTRA 8                   /* armed gang members on top of the game's 4 */
#define RAID_ONE_IN 3                   /* one armed gang member in 3 is a raider */
#define GANGS ((GangRespectContainer *const *)0x5EB898)   /* g_GangRespect, re/globals.csv */
#define MAX_ATTACKERS 4                 /* the game's own cap for gang observers (0x4371D0) */
#define FOOT_COP_FLAG ((volatile uint8_t *)0x5E5BD3)  /* g_FootCopPedCount, a 0/1 flag */
#define FOOT_COPS 3                     /* foot cops at once (the game: 1) */
#define FOOT_COP_RATIO 40               /* per mille, the game's default policePedRatio */
#define G_MAPBLOCKS 0x662C08            /* MapBlocks* */
#define G_PEDMGR 0x5E5BBC               /* g_PedManager: PedManager* */
#define CF_MAXPEDS 400                  /* the pool has 200; a broken list cannot hang us */

/* `test [ecx+0x21C], 0x2000000; jz; mov eax, [ecx+0x168]; ...`: the first check of the
 * predicate (an invisible ped with a sprite is never a target) */
GAME_FN(uint32_t, G2_FASTCALL, Ped_IsInvisibleWithSprite, 0x433DA0, (Ped *self));
/* the zone record at tile (x, y): the first zone of type 10/1/15 there, else the default */
GAME_FN(MapZoneInfo *, G2_THISCALL, GetDensity, 0x465250, (void *self, int x, int y));

typedef uint32_t (G2_THISCALL *should_react_fn)(Ped *self, Ped *cand);
static should_react_fn Ped_ShouldReactToPed;
typedef void (G2_STDCALL *spawn_ambient_fn)(int x, uint32_t y, int z, uint32_t rot);
static spawn_ambient_fn DummyPedManager_SpawnAmbientPed;

uint8_t city_fights;                    /* 0 = vanilla; set by the host */
C32_EXPORT(city_fights);

/* counters for the log line, exported for the host / debugging */
struct cf_stats { uint32_t cop_vs_gang, gang_vs_cop, extra_armed, raiders, foot_cops; };
struct cf_stats cf_stats;
C32_EXPORT(cf_stats);

/* what the predicate saw since the last census (cf_frame): calls with a cop observer, of
 * them with a gang candidate, and with the cop in a car */
static struct { uint32_t cop, cop_gang, cop_in_car, gang_obs; } cf_seen;

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

int wt_hunted(const Ped *cand);         /* wanted_thief.c */

static uint32_t G2_THISCALL hk_should_react(Ped *self, Ped *cand)
{
    uint32_t r = Ped_ShouldReactToPed(self, cand);
    if (cand && self != cand && !self->gang && is_cop(self) && wt_hunted(cand))
        return (r & ~0xFFu) | 1;        /* the wanted thief: every cop goes for him */
    if (!city_fights || !cand || self == cand)
        return r;
    if (!self->gang && is_cop(self)) {
        cf_seen.cop++;
        cf_seen.cop_gang += cand->gang != 0;
        cf_seen.cop_in_car += self->currentCar != 0;
    } else if (self->gang) {
        cf_seen.gang_obs++;
    }
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

/* live foot cops (POLICE_ON_FOOT) */
static int foot_cops(void)
{
    PedManager *pm = *(PedManager *volatile *)G_PEDMGR;
    int n = 0, guard = CF_MAXPEDS;
    for (Ped *p = pm ? pm->activeListHead : 0; p && guard--; p = p->nextPed)
        n += p->occupation == 29;
    return n;
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
    /* foot cops: the zone's ratio up to the game's default, the one-at-a-time flag lent
     * while fewer than FOOT_COPS walk */
    MapZoneInfo *zone = GetDensity(*(void *volatile *)G_MAPBLOCKS, x >> 14, (int)y >> 14);
    uint16_t ratio = zone ? zone->policePedRatio : 0;
    if (zone && ratio < FOOT_COP_RATIO)
        zone->policePedRatio = FOOT_COP_RATIO;
    uint8_t flag = *FOOT_COP_FLAG;
    int cops = flag ? foot_cops() : 0;
    if (flag && cops < FOOT_COPS)
        *FOOT_COP_FLAG = 0;
    DummyPedManager_SpawnAmbientPed(x, y, z, rot);
    if (zone)
        zone->policePedRatio = ratio;
    if (!*FOOT_COP_FLAG)
        *FOOT_COP_FLAG = flag;          /* nothing spawned: as it was */
    else if (!flag || cops < FOOT_COPS) {
        int now = foot_cops();
        if (now > (flag ? cops : 0)) {
            cf_stats.foot_cops++;
            c32_log("city_fights: foot cop #%d (cap %d)", now, FOOT_COPS);
        }
    }
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

#define CF_CENSUS       900             /* frames between two census lines (~30 s) */

/* Once per gameplay frame while on, from the host (c32_host.c): every CF_CENSUS frames one
 * log line of who is out there (cops on foot and in cars, armed gang members, the nearest
 * cop-to-gang distance on foot) and what the predicate was asked since the last line. It is
 * the evidence for "cops ignore gangs in normal play" (docs/city-fights.md). */
void G2_STDCALL cf_frame(void)
{
    static uint32_t n;
    if (++n % CF_CENSUS)
        return;
    PedManager *pm = *(PedManager *volatile *)G_PEDMGR;
    if (!pm)
        return;
    Ped *foot[16], *gang[32];
    int nfoot = 0, ngang = 0, ncar = 0, all = 0, fighting = 0;
    for (Ped *p = pm->activeListHead; p && all < CF_MAXPEDS; p = p->nextPed, all++) {
        if (p->task == 20 && p->taskTargetPed && p->taskTargetPed->pedClass != PED_CLASS_PLAYER)
            fighting++;
        if (!p->gang && is_cop(p)) {
            if (p->currentCar)
                ncar++;
            else if (nfoot < 16)
                foot[nfoot++] = p;
        } else if (p->gang && !p->currentCar && ngang < 32) {
            gang[ngang++] = p;
        }
    }
    int best = -1;                      /* nearest foot cop to a gang member, blocks */
    for (int i = 0; i < nfoot; i++)
        for (int j = 0; j < ngang; j++) {
            int dx = (foot[i]->position.x - gang[j]->position.x) >> 14;
            int dy = (foot[i]->position.y - gang[j]->position.y) >> 14;
            int d = (dx < 0 ? -dx : dx) > (dy < 0 ? -dy : dy) ? (dx < 0 ? -dx : dx)
                                                                : (dy < 0 ? -dy : dy);
            if (best < 0 || d < best)
                best = d;
        }
    c32_log("city_fights: census: %d peds, cops %d on foot / %d in cars, gang on foot %d, "
            "nearest foot cop-gang %d blocks, %d fighting a non-player; predicate since: "
            "cop observer %u (gang cand %u, in a car %u), gang observer %u; widened cop %u gang %u",
            all, nfoot, ncar, ngang, best, fighting, cf_seen.cop, cf_seen.cop_gang,
            cf_seen.cop_in_car, cf_seen.gang_obs, cf_stats.cop_vs_gang, cf_stats.gang_vs_cop);
    cf_seen.cop = cf_seen.cop_gang = cf_seen.cop_in_car = cf_seen.gang_obs = 0;
}
C32_EXPORT(cf_frame);

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
