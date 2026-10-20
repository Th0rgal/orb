// Offline fixture for prod mission 9304baf4 (Turbo-lean): several /btw threads,
// the most active one created earlier than another. Each /btw question
// re-dispatches a job on the same side mission, so a completed thread gets
// new questions and answers. `window.askOnServer(thread, q, a)` adds one the
// way Core does (another device, or after a restart) and streams it.
import {render} from 'solid-js/web';
import '../src/styles.css';
localStorage.setItem('orb.apiUrl',location.origin);
localStorage.setItem('orb.jwt','test');
localStorage.setItem('orb.machine','core');
const id='turbo',enc=new TextEncoder();
const streams=new Map<string,ReadableStreamDefaultController<Uint8Array>>();
const push=(mission:string,type:string,data:unknown)=>streams.get(mission)?.enqueue(enc.encode(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`));
const user=(seq:number,at:string,q:string)=>({id:seq,event_id:`u${seq}`,sequence:seq,event_type:'user_message',timestamp:at,content:`Context…\nCurrent request:\n${q}`,metadata:{queued:false}});
const answer=(seq:number,at:string,a:string)=>({id:seq,event_id:`a${seq}`,sequence:seq,event_type:'assistant_message',timestamp:at,content:a,metadata:{success:true}});
const thread=(tid:string,created:string,updated:string)=>({id:tid,title:'Turbo-lean · btw',backend:'opencode',status:'completed',history:[],created_at:created,updated_at:updated,last_activity_at:updated,project:'default',tags:[`btw-parent:${id}`]});
const core={
 mission:{id,title:'Turbo-lean',backend:'opencode',status:'awaiting_user',history:[],created_at:'',updated_at:'1',project:'default'} as any,
 threads:[thread('older','2026-10-18T13:00:00Z','2026-10-18T14:00:00Z'),thread('newest','2026-10-19T15:51:46Z','2026-10-20T12:56:59Z'),thread('middle','2026-10-19T10:16:57Z','2026-10-19T15:44:01Z')],
 events:{
  older:[user(1,'2026-10-18T13:00:00Z','Q1 oldest'),answer(2,'2026-10-18T13:05:00Z','A1')],
  middle:[user(1,'2026-10-19T10:17:00Z','Q2 middle'),answer(2,'2026-10-19T10:20:00Z','A2')],
  newest:[user(1,'2026-10-19T15:51:46Z','Q3 first on newest'),answer(2,'2026-10-19T15:53:25Z','A3'),user(3,'2026-10-20T12:51:13Z','Q4 today'),answer(4,'2026-10-20T12:53:08Z','A4')],
 } as Record<string,any[]>,
};
const askOnServer=(tid:string,q:string,a:string)=>{
 const ev=core.events[tid],seq=ev.length+1,t=core.threads.find(x=>x.id===tid)!;
 ev.push(user(seq,'2026-10-20T13:27:26Z',q));t.status='active';
 push(tid,'user_message',{id:`u${seq}`,content:q});push(tid,'mission_status_changed',{status:'active'});
 setTimeout(()=>{ev.push(answer(seq+1,'2026-10-20T13:41:48Z',a));t.status='completed';t.updated_at=t.last_activity_at='2026-10-20T13:41:48Z';push(tid,'assistant_message',{id:`a${seq+1}`,content:a});push(tid,'mission_status_changed',{status:'completed'});},400);
};
Object.assign(window,{core,askOnServer});
const page=(list:any[],url:URL)=>{const since=Number(url.searchParams.get('since_seq')??-1),rows=list.filter(e=>e.sequence>since),max=String(list.length);return Response.json(rows,{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':max,...(rows.length?{'X-Next-Cursor':max,'X-Page-Max-Sequence':max}:{})}});};
window.fetch=async(input,init)=>{
 const url=new URL(String(input),location.origin),path=url.pathname;
 if(path==='/api/control/stream'){const m=url.searchParams.get('mission')??'';return new Response(new ReadableStream({start(c){streams.set(m,c);}}),{headers:{'Content-Type':'text/event-stream'}});}
 if(path==='/api/control/missions'&&url.searchParams.get('tag')===`btw-parent:${id}`)return Response.json(core.threads);
 const ev=path.match(/^\/api\/control\/missions\/([^/]+)\/events$/);
 if(ev)return page(ev[1]===id?[]:core.events[ev[1]]??[],url);
 const one=path.match(/^\/api\/control\/missions\/([^/]+)$/);
 if(one)return Response.json(one[1]===id?core.mission:core.threads.find(t=>t.id===one[1]));
 if(path==='/api/projects')return Response.json({projects:[{slug:'default',title:'Default'}]});
 if(path==='/api/remote-nodes')return Response.json({enabled:true,nodes:[]});
 if(path.endsWith('/conflicts'))return Response.json({});
 if(path.endsWith('/files'))return Response.json({entries:[]});
 return Response.json([]);
};
const {NativeMissionView}=await import('../src/mission/MissionView');
render(()=><main class="main" style={{display:'flex','flex-direction':'column',height:'100vh'}}><NativeMissionView id={id} initial={core.mission}/></main>,document.getElementById('root')!);
