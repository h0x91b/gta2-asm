import { expect, test } from 'bun:test';
import { hasPak, pak } from './helpers.ts';
import { buildGxt, decodeGxt } from '../gxt.ts';
import { exportText, parseText, applyEdits, escapeUnits, checkText } from '../gxt-edit.ts';

const base = () => decodeGxt(buildGxt('e', { b: 'ⅺHello #you#', a: 'Cost: $%d', car0: 'Romero', z: 'x\\y' }));

test('export -> import of an unchanged table is byte-identical', () => {
  const g = base(), bytes = buildGxt('e', { b: 'ⅺHello #you#', a: 'Cost: $%d', car0: 'Romero', z: 'x\\y' });
  const txt = exportText(g);
  expect(txt).toContain('b\t\\u217aHello #you#'); expect(txt).toContain('z\tx\\\\y');
  const { bytes: out, report } = applyEdits(g, parseText(txt));
  expect(report).toMatchObject({ changed: [], added: [], unchanged: 4, errors: [] });
  expect(Buffer.compare(out, bytes)).toBe(0);
});

test('a partial patch changes and adds keys, keeps the rest and the sort order', () => {
  const { bytes, report } = applyEdits(base(), parseText('; comment\n\nb\t\\u217aHallö Welt\nnew\tNeu ß\r\n'));
  expect(report.changed).toEqual(['b']); expect(report.added).toEqual(['new']); expect(report.errors).toEqual([]);
  const g = decodeGxt(bytes);
  expect(g.issues).toEqual([]);
  expect(g.entries.map(e => e.key)).toEqual(['a', 'b', 'car0', 'new', 'z']);
  expect(escapeUnits(g.entries[1]!.raw)).toBe('\\u217aHallö Welt');
  expect(Array.from(g.entries[3]!.raw.slice(-1))).toEqual([0x96]);   // ß = font code 0x96
  expect(g.entries[0]!.text).toBe('Cost: $%d');
});

test('checks: printf arguments, buffer limits, speaker marker, keys, glyphs', () => {
  const r = applyEdits(base(), parseText('a\tCost\ncar0\tAN EXTREMELY LONG CAR NAME, OVER 32\nb\tNo marker\nlongkey8\tx\n'));
  const all = [...r.report.errors, ...r.report.warnings].join('\n');
  expect(r.report.errors.length).toBe(3);
  expect(all).toContain('printf arguments %d must stay'); expect(all).toContain('car name'); expect(all).toContain('1..7 printable ASCII');
  expect(all).toContain('speaker marker \\u217a -> none');
  expect(() => parseText('a\tПривет')).toThrow('no font glyph');
  expect(() => parseText('a\tbad \\q')).toThrow('unknown escape');
  expect(() => parseText('a\tx\na\ty')).toThrow('already given');
  expect(checkText('c01', Uint16Array.of(0x41, 0x410)).warnings.join()).toContain('no glyph');
});

test.skipIf(!hasPak)('export -> import round-trips every shipped .gxt byte-identically', () => {
  for (const f of pak().entries.filter(e => !e.dir && /\.gxt$/i.test(e.name))) {
    const bytes = pak().read(f.name), g = decodeGxt(bytes), { bytes: out, report } = applyEdits(g, parseText(exportText(g)));
    expect([f.name, report.changed.length, report.errors]).toEqual([f.name, 0, []]);
    expect(Buffer.compare(out, bytes)).toBe(0);
  }
});
