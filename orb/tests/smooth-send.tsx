// Offline visual fixture for Send now / queue / edit in place. A fake Core
// answers over fetch and an in-page SSE stream; no network, no model call.
import {render} from 'solid-js/web';
import '../src/styles.css';

localStorage.setItem('orb.apiUrl',location.origin);
localStorage.setItem('orb.jwt','test');
localStorage.setItem('orb.machine','core');
const id='smooth';
const enc=new TextEncoder();
let stream:ReadableStreamDefaultController<Uint8Array>|undefined;
const push=(type:string,data:unknown)=>stream?.enqueue(enc.encode(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`));
const core={
 mission:{id,title:'Smooth send',backend:'opencode',status:'active',history:[],created_at:'',updated_at:'1',project:'default',remote_node_id:'nippur',remote_job:{job_id:'old',node_id:'nippur',phase:'running',node_state:'running'}} as any,
 rows:[{id:'q1',mission_id:id,content:'First queued message',source:'remote-queue'},{id:'q2',mission_id:id,content:'Second queued message',source:'remote-queue'}] as any[],
 events:[{id:1,event_id:'u0',sequence:1,event_type:'user_message',timestamp:'',content:'Run the steps',metadata:{queued:false}}] as any[],
 refuseEdit:false,
 stopMs:400,
};
// `?cut`: one queued message, and a running turn with streamed text that the
// Send now cuts. The stream reproduces prod Core 1653f6d3 (mission c24318b8):
// the text_delta_latest buffer outlives the cut turn.
const cut=new URLSearchParams(location.search).has('cut');
const STEPS='step 1 done\nstep 2 done\nstep 3 done\nstep 4 done\nstep 5 done';
const REPLY='You said "retest queued", so I\'ll carry on';
if(cut){
 core.rows=[{id:'q2',mission_id:id,content:'retest queued',source:'remote-queue'}];
 core.events=[...core.events,{id:5,event_id:'text_delta_latest',sequence:5,event_type:'text_delta',timestamp:'',content:STEPS,metadata:{}}];
}
Object.assign(window,{STEPS,REPLY});
// `?idle`: a finished mission with a long transcript; a follow-up starts a
// turn the way Core does (receipt, then user_message and status ~1 s later).
const idle=new URLSearchParams(location.search).has('idle');
const conflict=new URLSearchParams(location.search).has('conflict');
(core as any).conflicts=2;
if(idle){
 core.mission={...core.mission,backend:'claudecode',status:'completed',remote_job:null};
 core.rows=[];
 core.events=[...core.events,...Array.from({length:30},(_,i)=>({id:2+i,event_id:`a${i}`,sequence:2+i,event_type:'assistant_message',timestamp:'',content:`Paragraph ${i} of a long answer that wraps over a couple of lines in the transcript column.`,metadata:{success:true}}))];
}
const status=(next:string,job:any,at:string)=>{core.mission={...core.mission,status:next,updated_at:at,remote_job:job};push('mission_status_changed',{status:next});};
Object.assign(window,{core,push,status});
window.fetch=async(input,init)=>{
 const url=new URL(String(input),location.origin),path=url.pathname,method=init?.method??'GET';
 if(path==='/api/control/stream')return new Response(new ReadableStream({start(c){stream=c;}}),{headers:{'Content-Type':'text/event-stream'}});
 if(path===`/api/control/missions/${id}/events`)return (()=>{const max=String(Math.max(0,...core.events.map(e=>e.sequence)));return Response.json(core.events,{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':max,'X-Next-Cursor':max,'X-Page-Max-Sequence':max}});})();
 if(path===`/api/control/missions/${id}`)return Response.json(core.mission);
 if(path==='/api/control/queue')return Response.json(core.rows);
 const send=path.match(/^\/api\/control\/queue\/([^/]+)\/send-now$/);
 if(send&&method==='POST'){
  const row=core.rows.find(r=>r.id===send[1]);
  core.rows=core.rows.filter(r=>r.id!==send[1]);
  // Core: stop the old turn, then start the promoted message's turn.
  if(cut){
   setTimeout(()=>{core.events=[...core.events,{id:8,sequence:8,event_type:'mission_status_changed',timestamp:'',content:'',metadata:{status:'interrupted'}}];status('interrupted',{job_id:'old',node_id:'nippur',phase:'finished',node_state:'cancelled'},'2');},core.stopMs);
   setTimeout(()=>{
    core.events=[...core.events,{id:9,event_id:row.id,sequence:9,event_type:'user_message',timestamp:'',content:row.content,metadata:{queued:false}}];
    push('user_message',{id:row.id,content:row.content,queued:false});
    status('active',{job_id:'new',node_id:'nippur',phase:'running',node_state:'running'},'3');
    const len=Array.from(STEPS).length;
    push('text_op',{bubble_id:'text_delta_latest',ops:[{type:'replace',range:[0,len],text:STEPS+REPLY}]});
   },core.stopMs*2);
   return Response.json({ok:true,delivered:false,promoted:true});
  }
  setTimeout(()=>status('interrupted',{job_id:'old',node_id:'nippur',phase:'finished',node_state:'cancelled'},'2'),core.stopMs);
  setTimeout(()=>{
   core.events=[...core.events,{id:9,event_id:row.id,sequence:9,event_type:'user_message',timestamp:'',content:row.content,metadata:{queued:false}}];
   push('user_message',{id:row.id,content:row.content,queued:false});
   status('active',{job_id:'new',node_id:'nippur',phase:'running',node_state:'running'},'3');
  },core.stopMs*2);
  return Response.json({ok:true,delivered:false,promoted:true});
 }
 const edit=path.match(/^\/api\/control\/queue\/([^/]+)$/);
 if(edit&&method==='PATCH'){
  await new Promise(r=>setTimeout(r,250));
  if(core.refuseEdit)return new Response('This message was already sent; it can no longer be edited',{status:409});
  const {content}=JSON.parse(String(init!.body));
  core.rows=core.rows.map(r=>r.id===edit[1]?{...r,content}:r);
  return Response.json({ok:true,id:edit[1],content});
 }
 if(edit&&method==='DELETE'){core.rows=core.rows.filter(r=>r.id!==edit[1]);return Response.json({ok:true});}
 if(path==='/api/control/message'&&method==='POST'){
  const body=JSON.parse(String(init!.body));const mid=body.client_message_id??body.id??crypto.randomUUID();
  await new Promise(r=>setTimeout(r,300));
  // `?conflict`: an older Core refusing the follow-up while an automatic
  // resume runs on the node, then accepting it.
  if(conflict&&(core as any).conflicts-->0)return new Response(`REMOTE_JOB_STILL_RUNNING: mission ${id} still owns job old on remote node 'babylon'; wait for it to finish or cancel the mission first`,{status:409});
  if(idle){
   setTimeout(()=>{
    core.events=[...core.events,{id:40,event_id:mid,sequence:40,event_type:'user_message',timestamp:'',content:body.content,metadata:{queued:false}}];
    push('user_message',{id:mid,content:body.content,queued:false});
    status('active',{job_id:'new',node_id:'nippur',phase:'running',node_state:'running'},'5');
   },700);
   return Response.json({id:mid,queued:false,message_accepted:true});
  }
  core.rows=[...core.rows,{id:mid,mission_id:id,content:body.content,source:'remote-queue'}];
  return Response.json({id:mid,queued:true,message_accepted:true});
 }
 if(path==='/api/projects')return Response.json({projects:[{slug:'default',title:'Default'}]});
 if(path==='/api/remote-nodes')return Response.json({enabled:true,nodes:[{id:'nippur',name:'Nippur'}]});
 if(path.endsWith('/conflicts'))return Response.json({});
 if(path.endsWith('/files'))return Response.json({entries:[]});
 return Response.json([]);
};
const {NativeMissionView}=await import('../src/mission/MissionView');
render(()=><main class="main" style={{display:'flex','flex-direction':'column',height:'100vh'}}><NativeMissionView id={id} initial={core.mission}/></main>,document.getElementById('root')!);
