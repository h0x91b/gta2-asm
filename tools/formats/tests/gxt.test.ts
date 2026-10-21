import { expect, test } from 'bun:test';
import { hasPak, pak } from './helpers.ts';
import { decodeGxt, encodeGxt, buildGxt, compareKeys, escapeText, toUnicode, fromUnicode } from '../gxt.ts';

test('buildGxt: sorted keys, TKEY then TDAT, decode round-trips', () => {
  const b = buildGxt('e', { zeta: 'Z', '1001': 'Hello', alpha: 'Aé⅓' });
  const g = decodeGxt(b);
  expect([g.lang, g.version, g.chunks.map(c => c.tag)]).toEqual(['E', 100, ['TKEY', 'TDAT']]);
  expect(g.entries.map(e => [e.key, e.text])).toEqual([['1001', 'Hello'], ['alpha', 'Aé⅓'], ['zeta', 'Z']]);
  expect(g.entries.map(e => e.offset)).toEqual([0, 12, 20]);
  expect(g.issues).toEqual([]);
  expect(encodeGxt(g)).toEqual(b);
});

test('unknown chunks and padding survive; repack re-lays TDAT after an edit', () => {
  const g = decodeGxt(buildGxt('f', { a: 'x', b: 'yy' }));
  g.chunks.push({ tag: 'XTRA', data: Uint8Array.of(1, 2, 3) });
  expect(decodeGxt(encodeGxt(g)).chunks.map(c => c.tag)).toEqual(['TKEY', 'TDAT', 'XTRA']);
  expect(decodeGxt(encodeGxt(g)).issues).toEqual(['unknown chunks: XTRA']);
  g.entries[0]!.raw = Uint16Array.from([65, 66, 67]);
  const r = decodeGxt(encodeGxt(g, { repack: true }));
  expect(r.entries.map(e => [e.key, e.text, e.offset])).toEqual([['a', 'ABC', 0], ['b', 'yy', 8]]);
});

test('validation reports unsorted, duplicate, shared, gap and odd-size problems', () => {
  const g = decodeGxt(buildGxt('e', { a: 'x', b: 'y' }));
  g.entries.reverse();
  g.entries[1]!.offset = g.entries[0]!.offset;                      // two keys share a string
  g.tdat = Uint16Array.of(...g.tdat, 7, 0);                         // unreferenced tail
  const issues = decodeGxt(encodeGxt(g)).issues.join('|');
  expect(issues).toContain('keys unsorted'); expect(issues).toContain('text shared'); expect(issues).toContain('unreferenced TDAT');
  const dup = decodeGxt(buildGxt('e', { a: 'x', b: 'y' })); dup.entries[1]!.keyBytes = dup.entries[0]!.keyBytes.slice();
  expect(decodeGxt(encodeGxt(dup)).issues.join()).toContain('duplicate key');
});

test('bad inputs are refused', () => {
  expect(() => decodeGxt(new Uint8Array(4))).toThrow('GBL');
  const b = buildGxt('e', { a: 'x' });
  expect(() => decodeGxt(b.subarray(0, b.length - 1))).toThrow('truncated');
  expect(() => buildGxt('e', { toolongkey: 'x' })).toThrow('bad key');
  expect(() => buildGxt('e', { a: 'x\0y' })).toThrow('U+0000');
});

test('key order is unsigned byte order; escapeText makes control units visible', () => {
  const k = (s: string) => { const b = new Uint8Array(8); b.set(new TextEncoder().encode(s)); return b; };
  expect(compareKeys(k('1001'), k('car0'))).toBeLessThan(0);
  expect(compareKeys(k('ab'), k('abc'))).toBeLessThan(0);
  expect(escapeText('a\\b\x01⅓')).toBe('a\\\\b\\x01\\u2153');
});

test('font code page: accents map both ways, unknown characters are refused', () => {
  const u = fromUnicode('\u217aFür ¿Sí? Ñ');
  expect(Array.from(u.subarray(0, 3))).toEqual([0x217a, 0x46, 0xac]);
  expect(u[5]).toBe(0xaf); expect(u[7]).toBe(0xa2); expect(u[u.length - 1]).toBe(0xad);
  expect(toUnicode(u)).toBe('\u217aFür ¿Sí? Ñ');
  expect(toUnicode([0x84, 0x96, 0x9b, 0xb0])).toBe('Æßæ¡');
  expect(() => fromUnicode('Ã')).toThrow('no font glyph');
  expect(() => fromUnicode('a\u217a')).toThrow('no font glyph');
});

test.skipIf(!hasPak)('every .gxt in the pak decodes cleanly and re-encodes byte-identically', () => {
  const files = pak().entries.filter(e => !e.dir && /\.gxt$/i.test(e.name));
  expect(files.length).toBeGreaterThan(0);
  for (const f of files) {
    const bytes = pak().read(f.name), g = decodeGxt(bytes);
    expect([f.name, g.issues]).toEqual([f.name, []]);
    expect(Buffer.compare(encodeGxt(g), bytes)).toBe(0);
    // repack of a faithful file must still decode to the same texts
    const r = decodeGxt(encodeGxt(g, { repack: true }));
    expect(r.entries.map(e => [e.key, e.text])).toEqual(g.entries.map(e => [e.key, e.text]));
  }
});
