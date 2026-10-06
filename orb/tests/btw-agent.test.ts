vi.mock('../src/btwContext',()=>({prepareBtwContext:vi.fn(async(_s:any,context:string)=>({context,cursor:{sequence:10,visibleHash:'hash'}}))}));
import {it,expect,vi,afterEach} from 'vitest';
import {askBtwAgent,btwSession,stopBtw,btwTurnEvents} from '../src/btwAgent';
import {startLocal,localBinding} from '../src/localAgents';
vi.mock('../src/localAgents',()=>({localBinding:vi.fn(()=>undefined),restoreLocalBindings:async()=>{},localAgentForLaunch:async()=>({id:'opencode',installed:true,path:'/bin/opencode'}),refreshLocalAgents:async()=>[{id:'opencode',installed:true,path:'/bin/opencode'}],rememberBinding:vi.fn(),startLocal:vi.fn(async()=>({run_id:'run',generation:1})),followLocal:vi.fn(async()=>({text:'Read fixture',done:true,exit_code:0})),stopLocal:vi.fn(),localActivities:()=>[],reconcileLocalRun:vi.fn(async()=>{}),recoverLocalLaunch:vi.fn(async()=>{}),localLiveText:()=> 'Read fixture'}));
import {ApiError,api,getMission,sendMissionMessage,cancelMission} from '../src/api';
vi.mock('../src/api',async original=>({...await original<typeof import('../src/api')>(),api:vi.fn(),getMission:vi.fn(),sendMissionMessage:vi.fn(),cancelMission:vi.fn(),appendClientTranscript:vi.fn(),setClientMissionStatus:vi.fn()}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),streamMission:vi.fn(()=>vi.fn()),getMissionEvents:vi.fn(async()=>[{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}])}));
afterEach(async()=>{localStorage.clear();vi.clearAllMocks();const {getMissionEvents,streamMission}=await import('../src/stream');vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}]);vi.mocked(streamMission).mockImplementation(()=>vi.fn());});
it('creates a distinct side agent and never sends to the parent',async()=>{
 vi.mocked(getMission).mockImplementation(async(id)=>({id,status:id==='parent'?'active':'awaiting_user',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'child'});
 const events:any[]=[];
 await askBtwAgent('parent','Inspect the repo','Main context',[],new AbortController().signal,e=>events.push(e));
 expect(api).toHaveBeenCalledWith('/api/control/missions/parent/btw/agent',expect.objectContaining({body:expect.stringContaining('builtin/smart')}));
 expect(btwSession('parent')?.id).toBe('child');expect(events.at(-1).type).toBe('done');expect(sendMissionMessage).not.toHaveBeenCalled();
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValueOnce([]);
 await askBtwAgent('parent','Follow up','New context',[],new AbortController().signal,()=>{});
 expect(sendMissionMessage).toHaveBeenCalledWith('child',expect.stringContaining('New context'));
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
 expect(getMissionEvents).toHaveBeenCalledWith('new-side');
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
  expect(receive).toHaveBeenLastCalledWith({type:'snapshot',text:'New draft'});
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
 expect(sendMissionMessage).toHaveBeenCalledWith('follow-new',expect.stringContaining('Next'));
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
 vi.mocked(api).mockResolvedValue({id:'local-child'});
 await askBtwAgent('local-parent','Read this folder','context',[],new AbortController().signal,()=>{});
 expect(startLocal).toHaveBeenCalledWith(expect.objectContaining({id:'local-child',cwd:'/work/shared',harness:'opencode',model:'builtin/smart',sessionId:undefined}));
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
 vi.mocked(api).mockResolvedValue({id:'native-child'});
 const receive=vi.fn();
 await askBtwAgent('native-parent','Q','context',[],new AbortController().signal,receive);
 expect(receive).toHaveBeenCalledWith({type:'done',answer:'Read fixture'});
 expect(btwSession('native-parent')?.active).toBe(false);
});


it('reconciles a restored local side run before subscribing',async()=>{
 const {reconcileLocalRun,followLocal}=await import('../src/localAgents');
 vi.mocked(localBinding).mockImplementation(id=>id==='recovery-parent'?{cwd:'/work/shared',harness:'claudecode',bin:'/bin/claude'}:undefined);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='recovery-parent'?'active':'awaiting_user',history:[],tags:id==='recovery-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'recovery-child'});
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
 vi.mocked(getMission).mockRejectedValueOnce(new ApiError(503,'Unavailable'));
 await expect(askBtwAgent('deleted-parent','Next','',[],new AbortController().signal,()=>{})).rejects.toThrow('503');
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
 vi.mocked(api).mockRejectedValueOnce(new ApiError(503,'Unavailable'));
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
 vi.mocked(api).mockResolvedValue({id:'sync-child'});
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
 vi.mocked(api).mockResolvedValueOnce({id:'failed-launch-child'}).mockResolvedValueOnce({id:'retry-launch-child'});
 vi.mocked(startLocal).mockRejectedValueOnce(new Error('native launch failed'));
 const ask=()=>askBtwAgent('failed-launch-parent','Q','context',[],new AbortController().signal,()=>{});
 await expect(ask()).rejects.toThrow('native launch failed');
 expect(btwSession('failed-launch-parent')?.launchPending).toBe(true);
 vi.mocked(recoverLocalLaunch).mockRejectedValueOnce(new Error('process still running'));
 await expect(ask()).rejects.toThrow('process still running');
 expect(setClientMissionStatus).not.toHaveBeenCalled();
 vi.mocked(setClientMissionStatus).mockImplementationOnce(async()=>{settled=true;});
 await ask();
 expect(recoverLocalLaunch).toHaveBeenCalledWith('failed-launch-child');
 expect(setClientMissionStatus).toHaveBeenCalledWith('failed-launch-child','interrupted');
 expect(btwSession('failed-launch-parent')?.id).toBe('retry-launch-child');
});
