// Ported from the user's my-games project (rts-dots2/games/gta2, bf84820c), src/assets/style.ts.
import {spriteDeltas,deltaPixels} from './deltas.ts';
/** GBST chunk reader, based on DMA's supplied GTA2 Style Format v4.6.
 * The shipped user files report 700 (the document says 600); their palette/tile layouts agree.
 * Unknown chunks are retained; bounds are checked before any read.
 */
export interface Style { version: number; chunks: Map<string, Uint8Array> }
const view = (b: Uint8Array) => new DataView(b.buffer,b.byteOffset,b.byteLength);
export function parseStyle(bytes: Uint8Array): Style {
  const d=view(bytes); if(bytes.length<6 || new TextDecoder().decode(bytes.subarray(0,4))!=='GBST') throw new Error('Not a GBST style');
  const version=d.getUint16(4,true); if(![600,700].includes(version)) throw new Error(`Unsupported GBST version ${version}`);
  const chunks=new Map<string,Uint8Array>();
  for(let p=6;p<bytes.length;) {
    if(p+8>bytes.length) throw new Error('Truncated chunk header');
    const tag=new TextDecoder().decode(bytes.subarray(p,p+4)); const size=d.getUint32(p+4,true); p+=8;
    if(size>bytes.length-p) throw new Error(`Truncated ${tag} chunk`);
    if(chunks.has(tag)) throw new Error(`Duplicate ${tag} chunk`);
    chunks.set(tag,bytes.subarray(p,p+size));p+=size;
  }
  return {version,chunks};
}
function chunk(s:Style,name:string) { const b=s.chunks.get(name); if(!b) throw new Error(`Missing ${name} chunk`); return b; }
export function paletteColor(style:Style,virtual:number,index:number): [number,number,number,number] {
  if(!Number.isInteger(virtual)||virtual<0||!Number.isInteger(index)||index<0||index>255) throw new Error('Invalid palette coordinate');
  const palx=chunk(style,'PALX'); if(virtual*2+2>palx.length) throw new Error('Palette index outside PALX');
  const physical=view(palx).getUint16(virtual*2,true), ppal=chunk(style,'PPAL');
  const offset=Math.floor(physical/64)*65536+index*256+(physical%64)*4;
  if(offset+4>ppal.length) throw new Error('Physical palette outside PPAL');
  return [ppal[offset+2]!,ppal[offset+1]!,ppal[offset]!,index===0?0:255];
}
export function decodeTile(style:Style,id:number): Uint8Array {
  const tiles=chunk(style,'TILE'); if(!Number.isInteger(id)||id<0||(Math.floor(id/16)+1)*65536>tiles.length) throw new Error('Tile index out of range');
  const rgba=new Uint8Array(64*64*4), page=Math.floor(id/16)*65536, x=(id%4)*64,y=Math.floor(id%16/4)*64;
  const palette=Array.from({length:256},(_,i)=>paletteColor(style,id,i));
  for(let py=0;py<64;py++) for(let px=0;px<64;px++) rgba.set(palette[tiles[page+(y+py)*256+x+px]!]!, (py*64+px)*4);
  return rgba;
}
export function spriteCounts(style:Style): number[] { const b=chunk(style,'SPRB'); if(b.length!==12) throw new Error('Invalid SPRB'); return Array.from({length:6},(_,i)=>view(b).getUint16(i*2,true)); }
export function decodeSprite(style:Style,id:number,virtualPalette?:number,damageMask=0): {width:number;height:number;rgba:Uint8Array} {
  const index=chunk(style,'SPRX'); if(!Number.isInteger(id)||id<0||id*8+8>index.length) throw new Error('Sprite index out of range');
  const d=view(index), ptr=d.getUint32(id*8,true),width=d.getUint8(id*8+4),height=d.getUint8(id*8+5),pixels=chunk(style,'SPRG');
  if(!width||!height||ptr+(height-1)*256+width>pixels.length) throw new Error('Sprite pixels outside SPRG');
  const base=chunk(style,'PALB'); if(base.length<2) throw new Error('Invalid PALB');
  const palette=Array.from({length:256},(_,i)=>paletteColor(style,virtualPalette??(id+view(base).getUint16(0,true)),i));
  const rgba=new Uint8Array(width*height*4);
  for(let y=0;y<height;y++) for(let x=0;x<width;x++) rgba.set(palette[pixels[ptr+y*256+x]!]!, (y*width+x)*4);
  if(!Number.isInteger(damageMask)||damageMask<0||damageMask>31)throw Error('Invalid damage mask');
  if(damageMask){const deltas=spriteDeltas(style).get(id);for(let n=0;n<5;n++)if(damageMask&(1<<n)){if(!deltas?.[n])throw Error('Missing damage delta');for(const pixel of deltaPixels(deltas[n]!,width,height))rgba.set(palette[pixel.index]!,4*(pixel.y*width+pixel.x));}}
  return {width,height,rgba};
}
