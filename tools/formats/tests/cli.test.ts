import { expect, test } from 'bun:test';
import { hasPak } from './helpers.ts';
const cli = (...args: string[]) => { const r = Bun.spawnSync(['bun', new URL('../cli.ts', import.meta.url).pathname, ...args]); return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() }; };
test('help lists every command', () => { const r = cli('help'); expect(r.code).toBe(0); for (const c of ['pak', 'sty', 'gmp', 'sdt', 'gci', 'tga']) expect(r.out).toContain(`  ${c} `); });
test.skipIf(!hasPak)('extracted data is never written to a tracked path inside the repo', () => {
  const r = cli('sty', 'data/wil.sty', '--tile', '0', '--out', new URL('../../../decoded-tile.png', import.meta.url).pathname);
  expect(r.code).toBe(1); expect(r.err).toContain('not git-ignored');
  expect(cli('sty', 'data/wil.sty', '--tile', '0').err).toContain('--out <path> is required');
});
test.skipIf(!hasPak)('gmp --block decodes the documented wil shop roof corner', () => {
  const r = JSON.parse(cli('gmp', 'DATA\\WIL.GMP', '--block', '40,135,3').out);
  expect(r.slope).toBe(49); expect(r.faces[0]).toMatchObject({ face: 'left', tile: 626 });
});
