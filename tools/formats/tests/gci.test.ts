import {expect,test} from 'bun:test';
import {GCI_FIELDS,parseGci} from '../gci.ts';
import {hasPak,pak} from './helpers.ts';
const row='0 0 50 0 '+Array(17).fill('f1.000').join(' ');
test('GCI separates comments and preserves original decimal tokens',()=>{const p=parseGci('{Example}\n0 {model} '+row.split(' ').slice(1).join(' '));expect(p.models[0]!.name).toBe('Example');expect(p.models[0]!.mass).toBe(1);expect(p.models[0]!.sourceTokens[4]).toBe('f1.000');expect(GCI_FIELDS.length).toBe(21);});
test('GCI rejects truncation, duplicate models, malformed comments and unknown numeric formats',()=>{for(const s of [row+' 1',row+' '+row,'{unfinished '+row,row.replace('f1.000','NaN'),row.replace('0 0','256 0')])expect(()=>parseGci(s)).toThrow();});
test.skipIf(!hasPak)('supplied GCI contains model-specific mass, drive bias and transmission',()=>{const p=parseGci(new TextDecoder().decode(pak().read('data/nyc.gci')));expect(p.models.length).toBe(83);expect(p.models.find(m=>m.model===0)).toMatchObject({name:'Romero',mass:16.5,maxSpeed:0.245,frontDriveBias:1});expect(p.models.find(m=>m.model===1)).toMatchObject({name:'Wellard',mass:14.5,maxSpeed:0.38});});
