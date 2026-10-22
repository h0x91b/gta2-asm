/* spawn.h — spawning cars, peds and objects the way the K menu's Spawn pages do, as plain
 * functions with no UI (host/c/menu/: helpers.c, spawn_car.c, spawn_ped.c,
 * spawn_object.c). The menu calls them; so may any host C (gta2ctl, Seq 58).
 *
 * Positions are SCR_f (14 fraction bits) x, y, z, rot is a Sprite rotation (1440 per turn,
 * 0 = facing +y). Each returns the new game object's VA, or 0, and sets km_spawn_why to
 * the menu's toast text (also on success, e.g. "Car spawned"). Call them on the game's side
 * of a frame (a DM_FRAME, hk_DrawUI, Vid_FlipBuffers, a hook), never from the input path:
 * they call into the game.
 */
#ifndef SPAWN_H
#define SPAWN_H

#include <stdint.h>

extern const char *km_spawn_why;

/* where the menu spawns: dist (SCR_f) in front of the player on foot, facing the same way;
 * out = x, y, z, rot. -> the player's Sprite*, or 0 (no player, in a car) */
uint32_t km_spawn_pos(int32_t out[4], int32_t dist);

/* model = CAR_MODEL4 id (SpawnCar refuses some: dm_spawnable lists the good ones);
 * remap -1 the game's random pick, 0 none (the sprite's own colours),
 * i = CarInfo.remap[i - 1]. -> Car* */
uint32_t km_spawn_car(int model, int remap, int32_t x, int32_t y, int32_t z, int rot);

/* remap = PED_REMAP 0..52 (the look); role 0 auto (the look's own) or a role index:
 * 1 civilian, 2 gang member, 3 cop, 4 SWAT, 5 FBI, 6 army, 7 medic, 8 fireman, 9 Elvis,
 * 10 mugger, 11 car thief, 12 psycho, 13 criminal, 14 stand-still bloke;
 * behave 0 normal, 1 hostile (kills the player), 2 follows the player (joins his group).
 * -> Ped* */
uint32_t km_spawn_ped(int remap, int role, int behave, int32_t x, int32_t y, int32_t z, int rot);

/* type = OBJECT_TYPE (pickups 200..244 go through the game's pickup path, with their
 * default ammo); remap -1 the prefab's own colours, else a remap of its palette.
 * -> WorldObject*, 0 = "Blocked here" (something in the way, a full pool) */
uint32_t km_spawn_object(int type, int remap, int32_t x, int32_t y, int32_t z, int rot);

#endif
