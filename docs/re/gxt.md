# GTA2 text: `.gxt` files, lookup, encoding, fonts (11.44)

How vanilla `gta2.exe` 11.44 loads its text table, finds a string by key, what the 16-bit
"characters" mean, how `DrawGTAText` turns them into font sprites, and which fixed buffers break
when strings get longer. Written so that a `.gxt` can be edited or rebuilt and still load and
render. Addresses are 11.44 VAs, 1:1 with the Ghidra program `gta2.segments.fixed.exe` and with
`re/`; every name below is saved in the `gta-2-recovered` project (Seq 35) and reaches `re/`
through `re/tools/export.sh`. Decoder/encoder: `tools/formats/gxt.ts`
(`bun tools/formats/cli.ts gxt data/e.gxt --list|--key KEY|--summary`).

**Evidence**: **V** = verified in the 11.44 decompile/disassembly and, for sizes and counts,
against the shipped files in `data.pak`; **H** = hypothesis (reason given).

## 1. File layout (V)

Little-endian. Measured on all 10 shipped files (`e f g i s .gxt`, `bob_e … bob_s .gxt`): every
one has exactly this shape and `encodeGxt(decodeGxt(f))` is byte-identical.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | magic `GBL` + upper-case language letter | `GBLE GBLF GBLG GBLI GBLS` (`GBLJ` for Japanese, not shipped). Checked with `strncmp(…, 4)`; mismatch → `DisplayError(0x5D)` |
| 4 | 2 | u16 version = 100 | mismatch → `DisplayError(0x5E)` |
| 6 | … | chunks `{char tag[4]; u32 size; u8 data[size]}` until EOF | shared chunk module of `.sty`/`.gmp`/`.scr` |

Chunks the game reads (`LocaleSettings_ReadGxtChunk` 0x4C2330, `strncmp(tag, …, 4)`):

- **`TKEY`** — `size / 12` entries of `{u32 offset; char key[8]}`. `offset` is a **byte offset
  from the start of the TDAT data**; after loading, `Gxt_ResolveKeyPointers` 0x4C20B0 adds the
  TDAT base and the field becomes a `wchar_t*`. `key` is ASCII, ≤ 7 characters, NUL-terminated,
  NUL-padded to 8 bytes. Entries are sorted by unsigned byte order (`strcmp`), unique.
- **`TDAT`** — `size / 2` u16 code units; each string ends with a u16 0. Shipped files pack the
  strings back to back with no gaps, no sharing and no empty strings, in authoring order
  (`car0 car1 …` first). That is **not** key order: offsets are non-monotonic in TKEY order.
- Any other tag is skipped by its size. A chunk of size 0 is skipped without dispatch. TKEY and
  TDAT may come in either order (pointers are fixed after the whole file is read). If either is
  missing every lookup returns the fallback `L" "`.

In memory (`LocaleSettings`, `operator_new(0x14)`):

| Off | Type | Field | |
|---|---|---|---|
| +0x0 | `LocaleSingle*` | `keys` | TKEY copy, `keyCount × 12` bytes; `.text` pointers after fix-up |
| +0x4 | int | `keyCount` | `size / 12` |
| +0x8 | `wchar_t*` | `text` | TDAT copy, `operator_new((size >> 1) * 2)` |
| +0xC | **u32** | `textLength` | `size >> 1`. A 32-bit store (`MOV [ESI+4],EAX` at 0x4C2150); Ghidra had `ushort`, fixed. No reader found. Shipped TDAT is 153 590–174 072 units, so there is no 65 535 limit |
| +0x10 | char | `language` | `e f g i s j` |

Ghidra's `LocaleSettings` type is 0x11 bytes; the object is 0x14 (3 bytes tail padding not
modelled, `resize_struct` was refused by the MCP tool).

**No validation** of `TKEY size % 12`, TDAT parity, offset range, sort order or duplicates (V,
the three readers above). Consequences: an odd TDAT size or a TKEY size not divisible by 12 reads
the whole chunk into a smaller block (heap overflow by up to 11 bytes); an offset past TDAT reads
garbage; an unsorted table makes `bsearch` miss keys silently (text renders as one space).

`bob_*.gxt` (201 keys: `version nocards recog2 3dtxt …`) hold real **Latin-1** text, not font
codes, and `gta2.exe` has no reference to them (only `GBH_BOB_MUTEX`): they belong to an external
tool (H: the launcher). Do not apply the font code page to them.

## 2. Loading and language selection (V)

```
WinMain → Debug_LoadFlagsFromRegistry → Gxt_AreAllFilesMissing 0x451800   (start-up probe only)
InitFrontend 0x456A60 ─┐
Game_Ctor 0x45C4D0 ────┼→ operator_new(0x14) → LocaleSettings_Ctor 0x4C2620 (reads registry language)
NetDlg_OnInitDialog ───┘    (lobby: own instance g_NetDialogLocaleSettings 0x5D31D8)
InitFrontend / LoadGMP_and_STY_Files 0x45B469 (sets g_Patch1144 flag 0x676204 = 1 first)
  → LoadGXT 0x4C2540: sprintf(strPathToGXT 0x676CD8, "data\%c.gxt", lang); sprintf(magic, "GBL%c", lang-0x20)
  → JMP Patch1144_LoadGXT_MmpOverrides 0x56DF08  (11.44 patch, multiplayer .mmp override)
  → Patch1144_LoadGXT_ClearFlagAndContinue 0x3F1664 (flag = 0, JMP 0x4C257F)
  → Gxt_LoadFromFile 0x4C257F: File_Open, header 6 B, FileHeader_CheckMagic/CheckVersion(100),
      chunk loop → LocaleSettings_ReadGxtChunk 0x4C2330 → GxtChunk_TKEY 0x4C2060 / GxtChunk_TDAT 0x4C2150 / File_Skip
      File_Close → Gxt_ResolveKeyPointers 0x4C20B0
```

- **Language**: `regGet("language")` from `HKCU\SOFTWARE\DMA Design Ltd\GTA2\Option` into
  `generalCharBuf`. Only the **first byte** is tested: lowercase `e f g i s j` is stored,
  anything else (upper case, empty, missing value) becomes `e`, silently. Only gta2manager writes
  that value (H: no other "language" string in the exe). Our host's registry is seeded from
  `gta2_install.reg` (docs/win32-shims.md, "Registry"); `Option\language` there picks the file.
- **Reload**: a fresh `LocaleSettings` (language re-read) and a fresh `LoadGXT` on every entry to
  the frontend and to a level; freed by the frontend teardown 0x456D90 and `Game_Dtor` 0x45D3D0
  (`LocaleSettings_Dtor` 0x4C26C0: two `free`s). An edited `.gxt` is picked up on the next
  frontend/level entry without restarting.
- **11.44 patch** (byte-checked): only when the flag is set (level load, not the frontend) **and**
  `isMultiplayer` (0x673E2C) = 1, it reads `[MapFiles] GXTFile` (default `e.gxt`) and `GCIFile`
  from the map's `.mmp` with `GetPrivateProfileStringA` into `strPathToGXT + 5` (after `data\`).
  If the value is exactly `e.gxt` the player's own language letter is put back; any other name
  forces `language = 'e'` for that object and the expected magic to `GBLE`. So a custom
  multiplayer text file is a bare name in `data\`, magic `GBLE`, shown to every language.
  It also resets the GCI path to `data\nyc.gci`. Shipped `.mmp` files have no `GXTFile`.
- `Gxt_AreAllFilesMissing` (was `CheckIFGXTexists`, the old name was inverted) returns TRUE only
  if none of `data\{e,f,g,i,j,s}.gxt` opens; the result `g_gxtAllFilesMissing` 0x5EAD73 makes
  `WinMain` take the "no text" movie path (`doPlayMovies = 0xE`).
- **Japanese** (`j`, `LocaleSettings_IsJapanese` 0x452E60): `Game_Ctor` also creates a
  `KanjiFont` (0x28 B) from `data\kanji.dat` = header `KANJ` + u16 100, chunks `KIDX` (u16 code →
  glyph index table) and `KBIT` (16×16 1-bpp bitmaps, 32 B each) (`KanjiFont_LoadKanjiDat`
  0x460F10, `KanjiFont_ReadChunk` 0x45FF70; created only when `LocaleSettings_IsJapanese`, else
  `g_KanjiFont` 0x661E98 stays NULL and none of it runs). Neither `j.gxt` nor `kanji.dat` is in `data.pak`.

## 3. Lookup (V)

- `Gxt_FindTextW` 0x4C2120, `wchar_t* __thiscall(LocaleSettings*, const char* key)`, `RET 4`:
  `bsearch(key, keys, keyCount, 12, Gxt_CompareKeys)`; hit → the TDAT pointer, miss → static
  `L" "` (0x575540). **A missing key draws one space: no assert, no log.** Most of the ~134 call
  sites go through `Gxt_FindTextW_thunk` 0x4C23A0. The "third argument" the decompiler used to
  show at every call was the next `swprintf`'s first vararg; the prototype is fixed.
- `Gxt_CompareKeys` 0x4C20E0: unsigned-byte `strcmp(key, entry + 4)`, case-sensitive, stops at the
  first NUL. An 8-character key has no NUL in its 8-byte field and runs into the next entry's
  offset bytes: it never matches. **Keys ≤ 7 bytes.**
- The returned pointer is into the shared TDAT block; callers copy or format it.
- `Gxt_FindTextAnsi` 0x4C23B0 → `Gxt_WideToAnsiStatic` 0x4C2280: copies ≤ 79 units into the static
  80-byte `g_GxtAnsiBuffer` 0x671880, every unit ≥ 0x80 becomes `#`. Used only by the Win32
  network-lobby dialog (`NetDlg_*`, keys `netui01…22`; `&` in them is the Win32 mnemonic).

### Who asks for text, with which keys (V unless marked)

| Area | Keys | Code |
|---|---|---|
| Mission scripts | **numeric**: `sprintf("%d", u16 id at cmd+8)` — text id 3724 is key `"3724"` | `Script_Op_DISPLAY_MESSAGE` 0x4792B0: opcode 117 → big label now (prio 3); 118/321/279 → brief queue prio 1/2/3, key queued, text looked up when shown. Phone templates 263/329 use ids `base−7 … base+1`. Mission fail on arrest 0x47F550: `8001` or the gang death-base briefs (e.g. 4200), plus big label `mfail` |
| Voice lines | ids 5000, 0x157D–0x1586, 0x1397, 0x13A7/8, 0x13BA–0x13C7 also `PlayVocal` a fixed sample | same handler: editing the text does not change the voice |
| Area names | 3-char zone name in the `.gmp` **is** the key: `m01–m44`, `s01–s09`, `w01–w03`, `B01–B25`; other lengths are shown raw | `Zone_GetDisplayName` 0x462BE0 |
| Car / gang / pickup names | `car%d` (0–86; 15, 20, 43 missing → blank), `ganga%d` (1–7), `c%02d` (c00–c44) | `GetCarModelName` 0x41F700, `GetGangName` 0x45DD20, `Hud_Pickup_Show` 0x4C69F0 |
| Big labels | `wasted fried nicked shocked g_over mfail kfstart kfpass kffail tport yourit excutin elvis_d em_dest gencide copkill carjaka accurcy wrngway fly_car stl_all dst_all` | `ShowBigOnScreenLabel` 0x4C6060 |
| Pause / quit | `pause pscore pgmiss pmiss psec pbon quit1-3` — **printf formats** | 0x4C9FA0, `DrawUI` 0x4CA440 |
| Frontend | `play options quit mainmen savepos hi_* charctr strtlev bonslev credits loading yes no …`; `MainMenu` copies with `wcsncpy(…, 50)` | `MainMenu` 0x453E20 and neighbours |
| Multiplayer | `mpkill1-5`, `comms1` (`%s has left the game!`), `mult_* frags_h pnts_h times_h` | `Hud_KillFeed_ShowMpKill` 0x4C9750, 0x4620E0 |
| Shop / save | `arig nespray nspraya bdone cdone sdone` (one `%d`), `svmiss svscore svdone` | `Car_BuyUpgrade`, `Car_Respray`, `Script_Op_PERFORM_SAVE_GAME` |

Numeric keys: 2184 in each main file (ranges 801–8002: wil briefs 1001–1624, ste 2900–6186, bil
3230–3753, kill-frenzy/race 5000–5063, 7000–7235, `8001`/`8002`); 411 named keys. Keys `8011–8013`
are requested by `Player_RunDebugKeyAction` but absent (blank). 36 named keys and the `psx*` set have no
reference in the exe (H: unused on PC).

**Debug aid**: registry/ini flag `show_brief_number` (`g_showBriefNumber` 0x5EADA5) draws every
brief as `(key)text` — the quickest way to see which key a line on screen comes from. In our host:
`debug:` / `show_brief_number: true` in the overlay's `config.yaml` (`host/c/config.c`).

## 4. Encoding (V)

A TDAT unit is a **font glyph code**, not Unicode or Latin-1. `DrawGTAText` draws sprite
`fontBase + (code − 0x21)` for everything that is not one of three special units (§5).

- `0x21–0x7E`: ASCII glyphs. `0x20`: space. No unit below 0x20 exists in any shipped string (no
  LF, no TAB): line breaks come only from word wrap.
- `0x80–0xB0`: the accented glyphs, same order in every font (read off the wil.sty font 1 sprite
  sheet; letter frequencies per language confirm them: é 0x9E is the most frequent French code,
  ß 0x96 / ü 0xAC German, ¡ 0xB0 / ñ 0xAE Spanish). `tools/formats/gxt.ts` `FONT_ACCENTS`,
  `toUnicode`, `fromUnicode`:

| +0 | +1 | +2 | +3 | +4 | +5 | +6 | +7 | +8 | +9 | +A | +B | +C | +D | +E | +F |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **0x80** À | Á | Â | Ä | Æ | Ç | È | É | Ê | Ë | Ì | Í | Î | Ï | Ò | Ó |
| **0x90** Ô | Ö | Ù | Ú | Û | Ü | ß | à | á | â | ä | æ | ç | è | é | ê |
| **0xA0** ë | ì | í | î | ï | ò | ó | ô | ö | ù | ú | û | ü | Ñ | ñ | ¿ |
| **0xB0** ¡ | | | | | | | | | | | | | | | |

  There is no Ã, Å, Õ, œ, ÿ, no Cyrillic, nothing beyond 0xB0 (0xB1 exists only in in-game font 5).
- Shipped bugs: f.gxt has Latin-1 `0xE9` ×4 and `0xF4` ×1, i.gxt `0xE0` ×4, s.gxt `0xE1`, `0xED`
  — real Latin-1 typed into the font-coded file. They index past the font and draw another
  font's sprites.
- `0x2153, 0x216B–0x216E, 0x2170, 0x2172, 0x2173, 0x2179, 0x217A`: **speaker markers**, only as
  the first unit of a brief (§5). Highest unit in any file: 0x217A.

**Upper-casing** (`LocaleSettings_ToUpperString` 0x4C2250 → `LocaleSettings_ToUpperChar`
0x4C21A0, a `switch` on the language letter): `e` a–z only; `f` a–z plus `g_UpperCaseTable_F`
0x594EF8 (accented lower case → plain ASCII capital, except æ→Æ, ç→Ç); `g i s` a–z plus
`g_UpperCaseTable_GIS` 0x594DF8 (0x97–0xAC → 0x80–0x95, ñ→Ñ); `j` and anything else unchanged.
Applied to the big label, car name and zone name (their fonts have no lower case), and to debug
labels in fonts G0/G5.

## 5. Control codes (V)

| Unit | Meaning | Handled in |
|---|---|---|
| `0x0A` | new line: x back to the start, y += line height × scale | `DrawGTAText` 0x4CC100, `GetGTATextWidth` 0x4CB0C0 (widest line), `Text_WordWrap` 0x4C2450 (resets width, counts lines), `Text_GetMultilineHeight` 0x4CC0C0 |
| `0x20` | advance by the font's space width; the only wrap point | same three |
| `#` 0x23 | **highlight toggle**, zero width, not drawn: switches between the caller's (palette, remap) and (`PALETTE_BASE_FONT_REMAP` 8, remap 0). Persists across wrapped lines; an unbalanced `#` stays on to the end of that string. `#alle Zaibatsu-Jobs#` highlights the span | `DrawGTAText`; zero width in width and wrap |
| first unit `0x216B…0x217A` | brief speaker icon: `Hud_Brief_SpeakerIconFromChar` 0x4C63F0 maps 216B→6, 216C→1, 216D→7, 216E→8, 2170→9, 2172→4, 2173→5, 2179→2, 217A→3, and the unit is skipped. Any other first unit → icon 8 and the unit is **kept** | `Hud_Brief_PrepareCurrentText` 0x4C6470. 0x2153 (key `2495`, once) is not in the switch → drawn as garbage (shipped bug) |
| `%d`, `%s`, `%%` | C `swprintf` conversion, only where the caller formats: briefs queued with an argument (one 32-bit arg; `nspraya bdone cdone sdone`), the pause screen, kill feed, `comms1`, `NetDlg_*` | 0x4C6470 and the callers in §3. A brief without an argument is not formatted: `%` is literal there |
| `*`, `#W #B #G #C` | **only in key `credits`**: `*` ends an entry / adds a 20-px gap; `#` + letter sets the line colour (W 0, B 2, G 3, C 4, other 1); TAB skipped | `Credits_ParseText` 0x449D70, `Credits_NextChar` 0x449D30 |

Nothing else is special: no `~`, `[ ]`, `{ }`, button tokens or escapes exist in the engine or the
files. `&` occurs only in `credits` ("MR. CLARKE & KEY WILDE", credits font Fe5 has the glyph) and
in the lobby `netui*` mnemonics.

## 6. Drawing and fonts (V unless marked)

`DrawGTAText(wchar_t* str, SCR_f x, SCR_f y, short fontId, SCR_f scale, PALETTE_BASE* pal, int
remap, int invisibility, byte alpha)`, stdcall, `RET 0x24`. x/y/scale are Fix16 (0x4000 = 1.0),
in 640×480 virtual units. Per unit: LF/space/`#` as in §5, otherwise sprite id
`StyleData_GetFontGlyphSpriteId(font, code − 0x21)` = `fontBases[font] + code − 0x21`
(`SPRITE_TYPE_FONT`), texture via `TextureCache_GetSpriteTexture(…, pal, remap)`, quad of sprite w×h × scale
through `gbh_DrawQuad`; advance = sprite width × scale. **No bounds check, no kerning, no
clipping, no alignment**: callers centre with `(0x280 − GetGTATextWidth) / 2` (`Text_GetCenteredX`
0x4521B0). Space width = width of glyph `n` (`StyleData_GetFontSpaceWidth` 0x4BF5D0), line height
= height of glyph `A` (`StyleData_GetFontLineHeight` 0x4BF630). `invisibility` 0/1/2 and `alpha`
go to `Text_GetQuadFlags` 0x4CB050 (0 = opaque; 1, 2 = blended with vertex colour
`alpha << 27 | 0xFFFFFF`, H on the exact blend). The K menu (`host/c/menu/core.c` `dm_text_at`) calls it with (…, 0, 0): correct.

Wrappers: `Hud_DrawScaledText` 0x4C7280 (× UI scale), `Hud_DrawScaledTextPlain` 0x4BA2C0,
`Frontend_DrawText` 0x4539F0, `Frontend_DrawTextInCells` 0x4566C0 (name entry, one char per cell).

**Font ids** are indices into the `.sty` FONB (counts prefix-summed by `StyleChunk_FONB`
0x4BFDD0); `StyleData_SetFontRoles` 0x4BFCC0 stores them in role globals, `Font_AssignRolesByLocale`
0x4CA520 (was `relToLang`) copies them into HUD slots (Japanese: the kanji fonts).

| Font (in-game wil/ste/bil.sty) | Role global | Glyphs | h | Use | Real glyphs |
|---|---|---|---|---|---|
| 0 | `g_FontRole_G0_Fe0` 0x670678 | 144 | 64 | big label (slot 0x672F2C) | upper case, digits, 80–96, AD, AF–B0; no lower case except `n` |
| 1 | `g_FontRole_G1` 0x670668 | 144 | 25 | **`DefaultFontId` 0x672F24**, briefs, pickups | full: upper + lower + 80–B0 (blank: `# & + < = > @ [ \ ] ^ _ { \| }`) |
| 2 | `g_FontRole_G2` 0x670640 | 144 | 30 | car name (0x672F28) | upper case only |
| 3, 4 | `g_FontRole_Kanji16/32` 0x67065C / 0x670650 | 1 | 17/34 | Japanese only | placeholder, glyphs come from `kanji.dat` |
| 5 | `g_FontRole_G5` 0x670674 | 145 | 32 | zone name (0x672F30) | upper case only (+0xB1) |
| 6 | `g_FontRole_G6_Fe3` 0x670654 | 144 | 42 | pause title (0x672F20) | upper case only |
| frontend fstyle.sty 0–13 | `g_FontRole_Fe0 … Fe13` | 140 (Fe0, Fe3) / 144 | 14–65 | menus (Fe4, Fe8, Fe11, Fe13), credits (Fe5), stats (Fe10) | Fe0/Fe3 full 21–AC; others like G6 |

(Role purposes come from xrefs: H for Fe5–Fe13. Glyph counts, heights and which slots are real vs
2-px blank placeholders: V from the `.sty` sprite widths.)

Out-of-range codes (< 0x21 or > 0x21 + count − 1) read the previous/next font's sprites, or past
the last font into the next sprite category: **this is the hard limit on new characters**.

Japanese path: if `fontId` is Kanji16/Kanji32, `KanjiFont_UploadGlyphSmall/Large`
(0x460CC0/0x460D30) look up the unit (a unit < 0x100 is shifted to the high byte) in the KIDX
table, `0xFFFF` → fallback `table[0x2100]`, upload a 16×17 / 32×34 bitmap per character; fixed
advance 16/32. `#` switches the `KanjiFont` colour bytes.

**`KanjiFont` in detail** (struct pass 4, 2026-10-25; V = code read, nothing seen at runtime).
`KanjiFont` is 0x28 B (`operator_new(0x28)` at 0x45D2BC, ctor `KanjiFont_Ctor` 0x460FB0, dtor
`KanjiFont_ScalarDeletingDtor` 0x45AC90 → `KanjiFont_FreeTables`):

| off | field | meaning |
|---|---|---|
| 0x00 / 0x04 | `kidxTable` (ushort*) / `kbitTable` (byte*) | `KIDX` chunk (`new ushort[size/2]`) / `KBIT` chunk (raw glyph bitmaps), `KanjiFont_ReadChunk`; other chunk tags are skipped |
| 0x08 | `kidxCount` | `size/2`; only a "loaded" marker, never a bound |
| 0x0C / 0x10 / 0x14 | `smallPixels` / `smallSprite` / `smallTexture` | glyph 0 of font role `g_FontRole_Kanji16`: pixel buffer (`SpriteEntry.ptr`), `SpriteEntry*`, `GbhTexture*` |
| 0x18 / 0x1C / 0x20 | `largePixels` / `largeSprite` / `largeTexture` | same for `g_FontRole_Kanji32` |
| 0x24 / 0x25 | `fillColour` / `outlineColour` | palette indices in the FONT_REMAP bank |

- **File**: `data\kanji.dat` = `KANJ` + version 100, then chunks `tag[4] + u32 size` until EOF.
  A glyph is 16×16, 1 bpp, 32 B (2 B per row, MSB first). The 32-px font is the same bitmap
  **doubled 2×** (`KanjiFont_Expand1bppLarge` 0x460480: every set bit writes a 2×2 block), not a
  separate set.
- **Lookup** (`UploadGlyphSmall/Large` 0x460CC0 / 0x460D30, per character from `DrawGTAText`):
  `code` = the wchar, shifted into the high byte if `< 0x100` (ASCII 'A' → index 0x4100);
  `idx = kidxTable[code]`; `0xFFFF` → `kidxTable[0x2100]`; bitmap = `kbitTable + idx*0x20`. Then
  `gbh_LockTexture`, `Expand1bpp*` writes fill-colour pixels (stride 0x100) into the font sprite's
  pixel buffer, `KanjiFont_OutlineGlyphBitmap` 0x460030 paints `outlineColour` on the 4-neighbours of
  every fill pixel, `gbh_UnlockTexture`; `DrawGTAText` draws a quad (16×17 or 32×34 from the glyph-0
  `SpriteEntry`).
- **Texture source**: `KanjiFont_BindFontSprites` 0x460DE0 (from `LoadGMP_and_STY_Files` 0x45B5E0
  after every `.sty` load when `g_KanjiFont != NULL`) takes glyph 0 of the two font roles and the
  texture from `TextureCache_GetSpriteTexture(FONT_REMAP 8, remap 8)`. So the kanji texture is a
  **re-used font sprite slot**: a host renderer must treat it as rewritten between Lock/Unlock **once
  per drawn character** (8-bit indices, 0 = transparent).
- **Colours**: ctor 0xFE/0xF7 (replaced at once); `KanjiFont_SetDefaultColors` 0x4CBA40 → fill 0xFF /
  outline 0xF1; `KanjiFont_SetRemapColors` 0x460DA0: remap 0 → 0x88/0x83, 5 → 0x27/0x23, 6 →
  0x47/0x43, **any other remap leaves the previous pair**. `DrawGTAText` calls Default when the
  caller's palette base is not 8, Remap(remap) when it is 8, and again at each `#`.
- A host font replacement must keep: the Lock/write/Unlock contract, the 16×17 / 32×34 geometry,
  those palette indices, the fixed 16/32 advance. Alternative: hook `KanjiFont_UploadGlyph*` and
  draw into the texture yourself.

Hazards (V by code read, not run):
1. **No bounds check on the KIDX lookup**: index is `code & 0xFFFF`, the buffer has `kidxCount`
   entries, and the fallback reads `kidxTable[0x2100]`. A `kanji.dat` with a KIDX smaller than
   0x20000 B (or < 0x2101 entries) reads past the heap block; `idx*0x20` is not checked against the
   KBIT size either. Own files only: ship a full 0x10000-entry KIDX.
2. **Stale bottom outline row** (hypothesis, medium confidence): `Expand1bppSmall` writes rows 0–15,
   the outline pass covers 17 rows and paints row 16, and nothing clears row 16 (Large: rows 32–33 of
   34). If the host does not clear the texture on `gbh_LockTexture`, a previous glyph's pixels stay
   under a glyph with a blank bottom row (faint wrong outline fragments).
3. An odd KIDX chunk size allocates `(size>>1)*2` but reads `size` bytes: 1-byte heap overflow.
4. `KanjiFont_LoadKanjiDat` does not check that `kanji.dat` exists (the `File_Open` failure path was
   not traced); `kanji.dat` is not in `data.pak`.
Unknown: the meaning of KIDX codes (Shift-JIS vs own mapping; no real file to test), and whether
callers can pass remaps other than 0/5/6.

## 7. HUD text widgets and limits (V unless marked)

`g_HudManager` (11 000 B, `HudManager_Ctor` 0x4CAC60):

| Widget | Offset | Buffer | Other | Copy |
|---|---|---|---|---|
| car name | +0x000 | 33 wchar | 120 frames, font G2, upper-cased | `wcscpy`, unbounded |
| zone name | +0x04C | 65 wchar | 90 frames, font G5, upper-cased | unbounded |
| **brief queue** `HudBriefQueue` | +0x0E4 | text 640 wchar (after wrap) | 20 `HudBriefNode`s `{char key[8]; int priority; next; u8 started; int arg}`; wrap 576 px (`g_BriefWrapWidth` 0x595004); font slot 0x672F3C (G1) | `swprintf` / `Text_WordWrap`, unbounded |
| debug labels | +0x818 | 29 × 82 wchar | wrap 640 px | |
| pickup text | +0x27B8 | 65 wchar | 90 frames | unbounded |
| big label `HudBigLabel` | +0x2854 | source 100 wchar, wrapped 121 | 90 frames, wrap 580 px, centred, y = (480 − h) / 4, font G0, upper-cased | `wcscpy`, unbounded |
| kill feed | +0x2A20 | 101 wchar | 120 frames | |
| `text_speed` | +0x2AF4 | registry `text_speed`, default 3 | | |

Brief queue (`Hud_Brief_Enqueue` 0x4C6690, was `showMessageToPlayer`): the key is `strcpy`'d into
the node; priority 3 or a higher priority pre-empts the head; when all 20 nodes are used the
oldest pending/lowest node is reused silently (`Hud_Brief_AllocNode` 0x4C6380). On show
(`Hud_Brief_StartHead` 0x4C6640) the text is looked up, formatted if the node has an argument,
the speaker marker stripped, wrapped, and shown for **`text_speed × wcslen(wrapped)` frames at 30
per second** (default 0.1 s per character). Finished briefs can be recalled (`Hud_Brief_RecallPending`
0x4C6830, H on the key). Briefs are bottom-anchored (`y = 480 − lineHeight × lines`, H): very
long briefs run off the top.

| Limit | Value | Evidence |
|---|---|---|
| key length | 7 ASCII bytes + NUL | `Gxt_CompareKeys` 0x4C20E0, brief node `char key[8]` |
| number of keys, TDAT size | no fixed limit (u32) | 0x4C2060, 0x4C2150 |
| brief text after wrap | **640 wchar**, no bounds check | `HudBriefQueue`, 0x4C6470 |
| brief duration | `text_speed × length` ≤ 32 767 frames (i16 timer) | 0x4C6640 |
| big label | **99 wchar** source, 120 after wrap, no bounds check | 0x4C6060, 0x4C5FE0 |
| zone / pickup name | 64 wchar, no bounds check | 0x4C6AF0, 0x4C69F0 |
| car name | 32 wchar, no bounds check | 0x4C6960 |
| kill-feed line | 100 wchar | 0x4C6A80 |
| frontend menu label | 50 wchar (truncated, safe) | `MainMenu` 0x453E20 |
| lobby (ANSI) | 79 chars, non-ASCII → `#` | 0x4C2280 |
| credits entry | 49 wchar per entry (108-B records); "600 lines / 50 chars" exists only as error strings (H: not enforced) | `Credits_ParseText` 0x449D70 |
| `swprintf` target `wcharBuf` 0x5E9F08 | ≥ 0x500 B, real size unknown (H) | |

Shipped maxima for comparison: longest ordinary string 259 units (f.gxt `2272`), `credits`
9 774–10 378 units.

## 8. Function table

| Address | Name | Role | |
|---|---|---|---|
| 0x4C2540 | `LoadGXT` | path + magic, jumps into the 11.44 patch | V |
| 0x56DF08 | `Patch1144_LoadGXT_MmpOverrides` | multiplayer `.mmp` GXTFile/GCIFile | V |
| 0x3F1664 | `Patch1144_LoadGXT_ClearFlagAndContinue` | flag = 0, back to the loader | V |
| 0x4C257F | `Gxt_LoadFromFile` | header, chunk loop, pointer fix-up | V |
| 0x4C2330 | `LocaleSettings_ReadGxtChunk` | TKEY/TDAT dispatch, skip others | V |
| 0x4C2060 | `GxtChunk_TKEY` | key table | V |
| 0x4C2150 | `GxtChunk_TDAT` | text block, 32-bit length | V |
| 0x4C20B0 | `Gxt_ResolveKeyPointers` | offset → pointer | V |
| 0x4C2620 | `LocaleSettings_Ctor` | registry `language` | V |
| 0x4C26C0 / 0x405A80 | `LocaleSettings_Dtor` / `LocaleSettings_ScalarDeletingDtor` | free | V |
| 0x4C23F0 / 0x4C2420 | `Gxt_ClearKeyTable` / `LocaleSettings_ClearText` | ctor helpers | V |
| 0x4C2400 / 0x4C2430 | `LocaleSettings_FreeKeyTable` / `LocaleSettings_FreeTextBlock` | dtor helpers | V |
| 0x451800 | `Gxt_AreAllFilesMissing` | start-up probe (was `CheckIFGXTexists`, inverted) | V |
| 0x452E60 | `LocaleSettings_IsJapanese` | `language == 'j'` | V |
| 0x460F10 / 0x460FB0 / 0x45FF70 | `KanjiFont_LoadKanjiDat` / `KanjiFont_Ctor` / `KanjiFont_ReadChunk` | `kanji.dat` | V |
| 0x4C2120 / 0x4C23A0 | `Gxt_FindTextW` / `Gxt_FindTextW_thunk` | bsearch lookup, `L" "` fallback | V |
| 0x4C20E0 | `Gxt_CompareKeys` | strcmp comparator | V |
| 0x4C23B0 / 0x4C2280 | `Gxt_FindTextAnsi` / `Gxt_WideToAnsiStatic` | lobby ANSI path | V |
| 0x462BE0 | `Zone_GetDisplayName` | 3-char zone name → key | V |
| 0x4065F0 … 0x408840 | `NetDlg_*` (8) | lobby dialog texts | V |
| 0x4C21A0 / 0x4C2250 | `LocaleSettings_ToUpperChar` / `LocaleSettings_ToUpperString` | per-language upper case | V |
| 0x4C2450 | `Text_WordWrap` | `int(dst, src, maxWidth, font)`, inserts LF, returns lines | V |
| 0x4CC0C0 / 0x4521B0 | `Text_GetMultilineHeight` / `Text_GetCenteredX` | layout helpers | V |
| 0x4CC100 | `DrawGTAText` | glyph loop | V |
| 0x4CB0C0 | `GetGTATextWidth` | widest line, unscaled | V |
| 0x4CB050 | `Text_GetQuadFlags` | quad flags from invisibility/alpha | V (flag meaning H) |
| 0x4BF550 / 0x4BF570 / 0x4BF5D0 / 0x4BF630 | `StyleData_GetFontGlyphSpriteId` / `…GlyphWidth` / `…SpaceWidth` / `…LineHeight` | font metrics | V |
| 0x4BFCC0 / 0x4BFDD0 | `StyleData_SetFontRoles` / `StyleChunk_FONB` | font ids | V |
| 0x4CA520 | `Font_AssignRolesByLocale` (was `relToLang`) | HUD font slots, Japanese switch | V |
| 0x4C7280 / 0x4BA2C0 / 0x4539F0 / 0x4566C0 | `Hud_DrawScaledText` / `Hud_DrawScaledTextPlain` / `Frontend_DrawText` / `Frontend_DrawTextInCells` | draw wrappers | V |
| 0x460CC0 / 0x460D30 / 0x460DA0 / 0x4CBA40 / 0x460DE0 | `KanjiFont_UploadGlyphSmall/Large`, `KanjiFont_SetRemapColors/SetDefaultColors`, `KanjiFont_BindFontSprites` | Japanese glyphs | V shape, H details |
| 0x4C6690 / 0x4C6750 | `Hud_Brief_Enqueue` (was `showMessageToPlayer`) / `Hud_Brief_EnqueueNoArg` | brief queue | V |
| 0x4C6380 / 0x4C6640 / 0x4C6770 / 0x4C68E0 / 0x4C6860 | `Hud_Brief_AllocNode` / `StartHead` / `Tick` / `Ctor` / `ClearAllBriefsWithPriority` | brief queue | V |
| 0x4C6470 / 0x4C63F0 | `Hud_Brief_PrepareCurrentText` / `Hud_Brief_SpeakerIconFromChar` | lookup, format, marker, wrap | V |
| 0x4C6830 | `Hud_Brief_RecallPending` | re-show a finished brief | H |
| 0x4C6060 / 0x4C5FE0 / 0x4C60B0 / 0x4C60C0 | `ShowBigOnScreenLabel` / `Hud_BigLabel_Layout` / `_Tick` / `_Ctor` | big label | V |
| 0x4C6960… / 0x4C6AF0… / 0x4C69F0… / 0x4C6A80… | `Hud_CarName_*`, `Hud_ZoneName_*`, `Hud_Pickup_*`, `Hud_KillFeed_*` | HUD labels | V |
| 0x4C9750 / 0x4C8AA0 / 0x4CABE0 | `Hud_KillFeed_ShowMpKill` / `Hud_DebugLabel_Init` / `Hud_RelayoutAllText` | | V |
| 0x449D70 / 0x449D30 | `Credits_ParseText` / `Credits_NextChar` | credits grammar | V |

Globals: `g_LocaleSettings` 0x671550, `g_NetDialogLocaleSettings` 0x5D31D8, `strPathToGXT`
0x676CD8, `g_gxtAllFilesMissing` 0x5EAD73, `g_GxtAnsiBuffer` 0x671880 (80 B), `g_KanjiFont`
0x661E98, `g_UpperCaseTable_GIS` 0x594DF8, `g_UpperCaseTable_F` 0x594EF8, `g_BriefWrapWidth`
0x595004 (576), `g_BriefDebugTextBuf` 0x5E9A08, `g_showBriefNumber` 0x5EADA5, `DefaultFontId`
0x672F24, font role globals 0x670640–0x670680. Types: `LocaleSettings`, `LocaleSingle`,
`HudBriefNode`, `HudBriefQueue` (applied at `HudManager.briefQueue` +0xE4), `HudBigLabel` (created,
not yet applied: needs a Structure Editor Clear of HudManager +0x2854..+0x2A1B).

## 9. How to safely change text

1. Edit with the CLI: `gxt data/e.gxt --export --out formats-out/e.txt` (one `key<TAB>text` line
   per key, accents as letters, `\uXXXX` for raw units), edit, then `gxt data/e.gxt --import
   formats-out/e.txt --out <overlay>/data/e.gxt`. The import file may hold every key or only the
   changed ones; unchanged keys keep their bytes (an unedited export imports byte-identically) and
   the checks below run on every edited line (errors stop the write unless `--force`). Verified in
   the game 2026-10-21: an imported `e.gxt` in the overlay changed the main-menu labels (`play`,
   `options` with Ö Ä Ü É) and loaded the level normally. In code: `gxt-edit.ts` `applyEdits`, or
   `buildGxt(lang, {key: text})` for a table from scratch (not run in the game). Never hand-edit offsets.
2. Keys: ≤ 7 ASCII bytes, unique, table sorted by unsigned bytes (`"7235" < "801" < "B01" < "c00"`).
   Script text ids are decimal strings; zone names are the 3-char `.gmp` names. Keep every key the
   game asks for (§3), or that text goes blank.
3. Characters: ASCII 0x21–0x7E plus the accent block 0x80–0xB0 only, and only those the target
   font really has: HUD fonts other than font 1 are upper case only (the game upper-cases big
   labels, car and zone names for you). No LF needed: the game wraps. `#…#` highlights.
4. Keep the leading speaker marker of each numeric (brief) string, or the brief gets the default
   icon. Keep `%d`/`%s` count and order in the printf keys (`pscore pgmiss pmiss psec pbon comms1
   nspraya bdone cdone sdone mpkill*`); a stray `%` there can crash, elsewhere it is literal.
5. Length: briefs ≤ ~640 units after wrapping (also: 0.1 s per character on screen), big labels
   ≤ 99, zone and pickup names ≤ 64, car names ≤ 32 — these copies have no bounds checks and
   overwrite the neighbouring HUD fields. Menu labels are cut at 50.
6. New characters (Cyrillic, Polish, …) need font work, and a new language letter needs code
   patches. Options, fonts to draw and drawing rules: [fonts-localization.md](fonts-localization.md).
   Replacing an existing language's file needs none.
7. Edited files go into the overlay (`~/Library/Application Support/gta2-resurrected/data/`), never
   into `data.pak`; they are picked up at the next frontend or level start.

## 10. Open questions

- ~~Readers of `LocaleSettings.textLength` (+0xC)~~: none (V, scan of all 141 `g_LocaleSettings` loads, Seq 27 R1).
- ~~Real size of `wcharBuf` 0x5E9F08; brief anchor and clipping~~: 640 wchar (bounded by `fileNameBuffer` 0x5EA408);
  `Hud_Brief_Draw` 0x4C9430 draws at x 64, bottom-anchored (y = 480 - lineHeight x lines), wrap width 576, no clipping
  (V, Seq 27 R1; [fonts-localization.md](fonts-localization.md) "RE status").
- Purpose of speaker icons 6–9 (0x216B, 0x216D, 0x216E, 0x2170) — gang assignment H.
- ~~Font roles Fe5–Fe13, `DefaultFontId` in the frontend~~: Fe4 = frontend default (`defaultFontId` +0x11C, name entry,
  credits), Fe5 selected item / credits, Fe7 / Fe9 / Fe10 menu page and stats, Fe8 / Fe11 / Fe13 `FrontEnd_InitPages`,
  Fe6 and Fe12 never read; the frontend never reads `DefaultFontId` 0x672F24 (V, Seq 27 R1).
- `FrontEnd_DrawBonusRatingText` (bonus-rating text, `Script_Op_SET_BONUS_RATING_TEXT_ID`) and `FrontEnd_DrawKeyHint`
  (key-help labels) have no direct callers: dead or indirect.
- Why 2066 of 2184 numeric keys are not referenced by the display opcodes of the shipped scripts
  (other opcodes, or unused/placeholder briefs such as `3001…` "REPORT DEAD BRIEF").
- `Player_GetDeathLocaleKey` 0x4A4E10 can return NULL and both callers pass it unchecked.
- `buildGxt` (a table from scratch) has not been loaded by the game; `--import` over the original has.
- Zone names that are not 3 characters (`training_mission` in wil.gmp) bypass the GXT: shown raw from the `.gmp`, upper-cased, `_` drawn as the font's blank glyph.
