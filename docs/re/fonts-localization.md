# Fonts and new alphabets (plan for a Russian translation)

What it takes to show text the shipped fonts cannot draw (Cyrillic first), the options with their
trade-offs, and how to draw glyphs so a later importer can use them. Facts come from
[gxt.md](gxt.md) (§4 encoding, §6 drawing and fonts, §7 limits); this page is the plan built on
them. Status 2026-10-26: **RE complete** (Seq 27 phase 3, §"RE status and implementation steps" at the end);
text editing works and was checked in the game; font sheets can be exported; nothing else is implemented yet.

## Why it is a font problem, not a text problem

- A `.gxt` string is an array of u16 units. Any value fits, so real Unicode Cyrillic (U+0410…U+044F,
  U+0401, U+0451) can be stored as is.
- The units are **font glyph codes**, not characters: `DrawGTAText` 0x4CC100 draws sprite
  `fontBase + code − 0x21`, with no table and no bounds check. A code past the font's last glyph
  draws the next font's sprites (garbage).
- Every in-game font has 144 glyphs (codes 0x21–0xB0; 0xB1 in font 5); fstyle fonts 0 and 3 have 140
  (to 0xAC). All slots are used by ASCII and the 49 accented letters (0x80–0xB0), except a few
  2-px blank placeholders: in wil font 1 `# & + < = > @ [ \ ] ^ _ { | }` and 0x7F.
- Shipped languages: `e f g i s` (Latin, the codes above) and `j` (Japanese, a separate bitmap font
  `kanji.dat` with a real u16 → glyph table; not shipped). There is no Cyrillic anywhere.

So a translation needs (1) glyphs for the new letters, (2) a way for the game to draw them, (3) the
text. Only (3) is solved (`gxt --export/--import`, gxt.md §9).

## Fonts that need glyphs

In-game fonts are pixel-identical in wil/ste/bil.sty (checked: every font sheet compares equal), so
one in-game set covers all three levels.

| Sheet (`sty --font-sheet`) | Used for | Case | Needs |
|---|---|---|---|
| `wil-font1` | HUD default (`DefaultFontId`), briefs, pager, pickups | upper + lower | all 66 letters, **the most important one** |
| `wil-font0` | big centre labels (WASTED, mission passed) | upper only | 33 capitals |
| `wil-font2` | car names | upper only | 33 capitals |
| `wil-font5` | zone names | upper only | 33 capitals |
| `wil-font6` | pause-screen title | upper only | 33 capitals |
| `fstyle-font4/8/11/13` | frontend menus | upper only (like font 6) | 33 capitals |
| `fstyle-font4/5` | credits (roles Fe4 0x67066C, Fe5 0x67064C) | upper only | 33 capitals |
| `fstyle-font10` | stats screen | upper only | 33 capitals |
| `fstyle-font0`, `fstyle-font3` | big/small frontend text, full 0x21–0xAC | upper + lower | 66 |
| `fstyle-font7/9` | menu decor (`FrontEnd_DrawMenuPage`) | upper only | 33 capitals |
| `fstyle-font6/12` | roles Fe6 / Fe12 are set but never read | — | leave alone |
| `wil-font3/4`, `fstyle-font1/2` | Japanese placeholders (1 glyph) | — | leave alone |

The game upper-cases big labels, car and zone names itself (`LocaleSettings_ToUpperString`
0x4C2250) because those fonts have no lower case, but its tables only know a–z and the Latin accents
(gxt.md §4). Cyrillic needs its own upper-casing (see the options), or those texts written in
capitals in the `.gxt`.

Text length: Russian runs ~15–25 % longer than English. Briefs have room (640 units after wrap,
longest shipped 259). Car names (32), zone and pickup names (64) and big labels (99) are copied
without bounds checks: `gxt --import` already refuses longer ones.

## Options

### 1. Custom code page in the accent slots (works with the vanilla exe)

Cyrillic letters that look like Latin ones reuse the Latin glyphs (А В Е К М Н О Р С Т Х, а е о р
с у х). The rest are painted over the 49 accent slots 0x80–0xB0 and the blank placeholders.
Distinct shapes needed: about 21 capitals (Б Г Д Ж З И Й Л П У Ф Ц Ч Ш Щ Ъ Ы Ь Э Ю Я) and about 26
lower case (б в г д ж з и й к л м н п т ф ц ч ш щ ъ ы ь э ю я, plus ё/Ё): roughly 47–49 slots, a
tight fit (estimate, not checked glyph by glyph). The `.gxt` then uses our own table, not Unicode.

- Upper-casing can ride the existing table for language `g`/`i`/`s` (0x97–0xAC → 0x80–0x95,
  0xAE → 0xAD): place each lower-case letter exactly 0x17 above its capital and the game
  upper-cases them for free. Fragile, and it loses the German/Italian/Spanish accents for good.
- Needs a `.sty` writer that replaces font sprites (we only have the decoder). Replacing a glyph with
  a different width means repacking sprite pixels (SPRG pages) and the SPRX index.
- Pro: the result also runs in the original game on Windows. Con: most work, every font of every
  `.sty` (three level styles and fstyle), and the accented languages are destroyed in that file set.

### 2. Glyph substitution in our port (recommended)

Our host already replaces the renderer, so it can draw glyphs the `.sty` does not have:

- detour the glyph branch of `DrawGTAText` at 0x4CC308 so codes ≥ 0x400 come from our own atlas textures
  instead of `.sty` sprites (hooking `StyleData_GetFontGlyphSpriteId` 0x4BF550 alone is not enough: the
  branch then reads a real SpriteEntry and texture by that id; see the steps at the end);
- hook `StyleData_GetFontGlyphWidth` 0x4BF570 the same way, or `GetGTATextWidth` and
  `Text_WordWrap` measure the wrong width and centring/wrapping break;
- add Cyrillic upper-casing next to `LocaleSettings_ToUpperChar` 0x4C21A0 (U+0430–U+044F → −0x20,
  ё → Ё);
- language: replace the `e` file's text (simplest), or a new letter, which needs patches in
  `LocaleSettings_Ctor` (compare chain 0x4C2652–0x4C26A7), the `ToUpperChar` switch,
  `Font_AssignRolesByLocale` 0x4CA520 and `Gxt_AreAllFilesMissing` 0x451800.

The `.gxt` holds real Unicode, `.sty` files stay untouched, the glyphs live as PNG sheets in the
overlay (or a pak of our own). Only works in our port — which is the point of the project. The
glyph art is the same work as in option 1, but drawn into PNGs instead of repacked into `.sty`.

### 3. The Japanese path as a Cyrillic font (vanilla exe, no `.sty` edits)

Set language `j` and ship a `j.gxt` plus our own `kanji.dat`: header `KANJ` + u16 100, chunk `KIDX`
(u16 code → glyph index; codes < 0x100 are looked up shifted into the high byte; `0xFFFF` →
fallback entry `0x2100`) and `KBIT` (16×16 1-bpp bitmaps, 32 bytes each; the 32-px font is the same
bitmap doubled 2×, not a second set) (`KanjiFont_*`, gxt.md §2, §6). **Ship a full 0x10000-entry
KIDX**: the lookup has no bounds check (see the hazards in gxt.md §6). All HUD text roles switch to the kanji fonts, so everything is drawn monospaced 16 or 32 px
wide in two colours. Works without code changes but looks like a terminal; the KIDX/KBIT reading was
analysed, not run.

## Drawing the glyphs (font sheets)

```
bun tools/formats/cli.ts sty data/wil.sty    --font-sheet all --out formats-out/fonts
bun tools/formats/cli.ts sty data/fstyle.sty --font-sheet all --out formats-out/fonts
```

Each `<style>-font<N>.png` (+ `.json` manifest, `tools/formats/font-sheet.ts`):

- Top block, magenta grid: the shipped glyphs, 16 per row by code (column = low hex digit, rows
  0x20, 0x30 … 0xB0), 1:1, the sprite's own palette, transparent background.
- Bottom block, cyan grid: 66 empty cells in Unicode order — А…Я, а…я, Ё, ё. Letters that look
  like Latin ones are pre-filled with a copy of that Latin glyph (`copiedFrom` in the manifest).

Rules so a future importer can read the sheets back:

1. Do not move or resize the grid; one glyph per cell, drawn from the cell's **top-left** corner.
2. Keep the font's height (every glyph of a font has the same height, `cellH`); width is free up to
   the cell width. The importer will take the width from the rightmost opaque pixel, so leave the
   spacing column(s) the Latin glyphs have (look at `w` of a neighbour in the manifest).
3. Use only colours already in that font (`colours` in the manifest): fonts are palette-indexed and
   drawn with remaps (`#` highlight = `PALETTE_BASE_FONT_REMAP`), so a new colour has no palette
   entry. Transparent = colour 0.
4. Upper-case-only fonts need only the capitals row(s).

The sheets are game-derived: keep them out of git (`formats-out/` is ignored) and out of the
disposable task worktree.

## Frontend limits a translation must respect

Read in code (Seq 27 U5 pass, 2026-10-24; details and VAs in
[hud-and-menus.md](hud-and-menus.md) §6.6–§6.7), not tested with a translated GXT:

- **Menu labels ≤ 49 characters.** `FrontEnd_InitPages` 0x453E20 copies every item / decor text
  with `_wcsncpy(dst, gxt, 50)` into `wchar[50]`; a string of 50+ characters is left without a NUL
  and the draw reads on into the item's `fontId` / `remap` fields. Russian runs about 20 % longer
  than English, so check the long keys.
- **`credits` grammar.** The single key `credits` is parsed by `Credits_ParseText` 0x449D70 with no
  bounds checks: `*` = 20 px gap and line end, `#W` / `#B` / `#G` / `#C` (or any other letter) =
  style, `BINKLOGO` / `MILESLOGO` = logo sprites. Every entry must be closed by `*` (the reader
  does not stop at NUL), each line ≤ 49 characters, ≤ 600 entries (the shipped text has ≤ 535,
  max 28 chars). Anything else writes past the FrontEnd object into the heap.
- **Name entry needs real glyphs.** A typed character is accepted only if its glyph is wider than
  2 px (0x459EB5) and the scancode has an entry in the `g_SKeyboard` layout table
  (`SKeyboard_GetCharForScancode`). The 2-px placeholder glyphs cannot be typed.
- **No restart needed.** The frontend is destroyed and recreated around every game
  (`FrontEnd_DestroyGlobal` / `FrontEnd_CreateGlobal`), and `InitFrontend` reloads the GXT each
  time, so a language switch shows on the next menu entry.

## RE status and implementation steps

RE complete (Seq 27 phase 3, 2026-10-26; R1 static analysis, the live probe `gta2ctl text`). (V) read in code, (L) live.

**The seam.** All text is drawn by `DrawGTAText` 0x4CC100 (9 callers, all wrappers: `Hud_DrawScaledText*`,
`Frontend_DrawText`, `FrontEnd_DrawCredits`, `FrontEnd_DrawMenuPage` x2, `Frontend_DrawTextInCells`, `FrontEnd_DrawKeyHint`,
`FrontEnd_DrawHighScoreRows`); there is no inlined copy of the glyph lookup elsewhere (V). Per character:

| Function | VA | Convention | Callers | Live (L, 2026-10-25/26) |
|---|---|---|---|---|
| `StyleData_GetFontGlyphSpriteId` | 0x4BF550 | thiscall(StyleData*, fontId, short glyph = code - 0x21), `RET 8`, 16-bit, no bound | `DrawGTAText` 0x4CC313 only (plus kanji init, a dead function) | only caller seen 0x4CC318, fonts 1, 4, 5, 7, 8, 9 (menu and HUD) |
| `StyleData_GetFontGlyphWidth` | 0x4BF570 | thiscall(StyleData*, ushort *fontId, ushort *code), `RET 8`: kanji 16/32, else `SPRX[fontBase + code - 0x21].w`, no bound | `GetGTATextWidth` 0x4CB119, `Font_GetGlyphWidth` 0x4539E0 (stdcall wrapper for `Text_WordWrap` and frontend name / code entry) | callers 0x4CB11E, 0x4539E5 |
| `LocaleSettings_ToUpperChar` | 0x4C21A0 | thiscall(LocaleSettings*, code), `RET 4`; tables only for 0x80..0xFF, every other code passes unchanged | `LocaleSettings_ToUpperString` 0x4C2250 only (big labels, car names, zone names, debug labels, MP names; not menus, credits, briefs) | caller 0x4C226C |

Live check (L, `gta2ctl text swap`, HUD pager "HELLO EVERYONE THE END"): glyph E drawn as X, then as I, came out as
"HXLLO XVXRYONX THX XND" / "HILLO IVIRYONI THI IND"; the advance follows the substituted glyph because `DrawGTAText`
takes it from the SpriteEntry of the returned id. The width function only measures (centring, wrapping, name entry),
so the left-anchored pager did not exercise it. Menu, HUD and pager fonts all came through the single `DrawGTAText` site.

**Why the hooks are mandatory.** A Cyrillic code (U+0410..) gives glyph offset ~0x3EF: sprite id fontBase + 0x3EF lies
past the 2089 sprites of `wil.sty`, so both the id path and the width path read past the sprite index (V; the crash
itself not run). The hooks must treat every code outside the font's real range (`fontBases[f+2] - fontBases[f+1]`
glyphs, `StyleChunk_FONB` 0x4BFDD0), not only Cyrillic: shipped f/i/s.gxt and MP chat contain such codes too.

**Other answers.**
- Text baked into images: none that matters. Frontend `.tga`s are photos and logos (`demoinfo.tga`, the only one with
  English paragraphs, is never shown); WASTED / BUSTED / MISSION COMPLETE / KILL FRENZY are GXT keys drawn with fonts;
  `user` sprites hold single letters and the BINK / MILES logos (V, rendered). Not checked: street signs in tiles and
  the `.bik` intros (U).
- Buffers: `wcharBuf` 0x5E9F08 and `g_BriefDebugTextBuf` 0x5E9A08 are 640 wchar; briefs wrap into 640 wchar after
  `Text_WordWrap` inserts line breaks (no bound); car name 33, zone and pickup 65, big label 100 wchar (V). Brief anchor
  (`Hud_Brief_Draw` 0x4C9430): x 64, bottom-anchored, wrap width 576, no clipping (V). `LocaleSettings.textLength`
  has no readers (V, scan of 141 loads).
- Language: the letter comes only from the registry (`Option\language`, `LocaleSettings_Ctor` 0x4C2620, compare chain
  0x4C2675..0x4C268B, anything unknown -> `e`); `LoadGXT` 0x4C2540 builds `data\%c.gxt` / `GBL%c`. A new letter `r`
  needs one detour in that chain; nothing else tests the letter except `LocaleSettings_IsJapanese` (V). **Recommended:
  replace the content of `e.gxt`** (overlay file or a VFS alias), zero exe patches.
- Typing (name entry, chat): `keybrd` 0x461200 reads `{eng,ger,...}_kb.cfg` byte by byte, so Cyrillic cannot come from a
  layout file; hook `SKeyboard_GetCharForScancode` 0x4611F0 (thiscall, `RET 4`, u16) to return Unicode from SDL. Name
  entry accepts a character only if its glyph is wider than 2 px (0x459EB5), so the width hook must answer for it.
- Upper-case-only fonts: menus and credits are not upper-cased by the game, so their Russian text must be written in
  capitals, or the glyph hook maps а..я to А..Я for those font ids.

**Implementation steps, in order** (the implementation task I would open):
1. Draw `wil-font1` Cyrillic (HUD, briefs, pager) on the font sheet; then the capitals of the other fonts.
2. Font-sheet importer: PNG cells -> glyph bitmaps + widths, palette-quantised to the font's colours.
3. C32 + host: a detour at 0x4CC308 that, for codes >= 0x400 (and any out-of-range code), supplies an atlas SpriteEntry
   (w, h) in ESI and a host texture in EDI and joins at 0x4CC350 like the kanji branches (whether EBP must be reloaded
   from [ESP+0x70] first is U: check it in the disassembly); a detour on `StyleData_GetFontGlyphWidth` returning atlas
   widths (blank width for unknown codes); Cyrillic in `LocaleSettings_ToUpperChar` (U+0430..U+044F -> -0x20, ё -> Ё).
   `host/c32/text_probe.c` already detours all three and is the starting point.
4. `gxt --import` accepts Cyrillic per font once glyphs exist; a Russian `e.gxt` in the overlay.
5. `SKeyboard_GetCharForScancode` hook for typing names.
6. The translation itself (2595 keys per language file, `credits` included; mind the limits above and in
   "Frontend limits").
