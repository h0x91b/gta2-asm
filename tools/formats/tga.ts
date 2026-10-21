/** GTA frontend RGB555 ignores bit 15 (as its opaque original presentation does).
 * True-colour TGA (raw and RLE), decoding into top-left-origin RGBA. */
export function decodeTga(bytes:Uint8Array): {width:number;height:number;rgba:Uint8Array} {
  if(bytes.length<18) throw new Error('Truncated TGA header');
  const d=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),type=bytes[2]!,width=d.getUint16(12,true),height=d.getUint16(14,true),bits=bytes[16]!,flags=bytes[17]!;
  if(bytes[1]!==0||![2,10].includes(type)||![16,24,32].includes(bits)||!width||!height||width*height>16_777_216) throw new Error('Unsupported TGA encoding');
  const stride=bits/8,rgba=new Uint8Array(width*height*4); let p=18+bytes[0]!,n=0;
  function pixel() { if(p+stride>bytes.length) throw new Error('Truncated TGA pixels'); const packed=stride===2 ? bytes[p]! | (bytes[p+1]!<<8) : 0; const expand=(n:number)=>(n<<3)|(n>>2); const c=stride===2 ? [expand((packed>>10)&31),expand((packed>>5)&31),expand(packed&31),255] : [bytes[p+2]!,bytes[p+1]!,bytes[p]!,stride===4?bytes[p+3]!:255]; p+=stride; return c; }
  function put(c:number[]) { if(n>=width*height) throw new Error('TGA RLE packet overflow'); const x=n%width,y=Math.floor(n/width);const tx=(flags&16)?width-1-x:x,ty=(flags&32)?y:height-1-y;rgba.set(c,(ty*width+tx)*4);n++; }
  while(n<width*height) {
    if(type===2) put(pixel());
    else { if(p>=bytes.length) throw new Error('Truncated TGA RLE'); const packet=bytes[p++]!,count=(packet&127)+1; if(packet&128){const c=pixel();for(let i=0;i<count;i++)put(c);}else for(let i=0;i<count;i++)put(pixel()); }
  }
  return {width,height,rgba};
}
