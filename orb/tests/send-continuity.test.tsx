import {afterEach,beforeEach,expect,it,vi} from 'vitest';
import {render,screen,waitFor} from '@solidjs/testing-library';
import {createSignal} from 'solid-js';
import {NativeMissionView} from '../src/App';
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
 await fireEvent.click(screen.getByRole('button',{name:'Cancel'}));
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
 await waitFor(()=>expect(view.container.querySelector('.agent-wait-status')).not.toBeNull());
 state.event!({type:'text_delta',data:{content:''}});
 expect(view.container.querySelector('.agent-wait-status')).not.toBeNull();
 state.event!({type:'thinking',data:{content:'Checking the requested model.',done:true}});
 state.event!({type:'tool_call',data:{tool_call_id:'partial-tool',name:'read',args:{}}});
 state.event!({type:'text_delta',data:{content:'I am'}});
 mission.status='awaiting_user';
 state.event!({type:'mission_status_changed',data:{status:'awaiting_user'}});
 await waitFor(()=>expect(view.container.querySelector('.agent-wait-status')).toBeNull());
 // Durable history lags the terminal status, and the live final never arrives.
 expect(screen.queryByText('I am Gemini inside Antigravity.')).toBeNull();
 complete=true;
 await poll!();
 await waitFor(()=>expect(screen.getByText('I am Gemini inside Antigravity.')).toBeDefined());
 expect(screen.queryByText('I am', {exact:true})).toBeNull();
 pollSpy.mockRestore();
 expect(view.container.querySelector('.agent-wait-status')).toBeNull();
});
