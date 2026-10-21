/** Mission script `.scr`, as loaded by MissionScript_Load (0x47F280) and
 * MissionScript_LoadSubScripts (0x476070). Layout and VM: docs/re/script-engine.md.
 *
 * main (82656 bytes): u16 ptr[6000] | code[65536] | u16 stringBytes | strings[5118]
 * sub:  u16 first | u16 start | u32 size | u16 ptr[1536] | code[size]
 * A pointer value is a byte offset into the code space shared by the main script and its
 * sub-scripts; a sub-script's local entry j is global pointer index first + j, and its code
 * starts at the smallest non-zero pointer. Every command begins with SCR_CMD_HEADER
 * {u16 cmd_this, u16 type, u16 cmd_next, u16 return_value}.
 */
import { SCR_OPCODES } from './scr-opcodes.ts';

export const MAIN_SCR_SIZE = 12000 + 65536 + 2 + 5118;
export const STRING_TYPE_MISSION_FILE = 21;

export type ScrCommand = { index: number; offset: number; type: number; name: string; next: number | null; returnValue: number; args: Uint8Array };
export type ScrString = { id: number; type: number; text: string };
export type Scr = { kind: 'main' | 'sub'; first: number; start: number | null; codeOrigin: number; commands: ScrCommand[]; strings: ScrString[] };

export const opcodeName = (type: number) => SCR_OPCODES[type] ?? `OP_${type}`;

export function parseScr(bytes: Uint8Array): Scr {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let kind: Scr['kind'], first = 0, start: number | null = null, pointers: number[], code: Uint8Array, codeOrigin = 0, strings: ScrString[] = [];
  if (bytes.length === MAIN_SCR_SIZE) {
    kind = 'main';
    pointers = Array.from({ length: 6000 }, (_, i) => v.getUint16(i * 2, true));
    code = bytes.subarray(12000, 12000 + 65536);
    strings = parseStrings(bytes.subarray(12000 + 65536 + 2), v.getUint16(12000 + 65536, true));
  } else {
    if (bytes.length < 8 + 3072) throw Error(`not a .scr: ${bytes.length} bytes`);
    kind = 'sub'; first = v.getUint16(0, true); start = v.getUint16(2, true);
    const size = v.getUint32(4, true);
    if (8 + 3072 + size !== bytes.length) throw Error(`sub-script size field ${size} does not match file length ${bytes.length}`);
    pointers = Array.from({ length: 1536 }, (_, i) => v.getUint16(8 + i * 2, true));
    code = bytes.subarray(8 + 3072);
    codeOrigin = Math.min(...pointers.filter(p => p !== 0));
  }
  const used = pointers.map((p, i) => ({ i, p })).filter(e => e.p !== 0).sort((a, b) => a.p - b.p);
  const commands: ScrCommand[] = used.map(({ i, p }, k) => {
    const at = p - codeOrigin, end = k + 1 < used.length ? used[k + 1]!.p - codeOrigin : endOfCode(code, at);
    if (at < 0 || at + 8 > code.length) throw Error(`pointer ${first + i} -> ${p} is outside the code`);
    const c = new DataView(code.buffer, code.byteOffset + at, 8), next = c.getUint16(4, true), type = c.getUint16(2, true);
    return { index: first + i, offset: p, type, name: opcodeName(type), next: next === 0xffff ? null : next, returnValue: c.getUint16(6, true), args: code.subarray(at + 8, Math.max(at + 8, end)) };
  });
  commands.sort((a, b) => a.index - b.index);
  return { kind, first, start, codeOrigin, commands, strings };
}

// The last command has no successor to bound it: its arguments run to the end of the non-zero bytes.
function endOfCode(code: Uint8Array, at: number) { let e = code.length; while (e > at + 8 && code[e - 1] === 0) e--; return e; }

function parseStrings(area: Uint8Array, total: number): ScrString[] {
  const v = new DataView(area.buffer, area.byteOffset, area.byteLength), out: ScrString[] = [];
  for (let o = 0; o < total;) {
    if (o + 9 > area.length) throw Error('string table overruns the file');
    const len = v.getUint8(o + 8), raw = area.subarray(o + 9, o + 9 + len), nul = raw.indexOf(0);
    out.push({ id: v.getUint16(o, true), type: v.getUint32(o + 4, true), text: new TextDecoder('latin1').decode(nul < 0 ? raw : raw.subarray(0, nul)) });
    o += 9 + len;
  }
  return out;
}

export const hex = (b: Uint8Array) => Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
