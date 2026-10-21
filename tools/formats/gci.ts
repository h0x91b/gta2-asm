// Ported from the user's my-games project (rts-dots2/games/gta2, bf84820c), src/assets/gci.ts.
/** Shipped NYC.GCI subset: four byte fields then seventeen f-prefixed source values.
 * Values remain in the source clock/units. This is data extraction, not a handling conversion.
 */
export const GCI_FIELDS=['model','turbo','value','pad','mass','frontDriveBias','frontMassBias','brakeFriction','turnIn','turnRatio','rearEndStability','handbrakeSlide','thrust','maxSpeed','antiStrength','skidThreshold','gear1Multiplier','gear2Multiplier','gear3Multiplier','gear2Speed','gear3Speed'] as const;
export function parseGci(text:string){
 const names=new Map([...text.matchAll(/\{([^{}\r\n]+)\}\s*(\d+)\s*\{model\}/g)].map(m=>[Number(m[2]),m[1]!.trim()]));
 const stripped=text.replace(/\{[^{}]*\}/g,' ');if(/[{}]/.test(stripped))throw Error('Unclosed GCI comment');
 const tokens=stripped.trim().split(/\s+/);if(tokens.length%GCI_FIELDS.length)throw Error('Incomplete GCI model');
 const models:({name:string;sourceTokens:string[]}&Record<typeof GCI_FIELDS[number],number>)[]=[];const seen=new Set<number>();
 for(let i=0;i<tokens.length;i+=GCI_FIELDS.length){const row={} as Record<typeof GCI_FIELDS[number],number>,sourceTokens=tokens.slice(i,i+GCI_FIELDS.length);
  GCI_FIELDS.forEach((key,j)=>{const token=sourceTokens[j]!;if(!(j<4?/^\d+$/:/^f-?\d+(?:\.\d+)?$/).test(token))throw Error(`Unsupported GCI token for ${key}: ${token}`);const n=Number(j<4?token:token.slice(1));if(!Number.isFinite(n)||j<4&&(n<0||n>255))throw Error('Invalid GCI value');row[key]=n;});
  if(seen.has(row.model))throw Error('Duplicate GCI model');seen.add(row.model);models.push({...row,name:names.get(row.model)??`Model ${row.model}`,sourceTokens});
 }
 return {version:1,units:'unconverted source values',models};
}
