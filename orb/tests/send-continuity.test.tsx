import {afterEach,beforeEach,expect,it,vi} from 'vitest';
import {render,screen,waitFor} from '@solidjs/testing-library';
import {createSignal} from 'solid-js';
import {NativeMissionView} from '../src/mission/MissionView';
import type {Mission} from '../src/api';
beforeEach(()=>{Object.defineProperty(HTMLElement.prototype,'scrollTo',{configurable:true,value:vi.fn()});});
const state=vi.hoisted(()=>({event:undefined as undefined|((event:any)=>void),starts:0,stops:0}));
vi.mock('../src/stream',async()=>({...await vi.importActual('../src/stream'),streamMission:(_id:string,receive:(event:any)=>void)=>{state.starts++;state.event=receive;return ()=>{state.stops++;};}}));
vi.mock('../src/api',async()=>({...await vi.importActual('../src/api'),sendMissionMessage:vi.fn(),getMission:vi.fn(async()=>({id:'accepted',status:'active',history:[],created_at:'',updated_at:''}))}));
afterEach(()=>{vi.unstubAllGlobals();state.event=undefined;state.starts=0;state.stops=0;});
it('keeps the initial bubble mounted across native identity allocation and canonical receipt',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json([])));
 const [id,setId]=createSignal('');
 const [mission,setMission]=createSignal<Mission>();
 const receipt={messageKey:'draft:one',prompt:'Keep this message visible',nodeId:'core',destination:'Core'};
 const view=render(()=><NativeMissionView id={id()} initial={mission()} launch={receipt}/>);
 const node=view.container.querySelector('.user');expect(node?.textContent).toContain(receipt.prompt);
 expect(state.event).toBeUndefined();
 setMission({id:'accepted',status:'active',history:[],created_at:'',updated_at:''});setId('accepted');
 await waitFor(()=>expect(state.event).toBeTypeOf('function'));
 state.event!({type:'user_message',data:{id:'canonical',content:receipt.prompt}});
 await waitFor(()=>expect(screen.getAllByText(receipt.prompt)).toHaveLength(1));
 expect(view.container.querySelector('.user')).toBe(node);
});
it('keeps the failed launch bubble in place and offers retry',()=>{
 const [error,setError]=createSignal<string>();const retry=vi.fn();
 const view=render(()=><NativeMissionView id="" launch={{messageKey:'draft:error',prompt:'Retain failed message',nodeId:'local',destination:'This computer'}} launchError={error()} onRetryLaunch={retry}/>);
 const node=view.container.querySelector('.user');setError('Connection unavailable');
 expect(view.container.querySelector('.user')).toBe(node);
 screen.getByRole('button',{name:'Retry'}).click();expect(retry).toHaveBeenCalledOnce();
});

it('keeps a follow-up visible through a failed request and retries with the same identity',async()=>{
 const {sendMissionMessage,getMission}=await import('../src/api');
 vi.mocked(getMission).mockResolvedValue({id:'followup',status:'awaiting_user',history:[],created_at:'',updated_at:''});
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}})));
 let reject!:(e:Error)=>void;
 vi.mocked(sendMissionMessage).mockImplementationOnce(()=>new Promise((_resolve,fail)=>{reject=fail;}));
 vi.mocked(sendMissionMessage).mockImplementationOnce(async(_id,_text,_attachments,id)=>({id:id!,queued:false}));
 const view=render(()=><NativeMissionView id="followup" initial={{id:'followup',status:'awaiting_user',history:[],created_at:'',updated_at:''}}/>);
 const input=screen.getByPlaceholderText('Send follow-up') as HTMLTextAreaElement;
 const {fireEvent}=await import('@solidjs/testing-library');
 fireEvent.input(input,{target:{value:'Keep my follow-up'}});fireEvent.keyDown(input,{key:'Enter'});
 const node=view.container.querySelector('.user');expect(node?.textContent).toContain('Keep my follow-up');
 await waitFor(()=>expect(reject).toBeTypeOf('function'));
 reject(new Error('Network unavailable'));
 await waitFor(()=>expect(screen.getByRole('button',{name:'Retry'})).toBeDefined());
 expect(view.container.querySelector('.user')).toBe(node);expect(input.value).toBe('');
 await waitFor(()=>expect(input.readOnly).toBe(false));
 fireEvent.click(screen.getByRole('button',{name:'Retry'}));
 await waitFor(()=>expect(sendMissionMessage).toHaveBeenCalledTimes(2));
 expect(vi.mocked(sendMissionMessage).mock.calls[1][3]).toBe(vi.mocked(sendMissionMessage).mock.calls[0][3]);
 expect(view.container.querySelector('.user')).toBe(node);
 expect(screen.getAllByText('Keep my follow-up')).toHaveLength(1);
});

it('shows a remote queued follow-up once and removes it without reopening the conversation',async()=>{
 const {getMission}=await import('../src/api');
 vi.mocked(getMission).mockResolvedValue({id:'remote-queued',status:'active',history:[],created_at:'',updated_at:''});
 let queued=true;
 vi.stubGlobal('fetch',vi.fn(async(url,options)=>{
  if(options?.method==='DELETE'){queued=false;return Response.json({ok:true});}
  if(String(url).includes('/queue?'))return Response.json(queued?[{id:'remote-message',mission_id:'remote-queued',content:'Durable remote follow-up',source:'remote-queue'}]:[]);
  return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
 }));
 render(()=><NativeMissionView id="remote-queued" initial={{id:'remote-queued',status:'active',history:[],created_at:'',updated_at:''}}/>);
 await waitFor(()=>expect(screen.getAllByText('Durable remote follow-up')).toHaveLength(1));
 const {fireEvent}=await import('@solidjs/testing-library');
 await fireEvent.click(screen.getByRole('button',{name:'Remove queued message: Durable remote follow-up'}));
 await waitFor(()=>expect(screen.queryByText('Durable remote follow-up')).toBeNull());
});

it('recovers a stored Antigravity answer on completion when live text was missed',async()=>{
 const polling=await import('../src/poll');
 let poll:undefined|(()=>void|Promise<unknown>);
 const pollSpy=vi.spyOn(polling,'pollWhileVisible').mockImplementation((run,ms)=>{if(ms===10000)poll=run;return ()=>{};});
 const id='antigravity-missed-final';
 const mission={id,backend:'antigravity',status:'active',history:[],created_at:'',updated_at:''};
 const {getMission}=await import('../src/api');
 vi.mocked(getMission).mockImplementation(async()=>({...mission}));
 let complete=false;
 vi.stubGlobal('fetch',vi.fn(async url=>{
  if(String(url).includes('/events'))return Response.json(complete?[{id:2,event_id:'agy-answer',sequence:2,event_type:'assistant_message',content:'I am Gemini inside Antigravity.',timestamp:''}]:[],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false',...(complete?{'X-Next-Cursor':'2','X-Page-Max-Sequence':'2'}:{})}});
  return Response.json([]);
 }));
 const view=render(()=><NativeMissionView id={id} initial={mission} launch={{prompt:'What model are you?',nodeId:'core',destination:'Core'}}/>);
 await waitFor(()=>expect(state.event).toBeTypeOf('function'));
 await waitFor(()=>expect(view.container.querySelector('.st-working')).not.toBeNull());
 state.event!({type:'text_delta',data:{content:''}});
 expect(view.container.querySelector('.st-working')).not.toBeNull();
 state.event!({type:'thinking',data:{content:'Checking the requested model.',done:true}});
 state.event!({type:'tool_call',data:{tool_call_id:'partial-tool',name:'read',args:{}}});
 state.event!({type:'text_delta',data:{content:'I am'}});
 mission.status='awaiting_user';
 state.event!({type:'mission_status_changed',data:{status:'awaiting_user'}});
 await waitFor(()=>expect(view.container.querySelector('.st-working')).toBeNull());
 // Durable history lags the terminal status, and the live final never arrives.
 expect(screen.queryByText('I am Gemini inside Antigravity.')).toBeNull();
 complete=true;
 await poll!();
 await waitFor(()=>expect(screen.getByText('I am Gemini inside Antigravity.')).toBeDefined());
 expect(screen.queryByText('I am', {exact:true})).toBeNull();
 pollSpy.mockRestore();
 expect(view.container.querySelector('.agent-wait-status')).toBeNull();
});

it.each(['job end', 'mission status'] as const)('clears startup progress on %s without waiting for transcript output',async ending=>{
 const polling=await import('../src/poll');
 let poll:undefined|(()=>void|Promise<unknown>);
 const pollSpy=vi.spyOn(polling,'pollWhileVisible').mockImplementation((run,ms)=>{if(ms===10000)poll=run;return ()=>{};});
 try {
  const id=`startup-progress-${ending}`;
  let mission:Mission={id,backend:'opencode',status:'starting',remote_node_id:'ashur',history:[],created_at:'',updated_at:''};
  const {getMission}=await import('../src/api');
  vi.mocked(getMission).mockImplementation(async()=>({...mission}));
  vi.stubGlobal('fetch',vi.fn(async()=>Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}})));
  const view=render(()=><NativeMissionView id={id} initial={mission}/>);
  await waitFor(()=>expect(state.event).toBeTypeOf('function'));
  // HTTP accepted the prompt, but its canonical user_message and every output
  // event were missed. Replaying that receipt must not keep a settled run alive.
  state.event!({type:'user_message',data:{id:'accepted-prompt',content:'Inspect the workspace',receipt:true,at:new Date(Date.now()-26_400_000).toISOString()}});
  await waitFor(()=>expect(view.container.querySelector('.st-working')?.textContent).toContain('Starting OpenCode on ashur'));
  expect(view.container.querySelector('.st-working-time')?.textContent).toBe('7 h 20');
  const bubble=view.container.querySelector('.user');
  if(ending==='job end'){
   mission={...mission,remote_job:{phase:'finished',node_state:'succeeded',finished_at:new Date().toISOString()}};
   await poll!();
  }else{
   mission={...mission,status:'awaiting_user'};
   state.event!({type:'mission_status_changed',data:{status:'awaiting_user'}});
  }
  await waitFor(()=>expect(view.container.querySelector('.st-working')).toBeNull());
  expect(view.container.querySelector('.agent-wait-status')).toBeNull();
  expect(view.container.querySelector('.user')).toBe(bubble);
  expect(screen.getAllByText('Inspect the workspace')).toHaveLength(1);
 } finally {pollSpy.mockRestore();}
});

it.each([['edits in place on a current Core',false],['preserves the original queue when an older Core rejects atomic editing',true]] as const)('%s, without leaving a duplicate Sending… row',async(_name,oldCore)=>{
 const {getMission,sendMissionMessage}=await import('../src/api');
 vi.mocked(sendMissionMessage).mockClear();
 vi.mocked(getMission).mockResolvedValue({id:'edit-remote-queued',status:'active',history:[],created_at:'',updated_at:''});
 let rows=[{id:'orig-msg',mission_id:'edit-remote-queued',content:'Original queued text',source:'remote-queue'}];
 vi.mocked(sendMissionMessage).mockImplementation(async(_id,text,_attachments,clientMessageId)=>{
  const id=clientMessageId??'generated-id';
  rows=[...rows,{id,mission_id:'edit-remote-queued',content:text,source:'remote-queue'}];
  return {id,queued:true};
 });
 vi.stubGlobal('fetch',vi.fn(async(url,options)=>{
  const u=String(url);
  if(options?.method==='PATCH'){
   if(oldCore)return new Response('Method Not Allowed',{status:405});
   const editedId=decodeURIComponent(u.split('/').pop()??'');
   const {content}=JSON.parse(String(options.body));
   rows=rows.map(r=>r.id===editedId?{...r,content}:r);
   return Response.json({ok:true,id:editedId,content});
  }
  if(options?.method==='DELETE'){
   const deletedId=decodeURIComponent(u.split('/').pop()??'');
   rows=rows.filter(r=>r.id!==deletedId);
   return Response.json({ok:true});
  }
  if(u.includes('/queue?'))return Response.json(rows);
  return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
 }));
 const view=render(()=><NativeMissionView id="edit-remote-queued" initial={{id:'edit-remote-queued',status:'active',history:[],created_at:'',updated_at:''}}/>);
 await waitFor(()=>expect(view.container.querySelector('.scroll .col')).not.toBeNull());
 await waitFor(()=>expect(screen.getAllByText('Original queued text')).toHaveLength(1));
 const {fireEvent}=await import('@solidjs/testing-library');
 await fireEvent.click(screen.getByRole('button',{name:'Edit queued message: Original queued text'}));
 const input=screen.getByPlaceholderText('Send follow-up') as HTMLTextAreaElement;
 expect(input.value).toBe('Original queued text');
 fireEvent.input(input,{target:{value:'Edited queued text'}});
 fireEvent.keyDown(input,{key:'Enter'});
 await waitFor(()=>expect(vi.mocked(fetch).mock.calls.filter(([,options])=>options?.method==='PATCH')).toHaveLength(1));
 expect(screen.queryByText('Sending…')).toBeNull();
 expect(screen.getByText('1 Queued')).toBeTruthy();
  if(oldCore){
   await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('405'));
   await waitFor(()=>expect(input.value).toBe('Edited queued text'));
   expect(screen.getAllByText('Original queued text')).toHaveLength(1);
   expect(rows).toEqual([{id:'orig-msg',mission_id:'edit-remote-queued',content:'Original queued text',source:'remote-queue'}]);
  }else{
  await waitFor(()=>expect(screen.getAllByText('Edited queued text')).toHaveLength(1));
  expect(screen.queryByText('Original queued text')).toBeNull();
 }
  expect(rows.map(r=>r.id)).toEqual(['orig-msg']);
  expect(vi.mocked(fetch).mock.calls.filter(([,options])=>options?.method==='DELETE')).toEqual([]);
  expect(sendMissionMessage).not.toHaveBeenCalled();
 });

 it('updates a queued row in place when another tab edits it',async()=>{
  const {getMission}=await import('../src/api');
  vi.mocked(getMission).mockResolvedValue({id:'cross-tab-edit',status:'active',history:[],created_at:'',updated_at:''});
  vi.stubGlobal('fetch',vi.fn(async(url)=>{
   if(String(url).includes('/queue?'))return Response.json([{id:'q1',mission_id:'cross-tab-edit',content:'draft one',source:'remote-queue'}]);
   return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
  }));
  const view=render(()=><NativeMissionView id="cross-tab-edit" initial={{id:'cross-tab-edit',status:'active',history:[],created_at:'',updated_at:''}}/>);
  await waitFor(()=>expect(state.event).toBeTypeOf('function'));
  await screen.findByText('draft one');
  const node=view.container.querySelector('.queue-item');
  state.event!({type:'user_message',data:{id:'q1',content:'edited in tab A',queued:true,source:'remote-queue'}});
  await waitFor(()=>expect(screen.getAllByText('edited in tab A')).toHaveLength(1));
  expect(screen.queryByText('draft one')).toBeNull();
  expect(screen.getByText('1 Queued')).toBeTruthy();
  expect(view.container.querySelector('.queue-item')).toBe(node);
 });

it('allows rapidly stacking multiple follow-up messages while earlier sends are still in flight',async()=>{
 const {getMission,sendMissionMessage}=await import('../src/api');
 vi.mocked(getMission).mockResolvedValue({id:'stack-busy',status:'active',history:[],created_at:'',updated_at:''});
 const resolvers:Array<(val:{id:string;queued:boolean})=>void>=[];
 const sentIds:string[]=[];
 vi.mocked(sendMissionMessage).mockImplementation((_id,_text,_attachments,clientMessageId)=>{
  const id=clientMessageId??'gen';
  sentIds.push(id);
  return new Promise(resolve=>{resolvers.push(()=>resolve({id,queued:true}));});
 });
 vi.stubGlobal('fetch',vi.fn(async(url)=>{
  if(String(url).includes('/queue?'))return Response.json([]);
  return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
 }));
 render(()=><NativeMissionView id="stack-busy" initial={{id:'stack-busy',status:'active',history:[],created_at:'',updated_at:''}}/>);
 const input=screen.getByPlaceholderText('Send follow-up') as HTMLTextAreaElement;
 const {fireEvent}=await import('@solidjs/testing-library');
 // Rapidly send 3 messages without waiting for the network
 for(const msg of ['First rapid message','Second rapid message','Third rapid message']){
  expect(input.readOnly).toBe(false);
  fireEvent.input(input,{target:{value:msg}});
  fireEvent.keyDown(input,{key:'Enter'});
  expect(input.value).toBe('');
 }
 // All 3 appear immediately in the queue in chronological order
 await screen.findByText('3 Queued');
 const texts=Array.from(document.querySelectorAll('.queue-text')).map(el=>el.textContent);
 expect(texts).toEqual(['First rapid message','Second rapid message','Third rapid message']);
 // Drain serialized sends one by one
 await waitFor(()=>expect(resolvers).toHaveLength(1));
 resolvers[0]({id:sentIds[0],queued:true});
 await waitFor(()=>expect(resolvers).toHaveLength(2));
 resolvers[1]({id:sentIds[1],queued:true});
 await waitFor(()=>expect(resolvers).toHaveLength(3));
 resolvers[2]({id:sentIds[2],queued:true});
 await screen.findByText('3 Queued');
 await waitFor(()=>expect(screen.queryByText('Sending…')).toBeNull());
 const confirmedTexts=Array.from(document.querySelectorAll('.queue-text')).map(el=>el.textContent);
 expect(confirmedTexts).toEqual(['First rapid message','Second rapid message','Third rapid message']);
});

it('never leaks an in-flight Send now retry to another mission when the selected mission changes',async()=>{
 const {getMission,sendMissionMessage}=await import('../src/api');
 const [missionId,setMissionId]=createSignal('mission-origin');
 vi.mocked(getMission).mockImplementation(async(id)=>({
  id,
  status:id==='mission-origin'?'active':'completed',
  history:[],
  created_at:'',
  updated_at:'',
 }));
 const sentTargets:string[]=[];
 let finishSendNow!:(response:Response)=>void;
 const sendNowGate=new Promise<Response>(resolve=>{finishSendNow=resolve;});
 const cancelRequests:string[]=[];
 vi.mocked(sendMissionMessage).mockImplementation(async(id,_text,_attachments,clientMessageId)=>{
  sentTargets.push(id);
  return {id:clientMessageId??'msg',queued:true};
 });
 vi.stubGlobal('fetch',vi.fn(async(url,options)=>{
  const u=String(url);
  if(u.includes('/send-now')&&options?.method==='POST')return sendNowGate;
  if(u.endsWith('/cancel')&&options?.method==='POST'){
   cancelRequests.push(u);
   return Response.json({ok:true});
  }
  if(options?.method==='DELETE')return Response.json({ok:true});
  if(u.includes('/queue?'))return Response.json([{id:'q-1',mission_id:'mission-origin',content:'Do not leak this prompt',source:'remote-queue'}]);
  return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
 }));
 render(()=><NativeMissionView id={missionId()} initial={{id:missionId(),status:'active',history:[],created_at:'',updated_at:''}}/>);
 await screen.findByText('Do not leak this prompt');
 const {fireEvent}=await import('@solidjs/testing-library');
 await fireEvent.click(screen.getByRole('button',{name:'Send now: Do not leak this prompt'}));
 await waitFor(()=>expect(fetch).toHaveBeenCalledWith(expect.stringContaining('/send-now'),expect.anything()));
 setMissionId('mission-unrelated');
 finishSendNow(Response.json({ok:true,delivered:false}));
 await new Promise(r=>setTimeout(r,50));
 expect(cancelRequests).toEqual([]);
 expect(sentTargets).not.toContain('mission-unrelated');
 expect(sentTargets).toEqual([]);
});




it('keeps one continuous Sending → Working state through a Send now stop',async()=>{
 const {getMission}=await import('../src/api');
 const {endHandoff}=await import('../src/missionStatus');
 let current:Mission={id:'handoff',status:'active',history:[],created_at:'',updated_at:'1',remote_job:{job_id:'old',node_id:'nippur',phase:'running',node_state:'running'}};
 vi.mocked(getMission).mockImplementation(async()=>current);
 let rows=[{id:'promote-me',mission_id:'handoff',content:'Do this now',source:'remote-queue'}];
 vi.stubGlobal('fetch',vi.fn(async(url,options)=>{
  const u=String(url);
  if(u.includes('/send-now')&&options?.method==='POST'){rows=[];return Response.json({ok:true,delivered:false,promoted:true});}
  if(u.includes('/queue?'))return Response.json(rows);
  return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
 }));
 const view=render(()=><NativeMissionView id="handoff" initial={current}/>);
 const {fireEvent}=await import('@solidjs/testing-library');
 await screen.findByRole('button',{name:'Send now: Do this now'});
 await fireEvent.click(screen.getByRole('button',{name:'Send now: Do this now'}));
 // Same batch: the message is in the transcript, marked as sending.
 const bubble=()=>[...view.container.querySelectorAll('.scroll .user')].find(node=>node.textContent?.includes('Do this now'));
 expect(bubble()?.classList.contains('sending')).toBe(true);
 const workingRow=()=>view.container.querySelector('.st-working')?.textContent??'';
 await waitFor(()=>expect(workingRow()).toMatch(/^Sending on /));
 // Core stops the old turn: interrupted, old job finished.
 current={...current,status:'interrupted',updated_at:'2',remote_job:{job_id:'old',node_id:'nippur',phase:'finished',node_state:'cancelled'}};
 state.event!({type:'mission_status_changed',data:{status:'interrupted'}});
 await waitFor(()=>expect(view.container.querySelector('.send.stop')).not.toBeNull());
 await new Promise(resolve=>setTimeout(resolve,50));
 expect(screen.queryByText('Mission interrupted')).toBeNull();
 expect(view.container.querySelector('.send.stop')).not.toBeNull();
 expect(workingRow()).toMatch(/^Sending on /);
 expect(bubble()?.classList.contains('sending')).toBe(true);
 // The promoted message starts the new turn.
 current={...current,status:'active',updated_at:'3',remote_job:{job_id:'new',node_id:'nippur',phase:'running',node_state:'running'}};
 state.event!({type:'mission_status_changed',data:{status:'active'}});
 await waitFor(()=>expect(workingRow()).toMatch(/^Working on /));
 expect(bubble()?.classList.contains('sending')).toBe(false);
 expect(screen.queryByText('Mission interrupted')).toBeNull();
 endHandoff('handoff');
});

it('shows one Working on This computer… line for local Antigravity runs without duplicate AgentActivity status rows',async()=>{
 const {getMission}=await import('../src/api');
 const {localActivities}=await import('../src/localAgents');
 const localMission:Mission={id:'local-agy',backend:'antigravity',status:'active',placement_kind:'client',tags:['placement:client'],history:[{role:'user',content:'Hello'}],created_at:'',updated_at:''};
 vi.mocked(getMission).mockImplementation(async()=>localMission);
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}})));
 const host=window as any,prevInternal=host.__TAURI_INTERNALS__,prevTauri=host.__TAURI__;
 host.__TAURI__={core:{Channel:class{onmessage=(_v:any)=>{};}}};
 const activities=[{id:'antigravity:status',kind:'status',label:'Working…',done:false,failed:false,started_at:Date.now()-9000,updated_at:Date.now(),detail:'Displayed thought summaries are read from this native conversation when available.'}];
 host.__TAURI_INTERNALS__={invoke:async(cmd:string,args?:any)=>{
  if(cmd==='local_bindings_subscribe'){args?.onEvent?.onmessage({revision:1,bindings:{'local-agy':{harness:'antigravity',bin:'agy',cwd:'/tmp'}}});return 1;}
  if(cmd==='local_bindings_refresh')return {revision:1,bindings:{'local-agy':{harness:'antigravity',bin:'agy',cwd:'/tmp'}}};
  if(cmd==='local_agents_poll')return {text:'',done:false,resumed:false,activities};
  if(cmd==='local_agents_subscribe'){args?.onEvent?.onmessage({text:'',reset:false,activities});return 1;}
  return null;
 }};
 let unmount=()=> {};
 try{
  const view=render(()=><NativeMissionView id="local-agy" initial={localMission}/>);
  unmount=view.unmount;
  await waitFor(()=>expect(localActivities('local-agy')).toHaveLength(1));
  await waitFor(()=>expect(view.container.querySelector('.st-working')?.textContent).toMatch(/^Working on This computer…/));
  expect(view.container.querySelector('.agent-activity')).toBeNull();
  expect(screen.queryByText(/Waiting for thought summaries/)).toBeNull();
  expect(view.container.querySelector('.scroll .user')?.classList.contains('pending')).toBe(true);
 }finally{
  unmount();
  window.dispatchEvent(new Event('pagehide'));
  host.__TAURI_INTERNALS__=prevInternal;host.__TAURI__=prevTauri;
 }
});

it('starts sidebar/folder handoff immediately on follow-up keypress and clears cleanly on failure',async()=>{
 const {sendMissionMessage,getMission}=await import('../src/api');
 const {missionActivity,missionHandoff,presentedStatus,endHandoff}=await import('../src/missionStatus');
 const {folderActivity}=await import('../src/FolderActivity');
 const idleMission:Mission={
  id:'idle-optimistic',
  project:'verity-core',
  folder:'audits',
  status:'completed',
  history:[],
  created_at:'',
  updated_at:'1',
  remote_job:{job_id:'old-turn',node_id:'ashur',phase:'finished',node_state:'succeeded',finished_at:'2026-11-08T00:00:00Z'},
 };
 vi.mocked(getMission).mockResolvedValue(idleMission);
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}})));
 let rejectSend!:(err:Error)=>void;
 vi.mocked(sendMissionMessage).mockImplementationOnce(()=>new Promise((_resolve,reject)=>{rejectSend=reject;}));
 const view=render(()=><NativeMissionView id="idle-optimistic" initial={idleMission}/>);
 const input=screen.getByPlaceholderText('Send follow-up') as HTMLTextAreaElement;
 const {fireEvent}=await import('@solidjs/testing-library');
 fireEvent.input(input,{target:{value:'Start turn 2 right away'}});
 fireEvent.keyDown(input,{key:'Enter'});

 // Synchronously on keypress: handoff is active, sidebar row presents "running", and collapsed folder spins.
 expect(missionHandoff('idle-optimistic')).not.toBeNull();
 expect(presentedStatus(idleMission,missionActivity(idleMission))).toBe('running');
 expect(folderActivity([idleMission]).get('verity-core')?.get('audits')).toBe(1);
 expect(view.container.querySelector('.user')?.textContent).toContain('Start turn 2 right away');

 // If the send request fails, handoff ends immediately so sidebar & composer restore real state.
 await waitFor(()=>expect(rejectSend).toBeTypeOf('function'));
 rejectSend(new Error('Network dropped'));
 await waitFor(()=>expect(screen.getByRole('button',{name:'Retry'})).toBeDefined());
 expect(missionHandoff('idle-optimistic')).toBeNull();
 expect(presentedStatus(idleMission,missionActivity(idleMission))).toBe('completed');
 expect(folderActivity([idleMission]).get('verity-core')).toBeUndefined();
 endHandoff('idle-optimistic');
});

it('mounts MissionView immediately without skeleton wait when initial mission record is already known',async()=>{
 const {MissionView}=await import('../src/mission/MissionView');
 const {getMission}=await import('../src/api');
 let resolveMission!:(m:Mission)=>void;
 vi.mocked(getMission).mockImplementationOnce(()=>new Promise<Mission>(resolve=>{resolveMission=resolve;}));
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}})));
 const completedProjectMission:Mission={
  id:'c2dcb8ab-2065-4569-a96d-c7673352125b',
  project:'verity-core',
  status:'completed',
  history:[],
  created_at:'',
  updated_at:'1',
 };
 const view=render(()=><MissionView id={completedProjectMission.id} initial={completedProjectMission}/>);
 // Renders NativeMissionView composer immediately (0 ms) even while getMission is stalled on the network!
 expect(screen.getByPlaceholderText('Send follow-up')).toBeDefined();
 expect(view.container.querySelector('.skeleton-conversation')).toBeNull();
 resolveMission?.(completedProjectMission);
});

it('reconciles missing final output on mount and status poll when reopening a settled mission from a stale recovery snapshot',async()=>{
 const {getMission}=await import('../src/api');
 const {putTranscript,isMissionDirtyWhileUnfocused}=await import('../src/missionCache');
 const {cacheReset}=await import('../src/pageCache');
 const {setMultiplexSyncEnabledForTest}=await import('../src/stream');
 const {buildTranscript}=await import('../src/transcriptModel');
 setMultiplexSyncEnabledForTest(true);
 try{
  cacheReset();
  const id='7fd6aff9-b25a-4e0f-8fd3-88ee366858cd';
  const staleEvents=[
   {type:'user_message' as const,eventId:'u1',sequence:1,data:{id:'u1',content:'Cross-check PPL and India dates',queued:false}},
   {type:'assistant_message' as const,eventId:'e79',sequence:79,data:{id:'e79',content:'Inference connection interrupted',success:false,resumable:true}},
   {type:'user_message' as const,eventId:'u82',sequence:82,data:{id:'u82',content:'[Automatic recovery] Inference connection interrupted stopped your previous turn.',source:'api:usage-limit-replay',queued:false}},
  ];
  putTranscript(id,{items:buildTranscript(staleEvents),stream:staleEvents,fromLog:true,cursor:82});
  expect(isMissionDirtyWhileUnfocused(id)).toBe(false);

  const completedMission:Mission={
   id,
   status:'completed',
   remote_node_id:'ashur',
   history:[],
   created_at:'',
   updated_at:'2',
  };
  vi.mocked(getMission).mockResolvedValue(completedMission);
  const fetchedUrls:string[]=[];
  vi.stubGlobal('fetch',vi.fn(async(input:RequestInfo|URL)=>{
   const url=String(input);
   fetchedUrls.push(url);
   if(url.includes('/queue?'))return Response.json([]);
   if(url.includes(`/missions/${id}/events?`)){
    return new Response(JSON.stringify([
     {
      id:8599000,
      mission_id:id,
      sequence:134,
      event_type:'assistant_message',
      event_id:'a134',
      timestamp:'2026-11-10T18:30:10Z',
      content:'Voici le bilan croisé final.',
      metadata:{success:true},
     },
    ]),{
     status:200,
     headers:{
      'Content-Type':'application/json',
      'X-Orb-Events-Protocol':'1',
      'X-Has-More':'false',
      'X-Next-Cursor':'134',
      'X-Page-Max-Sequence':'134',
      'X-Max-Sequence':'134',
     },
    });
   }
   return Response.json([]);
  }));

  const view=render(()=><NativeMissionView id={id} initial={completedMission}/>);
  await waitFor(()=>expect(screen.getByText('Voici le bilan croisé final.')).toBeDefined());
  expect(fetchedUrls.some(u=>u.includes(`/missions/${id}/events?`)&&u.includes('since_seq=82'))).toBe(true);
  expect(view.container.textContent).not.toContain('The mission completed without transcript output.');
  view.unmount();

  // Also verify poll reconciliation when a prior turn's error item precedes off-screen completion.
  vi.useFakeTimers();
  try{
   cacheReset();
   const pollId='7fd6aff9-poll-error-tail';
   const preRecoveryErrorEvents=staleEvents.slice(0,2);
   putTranscript(pollId,{items:buildTranscript(preRecoveryErrorEvents),stream:preRecoveryErrorEvents,fromLog:true,cursor:79});
   vi.mocked(getMission).mockResolvedValue({...completedMission,id:pollId});
   const pollFetched:string[]=[];
   let allowReply=false;
   vi.stubGlobal('fetch',vi.fn(async(input:RequestInfo|URL)=>{
    const url=String(input);
    pollFetched.push(url);
    if(url.includes('/queue?'))return Response.json([]);
    if(url.includes(`/missions/${pollId}/events?`)){
     const rows=allowReply?[{
      id:8599001,
      mission_id:pollId,
      sequence:134,
      event_type:'assistant_message',
      event_id:'a134-poll',
      timestamp:'2026-11-10T18:30:10Z',
      content:'Recovered synthesis from poll.',
      metadata:{success:true},
     }]:[];
     return new Response(JSON.stringify(rows),{
      status:200,
      headers:{
       'Content-Type':'application/json',
       'X-Orb-Events-Protocol':'1',
       'X-Has-More':'false',
       'X-Next-Cursor':allowReply?'134':'79',
       'X-Page-Max-Sequence':allowReply?'134':'79',
       'X-Max-Sequence':allowReply?'134':'79',
      },
     });
    }
    return Response.json([]);
   }));
   const pollView=render(()=><NativeMissionView id={pollId} initial={{...completedMission,id:pollId}}/>);
   await vi.advanceTimersByTimeAsync(50);
   pollFetched.length=0;
   allowReply=true;
   await vi.advanceTimersByTimeAsync(10_100);
   expect(pollFetched.some(u=>u.includes(`/missions/${pollId}/events?`))).toBe(true);
   expect(pollView.container.textContent).toContain('Recovered synthesis from poll.');
   pollView.unmount();
  }finally{
   vi.useRealTimers();
  }
 }finally{
  setMultiplexSyncEnabledForTest(false);
  cacheReset();
 }
});

it('detaches foreground stream and transcript retention when a keep-alive slot goes inactive and reconciles on return',async()=>{
 const {getMission}=await import('../src/api');
 const {cacheReset}=await import('../src/pageCache');
 const {setBackgroundSyncMode}=await import('../src/backgroundSync');
 const {applyLiveEventsToTranscriptCache,putTranscript,warmRecentMissionIds}=await import('../src/missionCache');
 const {buildTranscript}=await import('../src/transcriptModel');
 cacheReset();
 setBackgroundSyncMode('off');
 state.starts=0;
 state.stops=0;
 try{
  const id='keepalive-slot-m1';
  const mission:Mission={id,status:'completed',history:[],created_at:'',updated_at:'2026-11-11T10:00:00Z'};
  const seed=[
   {type:'user_message' as const,sequence:1,eventId:'u1',data:{id:'u1',content:'Initial prompt'}},
   {type:'assistant_message' as const,sequence:2,eventId:'a1',data:{id:'a1',content:'Initial reply',success:true}},
  ];
  putTranscript(id,{items:buildTranscript(seed),stream:seed,fromLog:true,cursor:2,hasOlder:false,spineComplete:true});
  vi.mocked(getMission).mockResolvedValue(mission);
  vi.stubGlobal('fetch',vi.fn(async()=>Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'2'}})));

  const [current,setCurrent]=createSignal(id);
  const view=render(()=><NativeMissionView id={id} active={current()===id} initial={mission}/>);
  await waitFor(()=>expect(screen.getByText('Initial reply')).toBeDefined());
  expect(state.starts).toBe(1);
  expect(state.stops).toBe(0);
  expect(warmRecentMissionIds()).toContain(id);

  // Hiding the keep-alive slot with Background sync = Off releases foreground retention and stops the stream.
  setCurrent('other-m2');
  await waitFor(()=>expect(state.stops).toBe(1));
  expect(warmRecentMissionIds()).not.toContain(id);

  // Switching between two other missions keeps the hidden slot completely inert.
  setCurrent('other-m3');
  expect(state.starts).toBe(1);
  expect(state.stops).toBe(1);

  // If the transcript cache advances while hidden, reactivating the slot reconciles items and reattaches the stream.
  applyLiveEventsToTranscriptCache(id,[
   {type:'assistant_message',sequence:3,eventId:'a2',data:{id:'a2',content:'Updated while hidden',success:true}},
  ]);
  setCurrent(id);
  await waitFor(()=>expect(screen.getByText('Updated while hidden')).toBeDefined());
  expect(state.starts).toBe(2);
  view.unmount();
 }finally{
  setBackgroundSyncMode('auto');
  cacheReset();
 }
});

it('surfaces Remote job stopped notice even when a pending remote mission also has a queued follow-up (734c3bb7 replay)',async()=>{
 const {getMission}=await import('../src/api');
 const blockedMission:Mission={
  id:'734c3bb7',
  status:'pending',
  backend:'opencode',
  remote_node_id:'ashur',
  remote_job:{
   job_id:'job-failed',
   node_id:'ashur',
   phase:'finished',
   lease_state:'terminal',
   terminal_reason:'remote_dispatch_failed',
   error:'remote node connection failed before the request was sent',
  },
  history:[],
  created_at:'2026-11-10T15:15:49Z',
  updated_at:'2026-11-11T18:46:19Z',
 };
 vi.mocked(getMission).mockResolvedValue(blockedMission);
 vi.stubGlobal('fetch',vi.fn(async(url)=>{
  if(String(url).includes('/queue?')){
   return Response.json([{id:'queued-followup-1',mission_id:'734c3bb7',content:'summarize what you have done so far',source:'remote-queue'}]);
  }
  return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
 }));
 const view=render(()=><NativeMissionView id="734c3bb7" initial={blockedMission}/>);
 await waitFor(()=>expect(screen.getByText('summarize what you have done so far')).toBeDefined());
 await waitFor(()=>expect(view.container.querySelector('.error-notice')).not.toBeNull());
 expect(view.container.textContent).toContain('Remote job stopped');
 expect(view.container.textContent).toContain('remote node connection failed before the request was sent');
 expect(view.container.querySelector('.st-working')).toBeNull();
 view.unmount();
});

it('734c3bb7 view-level sequence: feeding Core-emitted snapshots clears the Starting row and launch/status banner while keeping listed queue rows as Not delivered',async()=>{
 const {getMission}=await import('../src/api');
 const {cacheReset}=await import('../src/pageCache');
 const {setBackgroundSyncMode}=await import('../src/backgroundSync');
 const {putTranscript,warmRecentMissionIds}=await import('../src/missionCache');
 cacheReset();
 setBackgroundSyncMode('off');
 try{
  const id='734c3bb7-view';
  let currentSnap:Mission={
   id,
   backend:'opencode',
   status:'starting',
   run_generation:3,
   state_revision:5,
   remote_node_id:'ashur',
   remote_job:{job_id:'stale-job',node_id:'ashur',phase:'reconnecting',node_state:'reconnecting'},
   history:[],
   created_at:'2026-11-13T11:00:00Z',
   updated_at:'2026-11-13T11:48:00Z',
  };
  let replyLanded=false;
  vi.mocked(getMission).mockImplementation(async()=>({...currentSnap}));
  vi.stubGlobal('fetch',vi.fn(async(url)=>{
   if(String(url).includes('/queue?')){
    return Response.json([{id:'steer-1',mission_id:id,content:'Please stop and summarize',source:'remote-queue'}]);
   }
   if(String(url).includes(`/missions/${id}/events`)){
    const user={id:1,event_id:'u1',sequence:1,event_type:'user_message',timestamp:'2026-11-13T11:00:00Z',content:'Initial prompt',metadata:{queued:false}};
    const assistant={id:2,event_id:'a1',sequence:2,event_type:'assistant_message',timestamp:'2026-11-13T11:05:00Z',content:'Finished summary.',metadata:{success:true}};
    const rows=replyLanded?[user,assistant]:[user];
    const max=String(replyLanded?2:1);
    return Response.json(rows,{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':max,'X-Next-Cursor':max,'X-Page-Max-Sequence':max}});
   }
   return Response.json([]);
  }));
  const [propMission,setPropMission]=createSignal<Mission>(currentSnap);
  const view=render(()=><NativeMissionView id={id} initial={propMission()}/>);
  // Before the terminal snapshot: the Starting row is visible and the queue is plain.
  await waitFor(()=>expect(view.container.querySelector('.st-working')?.textContent).toContain('Starting'));
  expect(screen.getByText('1 Queued')).toBeDefined();

  // A turn ending in awaiting_user with a listed queue row keeps the Queued label
  // and the queue handover (working row stays mounted while Core delivers the row).
  currentSnap={
    id,
    backend:'opencode',
    status:'awaiting_user',
    run_generation:3,
    state_revision:6,
    remote_node_id:'ashur',
    history:[],
    created_at:'2026-11-13T11:00:00Z',
    updated_at:'2026-11-13T11:55:00Z',
  };
  setPropMission({...currentSnap});
  await waitFor(()=>expect(screen.getByText('1 Queued')).toBeDefined());
  expect(screen.queryByText('1 Not delivered')).toBeNull();
  expect(view.container.querySelector('.st-working')).not.toBeNull();

   // Feed the 734c3bb7 completion snapshot from another session (only Core-emitted fields),
   // with the reply that makes the transcript show activity.
   replyLanded=true;
   state.event?.({type:'assistant_message',sequence:2,eventId:'a1',data:{id:'a1',content:'Finished summary.',success:true}});
   currentSnap={
   id,
   backend:'opencode',
   status:'completed',
   terminal_reason:'completed',
   run_generation:3,
   state_revision:9,
   remote_node_id:'ashur',
   history:[],
   created_at:'2026-11-13T11:00:00Z',
   updated_at:'2026-11-13T12:10:00Z',
  };
  setPropMission({...currentSnap});
   // View level: no Starting row, no launch/status banner, and the listed queue row is real, labeled Not delivered.
   await waitFor(()=>expect(view.container.querySelector('.st-working')).toBeNull());
   // Once the reply is in the transcript, the settled phase is quiet: no banner at all.
   await waitFor(()=>expect(view.container.textContent).toContain('Finished summary.'));
   expect(view.container.querySelector('.launch-status')).toBeNull();
   expect(view.container.textContent).not.toMatch(/Starting\b/);
  expect(screen.getByText('1 Not delivered')).toBeDefined();
  expect(screen.getByText('Please stop and summarize')).toBeDefined();
  expect(view.container.textContent).not.toContain('Not sent: the mission ended before Core accepted this message');

  // Feed the stale active snapshot from lower state_revision with a newer updated_at:
  // it is rejected, so the view stays settled.
   setPropMission({
    id,
    backend:'opencode',
    status:'active',
    run_generation:3,
    state_revision:7,
    remote_node_id:'ashur',
    remote_job:{job_id:'stale-job',node_id:'ashur',phase:'reconnecting',node_state:'reconnecting'},
    history:[],
    created_at:'2026-11-13T11:00:00Z',
    updated_at:'2026-11-13T12:19:30Z',
   });
   await waitFor(()=>expect(view.container.querySelector('.st-working')).toBeNull());
   expect(view.container.querySelector('.launch-status')).toBeNull();
   expect(view.container.textContent).not.toMatch(/Starting\b/);
   expect(view.container.textContent).toContain('Finished summary.');
   view.unmount();
 }finally{
  cacheReset();
  setBackgroundSyncMode('auto');
  warmRecentMissionIds().length=0;
 }
});
