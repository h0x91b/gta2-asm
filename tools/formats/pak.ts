// data.pak reader: the same rules as host/w32_vfs.asm. The pak is a plain zip with every
// entry Stored (method 0, tools/mkpak.sh), so a file is one contiguous byte range. The
// central directory is read once; each entry's data offset comes from its LOCAL header
// (offset + 30 + name len + extra len). Encrypted, compressed or zip64 entries are refused.
// Lookups are case-insensitive with '/' separators ("DATA\\WIL.STY" finds data/wil.sty).
import { openSync, readSync, fstatSync, closeSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export interface PakEntry { name: string; offset: number; size: number; dir: boolean }
export interface Pak { path: string; entries: PakEntry[]; byName: Map<string, PakEntry>; read(name: string): Uint8Array; close(): void }

/** The repository root's data.pak (the canonical location, cloned into every worktree). */
export const DEFAULT_PAK = fileURLToPath(new URL('../../data.pak', import.meta.url));
export const pakKey = (name: string) => name.replace(/\\/g, '/').replace(/^\/+/, '').replace(/\/+$/, '').toLowerCase();

export function openPak(path = DEFAULT_PAK): Pak {
  const fd = openSync(path, 'r'), size = fstatSync(fd).size;
  const at = (pos: number, n: number) => { const b = new Uint8Array(n); if (readSync(fd, b, 0, n, pos) !== n) throw Error(`${path}: short read at ${pos}`); return b; };
  try {
    const tailSize = Math.min(size, 65557), tail = at(size - tailSize, tailSize), td = new DataView(tail.buffer);
    let eocd = -1;
    for (let p = tailSize - 22; p >= 0; p--) if (td.getUint32(p, true) === 0x06054b50) { eocd = p; break; }
    if (eocd < 0) throw Error(`${path}: no zip End of Central Directory`);
    const count = td.getUint16(eocd + 10, true), cdSize = td.getUint32(eocd + 12, true), cdOffset = td.getUint32(eocd + 16, true);
    if (count === 0xffff || cdOffset === 0xffffffff || cdOffset + cdSize > size) throw Error(`${path}: zip64 or corrupt central directory`);
    const cd = at(cdOffset, cdSize), d = new DataView(cd.buffer), text = new TextDecoder();
    const entries: PakEntry[] = [], byName = new Map<string, PakEntry>();
    for (let p = 0, i = 0; i < count; i++) {
      if (p + 46 > cdSize || d.getUint32(p, true) !== 0x02014b50) throw Error(`${path}: bad central directory record ${i}`);
      const flags = d.getUint16(p + 8, true), method = d.getUint16(p + 10, true), packed = d.getUint32(p + 20, true), unpacked = d.getUint32(p + 24, true);
      const nameLen = d.getUint16(p + 28, true), extraLen = d.getUint16(p + 30, true), commentLen = d.getUint16(p + 32, true), local = d.getUint32(p + 42, true);
      const raw = text.decode(cd.subarray(p + 46, p + 46 + nameLen));
      if (flags & 1) throw Error(`${path}: entry ${raw} is encrypted`);
      if (method !== 0) throw Error(`${path}: entry ${raw} is not Stored (method ${method}); rebuild it with tools/mkpak.sh (zip -0)`);
      if (packed !== unpacked || packed === 0xffffffff || local === 0xffffffff) throw Error(`${path}: entry ${raw} is zip64 or inconsistent`);
      const lh = new DataView(at(local, 30).buffer);
      if (lh.getUint32(0, true) !== 0x04034b50) throw Error(`${path}: bad local header for ${raw}`);
      const offset = local + 30 + lh.getUint16(26, true) + lh.getUint16(28, true);
      if (offset + unpacked > size) throw Error(`${path}: entry ${raw} runs past the end of the file`);
      const entry = { name: raw.replace(/\/$/, ''), offset, size: unpacked, dir: raw.endsWith('/') };
      entries.push(entry); byName.set(pakKey(raw), entry);
      p += 46 + nameLen + extraLen + commentLen;
    }
    return {
      path, entries, byName,
      read(name) {
        const e = byName.get(pakKey(name));
        if (!e || e.dir) throw Error(`${path}: no file ${name}`);
        return at(e.offset, e.size);
      },
      close() { closeSync(fd); },
    };
  } catch (error) { closeSync(fd); throw error; }
}
