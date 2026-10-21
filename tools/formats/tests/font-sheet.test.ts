import { expect, test } from 'bun:test';
import { hasPak, pak } from './helpers.ts';
import { parseStyle } from '../style.ts';
import { fontSheet } from '../font-sheet.ts';

test.skipIf(!hasPak)('font sheet: one cell per glyph at code position, Cyrillic block with look-alikes', () => {
  const f = fontSheet(parseStyle(pak().read('data/wil.sty')), 1), m = f.manifest;
  expect([m.glyphs, m.firstCode, m.lastCode]).toEqual([144, 0x21, 0xb0]);
  const A = m.cells.find(c => c.code === 0x41)!, a2 = m.cells.find(c => c.code === 0x410)!, B = m.cells.find(c => c.code === 0x411)!;
  expect([A.char, A.kind, A.x]).toEqual(['A', 'glyph', 1 * (m.cellW + 1) + 1]);
  expect(m.cells.find(c => c.code === 0x9e)!.char).toBe('é');
  expect([a2.copiedFrom, a2.w]).toEqual(['A', A.w]); expect([B.kind, B.w, B.copiedFrom]).toEqual(['new', 0, undefined]);
  expect(m.cells.filter(c => c.kind === 'new').length).toBe(66);
  expect(f.rgba.length).toBe(f.width * f.height * 4);
});
