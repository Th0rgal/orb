// Offline fixture: a follow-up sent to a mission whose previous turn ended
// (failed, interrupted, completed) or is running. The fake Core answers the
// way prod does (missions fe28bb77, 64619ac7): receipt, then
// mission_status_changed `active` ("Dispatched job …") before user_message,
// then "Remote node … is running". The stream carries only the status string;
// the mission row (with the new remote job) arrives with a slower GET.
// Params: backend=claudecode|opencode|antigravity, prev=failed|interrupted|completed|awaiting_user|active,
// remote=1|0.
import {render} from 'solid-js/web';
import '../src/styles.css';

localStorage.setItem('orb.apiUrl',location.origin);
localStorage.setItem('orb.jwt','test');
localStorage.setItem('orb.machine','core');
const q=new URLSearchParams(location.search);
const id='redflash',backend=q.get('backend')??'opencode',prev=q.get('prev')??'failed',remote=q.get('remote')!=='0';
const enc=new TextEncoder();
let stream:ReadableStreamDefaultController<Uint8Array>|undefined;
const push=(type:string,data:unknown)=>stream?.enqueue(enc.encode(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`));
const node=remote?'babylon':null;
const running=prev==='active';
const oldJob=!remote?null:running
 ?{job_id:'old',node_id:node,phase:'running',node_state:'running'}
 :{job_id:'old',node_id:node,phase:'finished',node_state:prev==='failed'?'failed':prev==='interrupted'?'cancelled':'completed',finished_at:'2026-10-20T10:00:00Z',exit_code:prev==='failed'?1:0,terminal_reason:prev==='failed'?'remote_job_failed':prev==='interrupted'?'remote_job_cancelled':null};
const newJob=remote?{job_id:'new',node_id:node,phase:'running',node_state:'running'}:null;
const assistant=(seq:number,text:string,success:boolean)=>({id:seq,event_id:`a${seq}`,sequence:seq,event_type:'assistant_message',timestamp:'',content:text,metadata:{success,model:backend}});
const shape:any[]=backend==='antigravity'
 ?[{id:2,event_id:'antigravity:c:old:1',sequence:2,event_type:'assistant_message_canonical',timestamp:'',content:'Checkpoint summary',metadata:{bubble_id:'antigravity:c:old:1',canonical_from:'text_op',revision:3}}]
 :backend==='claudecode'
 ?[{id:2,event_id:'t2',sequence:2,event_type:'tool_call',timestamp:'',content:'',metadata:{tool_call_id:'tc1',name:'Bash',args:{command:'ls'}}},{id:3,event_id:'t3',sequence:3,event_type:'tool_result',timestamp:'',content:'ok',metadata:{tool_call_id:'tc1',name:'Bash'}}]
 :[{id:2,event_id:'t2',sequence:2,event_type:'thinking',timestamp:'',content:'Looking at the repo',metadata:{done:true}}];
const core={
 mission:{id,title:'No red flash',backend,status:prev,history:[],created_at:'',updated_at:'1',project:'default',remote_node_id:node,remote_job:oldJob,status_message:prev==='failed'?`Remote ${backend} job old on node 'babylon' failed`:null} as any,
 events:[{id:1,event_id:'u0',sequence:1,event_type:'user_message',timestamp:'',content:'Run the steps',metadata:{queued:false}},...shape,
  ...(running?[]:[assistant(10,prev==='failed'?`Remote ${backend} job old on node 'babylon' failed (exit 1)`:'Done with the steps.',prev!=='failed'),{id:11,event_id:'s11',sequence:11,event_type:'mission_status_changed',timestamp:'',content:'',metadata:{status:prev}}])] as any[],
 rows:[] as any[],
 getMs:600,
};
Object.assign(window,{core,push});
const later=(ms:number,fn:()=>void)=>setTimeout(fn,ms);
const status=(next:string,job:any,at:string,summary='')=>{core.mission={...core.mission,status:next,updated_at:at,remote_job:job,status_message:summary||null};push('mission_status_changed',{status:next,summary});};
window.fetch=async(input,init)=>{
 const url=new URL(String(input),location.origin),path=url.pathname,method=init?.method??'GET';
 if(path==='/api/control/stream')return new Response(new ReadableStream({start(c){stream=c;}}),{headers:{'Content-Type':'text/event-stream'}});
 if(path===`/api/control/missions/${id}/events`){const max=String(Math.max(0,...core.events.map(e=>e.sequence)));return Response.json(core.events,{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':max,'X-Next-Cursor':max,'X-Page-Max-Sequence':max}});}
 if(path===`/api/control/missions/${id}`){const snap=core.mission;await new Promise(r=>setTimeout(r,(window as any).ready_?core.getMs:0));return Response.json(snap);}
 if(path==='/api/control/queue')return Response.json(core.rows);
 if(path==='/api/control/message'&&method==='POST'){
  const body=JSON.parse(String(init!.body));const mid=body.client_message_id??crypto.randomUUID();
  await new Promise(r=>setTimeout(r,150));
  if(running){core.rows=[...core.rows,{id:mid,mission_id:id,content:body.content,source:'remote-queue'}];return Response.json({id:mid,queued:true,message_accepted:true});}
  later(250,()=>status('active',newJob,'5',remote?`Dispatched job new to remote node '${node}'`:''));
  later(280,()=>{core.events=[...core.events,{id:40,event_id:mid,sequence:40,event_type:'user_message',timestamp:'',content:body.content,metadata:{queued:false}}];push('user_message',{id:mid,content:body.content,queued:false});});
  later(360,()=>status('active',newJob,'6',remote?`Remote node '${node}' is running`:''));
  return Response.json({id:mid,queued:false,message_accepted:true});
 }
 if(path==='/api/projects')return Response.json({projects:[{slug:'default',title:'Default'}]});
 if(path==='/api/remote-nodes')return Response.json({enabled:true,nodes:[{id:'babylon',name:'Babylon'}]});
 if(path.endsWith('/conflicts'))return Response.json({});
 if(path.endsWith('/files'))return Response.json({entries:[]});
 return Response.json([]);
};
const {NativeMissionView}=await import('../src/mission/MissionView');
render(()=><main class="main" style={{display:'flex','flex-direction':'column',height:'100vh'}}><NativeMissionView id={id} initial={core.mission}/></main>,document.getElementById('root')!);
