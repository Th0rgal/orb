import {expect,it,vi} from 'vitest';
const connection=vi.hoisted(()=>({version:0,url:'https://one.test'}));
vi.mock('../src/api',()=>({connectionVersion:()=>connection.version,getApiUrl:()=>connection.url}));
import {cacheMachineDestinations,cachedMachineDestinations} from '../src/machineDestinations';
it('never reuses cached destinations after changing account or server',()=>{
 const rows=[{machine:{kind:'core' as const},label:'Core',available:true}];
 cacheMachineDestinations(rows);
 expect(cachedMachineDestinations()).toEqual(rows);
 connection.version++;
 expect(cachedMachineDestinations()).toEqual([]);
 cacheMachineDestinations(rows);
 connection.url='https://two.test';
 expect(cachedMachineDestinations()).toEqual([]);
});
