// Ported from the user's my-games project (rts-dots2/games/gta2, bf84820c), tools/style-metadata.ts.
import { spriteCounts, type Style } from './style.ts';
export function styleMetadata(style:Style) {
  let base=0;
  const categories=spriteCounts(style).map((count,i)=>{const entry={name:['car','ped','codeObject','mapObject','user','font'][i]!,base,count};base+=count;return entry;});
  if(base!==(style.chunks.get('SPRX')?.length??0)/8)throw new Error('SPRB total differs from SPRX');
  const fonts:{id:number;base:number;count:number}[]=[];
  const f=style.chunks.get('FONB');
  if(f){const d=new DataView(f.buffer,f.byteOffset,f.byteLength);if(f.length<2||f.length!==2+d.getUint16(0,true)*2)throw new Error('Invalid FONB');
    let offset=categories[5]!.base;for(let i=0;i<d.getUint16(0,true);i++){const count=d.getUint16(2+i*2,true);fonts.push({id:i,base:offset,count});offset+=count;}if(offset!==base)throw new Error('Font counts differ from SPRB');}
  const cars:Record<string,unknown>[]=[];
  const c=style.chunks.get('CARI');
  if(c){const d=new DataView(c.buffer,c.byteOffset,c.byteLength);let p=0,sprite=-1;const seen=new Set<number>();
    while(p<c.length){if(p+15>c.length)throw new Error('Truncated CARI header');const start=p,model=c[p]!,count=c[p+1]!,remaps=c[p+4]!;
      if(count>1)throw new Error('Invalid CARI sprite count');sprite+=count;if(sprite<0||sprite>=categories[0]!.count||seen.has(model))throw new Error('Invalid CARI model/sprite');seen.add(model);
      p+=14;if(p+remaps+1>c.length)throw new Error('Truncated CARI remaps');const palettes=[...c.subarray(p,p+remaps)];p+=remaps;const doorCount=c[p++]!;
      if(p+doorCount*2>c.length)throw new Error('Truncated CARI doors');const doors=Array.from({length:doorCount},()=>{const rx=d.getInt8(p++),ry=d.getInt8(p++);return {rx,ry};});
      cars.push({model,sprite,width:c[start+2],height:c[start+3],passengers:c[start+5],wreck:c[start+6],rating:c[start+7],frontWheel:d.getInt8(start+8),rearWheel:d.getInt8(start+9),frontWindow:d.getInt8(start+10),rearWindow:d.getInt8(start+11),flags:c[start+12],flags2:c[start+13],remaps:palettes,doors});
    }
  }
  return {categories,fonts,cars};
}
