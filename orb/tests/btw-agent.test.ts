vi.mock('../src/btwContext',()=>({prepareBtwContext:vi.fn(async(_s:any,context:string)=>({context,cursor:{sequence:10,visibleHash:'hash'}}))}));
import {it,expect,vi,afterEach} from 'vitest';
import {askBtwAgent,btwSession,resetBtwThreadCache,stopBtw,btwTurnEvents} from '../src/btwAgent';
import {startLocal,localBinding} from '../src/localAgents';
import {sideQuestionKey} from '../src/sideQuestionStorage';
vi.mock('../src/localAgents',()=>({localBinding:vi.fn(()=>undefined),restoreLocalBindings:async()=>{},localAgentForLaunch:async()=>({id:'opencode',installed:true,path:'/bin/opencode'}),refreshLocalAgents:async()=>[{id:'opencode',installed:true,path:'/bin/opencode'}],rememberBinding:vi.fn(),startLocal:vi.fn(async()=>({run_id:'run',generation:1})),followLocal:vi.fn(async()=>({text:'Read fixture',done:true,exit_code:0})),stopLocal:vi.fn(),localActivities:()=>[],reconcileLocalRun:vi.fn(async()=>{}),recoverLocalLaunch:vi.fn(async()=>{}),localLiveText:()=> 'Read fixture'}));
import {ApiError,api,getMission,sendMissionMessage,cancelMission} from '../src/api';
vi.mock('../src/api',async original=>({...await original<typeof import('../src/api')>(),api:vi.fn(),getMission:vi.fn(),sendMissionMessage:vi.fn(),cancelMission:vi.fn(),appendClientTranscript:vi.fn(),setClientMissionStatus:vi.fn()}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),streamMission:vi.fn(()=>vi.fn()),getMissionEvents:vi.fn(async()=>[{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}])}));
afterEach(async()=>{resetBtwThreadCache();localStorage.clear();vi.clearAllMocks();const {getMissionEvents,streamMission}=await import('../src/stream');vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}]);vi.mocked(streamMission).mockImplementation(()=>vi.fn());});
it('creates a distinct side agent and never sends to the parent',async()=>{
 vi.mocked(getMission).mockImplementation(async(id)=>({id,status:id==='parent'?'active':'awaiting_user',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'child'});
 const events:any[]=[];
 await askBtwAgent('parent','Inspect the repo','Main context',[],new AbortController().signal,e=>events.push(e));
 expect(api).toHaveBeenCalledWith('/api/control/missions/parent/btw/agent',expect.objectContaining({body:expect.stringContaining('builtin/smart')}));
 // Placement must come from Core, never a pre-transfer local-origin row.
 expect(getMission).toHaveBeenCalledWith('parent',{coreOnly:true});
 expect(btwSession('parent')?.id).toBe('child');expect(events.at(-1).type).toBe('done');expect(sendMissionMessage).not.toHaveBeenCalled();
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValueOnce([]);
 await askBtwAgent('parent','Follow up','New context',[],new AbortController().signal,()=>{});
 expect(sendMissionMessage).toHaveBeenCalledWith('child',expect.stringContaining('New context'),undefined,expect.any(String));
 await stopBtw('parent');expect(cancelMission).toHaveBeenCalledWith('child');
});

it('follows multiple recovered side missions with a fresh sequence boundary',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {getMissionEvents,streamMission}=await import('../src/stream');
 const {watchBtw}=await import('../src/btwAgent');
 localStorage.setItem('agent:'+sideQuestionKey('recovered-parent'),JSON.stringify({id:'old-side',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:999,afterSequence:9000}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'awaiting_user',history:[],tags:id==='old-side'?['superseded_by:middle-side']:id==='middle-side'?['superseded_by:new-side']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'user_message',content:'Q',sequence:1,id:1,timestamp:''},{event_type:'assistant_message',content:'Recovered answer',sequence:2,id:2,timestamp:''}]);
 const events:any[]=[];
 await watchBtw('recovered-parent',new AbortController().signal,event=>events.push(event));
 expect(btwSession('recovered-parent')).toMatchObject({id:'new-side',baseline:0,active:false});
 expect(btwSession('recovered-parent')?.afterSequence).toBeUndefined();
 expect(getMissionEvents).toHaveBeenCalledWith('new-side',expect.objectContaining({enough:expect.any(Function)}));
 expect(streamMission).toHaveBeenCalledWith('new-side',expect.any(Function),expect.any(Function));
 expect(events.at(-1)).toEqual({type:'done',answer:'Recovered answer'});
});

it('reconnects to a replacement and rejects late events from the old stream',async()=>{
 vi.useFakeTimers();
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {getMissionEvents,streamMission}=await import('../src/stream');
 const {watchBtw,btwThoughts}=await import('../src/btwAgent');
 const callbacks=new Map<string,(event:any)=>void>(),disposes=new Map<string,ReturnType<typeof vi.fn>>();
 let replaced=false,finished=false;
 const receive=vi.fn();
 localStorage.setItem('agent:'+sideQuestionKey('stream-parent'),JSON.stringify({id:'old-stream',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0,afterSequence:500}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:finished?'awaiting_user':'active',history:[],tags:id==='old-stream'&&replaced?['superseded_by:new-stream']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockImplementation(async()=>finished?[{event_type:'assistant_message',content:'Final new answer',sequence:1,id:1,timestamp:''}]:[]);
 vi.mocked(streamMission).mockImplementation((id,callback)=>{callbacks.set(id,callback);const dispose=vi.fn();disposes.set(id,dispose);return dispose;});
 const abort=new AbortController();
 const watching=watchBtw('stream-parent',abort.signal,receive);
 try{
  await vi.advanceTimersByTimeAsync(0);
  callbacks.get('old-stream')!({type:'text_delta',data:{content:'Old draft'}});
  callbacks.get('old-stream')!({type:'thinking',data:{content:'Old thought',done:false}});
  replaced=true;
  await vi.advanceTimersByTimeAsync(5000);
  expect(disposes.get('old-stream')).toHaveBeenCalledOnce();
  expect(callbacks.has('new-stream')).toBe(true);
  expect(btwThoughts('stream-parent')).toEqual([]);
  const boundary=receive.mock.calls.length;
  callbacks.get('old-stream')!({type:'text_delta',data:{content:'Late old answer'}});
  expect(receive.mock.calls).toHaveLength(boundary);
  callbacks.get('new-stream')!({type:'text_delta',data:{content:'New draft'}});
  expect(receive).toHaveBeenLastCalledWith({type:'snapshot',text:'New draft',narration:[]});
  finished=true;
  callbacks.get('new-stream')!({type:'mission_status_changed',data:{status:'awaiting_user'}});
  await watching;
  expect(receive).toHaveBeenLastCalledWith({type:'done',answer:'Final new answer'});
  expect(disposes.get('new-stream')).toHaveBeenCalledOnce();
 }finally{abort.abort();await watching.catch(()=>{});vi.useRealTimers();vi.mocked(streamMission).mockImplementation(()=>vi.fn());}
});

it('does not accept the old streamed answer when a replacement completes empty',async()=>{
 vi.useFakeTimers();
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {getMissionEvents,streamMission}=await import('../src/stream');
 const {watchBtw}=await import('../src/btwAgent');
 let replaced=false;
 localStorage.setItem('agent:'+sideQuestionKey('empty-replacement-parent'),JSON.stringify({id:'empty-old',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:replaced?'awaiting_user':'active',history:[],tags:id==='empty-old'&&replaced?['superseded_by:empty-new']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockResolvedValue([]);
 vi.mocked(streamMission).mockImplementation((id,callback)=>{if(id==='empty-old')callback({type:'text_delta',data:{content:'Old answer'}});return vi.fn();});
 const abort=new AbortController();
 const watching=watchBtw('empty-replacement-parent',abort.signal,()=>{});
 const result=expect(watching).rejects.toThrow('No response was captured from the side agent (awaiting_user)');
 try{await vi.advanceTimersByTimeAsync(0);replaced=true;await vi.advanceTimersByTimeAsync(5000);await result;}
 finally{abort.abort();await watching.catch(()=>{});vi.useRealTimers();vi.mocked(streamMission).mockImplementation(()=>vi.fn());}
});

it('refuses cyclic replacement chains without changing the saved session',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {watchBtw}=await import('../src/btwAgent');
 const saved={id:'cycle-old',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0,afterSequence:88};
 localStorage.setItem('agent:'+sideQuestionKey('cycle-parent'),JSON.stringify(saved));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'completed',history:[],tags:[`superseded_by:${id==='cycle-old'?'cycle-new':'cycle-old'}`],title:null,created_at:'',updated_at:''}));
 await expect(watchBtw('cycle-parent',new AbortController().signal,()=>{})).rejects.toThrow('cycle');
 expect(btwSession('cycle-parent')).toEqual(saved);
});

it('preserves a pending replacement after a lookup failure instead of starting another side agent',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const saved={id:'missing-old',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0,afterSequence:88};
 localStorage.setItem('agent:'+sideQuestionKey('missing-parent'),JSON.stringify(saved));
 vi.mocked(getMission).mockImplementation(async id=>{if(id==='missing-new')throw new ApiError(404,'Not found');return {id,status:'completed',history:[],tags:['superseded_by:missing-new'],title:null,created_at:'',updated_at:''};});
 await expect(askBtwAgent('missing-parent','Next','context',[],new AbortController().signal,()=>{})).rejects.toThrow('Recovered side session is unavailable');
 expect(btwSession('missing-parent')).toEqual(saved);
 expect(api).not.toHaveBeenCalled();
 expect(sendMissionMessage).not.toHaveBeenCalled();
});

it('does not save replacement identities after cancellation',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {watchBtw}=await import('../src/btwAgent');
 const abort=new AbortController();
 const saved={id:'cancel-old',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0};
 localStorage.setItem('agent:'+sideQuestionKey('cancel-parent'),JSON.stringify(saved));
 vi.mocked(getMission).mockImplementation(async id=>{if(id==='cancel-new')abort.abort();return {id,status:'completed',history:[],tags:id==='cancel-old'?['superseded_by:cancel-new']:[],title:null,created_at:'',updated_at:''};});
 await expect(watchBtw('cancel-parent',abort.signal,()=>{})).rejects.toThrow('cancelled');
 expect(btwSession('cancel-parent')).toEqual(saved);
});

it('does not save replacement identities after the backend connection changes',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {bumpConnectionVersion}=await import('../src/api');
 const {watchBtw}=await import('../src/btwAgent');
 const saved={id:'connection-old',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0};
 localStorage.setItem('agent:'+sideQuestionKey('connection-parent'),JSON.stringify(saved));
 vi.mocked(getMission).mockImplementation(async id=>{if(id==='connection-new')bumpConnectionVersion(version=>version+1);return {id,status:'completed',history:[],tags:id==='connection-old'?['superseded_by:connection-new']:[],title:null,created_at:'',updated_at:''};});
 await expect(watchBtw('connection-parent',new AbortController().signal,()=>{})).rejects.toThrow('Connection changed');
 expect(btwSession('connection-parent')).toEqual(saved);
});

it('stops the recovered side agent instead of its superseded predecessor',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 localStorage.setItem('agent:'+sideQuestionKey('stop-parent'),JSON.stringify({id:'stop-old',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'active',history:[],tags:id==='stop-old'?['superseded_by:stop-new']:[],title:null,created_at:'',updated_at:''}));
 await stopBtw('stop-parent');
 expect(cancelMission).toHaveBeenCalledWith('stop-new');
});

it('sends a follow-up to the recovered session using its own sequence boundary',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {getMissionEvents}=await import('../src/stream');
 localStorage.setItem('agent:'+sideQuestionKey('follow-parent'),JSON.stringify({id:'follow-old',question:'First',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0,afterSequence:9000,contextVersion:2,conversationCursor:{sequence:10,visibleHash:'hash'},placement:JSON.stringify([false,undefined,undefined,undefined])}));
 let sent=false;
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='follow-parent'?'active':'awaiting_user',history:[],tags:id==='follow-old'?['superseded_by:follow-new']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockImplementation(async()=>sent?[{event_type:'user_message',content:'Next',sequence:2,id:2,timestamp:''},{event_type:'assistant_message',content:'Follow-up answer',sequence:3,id:3,timestamp:''}]:[{event_type:'assistant_message',content:'Earlier recovered answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(sendMissionMessage).mockImplementationOnce(async()=>{sent=true;return {} as any;});
 const receive=vi.fn();
 await askBtwAgent('follow-parent','Next','context',[],new AbortController().signal,receive);
 expect(sendMissionMessage).toHaveBeenCalledWith('follow-new',expect.stringContaining('Next'),undefined,expect.any(String));
 expect(api).not.toHaveBeenCalled();
 expect(btwSession('follow-parent')?.afterSequence).toBe(1);
 expect(receive).toHaveBeenLastCalledWith({type:'done',answer:'Follow-up answer'});
});

it('includes the terminal mission reason when a recovered session has no response',async()=>{
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {getMissionEvents}=await import('../src/stream');
 const {watchBtw}=await import('../src/btwAgent');
 localStorage.setItem('agent:'+sideQuestionKey('reason-parent'),JSON.stringify({id:'reason-old',question:'Q',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'completed',history:[],tags:id==='reason-old'?['superseded_by:reason-new']:[],status_message:'No assistant output recorded',title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockResolvedValue([]);
 await expect(watchBtw('reason-parent',new AbortController().signal,()=>{})).rejects.toThrow('completed: No assistant output recorded');
});
it('a missing agent endpoint fails without falling back to a normal fork',async()=>{
 vi.mocked(getMission).mockResolvedValue({id:'parent',status:'active',history:[],tags:[],title:null,created_at:'',updated_at:''});
 vi.mocked(api).mockRejectedValue(new Error('404'));
 await expect(askBtwAgent('parent','Q','',[],new AbortController().signal,()=>{})).rejects.toThrow('404');
 expect(api).toHaveBeenCalledTimes(1);expect(btwSession('parent')).toBeUndefined();
});

it('launches locally in the parent folder with a fresh session identity',async()=>{
 vi.mocked(localBinding).mockImplementation(id=>id==='local-parent'?{cwd:'/work/shared',harness:'claudecode',bin:'/bin/claude',sessionId:'never-reuse-parent'}:undefined);
 vi.mocked(getMission).mockImplementation(async(id)=>({id,status:id==='local-parent'?'active':'awaiting_user',history:[],tags:id==='local-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'local-child',tags:['placement:client']});
 await askBtwAgent('local-parent','Read this folder','context',[],new AbortController().signal,()=>{});
 expect(startLocal).toHaveBeenCalledWith(expect.objectContaining({id:'local-child',cwd:'/work/shared',harness:'opencode',model:'builtin/smart',sessionId:undefined,sharedCwdWith:'local-parent'}));
});

it('does not turn an empty successful exit into a fabricated answer',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([]);
 vi.mocked(getMission).mockImplementation(async(id)=>({id,status:id==='empty-parent'?'active':'awaiting_user',history:[],tags:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'empty-child'});
 const receive=vi.fn();
 await expect(askBtwAgent('empty-parent','Q','',[],new AbortController().signal,receive)).rejects.toThrow('No response was captured');
 expect(receive.mock.calls.some(([e])=>e.type==='done')).toBe(false);
});

it('never replays the previous answer underneath a new user question',()=>{
 const event=(sequence:number,event_type:string,content:string)=>({id:sequence,sequence,event_type,content,timestamp:''});
 const previous=event(4,'assistant_message','Previous CI answer');
 const next=event(7,'user_message','Explain Proof.lean');
 expect(btwTurnEvents([next,previous],{baseline:0})).toEqual([]);
 const answer=event(8,'assistant_message','Proof.lean is the entry point');
 expect(btwTurnEvents([answer,next,previous],{baseline:0})).toEqual([answer]);
 expect(btwTurnEvents([previous],{baseline:0,afterSequence:6})).toEqual([]);
});
it('advances the parent cursor only after an accepted send and resets it for a new model',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='cursor-parent'?'active':'awaiting_user',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'cursor-child'});
 await askBtwAgent('cursor-parent','Initial','first',[],new AbortController().signal,()=>{});
 expect(btwSession('cursor-parent')?.conversationCursor?.sequence).toBe(10);
 vi.mocked(prepareBtwContext).mockResolvedValueOnce({context:'delta',cursor:{sequence:20,visibleHash:'next'}});
 vi.mocked(sendMissionMessage).mockRejectedValueOnce(new Error('offline'));
 await expect(askBtwAgent('cursor-parent','Next','second',[],new AbortController().signal,()=>{})).rejects.toThrow('offline');
 expect(btwSession('cursor-parent')?.conversationCursor?.sequence).toBe(10);
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toEqual({sequence:10,visibleHash:'hash'});
 localStorage.setItem(sideQuestionKey('settings:btw'),JSON.stringify({harness:'opencode',model:'different'}));
 vi.mocked(api).mockResolvedValue({id:'new-child'});
 await askBtwAgent('cursor-parent','New model','third',[],new AbortController().signal,()=>{});
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toBeUndefined();
});

it('stages context on the committed transfer destination rather than a stale remote job',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='moved-parent'?'active':'awaiting_user',history:[],tags:[],title:'Main',created_at:'',updated_at:'',remote_job:{node_id:'old-node'},machine_transfer:{destination:{kind:'node',id:'new-node'}}} as any));
 vi.mocked(api).mockResolvedValue({id:'moved-child'});
 await askBtwAgent('moved-parent','Q','latest',[],new AbortController().signal,()=>{});
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[2]).toBe('new-node');
});

it('rejects generated empty-output or remote cancellation status notes instead of claiming an answer',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([
  {event_type:'assistant_message',content:"Remote opencode job 00000000-0000-0000-0000-000000000000 on node 'old-agent' finished without assistant text (stop reason: unknown).",sequence:1,id:1,timestamp:''},
  {event_type:'assistant_message',content:"Remote node 'old-agent' job e7c48aba-3101-4c3b-b7ad-1e17dab704dd reached state 'cancelled' (exit None) after the mission left Active (paused); the mission status is preserved. error: cancelled",sequence:2,id:2,timestamp:''},
 ]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='empty-status-parent'?'active':'completed',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'empty-status-child'});
 await expect(askBtwAgent('empty-status-parent','Q','latest',[],new AbortController().signal,()=>{})).rejects.toThrow('No response was captured');
});

it('creates a replacement side mission instead of messaging a failed or superseded-track side mission',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Fresh answer',sequence:1,id:1,timestamp:''}]);
 localStorage.setItem('agent:'+sideQuestionKey('dead-parent'),JSON.stringify({id:'dead-side',question:'First',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0,contextVersion:2,conversationCursor:{sequence:10,visibleHash:'hash'},placement:JSON.stringify([false,'old-agent','/work','ws-1'])}));
 vi.mocked(getMission).mockImplementation(async id=>({
  id,
  status:id==='dead-parent'?'active':id==='dead-side'?'failed':'awaiting_user',
  track:id==='dead-side'?'mission-old-side':undefined,
  remote_node_id:'old-agent',
  working_directory:'/work',
  workspace_id:'ws-1',
  history:[],
  tags:[],
  title:'Main',
  created_at:'',
  updated_at:'',
 } as any));
 vi.mocked(api).mockResolvedValueOnce({id:'fresh-side'});
 const history=[{question:'First',answer:'Earlier answer'}];
 const receive=vi.fn();
 await askBtwAgent('dead-parent','Follow up','delta',history as any,new AbortController().signal,receive);
 expect(sendMissionMessage).not.toHaveBeenCalled();
 expect(api).toHaveBeenCalledWith('/api/control/missions/dead-parent/btw/agent',expect.anything());
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toBeUndefined();
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[4]).toEqual(history);
 expect(btwSession('dead-parent')?.id).toBe('fresh-side');
});

it('replaces an explicitly refused side session only through the btw route and rearchives side history',async()=>{
 const {ApiError}=await import('../src/api');
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Status answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='replace-parent'?'active':'completed',history:[],tags:id==='replace-parent'?[]:['btw-parent:replace-parent'],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValueOnce({id:'old-side'}).mockResolvedValueOnce({id:'new-side'});
 await askBtwAgent('replace-parent','Initial','first',[],new AbortController().signal,()=>{});
 vi.mocked(sendMissionMessage).mockRejectedValueOnce(new ApiError(409,'REMOTE_RESUME_REQUIRES_REPLACEMENT: no session'));
 const history=[{question:'Initial',answer:'Prior answer'}];
 await askBtwAgent('replace-parent','Status now?','delta',history as any,new AbortController().signal,()=>{});
 expect(btwSession('replace-parent')?.id).toBe('new-side');
 expect(vi.mocked(api).mock.calls.every(([path])=>path==='/api/control/missions/replace-parent/btw/agent')).toBe(true);
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toBeUndefined();
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[4]).toEqual(history);
 expect(JSON.parse(vi.mocked(api).mock.calls.at(-1)![1]!.body as string).side_context_mode).toBe('incremental');
});

it('finishes a local side response without waiting for Core to persist terminal status',async()=>{
 vi.mocked(localBinding).mockImplementation(id=>id==='native-parent'?{cwd:'/work/shared',harness:'opencode',bin:'/bin/opencode'}:undefined);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'active',history:[],tags:id==='native-parent'?['placement:client']:[],created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'native-child',tags:['placement:client']});
 const receive=vi.fn();
 await askBtwAgent('native-parent','Q','context',[],new AbortController().signal,receive);
 expect(receive).toHaveBeenCalledWith({type:'done',answer:'Read fixture'});
 expect(btwSession('native-parent')?.active).toBe(false);
});


it('reconciles a restored local side run before subscribing',async()=>{
 const {reconcileLocalRun,followLocal}=await import('../src/localAgents');
 vi.mocked(localBinding).mockImplementation(id=>id==='recovery-parent'?{cwd:'/work/shared',harness:'claudecode',bin:'/bin/claude'}:undefined);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='recovery-parent'?'active':'awaiting_user',history:[],tags:id==='recovery-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'recovery-child',tags:['placement:client']});
 await askBtwAgent('recovery-parent','Check progress','context',[],new AbortController().signal,()=>{});
 expect(reconcileLocalRun).toHaveBeenCalledWith('recovery-child');
 expect(vi.mocked(reconcileLocalRun).mock.invocationCallOrder.at(-1)).toBeLessThan(vi.mocked(followLocal).mock.invocationCallOrder.at(-1)!);
});

it('reports remote capacity waits instead of pretending the side agent is answering', async()=>{
 const {btwQueueStatus}=await import('../src/btwAgent');
 expect(btwQueueStatus({status:'active',remote_job:{node_id:'old-agent',node_state:'queued'}} as any)).toBe('Waiting for capacity on old-agent…');
 expect(btwQueueStatus({status:'active',remote_job:{node_id:'old-agent',node_state:'running'}} as any)).toBe('');
 expect(btwQueueStatus({status:'pending'} as any)).toBe('Waiting to start…');
 expect(btwQueueStatus({status:'paused'} as any)).toBe('Side agent paused');
});

it.each(['pending','waiting_background','paused'])('does not create another side agent when a stale local flag hides a %s session',async(status)=>{
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='stale-parent'?'active':'awaiting_user',history:[],tags:[],created_at:'',updated_at:''}));
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'First answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(api).mockResolvedValue({id:'stale-child'});
 await askBtwAgent('stale-parent','First','',[],new AbortController().signal,()=>{});
 expect(btwSession('stale-parent')?.active).toBe(false);
 vi.mocked(getMission).mockImplementation(async id=>({id,status,history:[],tags:[],created_at:'',updated_at:''}));
 vi.mocked(api).mockClear();
 await expect(askBtwAgent('stale-parent','Second','',[],new AbortController().signal,()=>{})).rejects.toThrow('still running');
 expect(api).not.toHaveBeenCalled();
});

it('replaces a deleted saved side mission without hiding other lookup errors',async()=>{
 const {ApiError}=await import('../src/api');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='deleted-parent'?'active':'awaiting_user',history:[],tags:[],created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'deleted-child'});
 await askBtwAgent('deleted-parent','First','',[],new AbortController().signal,()=>{});
 vi.mocked(getMission).mockRejectedValueOnce(new ApiError(500,'Unavailable'));
 await expect(askBtwAgent('deleted-parent','Next','',[],new AbortController().signal,()=>{})).rejects.toThrow('500');
 expect(btwSession('deleted-parent')?.id).toBe('deleted-child');
 vi.mocked(getMission).mockRejectedValueOnce(new ApiError(404,'Not found'));
 vi.mocked(api).mockResolvedValue({id:'replacement-child'});
 await askBtwAgent('deleted-parent','Next','',[],new AbortController().signal,()=>{});
 expect(btwSession('deleted-parent')?.id).toBe('replacement-child');
 expect(sendMissionMessage).not.toHaveBeenCalled();
});

it('rotates rejected content keys but retains uncertain launch keys',async()=>{
 const {ApiError}=await import('../src/api');
 vi.mocked(getMission).mockResolvedValue({id:'conflict-parent',status:'active',history:[],tags:[],title:null,created_at:'',updated_at:''});
 const ask=()=>askBtwAgent('conflict-parent','Q','context',[],new AbortController().signal,()=>{});
 const attempt=()=>JSON.parse(vi.mocked(api).mock.calls.at(-1)![1]!.body as string).idempotency_key;
 vi.mocked(api).mockRejectedValueOnce(new Error('network lost'));
 await expect(ask()).rejects.toThrow('network lost');
 const original=attempt();
 vi.mocked(api).mockRejectedValueOnce(new ApiError(409,'This side request key was already used for different launch content; the new question was not sent.'));
 await expect(ask()).rejects.toThrow('different launch content');
 expect(attempt()).toBe(original);
 vi.mocked(api).mockRejectedValueOnce(new Error('network lost again'));
 await expect(ask()).rejects.toThrow('network lost again');
 const fresh=attempt();expect(fresh).not.toBe(original);
 vi.mocked(api).mockRejectedValueOnce(new ApiError(500,'Unavailable'));
 await expect(ask()).rejects.toThrow('Unavailable');
 expect(attempt()).toBe(fresh);
});

it('replays the exact payload after a lost response despite fresh context paths',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='retry-parent'?'active':'awaiting_user',history:[],tags:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Recovered answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(prepareBtwContext).mockResolvedValueOnce({context:'manifest /first',cursor:{sequence:1,visibleHash:'first'}});
 vi.mocked(api).mockRejectedValueOnce(new Error('lost response'));
 await expect(askBtwAgent('retry-parent','Q','context',[],new AbortController().signal,()=>{})).rejects.toThrow('lost response');
 const original=vi.mocked(api).mock.calls.at(-1)![1]!.body;
 vi.mocked(prepareBtwContext).mockResolvedValueOnce({context:'manifest /second',cursor:{sequence:2,visibleHash:'second'}});
 vi.mocked(api).mockResolvedValueOnce({id:'recovered-child'});
 await askBtwAgent('retry-parent','Q','new context',[],new AbortController().signal,()=>{});
 expect(vi.mocked(api).mock.calls.at(-1)![1]!.body).toBe(original);
 expect(btwSession('retry-parent')?.conversationCursor).toEqual({sequence:1,visibleHash:'first'});
});

it('waits for local completion synchronization before admitting a queued follow-up',async()=>{
 const {setClientMissionStatus}=await import('../src/api');
 const {getMissionEvents}=await import('../src/stream');
 let synced=false;let release!:()=>void;
 const pending=new Promise<void>(resolve=>{release=()=>{synced=true;resolve();};});
 vi.mocked(setClientMissionStatus).mockImplementationOnce(()=>pending);
 vi.mocked(localBinding).mockImplementation(()=>({cwd:'/work/shared',harness:'opencode',bin:'/bin/opencode'}));
 vi.mocked(getMissionEvents).mockResolvedValue([]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='sync-parent'?'active':synced?'awaiting_user':'pending',history:[],tags:id==='sync-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'sync-child',tags:['placement:client']});
 await askBtwAgent('sync-parent','First','context',[],new AbortController().signal,()=>{});
 const starts=vi.mocked(startLocal).mock.calls.length;
 const next=askBtwAgent('sync-parent','Next','context',[],new AbortController().signal,()=>{});
 await new Promise(resolve=>setTimeout(resolve,0));
 expect(startLocal).toHaveBeenCalledTimes(starts);
 release();await next;
 expect(startLocal).toHaveBeenCalledTimes(starts+1);
});

it('installs completion synchronization before announcing a restored local run as done',async()=>{
 const {watchBtw}=await import('../src/btwAgent');
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 const {setClientMissionStatus}=await import('../src/api');
 localStorage.setItem('agent:'+sideQuestionKey('restored-parent'),JSON.stringify({id:'restored-child',question:'First',harness:'opencode',model:'builtin/smart',local:true,active:true,baseline:0}));
 let release!:()=>void;
 vi.mocked(getMission).mockImplementationOnce(()=>new Promise(resolve=>{release=()=>resolve({id:'restored-child',status:'pending',history:[],tags:['placement:client'],title:null,created_at:'',updated_at:''});}));
 const events:any[]=[];
 const watching=watchBtw('restored-parent',new AbortController().signal,event=>events.push(event));
 await new Promise(resolve=>setTimeout(resolve,0));
 expect(events.some(event=>event.type==='done')).toBe(false);
 release();await watching;
 expect(setClientMissionStatus).toHaveBeenCalledWith('restored-child','awaiting_user',undefined);
 expect(events.at(-1).type).toBe('done');
});

it('recovers a failed native launch before retrying its pending Core mission',async()=>{
 const {recoverLocalLaunch}=await import('../src/localAgents');
 const {setClientMissionStatus}=await import('../src/api');
 let settled=false;
 vi.mocked(localBinding).mockImplementation(()=>({cwd:'/work/shared',harness:'opencode',bin:'/bin/opencode'}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='failed-launch-parent'?'active':settled?'interrupted':'pending',history:[],tags:id==='failed-launch-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValueOnce({id:'failed-launch-child',tags:['placement:client']}).mockResolvedValueOnce({id:'retry-launch-child',tags:['placement:client']});
 vi.mocked(startLocal).mockRejectedValueOnce(new Error('native launch failed'));
 const ask=()=>askBtwAgent('failed-launch-parent','Q','context',[],new AbortController().signal,()=>{});
 await expect(ask()).rejects.toThrow('native launch failed');
 expect(btwSession('failed-launch-parent')?.launchPending).toBe(true);
 vi.mocked(recoverLocalLaunch).mockRejectedValueOnce(new Error('process still running'));
 await expect(ask()).rejects.toThrow('process still running');
 expect(setClientMissionStatus).not.toHaveBeenCalled();
 vi.mocked(setClientMissionStatus).mockImplementationOnce(async()=>{settled=true;});
 await ask();
 expect(recoverLocalLaunch).toHaveBeenCalledWith('failed-launch-child','failed-launch-parent');
 expect(setClientMissionStatus).toHaveBeenCalledWith('failed-launch-child','interrupted');
 expect(btwSession('failed-launch-parent')?.id).toBe('retry-launch-child');
});

it('reuses a completed side session whose generated track uses the 8-char mission prefix',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 const childId='eee849c1-e696-4ea2-b1af-041f8d239739';
 vi.mocked(getMission).mockImplementation(async id=>({
  id,
  status:id==='verity-parent'?'active':'completed',
  track:id===childId?'mission-eee849c1':'mission-668f26f8',
  tags:id===childId?['btw-parent:verity-parent']:[],
  history:[],
  title:'Verity',
  created_at:'',
  updated_at:'',
 }));
 vi.mocked(api).mockResolvedValueOnce({id:childId});
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'First answer',sequence:1,id:1,timestamp:''}]);
 await askBtwAgent('verity-parent','First question','ctx1',[],new AbortController().signal,()=>{});
 expect(btwSession('verity-parent')?.id).toBe(childId);
 vi.mocked(api).mockClear();
 vi.mocked(getMissionEvents)
  .mockResolvedValueOnce([{event_type:'assistant_message',content:'First answer',sequence:1,id:1,timestamp:''}])
  .mockResolvedValueOnce([{event_type:'user_message',content:'Second question',sequence:2,id:2,timestamp:''},{event_type:'assistant_message',content:'Second answer',sequence:3,id:3,timestamp:''}]);
 vi.mocked(sendMissionMessage).mockResolvedValueOnce({id:'m2',queued:false});
 const events:any[]=[];
 await askBtwAgent('verity-parent','Second question','ctx2',[{question:'First question',answer:'First answer'}],new AbortController().signal,e=>events.push(e));
 expect(sendMissionMessage).toHaveBeenCalledWith(childId,expect.stringContaining('Second question'),undefined,expect.any(String));
 expect(api).not.toHaveBeenCalled();
 expect(events.at(-1)).toEqual({type:'done',answer:'Second answer'});
});

it('reconciles missing completed and active /btw turns from server btw-parent missions',async()=>{
 const {reconcileBtwServerHistory,extractBtwUserQuestion}=await import('../src/btwAgent');
 const {getMissionEvents}=await import('../src/stream');
 expect(extractBtwUserQuestion('<main_conversation_update>\nctx\n</main_conversation_update>\n\nCurrent request:\nwhat’s the status?\nAttachment: /tmp/a.png\n')).toBe('what’s the status?');
 vi.mocked(api).mockImplementation(async(path:string)=>{
  if(path.startsWith('/api/control/missions?tag=')){
   return [
    {id:'m1',status:'completed',created_at:'2026-10-07T12:22:00Z',backend:'opencode',model_override:'builtin/smart',tags:['btw-parent:p1'],history:[],title:null,updated_at:''},
    {id:'m2',status:'completed',created_at:'2026-10-07T14:11:14Z',backend:'opencode',model_override:'builtin/smart',tags:['btw-parent:p1'],history:[],title:null,updated_at:''},
    {id:'m3',status:'completed',created_at:'2026-10-07T14:13:46Z',backend:'opencode',model_override:'builtin/smart',tags:['btw-parent:p1'],history:[],title:null,updated_at:''},
   ] as any;
  }
  return [] as any;
 });
 vi.mocked(getMissionEvents).mockImplementation(async(id:string)=>{
  if(id==='m1')return [{id:1,sequence:1,event_type:'user_message',content:'Header\n\nCurrent request:\nOù en es-tu ?',timestamp:''},{id:2,sequence:2,event_type:'assistant_message',content:'Slice 1 en cours.',timestamp:''}];
  if(id==='m2')return [{id:3,sequence:1,event_type:'user_message',content:'Header\n\nCurrent request:\nwhat’s the status? What’s left to do?',timestamp:''},{id:4,sequence:2,event_type:'assistant_message',content:'Slices 1-3 done, Slice 4 validating.',timestamp:''}];
  if(id==='m3')return [{id:5,sequence:1,event_type:'user_message',content:'Header\n\nCurrent request:\nand it reused what was already started for morpho midnight, right?',timestamp:''},{id:6,sequence:2,event_type:'assistant_message',content:'Yes — branched directly on top of Midnight.',timestamp:''}];
  return [];
 });
 const result=await reconcileBtwServerHistory('p1',[{id:'local-1',question:'Où en es-tu ?',answer:'Slice 1 en cours.'}]);
 expect(result.history.map(h=>h.question)).toEqual([
  'Où en es-tu ?',
  'what’s the status? What’s left to do?',
  'and it reused what was already started for morpho midnight, right?',
 ]);
 expect(btwSession('p1')?.id).toBe('m3');
});

it('completes launching the side session in the background if the UI watch signal aborts during context preparation',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {btwLaunchPending}=await import('../src/btwAgent');
 const watchAbort=new AbortController();
 const launchAbort=new AbortController();
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'active',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(prepareBtwContext).mockImplementationOnce(async()=>{
  watchAbort.abort();
  return {context:'ctx',cursor:{sequence:5,visibleHash:'h5',archive:'.paloma/conversation/1/conversation.json'}};
 });
 vi.mocked(api).mockResolvedValueOnce({id:'bg-child'});
 const p=askBtwAgent('bg-parent','Status?','ctx',[],watchAbort.signal,()=>{},[],launchAbort.signal);
 expect(btwLaunchPending('bg-parent')).toBeTruthy();
 await p;
 expect(btwLaunchPending('bg-parent')).toBeUndefined();
 expect(api).toHaveBeenCalledWith('/api/control/missions/bg-parent/btw/agent',expect.anything());
 expect(btwSession('bg-parent')).toMatchObject({id:'bg-child',question:'Status?',active:true});
});

it('automatically starts a clean side session with preserved history when a reused turn returns an empty completion without running any tools',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMission).mockImplementation(async id=>({
  id,
  status:id==='empty-turn-parent'?'active':'completed',
  tags:id==='empty-turn-parent'?[]:['btw-parent:empty-turn-parent'],
  history:[],
  title:'EV Bench',
  created_at:'',
  updated_at:'',
 }));
 vi.mocked(api).mockResolvedValueOnce({id:'side-1'}).mockResolvedValueOnce({id:'side-2'});
 vi.mocked(getMissionEvents).mockResolvedValueOnce([{event_type:'assistant_message',content:'First turn answer',sequence:1,id:1,timestamp:''}]);
 await askBtwAgent('empty-turn-parent','Turn 1','ctx-1',[],new AbortController().signal,()=>{});
 expect(btwSession('empty-turn-parent')?.conversationCursor).toEqual({sequence:10,visibleHash:'hash'});

 // Turn 2 reuses side-1, finishes with a synthetic empty-response note and 0 tools,
 // and automatically recovers by launching clean side-2 with preserved history.
 vi.mocked(prepareBtwContext)
  .mockResolvedValueOnce({context:'delta-ctx',cursor:{sequence:25,visibleHash:'hash-25'}})
  .mockResolvedValueOnce({context:'fresh-ctx',cursor:{sequence:25,visibleHash:'hash-25'}});
 vi.mocked(getMissionEvents)
  .mockResolvedValueOnce([{event_type:'assistant_message',content:'First turn answer',sequence:1,id:1,timestamp:''}])
  .mockResolvedValueOnce([
   {event_type:'user_message',content:'Turn 2',sequence:2,id:2,timestamp:''},
   {event_type:'assistant_message',content:"Remote opencode job 5c8a6bb1-1f74-4515-8c9e-12a868cfd315 on node 'nippur' finished without assistant text (stop reason: end_turn).",sequence:3,id:3,timestamp:''},
  ])
  .mockResolvedValueOnce([{event_type:'assistant_message',content:'Recovered turn 2 answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(sendMissionMessage).mockResolvedValueOnce({id:'m2',queued:false});
 const history=[{question:'Turn 1',answer:'First turn answer'}];
 const events:any[]=[];
 await askBtwAgent('empty-turn-parent','Turn 2','ctx-2',history as any,new AbortController().signal,e=>events.push(e));
 expect(sendMissionMessage).toHaveBeenCalledTimes(1);
 expect(btwSession('empty-turn-parent')?.id).toBe('side-2');
 expect(btwSession('empty-turn-parent')?.brokenSession).toBeUndefined();
 expect(btwSession('empty-turn-parent')?.conversationCursor).toEqual({sequence:25,visibleHash:'hash-25'});
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toBeUndefined();
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[4]).toEqual(history);
 expect(events).toContainEqual({type:'status',text:'Starting clean side session…'});
 expect(events.at(-1)).toEqual({type:'done',answer:'Recovered turn 2 answer'});
});

it('marks the session broken if a fresh side session also returns an empty completion',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMission).mockImplementation(async id=>({
  id,
  status:id==='empty-fresh-parent'?'active':'completed',
  tags:id==='empty-fresh-parent'?[]:['btw-parent:empty-fresh-parent'],
  history:[],
  title:'EV Bench',
  created_at:'',
  updated_at:'',
 }));
 vi.mocked(api).mockResolvedValueOnce({id:'side-fresh-1'});
 vi.mocked(getMissionEvents).mockResolvedValueOnce([
  {event_type:'user_message',content:'Turn 1',sequence:1,id:1,timestamp:''},
  {event_type:'assistant_message',content:"Remote opencode job 5c8a6bb1-1f74-4515-8c9e-12a868cfd315 on node 'nippur' finished without assistant text (stop reason: end_turn).",sequence:2,id:2,timestamp:''},
 ]);
 await expect(askBtwAgent('empty-fresh-parent','Turn 1','ctx-1',[],new AbortController().signal,()=>{})).rejects.toThrow('The model returned an empty completion without running any tools; retry to start a clean side session.');
 expect(btwSession('empty-fresh-parent')?.brokenSession).toBe(true);
});




it('follows Core placement when a stale local view of a moved parent claims this computer',async()=>{
 const {rememberBinding}=await import('../src/localAgents');
 vi.mocked(localBinding).mockImplementation(()=>({cwd:'/work/shared',harness:'codex',bin:'/bin/codex'}));
 // Offline fallback: the local-origin journal always reports `placement:client`.
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='moved-parent'?'active':'awaiting_user',history:[],tags:id==='moved-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValueOnce({id:'node-side',tags:['btw-parent:moved-parent']});
 await askBtwAgent('moved-parent','Q','context',[],new AbortController().signal,()=>{});
 expect(startLocal).not.toHaveBeenCalled();
 expect(rememberBinding).not.toHaveBeenCalled();
 expect(btwSession('moved-parent')).toMatchObject({id:'node-side',local:false});
});

it('clears a pending native launch for a side session Core never placed on this computer',async()=>{
 const {recoverLocalLaunch}=await import('../src/localAgents');
 const {setClientMissionStatus}=await import('../src/api');
 localStorage.setItem('agent:'+sideQuestionKey('stuck-parent'),JSON.stringify({id:'stuck-side',question:'old',harness:'opencode',model:'builtin/smart',local:true,active:false,baseline:0,launchPending:true}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='stuck-parent'?'active':id==='stuck-side'?'failed':'awaiting_user',history:[],tags:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(recoverLocalLaunch).mockRejectedValueOnce('Could not inspect previous run (409 Conflict): This conversation no longer runs on this computer');
 vi.mocked(api).mockResolvedValueOnce({id:'fresh-side',tags:['btw-parent:stuck-parent']});
 await askBtwAgent('stuck-parent','Q','context',[],new AbortController().signal,()=>{});
 expect(setClientMissionStatus).not.toHaveBeenCalled();
 expect(btwSession('stuck-parent')).toMatchObject({id:'fresh-side',local:false});
 expect(btwSession('stuck-parent')?.launchPending).toBeFalsy();
});

// Side-context archives (btwContext is mocked above; these use the real module).

it("a long conversation is archived in bounded parts without freezing the page", async () => {
  const { archiveParts } = await vi.importActual<typeof import("../src/btwContext")>("../src/btwContext");
  const rows = Array.from({ length: 4000 }, (_, i) => `[${i}] tool_result: ${"é".repeat(1500)}`);
  const written: Record<string, string> = {};
  const started = performance.now();
  const paths = await archiveParts("events.jsonl", rows, async (name, text) => { written[name] = text; return name; });
  expect(performance.now() - started).toBeLessThan(2000);
  expect(paths).toEqual(["events.jsonl.0", "events.jsonl.1"]);
  const encoder = new TextEncoder();
  for (const path of paths) expect(encoder.encode(written[path]).length).toBeLessThanOrEqual(8 * 1024 * 1024);
  expect(paths.map(p => written[p]).join("")).toBe(rows.map(r => r + "\n").join(""));
});

it("one oversized row is split on character boundaries", async () => {
  const { archiveParts } = await vi.importActual<typeof import("../src/btwContext")>("../src/btwContext");
  const written: Record<string, string> = {};
  const paths = await archiveParts("t", ["é".repeat(5 * 1024 * 1024)], async (name, text) => { written[name] = text; return name; });
  expect(paths).toEqual(["t.0", "t.1"]);
  expect(paths.map(p => written[p]).join("")).toBe("é".repeat(5 * 1024 * 1024) + "\n");
  expect(written["t.0"].endsWith("é")).toBe(true);
});

// Side agents stay out of the navigation lists.
it('hides side agents in both navigation lists without hiding their transcript endpoint',async()=>{
 const {listMissions,listProjectMissions,getMission,isBtwMission,setConnection,clearConnection}=await vi.importActual<typeof import('../src/api')>('../src/api');
 setConnection('https://btw.test','test');
 try {
 const parent={id:'parent',title:'Main',project:'verity',tags:[]};
 const side={id:'side',title:'Generated title',project:'verity',tags:['fork-workspace:parent','btw-parent:parent']};
 const fork={id:'fork',project:'verity',tags:['fork-workspace:parent']};
 vi.stubGlobal('fetch',vi.fn(async(url:string)=>Response.json(url.endsWith('/side')?side:[parent,side,fork])));
 expect((await listMissions()).map(m=>m.id)).toEqual(['parent','fork']);
 expect((await listProjectMissions('verity')).map(m=>m.id)).toEqual(['parent','fork']);
 expect(await getMission('side')).toEqual(side);
 expect(isBtwMission({tags:['btw-parent:parent']})).toBe(true);
 expect(isBtwMission({})).toBe(false);
 } finally {clearConnection();vi.unstubAllGlobals();}
});

// Real shapes: d9f08eac seq 181 (opencode, compaction summary recorded before
// the answer) and c83baa5b (Antigravity: canonical narration bubbles, then the
// final assistant_message repeating the last bubble).
const COMPACTED='## Objective\n- Act as the `/btw` side-agent for main mission `3fe5c5a3`.\n\n## Next Move\n1. Check `git status`.\n\n## Relevant Files\n- `evm.fast-dev`: Main repository.\n\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed.\n\nC\'est fait : l\'agent principal a été arrêté proprement.\n\nhttps://github.com/Th0rgal/evm.fast-dev/pull/1';
it('strips a recorded opencode compaction summary from the side answer',async()=>{
 const {sideAnswer,stripCompactionSummary}=await import('../src/btwAgent');
 expect(stripCompactionSummary(COMPACTED)).toBe("C'est fait : l'agent principal a été arrêté proprement.\n\nhttps://github.com/Th0rgal/evm.fast-dev/pull/1");
 expect(sideAnswer([COMPACTED],COMPACTED).answer.startsWith("C'est fait")).toBe(true);
 expect(stripCompactionSummary('## Objective\nA real heading the model wrote.')).toBe('## Objective\nA real heading the model wrote.');
});

it('shows the final message as the answer and folds earlier narration',async()=>{
 const {sideAnswer}=await import('../src/btwAgent');
 const narration=["J'ai créé `BoundedCertificate.lean` et lancé sa vérification. J'attends la fin de la tâche.","J'ai retiré l'import et relancé la vérification."];
 const final='La mission **W1+W3** est terminée (`DONE`).';
 expect(sideAnswer([...narration,final+'\n'],final)).toEqual({answer:final,narration});
 // Without a final message (still streaming), the latest text is the answer.
 expect(sideAnswer(narration)).toEqual({answer:narration[1],narration:[narration[0]]});
});

it('watchBtw separates Antigravity narration bubbles from the final answer',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 const {watchBtw}=await import('../src/btwAgent');
 localStorage.setItem('agent:'+sideQuestionKey('ag-parent'),JSON.stringify({id:'ag-side',question:'Q',harness:'antigravity',model:'gemini',local:false,active:true,baseline:0}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'awaiting_user',history:[],tags:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockResolvedValue([
  {event_type:'user_message',content:'Q',sequence:1,id:1,timestamp:''},
  {event_type:'assistant_message_canonical',content:"J'attends la fin de la tâche.\n",sequence:118,id:2,timestamp:'',metadata:{bubble_id:'antigravity:c:j:85',canonical_from:'text_op',revision:1}},
  {event_type:'assistant_message_canonical',content:'La mission est terminée.\n',sequence:140,id:3,timestamp:'',metadata:{bubble_id:'antigravity:c:j:107',canonical_from:'text_op',revision:26}},
  {event_type:'assistant_message',content:'La mission est terminée.',sequence:141,id:4,timestamp:'',metadata:{success:true}},
 ] as any);
 const events:any[]=[];
 await watchBtw('ag-parent',new AbortController().signal,e=>events.push(e));
 const done=events.at(-1);
 expect(done.type).toBe('done');
 expect(done.answer).toBe('La mission est terminée.');
 expect(done.answer).not.toContain("J'attends");
});

it('reconciled history keeps only the final message as the answer',async()=>{
 const {reconcileBtwServerHistory}=await import('../src/btwAgent');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(api).mockImplementation(async(path:string)=>path.startsWith('/api/control/missions?tag=')?[{id:'oc',status:'completed',created_at:'2026-10-20T17:53:54Z',backend:'opencode',model_override:'builtin/smart',tags:['btw-parent:p-oc'],history:[],title:null,updated_at:''}] as any:[] as any);
 vi.mocked(getMissionEvents).mockImplementation(async()=>[
  {id:1,sequence:132,event_type:'user_message',content:'Header\n\nCurrent request:\ndis lui de s’arrêter',timestamp:''},
  {id:2,sequence:181,event_type:'assistant_message',content:COMPACTED,timestamp:''},
 ] as any);
 const result=await reconcileBtwServerHistory('p-oc',[]);
 expect(result.history[0].answer.startsWith("C'est fait")).toBe(true);
 expect(result.history[0].answer).not.toContain('Continue if you have next steps');
});

// 2026-10-24, /btw b6cf85d2: the network stalled for ~60 s, the send's first
// read hit the 30 s default deadline and WebKit reported "Fetch is aborted".
const aborted=()=>new DOMException('Fetch is aborted','AbortError');
function completedSide(parent:string){
 localStorage.setItem('agent:'+sideQuestionKey(parent),JSON.stringify({id:'side-done',question:'Q1',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0,contextVersion:2,conversationCursor:{sequence:1,visibleHash:'h'},placement:JSON.stringify([false,undefined,undefined,undefined])}));
}
it('resends a side question after an aborted request with the same client message id',async()=>{
 vi.useFakeTimers();
 try{
  completedSide('abort-parent');
  let calls=0;
  vi.mocked(getMission).mockImplementation(async id=>{if(id==='side-done'&&calls++<2)throw aborted();return {id,status:id==='abort-parent'?'active':'completed',history:[],tags:id==='side-done'?['btw-parent:abort-parent']:[],title:null,created_at:'',updated_at:''} as any;});
 vi.mocked(sendMissionMessage).mockRejectedValueOnce(aborted()).mockResolvedValue({id:'m',queued:false} as any);
  const events:any[]=[];
  const run=askBtwAgent('abort-parent','Follow up','ctx',[],new AbortController().signal,e=>events.push(e),[],new AbortController().signal,'turn-1');
  await vi.advanceTimersByTimeAsync(20000);
  await run;
  expect(events).toContainEqual({type:'status',text:'Connection interrupted — retrying…'});
  expect(sendMissionMessage).toHaveBeenCalledTimes(2);
  for(const call of vi.mocked(sendMissionMessage).mock.calls)expect(call[3]).toBe('turn-1');
  expect(events.at(-1).type).toBe('done');
 }finally{vi.useRealTimers();}
});
it('reports a question that never reached Core as not sent once retries are exhausted',async()=>{
 vi.useFakeTimers();
 try{
  completedSide('down-parent');
  vi.mocked(getMission).mockRejectedValue(aborted());
  const run=askBtwAgent('down-parent','Follow up','ctx',[],new AbortController().signal,()=>{},[],new AbortController().signal,'turn-2');
  const outcome=run.catch(e=>e);
  await vi.advanceTimersByTimeAsync(60000);
  const error=await outcome;
  expect(error).toMatchObject({notSent:true,message:'Connection interrupted — your question was not sent. Retry to send it.'});
  expect(getMission).toHaveBeenCalledTimes(6);
  expect(sendMissionMessage).not.toHaveBeenCalled();
 }finally{vi.useRealTimers();vi.mocked(getMission).mockReset();}
});
it('does not resend once Core accepted the question',async()=>{
 completedSide('sent-parent');
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='sent-parent'?'active':'completed',history:[],tags:['btw-parent:sent-parent'],title:null,created_at:'',updated_at:''} as any));
 vi.mocked(sendMissionMessage).mockResolvedValue({id:'m',queued:false} as any);
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValueOnce([]).mockRejectedValue(new Error('agent exploded'));
 const error=await askBtwAgent('sent-parent','Q','ctx',[],new AbortController().signal,()=>{},[],new AbortController().signal,'turn-3').catch(e=>e);
 expect(error.message).toBe('agent exploded');expect(error.notSent).toBeUndefined();
 expect(sendMissionMessage).toHaveBeenCalledTimes(1);
});

it('retries transient poll timeouts inside watchBtw instead of failing an active side question',async()=>{
 vi.useFakeTimers();
 const {RequestTimeoutError}=await import('../src/api');
 const {getMissionEvents}=await import('../src/stream');
 const {watchBtw}=await import('../src/btwAgent');
 localStorage.setItem('agent:'+sideQuestionKey('timeout-parent'),JSON.stringify({id:'timeout-side',question:'Analyze editablePaths',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0}));
 let polls=0;
 vi.mocked(getMission).mockImplementation(async id=>{
  polls++;
  if(polls===1)throw new RequestTimeoutError();
  return {id,status:polls<3?'active':'awaiting_user',history:[],tags:['btw-parent:timeout-parent'],title:null,created_at:'',updated_at:''} as any;
 });
 vi.mocked(getMissionEvents).mockImplementation(async()=>polls<3
  ?[{id:1,sequence:1,event_type:'user_message',content:'Analyze editablePaths',timestamp:''}]
  :[{id:1,sequence:1,event_type:'user_message',content:'Analyze editablePaths',timestamp:''},{id:2,sequence:2,event_type:'assistant_message',content:'Consensus answer ready.',timestamp:''}]);
 const events:any[]=[];
 const abort=new AbortController();
 const watching=watchBtw('timeout-parent',abort.signal,e=>events.push(e));
 try{
  await vi.advanceTimersByTimeAsync(11000);
  await watching;
  expect(events).toContainEqual({type:'status',text:'Connection interrupted — reconnecting…'});
  expect(events.at(-1)).toEqual({type:'done',answer:'Consensus answer ready.'});
  expect(btwSession('timeout-parent')?.active).toBe(false);
 }finally{abort.abort();await watching.catch(()=>{});vi.useRealTimers();}
});

it('reattaches watchBtw when Retry is clicked for the exact question already running on Core',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 localStorage.setItem('agent:'+sideQuestionKey('retry-live-parent'),JSON.stringify({id:'live-side',question:'Analyze editablePaths',harness:'opencode',model:'builtin/smart',local:false,active:false,baseline:0}));
 let calls=0;
 vi.mocked(getMission).mockImplementation(async id=>({id,status:calls++===0?'active':'awaiting_user',history:[],tags:['btw-parent:retry-live-parent'],title:null,created_at:'',updated_at:''} as any));
 vi.mocked(getMissionEvents).mockResolvedValue([{id:1,sequence:1,event_type:'user_message',content:'Analyze editablePaths',timestamp:''},{id:2,sequence:2,event_type:'assistant_message',content:'Finished live answer.',timestamp:''}]);
 const events:any[]=[];
 await askBtwAgent('retry-live-parent','Analyze editablePaths','ctx',[],new AbortController().signal,e=>events.push(e));
 expect(api).not.toHaveBeenCalled();
 expect(sendMissionMessage).not.toHaveBeenCalled();
 expect(events.at(-1)).toEqual({type:'done',answer:'Finished live answer.'});
});

it('memoizes completed /btw threads across polls and discovers newest active threads first',async()=>{
 const {reconcileBtwServerHistory}=await import('../src/btwAgent');
 const {getMissionEvents}=await import('../src/stream');
 const order:string[]=[];
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'active',tags:id==='fork-head'?['fork-of:fork-prev']:[],history:[],title:null,created_at:'',updated_at:''} as any));
 vi.mocked(api).mockImplementation(async(path:string)=>{
  if(path.includes(encodeURIComponent('btw-parent:fork-prev'))){
   return Array.from({length:6},(_,i)=>({id:`old-${i}`,status:'completed',created_at:`2026-10-29T0${i}:00:00Z`,updated_at:`2026-10-29T0${i}:10:00Z`,backend:'opencode',model_override:'builtin/smart',tags:['btw-parent:fork-prev'],history:[],title:null})) as any;
  }
  if(path.includes(encodeURIComponent('btw-parent:fork-head'))){
   return [{id:'live-634505a6',status:'active',created_at:'2026-10-30T05:44:41Z',updated_at:'2026-10-30T05:46:09Z',backend:'opencode',model_override:'builtin/smart',tags:['btw-parent:fork-head'],history:[],title:null}] as any;
  }
  return [] as any;
 });
 vi.mocked(getMissionEvents).mockImplementation(async(id:string)=>{
  order.push(id);
  if(id==='live-634505a6')return [{id:1,sequence:1,event_type:'user_message',content:'Header\n\nCurrent request:\nAnalyze editablePaths',timestamp:'2026-10-30T05:44:43Z'}];
  const idx=Number(id.split('-')[1]);
  return [
   {id:1,sequence:1,event_type:'user_message',content:`Header\n\nCurrent request:\nQ${idx}`,timestamp:`2026-10-29T0${idx}:00:01Z`},
   {id:2,sequence:2,event_type:'assistant_message',content:`A${idx}`,timestamp:`2026-10-29T0${idx}:05:00Z`},
  ];
 });
 const first=await reconcileBtwServerHistory('fork-head',[]);
 expect(order[0]).toBe('live-634505a6');
 expect(first.activeSession).toMatchObject({id:'live-634505a6',question:'Analyze editablePaths',active:true});
 expect(first.history.map(h=>h.question)).toEqual(['Q0','Q1','Q2','Q3','Q4','Q5']);
 order.length=0;
 const second=await reconcileBtwServerHistory('fork-head',first.history);
 // Terminal threads old-0..old-5 stay cached; only active live-634505a6 is re-fetched.
 expect(order).toEqual(['live-634505a6']);
 expect(second.history.map(h=>h.question)).toEqual(['Q0','Q1','Q2','Q3','Q4','Q5']);
 expect(second.activeSession).toMatchObject({id:'live-634505a6',active:true});
});

it('strips newer OpenCode compaction checkpoints without a compaction_continue footer',async()=>{
 const {sideAnswer,stripCompactionSummary}=await import('../src/btwAgent');
 const checkpoint='## Objective\nAnswer the side question.\n\n## Important Details\n- Node babylon.\n\n## Work State\n### Completed\n- Checked logs.\n### Active\n- Verifying.\n### Blocked\n- None.\n\n## Next Move\nSummarize findings.\n\n## Relevant Files\n- `src/main.rs`';
 expect(stripCompactionSummary(checkpoint)).toBe('');
 expect(sideAnswer([checkpoint,'Final verified answer.'],'Final verified answer.')).toEqual({answer:'Final verified answer.',narration:[]});
});

it('ignores metadata.queued user_message events in btwTurnEvents and parseBtwThread',async()=>{
 const {reconcileBtwServerHistory}=await import('../src/btwAgent');
 const {getMissionEvents}=await import('../src/stream');
 const rows=[
  {id:1,sequence:10,event_type:'user_message',content:'Header\n\nCurrent request:\nActive turn question',timestamp:'2026-11-01T00:00:01Z'},
  {id:2,sequence:11,event_type:'assistant_message_canonical',content:'Working through step 1.',timestamp:'2026-11-01T00:00:02Z'},
  {id:3,sequence:12,event_type:'user_message',content:'Header\n\nCurrent request:\nPre-submitted follow-up',timestamp:'2026-11-01T00:00:03Z',metadata:{queued:true}},
  {id:4,sequence:13,event_type:'assistant_message',content:'Active turn final answer.',timestamp:'2026-11-01T00:00:04Z'},
 ] as any;
 expect(btwTurnEvents(rows,{baseline:0}).map(e=>e.sequence)).toEqual([11,12,13]);
 vi.mocked(api).mockImplementation(async(path:string)=>path.startsWith('/api/control/missions?tag=')?[{id:'q-side',status:'active',created_at:'2026-11-01T00:00:00Z',backend:'opencode',model_override:'builtin/smart',tags:['btw-parent:q-parent'],history:[],title:null,updated_at:''}] as any:[] as any);
 vi.mocked(getMissionEvents).mockResolvedValue(rows);
 const reconciled=await reconcileBtwServerHistory('q-parent',[]);
 expect(reconciled.activeSession?.question).toBe('Active turn question');
 expect(reconciled.history).toEqual([]);
});

it('bases every queued follow-up on delivered context so deleting or promoting a predecessor keeps remaining prompts complete',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {queueBtwFollowUp,dropBtwQueuedCursor,replaceBtwUserQuestion}=await import('../src/btwAgent');
 localStorage.setItem('agent:'+sideQuestionKey('q-parent'),JSON.stringify({id:'q-side',question:'First?',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0,conversationCursor:{sequence:5,visibleHash:'h5'}}));
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'active',history:[],tags:id==='q-side'?['btw-parent:q-parent']:[],title:null,created_at:'',updated_at:''} as any));
 vi.mocked(prepareBtwContext)
  .mockResolvedValueOnce({context:'delta 5->8',cursor:{sequence:8,visibleHash:'h8'}})
  .mockResolvedValueOnce({context:'delta 5->12',cursor:{sequence:12,visibleHash:'h12'}});
 vi.mocked(sendMissionMessage)
  .mockResolvedValueOnce({id:'msg-1',queued:true} as any)
  .mockResolvedValueOnce({id:'msg-2',queued:true} as any);
 const first=await queueBtwFollowUp('q-parent','Follow-up one','ctx',[], [],'msg-1');
 expect(first).toMatchObject({id:'msg-1',missionId:'q-side',queued:true,local:false});
 expect(prepareBtwContext).toHaveBeenNthCalledWith(1,expect.anything(),'ctx','core',{sequence:5,visibleHash:'h5'},[],undefined);
 expect(sendMissionMessage).toHaveBeenCalledWith('q-side',expect.stringContaining('Current request:\nFollow-up one'),undefined,'msg-1');
 // Second follow-up also starts from delivered cursor {sequence:5}, so removing msg-1
 // or promoting msg-2 via Send now delivers msg-2 with full 5->12 parent context intact.
 const second=await queueBtwFollowUp('q-parent','Follow-up two','ctx',[], [],'msg-2');
 expect(prepareBtwContext).toHaveBeenNthCalledWith(2,expect.anything(),'ctx','core',{sequence:5,visibleHash:'h5'},[],undefined);
 expect(second.prompt).toContain('<main_conversation_update>\ndelta 5->12\n</main_conversation_update>');
 dropBtwQueuedCursor('q-parent','msg-1');
 expect(btwSession('q-parent')?.queuedCursors?.map(c=>c.id)).toEqual(['msg-2']);
 const edited=replaceBtwUserQuestion(first.prompt,'Edited follow-up one');
 expect(edited).toContain('<main_conversation_update>\ndelta 5->8\n</main_conversation_update>');
 expect(edited).toContain('Current request:\nEdited follow-up one');
 expect(edited).not.toContain('Follow-up one');
});

it('transitions watchBtw from Turn 1 to dequeued Turn 2, merges concurrent queuedCursors, and polls incrementally with since',async()=>{
 vi.useFakeTimers();
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 const {watchBtw,queueBtwFollowUp}=await import('../src/btwAgent');
 localStorage.setItem('agent:'+sideQuestionKey('handoff-parent'),JSON.stringify({id:'handoff-side',question:'First question',harness:'opencode',model:'builtin/smart',local:false,active:true,baseline:0,conversationCursor:{sequence:5,visibleHash:'h5'}}));
 let poll=0;
 vi.mocked(getMission).mockImplementation(async id=>({id,status:poll<2?'active':'completed',history:[],tags:id==='handoff-side'?['btw-parent:handoff-parent']:[],title:null,created_at:'',updated_at:''} as any));
 vi.mocked(prepareBtwContext).mockResolvedValueOnce({context:'delta 5->9',cursor:{sequence:9,visibleHash:'h9'}});
 vi.mocked(sendMissionMessage).mockResolvedValueOnce({id:'msg-2',queued:true} as any);
 const sinceArgs:(number|undefined)[]=[];
 vi.mocked(getMissionEvents).mockImplementation(async(_id,opts)=>{
  sinceArgs.push(opts?.since);
  const step=poll++;
  if(step===0)return [{id:1,sequence:1,event_type:'user_message',content:'Header\n\nCurrent request:\nFirst question',timestamp:'2026-11-01T00:00:01Z'}];
  if(step===1)return [
   {id:2,sequence:2,event_type:'assistant_message',content:'First answer.',timestamp:'2026-11-01T00:00:02Z'},
   {id:3,sequence:3,event_type:'user_message',event_id:'msg-2',content:'Header\n\nCurrent request:\nSecond question',timestamp:'2026-11-01T00:00:03Z'},
  ];
  return [{id:4,sequence:4,event_type:'assistant_message',content:'Second answer.',timestamp:'2026-11-01T00:00:04Z'}];
 });
 const received:any[]=[];
 const abort=new AbortController();
 const watching=watchBtw('handoff-parent',abort.signal,e=>received.push(e));
 try{
  await vi.advanceTimersByTimeAsync(100);
  // Queue msg-2 while watchBtw is already running with its initial session object.
  await queueBtwFollowUp('handoff-parent','Second question','ctx',[],[],'msg-2');
  await vi.advanceTimersByTimeAsync(11000);
  await watching;
  expect(sinceArgs).toEqual([undefined,1,3]);
  expect(received).toContainEqual({type:'turn',question:'Second question',messageId:'msg-2',completed:{question:'First question',answer:'First answer.'}});
  expect(received.at(-1)).toEqual({type:'done',answer:'Second answer.'});
  expect(btwSession('handoff-parent')?.conversationCursor).toEqual({sequence:9,visibleHash:'h9'});
  expect(btwSession('handoff-parent')?.queuedCursors).toBeUndefined();
 }finally{abort.abort();await watching.catch(()=>{});vi.useRealTimers();}
});
