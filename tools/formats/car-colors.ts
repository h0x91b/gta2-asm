// Trimmed: no atlas packing, no damage/door composites for the reimplementation's
// supported-model list. What is left is the palette arithmetic, which is the format fact.
import {styleMetadata} from './style-metadata.ts';
import type {Style} from './style.ts';
/** CARI remaps are relative to PALB's car-remap area, not absolute palettes. */
export function carColors(style:Style){
 const palb=style.chunks.get('PALB');if(!palb||palb.length!==16)throw Error('Invalid PALB');
 const d=new DataView(palb.buffer,palb.byteOffset,palb.byteLength),base=d.getUint16(0,true)+d.getUint16(2,true),count=d.getUint16(4,true);
 const metadata=styleMetadata(style),variants:{model:number;sprite:number;remap:number|null;palette:number|null}[]=[];
 for(const car of metadata.cars){
  const model=car.model as number,sprite=car.sprite as number,remaps=car.remaps as number[];
  variants.push({model,sprite,remap:null,palette:null});
  for(const remap of remaps){if(remap>=count)throw Error('CARI remap outside PALB');variants.push({model,sprite,remap,palette:base+remap});}
 }
 const wrecks=Object.fromEntries(metadata.cars.filter(c=>Number(c.wreck)<9).map(c=>[Number(c.model),72+Number(c.wreck)]));
 return {wrecks,variants,paletteBase:base,paletteCount:count};
}
