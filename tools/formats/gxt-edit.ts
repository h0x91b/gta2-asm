/** Editable text form of a `.gxt` and the checks that keep an edited file loadable and drawable
 * (rules and evidence: docs/re/gxt.md §5, §7, §9).
 *
 *   ; comment                 (lines starting with ';', and empty lines, are ignored)
 *   key<TAB>text              one entry per line; text is everything after the first TAB
 *
 * Text is Unicode for the font's accent block (é, ß, ñ …); `\n` new line, `\t` tab, `\\` backslash,
 * `\uXXXX` any raw u16 unit (speaker markers like `ⅺ`, or codes the font lacks). Export escapes
 * everything that is not printable ASCII or an accent, so export -> import of an unchanged file
 * gives back the same bytes.
 */
import { decodeGxt, encodeGxt, compareKeys, KEY_BYTES, FONT_ACCENTS, FONT_ACCENT_BASE, SPEAKER_MARKERS, type Gxt, type GxtEntry } from './gxt.ts';

const isAccent = (u: number) => u >= FONT_ACCENT_BASE && u < FONT_ACCENT_BASE + FONT_ACCENTS.length;

export function escapeUnits(raw: ArrayLike<number>): string {
  let s = '';
  for (let i = 0; i < raw.length; i++) {
    const u = raw[i]!;
    if (u === 0x5c) s += '\\\\';
    else if (u === 0x0a) s += '\\n';
    else if (u === 0x09) s += '\\t';
    else if (u >= 0x20 && u <= 0x7e) s += String.fromCharCode(u);
    else if (isAccent(u)) s += FONT_ACCENTS[u - FONT_ACCENT_BASE];
    else s += `\\u${u.toString(16).padStart(4, '0')}`;
  }
  return s;
}

export function exportText(g: Gxt, source = ''): string {
  const head = [`; ${source || 'gxt'}: ${g.entries.length} keys, language ${g.lang}. key<TAB>text, one per line.`,
    '; \\n new line (the game wraps by itself), \\uXXXX raw unit (\\u216b..\\u217a at the start = brief speaker icon, keep it),',
    "; '#' toggles highlight, %d/%s are printf arguments where the original has them. Rules: docs/re/gxt.md section 9."];
  return head.concat(g.entries.map(e => `${e.key}\t${escapeUnits(e.raw)}`)).join('\n') + '\n';
}

export type TextEdit = { key: string; raw: Uint16Array; line: number };

/** Parse the text form. Throws on syntax errors and on characters that have no font glyph. */
export function parseText(text: string): TextEdit[] {
  const out: TextEdit[] = [], seen = new Map<string, number>();
  text.split('\n').forEach((lineRaw, i) => {
    const line = lineRaw.endsWith('\r') ? lineRaw.slice(0, -1) : lineRaw, n = i + 1;
    if (line === '' || line.startsWith(';')) return;
    const tab = line.indexOf('\t'); if (tab < 0) throw Error(`line ${n}: expected key<TAB>text`);
    const key = line.slice(0, tab);
    if (seen.has(key)) throw Error(`line ${n}: key ${key} already given on line ${seen.get(key)}`);
    seen.set(key, n);
    out.push({ key, raw: unescapeUnits(line.slice(tab + 1), n, tab + 2), line: n });
  });
  return out;
}

function unescapeUnits(s: string, line: number, col0: number): Uint16Array {
  const u: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const ch = s[i]!, c = ch.charCodeAt(0), at = `line ${line} col ${col0 + i}`;
    if (ch === '\\') {
      const e = s[++i];
      if (e === '\\') u.push(0x5c); else if (e === 'n') u.push(0x0a); else if (e === 't') u.push(0x09);
      else if (e === 'u' && /^[0-9a-fA-F]{4}$/.test(s.slice(i + 1, i + 5))) { const v = parseInt(s.slice(i + 1, i + 5), 16); if (!v) throw Error(`${at}: \\u0000 is the string terminator`); u.push(v); i += 4; }
      else throw Error(`${at}: unknown escape \\${e ?? ''}`);
    } else if (c >= 0x20 && c <= 0x7e) u.push(c);
    else { const a = FONT_ACCENTS.indexOf(ch); if (a < 0) throw Error(`${at}: no font glyph for ${JSON.stringify(ch)} (U+${c.toString(16).padStart(4, '0')}); write \\uXXXX for a raw code`); u.push(FONT_ACCENT_BASE + a); }
  }
  return Uint16Array.from(u);
}

/** printf conversions in order (what swprintf would consume). */
export const printfSpecs = (raw: ArrayLike<number>) => (String.fromCharCode(...Array.from(raw)).match(/%[-+ #0]*\d*(?:\.\d+)?[hlL]?[a-zA-Z%]/g) ?? []).filter(x => x !== '%%');

/** Text widgets with fixed buffers and unbounded copies (docs/re/gxt.md §7), by key pattern. */
const LIMITS: [RegExp, number, string][] = [
  [/^car\d+$/, 32, 'car name buffer (wcscpy, unbounded)'],
  [/^[msw]\d\d$|^B\d\d$/, 64, 'zone name buffer (unbounded)'],
  [/^c\d\d$/, 64, 'pickup text buffer (unbounded)'],
  [/^mpkill\d$/, 100, 'kill-feed buffer'],
  [/^(wasted|fried|nicked|shocked|g_over|mfail|kfstart|kfpass|kffail|tport|yourit|excutin|elvis_d|em_dest|gencide|copkill|carjaka|accurcy|wrngway|fly_car|stl_all|dst_all)$/, 99, 'big label source buffer (wcscpy, unbounded)'],
  [/^\d+$/, 600, 'brief buffer is 640 units after word wrap'],
];
const MENU_KEYS = /^(play|options|quit|no_cd\d|charctr|savepos|hi_scre|strtlev|bonslev|car_dam|plr_qut|replay|mainmen|plr_ded|cmpltd|nxt_lvl|contnue|gam_cmp|score|repbons|kills_h|nicetry|fr_ent\d|fr_pmpt|entrnam)$/;

export type EditReport = { changed: string[]; added: string[]; unchanged: number; errors: string[]; warnings: string[] };

/** Check one text against the rules; `base` is the original entry's units when the key exists. */
export function checkText(key: string, raw: Uint16Array, base?: Uint16Array): { errors: string[]; warnings: string[] } {
  const errors: string[] = [], warnings: string[] = [], kb = new TextEncoder().encode(key);
  if (kb.length < 1 || kb.length > KEY_BYTES - 1 || kb.some(b => b <= 0x20 || b > 0x7e)) errors.push(`${key}: key must be 1..7 printable ASCII bytes (the game compares with strcmp, 8-byte field)`);
  const baseUnits = new Set(base ? Array.from(base) : []);
  raw.forEach((u, i) => {
    if ((u >= 0x20 && u <= 0x7e) || isAccent(u) || u === 0x0a) return;
    if (i === 0 && u in SPEAKER_MARKERS) return;
    if (baseUnits.has(u)) return;                       // already in the shipped text (e.g. a stray Latin-1 code)
    warnings.push(`${key}: unit 0x${u.toString(16)} at ${i} has no glyph in the shipped fonts (draws another font's sprite)`);
  });
  if (base) {
    const m0 = base[0]! in SPEAKER_MARKERS ? base[0] : undefined, m1 = raw[0]! in SPEAKER_MARKERS ? raw[0] : undefined;
    if (m0 !== m1) warnings.push(`${key}: speaker marker ${m0 === undefined ? 'none' : '\\u' + m0.toString(16)} -> ${m1 === undefined ? 'none' : '\\u' + m1.toString(16)}`);
    const p0 = printfSpecs(base), p1 = printfSpecs(raw);
    if (p0.length && p0.join() !== p1.join()) errors.push(`${key}: printf arguments ${p0.join(' ')} must stay (got ${p1.join(' ') || 'none'}): the game passes them to swprintf`);
    else if (!p0.length && p1.length) warnings.push(`${key}: new ${p1.join(' ')} — only formatted if the game passes an argument for this key; otherwise printed literally`);
  }
  for (const [re, max, what] of LIMITS) if (re.test(key) && raw.length > max) { (max < 600 ? errors : warnings).push(`${key}: ${raw.length} units > ${max} (${what})`); break; }
  if (MENU_KEYS.test(key) && raw.length > 50) warnings.push(`${key}: ${raw.length} units, the main menu keeps only 50`);
  return { errors, warnings };
}

/** Apply edits over a decoded base file. Unchanged keys keep their bytes; if nothing changed the
 * result is byte-identical to the base. Changed texts are re-laid in the original TDAT order, new
 * keys are inserted in sorted position (their text goes to the end of TDAT). */
export function applyEdits(base: Gxt, edits: TextEdit[]): { bytes: Uint8Array; report: EditReport } {
  const report: EditReport = { changed: [], added: [], unchanged: 0, errors: [], warnings: [] };
  const byKey = new Map(base.entries.map(e => [e.key, e] as const));
  const entries: GxtEntry[] = base.entries.map(e => ({ ...e }));
  for (const ed of edits) {
    const e = byKey.get(ed.key), c = checkText(ed.key, ed.raw, e?.raw);
    report.errors.push(...c.errors.map(x => `line ${ed.line}: ${x}`)); report.warnings.push(...c.warnings.map(x => `line ${ed.line}: ${x}`));
    if (e) {
      if (e.raw.length === ed.raw.length && e.raw.every((u, i) => u === ed.raw[i])) { report.unchanged++; continue; }
      entries.find(x => x.key === ed.key)!.raw = ed.raw; report.changed.push(ed.key);
    } else {
      const kb = new Uint8Array(KEY_BYTES); kb.set(new TextEncoder().encode(ed.key).subarray(0, KEY_BYTES - 1));
      entries.push({ key: ed.key, keyBytes: kb, offset: Infinity, text: '', raw: ed.raw }); report.added.push(ed.key);
    }
  }
  if (!report.changed.length && !report.added.length) return { bytes: encodeGxt(base), report };
  entries.sort((a, b) => compareKeys(a.keyBytes, b.keyBytes));
  return { bytes: encodeGxt({ ...base, entries }, { repack: true, keepTdatOrder: true }), report };
}

export { decodeGxt };
