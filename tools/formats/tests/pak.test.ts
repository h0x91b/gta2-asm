import { expect, test } from 'bun:test';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openPak } from '../pak.ts';
import { hasPak, pak } from './helpers.ts';
/** Minimal zip writer: Stored entries, optional per-entry method override. */
function zip(files: { name: string; data: Uint8Array; method?: number }[]) {
  const parts: Buffer[] = [], central: Buffer[] = []; let offset = 0;
  for (const f of files) {
    const name = Buffer.from(f.name), extra = Buffer.from([0xaa, 0xbb, 0, 0]), lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(f.method ?? 0, 8); lh.writeUInt32LE(f.data.length, 18); lh.writeUInt32LE(f.data.length, 22); lh.writeUInt16LE(name.length, 26); lh.writeUInt16LE(extra.length, 28);
    const ch = Buffer.alloc(46); ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(f.method ?? 0, 10); ch.writeUInt32LE(f.data.length, 20); ch.writeUInt32LE(f.data.length, 24); ch.writeUInt16LE(name.length, 28); ch.writeUInt32LE(offset, 42);
    parts.push(lh, name, extra, Buffer.from(f.data)); central.push(ch, name); offset += 30 + name.length + extra.length + f.data.length;
  }
  const cd = Buffer.concat(central), eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0); eocd.writeUInt16LE(files.length, 8); eocd.writeUInt16LE(files.length, 10); eocd.writeUInt32LE(cd.length, 12); eocd.writeUInt32LE(offset, 16);
  const path = join(mkdtempSync(join(tmpdir(), 'pak-test-')), 'test.pak'); writeFileSync(path, Buffer.concat([...parts, cd, eocd])); return path;
}
test('Stored entries resolve case-insensitively with either separator, past the local extra field', () => {
  const p = openPak(zip([{ name: 'data/', data: new Uint8Array() }, { name: 'data/Wil.STY', data: new Uint8Array([1, 2, 3]) }]));
  expect([...p.read('DATA\\WIL.sty')]).toEqual([1, 2, 3]); expect([...p.read('/data/wil.sty')]).toEqual([1, 2, 3]);
  expect(p.entries.find(e => e.name === 'data')?.dir).toBe(true); expect(() => p.read('data')).toThrow('no file'); expect(() => p.read('data/ste.sty')).toThrow('no file');
  p.close();
});
test('compressed entries and non-zip files are refused', () => {
  expect(() => openPak(zip([{ name: 'a.txt', data: new Uint8Array([1]), method: 8 }]))).toThrow('not Stored');
  const path = zip([]); writeFileSync(path, new Uint8Array(100)); expect(() => openPak(path)).toThrow('End of Central Directory');
});
test.skipIf(!hasPak)('data.pak indexes the game and serves gta2.ebin as a PE image', () => {
  const exe = pak().read('GTA2.EBIN'); expect(exe.length).toBe(1740800); expect(String.fromCharCode(exe[0]!, exe[1]!)).toBe('MZ');
  expect(new TextDecoder().decode(pak().read('data/wil.sty').subarray(0, 4))).toBe('GBST');
});
