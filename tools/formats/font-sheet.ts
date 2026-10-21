/** A font of a `.sty` as one editable PNG sheet + a JSON manifest, for drawing new glyphs.
 *
 * Top block: the shipped glyphs, 16 per row in code order starting at 0x20 (row 0x20, 0x30, …), so a
 * cell's column is the code's low nibble. Glyph code = sprite index + 0x21 (DrawGTAText 0x4CC100,
 * docs/re/gxt.md §6). Below it a block of empty cells for Cyrillic: А–Я, а–я (Unicode order), Ё, ё;
 * the letters that look like Latin ones are pre-filled with a copy of that Latin glyph.
 * Cells are 1 px apart on a magenta (shipped) / cyan (new) grid; pixels are the sprite's own palette
 * at 1:1, transparent where the sprite uses colour 0. Each glyph sits at its cell's top-left.
 */
import { decodeSprite, type Style } from './style.ts';
import { styleMetadata } from './style-metadata.ts';
import { FONT_ACCENTS, FONT_ACCENT_BASE } from './gxt.ts';

export type SheetCell = { code: number; char: string; x: number; y: number; w: number; h: number; kind: 'glyph' | 'blank' | 'new'; copiedFrom?: string };
export type FontSheet = { width: number; height: number; rgba: Uint8Array; manifest: { font: number; glyphs: number; firstCode: number; lastCode: number; cellW: number; cellH: number; colours: string[]; cells: SheetCell[] } };

const CYRILLIC = [...Array.from({ length: 64 }, (_, i) => 0x410 + i), 0x401, 0x451];
/** Cyrillic letter -> Latin glyph to start from (same shape in most pixel fonts). */
const LOOKALIKE: Record<string, string> = { А: 'A', В: 'B', Е: 'E', К: 'K', М: 'M', Н: 'H', О: 'O', Р: 'P', С: 'C', Т: 'T', Х: 'X', а: 'a', е: 'e', о: 'o', р: 'p', с: 'c', у: 'y', х: 'x', Ё: 'Ë', ё: 'ë' };
const fontChar = (code: number) => code >= FONT_ACCENT_BASE && code < FONT_ACCENT_BASE + FONT_ACCENTS.length ? FONT_ACCENTS[code - FONT_ACCENT_BASE]! : String.fromCharCode(code);
const fontCode = (ch: string) => { const a = FONT_ACCENTS.indexOf(ch); return a >= 0 ? FONT_ACCENT_BASE + a : ch.charCodeAt(0); };

export function fontSheet(style: Style, fontId: number): FontSheet {
  const font = styleMetadata(style).fonts[fontId];
  if (!font) throw Error(`no font ${fontId} (this style has ${styleMetadata(style).fonts.length})`);
  const glyphs = Array.from({ length: font.count }, (_, i) => decodeSprite(style, font.base + i));
  const cellW = Math.max(...glyphs.map(g => g.width)), cellH = Math.max(...glyphs.map(g => g.height));
  const firstCode = 0x21, lastCode = 0x21 + font.count - 1, shippedRows = (lastCode >> 4) - 1, newRows = Math.ceil(CYRILLIC.length / 16);
  const gap = 4, pitchX = cellW + 1, pitchY = cellH + 1;
  const width = 16 * pitchX + 1, topH = shippedRows * pitchY + 1, height = topH + gap + newRows * pitchY + 1;
  const rgba = new Uint8Array(width * height * 4);
  const grid = (y0: number, rows: number, c: [number, number, number]) => {
    for (let r = 0; r <= rows; r++) for (let x = 0; x < width; x++) rgba.set([...c, 255], ((y0 + r * pitchY) * width + x) * 4);
    for (let col = 0; col <= 16; col++) for (let y = y0; y <= y0 + rows * pitchY; y++) rgba.set([...c, 255], (y * width + col * pitchX) * 4);
  };
  grid(0, shippedRows, [255, 0, 255]); grid(topH + gap, newRows, [0, 200, 255]);
  const blit = (g: { width: number; height: number; rgba: Uint8Array }, x0: number, y0: number) => {
    for (let y = 0; y < g.height; y++) for (let x = 0; x < g.width; x++) { const p = (y * g.width + x) * 4; if (g.rgba[p + 3]) rgba.set(g.rgba.subarray(p, p + 4), ((y0 + y) * width + x0 + x) * 4); }
  };
  const cells: SheetCell[] = [], colours = new Set<string>();
  glyphs.forEach((g, i) => {
    const code = firstCode + i, x = (code & 15) * pitchX + 1, y = ((code >> 4) - 2) * pitchY + 1;
    blit(g, x, y);
    for (let p = 0; p < g.rgba.length; p += 4) if (g.rgba[p + 3]) colours.add(Array.from(g.rgba.subarray(p, p + 3), v => v.toString(16).padStart(2, '0')).join(''));
    cells.push({ code, char: fontChar(code), x, y, w: g.width, h: g.height, kind: g.width <= 2 ? 'blank' : 'glyph' });
  });
  CYRILLIC.forEach((u, i) => {
    const ch = String.fromCharCode(u), x = (i & 15) * pitchX + 1, y = topH + gap + (i >> 4) * pitchY + 1;
    const from = LOOKALIKE[ch], src = from !== undefined ? fontCode(from) - firstCode : -1, g = glyphs[src];
    const cell: SheetCell = { code: u, char: ch, x, y, w: 0, h: cellH, kind: 'new' };
    if (g && g.width > 2) { blit(g, x, y); cell.w = g.width; cell.copiedFrom = from; }
    cells.push(cell);
  });
  return { width, height, rgba, manifest: { font: fontId, glyphs: font.count, firstCode, lastCode, cellW, cellH, colours: [...colours].sort(), cells } };
}
