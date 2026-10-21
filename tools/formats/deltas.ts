import type {Style} from './style.ts';
const cache=new WeakMap<Style,Map<number,Uint8Array[]>>();
/** DELX describes variable-length sets; DELS uses cumulative 256-byte page offsets. */
export function spriteDeltas(style:Style):Map<number,Uint8Array[]> {
 const saved=cache.get(style);if(saved)return saved;
 const index=style.chunks.get('DELX'),store=style.chunks.get('DELS'),sets=new Map<number,Uint8Array[]>();
 if(!index&&!store)return sets;if(!index||!store)throw Error('Missing delta chunk');
 const d=new DataView(index.buffer,index.byteOffset,index.byteLength);let p=0,offset=0;
 while(p<index.length){if(p+4>index.length)throw Error('Truncated delta header');const id=d.getUint16(p,true),count=index[p+2]!;p+=4;
 if(count>32||p+count*2>index.length||sets.has(id))throw Error('Invalid delta index');const deltas=[];
 for(let i=0;i<count;i++){const length=d.getUint16(p,true);p+=2;if(offset+length>store.length)throw Error('Delta outside DELS');deltas.push(store.subarray(offset,offset+length));offset+=length;}
 sets.set(id,deltas);
 }
 if(offset!==store.length)throw Error('Unindexed delta bytes');cache.set(style,sets);return sets;
}
export function deltaPixels(bytes:Uint8Array,width:number,height:number):{x:number;y:number;index:number}[]{
 const d=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),pixels=[];let p=0,cursor=0;
 while(p<bytes.length){if(p+3>bytes.length)throw Error('Truncated delta run');cursor+=d.getUint16(p,true);const count=bytes[p+2]!;p+=3;
 if(p+count>bytes.length||cursor%256+count>width||Math.floor(cursor/256)>=height)throw Error('Delta run outside sprite');
 for(let i=0;i<count;i++){pixels.push({x:cursor%256,y:Math.floor(cursor/256),index:bytes[p++]!});cursor++;}
 }return pixels;
}
