// Ported from the user's my-games project (rts-dots2, bf84820c), tooling/assets/png.ts.
import { deflateSync } from 'node:zlib';
function crc32(bytes:Uint8Array):number { let crc=0xffffffff; for(const b of bytes){crc^=b;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);} return (crc^0xffffffff)>>>0; }
function chunk(type:string,bytes:Uint8Array) { const b=Buffer.alloc(bytes.length+12);b.writeUInt32BE(bytes.length);b.write(type,4,4,'ascii');b.set(bytes,8);b.writeUInt32BE(crc32(b.subarray(4,8+bytes.length)),8+bytes.length);return b; }
export function png(width:number,height:number,rgba:Uint8Array):Buffer {
  if(!Number.isInteger(width)||width<1||!Number.isInteger(height)||height<1||rgba.length!==width*height*4)throw new Error('Invalid PNG dimensions');
  const header=Buffer.alloc(13);header.writeUInt32BE(width);header.writeUInt32BE(height,4);header[8]=8;header[9]=6;
  const rows=Buffer.alloc((width*4+1)*height);for(let y=0;y<height;y++)rows.set(rgba.subarray(y*width*4,(y+1)*width*4),y*(width*4+1)+1);
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(rows)),chunk('IEND',new Uint8Array())]);
}
