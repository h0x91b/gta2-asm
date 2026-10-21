// Dropped: mesh/ramp geometry tests (they test the reimplementation's renderer, not the format).
import {test,expect} from 'bun:test';
import {parseMap,mapFace} from '../map.ts';
import {hasPak,pak} from './helpers.ts';
function fixture(word=4){const size=65536*word+word+word*3+word+24,b=Buffer.alloc(size);const write=(v:number,p:number)=>word===4?b.writeUInt32LE(v,p):b.writeUInt16LE(v,p);write(3,65536*word);const start=65537*word;b[start]=3;b[start+1]=1;write(1,start+word);write(1,start+word*2);write(2,start+word*3);b.writeUInt16LE(7|(2<<14),start+word*4+12+8);b[start+word*4+12+11]=1;return b;}
function wrap(data:Buffer,tag='DMAP',zones?:Buffer){const header=Buffer.from([71,66,77,80,244,1]);const parts:Buffer[]=[header];for(const [name,b]of [[tag,data],...(zones?[['ZONE',zones]]:[])] as [string,Buffer][]){const h=Buffer.alloc(8);h.write(name);h.writeUInt32LE(b.length,4);parts.push(h,b);}return Buffer.concat(parts);}
test('DMAP and CMAP word pointers expand offsets into correct z levels',()=>{for(const word of [2,4]){const map=parseMap(wrap(fixture(word),word===4?'DMAP':'CMAP'));expect(map.columns[0]).toEqual([0,1,1]);expect(map.columns[65535]).toEqual([0,1,1]);expect(map.blocks[1]!.faces[4]!.tile).toBe(7);expect(map.blocks[1]!.faces[4]!.rotation).toBe(2);}});
test('map parser rejects invalid pointers, heights, block indices and truncated zones',()=>{
 const b=fixture();b.writeUInt32LE(3,0);expect(()=>parseMap(wrap(b))).toThrow('Column pointer');
 const h=fixture();h[65537*4]=9;expect(()=>parseMap(wrap(h))).toThrow('height');
 const r=fixture();r.writeUInt32LE(2,65538*4);expect(()=>parseMap(wrap(r))).toThrow('Block reference');
 expect(()=>parseMap(wrap(fixture(),'DMAP',Buffer.from([2,1,1,2,2,4,65])))).toThrow('zone name');
 expect(()=>parseMap(wrap(fixture()).subarray(0,-1))).toThrow('Truncated');
});
test('lid lighting bits are not collision flags; zones preserve their names and type',()=>{expect(mapFace(3<<10,true)).toMatchObject({shade:3,wall:false,bulletWall:false});expect(mapFace(3<<10)).toMatchObject({shade:0,wall:true,bulletWall:true});const m=parseMap(wrap(fixture(),'DMAP',Buffer.from([2,10,20,3,4,3,97,98,99])));expect(m.zones).toEqual([{type:2,x:10,y:20,width:3,height:4,name:'abc'}]);});
test.skipIf(!hasPak)('every shipped map decodes into 256x256 columns of at most 8 valid blocks',()=>{
 const maps=pak().entries.filter(e=>/\.gmp$/i.test(e.name));expect(maps.length).toBe(17);
 for(const e of maps){const m=parseMap(pak().read(e.name));expect(m.columns.length).toBe(65536);expect(m.compression).toBe('DMAP');
  for(const c of m.columns){expect(c.length).toBeLessThanOrEqual(8);for(const b of c)expect(b).toBeLessThan(m.blocks.length);}}
},30000);
test.skipIf(!hasPak)('wil diagonal shop roofs are slopes 49-52 with side tile 626 (roof-corners.md)',()=>{
 const m=parseMap(pak().read('data/wil.gmp'));const b=m.blocks[m.columns[135*256+40]![3]!]!;expect(b.slope).toBeGreaterThanOrEqual(49);expect(b.slope).toBeLessThanOrEqual(52);expect(b.faces.some(f=>f.tile===626)).toBe(true);
});
