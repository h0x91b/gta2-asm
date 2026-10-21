import { expect, test } from 'bun:test';
import { hasPak, pak } from './helpers.ts';
import { decompile, decompileLevel, fix16 } from '../scr-mis.ts';
import { opcodeName, type Scr, type ScrCommand } from '../scr.ts';

const u8 = (...b: number[]) => Uint8Array.from(b);
const le16 = (v: number) => [v & 0xff, (v >> 8) & 0xff];
const cmd = (index: number, type: number, next: number | null, args: number[] = [], returnValue = 0): ScrCommand =>
  ({ index, offset: index * 16, type, name: opcodeName(type), next, returnValue, args: u8(...args) });
const main = (commands: ScrCommand[]): Scr => ({ kind: 'main', first: 0, start: null, codeOrigin: 0, commands, strings: [] });
const body = (text: string) => text.split('\n').filter(l => l && !l.startsWith('//')).map(l => l.trimEnd());

const COUNTER = 21, S_EQUAL_I = 94, INCREMENT = 96, NOT = 71, IF_JUMP = 98, GOTO = 77, DISPLAY_BRIEF = 118;
const jump = (isOr: number, target: number) => [isOr, 0, ...le16(target)];

test('fix16 prints DMA-style reals', () => {
  expect([fix16(0x4000), fix16(0x8000 + 0x2000), fix16(-0x4000), fix16(1638)]).toEqual(['1.0', '2.5', '-1.0', '0.1']);
});

// layout of bil_end.scr 1262..1271: cond -> IF_JUMP(after the construct) -> then; IF_JUMP target = else
test('IF / ELSE / ENDIF from the IF_JUMP graph', () => {
  const r = decompile(main([
    cmd(1, COUNTER, 2, [0, 0, 0, 0]),
    cmd(2, S_EQUAL_I, 5, [...le16(1), ...le16(3)]),
    cmd(3, DISPLAY_BRIEF, 7, le16(100)),
    cmd(4, DISPLAY_BRIEF, 7, le16(200)),
    cmd(5, IF_JUMP, 3, jump(0, 4)),
    cmd(7, INCREMENT, null, [...le16(1), 0, 0]),
  ]), []);
  expect(body(r.main)).toEqual(['COUNTER count1 = 0', 'IF ( count1 = 3 )', '\tDISPLAY_BRIEF (100)', 'ELSE', '\tDISPLAY_BRIEF (200)', 'ENDIF', '++count1']);
});

// layout of bil_end.scr 1181..1304: cond, NOT, IF_JUMP past the loop, body, GOTO back to the cond
test('WHILE_EXEC with NOT, and an AND / OR chain', () => {
  const r = decompile(main([
    cmd(1, COUNTER, 2, [0, 0, 0, 0]),
    cmd(2, S_EQUAL_I, 3, [...le16(1), ...le16(0)], 1),
    cmd(3, NOT, 8, [], 1),
    cmd(4, INCREMENT, 9, [...le16(1), 0, 0], 1),
    cmd(8, IF_JUMP, 4, jump(0, 10)),
    cmd(9, GOTO, 2, le16(8), 1),
    // ( count1 = 1 ) OR ( count1 = 2 ): an intermediate IF_JUMP sits right after the term it leads to
    // and jumps into the body when true; the final one follows the last term
    cmd(10, S_EQUAL_I, 12, [...le16(1), ...le16(1)]),
    cmd(11, S_EQUAL_I, 14, [...le16(1), ...le16(2)]),
    cmd(12, IF_JUMP, 11, jump(1, 13)),
    cmd(13, DISPLAY_BRIEF, 15, le16(7)),
    cmd(14, IF_JUMP, 13, jump(0, 15)),
    cmd(15, INCREMENT, null, [...le16(1), 0, 0]),
  ]), []);
  expect(body(r.main)).toEqual(['COUNTER count1 = 0', 'WHILE_EXEC ( NOT ( count1 = 0 ) )', '\t++count1', 'ENDWHILE',
    'IF ( ( count1 = 1 ) OR ( count1 = 2 ) )', '\tDISPLAY_BRIEF (7)', 'ENDIF', '++count1']);
});

test.skipIf(!hasPak)('every level decompiles with a template for every opcode', () => {
  const mains = pak().entries.filter(e => /^data\/[^/]+\.scr$/i.test(e.name));
  expect(mains.length).toBe(18);
  for (const m of mains) for (const f of decompileLevel(p => pak().read(p), m.name)) {
    // unknown opcodes and unstructured control flow are printed as `// NAME (type) hex` / `// stray` / `// GOTO ->`
    expect(f.text.split('\n').filter(l => /^\s*\/\/ /.test(l) && !l.startsWith('// decompiled')).map(l => `${f.name}: ${l.trim()}`)).toEqual([]);
  }
});

test.skipIf(!hasPak)('bil decompiles to the lines of DMA\'s own bil sources', () => {
  const files = Object.fromEntries(decompileLevel(p => pak().read(p), 'data/bil.scr').map(f => [f.name, f.text]));
  expect(Object.keys(files).length).toBe(23);
  expect(files['bil.mis']).toContain('SET_GANG_INFO (krisgang, 9, PISTOL, MOLOTOV, FLAME_THROWER, 6, 234.5, 193.5, 2.0, 1, KRSNABUS, -1)');
  expect(files['bil.mis']).toContain('MAP_ZONE B01 = (0, 0, 0, 0, 200, 0, 0, 0, 1000, 0, 200)');
  expect(files['bil_ke1.mis']).toMatch(/WHILE_EXEC \( NOT \( LOCATE_CHARACTER_ANY_MEANS \(\w+, 69\.0, 234\.0, 2\.0, 2\.0, 2\.0\) \) \)/);
  expect(files['bil_km1.mis']).toMatch(/\w+ = CREATE_LIGHT \(166\.0, 40\.0, 3\.0\) 7\.9 255 \(255, 0, 0\) 30 90 0/);
});
