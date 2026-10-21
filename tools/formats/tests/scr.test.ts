import { expect, test } from 'bun:test';
import { hasPak, pak } from './helpers.ts';
import { parseScr, MAIN_SCR_SIZE, STRING_TYPE_MISSION_FILE } from '../scr.ts';
import { SCR_OPCODES } from '../scr-opcodes.ts';

const cmd = (v: DataView, at: number, h: number[]) => h.forEach((x, i) => v.setUint16(at + i * 2, x, true));

test('opcode table covers the whole SCRCMD range', () => {
  expect(SCR_OPCODES.length).toBe(447);
  expect([SCR_OPCODES[59], SCR_OPCODES[60], SCR_OPCODES[272]]).toEqual(['LEVELSTART', 'LEVELEND', 'MISSIONSTART']);
});

test('synthetic main script: pointers, commands, arguments, strings', () => {
  const b = new Uint8Array(MAIN_SCR_SIZE), v = new DataView(b.buffer);
  v.setUint16(1 * 2, 8, true); v.setUint16(2 * 2, 20, true);            // ptr[1] = 8, ptr[2] = 20
  cmd(v, 12000 + 8, [1, 59, 2, 0]); v.setUint32(12000 + 16, 0xdeadbeef, true);
  cmd(v, 12000 + 20, [2, 60, 0xffff, 0]);
  const s = 12000 + 65536; v.setUint16(s, 9 + 4, true);
  v.setUint16(s + 2, 1, true); v.setUint32(s + 2 + 4, STRING_TYPE_MISSION_FILE, true); v.setUint8(s + 2 + 8, 4);
  b.set(new TextEncoder().encode('a.mi'), s + 2 + 9);
  const r = parseScr(b);
  expect(r.kind).toBe('main');
  expect(r.commands.map(c => [c.index, c.name, c.next])).toEqual([[1, 'LEVELSTART', 2], [2, 'LEVELEND', null]]);
  expect(Array.from(r.commands[0]!.args)).toEqual([0xef, 0xbe, 0xad, 0xde]);
  expect(r.strings).toEqual([{ id: 1, type: STRING_TYPE_MISSION_FILE, text: 'a.mi' }]);
});

test('synthetic sub-script: local entries map to first + j, offsets are absolute', () => {
  const code = 16, b = new Uint8Array(8 + 3072 + code), v = new DataView(b.buffer);
  v.setUint16(0, 100, true); v.setUint16(2, 101, true); v.setUint32(4, code, true);
  v.setUint16(8 + 1 * 2, 5000, true);                                     // local 1 = global 101 @5000
  cmd(v, 8 + 3072, [101, 272, 0xffff, 0]);
  const r = parseScr(b);
  expect([r.kind, r.first, r.start, r.codeOrigin]).toEqual(['sub', 100, 101, 5000]);
  expect(r.commands.map(c => [c.index, c.offset, c.name])).toEqual([[101, 5000, 'MISSIONSTART']]);
  expect(() => parseScr(b.subarray(0, b.length - 1))).toThrow('does not match');
});

test.skipIf(!hasPak)('every .scr in the pak parses and agrees with its own headers', () => {
  const files = pak().entries.filter(e => !e.dir && /\.scr$/i.test(e.name));
  expect(files.length).toBe(85);
  let mains = 0;
  for (const f of files) {
    const s = parseScr(pak().read(f.name));
    if (s.kind === 'main') mains++;
    // cmd_this of each command equals its pointer index
    const bytes = pak().read(f.name), base = s.kind === 'main' ? 12000 : 8 + 3072;
    for (const c of s.commands) expect(new DataView(bytes.buffer, bytes.byteOffset).getUint16(base + c.offset - s.codeOrigin, true)).toBe(c.index);
    if (s.kind === 'sub') expect(s.commands.find(c => c.index === s.start)?.name).toBe('MISSIONSTART');
  }
  expect(mains).toBe(18);
});

test.skipIf(!hasPak)('wil.scr names its sub-missions and starts with the player', () => {
  const s = parseScr(pak().read('data/wil.scr'));
  expect(s.commands[0]).toMatchObject({ index: 1, name: 'PLAYER_PED' });
  expect(s.commands.some(c => c.name === 'LEVELSTART')).toBe(true);
  expect(s.strings.filter(x => x.type === STRING_TYPE_MISSION_FILE).map(x => x.text)).toContain('wil_tra.mis');
});
