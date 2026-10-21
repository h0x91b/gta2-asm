import {test,expect} from 'bun:test';
import {parseSoundBank,soundWav} from '../sound.ts';
import {hasPak,pak} from './helpers.ts';
function table(count=1){const b=new Uint8Array(count*24),d=new DataView(b.buffer);for(let i=0;i<count;i++){d.setUint32(i*24+4,4,true);d.setUint32(i*24+8,22050,true);d.setInt32(i*24+20,-1,true);}return b;}
test('SDT uses 24-byte little-endian entries and preserves rate variation and byte loops',()=>{
 const b=table(),d=new DataView(b.buffer);d.setUint32(0,2,true);d.setUint32(12,500,true);d.setInt32(16,2,true);
 const s=parseSoundBank(b,new Uint8Array(6),'district')[0]!;expect(s).toMatchObject({offset:2,size:4,sampleRate:22050,variationSampleRate:500,loopStart:2,loopEnd:-1,bits:16,frames:2});
 const raw=new Uint8Array([9,9,0,128,255,127]),w=soundWav(raw,s),v=new DataView(w.buffer);expect(new TextDecoder().decode(w.subarray(0,4))).toBe('RIFF');expect(v.getUint16(34,true)).toBe(16);expect(v.getUint32(28,true)).toBe(44100);expect([...w.subarray(44)]).toEqual([0,128,255,127]);
});
test('police-radio IDs are U8 including even sizes; sample rate does not select encoding',()=>{
 const b=table(138),d=new DataView(b.buffer);d.setUint32(69*24+4,3,true);d.setUint32(69*24+8,5500,true);d.setUint32(137*24+8,5500,true);
 const sounds=parseSoundBank(b,new Uint8Array([0,128,255,0]),'district');expect(sounds[68]!.bits).toBe(16);expect(sounds[69]!.bits).toBe(8);expect(sounds[70]!.bits).toBe(8);expect(sounds[136]!.bits).toBe(8);expect(sounds[137]!.bits).toBe(16);
 const w=soundWav(new Uint8Array([0,128,255,0]),sounds[69]!),v=new DataView(w.buffer);expect(w.length).toBe(48);expect(v.getUint32(4,true)).toBe(40);expect(v.getUint32(40,true)).toBe(3);expect([...w.subarray(44)]).toEqual([0,128,255,0]);
});
test('malformed tables, RAW bounds, sample alignment, rates and loops fail loudly',()=>{
 const raw=new Uint8Array(8);expect(()=>parseSoundBank(new Uint8Array(23),raw,'district')).toThrow('24-byte');
 for(const [offset,value]of [[0,9],[4,10],[4,3],[8,0],[12,22050],[16,4],[16,1],[20,8]]){const b=table();new DataView(b.buffer).setUint32(offset!,value!,true);expect(()=>parseSoundBank(b,raw,'district')).toThrow();}
});
test.skipIf(!hasPak)('all four shipped banks round-trip exact PCM payloads, including 8-bit police words',()=>{
 let total=0,u8=0;for(const name of ['wil','ste','bil','fstyle']){
  const raw=pak().read(`data/audio/${name}.raw`),sounds=parseSoundBank(pak().read(`data/audio/${name}.sdt`),raw,name==='fstyle'?'frontend':'district');
  for(const s of sounds){const w=soundWav(raw,s),d=new DataView(w.buffer);expect(w.subarray(44,44+s.size)).toEqual(raw.subarray(s.offset,s.offset+s.size));expect(d.getUint16(34,true)).toBe(s.bits);expect(d.getUint32(24,true)).toBe(s.sampleRate);total++;if(s.bits===8)u8++;}
 }expect(total).toBe(978);expect(u8).toBe(204);
});
