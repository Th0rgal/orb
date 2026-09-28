import {beforeEach,expect,it,vi} from 'vitest';
const connection=vi.hoisted(()=>({version:0,url:'https://one.test',jwt:'token-a'}));
vi.mock('../src/api',()=>({connectionVersion:()=>connection.version,getApiUrl:()=>connection.url,getJwt:()=>connection.jwt}));
const rows=[{machine:{kind:'core' as const},label:'Core',available:true}];
beforeEach(()=>{localStorage.clear();vi.resetModules();Object.assign(connection,{version:0,url:'https://one.test',jwt:'token-a'});});
const load=()=>import('../src/machineDestinations');
it('never reuses cached destinations after changing account or server',async()=>{
 const {cacheMachineDestinations,cachedMachineDestinations}=await load();
 cacheMachineDestinations(rows);
 expect(cachedMachineDestinations()).toEqual(rows);
 connection.version++;connection.jwt='token-b';
 expect(cachedMachineDestinations()).toEqual([]);
 cacheMachineDestinations(rows);
 connection.version++;connection.url='https://two.test';
 expect(cachedMachineDestinations()).toEqual([]);
});
it('opens filled after a restart without storing the token',async()=>{
 (await load()).cacheMachineDestinations(rows);
 expect(localStorage.getItem('orb.machineDestinations')).not.toContain('token-a');
 vi.resetModules();connection.version=0;
 expect((await load()).cachedMachineDestinations()).toEqual(rows);
});
