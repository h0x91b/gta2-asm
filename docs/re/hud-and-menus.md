# HUD, on-screen text and frontend menus in gta2.exe 11.44

How vanilla GTA2 draws its HUD every frame, how on-screen text gets from a GXT key to the
screen, how the frontend menu works, and where the game reads and writes its settings.
Written for three uses: HUD mods, Seq 18 (our own options screen that replaces gta2manager)
and a Russian translation ([fonts-localization.md](fonts-localization.md)). §9 has the
recipes for mods.

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`). Every name is in the Ghidra
DB (`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and therefore in `re/`.
"verified" (V) = the body was read in the decompiler and checked from a second angle (a caller,
a field use, a string or an enum); "hypothesis" (H) = the name carries `unsure_`. Facts the
Seq 41 lead re-checked itself (bytes or decompile) are marked **(re-checked)**.
Sources: Seq 41 analysis in five slices (HUD frame + HudManager; text, brief and fonts; frontend
engine; registry, video settings and saves; score and popups), plus [gxt.md](gxt.md),
[script-engine.md](script-engine.md) and the names harvested from gta2-seuko-mod
(izawartka, [CREDITS.md](../../CREDITS.md)).

## 0. Coverage

The task brief assumed 0x4B0000-0x4CFFFF is the HUD/menu area. It is only partly: the range
mixes public transport and the traffic spawner (0x4B0-0x4B5), registry wrappers (0x4B5-0x4B6),
MSS audio, PlayerScore/FloatingScore (0x4B7-0x4B9), sprite collision (0x4BA2C0-0x4BE5B0,
owned by Seq 37), car attachments and the `.sty` loader (0x4BE-0x4C0), GXT (0x4C2), texture
cache, traffic lights, emergency vehicles (0x4C3-0x4C5), **the HUD (0x4C5E00-0x4CAD30)**,
renderer/video settings and text drawing (0x4CAD-0x4CC8) and weapons (0x4CC8+, owned by Seq 27).
**The frontend menu engine is not there at all: it is 0x452000-0x45A000**, plus the `Menu_*`
getters at 0x45E390-0x45EEC0 and the gta2manager launcher at 0x4D0820.

| Range | unnamed `FUN_` before | after | what is left |
|---|---|---|---|
| 0x4B0000-0x4CFFFF | **470** | **60** | 4 Fix16 helpers (0x4B9C20, 0x4B9C70, 0x4B9E10, 0x4B9E60, Seq 42) and 56 in the sprite-collision block 0x4BA2C0-0x4BE5B0 (Seq 37 keeps them) |
| 0x452000-0x45A000 (frontend) | 76 | 0 | |
| `Menu_*` block 0x45E390-0x45EEC0 | 38 | 0 | |

Named functions exported in 0x4B0000-0x4CFFFF: 304 → 714. The weapon functions in
0x4CC880-0x4CFEC0 were named before the scope change reached the slice; they are handed to Seq 27,
who keeps or renames them.

## 1. Frame structure: logic tick and render

Two clocks drive the HUD (V, disassembly + decompile):

- **Logic tick**, about 30 Hz: `drawAndLimitFrames` 0x462A30 → `Game_RunLogicStep` →
  `Game_StepByStatus` 0x45C3B0. Running: `GameTick` 0x45C1F0. Paused: `FUN_0045A690` only
  (cameras + `Hud_PauseOverlay_Tick` 0x4C6D90). So **`DrawGUI` (the HUD tick) does not run while
  paused**: timers, briefs, stars and arrows freeze, but they are still drawn.
  `GameTick` → … `MissionScript_ExecuteScriptThreads` … → **`DrawGUI` 0x4CAB50** → FrameCounter,
  FloatingScore update.
- **Render**, variable rate: `drawAndLimitFrames` → `draw` 0x461960 → **`eachFrame` 0x45A5A0** →
  `Vid_FlipBuffers`.

```
eachFrame 0x45A5A0
  g_ViewCamera(0x5E3CC4) = &Game.localPlayer->viewCamera        // a Camera*, UI scale at +0xA8
  map/sprite/draw-queue resets
  call [0x595314]  gbh_BeginScene                                 @0x45A5F4
  MapRenderer_DrawFrame 0x472110                                  @0x45A600
  if !g_cheatCocktart: FloatingScoreManager_Draw 0x4B98B0         @0x45A614
  MOV ECX,[0x672F40]  (g_HudManager)                              @0x45A619
  CALL DrawUI 0x4CA440                                            @0x45A61F   <-- the HUD (re-checked)
  if g_doMike: do_mike 0x474530                                   @0x45A633
  call [0x595318]  gbh_EndScene                                   @0x45A638
  JMP EndFrame2D 0x4CAF50
```

### 1.1 `DrawUI` 0x4CA440 (`__fastcall`, ECX = HudManager*): draw order

The whole body is skipped when `g_skipUser` (0x5EAD64) is set. In order (V, disassembly):

| # | Call | Element |
|---|---|---|
| 1 | `Hud_SetFullAmbientAtNight` 0x4C6DA0 | `gbh_SetAmbient(1.0)` at night so the HUD is not darkened |
| 2 | `Hud_DrawPlayerPanel` 0x4C9C20 | money (sprite 158, right-aligned at x 0x27F, y 4), lives + multiplier (SP), frags / tag time (MP); `Hud_Weapon_Draw` 0x4C9A40 (icon USER 0x55+weapon, ammo text, "K.F." when the ammo byte is 0xFF, H), `Hud_PowerupIcon_Draw` 0x4C9B40 per powerup (icon USER 0x8D+type; armour = ARMOR icon + number, no bar) |
| 3 | `Hud_PlayerMarker_Draw` 0x4C74A0 | USER sprite 0 at the player when a block column is above the ped (H: "player under a roof" marker) |
| 4 | `Hud_DrawPlayerNames` 0x4C78A0 | MP only, `g_showPlayerNames`; names over remote players' peds |
| 5 | `Hud_WantedStars_Draw` 0x4C7A30 | 0..6 stars, USER 0x0E (+lit) |
| 6 | `Hud_GangRespectBars_Draw` 0x4C74F0 | gang respect meters, icon USER 0x3F + gang arrowColour |
| 7 | `Hud_Health_Draw` 0x4C7B70 | hearts USER 0x71/0x72, "%d%%" with `show_instruments` |
| 8 | `Hud_ZoneName_Draw` 0x4C9890 | zone banner, top centre |
| 9 | `Hud_CarName_Draw` 0x4C94F0 | car name banner, bottom |
| 10 | `Hud_Pickup_Draw` 0x4C9690 | pickup message, y 32 |
| 11 | `Hud_Brief_Draw` 0x4C9430 | mission brief with speaker icon, bottom left |
| 12 | `Hud_Pager_C_Array_Draw` 0x4C92A0 | script timers / on-screen counters (also kill-frenzy timer and counter) |
| 13 | `Hud_DebugLabelPool_Draw` 0x4C8C80 | debug / instrument labels |
| 14 | `Hud_ArrowPool_Draw` 0x4C84C0 | mission and gang arrows |
| 15 | `Hud_KillFeed_Draw` 0x4C96F0 | MP kill line, y 16 |
| 16 | `Hud_BigLabel_Draw` 0x4C8A40 | big centred label ("WASTED", bonus names, DISPLAY_MESSAGE) |
| 17 | `Hud_PauseOverlay_Draw` 0x4C9FA0 | only while paused and no quit confirm; rotating pages `pscore`, `pgmiss`, `pmiss`, `psec`, `pbon` |
| 18 | `Hud_DrawChatInput` 0x4C8910 | MP chat line |
| 19 | quit-confirm block 0x4C8710 (tail of DrawUI) | `quit1/2/3` lines; Enter quits, Esc cancels (`Player_HandleQuitConfirmKey` 0x4C8690) |

**There is no radar** (V: no such call in DrawUI, no "radar" string in the exe).

### 1.2 `DrawGUI` 0x4CAB50: the HUD tick

ECX-relative to HudManager: `Hud_TickAnimatedValues` (money/lives/multiplier/frags rolling digits),
`Hud_PlayerMarker_Update` (+0x2844), `Hud_DebugPedInfo_Update` (+0x27B5, only if on),
`Hud_WantedStars_Update` (+0x2760), `Hud_CarName_Tick` (+0), `Hud_Pickup_Tick` (+0x27B8),
`Hud_ZoneName_Update` (+0x4C), `Hud_Brief_Tick` (+0xE4), `Hud_Pager_C_Array_TickTimers` (+0x7E8),
`Hud_DebugLabel_ExpireFinished` (+0x818), `Hud_ArrowPool_Tick` (+0x1F18), `Hud_BigLabel_Tick`
(+0x2854), then the kill-feed byte timer at +0x2A20 counts down.

## 2. HudManager (0x2AF8 bytes, global `g_HudManager` 0x672F40)

Built by `HudManager_Ctor` 0x4CAC60 in this order; every offset below is now typed in the DB
(re-checked with `get_struct_layout`), except `carName` (see §10).

| Off | Size | Type | Ctor | Draw / tick |
|---|---|---|---|---|
| 0x000 | 0x4C | `HudCarNameLabel` (not placed yet) | `Hud_CarName_Ctor` | 0x4C94F0 / `Hud_CarName_Tick` |
| 0x04C | 0x98 | `HudZoneNameLabel zoneName` | `Hud_ZoneName_Ctor` | 0x4C9890 / `Hud_ZoneName_Update` |
| 0x0E4 | 0x704 | `HudBriefQueue briefQueue` | `Hud_Brief_Ctor` | 0x4C9430 / `Hud_Brief_Tick` |
| 0x7E8 | 0x30 | `HudPagerArray pagerArray` (4 × `HudPagerEntry`) | `Hud_Pager_C_Array_Ctor` 0x4CA660 | 0x4C92A0 / 0x4C62B0 |
| 0x818 | 0x1700 | `HudDebugLabelPool debugLabels` (30 × 0xC4) | `Hud_DebugLabelPool_Init` 0x4C6250 | 0x4C8C80 / 0x4C6170 |
| 0x1F18 | 0x848 | `HudArrowPool arrowPool` (17 × `HudArrow`) | `Hud_ArrowPool_Ctor` 0x4C7080 | 0x4C84C0 / 0x4CA890 |
| 0x2760 | 0x54 | `HudWantedStars wantedStars` | `Hud_WantedStars_Init` 0x4C6EE0 | 0x4C7A30 / 0x4C79D0 |
| 0x27B5 | 1 | `displayDebugPedInfo` | 0x4C6E70 | – / 0x4CA680 |
| 0x27B8 | 0x88 | `HudPickupLabel pickupLabel` | `Hud_Pickup_Ctor` | 0x4C9690 / `Hud_Pickup_Tick` |
| 0x2844 | 0x10 | `HudPlayerMarker playerMarker` (H) | `Hud_PlayerMarker_Init` 0x4C6E50 | 0x4C74A0 / 0x4C73A0 |
| 0x2854 | 0x1C8 | `HudBigLabel bigLabel` | `Hud_BigLabel_Ctor` | 0x4C8A40 / `Hud_BigLabel_Tick` |
| 0x2A1C | 4 | `HudPausePage pausePage` (page byte, countdown byte) | `Hud_PauseOverlay_Init` 0x4C71A0 | 0x4C9FA0 / 0x4C6D00 |
| 0x2A20 | 0xD0 | `HudKillFeedLine killFeedLine` | `Hud_KillFeed_Ctor` | 0x4C96F0 / byte timer in DrawGUI |
| 0x2AF4 | 4 | `int text_speed` | ctor 0, `get_text_speed` 0x4C6DC0 | |

Earlier docs say the debug-label pool is "29 × 82 wchar". It is actually 30 nodes of 0xC4 bytes:
0x818 + 0x1700 = 0x1F18, which is where the arrow pool starts.

### 2.1 Element structs

- `HudArrowTarget` (0x24): +0 ped, +4 car, +8 object, +0xC player, +0x10 mode (0 none, 2 ped,
  3 car, 4 object, 5 gang location, 6 player; 1 static coords, H), +0x14/18/1C pos (Fix16),
  +0x20 onScreen.
- `HudArrow` (0x7C): +0/+4 screenX/Y, +8 angle (Ang16), +0xC orbitRadiusBase, +0x10 radius,
  +0x14 radiusSpeed, +0x20 colour (1 yellow, 2 red, 3 green, 4 hidden, 5 flashing), +0x24
  spriteId, +0x26 retarget cooldown, +0x28 gang (`GangRespect*`), +0x2C minRespect, +0x2D
  visible, +0x2E inUse, +0x30 target0, +0x54 target1, +0x78 current. Bytes 0x18..0x1F unknown.
- `HudArrowPool` (0x848): arrows[17], +0x83C enabled, +0x840 onScreenGangArrow, +0x844
  needsOrphanPrune.
- `HudWantedStar` (0xC) {lit, blinkCounter, blinkPeriod, bounceOffset, bounceDelta};
  `HudWantedStars` (0x54) {stars[6], count @0x48, spriteW, spriteH}.
- `HudPagerEntry` (0xC) {timerTicks (×30 per second, −1 free), counterPtr (int* to a script
  variable), sound}.
- `HudDebugLabel` (0xC4) {text wchar[82], timer (−3 sticky), x, y (0xFFFF = centre), fontId,
  paletteBase, remap, invisibility, alpha, next @0xC0}; `HudDebugLabelPool` {nodes[30], count
  @0x16F4, activeHead @0x16F8, freeHead @0x16FC}.
- `HudPickupLabel` (0x88) {timer, text wchar[65], textWidth}; `HudKillFeedLine` (0xD0) {timer,
  text wchar[101], textWidth}; `HudCarNameLabel` (0x4C) {timer, text wchar[33], textWidth,
  slideY}; `HudZoneNameLabel` (0x98) {timer, text wchar[65], textWidth, zoneType1 @0x88,
  zoneTypeF @0x8C, fadeBlend, fadeAlpha}.
- `HudBriefQueue` (0x704): 20-node pool, three lists `head` (active, by priority), `freeList`,
  `history` (finished briefs; was misnamed `pending`), `iconFrame` (was `field_50c`).
- `HudBigLabel` (0x1C8): srcText (99 wchar), wrappedText (121 wchar), x, y, timer, priority @0x1C4.

## 3. Text pipeline

```
GXT key ─ Gxt_FindTextW_thunk 0x4C23A0(g_LocaleSettings, "key") ─► wchar_t*   (miss → L" ")
   │   callers copy it, swprintf into wcharBuf 0x5E9F08 for %d/%s keys
   ▼
 LocaleSettings_ToUpperString 0x4C2250   car name, zone name, big label, labels in fonts G0/G5
 Text_WordWrap 0x4C2450(dest, src, maxWidthPx, fontId)   brief 576, big label 580, debug label 640
     widths: Font_GetGlyphWidth 0x4539D0 → StyleData_GetFontGlyphWidth 0x4BF570;
     space = width of 'n'; '\n' resets; overlong word gets a hard '\n' INSERTED; no bounds checks
   ▼
 GetGTATextWidth 0x4CB0C0(text, font)   widest line, raw px
 Text_GetMultilineHeight 0x4CC0C0(text) lines × line height (height of 'A')
   ▼
 Hud_DrawScaledText 0x4C7280      stdcall, 8 args, ret 0x20: 640×480 virtual units × uiScale
 Hud_DrawScaledTextPlain 0x4BA2C0 same with palette SPRITE, remap 0
 Frontend_DrawText 0x4539F0       frontend, unscaled
   ▼
 DrawGTAText 0x4CC100(str, x, y, fontId, scale, PALETTE_BASE* pal, remap, invisibility, alpha)  stdcall, ret 0x24
     per u16: '\n' new line, ' ' advance, '#' toggles (pal, remap) ↔ (8, 0);
     else sprite = StyleData_GetFontGlyphSpriteId(font, code − 0x21) → GetSpriteIndex(FONT)
          → GetSpriteEntry → TextureCache_GetSpriteTexture(g_TextureCache, …) → gbh_DrawQuad
     Kanji fonts take a separate path: KanjiFont_UploadGlyphSmall/Large per code
```

Argument notes (V): x, y are Fix16 (`n << 14`). `Hud_DrawScaledText` multiplies them by the UI
scale at `*(0x5E3CC4) + 0xA8` (Fix16; `g_ViewCamera`, formerly `ptrToGameStats`, = `&localPlayer->viewCamera`).
**`pal` is a pointer to a `PALETTE_BASE` value**, not the value: 2 = sprite palette for normal
text, 8 = FONT_REMAP when `remap` picks a colour (pickup and kill feed use 8/5). `invisibility`
0 = opaque, 1/2 = blended with a 5-bit `alpha`.

HUD font roles (`Font_AssignRolesByLocale` 0x4CA520; Japanese switches to kanji fonts):

| Global | Normal locale | Used by |
|---|---|---|
| 0x672F3C, 0x672F24 `DefaultFontId`, 0x672F18, 0x672F14 | G1 | brief text, kill feed + chat + pause texts, instruments, (0x672F14 H) |
| 0x672F20 | G6 | pause title |
| 0x672F28 | G2 | car name |
| 0x672F2C | G0 | big label |
| 0x672F30 | G5 | zone name |
| 0x672F34 | G1 | pickup text, debug labels |

### 3.1 Brief queue (the "pager" with the speaker icon)

- `Hud_Brief_Enqueue(priority, key, arg)` 0x4C6690 (stdcall, ECX = queue). It takes a free node.
  If none is free, it steals the oldest node of `history`, then the active tail (the lowest,
  oldest brief is dropped silently). The key is at most 7 chars. A higher priority, or priority 3,
  pre-empts the head; a started head goes to history, not back into the queue. Otherwise the node
  is inserted after the last node with priority ≥ its own (FIFO among equals).
- `Hud_Brief_StartHead` 0x4C6640: text from GXT (+ `swprintf` when arg ≠ −1). The first unit picks
  the speaker icon (`Hud_Brief_SpeakerIconFromChar`). Wrap at 576 px. `timer = text_speed × length`.
- `Hud_Brief_Tick` 0x4C6770: `timer--`. Every 3 ticks the icon frame follows the next text
  character (lip-sync, H on the intent, V on the arithmetic). At 0 the head moves to history.
  Edge case (V by arithmetic): if `text_speed × length` is 0, the timer passes 0 to −1 first, so
  the brief stays up for 65 536 ticks.
- `Hud_Brief_RecallPending` 0x4C6830 (player key 0x41) cycles through `history`.
- `text_speed` comes from registry `Option\text_speed` (default 3, `get_text_speed` 0x4C6DC0),
  i.e. 3 ticks ≈ 0.1 s per character. Nothing in the game writes it; gta2manager does.

### 3.2 Big label and text lines

- `ShowBigOnScreenLabel(text, priority, ?, HudBigLabel*)` 0x4C6060: replaces the label when
  `timer == 0` or `priority >= stored`. Upper-case, `timer = 90`, layout by `Hud_BigLabel_Layout`
  (wrap 580 px, x = (640−w)/2, y = (480−h)/4). Priority 1 = score bonuses, 3 = mission/status
  (`g_over`, `mfail`, DISPLAY_MESSAGE).
- Car name: `Hud_CarName_Show` from `Car_OnDriverEnter`, key `car%d`, 120 ticks, slides in and out.
- Zone name: `Hud_ZoneName_Update` every tick when the player's zone (type 1 or 0xF) changes,
  key = the zone's 3-char name, 90 ticks with a fade.
- Pickup: `Hud_Pickup_Show(id)` from `Ped_PickUp`, key `c%02d`, 90 ticks, y 32.
- Kill feed: MP only, `Hud_KillFeed_ShowMpKill` 0x4C9750, `mpkill1..5`, 120 ticks, y 16.
- All of them `wcscpy` without bounds; capacities 32 / 64 / 64 / 100 chars.

## 4. Arrows, wanted stars, timers, player panel

- **Arrows** (V): 17 `HudArrow`s; a script arrow handle is the pool index. Created by script
  POINT_ARROW_AT / SET_ARROW_COLOUR / REMOVE_ARROW, by SET_GANG_INFO (mode 5 = gang location from
  `GangRespect.arrowTargetX/Y/Z`), by gang phones (`Hud_ArrowPool_RegisterGangPhoneArrow`
  0x4CA910: object types RED/YELLOW/GREEN_PHONE 0xB0..0xB5 → colour, re-checked against the
  `OBJECT_TYPE` enum), and in MP one arrow per remote player. The arrow is a world-space sprite
  orbiting the player toward the target, projected with `Camera_WorldToScreen` 0x4B90E0.
  `Hud_Arrow_ShouldShow` 0x4CA770 hides gang arrows unless the player is in that gang's zone
  and respect ≥ minRespect (yellow 40, red 80, green −19: H on the meaning); `show_all_arrows`
  shows everything.
- **Wanted stars**: count = `Ped_GetCopStars` (0..6); blink every 2 ticks; bounce ±4 px while
  pursued.
- **Timers and counters** (`HudPagerArray`, 4 slots): DISPLAY_TIMER →
  `Hud_Pager_C_Array_CreateTimer` 0x4C9310 (seconds × 30); ADD_ONSCREEN_COUNTER →
  `Hud_Pager_C_Array_AddOnScreenCounter` 0x4C9360 (pointer to the script variable, shown live);
  CLEAR_TIMER → `…ClearSlot`; the MP time limit reuses them. Timer draw: MM:SS, flashes under 300
  ticks. Kill frenzies use the same timer + counter (`Script_Op_DO_BASIC_KF_TEMPLATE`).
- **Player panel**: money, lives and multiplier are `AnimatedValue`s ticked by
  `Hud_TickAnimatedValues` (rolling digits from a USER sprite strip, see §5).
- **Chat** (MP): `Player.chat` at Player+0x794, opened by `ChatInput_Open`, keys in
  `ChatInput_HandleKey`; `Hud_ChatInput_ConsumesKey` 0x4C5F70 and `Hud_QuitConfirm_ConsumesKey`
  0x4C5F30 stop those keys reaching the game (`Hud_IsKeyConsumedByOverlay` 0x4C6DE0).
- **Debug labels**: `Hud_DebugLabel_Show` 0x4C8C20 (text, x, y, font, ticks; x/y 0xFFFF = centre,
  ticks −2 = text_speed × length, −3 = forever); 14 callers (show_instruments, show_physics,
  counters, timing, debug ped info). An older label with the same text is expired.

## 5. Score and floating score popups

- Money: everything is paid through `GiveMoney(player, n)` =
  `PlayerScore_AddMoney(score, n × moneyMultiplier)`; spending uses `ChangeMoney`, which skips
  the multiplier. Storage: `Player.score` (PlayerScore at Player+0x2D4), `Player.lives`
  +0x684, `Player.moneyMultiplier` +0x6BC, all `AnimatedValue`s.
- The multiplier is halved (minimum 1) by `Player_OnBusted` when the player respawns without a
  get-out-of-jail card. Lives: +5 at level start (+1 in MP); game over at ≤ 0.
- Per-event payouts (`PlayerScore_OnPedKilled`, `_OnCarDestroyed`, `_OnCarjack`,
  `unsure_PlayerScore_OnCarWrecked`, `unsure_PlayerScore_OnCarStolen`,
  `unsure_PlayerScore_OnCrimeKind4`) use tables by weapon and victim class. Kill and car combos
  (×1..5 within 16 frames) apply.
- Bonuses in `PlayerScore_Update` (each pays and shows a big label): EXPEDITIOUS EXECUTION
  (`excutin`, 20-kill streak, 100 000), Elvis (`elvis_d`), MEDICAL EMERGENCY (`em_dest`), GENOCIDE
  (`gencide`, 1000 kills), COP KILLA (`copkill`), CAR JACKA (`carjaka`), accuracy (`accurcy`),
  BACK-TO-FRONT (`wrngway`), INSANE STUNT (`fly_car`), GRAND THEFT AUTO (`stl_all`), WIPEOUT.
- Kill frenzy payout is script-driven (`DO_BASIC_KF_TEMPLATE`), not in PlayerScore (H: that
  opcode's body was not read).
- **FloatingScore**: `FloatingScoreManager` (0x100) with a pool of 3 popups; spawned only for the
  local player and only when `g_cheatCocktart` is off. When the pool is full, a new popup replaces
  an active one with a smaller amount; otherwise the new popup is dropped. It stays still for 2
  ticks, then grows and rises for about 11 ticks. Each digit is a USER sprite **163 + digit**
  (re-checked: `DrawSprite2D(6, digit + 0xA3)` in `FloatingScore_DrawDigit` 0x4B92B0), recoloured by
  remap 9..13 (`FloatingScoreManager_NextColor`, re-checked). The world position is clamped so the
  popup never leaves the screen.
- `FloatingScore` fields added: `delayTicks` @0x38, `growX` @0x3C, `growY` @0x40.
- 0x4B9D50-0x4BA2C0 is not HUD: sprite bounds/position helpers and
  `Sprite_AttachChildToParent` 0x4B9D50 (re-checked: attaches roof guns, antennas, flames
  to a car/ped/object; 17 callers).

### 5.1 How a HUD sprite gets drawn

`GetSpriteIndex(style, type, id)` = `spriteBases[type] + id` (type 6 = USER, 7 = FONT) →
`GetSpriteEntry` (8-byte {ptr, w, h}) → `TextureCache_GetSpriteTexture(g_TextureCache, type, id, pal, remap)`
→ `gbh_DrawQuad`. `DrawSprite2D` 0x4CBA50 builds the rotated quad. HUD digits, weapon icons, stars,
hearts and popup digits are all USER sprites of the style file, so replacing a HUD image means
patching USER sprite data or overriding `TextureCache_GetSpriteTexture` for type 6.

## 6. Frontend menu engine (0x452000-0x45A000)

The frontend is a data-driven page engine (V). `InitFrontend` 0x456A60 calls
`FrontEnd_InitPages` 0x453E20 (was `MainMenu`), which builds **17 `FrontendPage`s at
`FrontEnd + 0x122 + k × 0xBCA`** at run time from GXT keys. There are no static page tables in
`.data`. `FrontEnd.pageId` (+0x11E, was misnamed `doPlayMovies`) is the current page.
**`FrontEnd_GotoPage` 0x4587B0 (was `?Intro`) is the only page switch**: per-page set-up, then
`selected = defaultSelected`, and `DisplayError(0xA5)` if nothing on the page is selectable.

Per-iteration driver, called by `WinMain2` 0x4D11B8 while in the frontend:
`FrontEnd_Tick` 0x45A320 (movie pages, a 60 s idle timeout → attract demo, logic every 33 ms,
otherwise `DrawFrontendFrame`) → `FrontEnd_UpdateMode` 0x45A250 → a switch on `FrontEnd.mode`.

| `FrontEnd.mode` (+0x110) | Meaning | Handler |
|---|---|---|
| 1 | menu (credits scroll on page 9) | `FrontEnd_UpdateMenuMode` 0x4597C0 / `FrontEnd_UpdateCreditsScroll` |
| 2 | starting a level → `resultCode = 3` | `FrontEnd_RequestGameStart` 0x451F60 |
| 3 | profile name entry | `FrontEnd_UpdateNameEntryMode` |
| 4 | delete-profile confirm | `FrontEnd_UpdateDeleteProfileConfirm` |
| 5 | parental code entry (page 0xE) | `FrontEnd_UpdateCodeEntryMode` 0x45A010 |

`FrontEnd.resultCode` (+0x108), returned by `FrontEnd_Tick`: 2 running, 1 quit the application,
3 start the game (`WinMain2` → `InitGame` 0x461DE0), 4 attract replay.

Item dispatch (`FrontEnd_UpdateMenuMode`): an item `action` (+0x80) below 0x100 is a page id
(→ `FrontEnd_GotoPage`); 0x101..0x10C go through the **jump table at 0x459DE0**. ESC uses the
jump table 0x459E10 with a per-page index byte table at **0x459E20**.

### 6.1 Structs

- `FrontendPageItem` (0x82): kind @0 (1 button, 2 selector), enabled @1, x @2, y @4,
  label wchar[50] @6, fontId @0x6A (0xFFFF = default), remap @0x6C, choice @0x6E, choice2 @0x70,
  choiceEnabled[12] @0x72, choiceMax @0x7E, **action @0x80**.
- `FrontendPageDecor` (0x6E): kind (1 text, 3 sprite), enabled, x, y, text[50], fontId, remap.
- `FrontendPageCursor` (6): x, y, enabled (UP/DOWN only stop on enabled cursors).
- `FrontendPage` (0xBCA): itemCount @0, decorCount @2, items[10] @4, decor[15] @0x518,
  cursors[10] @0xB8A, selected @0xBC6, defaultSelected @0xBC8. The old gzf `FrontendS1*` structs (wrong
  cursor stride 5) were merged into these types.
- `FrontendLevelPaths` (0x300: gmp, sty, scr paths) × 12 at FrontEnd+0xC9D4 (index = stage +
  area × 4), filled by `FrontEnd_LoadSeq` from `data\*.seq`; `FrontendSaveSlotInfo` (4) × 8 at
  +0xEDD4.
- `FrontEnd` (0x1EB40): about 40 fields named (mode, resultCode, pageId, key edge/prev bytes,
  code entry, credits, per-profile area/bonus selection, arrows, areaCount, levelCountPerArea …).
  The page array and level paths are not typed in yet (§10).
- `Menu` (0x578, global `ptrToMenu` 0x5EC070), now fully laid out: gmpFile/styFile/scrFile/savePath
  (4 × char[256]), startArea @0x400, bonusLevelId @0x401 (`area<<4 | stage`), isBonusLevel @0x402,
  profileSlot @0x403, levelEndReason @0x404 (H), crimeStats[10] @0x408, totalEarned @0x430,
  wantedStarSeconds @0x434, mpGameType @0x43B (1 frags, 2 points, 3 tag), fragLimit @0x43C, MP
  player count/index/winner, mpTimeLimitMinutes @0x444, kill matrix, frags, points, player names
  (6 × 16 wchar) @0x4B4, `bonusTokenCount` @0x574 (bonus tokens collected: Menu_Inc/Get/SetBonusTokenCount; FrontEnd_GotoPage compares with 50; saved in the savegame).

### 6.2 Pages

| Id | Screen | Items (GXT key → English text) → action | Notes |
|---|---|---|---|
| 0 | Main menu (version "GTA2 V%d.%d" drawn at page 0) | `play` PLAY → page 1; `options` OPTIONS → 0x101 (launch gta2manager); `quit` QUIT → 9 | No CD (`FrontEnd_IsGameCdPresent`==0): texts become `no_cd1/2/3`, all actions 9. ESC → 9. |
| 1 | Player / level select | 0 `charctr` PLAYER, selector kind 2, choice 0..7 = profile slot; 1 `savepos` RESUME SAVED STATUS → 0x104; 2 `hi_scre` VIEW HIGH SCORES → 5; 3 `strtlev` START PLAY IN AREA → 0x108, LEFT/RIGHT = area (`FrontEnd_AreaSelectorLeft/Right`); 4 `bonslev` BONUS STAGE → 0x109, LEFT/RIGHT = bonus level | Default selected = 3. Entry: reads registry `plyrslot`. ENTER on item 0 → mode 3 (name). DEL on item 0 → mode 4. LEFT/RIGHT on item 0 → `Reg_Player_SetDword(plyrslot)`. 10 decor (sprites: arrows; texts: area number, bonus letter). Items 1/3/4 are greyed when locked/absent (`enabled`). |
| 2 | Player dead ("plr_ded" YOU ARE DEAD!) | `savepos` → 0x104; `replay` REPLAY PREVIOUS AREA → 0x103; `mainmen` BACK TO MAIN MENU → 0 | Shown after `relToQuitGame` code 3 (non-bonus). |
| 3 | Area complete ("cmpltd" AREA COMPLETE!) | `nxt_lvl` PLAY NEXT AREA → 0x105; `savepos` → 0x104; `replay` → 0x103; `contnue` CONTINUE → 0x10a; `mainmen` → 0 | `relToQuitGame` code 4 (non-bonus). Stats panel. |
| 4 | Game complete ("gam_cmp" GAME COMPLETE!) | `mainmen` → 0 | From `OnContinueAction` when all levels unlocked. |
| 5 | High scores | one selector (kind 2, 12 choices = 3 areas × (1 main + 3 bonus)) → `hiScoreTableIndex` | `hi_for` HIGH SCORES FOR AREA. ESC → 1. |
| 6 | Bonus stage complete (title `bonslev`, `score`) | `repbons` REPLAY BONUS STAGE → 0x103; `nxt_lvl` → 0x105; `mainmen` → 0 | Bonus variants of codes 2/3/4 land here. |
| 7 | Multiplayer results (`mult_w`/`mult_l`/`mult_d`/`mult_q`, rows per player, frags/points/times) | `quit` QUIT → 0x102 | `relToQuitGame` code 5; ESC → quit. |
| 8 | Intro movie page (plays `IntroMovieBik()`) | `mainmen` (unused) | Tick: movie done or any key → page 0. |
| 9 | Credits | none | Any key → quit (resultCode 1). Reached by QUIT and ESC from pages 0/0xe. |
| 10 | "Nice try" (`nicetry` NICE TRY!) | `mainmen` → 0 | `OnContinueAction` on the last area when not all levels done. |
| 11 (0xb) | Player quit ("plr_qut" PLAYER QUIT!) | `savepos` → 0x104; `replay` → 0x103; `mainmen` → 0 | `relToQuitGame` code 2 (non-bonus). |
| 12, 13, 16 | unused (empty pages) | | ESC → quit (jump-table default). |
| 14 (0xe) | Parental lock code (`fr_ent1`/`fr_ent2`/`fr_pmpt`; error `fr_rnt1..3`) | `item 0` → 0x10c (nop) | Mode 5. Correct code is `L"WFUSDFCF"`. |
| 15 (0xf) | Pre-intro movie (`data\movie\preintro.bik`) | `mainmen` | Then page 8. |


### 6.3 Action codes and keys

| Code | Address | Effect |
|---|---|---|
| 0x101 | 0x4599A1 | `CALL 0x4D0820` OPTIONS (`FrontEnd_LaunchGta2Manager`) |
| 0x102 | 0x4599AB | `resultCode=1` (quit) |
| 0x103 | 0x459966 | `Menu_SetSavePath(default)`, start with the current paths (replay) |
| 0x104 | 0x45997A | if the slot file exists: `FrontEnd_LoadSavedGameSlot`, else same as 0x103 |
| 0x105 | 0x4598CA | next area: current + 1, `FrontEnd_SelectLevel` |
| 0x106, 0x10b | → default | `FrontEnd_GotoPage(action)`, invalid, not used by any item |
| 0x107 | 0x45984E | highest unlocked level of the area, `SetBonusLevelSelected(0)`, mode 2 |
| 0x108 | 0x4599B7 | `FrontEnd_SelectLevel(Menu area, 0)` |
| 0x109 | 0x4599D5 | unpack `bonusLevelId`, `FrontEnd_SelectLevel(area, stage)`, `SetBonusLevelSelected(1)` |
| 0x10a | 0x459A24 | `FrontEnd_OnContinueAction` |
| 0x10c | 0x459A35 | nothing |

Every start path ends with `FE.backgroundId=0x10`, `FE.mode=2`.

ESC (table 0x459E20, **V**): page 0, 14 → page 9; 1, 2, 3, 4, 6, 10, 11 → page 0; 5 → page 1; others → `resultCode=1`.

Key handling, all **V**: arrows UP/DOWN skip items whose cursor slot `enabled`==0, and play `MainMenuSoundPlay` 1 / 2. The sound ids are MAIN_MENU_SOUND values (ENTER_SOUND, BACK_SOUND, LEFT_RIGHT_SOUND=4, 7 = typed char, 8 = delete char, `CHEAT_SOUND`).

Background images (`g_FrontendImages` @ 0x591F68, 25 × 0x88, all `data\frontend\*.tga`, **V**): 0 `1`, 1 `1_Options`, 2 `1_Play`, 3 `1_Quit`, 4 `2`, 5-7 `2_Bonus1..3`, 8 `2_League`, 9-11 `2_Level1..3`, 12 `2_Name`, 13 `2_Restart`, 14 `3`, 15 `3_Tables`, 16 `GameComplete`, 17 `LevelComplete`, 18 `MPLose`, 19 `PlayerDead`, 20 `Mask`, 21 `Mask2`, 22 `Credits`, 23 `Mask3`, 24 `DemoInfo`. `backgroundId` → images: see the plate on `FrontEnd_GetBackgroundImageIds`.

### 6.4 Game-start path (frontend → InitGame), V


1. ENTER on a button → `FrontEnd_UpdateMenuMode` → action 0x103..0x109 / 0x10a.
2. `FrontEnd_SelectLevel(area, stage)` (or `FrontEnd_LoadSavedGameSlot` / `Menu_SetSavePath`) sets:
   - `Menu.gmpFile/styFile/scrFile` = `"data\"` + names from `FE.levelPaths[stage + area*4]`;
   - `Menu.savePath` = default (0x56E5B4);
   - `Menu.startArea`, or `bonusLevelId` + `isBonusLevel`;
   - `Menu.profileSlot`, set earlier by the profile selector.
   `FrontEnd_LoadSeq` fills that table from `data\*.seq` ("MAIN"/"BONUS" blocks, 3 file names each; max 3 areas × 4 levels).
3. `FE.backgroundId=0x10`, `FE.mode=2` → the next tick `FrontEnd_RequestGameStart` (0x451F60) sets `resultCode=3`.
4. `WinMain2` (0x4D11B8) gets 3 from `FUN_0045A320` → `isExit=0` → `InitGame` (0x461DE0) → `LoadGMP_and_STY_Files` (reads `Menu_GetGmpPath/StyPath/ScrPath/SavePath`) → `startGame`.
5. `InitGame` also reads `Menu_GetGameTimeLimit` and `Menu_SetPlayerName` (MP).
6. Return to the frontend: `WinMain2` after `relToQuitGame(game)` → `DeinitGame`, `isExit=1`, `doPlayMovies`/page id = 2 (player quit): page 0xb (6 if bonus); 3 (dead): page 2 (6); 4 (level done): page 3 (6); 5: page 7 (MP results); 6: page 0. Then `FrontEnd_GotoPage(page)` after `Init()`. `FUN_0045A480` (called from `Script_Op_FINISH_LEVEL`, `quitGame`) writes `Game.field11_0x28/relatedToQuitGame` and `Menu.levelEndReason`.
7. Between levels `Menu_CopyPlayerCrimeStats` fills `Menu.crimeStats/totalEarned/wantedStarSeconds` for the stats panel.


### 6.5 Settings the frontend itself reads and writes

| Item / event | Wrapper | Key |
|---|---|---|
| Page 1 item 0 LEFT/RIGHT (profile slot) | `Reg_Player_SetDword` 0x4B5D10, `ECX=0x66C6B4`, key at 0x57367C | `"plyrslot"` |
| `FrontEnd_GotoPage(1)` | `Reg_Player_GetDwordOrZero` 0x4B5C60 | `"plyrslot"` |
| `FrontEnd_OnCodeEntered`, `WinMain2` | `Reg_Screen_GetDwordOrInit` 0x4B5660 | `"do_play_movie"` (default 1) |
| `WinMain2` start | `Reg_Sound_HasFlag` 0x4B5000, `Reg_Sound_SetFlag` 0x4B5180 | `"do_3d_sound"` |
| `Menu_LoadDebugLevelFromRegistry` 0x45E8D0 | `Reg_Debug_GetString` 0x4B5420 | `"mapname"`, `"stylename"`, `"scriptname"`, `"savename"` (only the debug-skip-frontend path) |

  The frontend does not read the sound/video/key options itself; those live in gta2manager.
- Everything else the frontend persists is in the save files (`player\plyslotN.sgv`, via `FUN_004a89e0` / `FUN_004a8700` from `FrontEnd_CommitProfileName` / `FrontEnd_DeleteCurrentProfile`); format in §8.

The frontend does not read the sound, video or key options itself: gta2manager edits those in the registry, and the game reads them at startup (§7). Profile progress and high scores live in files (§8).

## 7. Settings: registry

### 7.1 Keys and values

Root for everything: `HKEY_CURRENT_USER\SOFTWARE\DMA Design Ltd\GTA2\<Key>` (each opener calls `RegOpenKeyExA`, falls back to `RegCreateKeyExA`; key names are case-insensitive, the seed file writes `screen` lowercase, the game opens `Screen`). Value names are case-insensitive in the host (`_strcasecmp` in `reg_val_find`).
The "init" getters (`*_GetDwordOrInit`) **write the default back** when the value is missing, so a missing value is never an error. Exceptions: the Debug flags (`Reg_Debug_HasValue`/`Reg_Sound_HasFlag` only test presence) and `Reg_Player_GetDwordOrZero`.
gta2manager (`gta2manager.ebin`): its strings contain the key paths Debug, Screen, Control, Sound, Option, **Options** (plural, unknown), Network and the value names below marked **GM**. we did not decompile it; "GM writes" means "the name is present in its strings" (hypothesis for who writes it).

**Screen** (opener `Reg_OpenScreenKey` 0x4B5340; getters `Reg_Screen_GetDwordOrInit` 0x4B5660, `Reg_Screen_GetStringOrInit` 0x4B5770; writer `Reg_Screen_SetDword` 0x4B5700 — writes the *current global* value, caller sets the global first)

| value | type | game default | host seed | reader | writer | consumer | meaning |
|---|---|---|---|---|---|---|---|
| renderdevice | DWORD | 1 | 1 | ReadRendererSettings 0x4CB3F0 | GM | `renderdevice` 0x673470 | Vid device index for the renderer DLL |
| videodevice | DWORD | 1 | 1 | ReadRendererSettings | GM | `videodevice` 0x673588 → `Vid_SetDevice`, `Vid_FindDevice` | video device index (adapter) |
| rendername | REG_SZ | "d3ddll.dll" (ptr table 0x595008) | "d3ddll.dll" | ReadRendererSettings via `Reg_Screen_GetStringOrInit` | GM | `rendername[256]` 0x673478 → `LoadRenderDll` (InitRenderer) | renderer plugin; "softdll.dll" → `g_RendererKind`=0, "3dfx.dll" → 2, anything else → 1 |
| videoname | REG_SZ | "dmavideo.dll" (0x59500C) | "dmavideo.dll" | ReadRendererSettings | GM | `dmavideo_dll` → `InitVideoDll` (InitVideo) | video plugin |
| window_width / window_height | DWORD | 640 / 480 | 0x3C0/0x2D0 (960×720); **host overrides in memory to 1280×960 or --window=WxH** (`reg_window_override`) | RenderSettings_LoadWindowMode 0x4CB290 | GM; the game rewrites them to 640×480 if `SetWindowedMode` fails (Video_ReloadSettingsAndRemode) | `window_width` 0x673578, `window_height` 0x6732E8 | client area size when windowed |
| full_width / full_height | DWORD | 640 / 480 | 0x3C0/0x2D0 | RenderSettings_LoadWindowMode | GM; SetFullscreenMode rewrites 640×480 when `Vid_CheckMode` rejects the pair | `full_width` 0x6732E4, `full_height` 0x6732E0 | fullscreen size (16 bpp, `Vid_CheckMode(...,0x10)`) |
| start_mode | DWORD | 1 | 0 | RenderSettings_LoadWindowMode | Screen_SetStartMode 0x4CB4D0, Screen_ToggleStartMode 0x4CB4F0 (WndProc), Video_ReloadSettingsAndRemode (fallback) | `start_mode` 0x595014 | 0 windowed, 1 fullscreen |
| tripple_buffer | DWORD | 0 (forced 1 when `g_RendererKind`==0) | 0 | RenderSettings_LoadWindowMode | GM | `tripple_buffer` 0x67359C → `SVideo.mask1` bit 0x10 | triple buffering |
| max_frame_rate | DWORD | 1 (forced 1 in multiplayer) | 1 | RenderSettings_LoadFrameRateLighting 0x4CB1D0 | GM | `max_frame_rate` 0x595010 (byte) | cap the frame rate |
| min_frame_rate | DWORD | 0 (forced 1 in multiplayer) | 1 | same | GM? (not in GM strings; only max_frame_rate is) | `min_frame_rate` 0x673598 | |
| lighting | DWORD | 1 | 1 | same | GM | `lighting` 0x67358C (=0x8000 if on, else 0); `isNight` 0x595011 | dynamic lighting |
| exploding_on | DWORD | 1 | 0 | same | GM | `g_cheatCocktart` = (value != 1) | name suggests "exploding pedestrians" cheat flag (hypothesis); seed 0 → flag on |
| gamma | DWORD | 10 | 10 (0x0A) | Gamma_ApplyFromRegistry 0x4CB990, Gamma_RetryTick 0x4CB9C0 | GM | `SetGamma` 0x4CB930: value × 0.1f → `Vid_SetGamma(r,g,b)`; `relatedToGamma` 0x673594 | gamma ×10 |
| do_play_movie | DWORD | 1 | 0 | WinMain2 (only if `FrontEnd_IntroMovieExists`), FUN_00459660 | the game's own option writer FUN_00459660 (sets `regSet("do_play_movie",1)`) | selects start page of the frontend | play intro movies |
| curr_dll_id | DWORD | – | 1 | **not read by gta2.exe** (string absent from the exe, checked with strings) | GM | – | legacy renderer index |
| special_recognition | DWORD | – | 1 | **not read by gta2.exe** | GM | – | legacy |

**Control** (opener `Reg_OpenControlKey` 0x4B52D0; getter `Reg_Control_GetKeyBindOrInit` 0x4B55A0; reader loop = function at 0x44BF30, called from `ReturnHandleOfDirectInput` 0x44BF70)
Value *names* are decimal action indexes "0".."11" (12 actions). Value = `scancode | flags<<15`: low byte → `Controls[i]` (0x5E8F5C), `value >> 15` → table 0x5E8F1C. Default table 0x591E9C == the seed: 0=0xC8(↑) 1=0xD0(↓) 2=0xCB(←) 3=0xCD(→) 4=0x1D(LCtrl) 5=0x1C(Enter) 6=0x39(Space) 7=0x2C(Z) 8=0x2D(X) 9=0x0F(Tab) 10=0x38(LAlt) 11=0x36(RShift). The action *meaning* per index is frontend's (not mapped) (hypothesis only here: 0..3 movement, 4 fire, 5 enter/exit, 6 handbrake, 7/8 weapon prev/next, 9 special/horn, 10/11 ?). Writer: GM (CControlCfg), the in-game controls screen.

**Sound** (opener `Reg_OpenSoundKey` 0x4B4F90)

| value | type | default | seed | reader | writer | consumer |
|---|---|---|---|---|---|---|
| CDVol | DWORD | 0x7F | 0x7F | FUN_00461880 (`Reg_Sound_GetDwordOrInit`) | `Reg_Sound_SetDword` 0x4B5110 from Player_OnKeyDown (debug key), GM | `SetCDVolume((byte)v)` |
| SFXVol | DWORD | 0x7F | **0x0B** | FUN_00461880 | GM | `FUN_004105c0((byte)v)` (SFX master volume) |
| do_3d_sound | presence flag (value 0 = on, absent = off) | absent | absent | `Reg_Sound_HasFlag` 0x4B5000 in FUN_00461880, WinMain2, WndProc, InitGame, Debug_LoadFlagsFromRegistry | `Reg_Sound_SetFlag` 0x4B5180 (WinMain2/InitGame/WndProc/FUN_00461880 write back the actually active state) | `Sound_Set3DSoundEnabled(&DAT_005d85a0, v)` |

SFXVol seed 0x0B is much lower than the 0x7F default — probably the installer's own choice; if audio sounds quiet, this is why (hypothesis, not verified in a run).

**Option** (opener `Reg_OpenOptionKey` 0x4B5260): `Language` REG_SZ (seed "e"; read as "language" by `Reg_Option_GetString` in LocaleSettings_Ctor 0x4C2620 → picks the .gxt), `text_speed` DWORD (default 3, seed 3, `get_text_speed` 0x4C6DC0 via `Reg_Option_GetDwordOrInit`). Writers: GM (CLanguageSelect, text speed), and the frontend options screen (none found in the exe).

**Player** (opener `Reg_OpenPlayerKey` 0x4B5BF0): `plyrslot` DWORD = last used profile slot (`Reg_Player_GetDwordOrZero` in FrontEnd_GotoPage; written with `Reg_Player_SetDword` 0x4B5D10 from FrontEnd_UpdateMenuMode 0x4597C0). **Not seeded** by the host: key is created on first open, value reads as 0 → slot 0 (harmless).

**Network** (opener `Reg_OpenNetworkKey` 0x4B58E0, root hive handle in `DAT_00593E6C`, unverified that it is HKCU 0x80000001): `map_index`(0), `game_time_limit`(1), `game_speed`(1), `game_type`(1), `police`(0), `f_limit`(3, only if game_type==1), `s_limit`(10000, otherwise) — all read by FUN_00406470 through `Reg_Network_GetDwordOrInit` 0x4B5AE0, `map_index` written back by FUN_00407605 (`Reg_Network_SetDword` 0x4B5B80); `show_player_names` (default 1, Debug_LoadFlagsFromRegistry, same getter). Blobs `UseProtocol` (16 B GUID) and `UseConnection` via `Reg_GetBlobSize`/`Reg_ReadSizedBlob` ("<name>s" = size, "<name>d" = data) in FUN_004D0ED0 (multiplayer connect). `PlayerName` is read by a *different* code path (the exe contains a second string `Software\DMA Design Ltd\GTA2\Network` at 0x57xxxx near the network code). Seeded: f_limit, game_speed, game_time_limit, game_type, map_index, PlayerName, police, protocol_selected (not read by the exe), show_player_names, TCPIPAddrString(d/s) (not read by the exe), UseConnection(d/s), UseProtocol(d/s).

**Debug** (opener `Reg_OpenDebugKey` 0x4B51F0): ~75 presence flags (`Reg_Debug_HasValue` 0x4B53B0) read once by `Debug_LoadFlagsFromRegistry` 0x451930 (full list: `host/config.asm` `cfg_flags`; the host seeds `do_blood`, `do_debug_keys`, `bob_debug_display`, `do_blood`, `do_debug_keys`, `mapname`, `replaynum`); strings via `Reg_Debug_GetString` 0x4B5420: `carname` (LoadGMP_and_STY_Files; seeded none → game default), `mapname`, `stylename`, `scriptname`, `savename` (Menu_LoadDebugLevelFromRegistry 0x45E8D0). `replaynum` is a DWORD read in Menu_LoadDebugLevelFromRegistry (seed 9); `bob_debug_display` appears in the seed but not in `cfg_flags` and we did not find its reader (hypothesis: read as a flag by Debug_LoadFlagsFromRegistry under another spelling).

**HKCU\Software\Aureal\A3D**: `Mss_A3D_DisableSplash` 0x4B5ED0 (called from MssAudio_Ctor) creates the key and writes `SplashScreen=0`, `SplashAudio=0` (A3D driver splash). The host's `RegCreateKeyExA` creates it in memory — fine.

**Seeded by the host but never read by gta2.exe:** Screen\curr_dll_id, Screen\special_recognition, Network\protocol_selected, Network\TCPIPAddrString/s. **Read by the game but not seeded** (all have defaults, none can fail): Player\plyrslot, Sound\do_3d_sound, Debug\* flags (absence = off), Debug\carname/stylename/scriptname/savename, Control\* (seeded, all 12), `Option\...` ok. So: **no key the game needs is missing from the host seed.**

### 7.2 When settings are read and written

1. **WinMain2 0x4D11B8**: `GetGameVersion` → `Debug_LoadFlagsFromRegistry` (Debug flags, Network `show_player_names`, Sound `do_3d_sound`) → `Menu_LoadDebugLevelFromRegistry` (Debug mapname/stylename/scriptname/savename) → `RegisterClass` → **`ReadRendererSettings`** (Screen: renderdevice, videodevice, rendername, videoname, then LoadFrameRateLighting + LoadWindowMode) → parse args → `FUN_004D0ED0` (multiplayer connect, Network UseProtocol/UseConnection) → create window sized from `window_width/height` → `diutil` (DirectInput; **controls loaded in `ReturnHandleOfDirectInput` → 0x44BF30**) → **`InitVideo`** (`Video_ReloadSettingsAndRemode` re-reads Screen settings and applies mode/gamma; then InitRenderer, `Gamma_ApplyFromRegistry`) → `InitRendererDevice` → **`FUN_00461880`** (keybrd, plydat = profile .dat files, then Sound CDVol/SFXVol/do_3d_sound) → intro-movie check (`do_play_movie`).
2. **Frontend** (isExit): `?Intro`/`FrontEnd_GotoPage` read Player\plyrslot; `LocaleSettings_Ctor` reads Option\language; `get_text_speed` reads Option\text_speed on demand. Options screens write through the same getters/setters (none found in the exe).
3. **InitGame 0x461DE0**: re-checks Sound\do_3d_sound and writes the active state back (`Reg_Sound_SetFlag`).
4. **Per frame**: `Gamma_RetryTick` (GameTick) retries `SetGamma` while `relatedToGamma` counts down from 0x1E; `Video_ReloadSettingsIfChanged` is called after each InitGame/Init (WinMain2) and compares newly read values with the old globals.
5. **WndProc 0x4D0A00**: Alt+Enter style handling → `Screen_ToggleStartMode`/`Screen_SetStartMode` (writes start_mode) then `Video_ReloadSettingsAndRemode`; `Gamma_ApplyFromRegistry`, `MouseExclusive_Acquire`; Sound items via `SetSetting`-style init.
6. **Writes at exit/save**: nothing special; registry writes are immediate (RegSetValueEx). The host keeps them **in memory only** (docs in `w32_advapi32.asm`: "not persisted yet").


### 7.3 Re-applying settings live (for Seq 18)

* **Persistence model today:** the registry is host-side, **in memory per process**, seeded from `gta2_install.reg` (overlay dir wins over the pak) and adjusted by `config.yaml` (debug flags) + the `--window=WxH` override of `screen\window_width/height`. An own options screen must therefore persist by either (a) writing the settings into the overlay `gta2_install.reg` (host re-seeds at every start), or (b) adding a persistence layer in the host (`RegSetValueExA` shim → flush). The game reads registry only through the shims listed above, so seeding is the only thing the game needs.
* **Take effect only after restart / re-init:** `Screen\renderdevice`, `videodevice`, `rendername`, `videoname` (read only by `ReadRendererSettings` before `InitVideo`; DLL load order); Control\*; Option\Language (LocaleSettings_Ctor, locale loaded at level/frontend init); Network\*; Debug\* (flags cached in globals at startup).
* **Live (call to re-apply):** 
  * video mode: write `screen\window_width/height/full_width/full_height/start_mode/tripple_buffer`, then call **`Video_ReloadSettingsAndRemode` 0x4CC5C0** (cdecl, 2 dummy args; re-reads, closes the screen, applies windowed/fullscreen, falls back to 640×480, re-applies gamma) followed by **`Video_ReapplyColourBankAndCameraDims` 0x4CB880** — exactly what `Video_ReloadSettingsIfChanged` 0x4CC6A0 does when `RenderSettings_LoadWindowMode` reports a change. In this port the real mode switch is our `dmavideo.dll` replacement (`Vid_SetMode`), so the host must make `Vid_SetMode/Vid_CheckMode` tolerate the size changes (not checked).
  * frame-rate/lighting/exploding: write `screen\max_frame_rate|min_frame_rate|lighting|exploding_on`, call **`RenderSettings_LoadFrameRateLighting` 0x4CB1D0** (cdecl, 1 dummy arg).
  * gamma: write `screen\gamma` (value = gamma × 10), call **`Gamma_ApplyFromRegistry` 0x4CB990**; `SetGamma` 0x4CB930 takes the ×10 integer directly. Our `Vid_SetGamma` is currently a stub (`host/w32_renderer.asm:573`), so gamma is a visual no-op until that is implemented.
  * audio: `SetCDVolume(byte)` (0x4105xx, call it directly), `FUN_004105C0(byte)` = SFX volume (still unnamed), persist with `Reg_Sound_SetDword` 0x4B5110 (CDVol only) / write the value yourself; 3D sound via `Sound_Set3DSoundEnabled(&DAT_005D85A0, flag)` + `Reg_Sound_SetFlag(&g_Registry,"do_3d_sound",flag)`.
  * controls: write `control\<idx>` DWORD (scancode | flags<<15) and call the loop at **0x44BF30** (cdecl, no args; fills `Controls` 0x5E8F5C and table 0x5E8F1C).
  * fullscreen/windowed toggle at runtime: `Screen_ToggleStartMode` 0x4CB4F0 (cdecl, 3 dummy args) then `Video_ReloadSettingsAndRemode`.
* **Calling convention notes:** the `__cdecl` entries with dummy arguments (`Video_ReloadSettingsAndRemode`, `RenderSettings_LoadFrameRateLighting`, `Gamma_ApplyFromRegistry`, `Screen_*`) are Ghidra prototype artefacts of unused register garbage; they take no real arguments (decompiled bodies never read them except `loadRender…`'s unused `param_1`). Cleaning the prototypes is a follow-up we did not do.


## 8. Save games and profiles

* **Savegame file:** `player\plyslot<N>.svg`, N = `Menu_GetProfileSlot` (0..7). Built in SaveGame (0x47EF40) with `sprintf("player\\plyslot%d.svg")` when the caller passes an empty name; `FrontEnd_BuildSaveSlotPath` does the same for the frontend. When a caller gives a path (`Menu_GetSavePath` = `Menu.unk2`/savePath, set by `Menu_SetSavePath`) that is used instead. Writes through `FUN_00402CF0` (create "wb") + `FUN_00402DA0` ("ab"), reads through `File_Open/File_Read`; the host serves the first from its overlay (`~/Library/Application Support/gta2-resurrected/player/`).
* **Format:** `[0x748-byte SaveGameHeader]` then three sections `[u32 size][size bytes]`, each possibly size 0 (the data block is skipped when size==0): (1) `g_MapBlocks` delta A = `*(MapBlocks+0x40008) + *(MapBlocks+0x40000)*4`, size `(this+0x360 - off)*4`; (2) delta B = `*(+0x4000C)+*(+0x40004)*0xC`, size `(this+0x354-off)*0xC`; (3) `this+4`, size `*(this+0x324) << 3`. These are the *dynamic tail* of the map's block/column tables (blocks added at runtime, i.e. modified map). Extracted by `FUN_004642A0`, re-applied by `FUN_00464250`. Layout semantics = hypothesis (Seq 37/map owner can confirm). No checksum, no version.
* **Functions:** save: `SaveGame` 0x47EF40 ← `Script_Op_SAVE_GAME` 0x47FE50 (opcode 277, unused in bil.scr), `Script_Op_PERFORM_SAVE_GAME` 0x47FE80 (opcode 438: the church/save point; costs $50000, "svmiss"/"svscore"/"svdone" HUD messages via `Hud_Brief_EnqueueNoArg`, refuses when a mission is active), `SomeSwitch` 0x41D0B0 case 9 (debug key via Player_OnKeyDown); helpers FUN_0047EE70 (collect patched script commands), FUN_00475CA0 (fill the three path strings + area/bonus bytes), FUN_00483D90 (collect weapon pickups), `Player::Player_SaveCheckpoint`. Load: `FrontEnd_LoadSavedGameSlot` 0x455850 (reads the first 0x52 header bytes, validates that each path starts with `data\`, calls `Menu_SetSavePath/GmpPath/StyPath/ScrPath/StartArea/BonusLevelId/IsBonusLevel`; DisplayError codes 0xA6/0xA7/0xA8 on a bad path) → game start → `InitGame` → `LoadGMP_and_STY_Files` 0x45B469 → `MissionScript_LoadSaveGame` 0x47F0B0 when `Menu_GetSavePath` is non-empty. Other callers of `Menu_SetSavePath`: `FrontEnd_SelectLevel`/`FrontEnd_UpdateMenuMode` clear it (`DAT_0056E5B4` = ""), `Replay_ReadHeader`, `Menu_LoadDebugLevelFromRegistry` (Debug\savename).
* **Other persistent files**: `player\plyslot<N>.dat` — profile/unlock data, 0x7E bytes, written by `FUN_004A89E0` (callers FrontEnd_CommitProfileName, FrontEnd_DeleteCurrentProfile, UnlockAllLevels, WinMain2-via-FUN_004A8F90 on level end, PlayerData_Ctor); `player\hiscores.hsc` — 0xF0 + 3×0x3F0 bytes of high scores, `FUN_004A8D80` (`FUN_004A8B60` builds the name). Both go through `FUN_00402CF0`. Owner: whoever takes `plydat`/`PlayerData_Ctor` (0x4A8xxx).
* **`host/debug_menu.asm` quick save** calls `SaveGame` 0x47EF40 directly (credit seuko-mod `save-game.cpp`); that is the full "save here" entry point for mods.


`SaveGameHeader` (0x748 bytes, struct created in the DB, not yet applied to `buf466` 0x664590):

| off | type | field | evidence |
|---|---|---|---|
| 0x00 | char[25] | gmpPath | FUN_00475ca0 copies Menu_GetGmpPath here; `DAT_006645a8`(=+0x18)=10 is its trailing marker (0x0A) |
| 0x19 | char[25] | styPath | `DAT_006645a9`; marker `DAT_006645c1`=10 |
| 0x32 | char[25] | scrPath | `DAT_006645c2`; marker `DAT_006645da`=10 |
| 0x4B | byte | startArea | `DAT_006645db` = Menu_GetStartArea; FrontEnd_LoadSavedGameSlot reads the first 0x52 bytes and uses it |
| 0x4C | byte | bonusLevelId | `DAT_006645dc` |
| 0x4D | byte | isBonusLevel | `DAT_006645dd` |
| 0x4E | 6 bytes | (unknown, not written by FUN_00475ca0) | gap to the checkpoint |
| 0x54 | byte[214] | playerCheckpoint | `Player::Player_SaveCheckpoint(currentPlayer, &DAT_006645e4)`; size = 0x6646BA-0x6645E4 (Seq 27 owns the layout; counterpart Player_LoadCheckpoint 0x4A6C80) |
| 0x12A | uint | patchCount | `_DAT_006646ba` written by FUN_0047ee70 (count of patched script commands). Width of the write is a decompiler guess (hypothesis) |
| 0x134 | ushort[600] | patchEntries | `DAT_006646c4`: 300 × {cmdIndex, value}; FUN_0047ee70 collects script commands of type 0x113/0x114 and stores `cmd_this` and the next command's `cmd_this`; FUN_0047ef10 writes them back on load |
| 0x5E4 | int[20] | pickupX | FUN_00483d90 (weapon pickups, ≤0x14, scans object table 0xEF1 × 0x2C) → `0x664b74` |
| 0x634 | int[20] | pickupY | +0x50 |
| 0x684 | int[20] | pickupZ | +0xA0 |
| 0x6D4 | ushort[20] | pickupType | +0xF0 (`object+0x18`) |
| 0x6FC | byte[20] | pickupAmmo | +0x118 (FUN_004340a0); FUN_00485640 respawns them with ObjectSpawner_SpawnObject + Pickup_SetAmmo on load |
| 0x710 | byte[50] | spawnerState | 12 dwords + 1 word copied from `g_ObjectSpawner+0x20` (→ `DAT_00664ca0`) |
| 0x744 | uint | menuField574 | `DAT_00664cd4` = `Menu+0x574` (`Menu_GetBonusTokenCount`); restored by FUN_00476b10 |

Verified: sum of the sections == 0x748 == the length passed to the writer (`local_10 = 0x748` in SaveGame, `iParm1 = 0x748` in MissionScript_LoadSaveGame) and the read of the first 0x52 bytes in FrontEnd_LoadSavedGameSlot lines up with +0x00/+0x19/+0x32/+0x4B..+0x4D.


## 9. Hooks for mods

### 9.1 Add a HUD element

- **Insertion point**: the `CALL DrawUI` at **0x45A61F** in `eachFrame` (preceded by
  `MOV ECX,[0x672F40]` at 0x45A619; re-checked from the bytes `8B 0D 40 2F 67 00 E8 1C FE 06 00`).
  The host already hooks this call site (`w32_hooks.asm`, used by `host/debug_menu.asm`). At that
  point the frame is between `gbh_BeginScene` and `gbh_EndScene`, the world and the score popups
  are drawn, and `g_ViewCamera` (0x5E3CC4) points to the local camera (UI scale at +0xA8).
  Call the original `DrawUI` (`__fastcall`, ECX = HudManager*) and then draw your element, or skip
  it to replace the whole HUD.
- **Text**: `Hud_DrawScaledText` 0x4C7280, stdcall, ret 0x20:
  `(wchar_t* text, Fix16 x, Fix16 y, short fontId, int* paletteBase, int remap, int invisibility, Fix16 alpha)`,
  with x/y in the 640×480 virtual space (`n << 14`). Or `DrawGTAText` 0x4CC100 (stdcall, ret 0x24,
  screen pixels). Pass a **pointer** to 2 as `paletteBase` for plain text.
- **Sprite**: `Hud_DrawSprite2DScaled` 0x4C71B0, stdcall, ret 0x24:
  `(type = 6 USER, spriteId, Fix16 x, Fix16 y, Ang16 rot, int* paletteBase, remap, invisibility, alpha)`.
- **Queued text without a hook**: `Hud_DebugLabel_Show` 0x4C8C20 (thiscall, ECX =
  g_HudManager + 0x818; text, x, y (0xFFFF = centre), fontId, ticks). It is safe from game-tick
  code, but each label is limited to 81 chars and 30 can be alive at once.
- **Per-tick state**: hook after the `DrawGUI` call in `GameTick`, or update the HudManager
  sub-objects in §2 directly.

### 9.2 Draw Cyrillic

`StyleData_GetFontGlyphSpriteId` 0x4BF550 turns a character code into a sprite id with a plain
add: `fontBase + code − 0x21`. There is no table and no bounds check, so a code ≥ 0x400 reads wild
memory: you get a crash or garbage, not a blank. Widths and wrapping only go through
`StyleData_GetFontGlyphWidth` 0x4BF570 (directly, or via `Font_GetGlyphWidth` 0x4539D0 and
`GetGTATextWidth`), and drawing goes through the glyph fetch inside `DrawGTAText`. Hooking those
two fetches, plus the texture for new ids, is enough: `Text_WordWrap` and the measure functions
then work unchanged. The kanji path (`KanjiFont_UploadGlyphSmall/Large`) already uploads arbitrary
bitmaps per code and is an alternative route that needs no `.sty` change (H).
`LocaleSettings_ToUpperChar` 0x4C21A0 needs a case for the new letters, or the `.gxt` must use
capitals. A new language letter needs `LocaleSettings_Ctor` 0x4C2620 (it accepts only
`e f g i s j`) and `Gxt_AreAllFilesMissing` 0x451800 patched; replacing the text of `e` needs
neither. Details: [fonts-localization.md](fonts-localization.md).

### 9.3 Add a menu item

Do it after `FrontEnd_InitPages` 0x453E20 has run (hook its call in `InitFrontend` 0x456A60, or
hook after `InitFrontend`). Fill the next free `FrontendPageItem` of the page (max 10; pages 2, 4,
8, 10, 11 and 15 have 1-3 items): `kind = 1`, `enabled = 1`, `x`, `y`, `label` (≤ 49 wchar),
`action`. Also set `cursors[i] = {x, y + 8, enabled = 1}`, because UP/DOWN read only the cursor,
then bump `itemCount`. No static tables need patching.

### 9.4 Add a new screen

Pages **12, 13 and 16 are constructed but empty**, so no table growth is needed:
1. fill the page (items, decor, cursors) as in §9.3;
2. point an item's `action` at it (12; a page id goes through `FrontEnd_GotoPage`);
3. **fix ESC**: the byte table at 0x459E20 sends page 12/13 to the "quit game" case. Patch
   byte `0x459E20 + 12` to 1 (back to page 0), or hook the ESC jump table 0x459E10;
4. background: `FrontEnd_UpdateBackgroundId` 0x455F90 gives unlisted pages image 7; patch it, or
   set `FrontEnd.backgroundId` (+0xEDF4) after `FrontEnd_GotoPage`.

### 9.5 Replace OPTIONS with our own screen (Seq 18)

OPTIONS is page 0 item 1, action 0x101. Its only code path is one call, **`CALL 0x4D0820` at
0x4599A1** (re-checked: `E8 7A 6E 07 00` → 0x4D0820). 0x4D0820 was misnamed `WinMain` and is now
**`FrontEnd_LaunchGta2Manager`**: it minimises the game window, and if the `GBH_BOB_MUTEX` mutex
is absent it calls `ShellExecuteA("gta2manager.exe")`; otherwise it brings the "GTA2 Manager"
window to front. Seq 17's `shl_ShellExecuteA` shim suppresses exactly that call. The comment in
`host/w32_misc.asm` still calls it "Ghidra WinMain". The same function is also reached from an
in-game key (stub 0x56DD67 from `Player_OnKeyDown`).

Options, in order of preference:
1. **Patch the call at 0x4599A1** to our routine, which calls `FrontEnd_GotoPage(this, 12)` on an
   empty page that we fill as in §9.4 (with the ESC fix). gta2manager is then never reached, and the
   Seq 17 shim becomes dead code.
2. Patch page 0 item 1's `action` word to 12 after `FrontEnd_InitPages`. This needs no code patch
   but needs the same ESC and background fixes.
3. Keep the 0x4D0820 hook and draw an overlay from the host. This needs the frontend keys muted by
   hand (`FrontEnd_SetKeyboardActive`, FE+0x10D), so it is more work.

Recommendation: 1. What the screen has to write and how each setting is re-applied is in §7.3.

## 10. Open questions and pending DB work

- **Structure Editor Clears that only the user can do** (MCP cannot free defined bytes):
  - `HudManager` +0x2E (1 byte, an anonymous `char` left over from a mistyped `this`). After it,
    place `HudCarNameLabel carName` at 0x0. (`zoneName` @0x4C and `bigLabel` @0x2854 went in
    without a Clear: `modify_struct_field` with a new type and name absorbs the following undefined
    bytes, re-checked with `get_struct_layout`.)
  - `FrontEnd` 0xD5E-0xD61 (`plyrslot`/`plyrslot2`, really page 1 item 0's choice fields),
    0x4DD8-0x4E3B (an unnamed wchar[50] = `pages[6].decor[2].text`) and 0xEDB5 (a 1-byte retype
    artefact). After them, add `FrontendPage pages[17]` at 0x122 and `FrontendLevelPaths
    levelPaths[12]` at 0xC9D4. Optional: 0x8-0xF, 0x1B, 0xFF-0x102 (stray fields inside the
    keyboard state[256] at 0x8), 0xC9A4-0xC9B5 (`wchar_t codeBuffer[9]`), 0xC9C5-0xC9C8 (the wrong
    dword `time`; the real next-tick time is the dword at 0xC9C8).
  - `SaveGameHeader` (§8) is created but not applied to `buf466` 0x664590, because the buffer
    interior carries its own `DAT_` labels.
- Hypotheses: the player marker at HudManager+0x2844; the arrow respect thresholds; "K.F." in the
  ammo text; `Hud_IsMpGameNotTag`; `MissionScript+0x344`; `Menu+0x574` and
  `levelEndReason`; the kill-frenzy payout path; the 30 Hz tick rate (taken from `CreateTimer`'s
  × 30, not measured).
- Unnamed callees on the edges: `FUN_004105C0` (SFX master volume), `FUN_00463850` (block-column
  query used by the player marker).
- The prototypes of the video/gamma functions still carry dummy cdecl parameters (they take none).
- gta2manager.ebin was not decompiled; "GM writes X" in §7 means only that X appears in its strings.

## Appendix A. Function table

Every named function of the HUD, text, frontend, settings and score areas, from `re/functions.csv`
at the time of writing. **V** = named or renamed by Seq 41 and verified (body + a second angle,
evidence in the Ghidra plate comment); **H** = `unsure_` prefix (hypothesis); **old** = the name
predates Seq 41 and was kept as is (checked by reading, but not re-verified in depth).

### Frontend (0x452000-0x459FFF, 98 functions)

| Address | Name | |
|---|---|---|
| 0x452000 | `FrontEnd_ReadKeyboardState` | V |
| 0x452050 | `FrontEnd_UpdateMenuKeys` | V |
| 0x4521B0 | `Text_GetCenteredX` | old |
| 0x452200 | `FrontEnd_GetItemDisplayText` | V |
| 0x452380 | `FrontEnd_GetDecorDisplayText` | V |
| 0x452490 | `copyPlayerName` | old |
| 0x4524C0 | `FrontEnd_ClearPlayerNameTail` | V |
| 0x452500 | `FrontEnd_GetCurrentProfileLevelTable` | V |
| 0x452530 | `Seq_ReadLabelLine` | old |
| 0x4527A0 | `FrontEnd_AddSeqLevel` | old |
| 0x452810 | `FrontEnd_GetLevelPaths` | V |
| 0x4528A0 | `FrontEnd_BuildSaveSlotPath` | V |
| 0x452940 | `FrontEnd_SaveSlotExists` | V |
| 0x452990 | `IntroMovieBik` | old |
| 0x4529C0 | `FrontEnd_GetPreIntroMoviePath` | V |
| 0x452A10 | `FrontEnd_IntroMovieExists` | V |
| 0x452A50 | `FrontEndPage_SelectPrevItem` | V |
| 0x452AA0 | `FrontEndPage_SelectNextItem` | V |
| 0x452B30 | `FrontEndItem_Ctor` | V |
| 0x452BD0 | `FrontEndItem_ChoiceNext` | V |
| 0x452C30 | `FrontEndItem_ChoicePrev` | V |
| 0x452C80 | `FrontEndDecor_Ctor` | V |
| 0x452CE0 | `FrontEndSaveSlotInfo_Ctor` | V |
| 0x452CF0 | `FrontEndSaveSlotInfo_Dtor` | V |
| 0x452D00 | `FrontEnd_ReadSaveSlotInfo` | V |
| 0x452D50 | `LoadFrontendImage` | old |
| 0x452E20 | `LoadFrontendImages` | old |
| 0x452E60 | `LocaleSettings_IsJapanese` | old |
| 0x452E80 | `FrontEnd_GetBackgroundImageIds` | V |
| 0x453020 | `DrawFrontendBackground` | old |
| 0x4531E0 | `FrontEnd_GetPrevUnlockedArea` | V |
| 0x453230 | `FrontEnd_GetNextUnlockedArea` | V |
| 0x4532B0 | `FrontEnd_HasPrevUnlockedArea` | V |
| 0x4532E0 | `FrontEnd_HasNextUnlockedArea` | V |
| 0x453310 | `FrontEnd_UpdateAreaSelector` | V |
| 0x453430 | `FrontEnd_FindLastUnlockedArea` | V |
| 0x453480 | `FrontEnd_UpdateCreditsScroll` | V |
| 0x453590 | `FrontEnd_DrawCredits` | V |
| 0x453870 | `FrontEnd_AreAllLevelsUnlocked` | V |
| 0x4538E0 | `FrontEnd_IsGameCdPresent` | V |
| 0x4538F0 | `FrontEnd_ClearCodeBufferTail` | V |
| 0x453930 | `FrontEnd_ShutdownMenuSound` | V |
| 0x453960 | `FrontEnd_InitMenuSound` | V |
| 0x4539B0 | `Font_GetLineHeight` | V |
| 0x4539D0 | `Font_GetGlyphWidth` | V |
| 0x4539F0 | `Frontend_DrawText` | old |
| 0x453A30 | `FrontEnd_SetKeyboardActive` | V |
| 0x453A40 | `FrontEnd_PackLevelId` | V |
| 0x453A60 | `FrontEnd_UnpackLevelId` | V |
| 0x453A80 | `Menu_GetBonusTokenCount` | V |
| 0x453A90 | `MultiplayerTag_HasPlayerQuit` | V |
| 0x453AA0 | `MultiplayerTag_GetPlayerTagTime` | V |
| 0x453AB0 | `MultiplayerTag_GetWinnerIndex` | V |
| 0x453B60 | `FrontEnd_DrawLoadingScreen` | V |
| 0x453BD0 | `FrontEnd_DrawDeleteProfileConfirm` | V |
| 0x453D40 | `FrontEnd_InitFontRole` | V |
| 0x453D80 | `dInput8` | old |
| 0x453E20 | `FrontEnd_InitPages` | V |
| 0x455340 | `FrontEnd_LoadSeq` | old |
| 0x4556A0 | `FrontEnd_SelectLevel` | V |
| 0x455850 | `FrontEnd_LoadSavedGameSlot` | V |
| 0x455C20 | `FrontEnd_LoadSaveSlotInfos` | V |
| 0x455C90 | `FrontEnd_DrawMultiplayerScores` | V |
| 0x455E50 | `FrontEndPage_Ctor` | V |
| 0x455EF0 | `FrontEndPage_Dtor` | V |
| 0x455F90 | `FrontEnd_UpdateBackgroundId` | V |
| 0x456110 | `FrontEnd_AreaSelectorLeft` | V |
| 0x456180 | `FrontEnd_GetPrevUnlockedBonusLevel` | V |
| 0x456280 | `FrontEnd_AreaSelectorRight` | V |
| 0x4562F0 | `FrontEnd_GetNextUnlockedBonusLevel` | V |
| 0x456430 | `FrontEnd_HasPrevUnlockedBonusLevel` | V |
| 0x456460 | `FrontEnd_HasNextUnlockedBonusLevel` | V |
| 0x456490 | `FrontEnd_UpdateBonusSelector` | V |
| 0x4565E0 | `FrontEnd_FindLastUnlockedBonusLevel` | V |
| 0x4566C0 | `Frontend_DrawTextInCells` | old |
| 0x456820 | `FrontEnd_DrawBonusRatingText` | V |
| 0x4568C0 | `FrontEnd_DrawKeyHint` | V |
| 0x456A60 | `InitFrontend` | old |
| 0x456D90 | `FrontEnd_Dtor` | V |
| 0x456E80 | `FrontEnd_RefreshProfileView` | V |
| 0x456F80 | `FrontEnd_DeleteCurrentProfile` | V |
| 0x456FB0 | `FrontEnd_DrawHighScoreRows` | V |
| 0x457140 | `FrontEnd_DrawLevelStatsPanel` | V |
| 0x457750 | `FrontEnd_BonusSelectorLeft` | V |
| 0x4577C0 | `FrontEnd_BonusSelectorRight` | V |
| 0x457830 | `Init` | old |
| 0x457900 | `FrontEnd_ScalarDeletingDtor` | V |
| 0x458590 | `FrontEnd_DrawPage` | V |
| 0x4585F0 | `DrawFrontendFrame` | old |
| 0x458650 | `FrontEnd_UpdateDeleteProfileConfirm` | V |
| 0x4587B0 | `FrontEnd_GotoPage` | V |
| 0x4590F0 | `ApplyCheats` | old |
| 0x459540 | `FrontEnd_CommitProfileName` | V |
| 0x459590 | `FrontEnd_OnContinueAction` | V |
| 0x459660 | `FrontEnd_OnCodeEntered` | V |
| 0x459760 | `relatedToAudio` | old |
| 0x4597C0 | `FrontEnd_UpdateMenuMode` | V |
| 0x459E30 | `FrontEnd_UpdateNameEntryMode` | V |

### Frontend tick (0x45A010-0x45A3CF, 3 functions)

| Address | Name | |
|---|---|---|
| 0x45A010 | `FrontEnd_UpdateCodeEntryMode` | V |
| 0x45A250 | `FrontEnd_UpdateMode` | V |
| 0x45A320 | `FrontEnd_Tick` | V |

### Menu block (0x45E390-0x45EEBF, 54 functions)

| Address | Name | |
|---|---|---|
| 0x45E390 | `Generator_Ctor` | V |
| 0x45E3A0 | `Generator_TurnOn` | old |
| 0x45E3E0 | `GeneratorManager_Ctor` | old |
| 0x45E410 | `Menu_SetGmpPath` | old |
| 0x45E430 | `Menu_SetStyPath` | old |
| 0x45E450 | `Menu_SetScrPath` | old |
| 0x45E470 | `Menu_SetSavePath` | old |
| 0x45E490 | `Menu_SetStartArea` | V |
| 0x45E4A0 | `Menu_SetBonusLevelId` | V |
| 0x45E4B0 | `Menu_SetIsBonusLevel` | V |
| 0x45E4C0 | `Menu_SetProfileSlot` | V |
| 0x45E4D0 | `Menu_SetLevelEndReason` | V |
| 0x45E4E0 | `Menu_GetGmpPath` | old |
| 0x45E4F0 | `Menu_GetStyPath` | old |
| 0x45E500 | `Menu_GetScrPath` | old |
| 0x45E510 | `Menu_GetSavePath` | old |
| 0x45E520 | `Menu_GetStartArea` | V |
| 0x45E530 | `Menu_GetBonusLevelId` | V |
| 0x45E540 | `Menu_GetIsBonusLevel` | V |
| 0x45E550 | `Menu_GetProfileSlot` | V |
| 0x45E560 | `Menu_GetLevelEndReason` | V |
| 0x45E570 | `Menu_SetCrimeStat` | V |
| 0x45E590 | `Menu_GetCrimeStat` | V |
| 0x45E5B0 | `Menu_SetTotalEarned` | V |
| 0x45E5C0 | `Menu_GetTotalEarned` | V |
| 0x45E5E0 | `Menu_GetWantedStarSeconds` | V |
| 0x45E5F0 | `Menu_SetBonusRatingTextId` | V |
| 0x45E600 | `Menu_GetBonusRatingTextId` | V |
| 0x45E610 | `Menu_SetBonusLevelSelected` | V |
| 0x45E620 | `Menu_GetBonusLevelSelected` | V |
| 0x45E630 | `Menu_ResetMultiplayerPlayerStats` | old |
| 0x45E6C0 | `Menu_SetMultiplayerGameSettings` | old |
| 0x45E700 | `Menu_GetMultiplayerGameType` | old |
| 0x45E710 | `Menu_GetFragLimit` | V |
| 0x45E720 | `Menu_GetMultiplayerLocalPlayerIndex` | V |
| 0x45E730 | `Menu_GetMultiplayerPlayerCount` | V |
| 0x45E740 | `Menu_SetMultiplayerWinnerIfUnset` | V |
| 0x45E760 | `Menu_GetMultiplayerWinner` | V |
| 0x45E770 | `Menu_SetPlayerName` | old |
| 0x45E7A0 | `Menu_GetPlayerName` | old |
| 0x45E7C0 | `Menu_AddMultiplayerPlayerPoints` | V |
| 0x45E7F0 | `Menu_GetMultiplayerPlayerPoints` | V |
| 0x45E810 | `Menu_GetMultiplayerPlayerFrags` | V |
| 0x45E830 | `Menu_GetMultiplayerKillMatrix` | V |
| 0x45E860 | `Menu_Ctor` | V |
| 0x45E8D0 | `Menu_LoadDebugLevelFromRegistry` | old |
| 0x45EC20 | `Menu_CopyPlayerCrimeStats` | V |
| 0x45EC70 | `Menu_RecordMultiplayerKill` | V |
| 0x45ED00 | `Keyboard_MaskLow12Bits` | V |
| 0x45ED10 | `Keyboard_SetMappedBit` | V |
| 0x45ED30 | `Keyboard_ClearMappedBit` | V |
| 0x45ED50 | `Keyboard_IsReservedKey` | V |
| 0x45EDC0 | `Keyboard_IsKeySwallowedWhilePaused` | H |
| 0x45EDE0 | `Keyboard_ToggleMappedBits` | V |

### Registry / config / stdio (0x4B5000-0x4B6B3F, 77 functions)

| Address | Name | |
|---|---|---|
| 0x4B5000 | `Reg_Sound_HasFlag` | V |
| 0x4B5070 | `Reg_Sound_GetDwordOrInit` | V |
| 0x4B5110 | `Reg_Sound_SetDword` | V |
| 0x4B5180 | `Reg_Sound_SetFlag` | V |
| 0x4B51F0 | `Reg_OpenDebugKey` | V |
| 0x4B5260 | `Reg_OpenOptionKey` | V |
| 0x4B52D0 | `Reg_OpenControlKey` | V |
| 0x4B5340 | `Reg_OpenScreenKey` | V |
| 0x4B53B0 | `Reg_Debug_HasValue` | V |
| 0x4B5420 | `Reg_Debug_GetString` | V |
| 0x4B5490 | `Reg_Option_GetString` | V |
| 0x4B5500 | `Reg_Option_GetDwordOrInit` | V |
| 0x4B55A0 | `Reg_Control_GetKeyBindOrInit` | V |
| 0x4B5660 | `Reg_Screen_GetDwordOrInit` | V |
| 0x4B5700 | `Reg_Screen_SetDword` | V |
| 0x4B5770 | `Reg_Screen_GetStringOrInit` | V |
| 0x4B58E0 | `Reg_OpenNetworkKey` | V |
| 0x4B5980 | `Reg_QueryDwordValue` | V |
| 0x4B5AE0 | `Reg_Network_GetDwordOrInit` | V |
| 0x4B5B80 | `Reg_Network_SetDword` | V |
| 0x4B5BF0 | `Reg_OpenPlayerKey` | V |
| 0x4B5C60 | `Reg_Player_GetDwordOrZero` | V |
| 0x4B5D10 | `Reg_Player_SetDword` | V |
| 0x4B5D80 | `Reg_ReadSizedBlob` | V |
| 0x4B5E20 | `Reg_GetBlobSize` | V |
| 0x4B5ED0 | `Mss_A3D_DisableSplash` | V |
| 0x4B5F70 | `MssAudio_ExtraSample_Alloc` | V |
| 0x4B5FB0 | `MssAudio_ExtraSample_Release` | V |
| 0x4B5FD0 | `MssAudio_Samples2D_ReleaseAll` | V |
| 0x4B6020 | `MssAudio_GetBankEntryFieldB0OrOne` | V |
| 0x4B6040 | `MssAudio_GetBankEntryFieldB4` | V |
| 0x4B6060 | `MssAudio_GetBankEntryFieldB8` | V |
| 0x4B6080 | `MssAudio_GetBankEntryFieldBC` | V |
| 0x4B60A0 | `MssAudio_GetBankEntrySize` | V |
| 0x4B60C0 | `MssAudio_Sample_SetAddress` | V |
| 0x4B6110 | `MssAudio_Sample_SetVolume` | V |
| 0x4B6130 | `MssAudio_Sample_SetPan` | V |
| 0x4B6150 | `MssAudio_Sample_SetPlaybackRate` | V |
| 0x4B6170 | `MssAudio_Sample_SetLoopBlock` | V |
| 0x4B6190 | `MssAudio_Sample_SetLoopCount` | V |
| 0x4B61B0 | `MssAudio_Sample_IsPlaying` | V |
| 0x4B61E0 | `MssAudio_Sample_Start` | V |
| 0x4B6200 | `MssAudio_Sample_End` | V |
| 0x4B6220 | `MssAudio_Sample3D_SetInfo` | V |
| 0x4B62B0 | `MssAudio_Sample3D_SetVolume` | V |
| 0x4B62D0 | `MssAudio_Sample3D_SetPosition` | V |
| 0x4B62F0 | `MssAudio_Sample3D_SetDistances` | V |
| 0x4B6320 | `MssAudio_Sample3D_SetPlaybackRate` | V |
| 0x4B6340 | `MssAudio_Sample3D_SetLoopBlock` | V |
| 0x4B6360 | `MssAudio_Sample3D_SetLoopCount` | V |
| 0x4B6380 | `MssAudio_Sample3D_IsPlaying` | V |
| 0x4B63B0 | `MssAudio_Sample3D_Start` | V |
| 0x4B63D0 | `MssAudio_Sample3D_EndIfPlaying` | V |
| 0x4B6420 | `MssAudio_Eax_SetEnvironment` | V |
| 0x4B6460 | `MssAudio_Eax_SetEffectParams` | V |
| 0x4B6550 | `MssAudio_Open3DProvider` | V |
| 0x4B65D0 | `MssAudio_Close3DProvider` | V |
| 0x4B6600 | `MssAudio_Enumerate3DProviders` | V |
| 0x4B66A0 | `MssAudio_MusicStream_IsDone` | V |
| 0x4B66D0 | `MssAudio_MusicStream_SetVolume` | V |
| 0x4B6700 | `MssAudio_MusicStream_Open` | V |
| 0x4B67B0 | `MssAudio_MusicStream_Close` | V |
| 0x4B67E0 | `MssAudio_MusicStream_FadeOutAndClose` | V |
| 0x4B6850 | `MssAudio_GetEnabledFlag` | V |
| 0x4B6860 | `MssAudio_Stream_Close` | V |
| 0x4B6890 | `MssAudio_Stream_SetVolume` | V |
| 0x4B68C0 | `MssAudio_Stream_SetPlaybackRate` | V |
| 0x4B68E0 | `MssAudio_Stream_GetPlaybackRate` | V |
| 0x4B6910 | `MssAudio_Stream_SetPositionMs` | V |
| 0x4B6930 | `MssAudio_Stream_GetPositionMs` | V |
| 0x4B6960 | `MssAudio_Stream_GetLengthMs` | V |
| 0x4B6990 | `MssAudio_ExtraSample_SetVolume` | V |
| 0x4B69B0 | `MssAudio_ExtraSample_PlayEntry` | V |
| 0x4B6A40 | `MssAudio_ExtraSample_IsNotDone` | V |
| 0x4B6A60 | `MssAudio_ExtraSample_End` | V |
| 0x4B6A80 | `MssAudio_ExtraSample_PlayRange` | V |
| 0x4B6B20 | `MssAudio_ExtraSample_Stop` | V |

### Score and floating score (0x4B73F0-0x4B998F, 43 functions)

| Address | Name | |
|---|---|---|
| 0x4B73F0 | `PlayerScore_Ctor` | old |
| 0x4B7490 | `PlayerScore_Init` | old |
| 0x4B74D0 | `PlayerScore_GetMoney` | old |
| 0x4B7500 | `PlayerScore_GetCarValue` | old |
| 0x4B7570 | `PlayerScore_GetFrags` | old |
| 0x4B7580 | `PlayerScore_AddFrags` | old |
| 0x4B7590 | `unsure_Game_IsExitReasonSet` | H |
| 0x4B75B0 | `PlayerScore_RecomputeCarModelFlags` | old |
| 0x4B7660 | `PlayerScore_AddMoney` | old |
| 0x4B76A0 | `PlayerScore_TrackAccuracy` | V |
| 0x4B7770 | `PlayerScore_Update` | old |
| 0x4B7D50 | `PlayerScore_ResetForLevel` | old |
| 0x4B7D80 | `PlayerScore_CheckAllCarsBonus` | old |
| 0x4B7E90 | `PlayerScore_MarkCarModel` | old |
| 0x4B7EB0 | `PlayerScore_OnPedKilled` | old |
| 0x4B85B0 | `PlayerScore_OnCarDestroyed` | old |
| 0x4B8870 | `unsure_PlayerScore_OnCarWrecked` | H |
| 0x4B89B0 | `unsure_PlayerScore_OnCarOccupantKilled` | H |
| 0x4B8A60 | `unsure_PlayerScore_GiveCarKillFlat20` | H |
| 0x4B8A70 | `PlayerScore_OnCarjack` | old |
| 0x4B8BD0 | `unsure_PlayerScore_OnCrimeKind4` | H |
| 0x4B8C80 | `unsure_PlayerScore_OnCarStolen` | H |
| 0x4B8D60 | `FloatingScoreManager_NextColor` | V |
| 0x4B8D80 | `FloatingScoreManager_IncFreeCount` | V |
| 0x4B8DC0 | `FloatingScore_ClearDigits` | V |
| 0x4B8DE0 | `FloatingScore_Init` | V |
| 0x4B8F70 | `FloatingScore_Tick` | V |
| 0x4B8FD0 | `FloatingScorePool_GetActiveHead` | V |
| 0x4B8FE0 | `FloatingScorePool_PopFreeToActive` | V |
| 0x4B9000 | `FloatingScorePool_MoveActiveToFree` | V |
| 0x4B90E0 | `Camera_WorldToScreen` | V |
| 0x4B91E0 | `FloatingScoreManager_DtorBody` | V |
| 0x4B91F0 | `FloatingScoreManager_Spawn` | old |
| 0x4B9260 | `FloatingScoreManager_Update` | old |
| 0x4B92B0 | `FloatingScore_DrawDigit` | V |
| 0x4B9440 | `FloatingScoreManager_InitPools` | V |
| 0x4B9490 | `FloatingScoreManager_Ctor` | old |
| 0x4B94B0 | `FloatingScore_Draw` | V |
| 0x4B98B0 | `FloatingScoreManager_Draw` | old |
| 0x4B98D0 | `OwnerSlotTable_AllocSlot` | old |
| 0x4B9940 | `OwnerSlotTable_DecRef` | V |
| 0x4B9960 | `OwnerSlotTable_Ctor` | old |
| 0x4B9980 | `OwnerSlotTable_Dtor` | V |

### GXT / locale (0x4C2000-0x4C296F, 29 functions)

| Address | Name | |
|---|---|---|
| 0x4C2060 | `GxtChunk_TKEY` | old |
| 0x4C20B0 | `Gxt_ResolveKeyPointers` | old |
| 0x4C20E0 | `Gxt_CompareKeys` | old |
| 0x4C2120 | `Gxt_FindTextW` | old |
| 0x4C2150 | `GxtChunk_TDAT` | old |
| 0x4C21A0 | `LocaleSettings_ToUpperChar` | old |
| 0x4C2250 | `LocaleSettings_ToUpperString` | old |
| 0x4C2280 | `Gxt_WideToAnsiStatic` | old |
| 0x4C22D0 | `Text_AnsiToWideStaticN` | V |
| 0x4C2300 | `Text_AnsiToWideStatic` | V |
| 0x4C2330 | `LocaleSettings_ReadGxtChunk` | old |
| 0x4C23A0 | `Gxt_FindTextW_thunk` | old |
| 0x4C23B0 | `Gxt_FindTextAnsi` | old |
| 0x4C23D0 | `Text_GetSpaceWidth` | V |
| 0x4C23F0 | `Gxt_ClearKeyTable` | old |
| 0x4C2400 | `LocaleSettings_FreeKeyTable` | old |
| 0x4C2420 | `LocaleSettings_ClearText` | old |
| 0x4C2430 | `LocaleSettings_FreeTextBlock` | old |
| 0x4C2450 | `Text_WordWrap` | old |
| 0x4C2540 | `LoadGXT` | old |
| 0x4C257F | `Gxt_LoadFromFile` | old |
| 0x4C2620 | `LocaleSettings_Ctor` | old |
| 0x4C26C0 | `LocaleSettings_Dtor` | old |
| 0x4C2710 | `TextureTable_Alloc` | V |
| 0x4C2780 | `TextureTable_RegisterSpriteTextures` | V |
| 0x4C27F0 | `TextureTable_RegisterSpritePaletteTextures` | V |
| 0x4C28D0 | `TextureTable_Free` | V |
| 0x4C2920 | `TextureTable_GetBySprite` | V |
| 0x4C2950 | `TextureTable_GetBySpritePalette` | V |

### HUD (0x4C5E00-0x4CAD2F, 163 functions)

| Address | Name | |
|---|---|---|
| 0x4C5E00 | `Hud_WantedStar_Tick` | V |
| 0x4C5E60 | `Hud_Arrow_SetArrowColour` | old |
| 0x4C5E70 | `Hud_ArrowPool_ClaimFreeArrow` | V |
| 0x4C5EA0 | `Hud_Arrow_ColourFromPhoneObjectType` | V |
| 0x4C5EE0 | `Hud_Arrow_ColourName` | V |
| 0x4C5F10 | `Hud_Arrow_RespectThresholdForColour` | V |
| 0x4C5F30 | `Hud_QuitConfirm_ConsumesKey` | V |
| 0x4C5F60 | `Player_SetQuitConfirm` | old |
| 0x4C5F70 | `Hud_ChatInput_ConsumesKey` | V |
| 0x4C5FD0 | `Hud_BigLabel_Hide` | V |
| 0x4C5FE0 | `Hud_BigLabel_Layout` | old |
| 0x4C6060 | `ShowBigOnScreenLabel` | old |
| 0x4C60B0 | `Hud_BigLabel_Tick` | old |
| 0x4C60C0 | `Hud_BigLabel_Ctor` | old |
| 0x4C60D0 | `Hud_MulIntByFix16` | V |
| 0x4C60F0 | `Hud_DebugLabel_TickIsExpired` | V |
| 0x4C6110 | `Hud_DebugLabel_IsDuplicateOf` | V |
| 0x4C6170 | `Hud_DebugLabel_ExpireFinished` | V |
| 0x4C6250 | `Hud_DebugLabelPool_Init` | V |
| 0x4C6290 | `Hud_Pager_C_Slot_TickTimer` | V |
| 0x4C62B0 | `Hud_Pager_C_Array_TickTimers` | V |
| 0x4C62D0 | `Hud_Brief_RestoreHistoryHeadToActive` | V |
| 0x4C62F0 | `Hud_Brief_RecycleHeadNode` | V |
| 0x4C6310 | `Hud_Brief_MoveHeadToHistoryFront` | V |
| 0x4C6340 | `Hud_Brief_MoveHeadToHistoryTail` | V |
| 0x4C6380 | `Hud_Brief_AllocNode` | old |
| 0x4C63F0 | `Hud_Brief_SpeakerIconFromChar` | old |
| 0x4C6470 | `Hud_Brief_PrepareCurrentText` | old |
| 0x4C6640 | `Hud_Brief_StartHead` | old |
| 0x4C6690 | `Hud_Brief_Enqueue` | old |
| 0x4C6750 | `Hud_Brief_EnqueueNoArg` | old |
| 0x4C6770 | `Hud_Brief_Tick` | old |
| 0x4C6830 | `Hud_Brief_RecallPending` | old |
| 0x4C6860 | `Hud_Brief_ClearAllBriefsWithPriority` | old |
| 0x4C68E0 | `Hud_Brief_Ctor` | old |
| 0x4C6940 | `Hud_CarName_Measure` | old |
| 0x4C6960 | `Hud_CarName_Show` | old |
| 0x4C69A0 | `Hud_CarName_Tick` | old |
| 0x4C69C0 | `Hud_CarName_Ctor` | old |
| 0x4C69D0 | `Hud_Pickup_Measure` | old |
| 0x4C69F0 | `Hud_Pickup_Show` | old |
| 0x4C6A40 | `Hud_Pickup_Tick` | old |
| 0x4C6A50 | `Hud_Pickup_Ctor` | old |
| 0x4C6A60 | `Hud_KillFeed_Measure` | old |
| 0x4C6A80 | `Hud_KillFeed_Show` | old |
| 0x4C6AC0 | `Hud_KillFeed_Ctor` | old |
| 0x4C6AD0 | `Hud_ZoneName_Measure` | old |
| 0x4C6AF0 | `Hud_ZoneName_Show` | old |
| 0x4C6B70 | `Hud_ZoneName_Update` | old |
| 0x4C6C60 | `Hud_ZoneName_ResetAnim` | V |
| 0x4C6C70 | `Hud_ZoneName_Ctor` | old |
| 0x4C6C90 | `StyleData_GetSpriteHeight` | V |
| 0x4C6CA0 | `Hud_TickAnimatedValues` | old |
| 0x4C6D00 | `Hud_PauseOverlay_AdvancePage` | V |
| 0x4C6D90 | `Hud_PauseOverlay_Tick` | V |
| 0x4C6DA0 | `Hud_SetFullAmbientAtNight` | V |
| 0x4C6DC0 | `get_text_speed` | old |
| 0x4C6DE0 | `Hud_IsKeyConsumedByOverlay` | V |
| 0x4C6E20 | `Hud_QuitConfirm_ConsumesKey_Thunk` | V |
| 0x4C6E30 | `ObjectPrefabs_GetDefaultSpriteId` | V |
| 0x4C6E50 | `Hud_PlayerMarker_Init` | V |
| 0x4C6E70 | `Hud_DebugPedInfo_Init` | V |
| 0x4C6EA0 | `Hud_WantedStar_SetBlinkPeriod` | V |
| 0x4C6EE0 | `Hud_WantedStars_Init` | V |
| 0x4C6F00 | `Hud_ArrowTarget_Clear` | V |
| 0x4C6F20 | `Hud_ArrowTarget_IsEmpty` | V |
| 0x4C6F30 | `Hud_ArrowTarget_GetPlayer` | V |
| 0x4C6F40 | `Hud_Arrow_Ctor` | V |
| 0x4C6F80 | `Hud_Arrow_HasNoTargets` | V |
| 0x4C6FB0 | `Hud_Arrow_HasBothTargets` | V |
| 0x4C6FE0 | `Hud_Arrow_SetGangIcon` | V |
| 0x4C6FF0 | `Hud_Arrow_InitOrbitRadiusBase` | V |
| 0x4C7030 | `Hud_Arrow_SetGang` | V |
| 0x4C7040 | `Hud_Arrow_SetMinRespect` | V |
| 0x4C7050 | `Hud_Arrow_IsVisible` | V |
| 0x4C7060 | `Hud_Arrow_ToggleCurrentTarget` | V |
| 0x4C7080 | `Hud_ArrowPool_Ctor` | V |
| 0x4C70B0 | `Hud_ArrowPool_IsEnabled` | V |
| 0x4C70E0 | `Hud_DebugLabel_ResetBlend` | V |
| 0x4C70F0 | `Hud_DebugLabel_Expire` | V |
| 0x4C7120 | `Hud_Pager_C_Slot_SetTimer` | V |
| 0x4C7130 | `Hud_Pager_C_Slot_SetCounter` | V |
| 0x4C7160 | `Hud_Pager_C_Slot_IsCounterFree` | V |
| 0x4C7170 | `Hud_Pager_C_Slot_IsTimerFree` | V |
| 0x4C7180 | `Hud_Pager_C_Slot_AddToTimer` | V |
| 0x4C71A0 | `Hud_PauseOverlay_Init` | V |
| 0x4C71B0 | `Hud_DrawSprite2DScaled` | V |
| 0x4C7220 | `Hud_GetUserSpriteWidth` | V |
| 0x4C7250 | `Hud_GetUserSpriteHeight` | V |
| 0x4C7280 | `Hud_DrawScaledText` | old |
| 0x4C72F0 | `ChatInput_AppendChar` | old |
| 0x4C7320 | `ChatInput_Backspace` | old |
| 0x4C7340 | `Player_GetArrowBlockerZone` | V |
| 0x4C7350 | `MissionScript_IsOnMission` | H |
| 0x4C7370 | `Hud_IsMpGameNotTag` | V |
| 0x4C7380 | `MultiplayerTag_GetPlayerTimeValue` | V |
| 0x4C73A0 | `Hud_PlayerMarker_Update` | V |
| 0x4C74A0 | `Hud_PlayerMarker_Draw` | V |
| 0x4C74F0 | `Hud_GangRespectBars_Draw` | V |
| 0x4C78A0 | `Hud_DrawPlayerNames` | old |
| 0x4C79D0 | `Hud_WantedStars_Update` | V |
| 0x4C7A30 | `Hud_WantedStars_Draw` | V |
| 0x4C7B10 | `Hud_WantedStars_InitFromSprite` | V |
| 0x4C7B70 | `Hud_Health_Draw` | V |
| 0x4C7CC0 | `Hud_ArrowTarget_SetGangLocation` | V |
| 0x4C7CF0 | `Hud_ArrowTarget_UpdatePosition` | V |
| 0x4C7E60 | `Hud_Arrow_UpdateTargets` | V |
| 0x4C82C0 | `Hud_Arrow_Draw` | V |
| 0x4C83D0 | `Hud_Arrow_SetSpriteFromPedRemap` | V |
| 0x4C8470 | `Hud_ArrowPool_HasOtherVisibleArrowForGang` | V |
| 0x4C84C0 | `Hud_ArrowPool_Draw` | V |
| 0x4C8540 | `Hud_ArrowPool_FindOnScreenGangArrow` | V |
| 0x4C8590 | `Hud_ArrowPool_HasLocationArrowForGang` | V |
| 0x4C85D0 | `Hud_ArrowPool_RemoveOrphanLocationArrows` | V |
| 0x4C8620 | `Hud_ArrowPool_Clear` | V |
| 0x4C8650 | `Hud_ArrowPool_FindByGangAndColour` | V |
| 0x4C8690 | `Player_HandleQuitConfirmKey` | old |
| 0x4C8880 | `ChatInput_HandleKey` | old |
| 0x4C8910 | `Hud_DrawChatInput` | old |
| 0x4C8990 | `Hud_ChatInput_DrawLine` | V |
| 0x4C8A20 | `ChatInput_Open` | old |
| 0x4C8A40 | `Hud_BigLabel_Draw` | V |
| 0x4C8AA0 | `Hud_DebugLabel_Init` | old |
| 0x4C8B90 | `Hud_DebugLabel_Draw` | V |
| 0x4C8BE0 | `Hud_DebugLabelPool_ExpireDuplicates` | V |
| 0x4C8C20 | `Hud_DebugLabel_Show` | V |
| 0x4C8C80 | `Hud_DebugLabelPool_Draw` | V |
| 0x4C8CA0 | `Hud_Pager_DrawCounterDigits` | V |
| 0x4C8E30 | `Hud_Pager_DrawTimerDigits` | V |
| 0x4C9040 | `Hud_Pager_Draw` | V |
| 0x4C92A0 | `Hud_Pager_C_Array_Draw` | V |
| 0x4C9310 | `Hud_Pager_C_Array_CreateTimer` | old |
| 0x4C9360 | `Hud_Pager_C_Array_AddOnScreenCounter` | old |
| 0x4C93B0 | `Hud_Pager_C_Array_ClearSlot` | V |
| 0x4C93D0 | `Hud_Pager_C_Array_ClearTimer` | V |
| 0x4C93F0 | `Hud_Pager_C_Array_AddTimeToTimer` | V |
| 0x4C9410 | `Hud_Pager_C_Array_ClearCounter` | V |
| 0x4C9430 | `Hud_Brief_Draw` | V |
| 0x4C94F0 | `Hud_CarName_Draw` | V |
| 0x4C9690 | `Hud_Pickup_Draw` | V |
| 0x4C96F0 | `Hud_KillFeed_Draw` | V |
| 0x4C9750 | `Hud_KillFeed_ShowMpKill` | old |
| 0x4C9890 | `Hud_ZoneName_Draw` | V |
| 0x4C9A40 | `Hud_Weapon_Draw` | V |
| 0x4C9B40 | `Hud_PowerupIcon_Draw` | V |
| 0x4C9C20 | `Hud_DrawPlayerPanel` | old |
| 0x4C9FA0 | `Hud_PauseOverlay_Draw` | V |
| 0x4CA440 | `DrawUI` | old |
| 0x4CA520 | `Font_AssignRolesByLocale` | old |
| 0x4CA5D0 | `Hud_HandleOverlayKeyDown` | V |
| 0x4CA610 | `Hud_Arrow_Reset` | V |
| 0x4CA650 | `Hud_Arrow_SetGangLocationTarget` | V |
| 0x4CA660 | `Hud_Pager_C_Array_Ctor` | V |
| 0x4CA680 | `Hud_DebugPedInfo_Update` | V |
| 0x4CA770 | `Hud_Arrow_ShouldShow` | V |
| 0x4CA860 | `Hud_Arrow_Tick` | V |
| 0x4CA890 | `Hud_ArrowPool_Tick` | V |
| 0x4CA8E0 | `Hud_Arrow_7C_Array_AllocArrow` | old |
| 0x4CA910 | `Hud_ArrowPool_RegisterGangPhoneArrow` | V |
| 0x4CAB50 | `DrawGUI` | old |
| 0x4CABE0 | `Hud_RelayoutAllText` | old |
| 0x4CAC30 | `Hud_OnGameStart` | V |
| 0x4CAC60 | `HudManager_Ctor` | old |

### Renderer, video settings, text and sprite drawing (0x4CAD30-0x4CC85F, 46 functions)

| Address | Name | |
|---|---|---|
| 0x4CAD30 | `InitMouseExclusive` | old |
| 0x4CADA0 | `MouseExclusive_Acquire` | V |
| 0x4CADB0 | `DeinitMouseExclusive` | old |
| 0x4CAE50 | `InitRenderer` | old |
| 0x4CAEA0 | `InitRendererDevice` | old |
| 0x4CAEB0 | `d3ddll_ConvertColourBank` | old |
| 0x4CAEC0 | `BeginFrame2D` | V |
| 0x4CAF50 | `EndFrame2D` | old |
| 0x4CAF60 | `Renderer_DrawLineByPlot` | V |
| 0x4CB050 | `Text_GetQuadFlags` | old |
| 0x4CB0C0 | `GetGTATextWidth` | old |
| 0x4CB140 | `Video_InvalidateCameraDimsCache` | V |
| 0x4CB150 | `Video_SyncCameraDimsAndTime` | V |
| 0x4CB1D0 | `RenderSettings_LoadFrameRateLighting` | V |
| 0x4CB290 | `RenderSettings_LoadWindowMode` | V |
| 0x4CB3F0 | `ReadRendererSettings` | old |
| 0x4CB4D0 | `Screen_SetStartMode` | V |
| 0x4CB4F0 | `Screen_ToggleStartMode` | V |
| 0x4CB520 | `isFullScreenMode` | old |
| 0x4CB530 | `HideMouseCursor` | old |
| 0x4CB550 | `ShowMouseCursor` | old |
| 0x4CB570 | `SetFullscreenMode` | old |
| 0x4CB6C0 | `Video_GetDesktopColourDepthStub16` | V |
| 0x4CB6F0 | `CanRenderWindowed` | old |
| 0x4CB720 | `Video_GetWindowedAllowed` | V |
| 0x4CB730 | `SetWindowedMode` | old |
| 0x4CB740 | `SetWindowedMode_Apply` | V |
| 0x4CB880 | `Video_ReapplyColourBankAndCameraDims` | V |
| 0x4CB890 | `ShutdownVideo` | old |
| 0x4CB930 | `SetGamma` | old |
| 0x4CB990 | `Gamma_ApplyFromRegistry` | V |
| 0x4CB9C0 | `Gamma_RetryTick` | V |
| 0x4CBA00 | `KanjiFont_GetSmallSpriteEntry` | V |
| 0x4CBA10 | `KanjiFont_GetSmallField14` | V |
| 0x4CBA20 | `KanjiFont_GetLargeSpriteEntry` | V |
| 0x4CBA30 | `KanjiFont_GetLargeField20` | V |
| 0x4CBA40 | `KanjiFont_SetDefaultColors` | old |
| 0x4CBA50 | `DrawSprite2D` | old |
| 0x4CBDB0 | `DrawSprite2DAt` | old |
| 0x4CC0C0 | `Text_GetMultilineHeight` | old |
| 0x4CC100 | `DrawGTAText` | old |
| 0x4CC580 | `Window_StoreWindowedPosition` | V |
| 0x4CC5C0 | `Video_ReloadSettingsAndRemode` | V |
| 0x4CC6A0 | `Video_ReloadSettingsIfChanged` | V |
| 0x4CC6D0 | `InitVideo` | old |
| 0x4CC810 | `Weapon_Reset` | V |

### Elsewhere

| Address | Name | |
|---|---|---|
| 0x455850 | `FrontEnd_LoadSavedGameSlot` | V |
| 0x45A5A0 | `eachFrame` | old |
| 0x47EF40 | `SaveGame` | old |
| 0x47F0B0 | `MissionScript_LoadSaveGame` | old |
| 0x4B90E0 | `Camera_WorldToScreen` | V |
| 0x4D0820 | `FrontEnd_LaunchGta2Manager` | V |
| 0x4D11B8 | `WinMain2` | old |

### Names added by Seq 47 (slice 4: 0x4A4770-0x4AF880)

| Address | Name | Confidence | Evidence |
|---|---|---|---|
| 0x4A4770 | `Hud_ZoneName_ClearZoneTypes` | high | zeroes HudZoneNameLabel +0x88/+0x8C (zone types; caller passes &g_HudManager->zoneName, not a Player - Seq 48); only caller Player_OnKeyDown |
| 0x4A4F10 | `Player_DtorMembers` | med | +0x360=0 and vector dtor of 10x0x2c at +0x1a8; callers Player_Dtor + Unwinds |
| 0x4A4FE0 | `Weapon_GetAmmo` | high | returns WEAPON_STRUCT.ammo; Player_BeginKfCarWeapon stores as kfSavedAmmo |
| 0x4A4FF0 | `Weapon_SetAmmoRaw` | high | writes ammo short without *10; Player_EndKfWeapon restores kfSavedAmmo |
| 0x4A5090 | `Camera_GetPosZPlusTwo` | med | Fix16_Add(camera+0xa0, 2.0 const DAT_0066b1d0); Player_GetPos/GetBlockPos |
| 0x4A5190 | `CarDeltas_GetBits` | med | returns *this of Car.deltasBitstate; sprite draw FUN_004be060 |
| 0x4A51A0 | `CarDeltas_SetBits` | med | *this=*p; sprite draw + Player_RestoreSavedCars |
| 0x4A51B0 | `Car_SetDamage` | high | writes Car+0x74 (damage short); Player_RestoreSavedCars |
| 0x4A52B0 | `Player_BeginKfWeapon` | high | on-foot twin of BeginKfCarWeapon; callers SET_KF_WEAPON / START_BASIC_KF_TEMPLATE |
| 0x4A61C0 | `Player_ResetPedsAndDeactivate` | med | Ped_ResetToDummy(ped, auxPed) + SetActive(0); caller prints "comms1" |
| 0x4A71F2 | `Player_OnKeyDown_Frag` | high | tail POP/POP/POP/RET 4 of Player_OnKeyDown, reached by JMP from Patch1144_OnKeyDown_LaunchManagerHook 0x56DD79 (section 4 of crt-and-network.md) |
| 0x4A8600 | `HiScoreTable_Clear` | high | 10x0x18 table cleared with default name |
| 0x4A8630 | `HiScoreTable_Insert` | high | sorted insert (name,score) into 10-entry table, returns inserted |
| 0x4A8700 | `ProfileSlot_Reset` | med | zeroes 0xa4 slot, unlocks first level; FrontEnd_DeleteCurrentProfile |
| 0x4A8780 | `PlayerProfile_GetTotalBestScore` | med | sums ints of 12 level records |
| 0x4A87B0 | `PlayerData_DtorMembers` | high | vector dtors for profiles/levelHiScores; caller scalar deleting dtor |
| 0x4A8820 | `Profile_BuildDatPath` | high | builds "player\plyslot<N>.dat" |
| 0x4A88C0 | `Profile_DatFileExists` | high | _findfirst on that path |
| 0x4A8910 | `PlayerData_LoadProfileSlot` | high | reads plyslot<N>.dat into slot N |
| 0x4A89E0 | `PlayerData_SaveProfileSlot` | high | packs 0x7E-byte image, File_WriteWhole |
| 0x4A8A90 | `PlayerData_UnlockLevel` | med | sets unlock byte of level (area*4+stage), saves slot |
| 0x4A8B60 | `HiScores_BuildPath` | high | copies "player\hiscores.hsc" |
| 0x4A8B80 | `PlayerData_InitDefaultHiScores` | med | default names ALAN..JACKSON / scores into PlayerData+0x24c0 |
| 0x4A8CB0 | `PlayerData_LoadHiScores` | high | reads hiscores.hsc |
| 0x4A8D80 | `PlayerData_SaveHiScores` | high | writes hiscores.hsc |
| 0x4A8ED0 | `PlayerData_ResetHiScoresToDefaults` | med | clears + inserts built-in default entries |
| 0x4A8F50 | `PlayerData_ScalarDeletingDtor` | high | DtorMembers + _free(flag&1) |
| 0x4A8F70 | `HiScoreTable_Ctor` | high | Clear(this); return this |
| 0x4A8F90 | `PlayerData_UpdateProfileLevelScore` | med | level end: best/last score of current level, save slot; WinMain2 |
| 0x4A9050 | `HiScores_FileExists` | high | _findfirst hiscores.hsc |
| 0x4A90A0 | `PlayerData_UpdateHiScoresAfterLevel` | med | inserts into tables, crime bests, saves; WinMain2 |
| 0x4A9210 | `PlayerData_ApplyMuchCashCheat` | high | profile name == "MUCHCASH" -> GiveMoney 500000 |
| 0x4A9270 | `PlayerData_DestroyGlobalInstance` | high | delete g_PlayerData |
| 0x4A9AC0 | `PoliceManager_FreeBuffer` | high | _free(this+0xa0); callers include 3 unwinds so maybe member dtor |
| 0x4AB9D0 | `PoliceCrew_HandleObjEnterCar` | high | case 0x23 of PoliceCrew_Update switch |
| 0x4ABA30 | `PoliceCrew_HandleObjLeaveCar` | high | case 0x24 of PoliceCrew_Update switch |
| 0x4ABA90 | `PoliceCrew_HandleObjGoToAreaInCar` | high | case 0xe of PoliceCrew_Update switch |
| 0x4AF570 | `PublicTransportManager_IsBusCarId` | med | carId == bus car (this+0x17cc), !g_skipBuses |
| 0x4AF5A0 | `PublicTransportManager_GetBoardableBusCar` | high | bus car if actor state(+0x1808)==0xd |
| 0x4AF5E0 | `PublicTransportManager_IncBusPassengerCount` | med | ++byte +0x1816 |
| 0x4AF5F0 | `PublicTransportManager_KillAllBusPassengers` | high | count=0 + PedList_KillAndFreeAll; Script_Op_KILL_ALL_PASSENGERS |
| 0x4AF7F0 | `PublicTransportManager_Dtor` | high | only caller is its ScalarDeletingDtor |
| 0x4AF860 | `Ped_SetTrainDriverStopOnArrive` | med | Ped+0x13c = stop; at train arrival in Manager_Update |
| 0x4AF880 | `Ped_SetTrainDriverStopOnDepart` | med | same body, at pre-departure timer |
