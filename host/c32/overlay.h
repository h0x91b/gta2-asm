/* overlay.h — drawing over the world from C32 (overlay.c): the shared toolkit of the K
 * menu's world overlays, "Ped paths" (debug_paths.c) and "Road network" (debug_roads.c).
 *
 * World points (SCR_f, 1.0 = 0x4000 = one block) go through the game's own
 * WorldPointToScreen on the player's camera and come back as back-buffer pixels; boxes are
 * the game's DrawFlatRect2D in those pixels. Sizes given "in units" are 640x480 units,
 * scaled by the main camera's uiScale like the HUD. Every call happens on the game's side
 * of a frame (a DM_FRAME hook call32s the overlay), before the HUD is drawn.
 */
#ifndef OVERLAY_H
#define OVERLAY_H

#include "c32.h"

struct ov_pt {
    int32_t x, y;                       /* back-buffer pixels */
};

extern Camera *ov_cam;                  /* the player's camera, set by ov_setup */
extern int32_t ov_scale;                /* the main camera's uiScale (SCR_f) */

int ov_setup(void);                     /* 1 when there is a player camera to draw for */
Player *ov_player(void);                /* Game->currentPlayer, or 0 */
struct ov_pt ov_project(int32_t x, int32_t y, int32_t z);
void ov_box(int32_t x1, int32_t y1, int32_t x2, int32_t y2, uint32_t argb);
void ov_rect(int32_t x, int32_t y, int32_t half, uint32_t argb);  /* half size in pixels */
void ov_mark(struct ov_pt p, int32_t half_units, uint32_t argb);
void ov_line(struct ov_pt a, struct ov_pt b, uint32_t argb);      /* dotted, ends excluded */
void ov_label(struct ov_pt p, uint32_t n, uint32_t argb);         /* 0..999, up-right of p */
uint32_t ov_hue(uint32_t id);           /* a stable, well-spread argb per object id */

#endif
