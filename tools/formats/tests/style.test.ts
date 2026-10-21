// Dropped: atlas/exported-asset round-trips and the reimplementation's damage simulation.
import { expect,test } from 'bun:test';
import { decodeTga } from '../tga.ts';
import { parseStyle,paletteColor,decodeTile,decodeSprite } from '../style.ts';
import { deltaPixels,spriteDeltas } from '../deltas.ts';
import { styleMetadata } from '../style-metadata.ts';
import { carColors } from '../car-colors.ts';
import { png } from '../png.ts';
import { inflateSync } from 'node:zlib';
import { hasPak,pak } from './helpers.ts';
function tga(type:number,bits:number,width:number,height:number,flags:number,pixels:number[]) { const b=new Uint8Array(18+pixels.length);const d=new DataView(b.buffer);b[2]=type;d.setUint16(12,width,true);d.setUint16(14,height,true);b[16]=bits;b[17]=flags;b.set(pixels,18);return b; }
test('TGA RGB555 expands white and red and flips bottom-up rows',()=>{
  const result=decodeTga(tga(2,16,1,2,1,[0,0x7c,0xff,0x7f]));expect([...result.rgba]).toEqual([255,255,255,255,255,0,0,255]);
});
test('TGA RLE handles repeated pixels, top/right origins and bounds',()=>{
  const result=decodeTga(tga(10,24,2,1,48,[1,0,0,255,255,0,0]));expect([...result.rgba]).toEqual([0,0,255,255,255,0,0,255]);
  expect([...decodeTga(tga(10,24,2,1,32,[129,0,255,0])).rgba]).toEqual([0,255,0,255,0,255,0,255]);
  expect(()=>decodeTga(tga(10,24,1,1,32,[129,0,255,0]))).toThrow('overflow');
  expect(()=>decodeTga(tga(2,24,2,1,32,[0]))).toThrow('Truncated');
});
function styleBytes(chunks:Record<string,Uint8Array>){const parts=[Buffer.from([71,66,83,84,188,2])];for(const [tag,data]of Object.entries(chunks)){const head=Buffer.alloc(8);head.write(tag);head.writeUInt32LE(data.length,4);parts.push(head,Buffer.from(data));}return Buffer.concat(parts);}
function fixture(){const palx=new Uint8Array(32768),ppal=new Uint8Array(131072),tile=new Uint8Array(65536);new DataView(palx.buffer).setUint16(0,65,true);ppal.set([11,22,33,0],65536+256+4);tile[0]=1;return {PALX:palx,PPAL:ppal,TILE:tile};}
test('GBST checks header, chunk bounds, duplicate chunks and retains unknown chunks',()=>{
  const bytes=styleBytes({TEST:new Uint8Array([7])});expect(parseStyle(bytes).chunks.get('TEST')?.[0]).toBe(7);
  expect(()=>parseStyle(bytes.subarray(0,-1))).toThrow('Truncated');expect(()=>parseStyle(new Uint8Array(7))).toThrow('GBST');
  expect(()=>parseStyle(Buffer.concat([bytes,bytes.subarray(6)]))).toThrow('Duplicate');
});
test('palette physical pages are column-interleaved BGRA and zero is transparent',()=>{
  const s=parseStyle(styleBytes(fixture()));expect(paletteColor(s,0,1)).toEqual([33,22,11,255]);expect(paletteColor(s,0,0)[3]).toBe(0);
  expect([...decodeTile(s,0).subarray(0,8)]).toEqual([33,22,11,255,0,0,0,0]);expect(()=>decodeTile(s,16)).toThrow();
});
test('sprites use 256-byte row stride rather than sprite width',()=>{
  const chunks=fixture(),sprg=new Uint8Array(512),sprx=new Uint8Array(8);sprg[0]=1;sprg[256]=1;sprx[4]=2;sprx[5]=2;
  const s=parseStyle(styleBytes({...chunks,SPRG:sprg,SPRX:sprx,PALB:new Uint8Array(16)}));const sprite=decodeSprite(s,0);
  expect(sprite.width).toBe(2);expect([...sprite.rgba.subarray(8,12)]).toEqual([33,22,11,255]);expect(()=>decodeSprite(s,1)).toThrow();expect([...decodeSprite(s,0,1).rgba.subarray(0,4)]).toEqual([0,0,0,255]);expect(()=>decodeSprite(s,0,-1)).toThrow();
});
test('PNG encodes exact RGBA into a valid filtered scanline',()=>{
  const b=png(1,1,new Uint8Array([10,20,30,255]));expect([...b.subarray(0,8)]).toEqual([137,80,78,71,13,10,26,10]);
  let p=8;while(p<b.length){const size=b.readUInt32BE(p),tag=b.toString('ascii',p+4,p+8);if(tag==='IDAT')expect([...inflateSync(b.subarray(p+8,p+8+size))]).toEqual([0,10,20,30,255]);p+=12+size;}
});
test('delta cursor advances through written pixels before the next relative skip',()=>{
 expect(deltaPixels(new Uint8Array([1,0,2,7,8,253,0,1,9]),4,2)).toEqual([{x:1,y:0,index:7},{x:2,y:0,index:8},{x:0,y:1,index:9}]);
 expect(()=>deltaPixels(new Uint8Array([3,0,2,7,8]),4,1)).toThrow();expect(()=>deltaPixels(new Uint8Array([0,0,2,7]),4,1)).toThrow();
});
test('car sprite counts are cumulative; zero shares predecessor; truncated metadata fails',()=>{
  const counts=new Uint8Array(12);counts[0]=1;const c=new Uint8Array(30);c[1]=1;c[15]=1;
  const s={version:700,chunks:new Map([['SPRB',counts],['SPRX',new Uint8Array(8)],['CARI',c]])};
  expect(styleMetadata(s).cars.map(c=>c.sprite)).toEqual([0,0]);s.chunks.set('CARI',c.subarray(0,29));expect(()=>styleMetadata(s)).toThrow('Truncated');
});
const style=(name:string)=>parseStyle(pak().read(`data/${name}.sty`));
test.skipIf(!hasPak)('the four shipped styles decode every tile and sprite without overrunning chunks',()=>{
  for(const name of ['wil','ste','bil','fstyle']){const s=style(name);const tileCount=(s.chunks.get('TILE')?.length??0)/4096;
    for(let i=0;i<tileCount;i++)expect(decodeTile(s,i).length).toBe(16384);
    const count=s.chunks.get('SPRX')!.length/8;for(let i=0;i<count;i++){const sprite=decodeSprite(s,i);expect(sprite.rgba.length).toBe(sprite.width*sprite.height*4);}
    expect(styleMetadata(s).categories.reduce((n,c)=>n+c.count,0)).toBe(count);
  }
},30000);
test.skipIf(!hasPak)('Romero/Wellard damage runs decode in all three district styles; combined dents preserve unchanged pixels',()=>{
 for(const name of ['wil','bil','ste']){const s=style(name),sets=spriteDeltas(s);
 for(const id of [0,1]){const base=decodeSprite(s,id),full=decodeSprite(s,id,undefined,31),changed=new Set<number>();
 for(let n=0;n<5;n++)for(const p of deltaPixels(sets.get(id)![n]!,base.width,base.height))changed.add(p.y*base.width+p.x);
 expect(changed.size).toBeGreaterThan(0);expect(full.rgba).not.toEqual(base.rgba);
 for(let p=0;p<base.width*base.height;p++)if(!changed.has(p))expect(full.rgba.slice(p*4,p*4+4)).toEqual(base.rgba.slice(p*4,p*4+4));
 }
 }
});
test.skipIf(!hasPak)('car remaps use their own palette base, include base art, and reject invalid references',()=>{
 const s=style('wil'),result=carColors(s);
 expect(result.paletteBase).toBe(3081);expect(result.paletteCount).toBe(37);
 expect(result.variants.filter(v=>v.model===0&&v.remap!==null).length).toBe(20);
 expect(result.variants.filter(v=>v.model===1&&v.remap!==null).length).toBe(12);
 const variants=result.variants.filter(v=>v.model===0),base=decodeSprite(s,0).rgba;
 expect(variants[0]!.remap).toBeNull();expect(variants[1]!.palette).toBe(result.paletteBase+29);
 expect(Buffer.from(decodeSprite(s,0,variants[1]!.palette!).rgba).equals(Buffer.from(base))).toBe(false);
 const bad={...s,chunks:new Map(s.chunks)},palb=s.chunks.get('PALB')!.slice();palb[4]=0;palb[5]=0;bad.chunks.set('PALB',palb);expect(()=>carColors(bad)).toThrow('outside PALB');
});
test.skipIf(!hasPak)('CARI wreck references resolve to unpainted original base sprites',()=>{
 const colors=carColors(style('wil'));
 for(const wreck of Object.values(colors.wrecks)){expect(colors.variants.find(v=>v.model===wreck&&v.remap===null)).toBeDefined();expect(wreck).toBeGreaterThanOrEqual(72);expect(wreck).toBeLessThanOrEqual(80);}
 expect(colors.wrecks[0]).toBe(74);expect(colors.wrecks[1]).toBe(75);expect(colors.wrecks[16]).toBe(78);
});
