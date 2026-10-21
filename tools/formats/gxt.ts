/** Text table `.gxt`, as loaded by LoadGXT (0x4C2540). Layout (measured, see decodeGxt notes):
 *
 *   header 6 B: "GBL" + upper-case language letter | u16 version (100)
 *   chunks    : { char tag[4], u32 size, data[size] } until EOF (unknown tags are skipped by the game)
 *   TKEY      : n x 12 B { u32 byte offset into TDAT, char key[8] }  (the game bsearches the keys)
 *   TDAT      : u16 code units; every string ends with a u16 0
 *
 * decodeGxt keeps everything needed for a byte-identical encodeGxt: the chunk order, unknown
 * chunks raw, the raw 8 key bytes and the whole TDAT (so padding / unreferenced regions survive).
 * buildGxt makes a fresh file from {key: text}; it is NOT tested in the game.
 */
export const GXT_VERSION = 100;
export const KEY_BYTES = 8;

export type GxtEntry = { key: string; keyBytes: Uint8Array; offset: number; text: string; raw: Uint16Array };
export type GxtChunk = { tag: string; data: Uint8Array };
export type Gxt = {
  lang: string; version: number;
  /** All chunks in file order. TKEY/TDAT hold the original bytes; encodeGxt regenerates them. */
  chunks: GxtChunk[];
  entries: GxtEntry[];
  /** TDAT as u16 code units (faithful mode of encodeGxt writes it back verbatim). */
  tdat: Uint16Array;
  issues: string[];
};

const dec = new TextDecoder('latin1'), enc = new TextEncoder();
const view = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);

/** strcmp / bsearch order: unsigned byte compare over the 8 key bytes (NUL-padded). */
export function compareKeys(a: Uint8Array, b: Uint8Array): number {
  for (let i = 0; i < KEY_BYTES; i++) if (a[i] !== b[i]) return a[i]! - b[i]!;
  return 0;
}
const keyString = (kb: Uint8Array) => { const n = kb.indexOf(0); return dec.decode(n < 0 ? kb : kb.subarray(0, n)); };
const units = (s: string) => Uint16Array.from(s, c => c.charCodeAt(0));
/** u16 code units -> JS string (code units are kept 1:1, no surrogate interpretation). */
export const unitsToString = (u: ArrayLike<number>) => { let s = ''; for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]!); return s; };

export function decodeGxt(bytes: Uint8Array): Gxt {
  if (bytes.length < 6 || dec.decode(bytes.subarray(0, 3)) !== 'GBL') throw Error('not a GXT (no GBL magic)');
  const v = view(bytes), lang = String.fromCharCode(bytes[3]!), version = v.getUint16(4, true), issues: string[] = [];
  if (version !== GXT_VERSION) throw Error(`unsupported GXT version ${version}`);
  const chunks: GxtChunk[] = [];
  for (let p = 6; p < bytes.length;) {
    if (p + 8 > bytes.length) throw Error(`truncated chunk header at ${p}`);
    const tag = dec.decode(bytes.subarray(p, p + 4)), size = v.getUint32(p + 4, true); p += 8;
    if (size > bytes.length - p) throw Error(`truncated ${tag} chunk`);
    chunks.push({ tag, data: bytes.subarray(p, p + size) }); p += size;
  }
  const tags = chunks.map(c => c.tag);
  for (const t of ['TKEY', 'TDAT']) if (tags.filter(x => x === t).length !== 1) throw Error(`expected exactly one ${t} chunk, found ${tags.filter(x => x === t).length}`);
  const unknown = tags.filter(t => t !== 'TKEY' && t !== 'TDAT');
  if (unknown.length) issues.push(`unknown chunks: ${unknown.join(',')}`);
  if (tags[0] !== 'TKEY' || tags[1] !== 'TDAT') issues.push(`chunk order is ${tags.join(',')}`);
  const tkey = chunks.find(c => c.tag === 'TKEY')!.data, tdatB = chunks.find(c => c.tag === 'TDAT')!.data;
  if (tkey.length % 12) issues.push(`TKEY size ${tkey.length} is not a multiple of 12`);
  if (tdatB.length % 2) issues.push(`TDAT size ${tdatB.length} is odd`);
  const tv = view(tdatB), tdat = new Uint16Array(tdatB.length >> 1);
  for (let i = 0; i < tdat.length; i++) tdat[i] = tv.getUint16(i * 2, true);
  const kv = view(tkey), n = Math.floor(tkey.length / 12), entries: GxtEntry[] = [];
  const covered = new Uint8Array(tdat.length), seenOffsets = new Map<number, string>();
  for (let i = 0; i < n; i++) {
    const offset = kv.getUint32(i * 12, true), keyBytes = tkey.slice(i * 12 + 4, i * 12 + 12), key = keyString(keyBytes);
    if (offset % 2) { issues.push(`${key}: odd byte offset ${offset}`); }
    const u = offset >> 1; let e = u; while (e < tdat.length && tdat[e] !== 0) e++;
    if (u >= tdat.length || e >= tdat.length) { issues.push(`${key}: string at ${offset} runs past TDAT`); entries.push({ key, keyBytes, offset, text: '', raw: new Uint16Array(0) }); continue; }
    for (let j = u; j <= e; j++) covered[j] = 1;
    const raw = tdat.slice(u, e);
    entries.push({ key, keyBytes, offset, text: unitsToString(raw), raw });
    const prev = seenOffsets.get(offset); if (prev !== undefined) issues.push(`text shared: ${prev} and ${key} -> offset ${offset}`); else seenOffsets.set(offset, key);
    if (keyBytes.indexOf(0) >= 0 && keyBytes.subarray(keyBytes.indexOf(0)).some(b => b !== 0)) issues.push(`${key}: non-zero bytes after the key's NUL`);
  }
  // offsets must be on string starts: the unit before a string must be the previous string's NUL
  for (const en of entries) { const u = en.offset >> 1; if (u > 0 && u < tdat.length && tdat[u - 1] !== 0) issues.push(`${en.key}: offset ${en.offset} is inside another string (previous unit is not NUL)`); }
  const seen = new Set<string>();
  for (let i = 0; i < n; i++) {
    const k = entries[i]!.keyBytes.join(',');
    if (seen.has(k)) issues.push(`duplicate key ${entries[i]!.key}`); seen.add(k);
    if (i && compareKeys(entries[i - 1]!.keyBytes, entries[i]!.keyBytes) > 0) issues.push(`keys unsorted at ${i}: ${entries[i - 1]!.key} > ${entries[i]!.key}`);
  }
  let gap = 0; for (let i = 0; i < covered.length; i++) if (!covered[i]) gap++;
  if (gap) issues.push(`${gap} unreferenced TDAT units`);
  return { lang, version, chunks, entries, tdat, issues };
}

function chunkBytes(tag: string, data: Uint8Array) {
  const out = new Uint8Array(8 + data.length); out.set(enc.encode(tag), 0); view(out).setUint32(4, data.length, true); out.set(data, 8); return out;
}

/** Serialise. Faithful mode (default) writes the decoded TDAT and each entry's offset/keyBytes verbatim,
 * so decode -> encode is byte-identical. `repack: true` instead lays TDAT out fresh from entries[].raw
 * (in entry order, no sharing, no padding) and recomputes the offsets: use it after editing texts.
 * `keepTdatOrder` lays the strings out in their original offset order instead (entries with no
 * offset, e.g. offset Infinity for new keys, go last), so an edit keeps the authoring order. */
export function encodeGxt(g: Gxt, opts: { repack?: boolean; keepTdatOrder?: boolean } = {}): Uint8Array {
  let tdat = g.tdat; const offsets = g.entries.map(e => e.offset);
  if (opts.repack) {
    const parts: Uint16Array[] = []; let at = 0;
    const order = g.entries.map((_, i) => i);
    if (opts.keepTdatOrder) order.sort((a, b) => (g.entries[a]!.offset - g.entries[b]!.offset) || a - b);
    for (const i of order) { const e = g.entries[i]!; offsets[i] = at * 2; parts.push(e.raw, Uint16Array.of(0)); at += e.raw.length + 1; }
    tdat = new Uint16Array(at); let p = 0; for (const x of parts) { tdat.set(x, p); p += x.length; }
  }
  const tk = new Uint8Array(g.entries.length * 12), kv = view(tk);
  g.entries.forEach((e, i) => { kv.setUint32(i * 12, offsets[i]!, true); tk.set(e.keyBytes, i * 12 + 4); });
  const td = new Uint8Array(tdat.length * 2), tv = view(td); tdat.forEach((u, i) => tv.setUint16(i * 2, u, true));
  const parts: Uint8Array[] = [new Uint8Array(6)];
  parts[0]!.set(enc.encode('GBL' + g.lang), 0); view(parts[0]!).setUint16(4, g.version, true);
  for (const c of g.chunks) parts.push(chunkBytes(c.tag, c.tag === 'TKEY' ? tk : c.tag === 'TDAT' ? td : c.data));
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let p = 0; for (const x of parts) { out.set(x, p); p += x.length; }
  return out;
}

/** Fresh file from {key: text}: keys sorted by bytes (what the game's bsearch needs), TKEY then TDAT,
 * strings in key order each followed by a NUL unit. Keys: 1..7 ASCII bytes (every shipped key leaves the 8th byte NUL, so the game's strcmp sees a terminator); text: code units 1..65535.
 * UNTESTED IN THE GAME. */
export function buildGxt(lang: string, texts: Record<string, string>): Uint8Array {
  if (!/^[A-Za-z]$/.test(lang)) throw Error('lang must be one letter');
  const keys = Object.keys(texts).map(k => { const b = enc.encode(k); if (b.length < 1 || b.length > KEY_BYTES - 1 || b.some(x => x === 0 || x > 127)) throw Error(`bad key ${JSON.stringify(k)}`); const kb = new Uint8Array(KEY_BYTES); kb.set(b); return { k, kb }; })
    .sort((a, b) => compareKeys(a.kb, b.kb));
  const entries: GxtEntry[] = keys.map(({ k, kb }) => {
    const raw = units(texts[k]!); if (raw.some(u => u === 0)) throw Error(`text of ${k} contains U+0000`);
    return { key: k, keyBytes: kb, offset: 0, text: texts[k]!, raw };
  });
  const g: Gxt = { lang: lang.toUpperCase(), version: GXT_VERSION, chunks: [{ tag: 'TKEY', data: new Uint8Array(0) }, { tag: 'TDAT', data: new Uint8Array(0) }], entries, tdat: new Uint16Array(0), issues: [] };
  return encodeGxt(g, { repack: true });
}

/** Printable form: control units (< 0x20, 0x7F..0x9F) become \xNN / \uNNNN, backslash is doubled. */
export function escapeText(s: string): string {
  return s.replace(/[\\\u0000-\u001f\u007f-\u009f]|[^\u0000-ÿ]/g, c => c === '\\' ? '\\\\' : c.charCodeAt(0) < 256 ? `\\x${c.charCodeAt(0).toString(16).padStart(2, '0')}` : `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
}

/** Font code page of the shipped e/f/g/i/s.gxt: TDAT units are font glyph codes (DrawGTAText 0x4CC100
 * draws sprite `fontBase + code - 0x21`), not Unicode. 0x21..0x7E are ASCII; 0x80..0xB0 are the accented
 * glyphs in this order (read off the wil.sty font 1 sprite sheet, cross-checked with letter frequencies
 * per language; docs/re/gxt.md). Codes past 0xB0 draw the next font's sprites. */
export const FONT_ACCENTS = 'ÀÁÂÄÆÇÈÉÊËÌÍÎÏÒÓÔÖÙÚÛÜßàáâäæçèéêëìíîïòóôöùúûüÑñ¿¡';
export const FONT_ACCENT_BASE = 0x80;
/** First-unit speaker markers of briefs (Hud_Brief_SpeakerIconFromChar 0x4C63F0) -> HUD icon number. */
export const SPEAKER_MARKERS: Record<number, number> = { 0x216b: 6, 0x216c: 1, 0x216d: 7, 0x216e: 8, 0x2170: 9, 0x2172: 4, 0x2173: 5, 0x2179: 2, 0x217a: 3 };

/** Font codes -> readable Unicode (accent block mapped; everything else kept as is). Lossy for the few
 * stray Latin-1 units in f/i/s.gxt (0xE9 and 0x9E both read as 'é'): edit through fromUnicode, keep
 * `raw` for byte-identical work. */
export function toUnicode(u: ArrayLike<number>): string {
  let s = '';
  for (let i = 0; i < u.length; i++) { const c = u[i]!, a = c - FONT_ACCENT_BASE; s += a >= 0 && a < FONT_ACCENTS.length ? FONT_ACCENTS[a] : String.fromCharCode(c); }
  return s;
}

/** Unicode -> font codes. Refuses characters the font has no glyph for (anything but printable ASCII,
 * space, '\n', the accent block, and a speaker marker as the first unit). */
export function fromUnicode(s: string): Uint16Array {
  return Uint16Array.from(s, (ch, i) => {
    const c = ch.charCodeAt(0), a = FONT_ACCENTS.indexOf(ch);
    if (a >= 0) return FONT_ACCENT_BASE + a;
    if ((c >= 0x20 && c <= 0x7e) || c === 0x0a || (i === 0 && c in SPEAKER_MARKERS)) return c;
    throw Error(`no font glyph for ${JSON.stringify(ch)} (U+${c.toString(16).padStart(4, '0')}) at ${i}`);
  });
}
