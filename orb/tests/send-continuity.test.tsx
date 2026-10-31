import {afterEach,beforeEach,expect,it,vi} from 'vitest';
import {render,screen,waitFor} from '@solidjs/testing-library';
import {createSignal} from 'solid-js';
import {NativeMissionView} from '../src/mission/MissionView';
import type {Mission} from '../src/api';
beforeEach(()=>{Object.defineProperty(HTMLElement.prototype,'scrollTo',{configurable:true,value:vi.fn()});});
const state=vi.hoisted(()=>({event:undefined as undefined|((event:any)=>void)}));
vi.mock('../src/stream',async()=>({...await vi.importActual('../src/stream'),streamMission:(_id:string,receive:(event:any)=>void)=>{state.event=receive;return ()=>{};}}));
vi.mock('../src/api',async()=>({...await vi.importActual('../src/api'),sendMissionMessage:vi.fn(),getMission:vi.fn(async()=>({id:'accepted',status:'active',history:[],created_at:'',updated_at:''}))}));
afterEach(()=>{vi.unstubAllGlobals();state.event=undefined;});
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

it.each([['edits in place on a current Core',false],['falls back to replace on an older Core',true]] as const)('%s, without leaving a duplicate Sending… row',async(_name,oldCore)=>{
 const {getMission,sendMissionMessage}=await import('../src/api');
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
 await waitFor(()=>{
  expect(screen.getAllByText('Edited queued text')).toHaveLength(1);
  expect(screen.queryByText('Sending…')).toBeNull();
 });
 expect(screen.queryByText('Original queued text')).toBeNull();
 // Same id and the count never changed: one row, never "2 Queued".
 expect(screen.getByText('1 Queued')).toBeTruthy();
 await waitFor(()=>expect(rows.map(r=>r.id)).toEqual(oldCore?[expect.not.stringMatching(/^orig-msg$/)]:['orig-msg']));
 await waitFor(()=>expect(screen.getAllByText('Edited queued text')).toHaveLength(1));
 expect(screen.queryByText('Original queued text')).toBeNull();
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
 const localMission:Mission={id:'local-agy',backend:'antigravity',status:'active',tags:['placement:client'],history:[{role:'user',content:'Hello'}],created_at:'',updated_at:''};
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
