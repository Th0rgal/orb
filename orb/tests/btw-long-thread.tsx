// Offline fixture for prod /btw thread 412e22b7 (parent 52bbf658): one side
// mission with 16 turns and more than 400 events, while this computer's cache
// still holds an older state of it (answers up to turn 14, turn 15 pending as
// "Starting side agent…"). `window.askOnServer(q, a)` adds a turn the way Core
// does and streams it.
import {render} from 'solid-js/web';
import '../src/styles.css';
import {longThreadEvents,longThreadMission,pagedEvents,LONG_PARENT_ID,LONG_THREAD_ID,LONG_TURNS,type FixtureEvent} from './btwLongThreadFixture';
localStorage.setItem('orb.apiUrl',location.origin);
localStorage.setItem('orb.jwt','test');
localStorage.setItem('orb.machine','core');
const {sideQuestionKey}=await import('../src/sideQuestionStorage');
const key=sideQuestionKey(LONG_PARENT_ID);
if(!sessionStorage.getItem('seeded')){
 sessionStorage.setItem('seeded','1');
 localStorage.setItem(key,JSON.stringify({history:LONG_TURNS.slice(0,14).map((t,i)=>({id:`cached-${i}`,question:t.q.trim(),answer:t.a})),draft:'',model:'',open:true,docked:true,pending:{question:LONG_TURNS[14].q.trim(),answer:''},queue:[]}));
 localStorage.setItem('agent:'+key,JSON.stringify({id:LONG_THREAD_ID,question:LONG_TURNS[14].q.trim(),harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0}));
}
const enc=new TextEncoder();
const streams=new Map<string,ReadableStreamDefaultController<Uint8Array>>();
const push=(mission:string,type:string,data:unknown)=>{try{streams.get(mission)?.enqueue(enc.encode(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`));}catch{}};
const events:FixtureEvent[]=longThreadEvents();
const thread=longThreadMission();
const parent={id:LONG_PARENT_ID,title:'Autoresearch-archi',backend:'opencode',status:'awaiting_user',history:[],created_at:'',updated_at:'1',project:'default'} as any;
const askOnServer=(q:string,a:string)=>{
 const add=(event_type:string,content:string)=>{const seq=events.at(-1)!.sequence+1;events.push({id:seq,sequence:seq,event_type,content,timestamp:new Date(Date.UTC(2026,9,20,23)+seq*1000).toISOString(),event_id:`x${seq}`});return seq;};
 add('user_message',`ctx\n\nCurrent request:\n${q}\n`);thread.status='active';
 push(LONG_THREAD_ID,'user_message',{content:q});
 setTimeout(()=>{add('assistant_message',a);thread.status='completed';thread.updated_at=thread.last_activity_at=events.at(-1)!.timestamp;push(LONG_THREAD_ID,'assistant_message',{content:a});push(LONG_THREAD_ID,'mission_status_changed',{status:'completed'});},300);
};
Object.assign(window,{askOnServer,eventRequests:[] as string[],eventCount:events.length});
window.fetch=async(input)=>{
 const url=new URL(String(input),location.origin),path=url.pathname;
 if(path==='/api/control/stream'){const m=url.searchParams.get('mission')??'';return new Response(new ReadableStream({start(c){streams.set(m,c);}}),{headers:{'Content-Type':'text/event-stream'}});}
 if(path==='/api/control/missions'&&url.searchParams.get('tag')===`btw-parent:${LONG_PARENT_ID}`)return Response.json([thread]);
 const ev=path.match(/^\/api\/control\/missions\/([^/]+)\/events$/);
 if(ev){(window as any).eventRequests.push(ev[1]+url.search);const {json,headers}=pagedEvents(url.searchParams,ev[1]===LONG_THREAD_ID?events:[]);return Response.json(json,{headers});}
 const one=path.match(/^\/api\/control\/missions\/([^/]+)$/);
 if(one)return Response.json(one[1]===LONG_PARENT_ID?parent:thread);
 if(path==='/api/projects')return Response.json({projects:[{slug:'default',title:'Default'}]});
 if(path==='/api/remote-nodes')return Response.json({enabled:true,nodes:[]});
 if(path.endsWith('/conflicts'))return Response.json({});
 if(path.endsWith('/files'))return Response.json({entries:[]});
 return Response.json([]);
};
const {NativeMissionView}=await import('../src/mission/MissionView');
render(()=><main class="main" style={{display:'flex','flex-direction':'column',height:'100vh'}}><NativeMissionView id={LONG_PARENT_ID} initial={parent}/></main>,document.getElementById('root')!);
