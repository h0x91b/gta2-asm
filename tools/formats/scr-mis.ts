/** Decompile `.scr` mission scripts back to DMA's `.mis` language.
 *
 * Commands are rendered from per-opcode templates (scr-mis-ops.ts), and control flow (IF / ELSE /
 * WHILE / WHILE_EXEC, AND / OR / NOT) is rebuilt from the IF_JUMP / GOTO graph (block() below).
 * Variable names are not stored in a .scr: each declaration gets a generated name (`char12`).
 * Layout facts: docs/re/script-engine.md. Ground truth for the output: DMA's bil sources in
 * docs/formats/specs/scripting/example/.
 */
import { parseScr, STRING_TYPE_MISSION_FILE, type Scr, type ScrCommand } from './scr.ts';
import { OPS, BOOL_FNS } from './scr-mis-ops.ts';
import { ENUMS } from './scr-consts.ts';

/** Template mini-language, one string per opcode. `{kind@offset}` reads the command's argument
 * bytes (offset counts from the end of the 8-byte header); `{kind:arg@offset}` passes an argument.
 *   u8 s8 u16 s16 u32 s32  integers           f  fix16 (0x4000 = 1.0)     xy xyz  2 / 3 fix16
 *   rect   xyz then w,h (5 fix16)             bxyz  3 x u8                rgb  u8 b,g,r -> "r, g, b"
 *   var    u16 pointer index -> the name declared there (`{var:u32@o}` for a 4-byte slot)
 *   decl:P declares this command's variable with prefix P and prints its name (no offset)
 *   fn     u16 command index of a label -> its name              str  u16 string id -> its text
 *   label  this FUNCTION's own label    name  the string declared with this command's index (zones)
 *   model  u16 car model, 0xFFFF -> NONE           crane  u16 crane var, 0 -> NO_HOMECRANE
 *   e:NAME:W  enum lookup in ENUMS[NAME] of a W (u8|u16|s16|u32) value; unknown values print as numbers
 * A template starting with `?` is a boolean check: it may appear in IF / WHILE conditions.
 */
export type Template = string;

export const fix16 = (raw: number) => { const v = Math.round(raw / 16384 * 100) / 100; return Number.isInteger(v) ? v.toFixed(1) : String(v); };

type Ctx = { names: Map<number, string>; counters: Map<string, number>; strings: Map<number, string>; labels: Map<number, string> };

export function newContext(): Ctx { return { names: new Map(), counters: new Map(), strings: new Map(), labels: new Map() }; }

function declare(ctx: Ctx, index: number, prefix: string) {
  const have = ctx.names.get(index); if (have) return have;
  const named = ctx.strings.get(index); if (named) { ctx.names.set(index, named); return named; } // zones, gangs, ... carry their name
  const n = (ctx.counters.get(prefix) ?? 0) + 1; ctx.counters.set(prefix, n);
  const name = `${prefix}${n}`; ctx.names.set(index, name); return name;
}

const READ: Record<string, [number, (v: DataView, o: number) => number]> = {
  u8: [1, (v, o) => v.getUint8(o)], s8: [1, (v, o) => v.getInt8(o)], u16: [2, (v, o) => v.getUint16(o, true)], s16: [2, (v, o) => v.getInt16(o, true)],
  u32: [4, (v, o) => v.getUint32(o, true)], s32: [4, (v, o) => v.getInt32(o, true)],
};

/** What a custom (function) entry in OPS gets: raw reads plus `t()`, which renders a template
 * against the same command. */
export type Helper = { c: ScrCommand; type: number; t: (tpl: Template) => string; n: (w: string, o: number) => number; e: (name: string, v: number) => string };
export type Op = Template | ((h: Helper) => string);

/** Render one command. Returns null when the opcode has no template. */
export function render(c: ScrCommand, ctx: Ctx): string | null {
  const op = OPS[c.type]; if (op === undefined) return null;
  const v = new DataView(c.args.buffer, c.args.byteOffset, c.args.byteLength);
  const num = (w: string, o: number) => { const r = READ[w]; if (!r) throw Error(`bad width ${w}`); if (o + r[0] > v.byteLength) throw Error(`${c.name}: read past args (${o}+${r[0]} > ${v.byteLength})`); return r[1](v, o); };
  const en = (name: string, x: number) => { const table = ENUMS[name]; if (!table) throw Error(`unknown enum ${name}`); return table[x] || String(x); };
  const tpl = (t: Template) => t.replace(/^\?/, '').replace(/\{([a-z0-9]+)(?::([^@}]*))?(?:@(\d+))?\}/gi, (_, kind: string, arg: string | undefined, off: string | undefined) => {
    const o = off === undefined ? 0 : Number(off);
    switch (kind) {
      case 'decl': return declare(ctx, c.index, arg ?? 'var');
      case 'label': return ctx.labels.get(c.index) ?? `label_${c.index}`;
      case 'name': return ctx.strings.get(c.index) ?? `str_${c.index}`;
      case 'f': return fix16(num('s32', o));
      case 'xy': return `${fix16(num('s32', o))}, ${fix16(num('s32', o + 4))}`;
      case 'xyz': return `${fix16(num('s32', o))}, ${fix16(num('s32', o + 4))}, ${fix16(num('s32', o + 8))}`;
      case 'rect': return [0, 4, 8, 12, 16].map(d => fix16(num('s32', o + d))).join(', ');
      case 'bxyz': return [0, 1, 2].map(d => num('u8', o + d)).join(', ');
      case 'rgb': return [2, 1, 0].map(d => num('u8', o + d)).join(', ');
      case 'var': { const i = num(arg ?? 'u16', o); return ctx.names.get(i) ?? `var_${i}`; }
      case 'fn': { const i = num('u16', o); return ctx.labels.get(i) ?? `label_${i}`; }
      case 'str': { const i = num('u16', o); return ctx.strings.get(i) ?? `str_${i}`; }
      case 'model': { const x = num('u16', o); return x === 0xffff ? 'NONE' : en('CARS', x); }       // 0xFFFF = no model
      case 'crane': { const i = num('u16', o); return i === 0 ? 'NO_HOMECRANE' : ctx.names.get(i) ?? `var_${i}`; }
      case 'e': { const [name, w = 'u8'] = (arg ?? '').split(':'); return en(name!, num(w, o)); }
      default: return String(num(kind, o));
    }
  });
  return typeof op === 'string' ? tpl(op) : op({ c, type: c.type, t: tpl, n: num, e: en });
}

export const isBool = (type: number) => { const op = OPS[type]; return typeof op === 'string' ? op.startsWith('?') : BOOL_FNS.has(type); };

/** Label names: every FUNCTION (opcode 67) command defines one, in index order across main and subs. */
export function nameLabels(ctx: Ctx, scripts: Scr[]) {
  let n = 0;
  for (const s of scripts) for (const c of s.commands) if (c.type === 67) ctx.labels.set(c.index, `label${++n}`);
}

/** Pre-pass: give every declaring command its name, so forward references resolve. */
export function nameDeclarations(ctx: Ctx, s: Scr) {
  for (const c of s.commands) { const t = OPS[c.type]; if (typeof t === 'function' || t?.includes('{decl')) render(c, ctx); }
}

// ---- control flow -------------------------------------------------------------------------
// IF_JUMP (98), verified in 11.44 at 0x478590: args {u8 is_or; u8 _; u16 target}. It jumps to
// `target` when (is_or && result) || (!is_or && !result), else goes to cmd_next. The compiler emits:
//   term1 [NOT] -> J1 -> term2 [NOT] -> J2 ... -> termN [NOT] -> F
// where each intermediate Jk sits right after the term it leads to (index = next term + 1) and the
// final F is placed after the whole construct: then-body = [F.next, F.target) when F.target < F.index
// (an ELSE follows, else-body = [F.target, F.index)), otherwise [F.next, F.index). A WHILE is an IF
// whose span (F.index, F.target) holds a GOTO back to the first term (WHILE_EXEC when that term has
// return_value 1 and the IF_JUMP 0: the whole loop body runs in one frame).
const IF_JUMP = 98, NOT = 71, GOTO = 77, FUNCTION = 67;

type Unit = { byIndex: Map<number, ScrCommand>; sorted: number[] };
const unit = (cmds: ScrCommand[]): Unit => ({ byIndex: new Map(cmds.map(c => [c.index, c])), sorted: cmds.map(c => c.index).sort((a, b) => a - b) });

type Cond = { terms: { cmd: ScrCommand; not: boolean }[]; ops: ('AND' | 'OR')[]; final: ScrCommand };

function jumpArgs(j: ScrCommand) { const v = new DataView(j.args.buffer, j.args.byteOffset, j.args.byteLength); return { isOr: v.getUint8(0) === 1, target: v.getUint16(2, true) }; }

function parseCond(u: Unit, start: ScrCommand): Cond | null {
  const terms: Cond['terms'] = [], ops: Cond['ops'] = [];
  let c: ScrCommand | undefined = start;
  for (let guard = 0; c && guard < 64; guard++) {
    if (!isBool(c.type)) return null;
    let n: ScrCommand | undefined = c.next === null ? undefined : u.byIndex.get(c.next), not = false;
    if (n && n.type === NOT) { not = true; n = n.next === null ? undefined : u.byIndex.get(n.next); }
    if (!n || n.type !== IF_JUMP) return null;
    terms.push({ cmd: c, not });
    const nx: ScrCommand | undefined = n.next === null ? undefined : u.byIndex.get(n.next);
    const intermediate = nx !== undefined && isBool(nx.type) && nextIndexAfter(u, nx.index) === n.index;
    if (!intermediate) return { terms, ops, final: n };
    ops.push(jumpArgs(n).isOr ? 'OR' : 'AND'); c = nx;
  }
  return null;
}
// the next non-empty pointer index after i (skipping the compiler's null pointers and NOT nodes)
function nextIndexAfter(u: Unit, i: number) { const k = u.sorted.indexOf(i); for (let j = k + 1; j < u.sorted.length; j++) { const c = u.byIndex.get(u.sorted[j]!)!; if (c.type !== NOT) return c.index; } return -1; }

export type Emit = { lines: string[]; depth: number };
const say = (e: Emit, s: string) => e.lines.push('\t'.repeat(e.depth) + s);

function condText(cond: Cond, ctx: Ctx) {
  const term = (t: Cond['terms'][number]) => { const s = render(t.cmd, ctx) ?? `<${t.cmd.name}>`; return t.not ? `NOT ( ${s} )` : s; };
  if (cond.terms.length === 1) return `( ${term(cond.terms[0]!)} )`;
  let s = `( ${term(cond.terms[0]!)} )`;
  for (let i = 1; i < cond.terms.length; i++) s = `( ${s} ${cond.ops[i - 1]} ( ${term(cond.terms[i]!)} ) )`;
  return s;
}

/** Emit the commands with index in [from, to) of one script, rebuilding IF / WHILE blocks. */
export function block(u: Unit, from: number, to: number, ctx: Ctx, e: Emit) {
  const idx = u.sorted.filter(i => i >= from && i < to);
  for (let k = 0; k < idx.length;) {
    const c = u.byIndex.get(idx[k]!)!;
    const cond = isBool(c.type) ? parseCond(u, c) : null;
    if (cond) {
      const F = cond.final, { target } = jumpArgs(F), thenStart = F.next ?? F.index;
      const span = u.sorted.filter(i => i > F.index && i < target).map(i => u.byIndex.get(i)!);
      const loop = target > F.index ? span.find(g => g.type === GOTO && g.next === c.index) : undefined;
      if (loop) {
        // WHILE_EXEC marks its condition (and body) return_value 1 but leaves its own IF_JUMP at 0.
        // ENDEXEC (64) is not part of it: DMA writes that keyword by hand inside plain WHILE loops.
        say(e, `${c.returnValue === 1 && F.returnValue === 0 ? 'WHILE_EXEC' : 'WHILE'} ${condText(cond, ctx)}`);
        e.depth++; block(u, thenStart, F.index, ctx, e); e.depth--; say(e, 'ENDWHILE');
        k = idx.findIndex(i => i >= target); if (k < 0) k = idx.length; continue;
      }
      say(e, `IF ${condText(cond, ctx)}`);
      e.depth++;
      if (target < F.index) { block(u, thenStart, target, ctx, e); e.depth--; say(e, 'ELSE'); e.depth++; block(u, target, F.index, ctx, e); }
      else block(u, thenStart, F.index, ctx, e);
      e.depth--; say(e, 'ENDIF');
      k = idx.findIndex(i => i > F.index); if (k < 0) k = idx.length; continue;
    }
    statement(c, u, ctx, e); k++;
  }
}

function statement(c: ScrCommand, u: Unit, ctx: Ctx, e: Emit) {
  if (c.type === IF_JUMP || c.type === NOT) { say(e, `// stray ${c.name} @${c.index}`); return; }
  if (c.type === FUNCTION) { e.lines.push('', `${ctx.labels.get(c.index) ?? `label_${c.index}`}:`); return; }
  if (c.type === GOTO) { const t = c.next === null ? undefined : u.byIndex.get(c.next); if (t?.type === FUNCTION) say(e, `GOTO ${ctx.labels.get(t.index)}`); else say(e, `// GOTO -> ${c.next}`); return; }
  const s = render(c, ctx);
  say(e, s ?? `// ${c.name} (${c.type}) ${Array.from(c.args, b => b.toString(16).padStart(2, '0')).join('')}`);
}

export function decompile(main: Scr, subs: { name: string; scr: Scr }[]) {
  const ctx = newContext();
  for (const s of main.strings) ctx.strings.set(s.id, s.text);
  const all = [main, ...subs.map(s => s.scr)];
  nameLabels(ctx, all);
  for (const s of all) nameDeclarations(ctx, s);
  const run = (s: Scr, header: string, forward: boolean) => {
    const e: Emit = { lines: [header, ''], depth: 0 };
    if (forward) { for (const c of s.commands) if (c.type === FUNCTION) say(e, `FORWARD ${ctx.labels.get(c.index)}:`); say(e, ''); }
    const u = unit(s.commands); block(u, -1, Infinity, ctx, e); return e.lines.join('\n') + '\n';
  };
  return { main: run(main, '// decompiled by tools/formats/scr-mis.ts', true), subs: subs.map(s => ({ name: s.name, text: run(s.scr, `// decompiled by tools/formats/scr-mis.ts from ${s.name}`, true) })) };
}

/** Decompile a level's main script and every sub-mission it names (`wil_tra.mis` -> data/wil/wil_tra.scr:
 * a folder named after the main script). Returns one .mis text per script, main first. */
export function decompileLevel(read: (path: string) => Uint8Array, mainPath: string) {
  const dir = mainPath.replace(/\.scr$/i, '/'), main = parseScr(read(mainPath));
  const subs = main.strings.filter(s => s.type === STRING_TYPE_MISSION_FILE).map(s => ({ name: s.text, scr: parseScr(read(dir + s.text.replace(/\.mis$/i, '.scr'))) }));
  const r = decompile(main, subs), base = mainPath.split(/[\\/]/).pop()!.replace(/\.scr$/i, '.mis');
  return [{ name: base, text: r.main }, ...r.subs];
}
