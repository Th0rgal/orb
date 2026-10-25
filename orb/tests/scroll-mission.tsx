// The real mission view in the app grid with the side question panel, a long
// main conversation and a live stream: `window.mainStream(type, data)` pushes
// an SSE event to the main mission.
import {render} from 'solid-js/web';
import '../src/styles.css';
localStorage.setItem('orb.apiUrl',location.origin);
localStorage.setItem('orb.jwt','test');
localStorage.setItem('orb.machine','core');
const ID='11111111-0000-4000-8000-000000000001';
const enc=new TextEncoder();
const streams=new Map<string,ReadableStreamDefaultController<Uint8Array>>();
const events:any[]=[];
const add=(event_type:string,content:string)=>{const seq=events.length+1;events.push({id:seq,sequence:seq,event_type,content,timestamp:new Date(Date.UTC(2026,9,20)+seq*1000).toISOString(),event_id:`e${seq}`});};
for(let i=0;i<40;i++){add('user_message',`Question ${i}: ${'please look at this '.repeat(1+i%4)}`);add('assistant_message',`## Answer ${i}\n\n${'A paragraph that wraps over a couple of lines so the turns differ in height. '.repeat(3+i%5)}`);}
const mission={id:ID,title:'Scroll fixture',backend:'opencode',status:'awaiting_user',history:[],created_at:'',updated_at:'1',project:'default'} as any;
Object.assign(window,{mainStream:(type:string,data:unknown)=>{try{streams.get(ID)?.enqueue(enc.encode(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`));}catch{}},mission});
(window as any).forks=[];(window as any).opened=[];
window.fetch=async(input,init)=>{
 const url=new URL(String(input),location.origin),path=url.pathname;
 if(path==='/api/control/stream'){const m=url.searchParams.get('mission')??'';return new Response(new ReadableStream({start(c){streams.set(m,c);}}),{headers:{'Content-Type':'text/event-stream'}});}
 const ev=path.match(/^\/api\/control\/missions\/([^/]+)\/events$/);
 if(ev){const page=ev[1]===ID?events:[];const all=page.map(e=>e.sequence);return Response.json(page,{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':String(all.length?Math.max(...all):0),...(all.length?{'X-Page-Max-Sequence':String(Math.max(...all)),'X-Next-Cursor':String(Math.min(...all))}:{})}});}
 if(path===`/api/control/missions/${ID}/fork`){const body=JSON.parse(String((init as RequestInit|undefined)?.body??'{}'));(window as any).forks.push(body);return Response.json({...mission,id:'22222222-0000-4000-8000-000000000002',tags:[`fork-of:${ID}`]});}
 const one=path.match(/^\/api\/control\/missions\/([^/]+)$/);
 if(one)return Response.json(mission);
 if(path==='/api/projects')return Response.json({projects:[{slug:'default',title:'Default'}]});
 if(path==='/api/remote-nodes')return Response.json({enabled:true,nodes:[]});
 if(path.endsWith('/conflicts'))return Response.json({});
 if(path.endsWith('/files'))return Response.json({entries:[]});
 return Response.json([]);
};
const {NativeMissionView}=await import('../src/mission/MissionView');
const {FilePanelProvider,FilePanelButton}=await import('../src/FilePanel');
render(()=><div class="app sb-hidden" style={{height:'100vh'}}><FilePanelProvider scope={{mission:mission,project:'default'}}><header style={{'grid-column':'2'}}><FilePanelButton/></header><main class="main"><NativeMissionView id={ID} initial={mission} onFork={m=>(window as any).opened.push(m.id)}/></main></FilePanelProvider></div>,document.getElementById('root')!);
