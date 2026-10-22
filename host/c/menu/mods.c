/* mods.c — the K menu's Mods page: switches for gameplay mods (C32, docs/c32.md). Each
 * mod registers its own row from its host side, e.g. "Car entry bonus" in
 * host/c/c32_host.c. */
#include "dm.h"

DM_PAGE(dmp_mods, dmp_root, 125, "Mods");
