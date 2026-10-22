/* spawn.c — the K menu's Spawn page: a group for spawners. Each spawner is its own page
 * under dmp_spawn in its own file (spawn_car.c, spawn_ped.c, spawn_object.c). */
#include "dm.h"

DM_PAGE(dmp_spawn, dmp_root, 120, "Spawn");
