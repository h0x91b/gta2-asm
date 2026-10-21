// Ported from the user's my-games project (rts-dots2/games/gta2, bf84820c), src/assets/map.ts.
/** DMA GBMP v500 reader: DMAP (32-bit words) preferred over CMAP (16-bit); other chunks are kept as sizes only. */
export interface MapFace {tile:number;wall:boolean;bulletWall:boolean;flat:boolean;flip:boolean;rotation:number;shade:number}
export interface MapBlock {faces:MapFace[];arrows:number;ground:number;slope:number}
export interface MapZone {type:number;x:number;y:number;width:number;height:number;name:string}
export interface MapData {version:1;compression:'DMAP'|'CMAP';width:256;height:256;depth:8;columns:number[][];blocks:MapBlock[];zones:MapZone[];sourceChunks:Record<string,number>}
export function mapFace(word:number,lid=false):MapFace {return {tile:word&1023,wall:!lid&&!!(word&1024),bulletWall:!lid&&!!(word&2048),flat:!!(word&4096),flip:!!(word&8192),rotation:word>>>14,shade:lid?(word>>>10)&3:0};}
export function parseMap(bytes:Uint8Array,prefer:'DMAP'|'CMAP'='DMAP'):MapData {
 const d=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),text=new TextDecoder();
 if(bytes.length<6||text.decode(bytes.subarray(0,4))!=='GBMP')throw Error('Not a GBMP map');if(d.getUint16(4,true)!==500)throw Error('Unsupported GBMP version');
 const chunks=new Map<string,Uint8Array>();for(let p=6;p<bytes.length;){if(p+8>bytes.length)throw Error('Truncated map chunk header');const tag=text.decode(bytes.subarray(p,p+4)),n=d.getUint32(p+4,true);p+=8;if(n>bytes.length-p)throw Error(`Truncated ${tag}`);if(chunks.has(tag))throw Error(`Duplicate ${tag}`);chunks.set(tag,bytes.subarray(p,p+n));p+=n;}
 const tag=chunks.has(prefer)?prefer:prefer==='DMAP'?'CMAP':'DMAP',c=chunks.get(tag);if(!c)throw Error('Missing compressed map');
 const word=tag==='DMAP'?4:2,v=new DataView(c.buffer,c.byteOffset,c.byteLength);const read=(p:number)=>{if(p<0||p+word>c.length)throw Error('Truncated map word');return word===4?v.getUint32(p,true):v.getUint16(p,true);};
 const columnWords=read(65536*word),columnStart=65537*word,blockStart=columnStart+columnWords*word+word,blockCount=read(blockStart-word);
 if(blockCount<1||blockStart+blockCount*12!==c.length)throw Error('Invalid map block store size');
 const blocks:MapBlock[]=Array.from({length:blockCount},(_,id)=>{const p=blockStart+id*12;return {faces:Array.from({length:5},(_,face)=>mapFace(v.getUint16(p+face*2,true),face===4)),arrows:v.getUint8(p+10),ground:v.getUint8(p+11)&3,slope:v.getUint8(p+11)>>>2};});
 const columns=Array.from({length:65536},(_,cell)=>{const index=read(cell*word);if(index>=columnWords)throw Error('Column pointer outside store');const p=columnStart+index*word,height=v.getUint8(p),offset=v.getUint8(p+1);if(height>8||offset>height||index+1+height-offset>columnWords)throw Error('Invalid column height/offset');const result=Array<number>(offset).fill(0);for(let z=offset;z<height;z++){const block=read(p+word+(z-offset)*word);if(block>=blockCount)throw Error('Block reference outside store');result.push(block);}return result;});
 const zones:MapZone[]=[];const zone=chunks.get('ZONE');if(zone)for(let p=0;p<zone.length;){if(p+6>zone.length)throw Error('Truncated zone header');const length=zone[p+5]!;if(p+6+length>zone.length)throw Error('Truncated zone name');zones.push({type:zone[p]!,x:zone[p+1]!,y:zone[p+2]!,width:zone[p+3]!,height:zone[p+4]!,name:text.decode(zone.subarray(p+6,p+6+length))});p+=6+length;}
 return {version:1,compression:tag,width:256,height:256,depth:8,columns,blocks,zones,sourceChunks:Object.fromEntries([...chunks].map(([k,v])=>[k,v.length]))};
}
