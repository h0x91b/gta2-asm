/* wanted_thief.c — "Wanted thief" on the K menu's Spawn page (the row is host C:
 * host/c/menu/wanted_thief.c): a car thief in red, near the player, whom the police hunt
 * as they hunt a player with N stars (default 4): cop cars with sirens, cops on foot who
 * shoot, a SWAT van, roadblocks ahead of the car he steals. The player's own wanted level
 * is not touched. docs/wanted-thief.md.
 *
 * The police pursuit is not player-specific (Ghidra gta-2-recovered, decompiled
 * 2026-10-25; docs/re/gangs-and-peds.md section 6):
 * - PoliceManager (0x66B7A0) has pursuitTargets[4] at +0x464 (PolicePursuitTarget 0x7C).
 *   PoliceManager_UpdatePursuitTargets 0x4AA030 runs every slot from 0 up to the first
 *   empty one: stars from Ped_GetCopStars(criminal) 0x434C00 (= Ped.wantedPoints +0x20A,
 *   600/1600/3000/5000/8000/12000), crews dispatched by PoliceManager_DispatchCrewToPursuit
 *   0x4A9EF0 on a road tile near lastSeen, a SWAT van at 4 stars, FBI at 5, army at 6.
 *   PoliceCrew_Update 0x4AD600 gives the crew KILL_CHAR_ON_FOOT / DRIVE_AND_ATTACK_CHAR on
 *   target->criminal, any Ped. It only runs while g_policeHaveCriminals (0x66B7A4) == 1.
 * - The only player gates: PoliceManager_RegisterCriminal 0x4A9D60 (Ped_IsPlayerControlled),
 *   reached from Ped_Update only for pedClass 2 (`jnz` 0x44571C), and the cop branch of
 *   Ped_ShouldReactToPed 0x4371D0, which marks only a player as sighted.
 *
 * So the thief is put into a slot here, as RegisterCriminal would put a player, and kept
 * there every frame: wantedPoints pinned, g_policeHaveCriminals = 1, sighted
 * (PoliceManager_MarkCriminalSighted 0x4AACA0: lastSeen = his position, sightTimer 250; the
 * police always know where he is, so the chase never drops to SEARCHING), offscreenTicks 0
 * (a car thief, class 6, would despawn 100 ticks off screen and end the hunt). Cops he
 * passes attack him through the predicate (city_fights.c asks wt_hunted). When he dies or
 * leaves the game his stars go to 0 and the game's own ENDED branch sends the crews home.
 *
 * Slot 0 matters: UpdatePursuitTargets stops at the first empty slot, and only slot 0's
 * sightTimer counts down (PoliceManager_UpdateFirstPursuitTimer 0x4A9E80). The thief takes
 * slot 0 when it is free; whenever slot 0 is empty and a later one is not (the thief's hunt
 * ended while the player's own pursuit sat in slot 1), the later slot moves down and the
 * crews' target pointers follow, so neither pursuit is left frozen.
 *
 * One thief at a time: a new one ends the old one's hunt.
 */
#include "c32.h"

C32_OFFSET(Ped, wantedPoints, 0x20A);
C32_OFFSET(Ped, offscreenTicks, 0x20E);
C32_OFFSET(Ped, id, 0x200);
C32_OFFSET(Ped, nextPed, 0x160);
C32_OFFSET(Ped, currentCar, 0x16C);
C32_OFFSET(Ped, position, 0x1AC);
C32_OFFSET(Ped, lifeState, 0x234);
C32_OFFSET(Ped, health, 0x216);
C32_OFFSET(Ped, objectiveTargetCar, 0x150);
C32_OFFSET(Ped, enterCarAsPassenger, 0x248);
C32_OFFSET(Ped, targetCarDoor, 0x24C);
C32_OFFSET(Ped, goalPosition, 0x1B8);
C32_OFFSET(Ped, objective, 0x258);
C32_OFFSET(Car, id, 0x6C);
C32_OFFSET(Ped, occupation, 0x240);
C32_OFFSET(Ped, objectiveTargetPed, 0x148);
C32_OFFSET(Ped, taskTargetPed, 0x14C);
C32_OFFSET(Ped, state, 0x278);
C32_OFFSET(PedManager, activeListHead, 0x4);
C32_OFFSET(PoliceManager, crews, 0x4);
C32_OFFSET(PoliceManager, pursuitTargets, 0x464);
C32_OFFSET(PoliceManager, copLevel, 0x654);
C32_OFFSET(PolicePursuitTarget, state, 0x8);
C32_OFFSET(PolicePursuitTarget, sightTimer, 0xC);
C32_OFFSET(PolicePursuitTarget, lastSeenX, 0x10);
C32_OFFSET(PolicePursuitTarget, numPoliceCrews, 0x70);
C32_OFFSET(PolicePursuitTarget, numCrews, 0x75);
C32_OFFSET(PoliceCrew, target, 0x14);
C32_OFFSET(PoliceCrew, vehSlot, 0x10);
C32_OFFSET(PoliceCrew, active, 0x1C);
C32_OFFSET(PoliceCrew, state, 0x24);
C32_OFFSET(PoliceManager, liveTrafficCrews, 0x658);
C32_OFFSET(EmergencyVehicleSlot, car, 0x0);
C32_OFFSET(Car, body, 0x50);
C32_OFFSET(Sprite, x, 0x14);
C32_ASSERT(sizeof(PolicePursuitTarget) == 0x7C && sizeof(PoliceCrew) == 0x38);

#define G_PEDMGR        0x5E5BBC        /* g_PedManager: PedManager* */
#define G_POLICE        0x66B7A0        /* g_PoliceManager: PoliceManager* */
#define G_HAVE_CRIM     0x66B7A4        /* g_policeHaveCriminals, byte */
#define PED_ALIVE       99              /* Ped.lifeState */
#define PED_WASTED      9               /* Ped.state */
#define WT_MAXPEDS      400             /* the pool has 200; a broken list cannot hang us */
#define WT_STEAL_FRAMES 300             /* `hunt steal`: the order is renewed this long */
#define WT_HEALTH       300             /* a ped has 100: at 4 stars he would last ~5 s */
#define WT_LOG_EVERY    60              /* frames between two "hunters" checks */
#define WT_RB_AFTER     90              /* frames in a car before a roadblock goes up ahead */
#define WT_RB_GAP       600             /* frames between two roadblocks */
#define WT_RB_MAX       2               /* ours at once; the oldest goes for a new one */
#define WT_ADOPT_RANGE  (24 << 14)      /* patrol cars this close join the chase (Chebyshev) */
#define WT_ADOPT_EVERY  15              /* frames between two looks for patrol cars */
#define WT_KICK_AFTER   60              /* frames IDLE before we dispatch the first crew */
#define G_CREW_TYPE     0x66B788        /* g_crewSpawnType: the next dispatch's crew */
#define G_CREW_TIMER    0x66B78C        /* g_crewSpawnTimer, short */
#define G_CREW_STATE    0x66B790        /* g_crewSpawnState */
#define G_CREW_KIND     0x66B798        /* g_crewSpawnKind */

GAME_FN(void, G2_THISCALL, PoliceManager_MarkCriminalSighted, 0x4AACA0,
        (PoliceManager *self, Ped *criminal));
GAME_FN(uint32_t, G2_FASTCALL, Ped_IsActive, 0x433B40, (Ped *self));
GAME_FN(uint32_t, G2_THISCALL, PoliceManager_DispatchCrewToPursuit, 0x4A9EF0,
        (PoliceManager *self, PolicePursuitTarget *target));
GAME_FN(void, G2_THISCALL, PoliceCrew_AddToPursuit, 0x4A9720, (PoliceCrew *self));
GAME_FN(void, G2_FASTCALL, Car_SirenOn, 0x422D20, (Car *self));
GAME_FN(void, G2_THISCALL, Ped_SetObjective, 0x43BBC0, (Ped *self, int objective, int timer));
GAME_FN(void, G2_THISCALL, Ped_SetTask, 0x436920, (Ped *self, int task, int timer));

int rb_place_near(Ped *ped, int kind);  /* roadblocks.c */
void rb_remove_slot(int slot);

static const int16_t star_points[7] = { 0, 600, 1600, 3000, 5000, 8000, 12000 };

/* the hunt, readable by the host (host/c/menu/wanted_thief.c, gta2ctl `hunt`) */
struct wt_status {
    uint32_t ped;                       /* Ped* of the thief, 0 = no hunt */
    int32_t id;                         /* his Ped.id */
    int32_t stars;
    int32_t slot;                       /* pursuit slot, -1 none */
    int32_t state;                      /* PURSUIT_STATE of that slot */
    int32_t crews, police_crews, swat_crews;
    int32_t hunters;                    /* cops with him as task / objective target */
    int32_t roadblocks;                 /* placed for him so far */
    uint32_t frames;                    /* since the hunt began */
};
struct wt_status wt_status = { .slot = -1 };
C32_EXPORT(wt_status);

static Ped *closing;                    /* an ended hunt whose slot is still in use */
static int touched;                     /* a hunt has run: from then on we keep the slots packed */
static int rb[WT_RB_MAX] = { -1, -1 };
static uint32_t car_frames, rb_last;
static Car *steal_car;                  /* `hunt steal`: the car, until he sits in one */
static uint32_t steal_frames;

static PoliceManager *police(void) { return *(PoliceManager *volatile *)G_POLICE; }

static int slot_of(PoliceManager *pm, Ped *ped)
{
    for (int i = 0; i < 4; i++)
        if (pm->pursuitTargets[i].criminal == ped)
            return i;
    return -1;
}

/* slot 0 empty, a later one not: move it down, crews follow (see the header) */
static void compact(PoliceManager *pm)
{
    PolicePursuitTarget *t = pm->pursuitTargets;
    if (t[0].criminal)
        return;
    for (int k = 1; k < 4; k++) {
        if (!t[k].criminal)
            continue;
        t[0] = t[k];
        for (int c = 0; c < 20; c++)
            if (pm->crews[c].target == &t[k])
                pm->crews[c].target = &t[0];
        uint8_t *p = (uint8_t *)&t[k];
        for (unsigned j = 0; j < sizeof t[k]; j++)
            p[j] = 0;
        c32_log("wanted_thief: pursuit slot %d moved to 0 (%s)", k,
                t[0].criminal->player ? "a player" : "a ped");
        return;
    }
}

/* the thief into a free slot, as RegisterCriminal fills one (slot 0 first) */
static int enrol(PoliceManager *pm, Ped *ped)
{
    int s = slot_of(pm, ped);
    if (s >= 0)
        return s;
    for (s = 0; s < 4 && pm->pursuitTargets[s].criminal; s++)
        ;
    if (s == 4)
        return -1;
    PolicePursuitTarget *t = &pm->pursuitTargets[s];
    t->criminal = ped;
    t->state = PURSUIT_IDLE;
    t->lastSeenX = ped->position.x;
    t->lastSeenY = ped->position.y;
    t->lastSeenZ = ped->position.z;
    c32_log("wanted_thief: ped %d in pursuit slot %d", ped->id, s);
    return s;
}

static int any_criminal(PoliceManager *pm)
{
    for (int i = 0; i < 4; i++)
        if (pm->pursuitTargets[i].criminal)
            return 1;
    return 0;
}

/* an ended hunt: stars 0, then the slot freed by the game's ENDED branch (or by us when it
 * never got a crew: IDLE has no way out) */
static void finish_closing(PoliceManager *pm)
{
    int s = slot_of(pm, closing);
    if (s < 0) {
        closing = 0;
        return;
    }
    PolicePursuitTarget *t = &pm->pursuitTargets[s];
    if (t->state == PURSUIT_IDLE && !t->numCrews)
        t->criminal = 0;
    else
        t->state = PURSUIT_ENDED;
}

static void end_hunt(const char *why)
{
    Ped *ped = (Ped *)wt_status.ped;
    c32_log("wanted_thief: hunt over after %u frames: %s (%d roadblocks, %d hunters at the end)",
            wt_status.frames, why, wt_status.roadblocks, wt_status.hunters);
    if (ped && (Ped_IsActive(ped) & 0xFF) && ped->id == wt_status.id)
        ped->wantedPoints = 0;
    closing = ped;
    for (int i = 0; i < WT_RB_MAX; i++) {
        rb_remove_slot(rb[i]);
        rb[i] = -1;
    }
    wt_status.ped = 0;
    wt_status.slot = -1;
}

/* cops with the thief as their task or objective target */
static int count_hunters(Ped *thief)
{
    PedManager *pm = *(PedManager *volatile *)G_PEDMGR;
    int n = 0, guard = WT_MAXPEDS;
    for (Ped *p = pm ? pm->activeListHead : 0; p && guard--; p = p->nextPed)
        if (p != thief && p->lifeState == PED_ALIVE &&
            (p->taskTargetPed == thief || p->objectiveTargetPed == thief))
            n++;
    return n;
}

/* a roadblock ahead of his car once he has driven a while, the oldest of ours removed */
static void roadblocks(Ped *ped)
{
    car_frames = ped->currentCar ? car_frames + 1 : 0;
    if (car_frames < WT_RB_AFTER || wt_status.stars < 3 ||
        (rb_last && wt_status.frames - rb_last < WT_RB_GAP))
        return;
    int i = rb[0] < 0 ? 0 : rb[1] < 0 ? 1 : 0;
    if (rb[i] >= 0) {
        rb_remove_slot(rb[i]);
        rb[i] = -1;
    }
    rb_last = wt_status.frames;         /* also after a miss: no retry every frame */
    rb[i] = rb_place_near(ped, wt_status.stars >= 6 ? 2 : wt_status.stars == 5 ? 1 : 0);
    if (rb[i] >= 0) {
        wt_status.roadblocks++;
        c32_log("wanted_thief: roadblock ahead of ped %d (slot %d)", ped->id, rb[i]);
    }
}

/* Patrol cars near him join the chase, as PoliceManager_AssignCarCrewToCriminal 0x4AABB0
 * does for a player a cop has seen (that one refuses a non-player: Ped_IsPlayerControlled):
 * target, PURSUE, AddToPursuit, siren. Not a crew busy with another criminal, not past the
 * 6 crews a slot holds. */
static void adopt_patrols(PoliceManager *pm, PolicePursuitTarget *t, Ped *ped)
{
    for (int c = 0; c < 20 && t->numCrews < 6; c++) {
        PoliceCrew *crew = &pm->crews[c];
        if (crew->active != 1 || crew->state != POLICE_CREW_PATROL || !crew->vehSlot)
            continue;
        if (crew->target && crew->target != t && crew->target->criminal)
            continue;
        Car *car = crew->vehSlot->car;
        Sprite *b = car ? car->body : 0;
        if (!b)
            continue;
        int dx = b->x - ped->position.x, dy = b->y - ped->position.y;
        if ((dx < 0 ? -dx : dx) > WT_ADOPT_RANGE || (dy < 0 ? -dy : dy) > WT_ADOPT_RANGE)
            continue;
        if (crew->vehSlot->crewType != EMERGENCY_CREW_ARMY && t->wantedLevel == 6)
            continue;                   /* the game's rule: only the army at 6 stars */
        t->state = PURSUIT_ACTIVE;
        crew->target = t;
        crew->state = POLICE_CREW_PURSUE;
        PoliceCrew_AddToPursuit(crew);
        if (crew->vehSlot->crewType != EMERGENCY_CREW_ARMY)
            Car_SirenOn(car);
        c32_log("wanted_thief: patrol car %d joins the chase of ped %d", car->id, ped->id);
    }
}

/* UpdatePursuitTargets dispatches the first crew from IDLE only while no patrol car exists
 * (liveTrafficCrews == 0; for a player the patrol cars are adopted when a cop sees him).
 * Downtown always has some, so a thief nobody has seen yet gets that first crew here, with
 * the IDLE branch's own settings (0x4AA4A0..). */
static void kick_idle(PoliceManager *pm, PolicePursuitTarget *t, uint32_t *idle)
{
    if (t->state != PURSUIT_IDLE || t->numPoliceCrews || !pm->liveTrafficCrews) {
        *idle = 0;
        return;
    }
    if (++*idle < WT_KICK_AFTER)
        return;
    *idle = 0;
    *(volatile int16_t *)G_CREW_TIMER = 200;
    *(volatile uint32_t *)G_CREW_TYPE = EMERGENCY_CREW_POLICE;
    *(volatile uint32_t *)G_CREW_STATE = POLICE_CREW_ALERTED;
    *(volatile uint32_t *)G_CREW_KIND = POLICE_CREW_KIND_POLICE;
    if (PoliceManager_DispatchCrewToPursuit(pm, t) & 0xFF) {
        t->state = PURSUIT_RESPONDING;
        c32_log("wanted_thief: first crew dispatched (%d patrol cars about)",
                pm->liveTrafficCrews);
    }
}

/* `hunt steal`: ENTER_CAR on that car, renewed while he is on foot and not on it (a flee
 * task from the threat scan can win the first tick: measured, one run in three) */
static void steal(Ped *ped)
{
    if (!steal_car)
        return;
    if (ped->currentCar || ++steal_frames > WT_STEAL_FRAMES) {
        c32_log("wanted_thief: steal order done: %s", ped->currentCar ? "in a car" : "gave up");
        steal_car = 0;
        return;
    }
    if (ped->objective == 35 && ped->objectiveTargetCar == steal_car)
        return;
    Ped_SetTask(ped, 0, 9999);          /* drop a flee task, as the crew code does */
    Ped_SetObjective(ped, 35, 9999);    /* ENTER_CAR, then his own AI drives off */
    ped->objectiveTargetCar = steal_car;
    ped->enterCarAsPassenger = 0;
    ped->targetCarDoor = 0;
    /* Ped_UpdateCarThief drops ENTER_CAR when goalPosition is far from him, and the goal
     * is only worked out from the car after it ran: start it at the car (measured: every
     * order dropped on the next tick without this) */
    Sprite *b = steal_car->body;
    if (b) {
        ped->goalPosition.x = b->x;
        ped->goalPosition.y = b->y;
        ped->goalPosition.z = b->z;
    }
}

/* 1 when cand is the hunted thief (city_fights.c: cops attack him) */
int wt_hunted(const Ped *cand)
{
    return wt_status.ped && cand == (const Ped *)wt_status.ped;
}

/* Once per gameplay frame, from the host's DM_FRAME: req 1 = hunt ped (a Ped*, freshly
 * spawned) at `stars` stars; req 2 = the thief steals that car now (a Car*; gta2ctl
 * `hunt steal`, for tests): the ENTER_CAR order Ped_UpdateCarThief 0x442050 gives him
 * itself when the nearest car is an ambient one. Returns a toast, or 0. */
const char *G2_STDCALL wt_frame(uint32_t req, uint32_t ped_va, uint32_t stars)
{
    PoliceManager *pm = police();
    const char *toast = 0;
    if (!pm)
        return 0;
    if (req == 1 && ped_va) {
        if (wt_status.ped)
            end_hunt("a new thief");
        Ped *ped = (Ped *)ped_va;
        wt_status = (struct wt_status){ .ped = ped_va, .id = ped->id, .slot = -1,
                                        .stars = stars < 1 || stars > 6 ? 4 : (int)stars };
        car_frames = rb_last = 0;
        steal_car = 0;
        touched = 1;
        ped->health = WT_HEALTH;
        c32_log("wanted_thief: ped %d hunted at %d stars", ped->id, wt_status.stars);
        toast = "Wanted thief spawned";
    }
    if (req == 2 && ped_va && wt_status.ped) {
        steal_car = (Car *)ped_va;
        steal_frames = 0;
        c32_log("wanted_thief: ped %d told to steal car %d", wt_status.id, steal_car->id);
    }
    if (closing)
        finish_closing(pm);
    Ped *ped = (Ped *)wt_status.ped;
    if (ped) {
        if (ped->id == wt_status.id && ped->state == PED_WASTED)
            end_hunt(ped->currentCar ? "he is dead, in his car" : "he is dead");
        else if (!(Ped_IsActive(ped) & 0xFF) || ped->id != wt_status.id)
            end_hunt("he left the game");
        else if (ped->lifeState != PED_ALIVE)
            end_hunt("he is dead");
    }
    ped = (Ped *)wt_status.ped;
    if (ped) {
        wt_status.frames++;
        ped->wantedPoints = star_points[wt_status.stars];
        ped->offscreenTicks = 0;
        int s = enrol(pm, ped);
        if (s < 0) {
            end_hunt("no free pursuit slot");
            toast = "No free pursuit slot";
        } else {
            PoliceManager_MarkCriminalSighted(pm, ped);
            PolicePursuitTarget *t = &pm->pursuitTargets[s];
            static uint32_t idle;
            kick_idle(pm, t, &idle);
            if (wt_status.frames % WT_ADOPT_EVERY == 0)
                adopt_patrols(pm, t, ped);
            if (s != wt_status.slot || (int)t->state != wt_status.state ||
                t->numCrews != wt_status.crews || t->numSwatCrews != wt_status.swat_crews)
                c32_log("wanted_thief: slot %d state %d, crews %d (police %d, swat %d), "
                        "copLevel %d", s, (int)t->state, t->numCrews, t->numPoliceCrews,
                        t->numSwatCrews, pm->copLevel);
            wt_status.slot = s;
            wt_status.state = (int)t->state;
            wt_status.crews = t->numCrews;
            wt_status.police_crews = t->numPoliceCrews;
            wt_status.swat_crews = t->numSwatCrews;
            if (wt_status.frames % WT_LOG_EVERY == 0) {
                int h = count_hunters(ped);
                if (h != wt_status.hunters)
                    c32_log("wanted_thief: %d cops after ped %d", h, ped->id);
                wt_status.hunters = h;
            }
            roadblocks(ped);
            steal(ped);
        }
    }
    if (touched) {                      /* until the first thief: vanilla, untouched */
        compact(pm);
        if (any_criminal(pm))
            *(volatile uint8_t *)G_HAVE_CRIM = 1;
    }
    return toast;
}
C32_EXPORT(wt_frame);
