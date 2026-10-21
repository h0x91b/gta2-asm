#!/usr/bin/env bun
// GTA2 file-format CLI over data.pak. Reads straight from the pak (pak.ts); writes only to
// an explicit --out path, and refuses one inside this repository unless git ignores it.
// Usage: bun tools/formats/cli.ts help
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve, relative, isAbsolute } from 'node:path';
import { openPak, DEFAULT_PAK, type Pak } from './pak.ts';
import { parseStyle, decodeSprite, decodeTile, paletteColor, type Style } from './style.ts';
import { styleMetadata } from './style-metadata.ts';
import { carColors } from './car-colors.ts';
import { spriteDeltas } from './deltas.ts';
import { parseMap, type MapFace } from './map.ts';
import { parseSoundBank, soundWav } from './sound.ts';
import { parseGci } from './gci.ts';
import { decodeTga } from './tga.ts';
import { png } from './png.ts';
import { decodeGxt, escapeText, toUnicode } from './gxt.ts';
import { parseScr, hex, STRING_TYPE_MISSION_FILE } from './scr.ts';
import { decompileLevel } from './scr-mis.ts';

const HELP = `bun tools/formats/cli.ts [--pak data.pak] <command> ...
  pak [--grep RE]                        list pak entries (size, data offset)
  sty <file> --summary                   chunks, sprite categories, palette bases, fonts, cars
  sty <file> --cars                      CARI records (model, sprite, size, remaps, doors)
  sty <file> --sprite N [--palette V] [--damage MASK] --out f.png
  sty <file> --tile N --out f.png
  sty <file> --palette-dump V            the 256 colours of virtual palette V
  gmp <file> --summary                   chunks, block count, zones
  gmp <file> --block x,y,z               block_info at that cell (faces, arrows, slope)
  gmp <file> --column x,y                block ids of the column, z=0 first
  gmp <file> --zones [--type T]          ZONE records
  sdt <bank> [--summary|--list]          bank = data/audio/wil (reads .sdt + .raw)
  sdt <bank> --wav ID --out f.wav
  gci [file] [--model N]                 nyc.gci car handling records
  tga <file> --out f.png
  scr <file> [--summary|--list|--strings] mission script: header, opcode counts / one line per command / strings
  gxt <file> [--summary|--list [--unicode]|--key KEY] text table: summary + validation / key<TAB>text, non-printables escaped (--unicode: font accent codes as letters) / one entry
  scr <main.scr> --mis [--out DIR]       decompile a level script and its sub-missions to .mis (stdout, or DIR/*.mis)
Paths inside the pak are case-insensitive; '\\\\' or '/' both work. JSON goes to stdout.`;

const argv = process.argv.slice(2);
function option(name: string): string | undefined { const i = argv.indexOf(name); if (i < 0) return undefined; const v = argv[i + 1]; if (v === undefined || v.startsWith('--')) throw Error(`${name} needs a value`); argv.splice(i, 2); return v; }
function flag(name: string): boolean { const i = argv.indexOf(name); if (i < 0) return false; argv.splice(i, 1); return true; }
function int(v: string | undefined, what: string): number { const n = Number(v); if (v === undefined || !Number.isInteger(n)) throw Error(`${what}: expected an integer, got ${v}`); return n; }
const ints = (v: string, n: number, what: string) => { const p = v.split(',').map(s => int(s, what)); if (p.length !== n) throw Error(`${what}: expected ${n} comma-separated integers`); return p; };
const json = (v: unknown) => console.log(JSON.stringify(v, null, 2));

const repoRoot = resolve(dirname(DEFAULT_PAK));
function writeOut(path: string | undefined, bytes: Uint8Array) {
  if (!path) throw Error('--out <path> is required (extracted game data never goes into the repo)');
  const full = resolve(path), rel = relative(repoRoot, full);
  if (!rel.startsWith('..') && !isAbsolute(rel)) {
    const ignored = Bun.spawnSync(['git', '-C', repoRoot, 'check-ignore', '-q', rel]).exitCode === 0;
    if (!ignored) throw Error(`refusing to write ${rel} inside the repo: not git-ignored (use a path outside, or /formats-out/)`);
  }
  mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, bytes);
  console.log(`wrote ${full} (${bytes.length} bytes)`);
}

const GROUND = ['air', 'road', 'pavement', 'field'];
const ZONE_TYPES = ['general_purpose', 'navigation', 'traffic_light', 'unused', 'unused', 'arrow_blocker', 'railway_station', 'bus_stop', 'general_trigger', 'unused', 'information', 'railway_station_entry', 'railway_station_exit', 'railway_stop', 'gang', 'local_navigation', 'restart', 'unused', 'unused', 'unused', 'arrest_restart'];
const FACE_NAMES = ['left', 'right', 'top', 'bottom', 'lid'];
const arrows = (a: number) => ({ raw: a, green: ['left', 'right', 'up', 'down'].filter((_, i) => a & (1 << i)), red: ['left', 'right', 'up', 'down'].filter((_, i) => a & (16 << i)) });

function sty(pak: Pak, file: string) {
  const s = parseStyle(pak.read(file));
  const sprite = option('--sprite'), tile = option('--tile'), palette = option('--palette'), damage = option('--damage'), dump = option('--palette-dump'), out = option('--out');
  if (sprite !== undefined) {
    const r = decodeSprite(s, int(sprite, '--sprite'), palette === undefined ? undefined : int(palette, '--palette'), damage === undefined ? 0 : int(damage, '--damage'));
    console.log(`sprite ${sprite}: ${r.width}x${r.height}`); return writeOut(out, png(r.width, r.height, r.rgba));
  }
  if (tile !== undefined) return writeOut(out, png(64, 64, decodeTile(s, int(tile, '--tile'))));
  if (dump !== undefined) { const v = int(dump, '--palette-dump'); return json(Array.from({ length: 256 }, (_, i) => paletteColor(s, v, i).slice(0, 3).map(c => c.toString(16).padStart(2, '0')).join(''))); }
  const meta = styleMetadata(s);
  if (flag('--cars')) return json(meta.cars);
  const palb = s.chunks.get('PALB'), pd = palb && new DataView(palb.buffer, palb.byteOffset, palb.byteLength);
  const names = ['tile', 'sprite', 'car_remap', 'ped_remap', 'code_obj_remap', 'map_obj_remap', 'user_remap', 'font_remap'];
  let base = 0; const paletteBases = pd ? Object.fromEntries(names.map((n, i) => { const count = pd.getUint16(i * 2, true), e = [n, { base, count }]; base += count; return e; })) : null;
  json({
    file, version: s.version, chunks: Object.fromEntries([...s.chunks].map(([k, v]) => [k, v.length])),
    tiles: (s.chunks.get('TILE')?.length ?? 0) / 4096, sprites: (s.chunks.get('SPRX')?.length ?? 0) / 8,
    spriteCategories: meta.categories, paletteBases, fonts: meta.fonts, cars: meta.cars.length,
    carPalettes: meta.cars.length ? (({ paletteBase, paletteCount }) => ({ paletteBase, paletteCount }))(carColors(s)) : null,
    deltaSets: spriteDeltas(s).size,
  });
}

function face(f: MapFace, i: number) { return { face: FACE_NAMES[i], ...f, ...(i === 4 ? { wall: undefined, bulletWall: undefined } : { shade: undefined }) }; }
function gmp(pak: Pak, file: string) {
  const m = parseMap(pak.read(file)), block = option('--block'), column = option('--column'), type = option('--type');
  if (block !== undefined) {
    const [x, y, z] = ints(block, 3, '--block'); if (x! < 0 || x! > 255 || y! < 0 || y! > 255 || z! < 0 || z! > 7) throw Error('--block: x,y in 0..255, z in 0..7');
    const id = m.columns[y! * 256 + x!]![z!];
    if (id === undefined) return json({ x, y, z, block: null, note: 'above the column top: air' });
    const b = m.blocks[id]!;
    return json({ x, y, z, block: id, ground: GROUND[b.ground], slope: b.slope, arrows: arrows(b.arrows), faces: b.faces.map(face) });
  }
  if (column !== undefined) { const [x, y] = ints(column, 2, '--column'); return json({ x, y, blocks: m.columns[y! * 256 + x!] }); }
  if (flag('--zones')) return json(m.zones.filter(z => type === undefined || z.type === int(type, '--type')).map(z => ({ ...z, typeName: ZONE_TYPES[z.type] ?? 'unknown' })));
  const zoneTypes: Record<string, number> = {}; for (const z of m.zones) { const n = ZONE_TYPES[z.type] ?? `type${z.type}`; zoneTypes[n] = (zoneTypes[n] ?? 0) + 1; }
  json({ file, decoded: m.compression, chunks: m.sourceChunks, blocks: m.blocks.length, zones: m.zones.length, zoneTypes });
}

function sdt(pak: Pak, bank: string) {
  const stem = bank.replace(/\.(sdt|raw)$/i, ''), name = stem.split(/[\\/]/).pop()!.toLowerCase();
  const sounds = parseSoundBank(pak.read(stem + '.sdt'), pak.read(stem + '.raw'), name === 'fstyle' ? 'frontend' : 'district');
  const wav = option('--wav'), out = option('--out');
  if (wav !== undefined) { const s = sounds[int(wav, '--wav')]; if (!s) throw Error(`no sound ${wav} (bank has ${sounds.length})`); return writeOut(out, soundWav(pak.read(stem + '.raw'), s)); }
  if (flag('--list')) return json(sounds);
  const rates: Record<number, number> = {}; for (const s of sounds) rates[s.sampleRate] = (rates[s.sampleRate] ?? 0) + 1;
  json({ bank: stem, entries: sounds.length, u8: sounds.filter(s => s.bits === 8).length, looped: sounds.filter(s => s.loopEnd !== -1).length, seconds: +sounds.reduce((n, s) => n + s.duration, 0).toFixed(2), rates });
}

function scr(pak: Pak, file: string) {
  if (flag('--mis')) {
    const out = option('--out'), files = decompileLevel(name => pak.read(name), file);
    for (const f of files) if (out) writeOut(`${out}/${f.name}`, new TextEncoder().encode(f.text)); else console.log(`// ==== ${f.name}\n${f.text}`);
    return;
  }
  const s = parseScr(pak.read(file));
  if (flag('--list')) {
    for (const c of s.commands) console.log(`${String(c.index).padStart(4)} @${c.offset.toString(16).padStart(4, '0')} ${String(c.type).padStart(3)} ${c.name.padEnd(36)} next=${c.next ?? 'end'}${c.returnValue ? ` rv=${c.returnValue}` : ''}${c.args.length ? ` ${hex(c.args)}` : ''}`);
    return;
  }
  if (flag('--strings')) return json(s.strings);
  const opcodes: Record<string, number> = {}; for (const c of s.commands) opcodes[c.name] = (opcodes[c.name] ?? 0) + 1;
  json({ file, kind: s.kind, first: s.first, start: s.start, commands: s.commands.length, strings: s.strings.length,
    missionFiles: s.strings.filter(x => x.type === STRING_TYPE_MISSION_FILE).map(x => x.text),
    opcodes: Object.fromEntries(Object.entries(opcodes).sort((a, b) => b[1] - a[1])) });
}

function gxt(pak: Pak, file: string) {
  const g = decodeGxt(pak.read(file)), key = option('--key');
  if (flag('--list')) { const uni = flag('--unicode'); for (const e of g.entries) console.log(`${e.key.padEnd(8)}\t${escapeText(uni ? toUnicode(e.raw) : e.text)}`); return; }
  if (key !== undefined) {
    const e = g.entries.find(x => x.key === key); if (!e) throw Error(`no key ${key} in ${file}`);
    return json({ key: e.key, offset: e.offset, units: e.raw.length, text: e.text, escaped: escapeText(e.text), unicode: toUnicode(e.raw), codeUnits: Array.from(e.raw, u => u.toString(16)).join(' ') });
  }
  const cps = new Set<number>(); let longest = { key: '', units: 0 };
  for (const e of g.entries) { for (const u of e.raw) if (u < 0x20 || u > 0x7e) cps.add(u); if (e.raw.length > longest.units) longest = { key: e.key, units: e.raw.length }; }
  json({ file, lang: g.lang, version: g.version, chunks: g.chunks.map(c => `${c.tag}:${c.data.length}`), keys: g.entries.length, tdatUnits: g.tdat.length, longest,
    nonAscii: Array.from(cps).sort((a, b) => a - b).map(u => u.toString(16)), issues: g.issues });
}

function main() {
  const pakPath = option('--pak'), cmd = argv.shift();
  if (!cmd || cmd === 'help' || cmd === '--help') return console.log(HELP);
  const pak = openPak(pakPath ?? DEFAULT_PAK);
  try {
    if (cmd === 'pak') { const re = option('--grep'), r = re ? new RegExp(re, 'i') : null; for (const e of pak.entries) if (!e.dir && (!r || r.test(e.name))) console.log(`${String(e.size).padStart(9)}  @${e.offset.toString(16).padStart(8, '0')}  ${e.name}`); return; }
    if (cmd === 'gci') { const file = argv[0] && !argv[0].startsWith('--') ? argv.shift()! : 'data/nyc.gci', model = option('--model'), g = parseGci(new TextDecoder().decode(pak.read(file)));
      return json(model === undefined ? { file, models: g.models.length, units: g.units, list: g.models.map(m => `${m.model} ${m.name}`) } : g.models.find(m => m.model === int(model, '--model')) ?? null); }
    const file = argv.shift(); if (!file) throw Error(`${cmd}: missing file argument\n\n${HELP}`);
    if (cmd === 'sty') sty(pak, file);
    else if (cmd === 'gmp') gmp(pak, file);
    else if (cmd === 'sdt') sdt(pak, file);
    else if (cmd === 'scr') scr(pak, file);
    else if (cmd === 'gxt') gxt(pak, file);
    else if (cmd === 'tga') { const r = decodeTga(pak.read(file)); console.log(`${file}: ${r.width}x${r.height}`); writeOut(option('--out'), png(r.width, r.height, r.rgba)); }
    else throw Error(`unknown command ${cmd}\n\n${HELP}`);
    flag('--summary');
    if (argv.length) console.error(`warning: ignored arguments: ${argv.join(' ')}`);
  } finally { pak.close(); }
}
try { main(); } catch (error) { console.error(`error: ${(error as Error).message}`); process.exit(1); }
