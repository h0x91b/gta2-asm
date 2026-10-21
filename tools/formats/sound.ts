// Ported from the user's my-games project (rts-dots2/games/gta2, bf84820c), src/assets/sound.ts.
/** Offline GTA2 SDT/RAW reader. See docs/formats/sound-banks.md for encoding evidence. */
export interface SoundEntry {
 id:number;offset:number;size:number;sampleRate:number;variationSampleRate:number;
 loopStart:number;loopEnd:number;bits:8|16;frames:number;duration:number;category:'police-radio'|'unclassified';
}
export function parseSoundBank(table:Uint8Array,raw:Uint8Array,kind:'district'|'frontend'):SoundEntry[] {
 if(!table.length||table.length%24)throw Error('SDT must contain complete 24-byte entries');
 const d=new DataView(table.buffer,table.byteOffset,table.byteLength),entries:SoundEntry[]=[];
 for(let p=0;p<table.length;p+=24){const id=p/24,offset=d.getUint32(p,true),size=d.getUint32(p+4,true),sampleRate=d.getUint32(p+8,true),variationSampleRate=d.getUint32(p+12,true),loopStart=d.getInt32(p+16,true),loopEnd=d.getInt32(p+20,true);
  // The original police-radio channel is unsigned 8-bit. Do not infer bit depth from rate or odd lengths.
  const bits=kind==='district'&&id>=69&&id<=136?8:16,align=bits/8;
  if(!size||offset>raw.length||size>raw.length-offset)throw Error(`Sound ${id} outside RAW`);
  if(size%align||sampleRate<1000||sampleRate>192000||variationSampleRate>=sampleRate)throw Error(`Invalid sound ${id} format`);
  if(loopStart<0||loopStart>=size||loopStart%align||loopEnd!==-1&&(loopEnd<=loopStart||loopEnd>size||loopEnd%align))throw Error(`Invalid sound ${id} loop`);
  const frames=size/align;entries.push({id,offset,size,sampleRate,variationSampleRate,loopStart,loopEnd,bits,frames,duration:frames/sampleRate,category:bits===8?'police-radio':'unclassified'});
 }
 return entries;
}
/** Lossless PCM container; RIFF padding is not part of the sample payload. */
export function soundWav(raw:Uint8Array,entry:SoundEntry):Uint8Array {
 const {offset,size,sampleRate,bits}=entry;if(offset<0||offset+size>raw.length||size%(bits/8))throw Error('Invalid PCM range');
 const out=new Uint8Array(44+size+(size%2)),d=new DataView(out.buffer),text=new TextEncoder();
 for(const [p,s]of [[0,'RIFF'],[8,'WAVE'],[12,'fmt '],[36,'data']] as const)out.set(text.encode(s),p);
 d.setUint32(4,out.length-8,true);d.setUint32(16,16,true);d.setUint16(20,1,true);d.setUint16(22,1,true);d.setUint32(24,sampleRate,true);d.setUint32(28,sampleRate*bits/8,true);d.setUint16(32,bits/8,true);d.setUint16(34,bits,true);d.setUint32(40,size,true);out.set(raw.subarray(offset,offset+size),44);return out;
}
