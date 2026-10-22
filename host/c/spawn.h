/* spawn.h — spawn a car, ped or object at a position, the K menu's recipes (agreed with
 * Seq 55, which ports the K menu to C and owns this interface; host/c/ctl_spawn.c is
 * gta2ctl's stand-in until that port lands).
 *
 * Positions are SCR_f (Q14, 0x4000 = 1 block), rot an Ang16 (1440 per turn). Every call
 * returns the new object's game VA or 0, and sets km_spawn_why to a short text (the K
 * menu's toast) on success and on failure. Call only on the game's side of a frame
 * (DM_FRAME, hk_DrawUI, Vid_FlipBuffers, a hook), never from the input path. */
#ifndef SPAWN_H
#define SPAWN_H

#include <stdint.h>

extern const char *km_spawn_why;

/* remap: -1 random (the game's pick), 0 none (the sprite's colours), i = CarInfo.remap[i-1] */
uint32_t km_spawn_car(int model, int remap, int32_t x, int32_t y, int32_t z, int rot);
/* role: 0 auto (the look's natural role), else an sp_roles index; behave: 0 normal,
 * 1 hostile to the player, 2 follows the player */
uint32_t km_spawn_ped(int remap, int role, int behave, int32_t x, int32_t y, int32_t z, int rot);
/* remap: -1 the object's own, else a palette remap */
uint32_t km_spawn_object(int type, int remap, int32_t x, int32_t y, int32_t z, int rot);
/* out = {x, y, z, rot} dist in front of the player on foot, facing the same way; returns the
 * player's Sprite* or 0 (no player, in a car) */
uint32_t km_spawn_pos(int32_t out[4], int32_t dist);

#endif
