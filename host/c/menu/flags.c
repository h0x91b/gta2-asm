/* flags.c — the K menu's Debug flags page: a few of the game's own debug flags, written
 * straight into their bytes, which HiddenDebugFlags 0x451930 filled from the registry at
 * startup; the game reads them as it goes. The Road network overlay (debug_roads.asm)
 * registers its row here from its own file.
 * Flag addresses: HiddenDebugFlags 0x451930 (each RegGet result is stored with
 * `mov [addr], al`; own disassembly, 74 of 74 flags; matches seuko-mod's Cheats @0x5EAD51).
 * Flag names as in h0x91b/gta2-resurection (https://github.com/h0x91b/gta2-resurection),
 * gta2-resurected.ct and its Ghidra archive gta2-resurected.exe.gzf @87e1d98. */
#include "dm.h"

DM_PAGE(dmp_flags, dmp_root, 130, "Debug flags");
DM_ITEM(dmp_flags, 10, DM_FLAG, "Show FPS: ", 0x5EAD79);           /* do_show_timing */
DM_ITEM(dmp_flags, 20, DM_FLAG, "Show camera info: ", 0x5EAD82);   /* do_show_camera */
DM_ITEM(dmp_flags, 30, DM_FLAG, "Show counters: ", 0x5EAD95);      /* do_show_counters */
DM_ITEM(dmp_flags, 40, DM_FLAG, "Show all arrows: ", 0x5EADB2);    /* show_all_arrows */
DM_ITEM(dmp_flags, 50, DM_FLAG, "Invulnerable: ", 0x5EAD71);       /* do_invulnerable */
DM_ITEM(dmp_flags, 60, DM_FLAG, "Infinite lives: ", 0x5EAD61);     /* do_infinite_lives */
DM_ITEM(dmp_flags, 70, DM_FLAG, "Keep weapons: ", 0x5EAD9E);       /* keep_weapons_after_death */
DM_ITEM(dmp_flags, 80, DM_FLAG, "Free shopping: ", 0x5EAD84);      /* do_free_shopping */
DM_ITEM(dmp_flags, 90, DM_FLAG, "No police: ", 0x5EAD5E);          /* skip_police */
