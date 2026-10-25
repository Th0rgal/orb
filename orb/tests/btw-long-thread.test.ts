import {it,expect,vi,beforeEach,afterEach} from 'vitest';
import {longThreadEvents,longThreadMission,pagedEvents,LONG_PARENT_ID,LONG_THREAD_ID,LONG_TURNS} from './btwLongThreadFixture';
vi.mock('../src/api',async original=>({...await original<typeof import('../src/api')>(),api:vi.fn(),getMission:vi.fn()}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),streamMission:vi.fn(()=>vi.fn())}));
import {api,getMission} from '../src/api';
import {getMissionEvents} from '../src/stream';
import {reconcileBtwServerHistory,watchBtw,btwSession} from '../src/btwAgent';
import {sideQuestionKey} from '../src/sideQuestionStorage';

const events=longThreadEvents();
const requests:string[]=[];
beforeEach(()=>{
 localStorage.setItem('orb.apiUrl','http://core.test');localStorage.setItem('orb.jwt','test');
 requests.length=0;
 vi.stubGlobal('fetch',vi.fn(async(input:string)=>{
  const url=new URL(input);requests.push(url.search);
  const {json,headers}=pagedEvents(url.searchParams,events);
  return new Response(JSON.stringify(json),{status:200,headers});
 }));
 vi.mocked(api).mockImplementation(async(path:string)=>path.startsWith('/api/control/missions?tag=')?[longThreadMission()] as any:[] as any);
 vi.mocked(getMission).mockImplementation(async()=>longThreadMission() as any);
});
afterEach(()=>{vi.unstubAllGlobals();localStorage.clear();vi.clearAllMocks();});

it('reads a thread longer than one event page to its end, newest last',async()=>{
 expect(events.length).toBeGreaterThan(400);
 const rows=await getMissionEvents(LONG_THREAD_ID);
 expect(rows.map(e=>e.sequence)).toEqual(events.map(e=>e.sequence));
 expect(requests.length).toBeGreaterThan(1);
 expect(requests.slice(1).every(q=>q.includes('before_seq='))).toBe(true);
});

it('shows every server turn of a long multi-turn thread, the latest answer last',async()=>{
 const {history}=await reconcileBtwServerHistory(LONG_PARENT_ID,[]);
 expect(history.map(h=>h.question)).toEqual(LONG_TURNS.map(t=>t.q.trim()));
 expect(history.at(-1)!.answer).toContain('Où nous en sommes sur la campagne `evm.fast-dev`');
 // Large injected context never leaks into the question bubble.
 expect(history.some(h=>h.question.includes('main_conversation_update'))).toBe(false);
});

it('lets Core win over a stale local cache of the same thread',async()=>{
 const stale=[
  {id:'l1',question:LONG_TURNS[0].q,answer:LONG_TURNS[0].a},
  {id:'l2',question:LONG_TURNS[13].q.trim(),answer:LONG_TURNS[13].a},
  {id:'l3',question:'A cached question Core never recorded',answer:'Stale cached answer'},
 ];
 const {history}=await reconcileBtwServerHistory(LONG_PARENT_ID,stale);
 expect(history.at(-1)!.answer).toContain('evm.fast-dev');
 expect(history.map(h=>h.answer)).not.toContain('Stale cached answer');
 expect(history).toHaveLength(LONG_TURNS.length);
 expect(btwSession(LONG_PARENT_ID)).toMatchObject({id:LONG_THREAD_ID,active:false,question:LONG_TURNS.at(-1)!.q.trim()});
});

it('watching a finished long thread reports its latest answer, not an older one',async()=>{
 localStorage.setItem('agent:'+sideQuestionKey(LONG_PARENT_ID),JSON.stringify({id:LONG_THREAD_ID,question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0}));
 const seen:any[]=[];
 await watchBtw(LONG_PARENT_ID,new AbortController().signal,e=>seen.push(e));
 expect(seen.at(-1)).toMatchObject({type:'done'});
 expect(seen.at(-1).answer).toContain('evm.fast-dev');
});

it('a conversation moved to another harness (a fork) keeps the /btw threads of the version it continues',async()=>{
 const moved='99999999-0000-4000-8000-000000000009';
 vi.mocked(getMission).mockImplementation(async(id:string)=>(id===moved?{id:moved,tags:[`fork-of:${LONG_PARENT_ID}`]}:{id,tags:[]}) as any);
 vi.mocked(api).mockImplementation(async(path:string)=>path.includes(encodeURIComponent(`btw-parent:${LONG_PARENT_ID}`))?[longThreadMission()] as any:[] as any);
 const {history}=await reconcileBtwServerHistory(moved,[]);
 expect(history.map(h=>h.question)).toEqual(LONG_TURNS.map(t=>t.q.trim()));
});
